# Sideport

Native macOS tray app and MCP broker for remote agents. Alpha 0.3.2.

This release adds a distinct menu-bar icon, a pill for confirmed client sessions, and desktop-control outlines with a local Stop button. See [behaviour and validation](Docs/indicators-0.3.2.md).

**Release status: ready for alpha testing.** Detached-process cleanup passes adversarial tests. A controlled GUI test confirms working capture/input and refusal of screen/Accessibility access from sandboxed commands. See [the audit follow-up](Docs/native-followup-2026-10-13.md).

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

Release exports are blocked by `RELEASE_BLOCKERS.json` while an audit blocker is open. `--audit-only` can create a signed private test app without exporting a ZIP.

`Scripts/integration.py --help` documents isolated end-to-end checks. `--github` performs authenticated reads and a push dry-run; it does not change remote data. `--npm` tests an audited reference provider. The suite uses synthetic approvals in fresh private test state and never starts a tunnel.

GUI checks require `Scripts/gui_check.py --interactive` with the person present. They use a fixed audit-app path and an exclusive lock. Missing native permissions are checked without capture probes; requesting them requires the separate `--request-permissions` flag. Never loop new GUI builds unattended.

Runtime-only dependency upgrades use release checksums and compatibility checks, with rollback on failure. The compiled automation library updates with a rebuilt app; its version and dependency graph are pinned in Package.swift and Package.resolved.

The existing bundle identifier is retained for macOS permission continuity. Settings and remembered folder identities retain their existing format. The installed app and live tunnel are not modified by building or packaging.

Legacy/0.2.2 preserves the source baseline for comparison.
