# Status and limitations

The native 0.3.4 alpha follows the audited 0.3.2 baseline. GitHub prereleases provide a zipped app with bundled runtime inputs, signed with the project's local identity. It is a technical preview: Developer ID signing, notarization and a complete first-run flow are not available. Fresh installations still need manual tunnel and client provisioning.

## Validation completed

- 21 native regression groups cover policy, request bounds, file scopes, remembered locations, process cleanup, provider transport, update rollback and computer-tool contracts.
- Isolated integration checks cover file and shell operations, agents-dev forwarding, scoped gateway credentials, authenticated client presence, transport-close clearing and tray lifecycle cleanup.
- Additional checks exercised detached-process ownership, fresh npm admission, GitHub authentication and an HTTPS push dry-run without remote writes.
- A controlled native UI fixture exercised capture, text replacement, Unicode insertion, clicking, selector-based drag and stale-selector refusal. Sandboxed screen and Accessibility probes were refused.

See the [initial audit](audits/native-audit-2026-10-13.md), [follow-up](audits/native-followup-2026-10-13.md) and [activity-indicator record](audits/indicators-0.3.2.md) for the evidence and its limits.

The [0.3.3 patch record](audits/presence-and-identity-0.3.3.md) covers retained-session accounting, the menu-bar capsule and POSIX user lookup in the shell sandbox.

The [0.3.4 live-presence record](audits/live-presence-0.3.4.md) covers current tunnel operations, tool receipt lifecycle, safe health reads and the configured client label. The earlier two-minute heuristic has been removed.

## Open work

- **Public distribution:** zipped technical-preview builds are labelled alpha and self-signed. Developer ID signing and notarization are pending; downloaded builds may need macOS's explicit per-app approval.
- **App updates:** the existing menu action updates runtime dependencies. The app self-updater is unfinished and is paused until a Developer ID certificate is available.
- **Initial setup:** tunnel and connector provisioning are not yet a complete first-run flow.
- **Smithery:** live forwarding remains unverified because the tested installed manager returned an error for its namespace. Parsing and connection selection have focused coverage.
- **Computer-tool breadth:** advanced file-picker handling and every shortcut across keyboard layouts have not been verified in live use. Native text editing and Unicode insertion have been exercised.
- **Connection presence:** Connected reflects a current tunnel operation; Operating reflects an executing tool. These are sampled live observations, not a persistent conversation session. Stateless clients show Available between requests, and very short calls may complete between samples. Client labels are local settings, not authenticated identities or counts of distinct conversations. Independent idle SSE clients connecting directly to the local gateway are not monitored by this transport-specific indicator.
- **Containment limits:** there are no hard per-job CPU, memory or disk quotas. Full GUI control is broader than the file/shell sandbox, and command review cannot prove arbitrary scripts safe.

The previous implementation is archived on [`legacy-node`](https://github.com/anschmieg/sideport/tree/legacy-node). It is published for reference and migration, not as the current native app.
