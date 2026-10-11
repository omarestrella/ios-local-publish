# Diagnose failures

Use the failed command's JSON error and retained run logs. Resolve the concrete cause before retrying an archive or creating more signing resources. Stop when a repair requires unavailable credentials, a device action, a choice between ambiguous projects, or changes beyond the requested app/distribution scope; report the specific action needed.

## Build or signing

- **Unknown/ambiguous project or scheme:** pass the exact workspace/project and a shared scheme with one identifiable application target. An unset `CURRENT_PROJECT_VERSION` needs an explicit build number. `CFBundleVersion` must use `$(CURRENT_PROJECT_VERSION)`; an exported number that ignores the reservation is rejected.
- **No local distribution identity:** check the authenticated `asc` account/team as well as the Keychain certificate/private key. `--team` does not switch `asc` accounts. Existing Apple certificates alone cannot sign. Do not revoke or replace certificates to fix discovery. Certificates and export profiles require more than 30 days of remaining life by default; `--min-validity-days` deliberately lowers that requirement, but cannot extend signing lifetime.
- **Missing bundle ID, capabilities, or export entitlements:** inspect the run's `archive.log`, `export.log`, and `signing/ExportOptions.plist`. Resolve the team/capability configuration in the intended developer account rather than changing the app identity.
- **Expired signing or newly added device:** build again, or export the existing archive with the selected devices. Inspect the resulting IPA with `inspect /path/to/App.ipa --udid HARDWARE_UDID --json`. Every extension must cover that device. A disabled Apple device is surfaced explicitly and is not silently re-enabled.
- **Another writer:** wait for the existing command to finish, or determine whether it has exited. Do not delete `.lock`; the lock belongs to the live file descriptor, and deleting it can allow competing writers.

## Link or hosting

- Check `serve status --json`, Mac sleep, and Tailscale connectivity on both ends. A successful fetch from the Mac does not prove that a device's tailnet policy permits access.
- Check the state's `server-logs/stderr.log` and `server.json` when the loopback server is unhealthy. `serve start` repairs this state's own stopped server/route. It refuses to overwrite another service's route; reuse the original state or resolve the route owner explicitly. Never run `tailscale serve reset` as a repair.
- If hosting verification fails after a successful export, reuse the retained run's `App.ipa` with `publish --ipa /path/to/run/App.ipa --json` after fixing access. A new compile or build-number reservation is unnecessary. Read the run's result/logs to find the artifact.
- Open the HTTPS **install page** in Safari on the device. The button is an `itms-services` URL pointing to an HTTPS manifest; downloading an IPA file directly is not the install flow. Normal devices require user approval.

## Already installed or failed replacement

Do not infer a single cause from iOS's generic installation message. Check the installed app's bundle ID/version/build when device access is authorized, the new release's build, its signature/profile/device coverage, and device OS compatibility.

The local build ledger does not include TestFlight, Xcode, or another publisher. Choose `--build-number` higher than the installed build when crossing distribution channels. Source builds then advance from that reservation; reused archives/IPAs keep their number. Signing/channel changes can impose additional replacement constraints. Do not promise that a build-number change repairs every case, and do not uninstall the existing app automatically: doing so can remove local data.

If verification is requested, `xcrun devicectl device info apps --help` describes the installed Xcode's app query. Use the selected physical device's identifier, filter the requested bundle, and record the returned version/build. A query confirms installed metadata, not successful launch or application behavior. Keep manual user confirmation separate from independently observed evidence.
