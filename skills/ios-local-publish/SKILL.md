---
name: ios-local-publish
description: Build and sign an iOS app on a Mac, then deliver it to a connected native Publish inbox on an iPhone or iPad over Tailscale, without TestFlight.
---

# iOS Local Publish

Use the bundled `scripts/ios-local-publish` launcher relative to this SKILL.md (called `PUBLISH` below). It compiles the self-contained Swift utility outside the installed skill. Requires macOS, full Xcode with Swift 6+, authenticated `asc`, a local distribution private key, and Tailscale. No Python is used.

## Select the native inbox

1. Check `PUBLISH service status --json`; start or update the Mac service with `PUBLISH service start --json` when needed. It manages only its own Tailscale HTTPS mount and LaunchAgent. For a port conflict, use `service start --https-port 8443`; never stop another service or reset Tailscale Serve.
2. Run `PUBLISH receivers list --json`. The user opens **Publish** on the target iPhone/iPad. It must connect and remain open during delivery. Local Bonjour advertises the Mac; remote devices enter the returned service `base_url` once. Tailscale node online status and an Xcode development tunnel do not establish an active inbox.
3. Select the requested receiver ID. If exactly one bound receiver is connected, the CLI can infer it. When several are connected, pass `--receiver ID`. Do not publish to all discovered devices.
4. For an unbound inbox, identify the intended physical device with `PUBLISH devices list --wifi --json` and run `PUBLISH receivers bind --receiver ID --udid HARDWARE_UDID --json`. The app cannot read its provisioning UDID. CoreDevice UUIDs are not provisioning UDIDs. Do not guess the association from an ambiguous device name.

The native Publish app must first be installed from this repository's `apps/ios/Publish.xcodeproj` with Xcode or XcodeBuildMCP. See [setup](references/setup.md) for bootstrapping and remote connections. Skill installation alone does not install the device app.

## Build and deliver

Reuse matching saved source defaults or pass an exact application project/workspace and shared scheme. Build the requested checkout including its changes. Do not change its bundle ID, signing settings, app URLs, marketing version, or build scripts to accommodate this utility. Build-number updates below are required.

```sh
PUBLISH init --project /path/to/App.xcodeproj --scheme App --team TEAM_ID --json
PUBLISH publish --receiver ID --json
PUBLISH publish --receiver ID --project /path/to/App.xcworkspace --scheme App --configuration Debug --json
PUBLISH publish --receiver ID --archive /path/to/App.xcarchive --json
PUBLISH publish --receiver ID --ipa /path/to/App.ipa --json
```

Publishing requires a live, bound inbox before compilation and rechecks its lease and IPA device coverage before delivery. A disconnected target leaves its completed IPA available for a later `--ipa` retry. Do not silently fall back to a browser link as delivery.

Always increment the Xcode project's build number for every new source build you deliver, including Debug builds and direct Xcode/XcodeBuildMCP device installs. Change `CURRENT_PROJECT_VERSION` (CFBundleVersion), not `MARKETING_VERSION`. For generated projects, update the authoritative generator configuration and regenerate the project. Keep app and embedded extension build numbers aligned.

For CLI source builds, automatic numbering reserves a number above the project, ledger, and published floor without editing source. After a successful build, persist the actual exported build number back to the project's authoritative configuration before finishing. For direct Xcode installs, increment and persist the project number before building, using a number above the last delivered build. Do not reuse a number for changed app bytes. Retrying delivery of the exact same archive/IPA retains its existing number.

When replacing a build from TestFlight or another publisher, inspect its build or ask for it and use `--build-number HIGHER_NUMBER` once. The IPA's exported number must match the reservation. Use `$(CURRENT_PROJECT_VERSION)` for CFBundleVersion. Debug compilation exports ad hoc distribution signing, not debugger-attach signing.

Certificates and profiles need more than 30 days of lifetime by default. Only lower `--min-validity-days N` intentionally. `--team` does not switch the authenticated asc account. Missing bundle IDs/capabilities or distribution private keys require setup; the utility never creates/revokes certificates. It may register the selected device and create a covering ad hoc profile for an authorized publish. Embedded extensions are checked too.

`--build-setting KEY=VALUE` passes project-specific Xcode arguments. An archive/IPA retains its own compilation settings and number and cannot be combined with source build overrides. Use `PUBLISH build --udid UDID ... --json` only for an IPA without native delivery.

## Report evidence

Return the app version/build, selected receiver, and `delivery.received`. The Mac verifies signatures, profile coverage, hosted manifest, and full hosted IPA checksum. The app acknowledges only after fetching and saving the inbox. A queued release without a receipt is not confirmed device delivery; check `PUBLISH receivers receipt --receiver ID --release ID --json` or explain the disconnected/timeout state.

`installed` stays false: delivery never proves installation or launch. The user taps Install in the native inbox and approves the iOS prompt. The Mac must remain awake and Tailscale reachable during installation. Do not uninstall the target app or erase its data as an automatic fix.

Use `PUBLISH doctor --json`, `service status --json`, and `latest --json` for diagnostics. Stop hosting only when requested with `service stop`. Preserve other Tailscale routes; never use Funnel or reset Serve. Read [troubleshooting](references/troubleshooting.md) when a command fails.

## Library management and version policy

The native app can add/rename/delete app entries and delete builds. Deletion removes server artifacts and inbox entries, never the installed application or its local data. App deletion includes its published builds. Use `PUBLISH builds cleanup-legacy --json` only when cleanup is requested; it preserves native inbox deliveries and the last standalone build while removing old browser-publisher artifacts.

Publishing a lower marketing version, or a lower build within the same version, is an error. The highest published version is retained even after deletion. Reusing a version/build with different IPA bytes is also rejected. Do not bypass this by deleting history or rewriting the source version. Report the mismatch and build the intended newer source. Automatic source build numbering incorporates the published floor when available.
