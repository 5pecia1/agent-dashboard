# `web/vendor/`: vendored Firebase JavaScript SDK

This directory contains third-party SDK files with only the transformations listed below. Keep application code elsewhere; the web push token adapter is one level up at `web/push_token_bridge.js`.

## Why vendor instead of using a CDN?

1. **Offline behavior.** `web/my_dashboard_service_worker.js` caches only same-origin GET requests. Cross-origin responses are opaque and cannot be included in the shell cache. An SDK fetched from a CDN is unavailable on an offline reload.
2. **COEP.** The local verification server (`app/scripts/serve_web.py`) and deployment headers can enable `Cross-Origin-Embedder-Policy: require-corp`. Cross-origin scripts without CORP headers are then blocked.
3. **Supply chain.** The upstream bytes are pinned by the SHA-256 values below.

## Upstream files

| File | Upstream | Upstream SHA-256 before transformation |
|---|---|---|
| `firebase-app.js` | `https://www.gstatic.com/firebasejs/12.18.0/firebase-app.js` | `2fddac0600772c36b848b6b9651e52d00eb8f0a3656b5c24246cd8380b0e452a` |
| `firebase-messaging.js` | `https://www.gstatic.com/firebasejs/12.18.0/firebase-messaging.js` | `706471bb9556d9d1db301c6f48b015cbe507b80cdc6b6a07a438c1fbc53db6f6` |

License: **Apache-2.0** (Copyright Google LLC). The license text is available at <https://www.apache.org/licenses/LICENSE-2.0>. Each file also carries a license banner at the beginning.

## Applied transformations

1. Both files have a leading comment with the license and provenance shown in the table. A leading comment does not change ESM module semantics.
2. The **single import specifier** in `firebase-messaging.js` uses a same-origin relative path. Without this change, executing the module would fetch from gstatic again.

   ```diff
   -import{...}from"https://www.gstatic.com/firebasejs/12.18.0/firebase-app.js";
   +import{...}from"./firebase-app.js";
   ```

   The two remaining `gstatic.com` strings in `firebase-app.js` are SDK package-name constants (`name$q` and the logger name), not network references. Leave them unchanged.

## Update procedure

```sh
V=<new-version>
curl -sSf "https://www.gstatic.com/firebasejs/$V/firebase-app.js"       -o /tmp/fb-app.orig.js
curl -sSf "https://www.gstatic.com/firebasejs/$V/firebase-messaging.js" -o /tmp/fb-msg.orig.js
shasum -a 256 /tmp/fb-app.orig.js /tmp/fb-msg.orig.js   # Update the table above.
# Add the banners and change only the import specifier shown above to './firebase-app.js'.
# Then run: python3 app/scripts/web_push_smoke.py to recheck both registrations and offline behavior.
grep -o '[^"]*gstatic\.com[^"]*' firebase-messaging.js   # Fail if any match remains outside the banner.
```

The two files depend on matching versions. **Always download both at the same version.**
