# Usage integrations

Agent Dashboard includes TeamClaude and Devin usage integrations. Distribution files contain no account credentials; each user connects their own services in Settings. An unconfigured integration makes no requests.

1. Open **Settings** and expand TeamClaude or Devin.
2. Enter and save your service URL and API key. TeamClaude accepts a server root URL or a `/teamclaude/dashboard` URL and an API key. Devin accepts your API server URL and key.
3. Check the usage values and last fetch time in the home screen's usage panels. The same usage information is available in the macOS tray.
4. To disconnect, clear that integration's settings. Your dashboard server, session, and notification settings remain unchanged.

Grok usage is available in the macOS app. Open **Settings**, expand **Grok**, and turn usage on. The app reads the Grok CLI login on that Mac and requests the usage figure itself. It does not store the login token. The web app does not call the usage endpoint. The endpoint is the one the Grok CLI uses and is not a public API, so a CLI change can require an integration update.

Grok Bot weekly usage is a separate switch in that same section. The macOS app reads the Grok Bot login already on that Mac and requests that usage figure itself. It does not store the login token. The web app does not call that endpoint. The endpoint is the one the Grok Bot app uses and is not a public API, so an app update can require an integration update.

The web app requires HTTPS service URLs, and each integration server must allow the web app's origin through CORS. A public HTTPS page may be unable to call an HTTP address on a private network directly. In that case, use the macOS app or configure an HTTPS relay that you operate. The dashboard server does not store integration keys on your behalf or automatically proxy requests.

Keys are stored in the current device's app settings or the browser's localStorage. Do not include keys entered in Settings or real account responses in issues or screenshots. Devin usage relies on a CLI-compatible query endpoint separate from the official public API, so provider changes may require integration updates. Devin session-status hook support is independent of usage queries.
