# Activity and shell identity patch · 0.3.3

## Findings

The menu-bar capsule was embedded in the status button's image. Native image padding and the selected-button background produced a smaller orange capsule inside a second dark shape. Its semantic orange also differed from the recording-indicator reference supplied by the user.

The live gateway returned 23 retained session rows labelled `openai-mcp`, including one-call records still marked `active`. Sideport counted those rows as agents. Neither those rows nor MCPProxy's history-derived client view establish how many conversations remain connected.

In an isolated shell fixture, `id -un` returned `501` rather than the host's username. The strict Mach-service allowlist excluded macOS's Libinfo identity query service. This breaks programs such as OpenSSH that require a successful `getpwuid` lookup.

## Changes

- Draw the capsule across the native status button, without image padding, retaining native click handling and accessibility. Use 36-point-wide, 24-point-high artwork constrained to the native button's height, and the supplied recording reference's orange (`#FF9230`).
- Show **Recent activity** by client label. Include only the current connection generation's authenticated records with activity in the last two minutes; deduplicate labels and reject missing, invalid or future activity timestamps. Remove the agent-count claim. Expiration clears the activity pill without disabling access.
- Allow only `com.apple.system.opendirectoryd.libinfo` for POSIX identity queries. The separate directory-management API and private RPC service remain denied; the existing screen, Accessibility, Keychain, controller-path and process boundaries remain in place.

## Verification

The native regression group includes duplicate records, idle expiry, timestamp failures and a second client label. Isolated integration adds current-UID resolution and `ssh -G -F /dev/null` configuration inspection against a synthetic hostname; SSH makes no connection. Package self-checks exercise the existing clipboard, Keychain, screen-service, protected environment and controller boundaries after the allowlist change.

Documentation rendering uses Sideport's own status button with its selection highlight enabled, plus synthetic UI data. It does not capture the desktop or establish an agent connection. The exact appearance alongside the system microphone pill still requires review in the installed build.

This patch does not modify the active installation or manufacture unique-agent identity. The activity window is an observation heuristic, not proof that an idle client disconnected. Full GUI containment was not re-audited for this patch; the computer-tool execution path is unchanged.
