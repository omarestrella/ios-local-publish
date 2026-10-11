from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import stat
import tempfile
import zipfile

from .common import PublishError, asc, progress, run, run_json


def now() -> datetime:
  return datetime.now(timezone.utc)


def utc(value: datetime) -> datetime:
  return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def normalize_devices(document: dict) -> list[dict]:
  devices = []
  for item in document.get("result", {}).get("devices", []):
    properties = item.get("properties", {})
    hardware = properties.get("hardware", item.get("hardwareProperties", {}))
    connection = properties.get("connection", item.get("connectionProperties", {}))
    state = properties.get("state", item.get("deviceProperties", {}))
    # CoreDevice also returns simulators; its identifier is NOT the provisioning UDID.
    if hardware.get("reality") != "physical" or hardware.get("deviceType") not in ("iPhone", "iPad"):
      continue
    software = properties.get("software", {}).get("osVersionNumber", {})
    devices.append({
      "name": state.get("name", "Unknown device"),
      "udid": hardware.get("udid"),
      "core_device_id": item.get("identifier"),
      "model": hardware.get("marketingName", hardware.get("productType")),
      "type": hardware.get("deviceType"),
      "transport": connection.get("transportType"),
      "connection": connection.get("state", connection.get("tunnelState", "unknown")),
      "pairing": connection.get("pairingState"),
      "os_version": software.get("stringValue", item.get("deviceProperties", {}).get("osVersionNumber")),
    })
  return sorted(devices, key=lambda d: (d["type"], d["name"]))


def discover_devices() -> list[dict]:
  # Raw CoreDevice exposes transport, physical/simulated reality, and the hardware UDID.
  # Higher-level device listings can conflate those fields.
  with tempfile.TemporaryDirectory(prefix="ios-publish-devices-") as temp:
    path = Path(temp) / "devices.json"
    run(["xcrun", "devicectl", "list", "devices", "--json-output", str(path)], timeout=30)
    import json
    return normalize_devices(json.loads(path.read_text()))


def select_devices(devices: list[dict], *, wifi: bool = False, connected: bool = False) -> list[dict]:
  selected = [d for d in devices if d.get("udid") and d.get("pairing") == "paired"]
  if wifi:
    selected = [d for d in selected if d.get("transport") == "localNetwork"]
  if connected:
    selected = [d for d in selected if d.get("connection") == "connected"]
  if not selected:
    raise PublishError("No matching physical iPhone/iPad devices found. Wake/unlock your paired devices or supply --udid.")
  return selected


def validate_devices(devices: list[dict]) -> list[dict]:
  if not devices:
    raise PublishError("Select at least one physical device")
  selected = {}
  for device in devices:
    udid = device.get("udid", "")
    if not isinstance(udid, str) or not re.fullmatch(r"(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{16}|[0-9a-fA-F]{40})", udid):
      raise PublishError(f"Invalid hardware UDID: {udid}. Use the provisioning UDID, not a CoreDevice UUID or simulator identifier.")
    selected[udid.upper()] = {**device, "udid": udid.upper()}
  return list(selected.values())


def register_devices(devices: list[dict]) -> list[dict]:
  devices = validate_devices(devices)
  rows = asc("devices", "list", "--paginate")["data"]
  by_udid = {r["attributes"]["udid"].upper(): r for r in rows}
  # Check the complete selection before consuming any new device slots.
  for device in devices:
    row = by_udid.get(device["udid"])
    if row and row["attributes"].get("status") != "ENABLED":
      raise PublishError(f"Device {device['name']} ({device['udid']}) is disabled in Apple Developer; enable it before publishing.")
  registered = []
  for device in devices:
    udid = device["udid"]
    row = by_udid.get(udid.upper())
    if row and row["attributes"].get("status") != "ENABLED":
      raise PublishError(f"Device {device['name']} ({udid}) is disabled in Apple Developer; enable it before publishing.")
    if not row:
      progress(f"Registering {device['name']} ({udid}) with Apple Developer")
      row = asc("devices", "register", "--name", device["name"], "--udid", udid, "--platform", "IOS")["data"]
    registered.append({**device, "apple_device_id": row["id"]})
  return registered


def decode_profile(data: bytes) -> dict:
  with tempfile.TemporaryDirectory(prefix="ios-publish-profile-") as temp:
    path = Path(temp) / "profile.mobileprovision"
    path.write_bytes(data)
    return plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))


def profile_matches(profile: dict, bundle: str, team: str, udids: list[str], certificate: str, min_validity_days: int = 30) -> bool:
  entitlements = profile.get("Entitlements", {})
  app_id = entitlements.get("application-identifier", "")
  # Match the suffix rather than assuming the legacy App ID prefix equals the team ID.
  profile_bundle = app_id.partition(".")[2]
  hashes = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
  return (
    profile_bundle == bundle
    and team in profile.get("TeamIdentifier", [])
    and not entitlements.get("get-task-allow", False)
    and not profile.get("ProvisionsAllDevices", False)
    and set(u.upper() for u in udids) <= set(u.upper() for u in profile.get("ProvisionedDevices", []))
    and bool(profile.get("ProvisionedDevices"))
    and utc(profile.get("ExpirationDate", datetime.min)) > now() + timedelta(days=min_validity_days)
    and certificate.upper() in hashes
  )


def signing_certificate(team: str, min_validity_days: int = 30) -> dict:
  identities = run(["security", "find-identity", "-v", "-p", "codesigning"]).decode()
  valid = set()
  for line in identities.splitlines():
    match = re.search(r'\b([0-9A-F]{40})\s+"([^"]+)"', line)
    if match and f"({team})" in match[2] and "REVOKED" not in line:
      valid.add(match[1])
  candidates = []
  for row in asc("certificates", "list", "--paginate")["data"]:
    attrs = row["attributes"]
    if attrs.get("certificateType") not in ("IOS_DISTRIBUTION", "DISTRIBUTION"):
      continue
    content = base64.b64decode(attrs["certificateContent"])
    fingerprint = hashlib.sha1(content).hexdigest().upper()
    expiry = datetime.fromisoformat(attrs["expirationDate"].replace("Z", "+00:00"))
    if fingerprint in valid and expiry > now() + timedelta(days=min_validity_days):
      candidates.append({"id": row["id"], "sha1": fingerprint, "expires_at": expiry.isoformat(), "name": attrs["name"]})
  if not candidates:
    raise PublishError(f"No distribution certificate with a local private key for team {team} valid for more than {min_validity_days} days. Check that asc is authenticated to this team, that its certificate/private key is in Keychain, and its expiry. --team does not switch asc accounts; use --min-validity-days only for an intentional shorter lifetime.")
  return max(candidates, key=lambda c: c["expires_at"])


def archive_bundles(archive: Path) -> list[dict]:
  applications = archive / "Products" / "Applications"
  main_apps = list(applications.glob("*.app"))
  if len(main_apps) != 1:
    raise PublishError(f"Expected one top-level app in {applications}; found {len(main_apps)}")
  app = main_apps[0]
  paths = [app, *sorted(app.rglob("*.appex")), *sorted(app.rglob("*.app"))]
  bundles = []
  for path in paths:
    info = plistlib.loads((path / "Info.plist").read_bytes())
    bundles.append({"path": str(path), "bundle_id": info["CFBundleIdentifier"], "info": info})
  return bundles


def signing_preflight(team: str, identifiers: list[str], min_validity_days: int = 30) -> dict:
  certificate = signing_certificate(team, min_validity_days)
  bundle_ids = {r["attributes"]["identifier"]: r for r in asc("bundle-ids", "list", "--paginate")["data"]}
  require_bundle_ids(identifiers, bundle_ids)
  profile_rows = asc("profiles", "list", "--profile-type", "IOS_APP_ADHOC", "--paginate")["data"]
  profiles = [(row, decode_profile(base64.b64decode(row["attributes"]["profileContent"])))
    for row in profile_rows if row["attributes"].get("profileState") == "ACTIVE"]
  return {"team": team, "certificate": certificate, "bundle_ids": bundle_ids, "profiles": profiles}


def require_bundle_ids(identifiers: list[str], bundle_ids: dict):
  missing = sorted(set(identifiers) - bundle_ids.keys())
  if missing:
    raise PublishError(f"Bundle IDs not registered with the authenticated asc account: {', '.join(missing)}. Check asc's account/team before registering IDs and capabilities; --team does not switch accounts.")


def prepare_signing(archive: Path, devices: list[dict], directory: Path, team: str | None = None,
    min_validity_days: int = 30, preflight: dict | None = None) -> dict:
  archive_info = plistlib.loads((archive / "Info.plist").read_bytes())
  team = team or archive_info.get("ApplicationProperties", {}).get("Team")
  if not team:
    raise PublishError("Cannot infer signing team from archive; pass --team.")
  bundles = archive_bundles(archive)
  devices = validate_devices(devices)
  preflight = preflight or signing_preflight(team, [b["bundle_id"] for b in bundles], min_validity_days)
  if preflight["team"] != team:
    raise PublishError("Signing preflight team differs from archive/export team")
  certificate, bundle_ids, profiles = preflight["certificate"], preflight["bundle_ids"], preflight["profiles"]
  require_bundle_ids([b["bundle_id"] for b in bundles], bundle_ids)
  devices = register_devices(devices)
  mapping = {}
  profile_details = []
  udids = [d["udid"] for d in devices]
  directory.mkdir(parents=True, exist_ok=True)
  for bundle in bundles:
    identifier = bundle["bundle_id"]
    candidates = [(r, p) for r, p in profiles if profile_matches(p, identifier, team, udids, certificate["sha1"], min_validity_days)]
    if candidates:
      row, profile = max(candidates, key=lambda rp: utc(rp[1]["ExpirationDate"]))
    else:
      resource = bundle_ids.get(identifier)
      if not resource:
        raise PublishError(f"Bundle ID {identifier} is not registered with the authenticated Apple team. Register it and its capabilities first.")
      progress(f"Creating ad hoc provisioning profile for {identifier}")
      row = asc("profiles", "create", "--name", f"ios-publish {identifier} {now():%Y%m%d-%H%M%S}",
        "--profile-type", "IOS_APP_ADHOC", "--bundle", resource["id"],
        "--certificate", certificate["id"], "--device", ",".join(d["apple_device_id"] for d in devices))["data"]
      profile = decode_profile(base64.b64decode(row["attributes"]["profileContent"]))
      if not profile_matches(profile, identifier, team, udids, certificate["sha1"], min_validity_days):
        raise PublishError(f"Created profile does not cover the requested devices and certificate: {identifier}")
    path = directory / f"{profile['UUID']}.mobileprovision"
    path.write_bytes(base64.b64decode(row["attributes"]["profileContent"]))
    install = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles" / path.name
    install.parent.mkdir(parents=True, exist_ok=True)
    # UUID-addressed profiles are immutable; no other developer profile is replaced.
    if not install.exists():
      install.write_bytes(path.read_bytes())
    mapping[identifier] = profile["UUID"]
    profile_details.append({"bundle_id": identifier, "uuid": profile["UUID"], "expires_at": utc(profile["ExpirationDate"]).isoformat()})
  options = {
    "method": "release-testing", "destination": "export", "signingStyle": "manual",
    "teamID": team, "signingCertificate": certificate["sha1"], "provisioningProfiles": mapping,
    "thinning": "<none>", "manageAppVersionAndBuildNumber": False,
    "stripSwiftSymbols": True,
  }
  options_path = directory / "ExportOptions.plist"
  options_path.write_bytes(plistlib.dumps(options))
  return {"team": team, "devices": devices, "certificate": certificate, "profiles": profile_details, "export_options": str(options_path)}


def inspect_ipa(path: Path, required_udids: list[str] | None = None) -> dict:
  required = {u.upper() for u in required_udids or []}
  profiles = []
  infos = []
  with zipfile.ZipFile(path) as ipa:
    for name in ipa.namelist():
      p = PurePosixPath(name)
      if p.is_absolute() or ".." in p.parts:
        raise PublishError(f"Unsafe path in IPA: {name}")
      entry = ipa.getinfo(name)
      if stat.S_ISLNK(entry.external_attr >> 16):
        target = ipa.read(name).decode()
        resolved = posixpath.normpath(str(p.parent / target))
        if target.startswith("/") or resolved == ".." or resolved.startswith("../"):
          raise PublishError(f"Unsafe symlink in IPA: {name}")
    main = [n for n in ipa.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
    if len(main) != 1:
      raise PublishError("IPA must contain one top-level Payload/*.app/Info.plist")
    root = main[0].removesuffix("Info.plist")
    bundle_plists = [main[0], *sorted(n for n in ipa.namelist() if n != main[0] and n.startswith(root)
      and n.endswith("/Info.plist") and PurePosixPath(n).parent.suffix in (".app", ".appex"))]
    for name in bundle_plists:
      info = plistlib.loads(ipa.read(name))
      profile_path = name.removesuffix("Info.plist") + "embedded.mobileprovision"
      if profile_path not in ipa.namelist():
        raise PublishError(f"Missing embedded provisioning profile for {info['CFBundleIdentifier']}")
      profile = decode_profile(ipa.read(profile_path))
      entitlements = profile.get("Entitlements", {})
      permitted = {u.upper() for u in profile.get("ProvisionedDevices", [])}
      if entitlements.get("get-task-allow") or profile.get("ProvisionsAllDevices") or not permitted:
        raise PublishError(f"{info['CFBundleIdentifier']} is not signed for ad hoc distribution")
      if required - permitted:
        raise PublishError(f"{info['CFBundleIdentifier']} profile excludes devices: {', '.join(sorted(required - permitted))}")
      if utc(profile["ExpirationDate"]) <= now():
        raise PublishError(f"Expired provisioning profile for {info['CFBundleIdentifier']}")
      if entitlements.get("application-identifier", "").partition(".")[2] != info["CFBundleIdentifier"]:
        raise PublishError(f"Provisioning profile bundle ID mismatch: {info['CFBundleIdentifier']}")
      profiles.append({"bundle_id": info["CFBundleIdentifier"], "uuid": profile["UUID"],
        "team": profile["TeamIdentifier"][0], "expires_at": utc(profile["ExpirationDate"]).isoformat(),
        "devices": sorted(permitted)})
      infos.append(info)
  teams = {p["team"] for p in profiles}
  if len(teams) != 1:
    raise PublishError("IPA bundles are signed by different teams")
  info = infos[0]
  with path.open("rb") as stream:
    checksum = hashlib.file_digest(stream, "sha256").hexdigest()
  common_devices = set.intersection(*(set(p["devices"]) for p in profiles))
  return {"ipa_path": str(path.resolve()), "bundle_id": info["CFBundleIdentifier"],
    "name": info.get("CFBundleDisplayName", info.get("CFBundleName", info["CFBundleIdentifier"])),
    "version": str(info["CFBundleShortVersionString"]), "build": str(info["CFBundleVersion"]),
    "minimum_os": info.get("MinimumOSVersion"), "team": next(iter(teams)),
    "expires_at": min(p["expires_at"] for p in profiles), "devices": sorted(common_devices),
    "profiles": profiles, "sha256": checksum, "size_bytes": path.stat().st_size}


def verify_signatures(path: Path):
  # inspect_ipa validates archive paths before extraction. ditto preserves symlinks.
  with tempfile.TemporaryDirectory(prefix="ios-publish-signature-") as temp:
    run(["ditto", "-x", "-k", str(path), temp], timeout=120)
    apps = list((Path(temp) / "Payload").glob("*.app"))
    if len(apps) != 1:
      raise PublishError("Cannot locate extracted app for code-signature verification")
    run(["codesign", "--verify", "--deep", "--strict", str(apps[0])], timeout=120)
    for index, bundle in enumerate([apps[0], *sorted(apps[0].rglob("*.appex")), *sorted(apps[0].rglob("*.app"))]):
      profile = decode_profile((bundle / "embedded.mobileprovision").read_bytes())
      entitlements = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(bundle)]))
      if (entitlements.get("application-identifier") != profile["Entitlements"].get("application-identifier")
        or entitlements.get("com.apple.developer.team-identifier") not in profile["TeamIdentifier"]
        or entitlements.get("get-task-allow", False)):
        raise PublishError(f"Signed entitlements do not match the ad hoc profile: {bundle.name}")
      prefix = str(Path(temp) / f"certificate-{index}-")
      run(["codesign", "-d", f"--extract-certificates={prefix}", str(bundle)])
      certificate = Path(prefix + "0")
      allowed = {hashlib.sha1(cert).digest() for cert in profile["DeveloperCertificates"]}
      if not certificate.exists() or hashlib.sha1(certificate.read_bytes()).digest() not in allowed:
        raise PublishError(f"Signing certificate does not match the embedded profile: {bundle.name}")
