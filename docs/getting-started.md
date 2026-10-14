# Sideport

Computer use for remote agents. Early alpha 0.3.2 · Apple Silicon · macOS 15 or later.

This configured alpha has passed isolated file, shell, provider, lifecycle and security checks, plus a controlled computer-use test. It remains an early alpha: live Smithery forwarding is unverified because the installed manager returns an error, and advanced file-picker handling has not had a live GUI test.

- Open Sideport and turn on **Allow connections** to make the Mac available through your existing tunnel.
- The menu-bar icon is an incoming arrow through an open port. An orange pill means the gateway reports a current agent session; tunnel readiness alone does not color it. The gateway reports sessions after their first tool call, so handshake-only clients are not yet shown.
- Desktop tools show an orange, click-through outline and a small client/Stop pill before proceeding. The indicator stays for eight seconds between actions, follows the selected window, and uses the screen edge for desktop-wide or unresolved targets. Client names are reported labels, not authenticated identities. If several clients are connected, the pill says Multiple remote agents rather than guessing which is acting. Stop disconnects all Sideport access, including running work.
- Turn the switch off or quit Sideport to stop access. The app starts disconnected and launches no helper services while off.
- File and shell tools use your approved folders and development caches. Additional locations require your local decision. **Remember this location** restores an approval when you reconnect.
- Screen control needs a separate approval. It can interact with apps beyond the file sandbox; it expires when you disconnect. Grant macOS Accessibility, Screen Recording and event-input permissions to Sideport when requested. The app waits briefly for native requests; macOS may still require reconnecting to refresh a cached grant. Permission checks do not initiate screen-capture probes.
- Ordinary shell commands have network access. Flagged commands use the configured reviewer; low-confidence decisions still ask you. Unknown or destructive authenticated GitHub changes always need your approval.
- Shell and provider sandboxes block local Unix sockets except the macOS DNS service, and block GUI/clipboard services. Use the separately approved computer tools for graphical tasks.
- Dynamic npm servers require an exact version and local approval. Install scripts are disabled, high/critical audit findings block admission, and the running server has no network access. Cached audits refresh after a day; unavailable or failing audits block refresh. Node is downloaded only when this feature needs it.
- Existing agents-dev and Smithery connections can be forwarded after approval. Their configured service credentials are used only for that connection. Sign in to the manager locally first.
- **Check for updates** updates standalone dependencies with verified checksums and compatibility checks. Peekaboo is compiled into Sideport and updates with the app.

App self-updates and Developer ID distribution are still being developed. For an existing local installation, replace the app as follows: disconnect Sideport, quit it, unzip the new release and move **Sideport.app** into **Applications**, replacing the old copy. Open it from Applications. Settings and remembered folders live in Application Support/Sideport and are retained. Keep the same signing identity when rebuilding locally so macOS recognizes the app’s permissions.

ChatGPT is one example client. Keep its existing Sideport tunnel connector; this release uses the same tunnel and connection settings.
