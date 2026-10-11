from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
import hashlib
from http.client import IncompleteRead
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/ios-local-publish/scripts"))

from ios_publish import apple, cli, hosting
from ios_publish.common import PublishError

UDID = "00008120-0000000000000001"
DEVICE = {"name": "Phone", "udid": UDID}
SETTINGS = [{"target": "App", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.application",
  "CURRENT_PROJECT_VERSION": "24", "DEVELOPMENT_TEAM": "TEAM", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app", "WRAPPER_EXTENSION": "app"}}]


class SigningPreflightTests(unittest.TestCase):
  @patch("ios_publish.apple.asc")
  def test_invalid_udids_rejected_before_any_apple_api_call(self, api):
    for value in ("not-a-udid", "E78E8956-FD32-556D-A5AA-5C1E1035A274", "", "00008120-000000000000000"):
      with self.subTest(value=value), self.assertRaisesRegex(PublishError, "hardware UDID"):
        apple.register_devices([DEVICE, {"name": "Invalid", "udid": value}])
    api.assert_not_called()
    self.assertEqual(len(apple.validate_devices([DEVICE, DEVICE])), 1)
    self.assertEqual(apple.validate_devices([{"udid": "a" * 40, "name": "Legacy"}])[0]["udid"], "A" * 40)

  @patch("ios_publish.apple.asc")
  def test_disabled_later_target_prevents_registering_earlier_new_target(self, api):
    disabled = "00008120-0000000000000002"
    api.return_value = {"data": [{"id": "ID", "attributes": {"udid": disabled, "status": "DISABLED"}}]}
    with self.assertRaisesRegex(PublishError, "disabled"):
      apple.register_devices([DEVICE, {"udid": disabled, "name": "Disabled"}])
    self.assertEqual(api.call_count, 1)

  def test_minimum_profile_lifetime_is_enforced_and_can_be_lowered(self):
    certificate = b"certificate"
    profile = {"TeamIdentifier": ["TEAM"], "DeveloperCertificates": [certificate], "ProvisionedDevices": [UDID],
      "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=2),
      "Entitlements": {"application-identifier": "TEAM.com.example.app", "get-task-allow": False}}
    fingerprint = hashlib.sha1(certificate).hexdigest()
    self.assertFalse(apple.profile_matches(profile, "com.example.app", "TEAM", [UDID], fingerprint))
    self.assertTrue(apple.profile_matches(profile, "com.example.app", "TEAM", [UDID], fingerprint, 0))

  @patch("ios_publish.apple.register_devices")
  @patch("ios_publish.apple.archive_bundles")
  @patch("ios_publish.apple.signing_preflight")
  def test_missing_archived_extension_id_prevents_registration(self, preflight, bundles, register):
    preflight.return_value = {"team": "TEAM", "certificate": {}, "bundle_ids": {"com.example.app": {}}, "profiles": []}
    bundles.return_value = [{"bundle_id": "com.example.app"}, {"bundle_id": "com.example.app.widget"}]
    with tempfile.TemporaryDirectory() as temp:
      archive = Path(temp)
      (archive / "Info.plist").write_bytes(plistlib.dumps({"ApplicationProperties": {"Team": "TEAM"}}))
      with self.assertRaisesRegex(PublishError, "widget"):
        apple.prepare_signing(archive, [DEVICE], archive / "signing")
    register.assert_not_called()


class BuildOrchestrationTests(unittest.TestCase):
  def setup_build(self, root):
    project = root / "App.xcodeproj"
    project.mkdir()
    args = cli.parser().parse_args(["build", "--project", str(project), "--scheme", "App", "--build-number", "46"])
    return args, {"devices": [DEVICE], "team": "TEAM"}

  @patch("ios_publish.cli.run")
  @patch("ios_publish.cli.project_settings", return_value=SETTINGS)
  @patch("ios_publish.apple.signing_preflight", side_effect=PublishError("missing certificate"))
  def test_missing_signing_material_fails_before_number_reservation_or_archive(self, preflight, settings, command):
    with tempfile.TemporaryDirectory() as temp:
      root = Path(temp)
      args, config = self.setup_build(root)
      with self.assertRaisesRegex(PublishError, "missing certificate"):
        cli.build(args, root, config)
      self.assertFalse((root / "build-numbers.json").exists())
    command.assert_not_called()

  @patch("ios_publish.cli.run")
  @patch("ios_publish.cli.project_settings", return_value=SETTINGS)
  @patch("ios_publish.apple.signing_preflight", return_value={"team": "TEAM"})
  @patch("ios_publish.apple.prepare_signing", return_value={"export_options": "fixture.plist"})
  @patch("ios_publish.apple.inspect_ipa", return_value={"build": "24"})
  def test_hardcoded_bundle_version_fails_before_success_or_publication(self, inspect, signing, preflight, settings, command):
    with tempfile.TemporaryDirectory() as temp:
      root = Path(temp)
      args, config = self.setup_build(root)
      with self.assertRaisesRegex(PublishError, "Exported build 24 differs from requested build 46"):
        cli.build(args, root, config)
      self.assertFalse((root / "last-build.json").exists())
      result = json.loads(next((root / "runs").glob("*/result.json")).read_text())
      self.assertEqual(result["status"], "failed")

  @patch("ios_publish.cli.project_settings")
  def test_unset_project_version_has_actionable_error(self, settings):
    settings.return_value = [{"target": "App", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.application"}}]
    with tempfile.TemporaryDirectory() as temp:
      with self.assertRaisesRegex(PublishError, "CURRENT_PROJECT_VERSION is unset"):
        cli.reserve_build_number(Path(temp), Path(temp) / "App.xcodeproj", "App", "Release")

  @patch("ios_publish.cli.build")
  @patch("ios_publish.hosting.serve_start", side_effect=PublishError("HTTPS unreachable"))
  def test_https_failure_prevents_build(self, start, build):
    args = cli.parser().parse_args(["publish", "--udid", UDID])
    with tempfile.TemporaryDirectory() as temp:
      with self.assertRaisesRegex(PublishError, "HTTPS unreachable"):
        cli.execute(args, Path(temp))
    build.assert_not_called()


class HostingFailureTests(unittest.TestCase):
  @patch("ios_publish.hosting.urlopen", side_effect=IncompleteRead(b"partial", 100))
  def test_http_protocol_errors_are_wrapped(self, request):
    with self.assertRaisesRegex(PublishError, "Cannot verify hosted"):
      hosting.verify_hosted({"manifest_url": "https://mac.example/manifest.plist"})

  @patch("ios_publish.hosting.verify_hosted", side_effect=KeyboardInterrupt)
  def test_interrupt_removes_unverified_release_and_preserves_latest(self, verify):
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp)
      ipa = state / "App.ipa"
      ipa.write_bytes(b"fixture")
      (state / "latest.json").write_text('{"build":"45"}')
      metadata = {"bundle_id": "com.example.app", "ipa_path": str(ipa), "name": "App", "version": "1.0", "build": "46",
        "expires_at": "2027-01-01T00:00:00+00:00", "size_bytes": 7, "sha256": "fixture"}
      with self.assertRaises(KeyboardInterrupt):
        hosting.publish_ipa(state, metadata, "https://mac.example/ios-publish")
      self.assertEqual(list((state / "site/apps/com.example.app").iterdir()), [])
      self.assertEqual(json.loads((state / "latest.json").read_text())["build"], "45")

  @patch("ios_publish.hosting.time.sleep")
  @patch("ios_publish.hosting.urlopen")
  def test_https_preflight_retries_and_checks_publisher_identity(self, request, sleep):
    site = "/private/publisher/site"
    request.side_effect = [OSError("certificate pending"), io.BytesIO(json.dumps(hosting.health_identity(site)).encode())]
    hosting.verify_https("https://mac.example/ios-publish", site)
    self.assertEqual(request.call_count, 2)
    self.assertNotIn(site, json.dumps(hosting.health_identity(site)))
    request.side_effect = [io.BytesIO(b'{"service":"wrong"}')]
    with self.assertRaisesRegex(PublishError, "different local publisher"):
      hosting.verify_https("https://mac.example/ios-publish", site)

  @patch("ios_publish.hosting.server_interpreter", return_value=sys.executable)
  @patch("ios_publish.hosting.server_health", return_value=True)
  @patch("ios_publish.hosting.run")
  def test_server_code_lives_in_state_and_missing_plist_job_is_unloaded(self, command, health, interpreter):
    with tempfile.TemporaryDirectory() as temp:
      state = Path(temp) / "state"
      state.mkdir()
      with patch("pathlib.Path.home", return_value=Path(temp)):
        metadata = hosting.local_server(state)
      agent = plistlib.loads(Path(metadata["launch_agent"]).read_bytes())
      self.assertEqual(agent["ProgramArguments"][1], str(state / "server-runtime/server.py"))
      self.assertTrue(Path(agent["ProgramArguments"][1]).is_file())
      self.assertEqual(command.call_args_list[0].args[0][:2], ["launchctl", "bootout"])
      self.assertTrue(hosting.program_paths_exist(metadata))
      Path(agent["ProgramArguments"][1]).unlink()
      self.assertFalse(hosting.program_paths_exist(metadata))

  @patch("ios_publish.cli.shutil.which", return_value="/usr/bin/tool")
  @patch("ios_publish.cli.run", return_value=b"fixture")
  @patch("ios_publish.cli.asc", return_value={})
  @patch("ios_publish.hosting.serve_status", return_value={"owned": True, "active": False, "server_ready": False, "program_paths_exist": True})
  def test_doctor_reports_owned_unhealthy_hosting_as_failure(self, status, asc, command, which):
    with tempfile.TemporaryDirectory() as temp:
      result = cli.execute(cli.parser().parse_args(["doctor"]), Path(temp))
    self.assertFalse(result["ok"])
    self.assertIn("unhealthy", result["hosting"]["error"])


class CLIContractTests(unittest.TestCase):
  def test_parse_errors_are_one_json_document(self):
    for args in (["publish", "--unknown", "--json"], ["serve", "invalid", "--json"], ["build", "--min-validity-days", "-1", "--json"]):
      out = io.StringIO()
      with self.subTest(args=args), patch.object(sys, "argv", ["ios-publish", *args]), redirect_stdout(out):
        with self.assertRaises(SystemExit) as context:
          cli.main()
        self.assertEqual(context.exception.code, 1)
      self.assertFalse(json.loads(out.getvalue())["ok"])

  def test_ignored_argument_combinations_now_fail(self):
    cases = (["publish", "--connected"], ["build", "--archive", "App.xcarchive", "--build-number", "50"],
      ["publish", "--ipa", "App.ipa", "--configuration", "Debug"], ["devices", "register", "--wifi", "--udid", UDID])
    with tempfile.TemporaryDirectory() as temp:
      for command in cases:
        with self.subTest(command=command), self.assertRaises(PublishError):
          cli.execute(cli.parser().parse_args(command), Path(temp))


if __name__ == "__main__":
  unittest.main()
