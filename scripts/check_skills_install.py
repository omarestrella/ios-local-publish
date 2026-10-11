#!/usr/bin/env python3
"""Exercise the real Vercel skills CLI in disposable project directories."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd, env):
  result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
  if result.returncode:
    raise RuntimeError(f"{command[0]} failed: {result.stdout}\n{result.stderr}")
  return result.stdout


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--skills-version", default="1.7.2", help="Published skills CLI version to test")
  args = parser.parse_args()
  with tempfile.TemporaryDirectory(prefix="ios-local-publish-skills-") as temporary:
    workspace = Path(temporary).resolve()
    env = {key: value for key, value in os.environ.items() if key not in ("IOS_PUBLISH_HOME", "PYTHONPATH")}
    env.update({"DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1", "IOS_LOCAL_PUBLISH_SETTINGS": str(workspace / "no-machine-settings.json")})
    state = workspace / "state"
    state.mkdir()
    (state / "latest.json").write_text('{"build":"46","release_id":"fixture"}')
    prefix = ["npx", "--yes", f"skills@{args.skills_version}", "add", str(ROOT), "--skill", "ios-local-publish"]
    discovery = run([*prefix, "--list"], workspace, env)
    if "ios-local-publish" not in discovery:
      raise RuntimeError("skills CLI did not discover ios-local-publish")
    for mode in ("symlink", "copy"):
      project = workspace / mode
      project.mkdir()
      command = [*prefix, "--agent", "codex", "claude-code", "--yes"]
      if mode == "copy":
        command.append("--copy")
      run(command, project, env)
      for agent_dir in (".agents", ".claude"):
        skill = project / agent_dir / "skills/ios-local-publish"
        launcher = skill / "scripts/ios-local-publish"
        if not launcher.is_file():
          raise RuntimeError(f"Missing launcher after {mode} install: {launcher}")
        if not os.access(launcher, os.X_OK):
          raise RuntimeError(f"Installed launcher is not executable: {launcher}")
        forbidden = [path for path in skill.rglob("*") if path.name.endswith((".ipa", ".p12", ".p8", ".mobileprovision", ".egg-info")) or path.name == "__pycache__"]
        if forbidden:
          raise RuntimeError(f"Generated/private artifacts were bundled: {forbidden}")
        result = json.loads(run([sys.executable, "-I", str(launcher), "--state-dir", str(state), "latest", "--json"], workspace, env))
        if result.get("build") != "46":
          raise RuntimeError(f"Installed {agent_dir}/{mode} launcher failed: {result}")
        print(json.dumps({"mode": mode, "agent": agent_dir, "standalone_runtime": True}), flush=True)
      # Reinstall through the actual CLI and confirm the external ledger survives.
      run(command, project, env)
      if json.loads((state / "latest.json").read_text())["release_id"] != "fixture":
        raise RuntimeError("Reinstall changed external state")
    print(json.dumps({"ok": True, "skills_version": args.skills_version, "discovery": True, "reinstall": True}))


if __name__ == "__main__":
  main()
