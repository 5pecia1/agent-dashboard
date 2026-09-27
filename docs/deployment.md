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
2. Tag the commit with the app version **only in the public `agent-dashboard` checkout**. If the change was made in the development source repository, export it to the public repository through Copybara first. Do not push app tags to the private development repository. For app version `0.1.1`, run:

   ```sh
   git switch main
   git pull --ff-only
   git tag v0.1.1
   git push origin v0.1.1
   ```

3. Confirm that the build, GitHub Release publication, and Pages deployment all succeed in Actions. Creating the GitHub Release alone does not complete the web deployment.

[`release-product.yml`](../.github/workflows/release-product.yml) builds and checks the web app on Ubuntu and the macOS app on macOS 15. It also runs the web app in Chromium. After uploading the verified web archive and macOS ZIP to GitHub Releases, it downloads the published web archive, verifies its SHA256 and source metadata, and deploys those same bytes to Pages.

Stable versions such as `v0.1.1` update the production web app. Prereleases such as `v0.2.0-alpha.1` deploy to a preview URL and leave production unchanged. The server package uses a separate `server-vVERSION` release process.

The release's `SHA256SUMS` and `release.json` record archive hashes and the source commit. The web app's `/release-manifest.json` also identifies the deployed tag and commit; the production deployment job must verify these values to succeed. Current macOS releases are not Developer ID signed or notarized, so Gatekeeper may block launch. The actual signing status is recorded in the release metadata.

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
