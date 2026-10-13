# Native branch audit — 13 October 2026

Status: **hold migration**. The native branch has substantial core parity, but it does not have full legacy computer-tool compatibility or a demonstrated boundary that stops every agent-started process on disconnect.

Comparison: `main` / `077854d` (legacy 0.2.2 sources), against `feat/native-swift-core` / `eb1e35b` and the fixes from this audit. The installed app and live tunnel were not replaced or restarted. All gateway/approval mutations used private test state; GitHub checks were account reads and an owned-repository push dry-run.

## Open findings

| Severity | Finding | Evidence / consequence | Required follow-up |
|---|---|---|---|
| High, release blocker | Deliberate double-fork / `setsid` can escape descendant tracking | The isolated fixture continued updating its heartbeat after `run_shell` returned. It retains its inherited sandbox and, for shell/managed execution, network access. Closing the gateway does not revoke a running process’s file permissions. The fixture is identified and killed by the audit harness. | Establish reliable ownership of detached descendants, including crash and force-quit cases. More frequent polling is not a sufficient security boundary. |
| Medium, compatibility | The embedded computer wrapper exposes narrower schemas than the full legacy Peekaboo MCP server | There are 23 computer tool names, but name counts do not prove parity. The native wrapper lacks some advanced operations/options listed below. | Complete the supported contract or explicitly approve/document the reduced surface before migration. |
| Verification gap | Live screen/input permissions and GUI interactions have not been retested with the rebuilt signed app | The audit validates compilation, response bounds, selectors, receipts, and the approval gate. It does not demonstrate actual capture/type/drag under the installed app’s TCC identity. | Exercise a harmless dedicated GUI fixture in a signed audit build, including stale-window rejection and denial of GUI capture from sandboxed children. |
| Verification gap | Smithery forwarding has no live service test | Installed helper code is copied into protected storage, and argument/configuration handling was reviewed. Native agents-dev forwarding has an isolated integration test. | Add a fixture for Smithery CLI output variants and a read-only live forwarding check. |

The lifecycle probe is available through `Scripts/integration.py --audit-detach`. It reports the finding and exits unsuccessfully if the fixture survives. The normal suite intentionally does not claim to settle that adversarial case.

## Corrections made in this pass

| Area | Before | Correction |
|---|---|---|
| Update archives | Native code rejected symlinks after extraction and did not preflight hard links/special members | Preflight rejects unsafe/control-byte paths, duplicate normalized names, links and special entries. Official Node’s two npm/npx wrapper links are excluded from extraction; npm is invoked by its JS entry point. |
| Trusted execution | GitHub/Smithery host invocations used agent-writable installation paths | Copy installed helpers into private per-broker storage before accepting RPC. Credentials and service calls use those copies. Sandbox write rules protect the app, snapshots, and original helper installations, including the paths used at the next connection. |
| Local administration | The inherited config enabled MCPProxy’s OS-authenticated admin socket | Disable that socket, built-in code execution, and direct server add/remove. Agent-token server mutation and unauthenticated config access are tested as denied. |
| IPC / computer gate | Generic sandbox Mach lookup could reach services outside file permissions | Deny GUI/TCC/launch/clipboard services explicitly. Block Unix-socket connections except macOS DNS. A private named-pasteboard test includes a positive control and never touches the user’s clipboard. This is not yet a live screen-capture containment proof. |
| Update rollback | Gateway database preservation was lost; rollback errors were suppressed | Retain the gateway data directory, test compatibility against a private database clone, restore binary/metadata/data state on failure, and report rollback failures. Bootstrap also restores metadata/configuration state. |
| Concurrent instances | Startup could overlap dependency replacement or another app instance | Hold an OS-released controller lock through connection lifetime or replacement. An overlapping app instance is tested as refused. |
| Process cleanup | A rapidly exiting leader could be reaped before its background children were killed | Observe exit without reaping, kill the reserved owned process group, then reap. Test fast ordinary background children separately from deliberately detached processes. |
| File tools | Large files were refused rather than returning a bounded prefix; escaped output could overflow the subprocess cap; listings lost directory flags | Restore prefix reads with a truncation flag, allow bounded JSON expansion, and return directory-type metadata. Reject hard-linked write destinations before truncation. Kernel denial of linking controller state is exercised with a synthetic sentinel. |
| Forwarding | Only the first provider tool page was loaded; shutdown could race admission | Fetch bounded pages, reject repeated cursors/duplicate tools, and refuse admission after shutdown. |
| Computer responses | Large screenshots could be silently omitted; input could be reported complete without verification | Send a bounded JPEG preview with dimensions and scaling guidance. Preserve action outcomes and distinguish confirmed, unverified, partial, and refused input. Consume snapshots even after uncertain failures. |
| Computer options | Common operations were missing | Restore app hide/unhide, Dock add/remove and right-click alias, window set-bounds, dialog input/dismiss aliases, and text clipboard status/clear/save/restore. Focus and pointer/Space mutations check the observed window identity. |
| Cached npm audit | An audit marker was trusted indefinitely | Re-audit after 24 hours, on missing/unparseable timestamps, or after clock reversal. Refresh failures fail closed. |
| Development environment | The stripped environment could lose the per-user temporary directory | Resolve it through the OS API rather than relying only on inherited `TMPDIR`. |

## Parity assessment

| Capability | Assessment |
|---|---|
| Outer MCP contract | All 16 bundled tool definitions are byte-equivalent as parsed JSON to the legacy manifest. July 2026 discovery and classic fallback are exercised. This is not a full protocol-conformance certification. |
| Remembered locations | Version-1 state fields and device/inode validation are preserved. Reopen, permission promotion, and replacement-directory rejection have regression coverage. |
| File and shell access | Core behavior is covered, including denied controller paths, symlinks, hard links, UTF-8 writes, escaped reads, large-file prefixes, network access and command review. Response objects have changed from legacy stdout-style wrappers; consumers must use current responses. |
| GitHub authentication | Protected helper copies work with the existing Keychain login and trusted nono proxy. Account read, credential-export refusal, controller-key input refusal and HTTPS push dry-run pass. No remote write was performed. |
| npm providers | Fresh pinned Node acquisition/extraction, exact-version package installation/audit, legacy MCP fallback, tool calls, scoped files and shutdown are exercised. Python/Cargo/Go package acquisition remains unsupported, as in the legacy broker; existing managed executables are a separate route. |
| agents-dev | Project configuration discovery, credential-free listing, local approval, stdio forwarding, tool call and stop are exercised with an isolated fixture. |
| Smithery | Present, reviewed, and protected against changing host CLI code through agent write grants; live forwarding remains unverified. |
| Tray / lifecycle | Off-state, toggle, cancellation, helper force-quit and credential removal are exercised locally. Fast ordinary background cleanup has separate coverage. Deliberate detachment remains a blocker. |
| Updater | Checksum/asset/path rules and rollback are reviewed; archive extraction and failure-injected database/binary/metadata restoration are tested. An actual upgrade to a different future dependency version is not certified. |
| Computer use | Core observation and element-directed input remain. Schemas and some options are intentionally stricter, but the reduced contract has not been agreed as full parity. Live GUI verification remains open. |

Remaining computer differences include app open/relaunch/new-instance/launch options; binary clipboard types/files/named slots; dedicated file-picker handling; advanced image output, format, region and multi-capture options; richer selector/modifier/typing/scroll controls. New tool schemas must be queried rather than reusing legacy arguments. Coordinate drag remains prohibited.

## Security limits

- Full computer-control approval is broader than the file/shell sandbox. It can open Terminal or other apps and reach files outside approved folders. The UI states this; instructions to an agent are not an enforcement mechanism.
- Shell/managed execution permits Internet and LAN traffic. Writable shared development caches can contain executable code. These are deliberate compatibility/trust choices, not a claim that arbitrary downloaded code is harmless.
- DCG and model review screen commands; they cannot prove every script safe. Reviewer task context originates with the requesting agent and is treated as untrusted evidence.
- Release checksums authenticate downloaded bytes against the vendor’s published metadata. They do not protect against a compromised vendor release or malicious package with no known advisory.
- Same-user malware outside Sideport’s sandbox, kernel exploits, resource exhaustion and the detached-process ownership gap are outside the tested containment claim. There are no per-job hard CPU/memory/disk quotas.

## Validation record

The native release build and strict Swift formatting are required. Python harnesses pass compilation. The native runner has 17 groups covering policy, uncertain decisions, remote endpoints, package admission, bounded execution, RPC, ordinary process cleanup, scopes, selectors, archives, pagination, rollback, image/action receipts and remembered grants.

Isolated integration covers the broker, gateway, npm and GitHub paths described above. The private compatibility check validates sandbox execution, controller and clipboard isolation, a cloned gateway database, scoped token creation/revocation and the tunnel’s local interface. It does not open a remote tunnel or create a normal ChatGPT conversation.

Release exports are held by `RELEASE_BLOCKERS.json`; the packager allows a private `--audit-only` build without a ZIP. No new release ZIP is exported by this audit. The previously exported 0.3.0 ZIP predates these fixes and must not be described as the audited build.
