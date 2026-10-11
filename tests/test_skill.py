import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install_skill.py"
spec = importlib.util.spec_from_file_location("install_skill", INSTALLER)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class SkillTests(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory()
    self.addCleanup(self.temporary.cleanup)
    self.root = Path(self.temporary.name).resolve()
    self.destination = self.root / "skills with spaces/ios-local-publish"
    self.settings = self.root / "settings.json"
    self.state = self.root / "state with spaces"
    self.state.mkdir()
    (self.state / "latest.json").write_text('{"build":"46","release_id":"existing","published":true}')
    self.env = {key: value for key, value in os.environ.items() if key not in ("IOS_PUBLISH_HOME", "PYTHONPATH")}
    self.env["IOS_LOCAL_PUBLISH_SETTINGS"] = str(self.settings)

  def install(self, *args):
    return subprocess.run([sys.executable, str(INSTALLER), "--destination", str(self.destination),
      "--settings", str(self.settings), *args], capture_output=True, text=True, env=self.env, cwd=self.root)

  def invoke(self, *args, env=None):
    return subprocess.run([sys.executable, "-I", str(self.destination / "scripts/ios-local-publish"), *args],
      capture_output=True, text=True, env=env or self.env, cwd=self.root)

  def test_standalone_bundle_runs_outside_checkout_and_contains_no_state(self):
    result = self.install("--state-dir", str(self.state))
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    manifest = json.loads((self.destination / "bundle.json").read_text())
    self.assertEqual(manifest["name"], "ios-local-publish")
    self.assertEqual(set(manifest["files"]), {
      "SKILL.md", "agents/openai.yaml", "references/setup.md", "references/troubleshooting.md", "scripts/ios-local-publish",
      *["scripts/ios_publish/" + path.name for path in (ROOT / "skills/ios-local-publish/scripts/ios_publish").glob("*.py")]})
    result = self.invoke("latest", "--json")
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertEqual(json.loads(result.stdout)["build"], "46")
    self.assertEqual(list(self.destination.rglob("__pycache__")), [])

  def test_upgrade_preserves_external_state_settings_and_link(self):
    self.assertEqual(self.install("--state-dir", str(self.state)).returncode, 0)
    state_before = (self.state / "latest.json").read_bytes()
    self.settings.write_text(json.dumps({"state_dir": str(self.state), "unrelated_setting": True}))
    result = self.install()
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertEqual(json.loads(self.settings.read_text())["state_dir"], str(self.state))
    self.assertTrue(json.loads(self.settings.read_text())["unrelated_setting"])
    self.assertEqual((self.state / "latest.json").read_bytes(), state_before)
    self.assertEqual(json.loads(self.invoke("latest", "--json").stdout)["release_id"], "existing")

  def test_state_flag_overrides_environment_which_overrides_settings(self):
    self.assertEqual(self.install("--state-dir", str(self.state)).returncode, 0)
    alternative = self.root / "alternative"
    alternative.mkdir()
    (alternative / "latest.json").write_text('{"build":"99"}')
    env = {**self.env, "IOS_PUBLISH_HOME": str(alternative)}
    self.assertEqual(json.loads(self.invoke("latest", "--json", env=env).stdout)["build"], "99")
    self.assertEqual(json.loads(self.invoke("--state-dir", str(self.state), "latest", "--json", env=env).stdout)["build"], "46")
    self.settings.write_text("invalid json")
    result = self.invoke("latest", "--json")
    self.assertEqual(result.returncode, 1)
    self.assertIn("machine settings", json.loads(result.stdout)["error"])
    self.assertEqual(json.loads(self.invoke("--state-dir=" + str(self.state), "latest", "--json").stdout)["build"], "46")

  def test_portable_bundle_uses_normal_default_without_machine_settings(self):
    self.assertEqual(self.install("--state-dir", str(self.state)).returncode, 0)
    self.settings.unlink()
    env = {**self.env, "HOME": str(self.root / "fresh-home")}
    default = Path(env["HOME"]) / ".local/share/ios-publish"
    default.mkdir(parents=True)
    (default / "latest.json").write_text('{"build":"2"}')
    result = self.invoke("latest", "--json", env=env)
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertEqual(json.loads(result.stdout)["build"], "2")

  def test_refuses_unmanaged_modified_or_symlinked_destinations(self):
    self.destination.mkdir(parents=True)
    sentinel = self.destination / "existing.txt"
    sentinel.write_text("preserve")
    result = self.install("--state-dir", str(self.state))
    self.assertEqual(result.returncode, 1)
    self.assertEqual(sentinel.read_text(), "preserve")
    shutil.rmtree(self.destination)
    self.assertEqual(self.install("--state-dir", str(self.state)).returncode, 0)
    entry = self.destination / "SKILL.md"
    entry.write_text(entry.read_text() + "\nlocal edit\n")
    self.assertEqual(self.install().returncode, 1)
    self.assertTrue(entry.read_text().endswith("local edit\n"))
    original = self.destination.with_name("original")
    self.destination.rename(original)
    self.destination.symlink_to(original, target_is_directory=True)
    result = self.install()
    self.assertEqual(result.returncode, 1)
    self.assertIn("symlink", json.loads(result.stdout)["error"])

  def test_settings_write_failure_rolls_back_installed_code(self):
    self.assertEqual(self.install("--state-dir", str(self.state)).returncode, 0)
    before = (self.destination / "bundle.json").read_bytes()
    argv = [str(INSTALLER), "--destination", str(self.destination), "--settings", str(self.settings)]
    real_write = installer.write_json
    def fail_settings(path, value):
      if path == self.settings:
        raise OSError("settings are unwritable")
      return real_write(path, value)
    with patch.object(sys, "argv", argv), patch.object(installer, "write_json", side_effect=fail_settings), redirect_stdout(io.StringIO()):
      with self.assertRaises(SystemExit) as context:
        installer.main()
      self.assertEqual(context.exception.code, 1)
    self.assertEqual((self.destination / "bundle.json").read_bytes(), before)
    self.assertEqual(json.loads(self.invoke("latest", "--json").stdout)["build"], "46")

  def test_refuses_state_or_settings_inside_bundle(self):
    result = self.install("--state-dir", str(self.destination / "state"))
    self.assertEqual(result.returncode, 1)
    self.assertFalse(self.destination.exists())
    result = subprocess.run([sys.executable, str(INSTALLER), "--destination", str(self.destination),
      "--settings", str(self.destination / "settings.json")], capture_output=True, text=True)
    self.assertEqual(result.returncode, 1)
    self.assertFalse(self.destination.exists())

  def test_finder_metadata_does_not_prevent_upgrade(self):
    self.assertEqual(self.install("--state-dir", str(self.state)).returncode, 0)
    (self.destination / ".DS_Store").write_bytes(b"Finder metadata")
    result = self.install()
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertFalse((self.destination / ".DS_Store").exists())

  def test_source_skill_alone_is_a_complete_installable_bundle(self):
    shutil.copytree(ROOT / "skills/ios-local-publish", self.destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    result = self.invoke("--state-dir", str(self.state), "latest", "--json")
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertEqual(json.loads(result.stdout)["build"], "46")

  def test_checkout_launcher_shares_machine_settings(self):
    self.settings.write_text(json.dumps({"state_dir": str(self.state)}))
    result = subprocess.run([sys.executable, "-I", str(ROOT / "ios-publish"), "latest", "--json"],
      cwd=self.root, env=self.env, capture_output=True, text=True)
    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    self.assertEqual(json.loads(result.stdout)["release_id"], "existing")


if __name__ == "__main__":
  unittest.main()
