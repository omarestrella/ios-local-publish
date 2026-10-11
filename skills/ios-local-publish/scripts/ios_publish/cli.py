from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import shutil
import re
import sys
import uuid
import zipfile

from . import apple, hosting
from .common import PublishError, asc, default_state, progress, run, run_json, write_json


class ArgumentParser(argparse.ArgumentParser):
  def error(self, message):
    raise PublishError(message)


def nonnegative(value: str) -> int:
  try:
    result = int(value)
  except ValueError:
    raise argparse.ArgumentTypeError("must be a nonnegative integer") from None
  if result < 0:
    raise argparse.ArgumentTypeError("must be a nonnegative integer")
  return result


def load_config(state: Path) -> dict:
  path = state / "config.json"
  return json.loads(path.read_text()) if path.exists() else {}


def configured_devices(args, config: dict) -> list[dict]:
  if getattr(args, "udid", None):
    return apple.validate_devices([{"udid": udid, "name": udid} for udid in args.udid])
  if getattr(args, "wifi", False):
    return apple.validate_devices(apple.select_devices(apple.discover_devices(), wifi=True, connected=getattr(args, "connected", False)))
  devices = config.get("devices", [])
  if not devices:
    raise PublishError("No target devices configured. Run devices register --wifi, or pass --udid.")
  return apple.validate_devices(devices)


def project_settings(project: Path, scheme: str, configuration: str, extra: list[str] | None = None) -> list[dict]:
  flag = "-workspace" if project.suffix == ".xcworkspace" else "-project"
  return run_json(["xcodebuild", flag, str(project), "-scheme", scheme,
    "-configuration", configuration, *(extra or []), "-showBuildSettings", "-json"])


def application_settings(settings: list[dict], scheme: str) -> dict:
  applications = [row for row in settings if row.get("buildSettings", {}).get("PRODUCT_TYPE") == "com.apple.product-type.application"]
  main = next((row for row in applications if row.get("target") == scheme), None)
  if main is None and len(applications) == 1:
    main = applications[0]
  if main is None:
    raise PublishError("Cannot identify the scheme's app target. Select a scheme with one application target.")
  return main["buildSettings"]


def resolve_project(value: str) -> tuple[Path, str]:
  path = Path(value).expanduser().resolve()
  if path.is_dir() and path.suffix in (".xcodeproj", ".xcworkspace"):
    return path, "--workspace" if path.suffix == ".xcworkspace" else "--project"
  if not path.is_dir():
    raise PublishError(f"Project directory does not exist: {path}")
  # Prefer a workspace alongside projects, ignoring project-internal and dependency workspaces.
  candidates = []
  for root, dirs, _ in os.walk(path):
    dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "Pods", "Carthage", ".build", ".ios-publish", ".venv")]
    for name in list(dirs):
      candidate = Path(root) / name
      if candidate.suffix in (".xcodeproj", ".xcworkspace"):
        candidates.append(candidate)
        dirs.remove(name)
    if len(Path(root).relative_to(path).parts) >= 3:
      dirs.clear()
  workspaces = [c for c in candidates if c.suffix == ".xcworkspace"]
  choices = workspaces or candidates
  if len(choices) != 1:
    raise PublishError("Specify an exact .xcodeproj/.xcworkspace; found: " + ", ".join(str(c) for c in choices))
  return resolve_project(str(choices[0]))


def build_version(value: str) -> tuple[int, int, int]:
  if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
    raise PublishError(f"Build number must contain one to three numeric components: {value}")
  parts = [int(part) for part in value.split(".")]
  return tuple(parts + [0] * (3 - len(parts)))


def reserve_build_number(state: Path, project: Path, scheme: str, configuration: str, explicit: str | None = None,
    settings: list[dict] | None = None) -> str:
  identity = hashlib.sha256(f"{project}\n{scheme}".encode()).hexdigest()
  ledger_path = state / "build-numbers.json"
  ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {}
  candidates = [ledger[identity]["build"]] if identity in ledger else []
  # Migrate the existing local record, including builds published before automatic numbering.
  previous_path = state / "last-build.json"
  if previous_path.exists():
    previous = json.loads(previous_path.read_text())
    config = load_config(state)
    previous_project = previous.get("project", config.get("project"))
    previous_scheme = previous.get("scheme", config.get("scheme"))
    if previous_project == str(project) and previous_scheme == scheme and previous.get("build"):
      candidates.append(previous["build"])
  if explicit:
    build_version(explicit)
    number = explicit
  else:
    main = application_settings(settings if settings is not None else project_settings(project, scheme, configuration), scheme)
    current = str(main.get("CURRENT_PROJECT_VERSION", ""))
    if not current:
      raise PublishError("CURRENT_PROJECT_VERSION is unset; pass --build-number and ensure CFBundleVersion uses $(CURRENT_PROJECT_VERSION).")
    build_version(current)
    candidates.append(current)
    highest = max(candidates, key=build_version)
    parts = highest.split(".")
    parts[-1] = str(int(parts[-1]) + 1)
    number = ".".join(parts)
  high_water = max([*candidates, number], key=build_version)
  ledger[identity] = {"project": str(project), "scheme": scheme, "build": high_water}
  # Reserve before archiving so failed/retried builds also advance rather than reuse a number.
  write_json(ledger_path, ledger)
  return number


def build(args, state: Path, config: dict) -> dict:
  devices = configured_devices(args, config)
  min_validity = getattr(args, "min_validity_days", 30)
  team = getattr(args, "team", None) or config.get("team")
  preflight = None
  project_value = getattr(args, "project", None) or config.get("project")
  scheme = getattr(args, "scheme", None) or config.get("scheme")
  existing = getattr(args, "archive", None)
  if not existing and (not project_value or not scheme):
    raise PublishError("Provide --project and --scheme, or configure them with init.")
  run_dir = state / "runs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
  run_dir.mkdir(parents=True)
  archive = Path(existing).expanduser().resolve() if existing else run_dir / "App.xcarchive"
  record = {"status": "building", "run_path": str(run_dir), "archive_path": str(archive)}
  write_json(run_dir / "result.json", record)
  try:
    if existing:
      if not (archive / "Info.plist").is_file():
        raise PublishError(f"Not an Xcode archive: {archive}")
    else:
      project, flag = resolve_project(project_value)
      configuration = getattr(args, "configuration", None) or config.get("configuration", "Release")
      settings = project_settings(project, scheme, configuration, getattr(args, "build_setting", []))
      main = application_settings(settings, scheme)
      team = team or main.get("DEVELOPMENT_TEAM")
      if not team:
        raise PublishError("Cannot infer the developer team; pass --team or configure DEVELOPMENT_TEAM.")
      identifiers = [row["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] for row in settings
        if row.get("buildSettings", {}).get("WRAPPER_EXTENSION") in ("app", "appex")
        and row["buildSettings"].get("PRODUCT_BUNDLE_IDENTIFIER")]
      if main.get("PRODUCT_BUNDLE_IDENTIFIER") not in identifiers:
        identifiers.append(main.get("PRODUCT_BUNDLE_IDENTIFIER", ""))
      preflight = apple.signing_preflight(team, identifiers, min_validity)
      number = reserve_build_number(state, project, scheme, configuration, getattr(args, "build_number", None), settings)
      record.update({"project": str(project), "scheme": scheme, "requested_build": number})
      write_json(run_dir / "result.json", record)
      progress(f"Archiving build {number}")
      command = ["asc", "xcode", "archive", flag, str(project), "--scheme", scheme,
        "--configuration", configuration,
        "--archive-path", str(archive), "--xcodebuild-flag=-destination", "--xcodebuild-flag=generic/platform=iOS", "--output", "json"]
      command.append(f"--xcodebuild-flag=CURRENT_PROJECT_VERSION={number}")
      command.extend(f"--xcodebuild-flag={value}" for value in getattr(args, "build_setting", []) or [])
      run(command, log=run_dir / "archive.log", timeout=None)
    progress("Preparing ad hoc signing for the app and embedded extensions")
    signing = apple.prepare_signing(archive, devices, run_dir / "signing", team, min_validity, preflight)
    ipa = run_dir / "App.ipa"
    run(["asc", "xcode", "export", "--archive-path", str(archive), "--ipa-path", str(ipa),
      "--export-options", signing["export_options"], "--output", "json"], log=run_dir / "export.log", timeout=None)
    metadata = apple.inspect_ipa(ipa, [d["udid"] for d in devices])
    if record.get("requested_build") and metadata["build"] != record["requested_build"]:
      raise PublishError(f"Exported build {metadata['build']} differs from requested build {record['requested_build']}. Configure CFBundleVersion to use $(CURRENT_PROJECT_VERSION); the IPA was not published.")
    apple.verify_signatures(ipa)
    result = {**record, **metadata, "status": "built", "signing": signing,
      "signatures_verified": True, "published": False, "installed": False}
    write_json(run_dir / "result.json", result)
    write_json(state / "last-build.json", result)
    return result
  except BaseException as error:
    write_json(run_dir / "result.json", {**record, "status": "failed", "error": str(error) or type(error).__name__})
    raise


def parser() -> argparse.ArgumentParser:
  root = ArgumentParser(description="Build ad hoc signed iOS IPAs and install them over Tailscale.")
  root.add_argument("--state-dir", type=Path, help="Local state (default: IOS_PUBLISH_HOME, machine settings, or ~/.local/share/ios-publish)")
  root.add_argument("--json", action="store_true", help="Emit one JSON result on stdout; progress goes to stderr")
  commands = root.add_subparsers(dest="command", required=True)
  def json_flag(command):
    command.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
  init = commands.add_parser("init", help="Save project, scheme, and optional team defaults")
  init.add_argument("--project", required=True)
  init.add_argument("--scheme", required=True)
  init.add_argument("--team")
  init.add_argument("--configuration", default="Release")
  json_flag(init)
  doctor = commands.add_parser("doctor", help="Check tools, Apple credentials, signing identities, and Tailscale")
  json_flag(doctor)
  devices = commands.add_parser("devices", help="Discover physical devices and register/save targets")
  ds = devices.add_subparsers(dest="device_command", required=True)
  for verb in ("list", "register"):
    command = ds.add_parser(verb)
    command.add_argument("--wifi", action="store_true", help="Only paired physical devices with Wi-Fi transport (may be asleep)")
    command.add_argument("--connected", action="store_true", help="Only devices with a live CoreDevice tunnel")
    if verb == "register":
      command.add_argument("--udid", action="append", help="Explicit hardware UDID; repeat for multiple devices")
    json_flag(command)
  for verb in ("build", "publish"):
    command = commands.add_parser(verb, help="Archive/export a signed IPA" if verb == "build" else "Build and publish a verified OTA install link")
    command.add_argument("--project", help=".xcodeproj, .xcworkspace, or an unambiguous source directory")
    command.add_argument("--scheme")
    command.add_argument("--configuration")
    command.add_argument("--team")
    command.add_argument("--archive", help="Reuse an existing .xcarchive instead of building")
    command.add_argument("--build-number", help="Explicit build number (default: advance past project and local build history)")
    command.add_argument("--min-validity-days", type=nonnegative, default=30, help="Minimum remaining certificate/profile lifetime (default: 30 days)")
    command.add_argument("--build-setting", action="append", default=[], help="Pass one Xcode argument; repeat as needed")
    command.add_argument("--udid", action="append")
    command.add_argument("--wifi", action="store_true")
    command.add_argument("--connected", action="store_true")
    if verb == "publish":
      command.add_argument("--ipa", type=Path, help="Publish an existing ad hoc IPA instead of building")
    json_flag(command)
  inspect = commands.add_parser("inspect", help="Validate an ad hoc IPA and its device coverage/signatures")
  inspect.add_argument("ipa", type=Path)
  inspect.add_argument("--udid", action="append", default=[])
  json_flag(inspect)
  serve = commands.add_parser("serve", help="Manage only the /ios-publish Tailscale Serve route")
  serve.add_argument("action", choices=("start", "status", "stop"))
  json_flag(serve)
  latest = commands.add_parser("latest", help="Show the last published release")
  json_flag(latest)
  return root


def execute(args, state: Path):
  if args.command in ("build", "publish") or (args.command == "devices" and args.device_command == "register"):
    if args.connected and not args.wifi:
      raise PublishError("--connected requires --wifi for build/publish/device registration; use devices list --connected to inspect live devices.")
    if args.udid and args.wifi:
      raise PublishError("Choose explicit --udid targets or --wifi discovery, not both")
  if args.command in ("build", "publish"):
    if args.archive and (args.project or args.scheme or args.configuration or args.build_number or args.build_setting):
      raise PublishError("--archive cannot be combined with source build options; an archive retains its original build number")
  config = load_config(state)
  if args.command == "init":
    project, _ = resolve_project(args.project)
    config.update({"project": str(project), "scheme": args.scheme, "configuration": args.configuration})
    if args.team:
      config["team"] = args.team
    write_json(state / "config.json", config)
    return {"config_path": str(state / "config.json"), **config}
  if args.command == "doctor":
    checks = {"tools": {tool: shutil.which(tool) for tool in ("asc", "xcrun", "xcodebuild", "security", "codesign", "ditto", "tailscale")}}
    for key, action in (("xcode", lambda: run(["xcodebuild", "-version"]).decode().strip()),
      ("apple_auth", lambda: asc("auth", "status")),
      ("signing_identities", lambda: run(["security", "find-identity", "-v", "-p", "codesigning"]).decode().strip()),
      ("hosting", lambda: hosting.serve_status(state))):
      try:
        checks[key] = action()
      except PublishError as error:
        checks[key] = {"error": str(error)}
    if config.get("team"):
      try:
        checks["distribution_certificate"] = apple.signing_certificate(config["team"])
      except PublishError as error:
        checks["distribution_certificate"] = {"error": str(error)}
    host = checks.get("hosting", {})
    if host.get("owned") and (not host.get("active") or not host.get("program_paths_exist", False)):
      host["error"] = "Owned hosting is unhealthy; run serve start to repair its server/LaunchAgent"
    elif host.get("active"):
      try:
        hosting.verify_https(host["base_url"], str((state / "site").resolve()))
      except PublishError as error:
        host["error"] = str(error)
    checks["ok"] = all(checks["tools"].values()) and not any(isinstance(v, dict) and "error" in v for v in checks.values())
    return checks
  if args.command == "devices":
    if args.device_command == "list":
      devices = apple.discover_devices()
      if args.wifi or args.connected:
        devices = apple.select_devices(devices, wifi=args.wifi, connected=args.connected)
      return {"devices": devices, "saved_targets": config.get("devices", [])}
    if not args.udid and not args.wifi:
      raise PublishError("Choose devices explicitly with --wifi or repeat --udid.")
    devices = apple.register_devices(configured_devices(args, config))
    config["devices"] = devices
    write_json(state / "config.json", config)
    return {"devices": devices, "config_path": str(state / "config.json")}
  if args.command == "serve":
    return {"start": hosting.serve_start, "status": hosting.serve_status, "stop": hosting.serve_stop}[args.action](state)
  if args.command == "inspect":
    result = apple.inspect_ipa(args.ipa.resolve(), args.udid)
    apple.verify_signatures(args.ipa.resolve())
    return {**result, "signatures_verified": True}
  if args.command == "latest":
    path = state / "latest.json"
    if not path.exists():
      raise PublishError("No release published yet.")
    return json.loads(path.read_text())
  if args.command == "build":
    return build(args, state, config)
  if args.command == "publish":
    if args.ipa and (args.archive or args.project or args.scheme or args.configuration or args.build_number or args.build_setting):
      raise PublishError("--ipa cannot be combined with archive/build options.")
    configured_devices(args, config)  # Reject invalid selection before starting services.
    # Check loopback and real HTTPS reachability before spending time on a build.
    server = hosting.serve_start(state)
    if args.ipa:
      devices = configured_devices(args, config)
      metadata = apple.inspect_ipa(args.ipa.resolve(), [d["udid"] for d in devices])
      if datetime.fromisoformat(metadata["expires_at"]) <= datetime.now(timezone.utc) + timedelta(days=args.min_validity_days):
        raise PublishError(f"IPA signing expires within {args.min_validity_days} days; re-export or deliberately lower --min-validity-days.")
      apple.verify_signatures(args.ipa.resolve())
      metadata["signatures_verified"] = True
    else:
      metadata = build(args, state, config)
    progress("Publishing OTA manifest and verifying the hosted IPA checksum")
    return hosting.publish_ipa(state, metadata, server["base_url"])
  raise PublishError("Unknown command")


def main():
  json_output = "--json" in sys.argv[1:]
  try:
    args = parser().parse_args()
    json_output = args.json
    state = (args.state_dir or default_state()).expanduser().resolve()
    state.mkdir(parents=True, exist_ok=True)
    # One writer per state directory; parallel agent calls fail clearly instead of racing latest/config.
    with (state / ".lock").open("a") as lock:
      read_only = args.command in ("doctor", "inspect", "latest") or (args.command == "devices" and args.device_command == "list") or (args.command == "serve" and args.action == "status")
      if not read_only:
        try:
          fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
          raise PublishError(f"Another ios-publish command is changing {state}; wait for it to finish.") from None
      result = execute(args, state)
    if args.json:
      print(json.dumps({"ok": result.get("ok", True), **result}, ensure_ascii=False))
    elif result.get("install_page_url"):
      print(f"{result['name']} {result['version']} ({result['build']})\nInstall: {result['install_page_url']}\nLatest:  {result['latest_url']}\nIPA:     {result['ipa_path']}")
    else:
      print(json.dumps(result, indent=2, ensure_ascii=False))
    if result.get("ok") is False:
      sys.exit(1)
  except (PublishError, OSError, ValueError, KeyError, HTTPException, zipfile.BadZipFile) as error:
    if json_output:
      print(json.dumps({"ok": False, "error": str(error)}))
    else:
      progress(f"Error: {error}")
    sys.exit(1)
  except KeyboardInterrupt:
    message = "Interrupted; existing build logs and artifacts retained."
    if json_output:
      print(json.dumps({"ok": False, "error": message}))
    else:
      progress(message)
    sys.exit(130)


if __name__ == "__main__":
  main()
