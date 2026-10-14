# Development

## Build

Use an Apple Silicon Mac with Swift 6.2 or later and Apple’s developer tools. The app targets macOS 15 or later.

```sh
swift build --build-system native -c release
.build/release/Sideport --regression-tests
swift format lint --strict --recursive Sources Package.swift
python3 -m py_compile scripts/*.py
```

The native SwiftPM build system is used because the default Xcode build path fails with this project’s current command-line-tools setup. Dependencies are pinned in `Package.swift` and `Package.resolved`.

`Sources/Sideport/main.swift` is the entry point. The native regression runner lives under `Diagnostics/` because it is also exposed as an explicit command-line mode; this setup does not require XCTest or a full Xcode installation.

## Source layout

| Directory | Responsibility |
|---|---|
| `App/` | Tray UI, approval dialogs and activity indicators |
| `Broker/` | Outer MCP contract and tool dispatch |
| `Computer/` | Native observation, input, capture and clipboard wrapper |
| `Permissions/` | File scopes, remembered locations and command review |
| `Providers/` | Dynamic and managed MCP providers, transport peers and GitHub access |
| `Runtime/` | Provisioning, process ownership, sandbox profiles, gateway and dependency updates |
| `Diagnostics/` | Regression checks and isolated UI fixtures |

All paths above are relative to `Sources/Sideport/`. The `legacy-node` branch preserves the former JavaScript implementation at its own root.

## Validation

`scripts/integration.py` runs the signed app in fresh private state. It does not use the installed gateway or start a remote tunnel.

```sh
python3 scripts/integration.py --app /path/to/Sideport.app --dependencies /path/to/trusted/work
```

Optional flags add adversarial detached-process checks (`--audit-detach`), authenticated GitHub reads and a push dry-run (`--github`), and a version-pinned reference npm provider (`--npm`). `--download-runtime` checks fresh acquisition of the optional Node runtime. Use each script’s `--help` for the full interface.

The computer-use audit requires a person at the Mac:

```sh
python3 scripts/gui_check.py --app /path/to/Sideport.app --report /path/to/report.txt --interactive
```

It uses one private audit-app path and an exclusive lock. Missing native permissions are checked without capture probes; requesting them requires the separate `--request-permissions` flag. Never loop GUI audits unattended.

## Documentation screenshots

```sh
python3 scripts/screenshots.py
```

This renders Sideport’s native views into `docs/images/`, using synthetic folders, a synthetic agent and a temporary demonstration window. It does not capture the desktop, read the clipboard, request recording permissions or start a connection. Review the images before committing them.

## Packaging

The packager accepts verified external runtime assets. These are inputs, not files to commit:

- MCPProxy, nono and DCG binaries with their release metadata and license notices.
- The official runtime-only tunnel release.
- An optional private signing-identity configuration, stored outside the repository.

```sh
python3 scripts/package.py --help
```

The script builds the app, runs the native checks, validates signatures, tests disconnected startup and sandbox compatibility, and checks the gateway and tunnel interfaces. It never packages account credentials or signing keys. The canonical bundled user guide is `docs/getting-started.md`.

`docs/audits/release-readiness.json` can block release exports while an audit issue is open. `--audit-only` creates a private test app without exporting a ZIP. Developer ID distribution, notarization and app self-updates remain separate unfinished release work. Do not describe a locally signed audit build as a notarized public release.
