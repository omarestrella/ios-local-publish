# Publish client API

HTTP API exposed by the Publish Mac service.

## Base URL and discovery

The Mac CLI's `ios-publish service status --json` returns `base_url`, for example `https://your-mac.your-tailnet.ts.net:8443/ios-publish`. All endpoint paths are appended to this base URL, including its port and path prefix.

The service uses trusted HTTPS over Tailscale. Same Wi-Fi is not required. The Mac must be awake and reachable when refreshing or installing.

The service advertises `_ios-publish._tcp` in `local.`. The service's TXT record `url` contains the complete HTTPS base URL. The Bonjour hostname is separate from this HTTPS URL. Bonjour discovery is local to the network; remote Tailscale connections use the HTTPS URL directly.

`GET {base_url}/healthz` has no authentication and returns:

```json
{"service":"ios-publish","site_id":"opaque-server-identifier"}
```

`site_id` identifies server state, not a device credential or protocol version. There is currently no negotiated API version.

## Identity and authentication

A receiver identity consists of:

- `id`: accepted pattern `^[A-Za-z0-9-]{16,64}$`.
- `token`: accepted pattern `^[A-Za-z0-9_-]{32,128}$`.

The native client persists its ID and token in device-local Keychain storage. Its ID is a UUID and its token is two concatenated UUIDs without hyphens. The server stores the token hash. An existing ID requires its original token. The token is chosen by the client, not issued by the server.

All `/api/*` endpoints use POST with a JSON object and these headers:

```http
Authorization: Bearer YOUR_TOKEN
Content-Type: application/json
```

Every request includes `id` in its body. These endpoints use receiver credentials, not cookies or the separate Mac admin token.

## Endpoint reference

Paths below are relative to `base_url`. All successful POSTs return HTTP 200 and JSON.

| Method/path | Request body | Response |
| --- | --- | --- |
| `POST /api/connect` | `{id, name, platform}` | `{receiver_id, lease_seconds}` |
| `POST /api/heartbeat` | `{id, active?: boolean}` | `{releases: Build[], apps: App[], lease_seconds}` |
| `POST /api/apps/save` | `{id, bundle_id, name}` | `App` |
| `POST /api/builds/delete` | `{id, release_id}` | `{deleted: true}` |
| `POST /api/apps/delete` | `{id, bundle_id}` | `{deleted: true}` |

### Register/reconnect

```json
{"id":"12345678-1234-4234-8234-123456789abc","name":"My iPhone","platform":"iPhone"}
```

`platform` must be `iPhone` or `iPad`; name is nonempty and at most 100 characters. First connection registers the ID/token. Later connections authenticate the same credentials and update the display name/platform. Response:

```json
{"receiver_id":"12345678-1234-4234-8234-123456789abc","lease_seconds":30}
```

After initial registration, an operator binds the receiver to its physical provisioning UDID on the Mac:

```sh
ios-publish receivers list --json
ios-publish receivers bind --receiver RECEIVER_ID --udid HARDWARE_UDID --json
```

The iOS app cannot obtain that UDID itself. Publishing to a receiver requires its identity to be bound to a provisioning UDID. Builds are scoped to receiver identity; a new client identity does not automatically inherit the old client's inbox.

### Refresh builds and catalog

```json
{"id":"12345678-1234-4234-8234-123456789abc","active":true}
```

`/api/heartbeat` returns the inbox snapshot. `active` defaults to true. It updates informational presence and returns the complete current snapshot, not a delta. The native client refreshes on foreground, pull-to-refresh, and after mutations, and polls every five seconds while open.

`lease_seconds: 30` only controls the Mac's connected indicator. It does not expire credentials, stored builds, or permission to publish. Publication accepts offline receivers. An `active:false` call marks the receiver inactive; absence of that call does not affect publication.

```ts
interface App {
  bundle_id: string;
  name: string;
}

interface Build {
  release_id: string;       // Stable row identity; opaque string.
  name: string;             // Name from the IPA; catalog name may override display.
  bundle_id: string;
  version: string;          // Marketing version.
  build: string;            // CFBundleVersion; may contain dots.
  configuration?: string;  // For example Debug or Release.
  published_at?: string;   // ISO 8601 timestamp.
  size_bytes: number;
  expires_at: string;      // ISO 8601 signing expiry.
  install_url: string;     // itms-services URL containing HTTPS manifest URL.
  install_page_url: string;// HTTPS fallback landing page.
  sha256?: string;
  minimum_os?: string;
}

interface Inbox {
  apps: App[];
  releases: Build[];
  lease_seconds: number;
}
```

Releases are returned newest insertion first; catalog apps are sorted by name. Catalog entries can have no builds. The native client groups builds by `bundle_id`, uses the catalog name when present, and caches the complete snapshot locally. A refresh replaces the snapshot, including deleted entries.

The client receives install URLs, not private Mac filesystem paths. There is no authenticated IPA download endpoint or upload endpoint for mobile clients.

### App and build management

`apps/save` creates an entry or renames an existing entry using the same immutable `bundle_id`. A bundle ID must contain a dot and match `^[A-Za-z0-9][A-Za-z0-9.-]*$`. A name must contain non-whitespace text and be at most 100 characters. Creating an app does not publish a build.

A client can manage entries it created or apps whose builds are in its inbox. Names are server catalog values shared by viewers of that app.

Deletion behavior:

- `builds/delete` deletes that published build and its hosted artifacts, and removes it from every inbox containing it. The requesting inbox must contain the build.
- `apps/delete` deletes the visible app entry and all its published builds, including those listed in other inboxes.

Neither operation uninstalls an app or deletes its on-device data. Deletion does not reset the server's highest published version/build.

## Installation

The native client starts installation on an Install tap. It disables installation when `expires_at` is past or cannot be parsed.

The server supplies an `itms-services` URL with `action=download-manifest` and a `url` query value pointing to the hosted HTTPS manifest beneath `base_url`. The fallback landing page is also beneath `base_url`.

Installer URL format:

```text
itms-services://?action=download-manifest&url=ENCODED_HTTPS_MANIFEST_URL
```

The native client opens the installer URL through UIKit. If opening fails, it opens `install_page_url` in Safari. iOS then presents its normal installation confirmation. A successful URL-open result means only that the request was accepted, not that installation finished.

The manifest and IPA URLs are accessible without bearer headers so the system installer can fetch them; access is restricted by the private Tailscale network. The Mac and Tailscale connection are required during installation. Installer URLs contain no API tokens.

There are no receipts, acknowledgments, install-status callbacks, or completion reports. Server publication finishes independently of the client. Refreshing later reveals the stored builds.

## Errors and transport limits

HTTP behavior:

- Validation, authentication, authorization, and caught file/server errors return HTTP **400** with `{"error":"message"}`.
- Unknown API endpoints return 404 with that JSON error shape.
- Unsupported methods return 405.
- JSON bodies are limited to 64 KiB; the total buffered request is limited to 128 KiB. Oversized or malformed requests may close the connection rather than return a JSON error.
- There are no pagination, WebSocket, or server-sent-event APIs.
- Browser CORS response headers and preflight handling are not implemented.

## Minimal client sequence

```ts
// Identity comes from Keychain; baseURL comes from settings or Bonjour TXT `url`.
async function post(path: string, fields: Record<string, unknown> = {}) {
  const response = await fetch(`${baseURL.replace(/\/+$/, '')}/api/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${identity.token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ ...fields, id: identity.id }),
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error ?? 'Publisher request failed');
  return body;
}

await post('connect', { name: deviceName, platform: 'iPhone' });
const snapshot: Inbox = await post('heartbeat');
// App catalog mutation:
await post('apps/save', { bundle_id: 'com.example.app', name: 'Example' });
const refreshed: Inbox = await post('heartbeat');
```

## Source references

Client: `apps/ios/Publish/{PublisherClient,Models,Identity,Discovery}.swift`. Server: `skills/ios-local-publish/scripts/Publisher/Sources/PublisherCore/{Service,InboxStore,Catalog}.swift`. Integration check: `scripts/check-service.mjs`.
