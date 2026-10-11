---
name: ios-local-publish
description: Build an Xcode iOS app, export an ad hoc signed IPA, and share a private OTA install link through this Mac and Tailscale. Use for developer or agent distribution to registered iPhones and iPads without TestFlight, including devices on remote networks.
---

# iOS Local Publish

Use the bundled `scripts/ios-local-publish` CLI. It archives with `asc`, signs the main app and extensions for registered devices, and publishes a verified HTTPS install page through Tailscale Serve. Python 3.11+ and macOS are required. The installed bundle contains the runtime; no source checkout or Python package installation is needed.

Resolve the launcher relative to this `SKILL.md`; use its absolute path in commands. Examples below call that path `PUBLISH`. Read [setup.md](references/setup.md) for a new machine, unconfigured project, device selection, or missing dependencies. Read [troubleshooting.md](references/troubleshooting.md) when a command or installation fails.

## Choose the app and devices

- Start with `PUBLISH doctor --json` and `PUBLISH devices list --json` to inspect readiness and saved targets. Reuse an existing configuration when it matches the request. Do not register every discovered device when the user selected only one.
- Accept an exact `.xcodeproj`, `.xcworkspace`, or source directory with one unambiguous project. Determine the shared app scheme from the project or `xcodebuild -list -json`; do not guess it. Build the requested checkout, including its current changes. Do not edit the app's bundle ID, signing settings, server URLs, or version files to accommodate this tool.
- On first setup, save defaults with `PUBLISH init --project /path/to/App.xcodeproj --scheme App --team TEAM_ID --json`, then select/register the authorized hardware UDIDs. Wi-Fi discovery exposes paired physical devices, including sleeping development tunnels. Devices need not remain discoverable after registration.
- One shared state directory owns this Mac's `/ios-publish` route and can host several apps. To publish another app without changing defaults, pass `--project` and `--scheme` to `publish`; specify `--team` and repeated `--udid` when they differ from the saved defaults. Ensure `asc` is authenticated to that team first: `--team` does not switch accounts. A second state directory cannot take over the existing route.

## Build and publish

```sh
PUBLISH publish --json
PUBLISH publish --project /path/to/App.xcworkspace --scheme App --json
```

Use `build` instead of `publish` for an IPA without hosting. Reuse an archive with `publish --archive /path/to/App.xcarchive`; publish an already signed ad hoc IPA with `publish --ipa /path/to/App.ipa`. Both retain the existing build number.

Source builds reserve a build number above the scheme's project version and local history before archiving. Failed attempts may leave gaps. If the installed app came from TestFlight, Xcode, or another publisher, inspect its build or ask for it and pass `--build-number HIGHER_NUMBER` once. Remote distribution history is not queried. Subsequent source builds advance automatically.

Repeat `--build-setting KEY=VALUE` for project-specific Xcode arguments. Build scripts run as configured by the target project; inspect them when external side effects matter. Do not automatically disable uploads or change build behavior. The CLI creates missing ad hoc profiles and registers selected devices as needed for an authorized publish; it never creates/revokes certificates or deletes unrelated profiles.

Signing preflight and HTTPS readiness run before compilation. Certificates and export profiles need more than 30 days of validity by default; use `--min-validity-days N` only when a shorter lifetime is intentional. Source build flags with `--archive`/`--ipa`, or `--connected` without `--wifi` for a build, are rejected. A hardcoded exported build number that ignores the reservation is an error; configure `CFBundleVersion` to use `$(CURRENT_PROJECT_VERSION)`.

## Return evidence

Every command accepts `--json`: one result on stdout, progress on stderr, and a nonzero exit on failure. The global `--state-dir /absolute/path` must precede the subcommand. Override state with that flag or `IOS_PUBLISH_HOME`; otherwise the launcher uses the machine's saved settings and finally `~/.local/share/ios-publish`.

On success, return the clickable `install_page_url`, version/build, and IPA path when useful. `latest_url` is a stable per-app page; `install_page_url` identifies this immutable release. The CLI checks signatures, every embedded provisioning profile, device coverage, expiry, hosted manifest, install page, and the entire downloaded IPA's checksum before promoting latest.

`published: true` proves publication and download from the Mac. It does not prove device installation or launch; `installed` remains false. Verify those separately only when requested, and distinguish observed installed version from user-reported operation. An ordinary personal device must open the page in Safari and approve installation. The Mac must stay awake and both ends must have Tailscale access; a cable and shared Wi-Fi are unnecessary.

For status or the previous link, use `PUBLISH serve status --json` or `PUBLISH latest --json`. Only run `serve stop` when stopping hosting is requested. It removes this tool's route and LaunchAgent; existing other Tailscale routes are preserved. Do not use Funnel, reset Serve, uninstall an app, or remove its local data as an automatic repair.
