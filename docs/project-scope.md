# Project goals and scope

Sideport lets a remote agent operate a Mac with the local user's permission. It is a native menu-bar app that supplies tools, enforces access decisions, and makes activity visible. The remote client owns the conversation, task planning and reasoning.

This document records the product direction agreed during development. It describes the intended product; [status and limitations](status.md) records what is implemented and verified today. A goal here is not a claim that the alpha already meets it.

## Who it serves

The primary user owns the Mac and wants an agent to work with local projects, files and desktop apps without running a separate development environment or supervising every routine command. The user may leave Sideport running in the menu bar but must deliberately enable remote access. Technical users are the initial alpha audience; daily operation should not require terminal commands or repeated authentication after setup.

ChatGPT is one example client. Sideport's name, UI and core tool contract should describe computer use for remote agents. The current packaged transport uses OpenAI's tunnel; support for other clients depends on compatible transports and is not promised merely because they support MCP.

## Product goals

| Goal | What a successful implementation does |
|---|---|
| Deliberate access | Starts disconnected. Enabling access is a local decision. Stop, disconnect and quit end owned work, close the connection and discard session credentials. Restarting does not silently re-enable access. |
| Quiet when off | Keeps only the lightweight tray app alive while disconnected. Discovery, tunnels, providers and agent work do not run in the background. Measure idle CPU, memory and wakeups before claiming a resource budget; literal zero resource use is not possible for a running app. |
| Useful tools | Provides computer observation and input, approved file access, and a shell that supports ordinary development work, networking and common toolchains. Shell restrictions should produce an actionable access request, rather than encourage a fallback to a GUI terminal to bypass them. |
| Understandable consent | Explains the action, why it is needed, the granted scope and duration, and the consequence of each choice. An agent can choose to request access after a denial; the app does not repeatedly prompt on every failed attempt. Remembered folder grants survive ordinary restarts and updates and remain revocable. |
| Visible activity | Distinguishes access off, connecting, available and observed agent activity. A distinctive menu-bar pill marks activity; any limitation in determining live connection state must be explicit. Desktop input requires a visible outline or screen indicator and a client/Stop control that does not steal focus. Client labels must not be presented as verified identities or distinct-agent counts. |
| Tools on demand | Lets the client discover and request suitable MCP servers or forward servers managed elsewhere. New providers remain subject to admission, scoped execution and local consent. Acquire runtimes and packages only when needed; caching is acceptable. |
| Low maintenance | Uses a small native app with maintained upstream components and reproducible, pinned builds. A configured installation should reconnect without extra manual startup or authentication. Signed updates should preserve settings and permissions where macOS permits, validate replacements, and recover from failures. |

Computer control is a separate, broader capability than file and shell access. The shell's compatibility grants and optional command screening are an execution safety layer, not proof that arbitrary code is harmless. A separately approved desktop session can operate apps outside the file sandbox; its indicator does not provide filesystem containment. See [security boundaries](security.md).

Optional decision-model review can reduce command prompts. Agent-supplied context is untrusted, and low confidence or unavailable review must retain the local user decision path. The reviewer does not silently enlarge filesystem grants or authorize providers and desktop access.

## Extensibility boundary

An agent may expand its available tools to complete a task. This means discovering, requesting and using providers through Sideport's controlled interfaces. It does not mean rewriting Sideport, changing its approval policy, installing persistence, or gaining access to its credentials and trusted helpers.

Prefer forwarding a maintained provider or adopting a supported upstream feature over implementing another service inside Sideport. A separate provider runtime is acceptable when the task needs it; an always-running general-purpose runtime in the app should require a concrete benefit. MCP compatibility should prefer the July 2026 standard and later revisions where supported, with explicit version negotiation and a documented older-client fallback where needed.

## Outside the current scope

- An agent planner, chat interface, memory system, task scheduler or agent hosting service.
- A public relay service, multi-user fleet administration or an enterprise permissions platform.
- A replacement package manager, registry or catalog of custom integrations for every desktop app.
- Invisible or unattended remote access by default, or automatic restoration of an active connection after launch.
- A virtual machine, formal security certification or protection against a compromised host OS. Hard per-job resource quotas are not part of the current alpha.
- Cross-platform desktop support. Apple Silicon macOS is the current target; Intel support needs its own decision and validation.

## How to choose implementation work

Fix failures in connection state, shutdown, permissions, credentials and activity visibility before adding capabilities. Next make the baseline tools work reliably for ordinary tasks, then complete first-run setup, distribution and app updates. New features should have a concrete task they enable and a maintenance cost proportionate to that benefit.

For a proposed change, record the user task, the access it requires, how it behaves when disconnected or cancelled, and how it will be verified. If it adds a daemon, dependency, transport or policy exception, explain why the existing components cannot serve the task. Keep substantial scope changes explicit instead of introducing them through an incidental refactor.

## Alpha acceptance and evidence

A distributable alpha should let a new technical user complete setup, enable a connection, use the baseline tools, make and revoke access decisions, stop work, and later update without manually rebuilding or replacing the app. Denial must leave the requested capability ungranted. Client closure must clear its active presence without pretending the user disabled access. Controller failure and cancelled connection startup must leave access off and no orphaned owned work.

Check the protected paths, credential channels, provider admission and cleanup behavior in isolated integration tests. Verify computer use in a controlled fixture with a person present, including selector-based drag and nonstandard keyboard layouts. Render synthetic UI for documentation and inspect actual interaction states separately. A screenshot demonstrates presentation, not a live connection or a security boundary.

Publish only the claims supported by the tested build and its evidence. Developer ID signing, notarization, app self-updates and complete initial provisioning are still pending in the current alpha; see [status](status.md). These requirements define the direction of release work, not permission to weaken protections to get a release out.
