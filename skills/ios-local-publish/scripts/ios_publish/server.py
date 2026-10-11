"""Loopback-only OTA file server, supervised by the user's launchd agent."""
import argparse
import hashlib
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import unquote, urlparse


class Handler(SimpleHTTPRequestHandler):
  extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".ipa": "application/octet-stream", ".plist": "text/xml"}

  def do_GET(self):
    if urlparse(self.path).path == "/healthz":
      identity = hashlib.sha256(str(Path(self.directory).resolve()).encode()).hexdigest()
      body = json.dumps({"service": "ios-publish", "site_id": identity}).encode()
      self.send_response(200)
      self.send_header("Content-Type", "application/json")
      self.send_header("Content-Length", str(len(body)))
      self.end_headers()
      self.wfile.write(body)
      return
    super().do_GET()

  def send_head(self):
    # Serve only files within the publish root; no symlink escapes or hidden files.
    path = Path(self.translate_path(self.path)).resolve()
    root = Path(self.directory).resolve()
    if not path.is_relative_to(root) or any(part.startswith(".") for part in Path(unquote(urlparse(self.path).path)).parts if part not in ("/",)):
      self.send_error(404)
      return None
    if path.is_dir():
      for name in ("index.html", "index.htm"):
        index = path / name
        if index.exists() and not index.resolve().is_relative_to(root):
          self.send_error(404)
          return None
    return super().send_head()

  def list_directory(self, path):
    self.send_error(404, "Directory listing is disabled")
    return None

  def end_headers(self):
    if not urlparse(self.path).path.endswith(".ipa"):
      self.send_header("Cache-Control", "no-store")
    self.send_header("X-Content-Type-Options", "nosniff")
    super().end_headers()


class LocalHTTPServer(ThreadingHTTPServer):
  def server_bind(self):
    # This is a known loopback address; HTTPServer's reverse-DNS lookup can stall startup.
    TCPServer.server_bind(self)
    self.server_name = "localhost"
    self.server_port = self.server_address[1]


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--directory", required=True)
  parser.add_argument("--port", type=int, required=True)
  args = parser.parse_args()
  server = LocalHTTPServer(("127.0.0.1", args.port), partial(Handler, directory=args.directory))
  server.serve_forever()


if __name__ == "__main__":
  main()
