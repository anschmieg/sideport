# Sideport

Native macOS tray app and MCP broker for remote agents. Alpha 0.3.0.

**Release status: held.** The second audit found incomplete computer-tool compatibility and a reproducible detached-process cleanup gap. See [the native audit](Docs/native-audit-2026-10-13.md). Passing the ordinary regression suite does not clear those findings.

| Component | Implementation |
|---|---|
| Tray, approvals, broker, forwarding and update checks | Swift |
| Computer use | Embedded PeekabooAutomationKit 4.9.1 |
| Discovery and aggregation | MCPProxy core |
| Connection | Official runtime-only OpenAI tunnel |
| Execution policy | nono and DCG |
| npm / Smithery runtime | Optional Node, acquired when needed |

## Build and validate

```sh
swift build --build-system native -c release
.build/release/Sideport --regression-tests
swift format lint --strict --recursive Sources Package.swift
```

`Scripts/package.py --help` documents packaging inputs. It verifies the native runner, app signature, disconnected startup, sandbox, gateway credentials and tunnel interface before exporting a ZIP. Signing identity and runtime keys are external inputs and are never packaged.

Release exports are blocked by `RELEASE_BLOCKERS.json` while the lifecycle finding is open. `--audit-only` can create a signed private test app without exporting a ZIP.

`Scripts/integration.py --help` documents isolated end-to-end checks. `--github` performs authenticated reads and a push dry-run; it does not change remote data. `--npm` tests an audited reference provider. The suite uses synthetic approvals in fresh private test state and never starts a tunnel.

Runtime-only dependency upgrades use release checksums and compatibility checks, with rollback on failure. The compiled automation library updates with a rebuilt app; its version and dependency graph are pinned in Package.swift and Package.resolved.

The existing bundle identifier is retained for macOS permission continuity. Settings and remembered folder identities retain their existing format. The installed app and live tunnel are not modified by building or packaging.

Legacy/0.2.2 preserves the source baseline for comparison.
