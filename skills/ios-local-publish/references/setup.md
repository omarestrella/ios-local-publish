# Setup

Install full Xcode with Swift 6+, authenticate `asc` to the intended Apple Developer team, and install Tailscale on the Mac and devices. Add the distribution certificate and private key to Keychain. Register the target application and extension bundle IDs/capabilities with Apple. `--team` selects expected signing identity; it does not change asc authentication.

Run the bundled Swift launcher:

```sh
PUBLISH service start --json
```

Use `--https-port 8443` if another service uses 443. The service is a Swift executable supervised by a user LaunchAgent, with private HTTPS from Tailscale Serve. The route and executable survive checkout moves or skill updates. Re-run service start after updating the skill to deploy the new executable.

## Native app bootstrap

The source repository contains `apps/ios/Publish.xcodeproj`, scheme `Publish`, bundle ID `net.bitcreative.iospublish`, iOS/iPadOS 18+. Select your developer team and run it on the intended phone/tablet. This development install requires an existing Xcode device pairing or an initial cable pairing.

Agents can use XcodeBuildMCP's device build-and-run workflow after checking its current help and session defaults. Provide the source project's exact path, the intended CoreDevice ID, and `DEVELOPMENT_TEAM=YOUR_TEAM` / `-allowProvisioningUpdates` as build arguments. Optionally set `PUBLISHER_URL` to the service's base_url to preconfigure your own build. No personal defaults or secrets are checked into the project. Generated project sources are maintained in `apps/ios/project.yml`.

The app's Publisher screen lists Bonjour-advertised Mac services on local Wi-Fi. Select one, or enter its HTTPS base_url manually over a remote Tailscale connection. The app remembers the URL and a random credential in Keychain. No separate Mac-phone pairing protocol is needed.

Open the app and keep it foregrounded. Select the matching inbox ID from receivers list, identify its hardware UDID with devices list, and bind them once:

```sh
PUBLISH receivers list --json
PUBLISH devices list --wifi --json
PUBLISH receivers bind --receiver INBOX_ID --udid HARDWARE_UDID --json
```

The app cannot retrieve its hardware UDID. Binding is a local admin action; any authenticated inbox cannot claim a provisioning identity by itself. Devices on the tailnet may enroll inboxes but cannot publish or bind them remotely without the Mac admin credential.

## Storage

State defaults to `~/.local/share/ios-publish`. Selection precedence is explicit `--state-dir`, `IOS_PUBLISH_HOME`, machine settings at `~/.config/ios-local-publish/settings.json`, then the default. `IOS_LOCAL_PUBLISH_SETTINGS` selects another machine-settings file. Skill reinstallation does not replace service state or builds.

Keep the Mac awake through installation. The device app may go offline after starting the system installer; artifact hosting continues independently on the Mac.
