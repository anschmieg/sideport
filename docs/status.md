# Status and limitations

The native 0.3.2 baseline is an early alpha for technical users. Source builds and native checks are available. A fresh usable installation still needs external runtime inputs and one-time connection provisioning; a public notarized installer is not available yet.

## Validation completed

- 21 native regression groups cover policy, request bounds, file scopes, remembered locations, process cleanup, provider transport, update rollback and computer-tool contracts.
- Isolated integration checks cover file and shell operations, agents-dev forwarding, scoped gateway credentials, authenticated client presence, transport-close clearing and tray lifecycle cleanup.
- Additional checks exercised detached-process ownership, fresh npm admission, GitHub authentication and an HTTPS push dry-run without remote writes.
- A controlled native UI fixture exercised capture, text replacement, Unicode insertion, clicking, selector-based drag and stale-selector refusal. Sandboxed screen and Accessibility probes were refused.

See the [initial audit](audits/native-audit-2026-10-13.md), [follow-up](audits/native-followup-2026-10-13.md) and [activity-indicator record](audits/indicators-0.3.2.md) for the evidence and its limits.

## Open work

- **Public distribution:** Developer ID signing and notarization are pending. Public releases will be labelled alpha.
- **App updates:** the existing menu action updates runtime dependencies. The app self-updater is unfinished and is paused until a Developer ID certificate is available.
- **Initial setup:** tunnel and connector provisioning are not yet a complete first-run flow.
- **Smithery:** live forwarding remains unverified because the tested installed manager returned an error for its namespace. Parsing and connection selection have focused coverage.
- **Computer-tool breadth:** advanced file-picker handling and every shortcut across keyboard layouts have not been verified in live use. Native text editing and Unicode insertion have been exercised.
- **Connection presence:** the gateway reports sessions after the first tool call, so a handshake-only client is not immediately shown. Client names are reported labels, not proof of identity. Multiple sessions are not attributed to one specific desktop actor.
- **Containment limits:** there are no hard per-job CPU, memory or disk quotas. Full GUI control is broader than the file/shell sandbox, and command review cannot prove arbitrary scripts safe.

The previous implementation is archived on [`legacy-node`](https://github.com/anschmieg/sideport/tree/legacy-node). It is published for reference and migration, not as the current native app.
