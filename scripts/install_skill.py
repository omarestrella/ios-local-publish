#!/usr/bin/env python3
"""Build and atomically install the skill, without bundling machine state."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
NAME = "ios-local-publish"


def write_json(path: Path, document):
  path.parent.mkdir(parents=True, exist_ok=True)
  fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
  try:
    with os.fdopen(fd, "w") as output:
      json.dump(document, output, indent=2)
      output.write("\n")
    os.replace(temporary, path)
  finally:
    Path(temporary).unlink(missing_ok=True)


def checksum(path: Path):
  return hashlib.sha256(path.read_bytes()).hexdigest()


def check_destination(destination: Path):
  if destination.is_symlink():
    raise ValueError(f"Refusing to replace a symlink: {destination}")
  if not destination.exists():
    return
  marker = destination / "bundle.json"
  if not marker.is_file():
    raise ValueError(f"Existing destination is not an installer-managed skill: {destination}")
  document = json.loads(marker.read_text())
  if not isinstance(document, dict) or document.get("name") != NAME or document.get("format") != 1:
    raise ValueError(f"Unrecognized skill bundle at {destination}")
  expected = document.get("files", {})
  actual = {str(path.relative_to(destination)): checksum(path) for path in destination.rglob("*")
    if path.is_file() and path != marker and "__pycache__" not in path.parts and path.name != ".DS_Store"}
  if actual != expected or any(path.is_symlink() for path in destination.rglob("*")):
    raise ValueError(f"Installed skill has local changes; preserve them before upgrading: {destination}")


def build_bundle(destination: Path):
  template = ROOT / "skills" / NAME
  sources = [template / "SKILL.md", template / "scripts" / NAME,
    *sorted((template / "agents").glob("*.yaml")), *sorted((template / "references").glob("*.md")),
    *sorted((template / "scripts/ios_publish").glob("*.py"))]
  destination.mkdir()
  for source in sources:
    if source.is_symlink():
      raise ValueError(f"Skill source must not be a symlink: {source}")
    target = destination / source.relative_to(template)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
  launcher = destination / "scripts" / NAME
  launcher.chmod(0o755)
  smoke = subprocess.run([sys.executable, str(launcher), "--help"], cwd=destination,
    env={**os.environ, "IOS_PUBLISH_HOME": str(destination / "unused-state")}, capture_output=True, text=True)
  if smoke.returncode:
    raise ValueError(f"Bundled runtime failed its smoke check: {smoke.stderr or smoke.stdout}")
  version = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]["version"]
  files = {str(path.relative_to(destination)): checksum(path) for path in sorted(destination.rglob("*")) if path.is_file()}
  write_json(destination / "bundle.json", {"format": 1, "name": NAME, "version": version, "files": files})


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--destination", type=Path, default=Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "skills" / NAME,
    help="Complete destination skill folder (default: $CODEX_HOME/skills/ios-local-publish)")
  parser.add_argument("--state-dir", type=Path, help="Adopt an existing state directory or choose a new one; artifacts stay there")
  parser.add_argument("--adopt-checkout-state", action="store_true", help="Explicitly use this checkout's existing .ios-publish state")
  parser.add_argument("--settings", type=Path, default=Path(os.environ.get("IOS_LOCAL_PUBLISH_SETTINGS", Path.home() / ".config/ios-local-publish/settings.json")),
    help="Machine settings file outside the skill")
  args = parser.parse_args()
  # Preserve the final component so destination symlinks can be rejected.
  destination = args.destination.expanduser().absolute()
  settings = args.settings.expanduser().resolve()
  try:
    if args.adopt_checkout_state and args.state_dir:
      raise ValueError("Choose --state-dir or --adopt-checkout-state, not both")
    if settings.is_relative_to(destination.resolve()):
      raise ValueError("Machine settings must live outside the skill bundle")
    previous_settings = json.loads(settings.read_text()) if settings.exists() else {}
    if not isinstance(previous_settings, dict):
      raise ValueError("Machine settings must contain a JSON object")
    if args.adopt_checkout_state:
      state = ROOT / ".ios-publish"
      if not (state / "config.json").is_file():
        raise ValueError("No configured .ios-publish state exists in this checkout")
    elif args.state_dir:
      state = args.state_dir.expanduser().resolve()
    elif previous_settings.get("state_dir"):
      state = Path(previous_settings["state_dir"]).expanduser()
      if not state.is_absolute():
        raise ValueError("Saved state_dir must be absolute")
      state = state.resolve()
    else:
      state = Path.home() / ".local/share/ios-publish"
    if state == destination.resolve() or state.is_relative_to(destination.resolve()) or destination.resolve().is_relative_to(state):
      raise ValueError("The skill and state directories must be separate")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with (destination.parent / f".{NAME}.install.lock").open("a") as lock:
      try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
      except BlockingIOError:
        raise ValueError("Another ios-local-publish installation is running; wait for it to finish") from None
      check_destination(destination)
      with tempfile.TemporaryDirectory(dir=destination.parent, prefix=f".{NAME}-") as temporary:
        staged = Path(temporary) / NAME
        backup = Path(temporary) / "previous"
        build_bundle(staged)
        if destination.exists():
          destination.rename(backup)
        try:
          staged.rename(destination)
          write_json(settings, {**previous_settings, "state_dir": str(state)})
        except BaseException:
          if destination.exists():
            shutil.rmtree(destination)
          if backup.exists():
            backup.rename(destination)
          raise
    print(json.dumps({"ok": True, "skill_path": str(destination), "launcher": str(destination / "scripts" / NAME),
      "settings_path": str(settings), "state_dir": str(state)}))
  except (OSError, ValueError, TypeError) as error:
    print(json.dumps({"ok": False, "error": str(error)}))
    raise SystemExit(1)


if __name__ == "__main__":
  main()
