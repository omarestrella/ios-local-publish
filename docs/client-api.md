# Publish client API

This is the contract for a replacement Publish client, including a Juno/Quasar implementation. It describes the current Swift server, not a proposed API. No receipt or installation-reporting protocol exists.

## Base URL and discovery

The Mac CLI's `ios-publish service status --json` returns `base_url`, for example `https://your-mac.your-tailnet.ts.net:8443/ios-publish`. Preserve its port and path prefix. Append endpoint paths to that prefix; resolving `/api/connect` against the origin would incorrectly drop `/ios-publish`.

Use trusted HTTPS and the device's Tailscale connection. Same Wi-Fi is not required. The Mac must be awake and reachable when refreshing or installing.

Optional local Bonjour discovery: browse `_ios-publish._tcp` in `local.`. The service's TXT record `url` contains the complete HTTPS base URL. Use that value rather than constructing an HTTP URL from its Bonjour hostname. Bonjour does not discover remote Tailscale nodes; allow entering and saving the URL.

`GET {base_url}/healthz` has no authentication and returns:

```json
{"service":"ios-publish","site_id":"opaque-server-identifier"}
```

`site_id` identifies server state, not a device credential or protocol version. There is currently no negotiated API version.

## Identity and authentication

Generate one persistent identity per client installation/project:

- `id`: UUID string recommended; accepted pattern `^[A-Za-z0-9-]{16,64}$`.
- `token`: cryptographically random 32-byte value encoded as 64 hexadecimal characters recommended; accepted pattern `^[A-Za-z0-9_-]{32,128}$`.

Persist both securely in project-isolated Keychain storage. Reuse them across launches. Losing the token prevents authenticating its existing ID; do not generate a new token for that same ID. The token is chosen by the client, not issued by the server.

All `/api/*` endpoints use POST with a JSON object and these headers:

```http
Authorization: Bearer YOUR_TOKEN
Content-Type: application/json
```

Every request includes `id` in its body. No cookies or Mac admin token are needed. Never distribute the Mac's admin credential to a client.

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

The iOS app cannot obtain that UDID itself. A replacement client with a new identity must be bound once before an agent can publish builds to it. Builds are scoped to receiver identity; a new client identity does not automatically inherit the old client's inbox.

### Refresh builds and catalog

```json
{"id":"12345678-1234-4234-8234-123456789abc","active":true}
```

Despite its historical name, `/api/heartbeat` is the inbox refresh endpoint. `active` defaults to true. It updates informational presence and returns the complete current snapshot, not a delta. A client may refresh on launch, foreground, pull-to-refresh, and after mutations. The existing native client also polls every five seconds while open; polling is optional.

`lease_seconds: 30` only controls the Mac's connected indicator. It does not expire credentials, stored builds, or permission to publish. Closing the client must not block publishing. An optional `active:false` call updates presence; no shutdown call is required for correctness.

```ts
interface App {
  bundle_id: string;
  name: string;
}

interface Build {
  release_id: string;       // Stable row identity; opaque string.
  name: string;             // Name from the IPA; catalog name may override display.
  bundle_id: string;
  version: string;          // Marketing version; retain as string.
  build: string;            // CFBundleVersion; retain as string (may contain dots).
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

Ignore unknown response fields. Releases are returned newest insertion first; catalog apps are sorted by name. Group builds by `bundle_id`; prefer the catalog name, falling back to the build name. Preserve catalog entries with no builds. Replace cached snapshots on refresh so deletions disappear; do not only append new releases. Cache locally to show the last snapshot when offline, and distinguish cached content from a successful current refresh.

The client receives install URLs, not private Mac filesystem paths. There is no authenticated IPA download endpoint or upload endpoint for mobile clients.

### App and build management

`apps/save` creates an entry or renames an existing entry using the same immutable `bundle_id`. A bundle ID must contain a dot and match `^[A-Za-z0-9][A-Za-z0-9.-]*$`. A name must contain non-whitespace text and be at most 100 characters. Creating an app does not publish a build.

A client can manage entries it created or apps whose builds are in its inbox. Names are server catalog values shared by viewers of that app.

Confirm destructive actions before calling deletion endpoints:

- `builds/delete` deletes that published build and its hosted artifacts, and removes it from every inbox containing it. The requesting inbox must contain the build.
- `apps/delete` deletes the visible app entry and all its published builds, including those listed in other inboxes.

Neither operation uninstalls an app or deletes its on-device data. Deletion does not reset the server's highest published version/build. Refresh after successful mutations.

## Installation

Installation begins only on a user's tap. Disable Install after `expires_at`; do not treat an unparseable expiry as installable.

Before opening an install URL, validate that it has scheme `itms-services`, query `action=download-manifest`, and a `url` query value pointing to HTTPS on the configured server's origin and beneath its base path. Validate the fallback landing page against the same server boundary. Parse URLs; do not accept arbitrary remote installer links.

If JSKit exposes `installer.install(manifestURL)`, extract the manifest URL from `install_url` and pass it to that binding. Otherwise open the supplied installer URL through a native URL-opening bridge. The server currently constructs this form:

```text
itms-services://?action=download-manifest&url=ENCODED_HTTPS_MANIFEST_URL
```

Use URL/query APIs to encode values. If native opening fails, the existing client opens `install_page_url` in Safari. iOS then presents its normal installation confirmation. A successful URL-open result means only that the request was accepted, not that installation finished.

The manifest and IPA URLs are accessible without bearer headers so the system installer can fetch them; access is restricted by the private Tailscale network. Keep the Mac and Tailscale reachable throughout installation. Do not send API tokens in URLs.

There are no receipts, acknowledgments, install-status callbacks, or completion reports to send. Server publication finishes independently of the client. Refreshing later reveals the stored builds.

## Errors and transport limits

Current behavior (including its nonstandard status choices):

- Validation, authentication, authorization, and caught file/server errors return HTTP **400** with `{"error":"message"}`. Do not assume 401/403 or silently replace credentials after an error.
- Unknown API endpoints return 404 with that JSON error shape.
- Unsupported methods return 405. Use POST for every `/api/*` operation.
- Request headers and JSON bodies are limited to 64 KiB each by the HTTP parser.
- There are no pagination, WebSocket, or server-sent-event APIs.
- Browser CORS/preflight is not implemented. A browser-based Quasar build cannot assume cross-origin `fetch` will work. Use the native host's HTTP binding, or implement and verify CORS separately if a browser client is intended.

Show connection errors with retry. Keep cached builds visible where useful. Do not require an active client as part of the agent's publish workflow.

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
// Render snapshot. On a user action:
await post('apps/save', { bundle_id: 'com.example.app', name: 'Example' });
const refreshed: Inbox = await post('heartbeat');
```

## Juno/Quasar implementation handoff

Build a client against this contract. Keep the Swift Mac service unchanged. Implement server selection, secure persistent identity, initial registration, cached app/build listing, refresh, add/rename/delete app entries, build deletion with confirmation, expiry handling, and user-triggered installation. Use system-native colors. Do not implement receipts or block publishing on the app being open.

Native capabilities needed: isolated Keychain storage, optional Bonjour browsing, and an installer URL-opening binding. HTTP and local caching use existing runtime APIs. Confirm that the chosen Quasar runtime exposes these capabilities; a standard browser alone cannot supply them.

Verify: first registration; later reconnect with the same identity; publication while the client is closed followed by refresh; cached offline display; mutations and shared deletion; denied access to another inbox; real-device installer prompt. Do not equate a displayed build or accepted installer URL with completed installation.

Implementation references: `apps/ios/Publish/PublisherClient.swift`, `Models.swift`, `Identity.swift`, `Discovery.swift`; server routes and validation are in `skills/ios-local-publish/scripts/Publisher/Sources/PublisherCore/{Service,InboxStore,Catalog}.swift`. The integration check is `scripts/check-service.mjs`.
