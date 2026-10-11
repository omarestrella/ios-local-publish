import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import fcntl
from functools import partial
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse
from urllib.error import HTTPError
from urllib.request import urlopen
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/ios-local-publish/scripts"))

from ios_publish import apple, hosting
from ios_publish.cli import resolve_project, reserve_build_number
from ios_publish.common import PublishError
from ios_publish.server import Handler, LocalHTTPServer


class DeviceTests(unittest.TestCase):
  def test_physical_wifi_devices_use_hardware_udid_and_live_state(self):
    raw = {"result": {"devices": [
      {"identifier": "CORE-ID", "properties": {"hardware": {"reality": "physical", "deviceType": "iPad", "udid": "HARDWARE-UDID"},
        "connection": {"transportType": "localNetwork", "state": "disconnected", "pairingState": "paired"}, "state": {"name": "iPad"}}},
      {"identifier": "SIM-ID", "properties": {"hardware": {"reality": "simulated", "deviceType": "iPhone", "udid": "SIM-UDID"},
        "connection": {"transportType": "sameMachine", "state": "connected", "pairingState": "paired"}, "state": {"name": "Simulator"}}},
    ]}}
    devices = apple.normalize_devices(raw)
    self.assertEqual([d["udid"] for d in devices], ["HARDWARE-UDID"])
    self.assertEqual(apple.select_devices(devices, wifi=True)[0]["connection"], "disconnected")
    with self.assertRaises(PublishError):
      apple.select_devices(devices, wifi=True, connected=True)

  def test_legacy_coredevice_schema_and_usb_filter(self):
    raw = {"result": {"devices": [{"identifier": "CORE-ID",
      "hardwareProperties": {"reality": "physical", "deviceType": "iPhone", "udid": "UDID"},
      "deviceProperties": {"name": "Phone", "osVersionNumber": "27.0"},
      "connectionProperties": {"transportType": "wired", "tunnelState": "connected", "pairingState": "paired"}}]}}
    devices = apple.normalize_devices(raw)
    self.assertEqual(devices[0]["udid"], "UDID")
    with self.assertRaises(PublishError):
      apple.select_devices(devices, wifi=True)


class SigningTests(unittest.TestCase):
  def profile(self, bundle="com.example.app", devices=None):
    return {"UUID": bundle, "TeamIdentifier": ["TEAM"], "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=90),
      "DeveloperCertificates": [b"certificate"], "ProvisionedDevices": devices if devices is not None else ["PHONE", "IPAD"],
      "Entitlements": {"application-identifier": "LEGACYPREFIX." + bundle, "get-task-allow": False}}

  def test_profile_requires_device_certificate_team_bundle_and_distribution(self):
    profile = self.profile()
    fingerprint = hashlib.sha1(b"certificate").hexdigest()
    self.assertTrue(apple.profile_matches(profile, "com.example.app", "TEAM", ["phone", "IPAD"], fingerprint))
    for change in ({"ProvisionedDevices": ["PHONE"]}, {"DeveloperCertificates": [b"wrong"]},
      {"TeamIdentifier": ["OTHER"]}, {"ExpirationDate": datetime(2020, 1, 1)}, {"ProvisionsAllDevices": True},
      {"Entitlements": {"application-identifier": "TEAM.com.other", "get-task-allow": False}},
      {"Entitlements": {"application-identifier": "TEAM.com.example.app", "get-task-allow": True}}):
      with self.subTest(change=change):
        self.assertFalse(apple.profile_matches({**profile, **change}, "com.example.app", "TEAM", ["PHONE", "IPAD"], fingerprint))

  def make_ipa(self, path, extension_devices=None, unsafe=False):
    bundles = [("Payload/App.app", "com.example.app", self.profile()),
      ("Payload/App.app/PlugIns/Widget.appex", "com.example.app.widget", self.profile("com.example.app.widget", extension_devices))]
    with zipfile.ZipFile(path, "w") as ipa:
      for directory, identifier, profile in bundles:
        ipa.writestr(directory + "/Info.plist", plistlib.dumps({"CFBundleIdentifier": identifier,
          "CFBundleShortVersionString": "1.0", "CFBundleVersion": "25", "CFBundleName": "Example"}))
        # CMS decoding is stubbed at its OS boundary; actual profile contents are tested.
        ipa.writestr(directory + "/embedded.mobileprovision", plistlib.dumps(profile))
      if unsafe:
        ipa.writestr("../../escape", b"bad")

  @patch("ios_publish.apple.decode_profile", side_effect=plistlib.loads)
  def test_ipa_checks_every_extension_and_reports_common_device_coverage(self, decode):
    with tempfile.TemporaryDirectory() as temp:
      path = Path(temp) / "app.ipa"
      self.make_ipa(path)
      metadata = apple.inspect_ipa(path, ["PHONE", "IPAD"])
      self.assertEqual(len(metadata["profiles"]), 2)
      self.assertEqual(metadata["devices"], ["IPAD", "PHONE"])
      self.assertEqual(metadata["build"], "25")
      self.assertEqual(metadata["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
      self.make_ipa(path, extension_devices=["PHONE"])
      with self.assertRaisesRegex(PublishError, "widget profile excludes devices: IPAD"):
        apple.inspect_ipa(path, ["PHONE", "IPAD"])

  @patch("ios_publish.apple.decode_profile", side_effect=plistlib.loads)
  def test_ipa_rejects_path_traversal_before_extracting(self, decode):
    with tempfile.TemporaryDirectory() as temp:
      path = Path(temp) / "app.ipa"
      self.make_ipa(path, unsafe=True)
      with self.assertRaisesRegex(PublishError, "Unsafe path"):
        apple.inspect_ipa(path)
      decode.assert_not_called()

  def test_ipa_rejects_symlink_escape_before_extracting(self):
    with tempfile.TemporaryDirectory() as temp:
      path = Path(temp) / "app.ipa"
      self.make_ipa(path)
      with zipfile.ZipFile(path, "a") as ipa:
        entry = zipfile.ZipInfo("Payload/App.app/escape")
        entry.create_system = 3
        entry.external_attr = 0o120777 << 16
        ipa.writestr(entry, "../../../outside")
      with self.assertRaisesRegex(PublishError, "Unsafe symlink"):
        apple.inspect_ipa(path)

  @patch("ios_publish.apple.asc")
  def test_disabled_device_is_not_reregistered_or_silently_enabled(self, api):
    udid = "00008120-0000000000000001"
    api.return_value = {"data": [{"id": "ID", "attributes": {"udid": udid, "status": "DISABLED"}}]}
    with self.assertRaisesRegex(PublishError, "disabled"):
      apple.register_devices([{"name": "Phone", "udid": udid}])
    self.assertEqual(api.call_count, 1)


class HostingTests(unittest.TestCase):
  def metadata(self, path):
    return {"ipa_path": str(path), "name": "App <Example>", "bundle_id": "com.example.app", "version": "1.0", "build": "25",
      "expires_at": "2027-01-01T00:00:00+00:00", "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size_bytes": path.stat().st_size}

  def test_manifest_url_and_html_escape_are_valid(self):
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp)
      ipa = state / "input.ipa"
      ipa.write_bytes(b"signed IPA fixture")
      def verify(release):
        relative = urlparse(release["manifest_url"]).path.removeprefix("/ios-publish/")
        document = plistlib.loads((state / "site" / relative).read_bytes())
        self.assertEqual(document["items"][0]["assets"][0]["url"], release["ipa_url"])
        self.assertEqual(document["items"][0]["metadata"]["bundle-version"], "25")
        self.assertEqual(parse_qs(urlparse(release["install_url"]).query)["url"], [release["manifest_url"]])
        page = (state / "site" / relative).with_name("index.html").read_text()
        self.assertIn("App &lt;Example&gt;", page)
        self.assertNotIn("App <Example>", page)
        return {"manifest": True, "ipa_sha256": True, "install_page": True}
      with patch("ios_publish.hosting.verify_hosted", side_effect=verify):
        result = hosting.publish_ipa(state, self.metadata(ipa), "https://mac.example/ios-publish")
      self.assertTrue(result["published"])
      self.assertFalse(result["installed"])
      self.assertEqual(json.loads((state / "latest.json").read_text())["release_id"], result["release_id"])

  def test_failed_host_verification_does_not_promote_latest(self):
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp)
      ipa = state / "input.ipa"
      ipa.write_bytes(b"IPA fixture")
      (state / "latest.json").write_text('{"release_id": "previous"}')
      with patch("ios_publish.hosting.verify_hosted", side_effect=PublishError("checksum mismatch")):
        with self.assertRaises(PublishError):
          hosting.publish_ipa(state, self.metadata(ipa), "https://mac.example/ios-publish")
      self.assertEqual(json.loads((state / "latest.json").read_text())["release_id"], "previous")
      self.assertEqual(list((state / "site/apps/com.example.app").iterdir()), [])

  def test_rejects_invalid_https_base_urls(self):
    for url in ("http://mac.example", "https://user:password@mac.example", "https://mac.example?token=secret", "https://mac.example/#fragment"):
      with self.subTest(url=url), self.assertRaises(PublishError):
        hosting.validate_base_url(url)

  @patch("ios_publish.hosting.run")
  @patch("ios_publish.hosting.serve_status")
  def test_serve_refuses_to_overwrite_another_route(self, status, command):
    status.return_value = {"active": False, "owned": False, "handler": {"Proxy": "http://127.0.0.1:9000"}}
    with tempfile.TemporaryDirectory() as temp:
      with self.assertRaisesRegex(PublishError, "already owned"):
        hosting.serve_start(Path(temp))
      with self.assertRaisesRegex(PublishError, "owned by another"):
        hosting.serve_stop(Path(temp))
    command.assert_not_called()

  @patch("ios_publish.hosting.run")
  @patch("ios_publish.hosting.local_server", return_value={"port": 12345})
  @patch("ios_publish.hosting.serve_status")
  @patch("ios_publish.hosting.verify_https")
  def test_serve_adds_only_its_mount_without_resetting_other_routes(self, https, status, server, command):
    status.side_effect = [{"active": False, "handler": None}, {"active": True, "handler": {"Path": "/site"}, "base_url": "https://mac.example/ios-publish"}]
    with tempfile.TemporaryDirectory() as temp:
      hosting.serve_start(Path(temp))
      args = command.call_args.args[0]
      self.assertIn("--set-path=/ios-publish", args)
      self.assertNotIn("reset", args)


class ProjectTests(unittest.TestCase):
  def test_workspace_discovery_ignores_project_internal_workspace(self):
    with tempfile.TemporaryDirectory() as temp:
      root = Path(temp).resolve()
      (root / "App.xcodeproj/project.xcworkspace").mkdir(parents=True)
      path, flag = resolve_project(temp)
      self.assertEqual(path, root / "App.xcodeproj")
      self.assertEqual(flag, "--project")
      (root / "App.xcworkspace").mkdir()
      path, flag = resolve_project(temp)
      self.assertEqual(path, root / "App.xcworkspace")
      self.assertEqual(flag, "--workspace")

  def test_ambiguous_projects_require_an_explicit_choice(self):
    with tempfile.TemporaryDirectory() as temp:
      (Path(temp) / "One.xcodeproj").mkdir()
      (Path(temp) / "Two.xcodeproj").mkdir()
      with self.assertRaisesRegex(PublishError, "Specify an exact"):
        resolve_project(temp)


class ServerTests(unittest.TestCase):
  def test_loopback_server_mime_types_and_private_paths(self):
    with tempfile.TemporaryDirectory() as temp:
      root = Path(temp) / "site"
      root.mkdir()
      (root / "manifest.plist").write_bytes(b"<plist/>")
      (root / "app.ipa").write_bytes(b"IPA")
      (root / ".secret").write_bytes(b"private")
      outside = Path(temp) / "outside"
      outside.write_bytes(b"private")
      (root / "escape").symlink_to(outside)
      (root / "empty").mkdir()
      (root / "directory").mkdir()
      (root / "directory/index.html").symlink_to(outside)
      class QuietHandler(Handler):
        def log_message(self, *args):
          pass
      server = LocalHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(root)))
      thread = threading.Thread(target=server.serve_forever, daemon=True)
      thread.start()
      try:
        base = f"http://127.0.0.1:{server.server_port}"
        with urlopen(base + "/manifest.plist") as response:
          self.assertEqual(response.headers["Content-Type"], "text/xml")
          self.assertEqual(response.headers["Cache-Control"], "no-store")
        with urlopen(base + "/app.ipa") as response:
          self.assertEqual(response.headers["Content-Type"], "application/octet-stream")
          self.assertEqual(response.read(), b"IPA")
        for path in ("/.secret", "/escape", "/empty/", "/directory/"):
          with self.subTest(path=path), self.assertRaises(HTTPError) as context:
            urlopen(base + path)
          self.assertEqual(context.exception.code, 404)
          context.exception.close()
      finally:
        server.shutdown()
        server.server_close()
        thread.join()


class AgentInterfaceTests(unittest.TestCase):
  def invoke(self, state, *args):
    launcher = Path(__file__).resolve().parents[1] / "ios-publish"
    return subprocess.run([sys.executable, str(launcher), "--state-dir", str(state), *args, "--json"],
      capture_output=True, text=True, cwd=state)

  def test_error_is_one_json_document_with_nonzero_exit(self):
    with tempfile.TemporaryDirectory() as temp:
      result = self.invoke(temp, "latest")
      self.assertEqual(result.returncode, 1)
      self.assertFalse(json.loads(result.stdout)["ok"])
      self.assertEqual(result.stderr, "")

  def test_concurrent_writers_fail_clearly_and_readers_still_work(self):
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp)
      project = state / "App With Spaces.xcodeproj"
      project.mkdir()
      (state / "latest.json").write_text('{"release_id":"previous"}')
      with (state / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = self.invoke(state, "init", "--project", str(project), "--scheme", "App")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Another ios-publish command", json.loads(result.stdout)["error"])
        result = self.invoke(state, "latest")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["release_id"], "previous")
      result = self.invoke(state, "init", "--project", str(project), "--scheme", "App")
      self.assertEqual(result.returncode, 0)
      self.assertEqual(json.loads(result.stdout)["project"], str(project.resolve()))


class BuildNumberTests(unittest.TestCase):
  @patch("ios_publish.cli.run_json")
  def test_default_advances_past_project_history_and_failed_reservations(self, settings):
    settings.return_value = [{"target": "App", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.application", "CURRENT_PROJECT_VERSION": "24"}}]
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp)
      project = state / "App.xcodeproj"
      self.assertEqual(reserve_build_number(state, project, "App", "Release", "46"), "46")
      self.assertEqual(reserve_build_number(state, project, "App", "Release"), "47")
      self.assertEqual(reserve_build_number(state, project, "App", "Release"), "48")
      self.assertEqual(reserve_build_number(state, project, "App", "Release", "25"), "25")
      self.assertEqual(reserve_build_number(state, project, "App", "Release"), "49")

  @patch("ios_publish.cli.run_json")
  def test_migrates_existing_build_and_keeps_projects_separate(self, settings):
    settings.return_value = [{"target": "App", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.application", "CURRENT_PROJECT_VERSION": "24"}}]
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp)
      project = state / "App.xcodeproj"
      (state / "config.json").write_text(json.dumps({"project": str(project), "scheme": "App"}))
      (state / "last-build.json").write_text(json.dumps({"build": "46"}))
      self.assertEqual(reserve_build_number(state, project, "App", "Release"), "47")
      self.assertEqual(reserve_build_number(state, state / "Other.xcodeproj", "App", "Release"), "25")


if __name__ == "__main__":
  unittest.main()
