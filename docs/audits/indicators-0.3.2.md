# Sideport 0.3.2 activity indicators

| State | Indicator |
|---|---|
| Off, starting, or available without a confirmed agent session | Neutral open-port/arrow icon; no On/Off text |
| Current agent session reported by the gateway | Orange menu-bar pill |
| Desktop tool activity | Orange click-through window outline and nonactivating client/Stop pill |
| Desktop-wide or unresolved target | Screen-edge outline |
| Stop | Hide the overlay and disconnect all Sideport access |

The menu indicator reads the authenticated local gateway's active sessions, filters for Sideport's scoped token and the current connection's start time, and ignores old, closed and administrator sessions. Lookup failure leaves the icon neutral. The [gateway session API](https://docs.mcpproxy.app/api/rest-api/) omits handshake-only sessions until their first tool call; this release therefore cannot indicate an idle handshake immediately.

Desktop activity is published in the protected approval directory, with the broker's process-generation identity and a unique action ID. Production desktop actions wait for the tray's matching visibility acknowledgement and refuse to proceed if it does not arrive. Permission approval alone does not activate the overlay. It remains visible for eight seconds between actions and clears on disconnect or broker exit. Client names are untrusted reported labels; when several sessions are present the overlay says Multiple remote agents instead of assigning the action to one of them.

Validation: 21 native regression groups; signed sandbox/gateway packaging checks; missing-indicator refusal and matching-acknowledgement admission; authenticated external MCP session appearance and transport-close removal; tray toggle, disconnect and force-quit cleanup; click-through outline, nonactivating pill and Stop callback. The preview renders only Sideport's own views. No additional desktop capture audit or screen permission request was run. The installed app and live connection were not changed.

The native migration's existing limitations, including live Smithery forwarding and advanced file-picker verification, remain documented in the earlier audit follow-up.
