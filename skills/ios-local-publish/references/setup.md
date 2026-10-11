# Setup and state

## Prerequisites

Run the bundled launcher with `doctor --json`. It reports tools, Xcode, Apple authentication, signing identities, the configured team's distribution certificate, and Tailscale readiness. An inactive hosting route alone is expected before the first publish.

- macOS, selected full Xcode, and Python 3.11+. Use `xcode-select -p` and `xcodebuild -version` to diagnose the selected developer directory.
- The `asc` CLI, authenticated to the intended Apple Developer team. Use `asc auth status` and `asc auth --help` for the installed CLI's supported setup. The tool was exercised with asc 3.7.0 and Xcode 27; inspect command help if a different version rejects an option.
- A paid Apple Developer account and a valid distribution certificate **with its private key** in the local Keychain. The CLI matches local identities to the authenticated team's Apple certificate records; it does not create a new certificate. Import the team's existing signing material through the normal secure Keychain workflow when missing. Never put a `.p12`, API private key, or password into this skill.
- The app and extension bundle IDs and required capabilities registered in that team. Xcode must be able to archive the project. The exporter creates or reuses ad hoc profiles for every embedded `.app` and `.appex`.
- Tailscale running on the Mac and target devices, with HTTPS Serve available and tailnet policy allowing access. Its executable must be on PATH; GUI app installations may require separately installing the CLI. A shell alias is insufficient for subprocess calls. Both GUI and open-source macOS variants work through the bundled loopback server. Do not expose it publicly with Funnel.
- Registered physical iPhone/iPad targets; enable Developer Mode on development devices if required by their configuration. Initial Wi-Fi discovery requires prior pairing with Xcode; a device can be remote/offline for later builds and installation.

Primary references when current platform behavior needs verification: [asc](https://github.com/rudrankriyam/App-Store-Connect-CLI), [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve), and [Apple ad hoc distribution](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/).

## Initial configuration

Here `PUBLISH` means the absolute path to `scripts/ios-local-publish` in this skill.

```sh
PUBLISH init --project /path/to/App.xcodeproj --scheme App --team TEAM_ID --json
PUBLISH devices list --wifi --json
PUBLISH devices register --udid IPHONE_HARDWARE_UDID --json
PUBLISH publish --json
```

Repeat `--udid` for several selected devices. `devices register` saves that complete target set; it does not append to the previous set. `devices register --wifi` saves all currently discovered paired physical Wi-Fi devices, so use it only when that matches the request. `--connected` requires `--wifi` for registration/build/publish and additionally requires a live CoreDevice tunnel. `devices list --connected` can inspect all live transports. The hardware provisioning UDID differs from the CoreDevice identifier and simulator ID; malformed IDs are rejected before contacting Apple.

For a one-off device selection, pass repeated `--udid` to `build` or `publish`. The profiles must include every selected device in every bundle. Adding a device requires a new export/publication; the old IPA cannot acquire new coverage from its link.

## State and upgrades

State selection, highest priority first:

1. `PUBLISH --state-dir /absolute/path COMMAND ...`
2. `IOS_PUBLISH_HOME`
3. `state_dir` in `~/.config/ios-local-publish/settings.json` (or `IOS_LOCAL_PUBLISH_SETTINGS`)
4. `~/.local/share/ios-publish`

Install with `npx skills add omarestrella/ios-local-publish --skill ios-local-publish`, or add `--global --agent codex claude-code`. The entire runtime is in this directory and works with copy or symlink installs without post-install hooks. The optional repository installer saves machine settings outside the skill and adopts old checkout-local state only with explicit `--adopt-checkout-state`. All launchers share these state rules. A portable skill bundle contains source code and instructions only.

State contains `config.json`, the per-project/scheme build-number ledger, run logs and archives/IPAs, release metadata, the served `site/`, and local-server metadata. Keep it when upgrading the skill. One writer is permitted per state directory; readers can still inspect status. Several apps can share the same state and route, with separate per-bundle latest pages. `latest` reports the most recently published app globally.

The file server binds only to `127.0.0.1`, runs under a per-state user LaunchAgent, and Tailscale proxies `/ios-publish` over HTTPS. The route is checked for ownership before modification. The LaunchAgent starts at login and after crashes; it does not keep the Mac awake or run before login. Build logs, profiles, and configuration stay outside `site/`. Old releases are retained until deliberately removed.

Use `npx skills update ios-local-publish` for a skills-managed installation; use the repository installer for its own managed installation. Do not mix installers on the same destination. Upgrades preserve external state and active hosting. The LaunchAgent's server script lives in `state/server-runtime/`, so removing a skill copy does not delete the running server's code. `serve start` refreshes stale server code and missing program paths and checks real HTTPS readiness. Run `serve stop` before deliberately decommissioning hosting, and retain state if published links must remain available.
