# Publish

A native iPhone/iPad inbox for developer builds, backed by a Swift Mac service. An agent builds and signs your app, publishes to a server-backed inbox, and you tap **Install** to approve the usual iOS installation prompt. No TestFlight processing.

## Install the agent skill

```sh
npx skills add omarestrella/ios-local-publish --skill ios-local-publish
```

The skill includes the complete Swift CLI package. Default symlink installs and `--copy` both work. No Python or third-party Swift dependencies. The launcher compiles to `~/Library/Caches/ios-local-publish`, outside the installed skill. The service runs a durable copy of the compiled executable outside the checkout.

## Requirements

- macOS 14+, full Xcode with Swift 6+, and `asc` authenticated to your paid Apple Developer team.
- A distribution certificate/private key in Keychain; registered bundle IDs and capabilities for the app and its extensions.
- Tailscale on the Mac and devices. HTTPS enabled for the tailnet, with policy allowing device access to the Mac.
- The **Publish** app installed on the target iPhone or iPad. Connect it once to register; open it whenever you want to retrieve and install builds.

## Start the Mac service

```sh
./ios-publish service start --json
```

A user LaunchAgent hosts the inbox API and installation files. Tailscale Serve provides trusted HTTPS privately on your tailnet. Only this utility's `/ios-publish` mount is changed. The Mac must stay awake during installation.

If another utility owns port 443:

```sh
./ios-publish service start --https-port 8443 --json
```

The returned `base_url` is the address for the device app. The service advertises it with Bonjour on the local network. On a remote network, enter this HTTPS address in Publish once; the app remembers it. Bonjour multicast does not cross Tailscale. No Tailscale SDK or custom VPN is embedded in the app.

## Install the native app

Open `apps/ios/Publish.xcodeproj`, select your developer team and physical iPhone/iPad, and run the **Publish** scheme. The checked-in project is generated from `apps/ios/project.yml` with XcodeGen. It has no external packages. The app supports iOS/iPadOS 18+.

An agent can bootstrap it over an existing Xcode Wi-Fi device pairing using XcodeBuildMCP's `device build-and-run`. Set `DEVELOPMENT_TEAM` and optionally `PUBLISHER_URL` as build arguments; the repository contains no personal team or host settings. This first development install is separate from ad hoc builds delivered into the inbox.

Open Publish, choose your nearby Mac under **Publisher**, or enter its `base_url`. Foreground presence expires after 30 seconds without a heartbeat. The app remembers a random receiver credential in Keychain and its inbox on disk; it cannot read the hardware provisioning UDID.

## Bind the device and publish

```sh
./ios-publish receivers list --json
./ios-publish devices list --wifi --json
./ios-publish receivers bind --receiver RECEIVER_ID --udid HARDWARE_UDID --json
./ios-publish init --project /path/to/App.xcodeproj --scheme App --team TEAM_ID
./ios-publish publish --receiver RECEIVER_ID --json
```

Binding associates an inbox with an already identified provisioning device; it does not pair a network connection. `devices list` reports Xcode hardware UDIDs and CoreDevice identifiers separately. Use the hardware UDID for signing. If exactly one registered receiver is bound, `--receiver` may be omitted. Several bound devices require explicit selection. Nothing automatically selects every discovered device.

Source builds reserve increasing build numbers without editing source files. Signing and HTTPS are checked before compilation. Profile coverage is checked before publication. The device may be offline: builds are queued durably on the Mac and fetched when Publish next opens. Existing IPA files can also be published:

```sh
./ios-publish publish --receiver RECEIVER_ID --ipa /path/to/App.ipa --json
```

Other commands:

```sh
./ios-publish publish --receiver ID --configuration Debug --json
./ios-publish publish --receiver ID --archive App.xcarchive --json
./ios-publish build --project App.xcodeproj --scheme App --udid HARDWARE_UDID --json
./ios-publish inspect App.ipa --udid HARDWARE_UDID --json
./ios-publish service status --json
./ios-publish doctor --json
./ios-publish latest --json
./ios-publish service stop
```

Debug compilation still exports ad hoc distribution signing; debugger attachment is disabled. Archives/IPAs retain their compilation settings and build numbers. `--min-validity-days` defaults to 30 for signing. `--build-number` can establish a higher baseline when replacing a build from another publisher. Use `$(CURRENT_PROJECT_VERSION)` for the app's `CFBundleVersion`.

## Delivery and trust

The Mac service has no remote build or signing endpoint. The agent runs Xcode/asc locally and submits the verified IPA through a bearer-authenticated admin API. The admin secret remains in a mode-0600 file on the Mac. Each native inbox has its own credential and can fetch only its own deliveries. Receiver names are descriptive, not identity proof; select the known receiver ID and bind its verified hardware UDID.

Devices with tailnet access can enroll a new inbox, but enrollment cannot bind a UDID or publish a build. Artifact URLs are private to the tailnet and are bearer-like unguessable links; the system installer must be able to fetch them without the app's authorization headers.

`published` means the HTTPS manifest and IPA checksum were verified and the build is stored on the server. Publication completes without contacting the phone. Publish refreshes its available builds when opened. The app opens the system installer on your tap; publication does not establish installation or launch.

State lives in `~/.local/share/ios-publish`, or the saved machine settings, `IOS_PUBLISH_HOME`, or explicit `--state-dir`. Existing build ledgers, IPA artifacts, and source configuration are reused. Old browser-console routes are no longer the product interface. A minimal Safari install page remains for the system handoff.

## Development

```sh
swift test --package-path skills/ios-local-publish/scripts/Publisher
./ios-publish --help
node scripts/check-service.mjs
node scripts/check-skills-install.mjs
```

The Swift package contains the CLI, signing/export pipeline, HTTP service, and durable inbox store. `apps/ios` contains the SwiftUI app. Build products, device captures, credentials, and personal machine settings do not belong in this repository.

## App and build management

Use **+** in Publish to add an app entry by name and bundle ID. The app menu supports renaming and deletion. Swipe a build to delete it. Deleting an app also deletes its published builds; deleting a build removes its hosted artifacts and managed source run when nothing else references it. Installed apps and their device data are untouched. Deletions are reflected in every inbox that held the same build.

Publishing rejects a marketing version below the highest published version, or a lower build number within that same version. Comparison is numeric (`1.10` is newer than `1.9`). A higher marketing version may start a new build sequence. Reusing the same version/build with different IPA bytes is an error. Deleting builds or app entries does not reset this high-water mark. Source publishing checks available version settings before compilation and checks the exported IPA again before hosting.

To remove artifacts left by the old browser publisher:

```sh
./ios-publish builds cleanup-legacy --json
```

This preserves native inbox deliveries and the most recent standalone build, removes legacy releases and unreferenced run directories, and retains version/build history needed to prevent downgrades.
