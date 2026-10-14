# Install and configure the alpha

This is a technical preview for Apple Silicon Macs running macOS 15 or later. The ZIP bundles the native app and its runtime tools. It does not include a tunnel, account credentials or an automatic setup wizard.

## Install or replace the app

Download the ZIP and checksum from the matching [GitHub prerelease](https://github.com/anschmieg/sideport/releases). For an existing installation, finish agent work, disable access and quit Sideport before replacing it. Unzip the archive, move **Sideport.app** into **Applications**, and open it there. It starts with access off; existing settings remain in Application Support.

The alpha is signed with a local self-signed identity, not Apple Developer ID, and is not notarized. If macOS blocks the download, use its per-app approval only if you choose to trust this preview, following [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Keep Gatekeeper enabled. The alpha does not require importing a signing certificate or changing global trust settings.

## Provision a new connection

Existing configured installations can skip this section. First open Sideport once, leave access off and quit it; this creates its runtime directory and local gateway configuration.

Create or select a tunnel in [OpenAI Platform's tunnel settings](https://platform.openai.com/settings/organization/tunnels), associate it with the intended client workspace, and create a restricted runtime key. Tunnel administration and client permissions are separate; use the roles and association instructions in the [official tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels). Use a runtime key with the required tunnel access, not an organization admin key.

Store that key locally as a single line in:

```text
~/Library/Application Support/Sideport/work/tunnel-runtime.key
```

Enter the key in a local editor rather than a chat, shell argument or public issue. Protect the file with permissions `0600`. Keep Sideport's controller directory private; never grant it to an agent.

Create `~/Library/Application Support/Sideport/work/tunnel-profiles/macbook-mcpproxy.yaml` using this template. Replace `YOURNAME` with the Mac account's home-directory name and `YOUR_TUNNEL_ID` with the provisioned tunnel ID. File references need absolute paths. A fresh installation's gateway listens on `127.0.0.1:18089`; if you changed it, use the IPv4-loopback address from `work/mcpproxy-pilot/config.json`.

```yaml
config_version: 1
control_plane:
  base_url: "https://api.openai.com"
  tunnel_id: "YOUR_TUNNEL_ID"
  api_key: "file:/Users/YOURNAME/Library/Application Support/Sideport/work/tunnel-runtime.key"
health:
  listen_addr: "127.0.0.1:0"
log:
  level: warn
  format: json
mcp:
  server_urls:
    - channel: main
      url: "http://127.0.0.1:18089/mcp"
  extra_headers:
    X-API-Key: "file:/Users/YOURNAME/Library/Application Support/Sideport/work/mcpproxy-runtime.key"
```

Protect the profile with permissions `0600` as well. Sideport creates the restricted local `mcpproxy-runtime.key` when you enable access; do not replace this reference with the gateway's administrator key. The runtime profile schema and secret references are documented [upstream](https://github.com/openai/tunnel-client/blob/v0.0.15/docs/configuration.md).

Open Sideport and enable **Allow connections**. Use the client product's tunnel connection option and select the same tunnel, following its current setup instructions. For ChatGPT, see the [official connection steps](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels#connect-from-chatgpt). The current label defaults to ChatGPT; a different client can set `work/client-label.json` to `{"label":"Your client"}` locally.

Verify a harmless request, such as listing approved locations. Setup is complete only after a client tool call succeeds. If it fails, disable access and inspect the local connection log; redact keys and private details before reporting a problem.

## Daily use and updates

Grant macOS recording and Accessibility permissions only when requesting computer control. The [user guide](https://github.com/anschmieg/sideport/blob/main/docs/getting-started.md) explains scopes, approvals, the activity pill and Stop. Enabling access starts the connection; stopping or quitting ends it.

App self-updates are not shipped yet. **Check for updates** updates standalone runtime tools, not the app. Install subsequent alpha ZIPs by disconnecting and replacing the app. A future Developer ID identity transition may require macOS permissions to be granted again.
