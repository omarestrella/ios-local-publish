from __future__ import annotations

import hashlib
import html
from http.client import HTTPException
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import sys
import tempfile
import time
from urllib.parse import quote, urlencode, urlparse
from urllib.request import urlopen
import uuid

from .common import PublishError, atomic_write, run, run_json, write_json


MOUNT = "/ios-publish"


def server_label(state: Path) -> str:
  return "net.bitcreative.ios-publish." + hashlib.sha256(str(state.resolve()).encode()).hexdigest()[:12]


def server_health(port: int, site: str) -> bool:
  try:
    with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=2) as response:
      return json.load(response) == health_identity(site)
  except (OSError, ValueError, HTTPException):
    return False


def health_identity(site: str) -> dict:
  return {"service": "ios-publish", "site_id": hashlib.sha256(site.encode()).hexdigest()}


def verify_https(base_url: str, site: str):
  error = None
  for attempt in range(3):
    try:
      with urlopen(base_url + "/healthz", timeout=20) as response:
        if json.load(response) != health_identity(site):
          raise PublishError("HTTPS route points to a different local publisher")
      return
    except (OSError, ValueError, HTTPException) as failure:
      error = failure
      if attempt < 2:
        time.sleep(attempt + 1)
  raise PublishError(f"Cannot reach this publisher over HTTPS at {base_url}: {error}. Check Tailscale DNS, TLS trust, and Serve access before building.")


def program_paths_exist(server: dict | None) -> bool:
  if not server:
    return False
  try:
    agent = plistlib.loads(Path(server["launch_agent"]).read_bytes())
    programs = agent.get("ProgramArguments", [])
    return (agent.get("Label") == server["label"] and len(programs) >= 2
      and os.access(programs[0], os.X_OK) and Path(programs[1]).is_file())
  except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
    return False


def server_interpreter() -> str:
  # Keep Homebrew's stable symlink rather than recording its versioned Cellar path.
  for candidate in dict.fromkeys(["/opt/homebrew/bin/python3", "/usr/local/bin/python3", shutil.which("python3"), sys.executable]):
    if not candidate or not os.access(candidate, os.X_OK):
      continue
    try:
      run([candidate, "-c", "import sys; sys.exit(sys.version_info < (3, 11))"])
      return candidate
    except PublishError:
      continue
  raise PublishError("No Python 3.11+ interpreter is available for the hosting LaunchAgent")


def local_server(state: Path) -> dict:
  site = str((state / "site").resolve())
  metadata_path = state / "server.json"
  metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
  runtime = state / "server-runtime/server.py"
  source = Path(__file__).with_name("server.py").read_bytes()
  runtime_current = runtime.is_file() and runtime.read_bytes() == source
  if metadata and server_health(metadata["port"], site) and program_paths_exist(metadata) and runtime_current:
    return metadata
  # Let the OS choose an unused loopback port. Persist it for later idempotent calls.
  with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
  label = server_label(state)
  domain = f"gui/{os.getuid()}"
  agent = Path.home() / "Library/LaunchAgents" / f"{label}.plist"
  agent.parent.mkdir(parents=True, exist_ok=True)
  # Also unload a stale job whose plist has been removed. Only our derived label.
  try:
    run(["launchctl", "bootout", f"{domain}/{label}"])
  except PublishError:
    pass
  logs = state / "server-logs"
  logs.mkdir(parents=True, exist_ok=True)
  atomic_write(runtime, source)
  document = {"Label": label, "ProgramArguments": [server_interpreter(), str(runtime),
    "--directory", site, "--port", str(port)], "RunAtLoad": True, "KeepAlive": True,
    "StandardOutPath": str(logs / "stdout.log"), "StandardErrorPath": str(logs / "stderr.log")}
  atomic_write(agent, plistlib.dumps(document))
  for attempt in range(3):
    try:
      run(["launchctl", "bootstrap", domain, str(agent)])
      break
    except PublishError:
      if attempt == 2:
        raise
      time.sleep(.5 * (attempt + 1))
  deadline = time.monotonic() + 10
  while time.monotonic() < deadline:
    if server_health(port, site):
      metadata = {"port": port, "label": label, "launch_agent": str(agent), "site": site}
      write_json(metadata_path, metadata)
      return metadata
    time.sleep(.2)
  raise PublishError(f"Local file server did not start; see {logs / 'stderr.log'}")


def tailscale_host() -> str:
  status = run_json(["tailscale", "status", "--json"])
  if status.get("BackendState") != "Running":
    raise PublishError("Tailscale is not connected. Connect Tailscale on this Mac first.")
  host = status.get("Self", {}).get("DNSName", "").rstrip(".")
  if not host:
    raise PublishError("Tailscale has not assigned this Mac a DNS name.")
  return host


def existing_handler(status: dict, host: str) -> dict | None:
  handlers = status.get("Web", {}).get(f"{host}:443", {}).get("Handlers", {})
  return handlers.get(MOUNT) or handlers.get(MOUNT + "/")


def serve_status(state: Path) -> dict:
  host = tailscale_host()
  status = run_json(["tailscale", "serve", "status", "--json"])
  handler = existing_handler(status, host)
  expected = str((state / "site").resolve())
  metadata_path = state / "server.json"
  server = json.loads(metadata_path.read_text()) if metadata_path.exists() else None
  proxy = f"http://127.0.0.1:{server['port']}" if server else None
  owned = bool(handler and (handler.get("Path") == expected or (proxy and handler.get("Proxy") == proxy)))
  ready = bool(server and server_health(server["port"], expected))
  return {"base_url": f"https://{host}{MOUNT}", "active": bool(owned and ready and handler.get("Proxy")),
    "owned": owned, "handler": handler, "server": server, "server_ready": ready,
    "program_paths_exist": program_paths_exist(server),
    "site_path": expected, "requires": "Mac awake and Tailscale connected on both Mac and device"}


def serve_start(state: Path) -> dict:
  site = (state / "site").resolve()
  site.mkdir(parents=True, exist_ok=True)
  status = serve_status(state)
  if status["handler"] and not status["owned"]:
    raise PublishError(f"Tailscale route {MOUNT} is already owned by another service: {status['handler']}")
  server = local_server(state)
  proxy = f"http://127.0.0.1:{server['port']}"
  if not status["active"] or status["handler"].get("Proxy") != proxy:
    # Add just this mount; never reset or replace other Tailscale Serve routes.
    run(["tailscale", "serve", "--bg", "--yes", "--https=443", f"--set-path={MOUNT}", f"http://127.0.0.1:{server['port']}"], timeout=45)
  status = serve_status(state)
  if not status["active"]:
    raise PublishError("Tailscale did not activate the loopback file-server route.")
  verify_https(status["base_url"], str(site))
  return status


def serve_stop(state: Path) -> dict:
  status = serve_status(state)
  if status["handler"] and not status["owned"]:
    raise PublishError("Refusing to remove a Tailscale route owned by another service.")
  if status["owned"]:
    run(["tailscale", "serve", "--https=443", f"--set-path={MOUNT}", "off"])
  if status["server"]:
    label = status["server"]["label"]
    if label != server_label(state):
      raise PublishError("Local server label does not match this state directory")
    try:
      run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"])
    except PublishError:
      # A stopped or unloaded job needs no further process action.
      pass
    Path(status["server"]["launch_agent"]).unlink(missing_ok=True)
  return serve_status(state)


def validate_base_url(url: str) -> str:
  parts = urlparse(url)
  if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
    raise PublishError("Install base URL must be an HTTPS URL without credentials, query, or fragment.")
  return url.rstrip("/")


def manifest(metadata: dict, ipa_url: str) -> bytes:
  return plistlib.dumps({"items": [{"assets": [{"kind": "software-package", "url": ipa_url}],
    "metadata": {"bundle-identifier": metadata["bundle_id"], "bundle-version": metadata["build"],
      "kind": "software", "title": metadata["name"]}}]})


def page(metadata: dict, install_url: str) -> bytes:
  e = html.escape
  title = e(str(metadata["name"]))
  details = e(f"{metadata['version']} · Build {metadata['build']}")
  expiry = e(metadata["expires_at"].split("T")[0])
  size = metadata["size_bytes"] / (1024 * 1024)
  return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark"><title>Install {title}</title>
<style>
:root{{font:17px/1.5 system-ui,-apple-system,sans-serif;color-scheme:light dark;background:light-dark(#f6f6f3,#161715);color:light-dark(#242621,#e7e8e3)}}
body{{max-width:30rem;margin:12vh auto;padding:1.5rem}}h1{{font-size:2rem;line-height:1.2;letter-spacing:-.04em;margin:0 0 .5rem}}
.muted{{opacity:.65}}.install{{display:block;text-align:center;background:light-dark(#38593c,#b4d0aa);color:light-dark(white,#142010);padding:1rem;border-radius:14px;text-decoration:none;font-weight:600;margin:2rem 0}}
ol{{padding-left:1.3rem}}li{{padding:.3rem 0}}footer{{margin-top:2rem;font-size:.8rem;overflow-wrap:anywhere}}
</style><body><p class="muted">ios-publish</p><h1>{title}</h1><p class="muted">{details} · {size:.1f} MB</p>
<a class="install" href="{e(install_url, quote=True)}">Install {title}</a>
<ol><li>Open this page in Safari with Tailscale connected.</li><li>Tap Install and approve the iOS prompt.</li><li>Wait for the app to finish installing on your Home Screen.</li></ol>
<p class="muted">For registered devices only. Developer Mode must be enabled. Keep this Mac awake while installing. To update, install over the existing app to retain its data.</p>
<footer class="muted">Signed through {expiry}<br>{e(metadata['bundle_id'])}<br>SHA-256 {e(metadata['sha256'])}</footer></body></html>
""".encode()


def verify_hosted(release: dict) -> dict:
  try:
    with urlopen(release["manifest_url"], timeout=30) as response:
      document = plistlib.loads(response.read())
    asset_url = document["items"][0]["assets"][0]["url"]
    if asset_url != release["ipa_url"]:
      raise PublishError("Hosted manifest points to the wrong IPA")
    digest = hashlib.sha256()
    size = 0
    with urlopen(asset_url, timeout=60) as response:
      for chunk in iter(lambda: response.read(1024 * 1024), b""):
        digest.update(chunk)
        size += len(chunk)
    if digest.hexdigest() != release["sha256"] or size != release["size_bytes"]:
      raise PublishError("Hosted IPA checksum/size does not match the signed local artifact")
    with urlopen(release["install_page_url"], timeout=30) as response:
      if release["install_url"].encode() not in html.unescape(response.read().decode()).encode():
        raise PublishError("Hosted install page does not contain the expected install link")
  except (OSError, KeyError, ValueError, IndexError, HTTPException, plistlib.InvalidFileException) as error:
    raise PublishError(f"Cannot verify hosted install files: {error}") from error
  return {"manifest": True, "ipa_sha256": True, "install_page": True, "checked_from": "build Mac"}


def publish_ipa(state: Path, metadata: dict, base_url: str) -> dict:
  base_url = validate_base_url(base_url)
  bundle = metadata["bundle_id"]
  if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", bundle):
    raise PublishError("Unsupported bundle identifier for publishing path")
  release_id = uuid.uuid4().hex
  relative = f"apps/{bundle}/{release_id}"
  release_url = f"{base_url}/{quote(relative, safe='/')}"
  manifest_url = release_url + "/manifest.plist"
  install_url = "itms-services://?" + urlencode({"action": "download-manifest", "url": manifest_url}, quote_via=quote)
  result = {**metadata, "release_id": release_id, "install_page_url": release_url + "/index.html",
    "latest_url": f"{base_url}/apps/{quote(bundle)}/index.html", "manifest_url": manifest_url,
    "ipa_url": release_url + "/app.ipa", "install_url": install_url,
    "published": False, "installed": False}
  site = state / "site"
  app_dir = site / "apps" / bundle
  app_dir.mkdir(parents=True, exist_ok=True)
  destination = app_dir / release_id
  # Prepare a complete release privately, then atomically expose it.
  with tempfile.TemporaryDirectory(dir=state, prefix="publish-") as temp:
    staging = Path(temp) / release_id
    staging.mkdir()
    shutil.copy2(metadata["ipa_path"], staging / "app.ipa")
    (staging / "manifest.plist").write_bytes(manifest(metadata, result["ipa_url"]))
    (staging / "index.html").write_bytes(page(metadata, install_url))
    staging.rename(destination)
  try:
    result["hosting_verified"] = verify_hosted(result)
  except BaseException:
    shutil.rmtree(destination)
    raise
  result["published"] = True
  # Promote latest only after the immutable release downloads correctly.
  atomic_write(app_dir / "index.html", page(metadata, install_url))
  write_json(state / "releases" / f"{release_id}.json", result)
  write_json(state / "latest.json", result)
  entries = []
  for path in sorted((site / "apps").glob("*/index.html")):
    app_id = path.parent.name
    entries.append(f'<li><a href="{html.escape(base_url, quote=True)}/apps/{quote(app_id)}/index.html">{html.escape(app_id)}</a></li>')
  atomic_write(site / "index.html", ('<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>iOS builds</title><body style="font:18px system-ui;max-width:40rem;margin:10vh auto;padding:1rem">'
    '<h1>iOS builds</h1><ul>' + "".join(entries) + '</ul></body>').encode())
  return result
