# Sideport — legacy Node implementation

This branch preserves the 0.2.2 implementation: a Swift menu-bar app with a JavaScript MCP broker. Current development and documentation are on [main](https://github.com/anschmieg/sideport/tree/main), where the broker and computer-use wrapper are native Swift.

| Path | Contents |
|---|---|
| `mcpproxy.swift` | Tray app and connection lifecycle |
| `ApprovalDialog.swift`, `RememberedLocations.swift` | Local approvals and saved folder scopes |
| `Bootstrap.swift` | Runtime provisioning |
| `permission-broker/` | JavaScript broker, providers, policy and regression fixtures |

The legacy setup relied on separately provisioned runtimes, credentials and MCP servers. This is a source archive for comparison and migration, rather than a self-contained installer. Credentials, local configuration and signing keys are not included.

The historical copy of the DCG executable is omitted from this branch's current tree. Obtain that dependency from its [official releases](https://github.com/Dicklesworthstone/destructive_command_guard/releases) if you need to reconstruct the old environment.
