from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


class PublishError(Exception):
  pass


def default_state() -> Path:
  if "IOS_PUBLISH_HOME" in os.environ:
    return Path(os.environ["IOS_PUBLISH_HOME"])
  settings = Path(os.environ.get("IOS_LOCAL_PUBLISH_SETTINGS", Path.home() / ".config/ios-local-publish/settings.json")).expanduser()
  try:
    if settings.exists():
      document = json.loads(settings.read_text())
      if not isinstance(document, dict) or not isinstance(document.get("state_dir"), str):
        raise ValueError("expected an object with a state_dir string")
      state = Path(document["state_dir"]).expanduser()
      if not state.is_absolute():
        raise ValueError("state_dir must be absolute")
      return state
  except (OSError, ValueError) as error:
    raise PublishError(f"Cannot read machine settings {settings}: {error}") from error
  return Path.home() / ".local/share/ios-publish"


def progress(message: str):
  print(message, file=sys.stderr, flush=True)


def run(args: list[str], *, log: Path | None = None, timeout: int | None = 120) -> bytes:
  """Never invoke a shell; reserve stdout for the caller's JSON result."""
  try:
    if log:
      log.parent.mkdir(parents=True, exist_ok=True)
      progress(f"Running {args[0]} {args[1]} {args[2]} — log: {log}")
      with log.open("wb") as output:
        result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
      if result.returncode:
        raise PublishError(f"Command failed ({result.returncode}); see {log}")
      return log.read_bytes()
    result = subprocess.run(args, capture_output=True, timeout=timeout)
  except FileNotFoundError:
    raise PublishError(f"Required command not found: {args[0]}") from None
  except subprocess.TimeoutExpired:
    raise PublishError(f"Command timed out: {args[0]} {' '.join(args[1:3])}") from None
  if result.returncode:
    message = result.stderr.decode(errors="replace").strip() or result.stdout.decode(errors="replace").strip()
    raise PublishError(f"{args[0]} {' '.join(args[1:3])} failed ({result.returncode}): {message[-3000:]}")
  return result.stdout


def run_json(args: list[str]):
  try:
    return json.loads(run(args))
  except json.JSONDecodeError:
    raise PublishError(f"Invalid JSON from {args[0]}") from None


def asc(*args: str):
  return run_json(["asc", *args, "--output", "json"])


def write_json(path: Path, value):
  atomic_write(path, (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode())


def atomic_write(path: Path, data: bytes):
  path.parent.mkdir(parents=True, exist_ok=True)
  fd, name = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
  try:
    with os.fdopen(fd, "wb") as output:
      output.write(data)
    os.replace(name, path)
  finally:
    Path(name).unlink(missing_ok=True)
