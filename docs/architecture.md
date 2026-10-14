# Architecture

Sideport has a native Swift tray app and broker. PeekabooAutomationKit is compiled into the app. MCPProxy provides discovery, aggregation and the authenticated local gateway. The current remote transport is the official runtime-only OpenAI tunnel.

```mermaid
flowchart LR
    Client[Remote MCP client] --> Tunnel[Connection tunnel]
    Tunnel --> Gateway[MCPProxy gateway]
    Gateway --> Broker[Native Sideport broker]
    Tray[Tray app and local approvals] --> Broker
    Broker --> Scoped[File and shell sandbox]
    Broker --> Computer[Approved computer tools]
    Broker --> Providers[MCP providers]
```

The tray app starts disconnected. Enabling connections provisions a fresh approval session and scoped gateway credential, then starts the gateway and tunnel. Disabling connections stops managed work and services and removes the session credential. Remembered folder identities persist separately; computer and provider approvals expire with the connection.

File, shell and local provider execution use nono profiles. A trusted custodian creates a distinct kernel audit session for each sandbox job and tracks it across detachment, completion, timeout and controller failure. Controller state and trusted helper code are excluded from agent write grants.

Computer tools run through the broker after a separate local approval. The wrapper retains recent observations and binds input to checked window and element identities. Drag endpoints use selectors; coordinates are not accepted by the drag contract. This path has broader desktop access than the file sandbox.

MCPProxy discovers additional providers. Dynamic npm servers need an exact version, package audit and local approval; installation scripts are disabled and the running provider has no network access. Existing agents-dev and Smithery connections can be forwarded with their configured credentials after local approval. Node is optional and acquired on demand.

Activity indicators use protected local state. The menu-bar pill follows authenticated gateway activity from the last two minutes, rather than tunnel readiness or a count of retained session rows. Repeated rows with the same displayed client label are grouped; this cannot identify distinct conversations sharing that label. Desktop actions publish a unique action ID and wait for the tray’s matching visibility acknowledgement before proceeding. The overlay clears after eight seconds of inactivity, on disconnect or when its broker exits.

The shell's strict Mach-service allowlist includes the OpenDirectory Libinfo query endpoint for POSIX UID/name resolution. The separate directory-management API remains denied, alongside screen, Accessibility and Keychain services.

## Components

| Component | Upstream |
|---|---|
| Computer use | [Peekaboo](https://github.com/openclaw/Peekaboo) |
| Discovery and gateway | [MCPProxy](https://github.com/smart-mcp-proxy/mcpproxy-go) |
| Remote connection | [OpenAI tunnel-client](https://github.com/openai/tunnel-client) |
| Execution sandbox | [nono](https://github.com/nolabs-ai/nono) |
| Destructive-command screening | [DCG](https://github.com/Dicklesworthstone/destructive_command_guard) |

The application’s dependency pins and release metadata determine the actual versions. Standalone dependencies update through checksum and compatibility checks with rollback. The compiled computer-use library updates with a rebuilt app.
