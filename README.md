# ios-local-publish

Build an iOS app, export an ad hoc signed IPA, and share a private install link through this Mac and Tailscale. For developers and coding agents who want remote device installs without TestFlight processing.

## Install the skill

```sh
npx skills add omarestrella/ios-local-publish --skill ios-local-publish
```

Select your coding agents when prompted, or install globally for Codex and Claude Code:

```sh
npx skills add omarestrella/ios-local-publish --skill ios-local-publish --global --agent codex claude-code
```

Both the default symlink installation and `--copy` work. The complete Python runtime is inside `skills/ios-local-publish/`; installation needs no post-install hook, source checkout, or Python package download. Invoke `$ios-local-publish` in Codex or ask your agent to use the skill. Resolve its launcher relative to the installed `SKILL.md`.

For local development before pushing this repository:

```sh
npx skills add . --skill ios-local-publish
```

The GitHub commands require the repository to have been pushed. `npx skills update ios-local-publish` updates a skills-managed installation. Do not mix package managers for the same destination.

## Requirements

- macOS, selected full Xcode, and Python 3.11+.
- [asc](https://github.com/rudrankriyam/App-Store-Connect-CLI) authenticated to the intended Apple Developer team, with paid Developer Program membership.
- A distribution certificate and its private key in the local Keychain. App and extension bundle IDs/capabilities must exist in the authenticated team. `--team` selects signing expectations; it does not switch the `asc` account.
- Tailscale connected on the Mac and installing devices, with HTTPS Serve available and tailnet policy permitting access. The executable `tailscale` must be on PATH; a shell alias is insufficient. GUI installations may need their CLI installed separately.
- Registered physical iPhones/iPads. Initial Wi-Fi discovery requires prior Xcode pairing. Saved targets can be remote or offline during later builds.

## First publish

Use the checkout launcher below, or the installed skill's `scripts/ios-local-publish` with the same arguments:

```sh
./ios-publish doctor --json
./ios-publish init --project /path/to/App.xcodeproj --scheme App --team TEAM_ID
./ios-publish devices list --wifi
./ios-publish devices register --udid IPHONE_HARDWARE_UDID
./ios-publish publish --json
```

`--project` accepts an exact `.xcodeproj`, `.xcworkspace`, or directory with one unambiguous project/workspace. Prefer an explicit shared application scheme. Repeat `--udid` for multiple targets; hardware provisioning UDIDs differ from CoreDevice UUIDs. `devices register` replaces the saved target set. Use `--wifi` to select all paired physical Wi-Fi devices only when that matches your intent. `--connected` requires `--wifi` for registration/build/publish; `devices list --connected` can inspect all live transports.

Open the returned HTTPS install page in Safari on the device, tap Install, and approve the iOS prompt. A cable and shared Wi-Fi are unnecessary. **Keep this Mac awake and Tailscale connected on both ends.** Install over the existing app when replacement is supported to retain local data; the tool never uninstalls an app automatically.

## Daily commands

```sh
./ios-publish publish                         # Build, sign, verify, host
./ios-publish build                           # Signed IPA only
./ios-publish publish --archive App.xcarchive # Re-export without compiling
./ios-publish publish --ipa App.ipa           # Publish an existing ad hoc IPA
./ios-publish inspect App.ipa --udid DEVICE_UDID --json
./ios-publish latest --json
./ios-publish serve status --json
./ios-publish serve stop                      # Stop this publisher's hosting
```

Source builds automatically reserve a number above the scheme's project version and local history. Failed builds may leave gaps. When switching from TestFlight, Xcode, or another publisher, pass `--build-number HIGHER_NUMBER` once; remote build history is not queried. The exported number must match the reservation, so a hardcoded `CFBundleVersion` is reported as an error. Configure it to use `$(CURRENT_PROJECT_VERSION)`. Version files are never rewritten.

Reused archives/IPAs retain their build number; source build flags with `--archive` or `--ipa` are rejected. Repeat `--build-setting KEY=VALUE` for project-specific Xcode arguments. Build scripts still run normally, including any configured uploads. This tool does not alter app identity, backend URLs, build scripts, or working-tree changes.

Read-only signing preflight checks certificates, known scheme bundle IDs, and profiles before compiling. All bundles actually present in the archive are checked before registering devices. Missing profiles are then created for the selected devices and local distribution certificate. Existing unrelated certificates and profiles are never revoked or deleted. Certificates and profiles must remain valid for more than 30 days by default; deliberately lower this with `--min-validity-days N` when a shorter lifetime is acceptable. A new profile cannot extend an expiring certificate.

## State and hosting

All launchers, including the optional Python package entry point, use the same state selection:

1. Global `--state-dir /absolute/path` before the subcommand.
2. `IOS_PUBLISH_HOME`.
3. `state_dir` in `~/.config/ios-local-publish/settings.json` (override the settings file with `IOS_LOCAL_PUBLISH_SETTINGS`).
4. `~/.local/share/ios-publish`.

Keep machine settings, build archives, IPAs, device records, and signing material outside the skill and repository. One shared state directory owns this Mac's `/ios-publish` route and can host several apps. Pass `--project`, `--scheme`, `--team`, and selected `--udid` values for another app without changing defaults. Build-number ledgers are separated by project and scheme; latest install pages are separated by bundle ID. The `latest` command reports the most recently published app globally.

A loopback file server is supervised by a user LaunchAgent. Its server code lives in the persistent state directory, and it prefers a stable Python executable path. Tailscale Serve proxies only `state/site/` to `https://<mac>.ts.net/ios-publish/`. Other Serve routes are preserved; an existing route owner is never overwritten. No public Funnel endpoint is created. Run `serve start` to repair or refresh this state's server; `doctor` reports unhealthy owned hosting and missing LaunchAgent program paths.

Each release has an immutable page, IPA, and OTA manifest. HTTPS readiness is checked before building. Latest is promoted only after downloading the hosted manifest, page, and entire IPA and verifying its checksum/size. Interrupted or failed verification removes the unverified release. Logs and signing files stay outside the served directory. Old artifacts are retained until deliberately removed.

`published: true` proves publication and download verification from the Mac. It does not prove device installation or launch; `installed` remains false. Verify those separately. Adding a device requires re-exporting and publishing; an old signed IPA cannot acquire new device coverage. The LaunchAgent runs after login and does not keep the Mac awake.

## Other installation options

For a direct Codex installation without Node:

```sh
python3 scripts/install_skill.py
```

This optional installer targets `${CODEX_HOME:-~/.codex}/skills/ios-local-publish`, stages and smoke-checks upgrades, and rolls back if saving settings fails. It rejects unmanaged/modified destinations. Existing machine settings and external state are preserved. Choose state with `--state-dir`; adopting old checkout-local `.ios-publish` state requires explicit `--adopt-checkout-state`. Prefer external state for long-lived hosting.

For a shell command, `uv tool install .` provides `ios-publish` with the same state rules. The skill itself has no Python dependencies. Its setup and troubleshooting guidance is in [SKILL.md](skills/ios-local-publish/SKILL.md).

## Development checks

```sh
python3 -m unittest discover -s tests -v
python3 scripts/check_skills_install.py
```

The second check exercises published `skills@1.7.2` discovery, copy/symlink installation for Codex and Claude Code, standalone execution, and reinstalls in disposable project directories. Override `--skills-version` to check another release. It requires Node/npm and network access. Unit tests exercise signing/device selection, failure ordering, hosted verification/rollback, server lifecycle boundaries, numbering, JSON errors, state selection, and installer upgrades. Live archive/export and physical installation remain separate validation steps.
