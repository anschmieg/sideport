# Live presence · 0.3.4 alpha

## Observations and scope

The pinned tunnel runtime, v0.0.15, exposes `DispatcherDetails.active` on its passive `/health/dispatcher` endpoint. Its maintained dispatcher increments the count around actual command execution and decrements it when execution returns, including failures and timeouts. Idle polling and cumulative completion counters are separate. See the [upstream health contract](https://github.com/openai/tunnel-client/blob/v0.0.15/docs/health.md) and [execution observer](https://github.com/openai/tunnel-client/blob/v0.0.15/pkg/dispatcher/internal/queue_listener.go).

Sideport uses this existing interface rather than adding a proxy, forking the gateway or inferring connections from history. The supported tunnel path is request-driven. **Connected** denotes a currently executing tunnel operation, not an idle conversation or a pooled connection to the local gateway. **Operating** denotes an executing broker tool. Independent direct SSE transports are outside this indicator's coverage.

## Implementation

- Sample live health every half-second while access is enabled. Refuse non-loopback URLs, credentials in URLs, redirects, HTTP caches, oversized/invalid replies and old snapshots. Report unknown live status instead of using retained sessions or a recency timeout.
- Publish a protected tool receipt at entry, remove it on return or failure, and validate its kernel process identity in the tray. Process death or PID reuse invalidates leftover receipts. The receipt contains no command, arguments or credentials.
- Use a local connection label, defaulting to ChatGPT for the current setup. Apply it to the popover and desktop pill. This label is neither proof of remote identity nor a count of distinct agents.
- Cancel observation across disconnect/reconnect generations. Stop clears session state and removes the credential; no presence polling occurs with access off.

## Verification

Native checks cover active versus completed counts, zero-state clearing, malformed/future/stale snapshots, invalid endpoints, tool receipt lifecycle and kernel identity mismatch. Isolated integration exercises an actual sleeping shell request, sees its receipt while executing, and confirms removal before completion is reported. A private HTTP fixture exercises the native health reader through positive, zero, stale and redirect responses.

`scripts/tunnel_presence.py` additionally runs the packaged official tunnel against synthetic local control-plane and MCP servers. It holds a real forwarded request, checks a positive count with Sideport's native reader, completes delivery and checks an immediate return to zero. No real runtime key or account traffic is used.

Package checks retain controller, clipboard, Keychain, screen-service and environment isolation probes. Documentation renders the native UI with synthetic data. The pinned runtime's live health endpoint was also read without altering the installed connection. No real desktop input, capture or native permission request was needed for this change.

The half-second sampling interval means very short calls can finish between samples. Missing or unhealthy tunnel observations do not authorize any work, and a valid tool receipt can still show Operating while the health surface is unavailable. The previous 0.3.3 two-minute observation window is removed. Baseline GUI validation remains recorded separately; this patch does not claim a new complete GUI audit.
