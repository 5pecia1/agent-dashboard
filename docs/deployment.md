# Web deployment and app releases

Agent Dashboard builds through GitHub Actions in the public repository and deploys to Cloudflare Pages. The web app is available at [agent-dashboard.5pecia1.dev](https://agent-dashboard.5pecia1.dev). Enter your server URL and client token in the browser to connect. Deploying the web app does not deploy or update the Worker server.

To install the app or deploy your own server, follow the [quickstart](quickstart.md). This guide covers maintaining the public web app and releases. GitHub Raw serves `install.sh` from the public repository; GitHub Releases provides installation archives and checksums. The installer and installation archives are not copied to Pages, so web redeployments and rollbacks are independent of installer updates.

## Initial setup: connect a Cloudflare token

The repository already has a Pages project, deployment variables, and a token configured. Follow these steps when replacing the token or connecting a new repository.

1. In [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens), select **Create Token → Create Custom Token**. Grant **Account / Cloudflare Pages / Edit** and limit Account Resources to the account used for deployment.
2. Copy the generated token and open the [cloudflare-pages environment in GitHub](https://github.com/5pecia1/agent-dashboard/settings/environments/22852585188/edit). Select **Add environment secret**, name it `CLOUDFLARE_API_TOKEN`, and paste the token. Keep the token out of source code and issues.
3. To deploy an existing release, follow [Redeploy an existing release](#redeploy-an-existing-release). To deploy a new version, bump the version and push its tag.
4. Confirm that the Actions run succeeds through its final `deploy` job.

When moving to another account or project, also update the following variables in the same GitHub environment. Set the Pages project's production branch to `main`. If the environment restricts deployment refs, allow the `main` branch and `v*` tags.

| Variable | Value |
|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | The ID of the account containing the Pages project |
| `CLOUDFLARE_PAGES_PROJECT` | `agent-dashboard` |
| `CLOUDFLARE_PAGES_URL` | `https://agent-dashboard.5pecia1.dev` |

The deployment uses the `CLOUDFLARE_API_TOKEN` GitHub secret together with all three variables. If configuration is missing, the deployment job fails and identifies the missing names. `CLOUDFLARE_PAGES_URL` is the production URL checked after deployment. If you do not use a custom domain, enter the actual `*.pages.dev` URL assigned by Pages.

## Connect a custom domain

`agent-dashboard.5pecia1.dev` is connected to the same Pages project. The existing [agent-dashboard-qgd.pages.dev](https://agent-dashboard-qgd.pages.dev) URL also remains available. To add a domain and change the primary URL, complete this setup once.

1. In Cloudflare, open **Workers & Pages → agent-dashboard → Custom domains → Set up a domain** and register the new hostname. Connect the domain to the Pages project as well as creating its DNS record.
2. Check the DNS record. The current configuration is **CNAME**, name **agent-dashboard**, target **agent-dashboard-qgd.pages.dev**, proxy **Proxied**, and TTL **Auto**. For another hostname, change the record name accordingly. Do not include `https://` in the CNAME target.
3. Once the domain status is **Active** and the new HTTPS URL works, update `CLOUDFLARE_PAGES_URL` in GitHub's `cloudflare-pages` environment.
4. Add the new web origin to the connected server's CORS allowlist. Check the production version at `/release-manifest.json` on the new domain.

Wrangler continues to deploy files to the same Pages project. To connect a domain from the CLI, use the Pages API for the domain and the DNS API for DNS records. A one-time token that also changes DNS needs **Zone / DNS / Edit** for the relevant zone. Subsequent GitHub Actions deployments only need the existing **Account / Cloudflare Pages / Edit** permission. See [Cloudflare's custom domain documentation](https://developers.cloudflare.com/pages/configuration/custom-domains/) for the connection procedure.

Browser settings are stored per origin. Enter your server URL and token again when opening the new domain for the first time. Settings for the previous URL remain in place.

## Bump the version and deploy

1. Update the workspace version in `app/Cargo.toml`, along with `version` and the numeric `msix_version` in `app/flutter_app/pubspec.yaml`. Commit changed lockfiles as well, and merge into `main` after review.
2. Push a version tag such as `v0.1.11` on that commit. The release workflow builds the public web app and the universal macOS archive. The macOS job signs with Developer ID, submits the signed app to Apple for notarization, and verifies the extracted universal ZIP. New releases include Apple’s acceptance record in `Apple-notarization.json`.
3. The publish job uses the verified bytes from Actions. Stable releases deploy to the production Pages site. Prereleases deploy to a preview. Check the deployed web manifest after publication.

### Configure signing in GitHub Actions

Create the `macos-signing` environment. Allow the release tags and trusted signing rehearsal branches. Set `APPLE_TEAM_ID` to the expected ten-character Apple Developer Team ID. Add the following environment secrets.

| Environment secret | Value |
|---|---|
| `CI_SIGNING_P12` | Base64 of a password-protected PKCS#12 export containing the Developer ID Application identity and its private key |
| `CI_SIGNING_P12_PASSWORD` | Password for that PKCS#12 export |
| `ASC_KEY_ID` | Identifier of the App Store Connect team API key used to submit and check notarization |
| `ASC_ISSUER_ID` | Issuer UUID for the same API key |
| `ASC_PRIVATE_KEY` | Original multiline PEM contents of its downloaded `.p8` file |
| `SPARKLE_PRIVATE_KEY` | Base64 Ed25519 private seed exported by Sparkle for the public Agent Dashboard update channel |

The signing step imports the Developer ID identity into a temporary keychain. The dedicated Developer-role API key authenticates the notarization request. Apple’s log must report acceptance of the exact ZIP submitted. The job staples the ticket, packages the app, and reopens the final ZIP to check its signature, team, bundle ID, signed source commit, Gatekeeper assessment and architecture. `release.json` identifies the distributed ZIP; `Apple-notarization.json` identifies the pre-staple upload. [Apple team API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/) · [Apple Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)

An owner can rehearse signing on a trusted branch at a specific pushed commit. The rehearsal builds the real archive and checks the signed universal ZIP and Apple receipt. The full app tests run in PR checks and tag releases. Only a release tag can publish the GitHub release and deploy Pages.

```sh
gh workflow run release-product.yml --ref main -f sign_only=true -f expected_sha="$(git rev-parse HEAD)"
```

On a failure after upload starts, select **Re-run failed jobs** on the same Actions run within one day. The macOS job restores the signed upload and available submission metadata for that run and resumes the original request. A new workflow dispatch creates a separate run. A retry of an already-published release downloads and verifies the published macOS bytes. Historical assets remain immutable.

### Publish a Sparkle update

Increase both the app version and its numeric Flutter build number before releasing. Keep the public key in the app’s `SUPublicEDKey` consistent across updates. Store the corresponding private key only in the public product’s signing environment. The macOS CI uses the pinned Sparkle 2.10.1 `sign_update` tool, passes its key on standard input, and verifies the signature against the public key from the final ZIP. The signing rehearsal creates an appcast artifact for inspection.

Each GitHub app release includes `appcast.xml`. Its enclosure identifies the immutable release ZIP, its byte count, and its Ed25519 signature. The stable updater reads [the production appcast](https://agent-dashboard.5pecia1.dev/appcast.xml). Once the release exists on GitHub, a production Pages deployment downloads and checks the stable release ZIP and feed. It selects the highest published stable build independently of the web version being deployed. Redeploying an older web version carries that same stable Mac feed forward. Prerelease and sign-only runs never promote an update to the production channel.

For local packaging, sign the exact distributed ZIP after notarization. `sparkle_release.py tools --output DIR` installs the checksum-pinned tools. Set `SPARKLE_BIN_DIR` to that directory and provide `SPARKLE_PRIVATE_KEY` through a protected environment. Run `sparkle_release.py sign --help` for the archive, product identity, HTTPS enclosure URL and output arguments. The command prints the signature, archive SHA256, size, display version and build number. [Sparkle publishing guide](https://sparkle-project.org/documentation/publishing/)

### Sign on a development Mac

Use a fresh public checkout of the reviewed commit. Replace the example tag with the new version. Preserve the archive directory until Gatekeeper and release verification have passed.

```sh
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
release_tag=v0.1.11
source_commit=$(git rev-parse HEAD)
test -z "$(git status --porcelain)"
python3 app/scripts/version_check.py --tag "$release_tag"
release_dir="$HOME/Library/Developer/Xcode/Archives/Agent-Dashboard-$release_tag-$source_commit"
app_archive="$release_dir/Agent Dashboard.xcarchive"
(cd app && mise install && mise exec -- python3 scripts/macos_distribution.py archive \
  --project flutter_app --archive "$app_archive" \
  --bundle-id io.github.5pecia1.mydashboard --source-commit "$source_commit")
python3 app/scripts/macos_distribution.py cloud --submit \
  --archive "$app_archive" --output "$release_dir/Agent Dashboard.app" \
  --bundle-id io.github.5pecia1.mydashboard --team-id "$APPLE_TEAM_ID" --source-commit "$source_commit"
```

The archive records the commit before it goes to Apple. Xcode uploads with your team's automatic Developer ID signing. If processing is pending, repeat the `cloud` command with the same archive and omit `--submit`. Xcode downloads the notarized app and attaches the ticket. The tool checks Apple's submission ID, the `Accepted` result, and the app's code signature, bundle ID, team, hardened runtime, timestamp and Gatekeeper assessment before emitting the app.

### Stage the signed release and push the tag

```sh
python3 app/scripts/release_product.py package --platform macos \
  --source "$release_dir/Agent Dashboard.app" --team-id "$APPLE_TEAM_ID" \
  --arch "$(uname -m)" --tag "$release_tag" --commit "$source_commit" --output "$release_dir/assets"
```

The local ZIP can be inspected with the same `verify-macos` command used by the release workflow.

Release retries verify an existing published ZIP before reusing it. Historical versions through v0.1.10 retain their original signing status.

### Use a local Developer ID certificate

A signing Mac with a matching **Developer ID Application** private key and a Keychain notary profile can also sign a built app directly. Obtain the certificate fingerprint from `security find-identity -v -p codesigning` and set `SIGNING_IDENTITY`. Set `NOTARY_PROFILE` to an existing profile or create one interactively with `xcrun notarytool store-credentials "$NOTARY_PROFILE"`. With the version, source commit, and fresh output directory from the preparation step, run the following commands before staging the ZIP. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

```sh
python3 app/scripts/macos_distribution.py preflight \
  --bundle-id io.github.5pecia1.mydashboard --team-id "$APPLE_TEAM_ID" \
  --identity "$SIGNING_IDENTITY" --notary-profile "$NOTARY_PROFILE"
(cd app && mise install && mise run deps && mise run build)
python3 app/scripts/macos_distribution.py sign \
  --source app/flutter_app/build/macos/Build/Products/Release/my_dashboard.app \
  --output "$release_dir/Agent Dashboard.app" --source-commit "$source_commit" \
  --bundle-id io.github.5pecia1.mydashboard --team-id "$APPLE_TEAM_ID" \
  --identity "$SIGNING_IDENTITY" --notary-profile "$NOTARY_PROFILE" \
  --entitlements app/flutter_app/macos/Runner/Release.entitlements
```

## Redeploy an existing release

1. Open [Deploy published Agent Dashboard](https://github.com/5pecia1/agent-dashboard/actions/workflows/deploy-web.yml).
2. Select **Run workflow**, choose branch `main`, and set `tag` to the existing version to deploy, such as `v0.1.1`. Enable `allow_rollback` only when intentionally returning to an earlier version.
3. Confirm that the `deploy` job and its final **Confirm the deployed production manifest** step succeed. Prereleases deploy to preview URLs, so the production confirmation step is skipped.

You can also run the same workflow from the CLI:

```sh
gh workflow run deploy-web.yml --repo 5pecia1/agent-dashboard --ref main -f tag=v0.1.1
```

This workflow uses the latest deployment code from `main`, verifies the existing release's hashes and source, and reuses its artifacts. Selecting **Re-run failed jobs** on a failed run for an older tag also reruns the older workflow code. Use the procedure above when deployment code has changed. To change the published build itself, create a new version. For an intentional rollback from the CLI, add `-f allow_rollback=true`.

## Deploy directly to your own Pages project

Install [mise](https://mise.jdx.dev), Node.js 22 or newer, and the tools pinned in `app/.mise.toml`, then run from the repository root:

```sh
cd app
mise install
mise run deps
mise run tools:web
mise run build:web
cd ..
npm --prefix server ci
server/node_modules/.bin/wrangler login
server/node_modules/.bin/wrangler pages project create YOUR_PROJECT --production-branch main
server/node_modules/.bin/wrangler pages deploy app/flutter_app/build/web --project-name YOUR_PROJECT --branch main
```

The app is served at the domain root. Deployment includes a `_headers` file that makes browsers revalidate files for new versions. You can connect a custom domain to the same Pages project. If your server uses a CORS allowlist, add the web app's origin. Optional integrations called directly from the browser must also satisfy each service's CORS policy. See [Cloudflare's Direct Upload documentation](https://developers.cloudflare.com/pages/get-started/direct-upload/) for project setup details.
