# 웹 배포와 앱 릴리스

Agent Dashboard는 공개 저장소의 GitHub Actions에서 빌드하고 Cloudflare Pages에 배포합니다. 웹 주소는 [agent-dashboard.5pecia1.dev](https://agent-dashboard.5pecia1.dev)입니다. 브라우저에서 자신의 서버 주소와 클라이언트 토큰을 입력해 연결합니다. 웹 배포는 Worker 서버를 배포하거나 갱신하지 않습니다.

앱을 설치하거나 자신의 서버를 배포하려면 [quickstart](quickstart.md)를 따릅니다. 이 문서는 공개 웹과 릴리스를 관리하는 절차입니다. `install.sh`는 공개 저장소의 GitHub Raw에서 제공하며, 설치 파일과 checksum은 GitHub Releases에서 제공합니다. Pages에는 설치기나 설치용 archive를 복사하지 않으므로 웹 재배포·롤백과 설치기 갱신은 서로 독립적입니다.

## 처음 한 번: Cloudflare 토큰 연결

현재 저장소에는 Pages 프로젝트, 배포 변수와 토큰이 설정되어 있습니다. 토큰을 교체하거나 새 저장소를 연결할 때 다음 순서로 등록합니다.

1. [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens)에서 **Create Token → Create Custom Token**을 선택합니다. 권한은 **Account / Cloudflare Pages / Edit**, Account Resources는 배포할 계정 하나로 제한합니다.
2. 생성된 토큰을 복사한 뒤 [GitHub의 cloudflare-pages 환경](https://github.com/5pecia1/agent-dashboard/settings/environments/22852585188/edit)을 엽니다. **Add environment secret**으로 이름을 `CLOUDFLARE_API_TOKEN`으로 지정하고 토큰을 붙여 넣습니다. 토큰을 소스 코드나 이슈에 남기지 않습니다.
3. 기존 릴리스를 배포하려면 아래의 **기존 릴리스 다시 배포하기**를 따릅니다. 새 버전을 배포하려면 버전을 올리고 태그를 push합니다.
4. 해당 Actions 실행의 마지막 `deploy` 작업까지 성공했는지 확인합니다.

다른 계정이나 프로젝트로 옮길 때는 같은 GitHub 환경에서 다음 변수도 수정합니다. Pages 프로젝트의 production branch는 `main`으로 설정합니다. 환경에 배포 참조 제한을 적용했다면 `main` 브랜치와 `v*` 태그를 허용해야 합니다.

| 변수 | 값 |
|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | Pages 프로젝트가 있는 계정 ID |
| `CLOUDFLARE_PAGES_PROJECT` | `agent-dashboard` |
| `CLOUDFLARE_PAGES_URL` | `https://agent-dashboard.5pecia1.dev` |

GitHub의 비밀값 `CLOUDFLARE_API_TOKEN`과 위 변수 세 개를 함께 사용합니다. 설정이 빠지면 배포 작업이 누락된 이름을 표시하며 실패합니다. `CLOUDFLARE_PAGES_URL`은 배포 후 확인할 운영 주소입니다. 사용자 지정 도메인을 쓰지 않는다면 Pages가 실제로 발급한 `*.pages.dev` 주소를 넣습니다.

## 사용자 지정 도메인 연결하기

현재 `agent-dashboard.5pecia1.dev`는 같은 Pages 프로젝트에 연결되어 있습니다. 기존 [agent-dashboard-qgd.pages.dev](https://agent-dashboard-qgd.pages.dev) 주소도 계속 사용할 수 있습니다. 새 도메인을 추가하고 기본 접속 주소를 바꾸려면 다음을 한 번 설정합니다.

1. Cloudflare에서 **Workers & Pages → agent-dashboard → Custom domains → Set up a domain**을 열어 새 호스트 이름을 등록합니다. DNS 레코드만 만들지 말고 Pages 프로젝트에도 도메인을 연결합니다.
2. DNS 레코드를 확인합니다. 현재 설정은 **CNAME**, 이름 **agent-dashboard**, 대상 **agent-dashboard-qgd.pages.dev**, 프록시 **켜짐**, TTL **자동**입니다. 다른 호스트를 연결할 때는 레코드 이름을 해당 호스트로 바꿉니다. CNAME 대상에는 `https://`를 붙이지 않습니다.
3. 도메인 상태가 **Active**가 되고 새 HTTPS 주소가 열리면 GitHub의 `cloudflare-pages` 환경에서 `CLOUDFLARE_PAGES_URL`을 새 주소로 바꿉니다.
4. 연결할 서버의 CORS 허용 목록에도 새 웹 origin을 추가합니다. 새 주소의 `/release-manifest.json`에서 운영 버전을 확인합니다.

Wrangler는 기존과 같이 같은 Pages 프로젝트에 파일을 배포합니다. 도메인을 CLI로 연결하려면 Pages API를 사용하고 DNS 레코드는 DNS API로 설정합니다. DNS까지 API로 변경하는 일회성 토큰에는 해당 zone의 **Zone / DNS / Edit** 권한이 필요합니다. 이후 GitHub Actions 배포 토큰은 기존 **Account / Cloudflare Pages / Edit**만 유지하면 됩니다. [Cloudflare 사용자 지정 도메인 문서](https://developers.cloudflare.com/pages/configuration/custom-domains/)에 연결 절차가 있습니다.

브라우저 설정은 주소별로 저장됩니다. 새 도메인을 처음 열 때는 서버 주소와 토큰을 다시 입력합니다. 기존 주소의 설정은 그대로 남습니다.

## 버전을 올려 배포하기

1. `app/Cargo.toml`의 workspace 버전과 `app/flutter_app/pubspec.yaml`의 `version`, 숫자 형식의 `msix_version`을 함께 올립니다. 변경된 lockfile도 커밋하고 검토를 거쳐 `main`에 병합합니다.
2. **공개 `agent-dashboard` checkout에서만** 해당 커밋에 앱 버전 태그를 붙입니다. 개발 정본에서 변경했다면 먼저 Copybara로 공개 저장소에 반영합니다. 비공개 `my-dashboard`에 앱 태그를 push하지 않습니다. 앱 버전이 `0.1.1`이라면 다음과 같이 실행합니다.

   ```sh
   git switch main
   git pull --ff-only
   git tag v0.1.1
   git push origin v0.1.1
   ```

3. Actions에서 빌드, GitHub Release 발행, Pages 배포가 모두 성공했는지 확인합니다. GitHub Release만 만들어졌다면 웹 배포는 아직 끝난 것이 아닙니다.

[`release-product.yml`](../.github/workflows/release-product.yml)은 Ubuntu에서 웹을, macOS 15에서 앱을 빌드하고 검사합니다. 웹은 Chromium에서도 실행해 확인합니다. 검증한 웹 아카이브와 macOS ZIP을 GitHub Release에 올린 뒤, 게시된 웹 아카이브를 다시 내려받아 SHA256과 소스 정보를 확인하고 그대로 Pages에 배포합니다.

`v0.1.1` 같은 정식 버전은 운영 웹을 갱신합니다. `v0.2.0-alpha.1` 같은 사전 버전은 미리보기 주소에 배포하며 운영 웹을 유지합니다. 서버 패키지는 별도의 `server-vVERSION` 릴리스 절차를 사용합니다.

릴리스의 `SHA256SUMS`와 `release.json`에는 아카이브 해시와 소스 커밋이 기록됩니다. 웹의 `/release-manifest.json`에서도 배포된 태그와 커밋을 확인할 수 있으며, 운영 배포 작업이 이 값까지 확인해야 성공합니다. 현재 macOS 릴리스에는 Developer ID 서명과 공증을 제공하지 않으므로 Gatekeeper가 실행을 막을 수 있습니다. 실제 서명 상태는 릴리스 메타데이터에 기록됩니다.

## 기존 릴리스 다시 배포하기

1. [Deploy published Agent Dashboard](https://github.com/5pecia1/agent-dashboard/actions/workflows/deploy-web.yml)를 엽니다.
2. **Run workflow**에서 브랜치를 `main`, `tag`를 배포할 기존 버전(예: `v0.1.1`)으로 지정하고 실행합니다. `allow_rollback`은 의도적으로 이전 버전으로 되돌릴 때만 켭니다.
3. `deploy` 작업과 마지막 **Confirm the deployed production manifest** 단계의 성공을 확인합니다. 사전 버전은 미리보기로 배포되므로 운영 확인 단계가 생략됩니다.

CLI로도 같은 작업을 실행할 수 있습니다.

```sh
gh workflow run deploy-web.yml --repo 5pecia1/agent-dashboard --ref main -f tag=v0.1.1
```

이 workflow는 `main`의 최신 배포 코드를 사용하며 기존 릴리스의 해시와 소스를 확인한 뒤 같은 산출물을 재사용합니다. 이전 태그의 실패한 실행에서 **Re-run failed jobs**를 누르면 이전 workflow 코드도 그대로 실행되므로, 배포 코드가 수정됐을 때는 위 절차를 사용합니다. 게시된 빌드 자체를 바꾸려면 새 버전을 만듭니다. CLI에서 의도적으로 이전 버전으로 되돌릴 때는 `-f allow_rollback=true`를 추가합니다.

## 자신의 Pages 프로젝트에 직접 배포하기

[mise](https://mise.jdx.dev), Node.js 22 이상, `app/.mise.toml`에 고정된 도구를 설치한 뒤 저장소 루트에서 실행합니다.

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

앱은 도메인의 루트 경로에서 제공합니다. 새 버전의 파일을 재확인하도록 하는 `_headers` 파일도 함께 배포합니다. 사용자 지정 도메인은 같은 Pages 프로젝트에 연결할 수 있습니다. 서버가 CORS 허용 목록을 사용한다면 웹 주소를 추가해야 하며, 브라우저에서 직접 연결하는 선택 연동도 해당 서비스의 CORS 정책을 따릅니다. 자세한 프로젝트 설정은 [Cloudflare Direct Upload 문서](https://developers.cloudflare.com/pages/get-started/direct-upload/)를 참고합니다.
