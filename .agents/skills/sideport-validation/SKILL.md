---
name: sideport-validation
description: "Select and run Sideport build, regression, integration or UI checks in isolated state. Use for validating app changes or investigating regressions in this repository; documentation-only edits need local consistency checks, not live access."
---

# Sideport Validation

Locate the repository containing `Package.swift`, `Sources/Sideport/` and `scripts/`. Run commands from that root. Read `AGENTS.md` and `docs/development.md`; read `docs/security.md` for permission, provider, process or credential changes. Paths below are relative to the repository, not this skill directory.

## Select checks by behavior changed

- Documentation only: check local links and file references, distinguish intended goals from implemented behavior, and run `git diff --check`. Do not start a gateway, GUI audit or permission prompt.
- Swift app or broker: run `swift build --build-system native -c release`, `.build/release/Sideport --regression-tests` and `swift format lint --strict --recursive Sources Package.swift`. The project uses native SwiftPM with command-line tools; do not substitute the failing Xcode build path without investigating it.
- Python tooling: run `python3 -m py_compile scripts/*.py` and the changed tool's relevant safe path. Compilation alone does not verify packaging or process behavior.
- Permissions, providers, gateway or process ownership: add the applicable isolated integration checks. Read the script's arguments before selecting optional probes.
- UI presentation: render the native documentation views with `python3 scripts/screenshots.py --output /absolute/temporary/directory` and inspect the images. This demonstrates layout, not live connection state or computer-use safety.

## Isolated integration

Use a verified private app and trusted runtime inputs with `scripts/integration.py --app ... --dependencies ...`. Add `--executable .build/release/Sideport` to exercise the freshly built code with the app's resources. The script supplies fresh private state and synthetic project scopes, tests a local gateway and does not start the remote tunnel.

Use `--audit-detach` when cleanup or execution containment changes. `--npm` and `--download-runtime` perform downloads; `--github` uses the real CLI account for reads and a push dry-run; `--smithery` reads existing manager connections. Check authorization for that network or account use. Synthetic decisions in the integration fixture are not permission to approve live requests or modify real grants.

If the verified inputs are unavailable, finish the checks that can run and report the integration gap. Do not borrow credentials, relax signatures or install new trust to make a test pass. Changes to the installed app or an active session require their own authorization.

## Controlled computer-use checks

Use `scripts/gui_check.py --app ... --report ... --interactive` only with an agreed check and a person at the Mac. It uses a fixed disposable audit-app path and an exclusive lock. Default behavior checks existing permissions; `--request-permissions` is a separate, explicitly authorized step. Give the person time to respond to a native prompt. On denial, missing permission or an unexpected prompt, stop and report it rather than retrying captures.

Use only the synthetic audit window for input. Drag must use fresh element selectors. Do not modify normal user apps, type test commands into a real terminal or assume the keyboard is QWERTY. A changed executable or signing identity can invalidate a prior macOS grant.

## Report evidence

State which build and checks ran, which behaviors they covered, any failures or skipped paths, and whether live access was touched. Run `git diff --check` before finishing. Passing native tests does not prove GUI containment or a notarized release; screenshot rendering does not test actual agent presence. Once relevant checks pass, repeat them only for further changes or unresolved concerns.
