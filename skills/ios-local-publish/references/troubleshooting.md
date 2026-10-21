# Troubleshooting

- **No registered receiver:** Connect Publish to the Mac once and bind its hardware UDID. Registered, bound inboxes work offline; an expired heartbeat never blocks publishing. Use `--receiver ID` when several are bound.
- **Multiple receivers:** Select an explicit `--receiver ID` matching the user's requested device. Names are descriptive and can be duplicated.
- **Unbound inbox:** Use receivers bind with the verified hardware provisioning UDID. Never use a CoreDevice UUID. Binding does not register a new network pairing.
- **HTTPS fails:** Check Tailscale, the returned service URL, tailnet access policy, and port ownership. Use service start --https-port 8443 for a port conflict. Never weaken TLS verification or stop another utility automatically.
- **Nearby Mac not listed:** Allow local network access for Publish in iOS Settings. Bonjour discovery is local only; enter the HTTPS base_url on remote networks. Tailscale on both ends provides connectivity, not Bonjour multicast forwarding.
- **Missing signing identity:** Confirm the distribution certificate/private key is in Keychain and asc is authenticated to the matching team. --team does not change accounts.
- **Missing bundle IDs/extensions:** Register the app and embedded targets with their required capabilities in the intended Apple team before building. The utility does not guess capabilities or create certificates.
- **Signing expires soon:** Recreate the necessary certificate/profile or deliberately use a shorter --min-validity-days threshold. Default is 30 days. Expired builds cannot install.
- **Exported build mismatch:** Use $(CURRENT_PROJECT_VERSION) for CFBundleVersion and reserve with --build-number. Source files are not rewritten. Use a number above builds installed through another publisher.
- **Device offline during publication:** Expected. The server retains the queued build; Publish fetches it on its next connection. No rebuild or delivery retry is needed.
- **Install prompt opens but app is absent:** Installation is performed by iOS, not the receiver app. Inspect device compatibility, profile UDID coverage, signing expiry, replacement rules, and network reachability. Never automatically uninstall an existing app, especially when it holds user data.
- **Swift service fails to start:** Check state/service-logs/stderr.log and the derived user LaunchAgent. service start deploys a fresh compiled executable. No runtime depends on a checkout path or Python interpreter.

- **Version/build is older than latest published:** Use the intended newer source or an explicit higher build for the same marketing version. Deleting the latest build does not reset this policy. Equal version/build with different bytes requires a new build number.
- **App/build deletion:** The native menu manages app entries; swipe deletes a build. These remove server resources, not installed apps. Other inboxes that held a deleted build update on their next refresh.
