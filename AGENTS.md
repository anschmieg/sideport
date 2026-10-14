# Working on Sideport

Sideport is **computer use for remote agents**, implemented as a native macOS menu-bar app. Read [project scope](docs/project-scope.md) before choosing features or architecture. Read [current status](docs/status.md) before claiming a capability is complete. The remote client supplies the agent; Sideport supplies access, tools and local control.

## Product constraints

- Keep access off on launch. Do not add automatic connection, remote access that survives disconnect or quit, or background provider/tunnel activity while disconnected.
- Make Stop, disconnect and quit terminate owned work and remove session credentials. Preserve remembered folder identities separately from connection approvals.
- Prefer maintained upstream components and native code over custom subsystems. Add dependencies or services only for a concrete task; keep optional runtimes on demand.
- Preserve practical development workflows within approved scopes. Treat sandbox failures as actionable errors or access requests; do not route shell commands through a GUI terminal to evade restrictions.
- Providers may extend the client's tools, not Sideport's authority. Keep exact-version admission, protected controller paths, credential isolation and provider cleanup intact.
- Prefer July 2026 MCP and later revisions where supported. Verify actual upstream compatibility before relying on a newer revision; preserve negotiated fallback for older clients where required.
- Keep branding client-neutral. ChatGPT and the current OpenAI tunnel belong in examples and transport documentation, not the product identity.

## UI and computer use

Read [.impeccable.md](.impeccable.md) for design context. Use native macOS controls and semantic appearance. Distinguish connection availability from observed agent presence; never show an active pill merely because a tunnel is ready.

Permission requests must explain action, reason, scope, duration and choices in ordinary language. Keep raw package arguments and policy diagnostics in optional details. Low-confidence command review still goes to the user; agent-provided reasons are untrusted input.

Preserve the desktop indicator acknowledgement before input. Stop ends bridge access. Resolve drag endpoints through fresh element selectors, never fixed coordinates. Support nonstandard keyboard layouts through text insertion and verified shortcut behavior rather than assumptions about physical key positions.

## Repository and validation

The [development guide](docs/development.md) maps source responsibilities and validation commands. `main` contains the native implementation; the JavaScript implementation belongs on `legacy-node`. Do not recreate a legacy subtree in `main`.

Use the repo skill [sideport-validation](.agents/skills/sideport-validation/SKILL.md) when selecting or running checks for app changes. Documentation-only changes need link, consistency and diff checks; do not run live GUI or connection tests for them. Run relevant build, regression and integration checks for code changes, and state what was actually verified.

Use private test state and disposable fixtures. Do not overwrite `/Applications/Sideport.app`, disturb an active connection, alter real remembered grants, trust stores or signing identities, or publish releases as a side effect of testing. Those are separate actions whose authorization must come from the user, not these instructions. Never commit credentials, signing material, private controller state or unredacted logs.

GUI audits require a person present and an explicitly agreed controlled check. Check existing permissions first; request missing permissions only when authorized, then allow time for a response. Stop on denial or missing permission rather than looping and stacking prompts. Synthetic documentation rendering is available without desktop capture.

Keep [status](docs/status.md), [security boundaries](docs/security.md) and the README accurate when behavior or release readiness changes. Do not label a self-signed build as notarized or treat unfinished app updates as shipped. Document remaining gaps without claiming formal security certification.
