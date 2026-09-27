# 단독 Worker 예제

새 서버는 릴리스의 설치용 archive로 시작할 수 있습니다. Node.js 22 이상과 npm을 설치한 뒤 실행합니다. 현재 서버는 alpha만 있으므로 `--prerelease`를 명시합니다.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --prerelease
cd agent-dashboard-server
npm ci
```

버전을 지정하려면 `--prerelease` 대신 `--version 0.1.0-alpha.2`를 사용합니다. 생성된 프로젝트의 `README.md` 또는 [설치 후 배포 안내](STARTER.md)를 따라 Cloudflare 로그인, D1 생성, 토큰 설정, 배포를 진행합니다. 소스 저장소를 clone하거나 서버를 빌드할 필요가 없습니다. 기존 서버 폴더에는 덮어쓰지 않습니다.

## 소스에서 예제 생성하기

이 폴더 자체는 생성용 템플릿이므로 여기에서 곧바로 `npm ci`를 실행하지 않습니다. 패키지를 수정해 검증할 때는 저장소 루트에서 독립 프로젝트를 생성합니다.

```sh
npm --prefix server ci
npm --prefix server run build
(cd server && npm pack --pack-destination /tmp)
node server/scripts/create-example.mjs \
  --package-tgz /tmp/5pecia1-agent-dashboard-server-0.1.0-alpha.2.tgz \
  --out /tmp/agent-dashboard-worker
```

생성기는 패키지를 프로젝트의 `vendor/`에 복사하고 상대 경로로 참조합니다. 생성한 폴더를 옮겨도 원래 tarball 경로에 의존하지 않습니다. 생성 시 의존성이 설치되며 `node_modules` 없이 옮긴 경우에는 `npm ci`로 다시 설치합니다.

생성된 프로젝트에서 `.dev.vars.example`을 `.dev.vars`로 복사하고 서로 다른 수집용·클라이언트용 토큰을 입력합니다. 이 파일은 Git에 추가하지 않습니다.

```sh
cd /tmp/agent-dashboard-worker
npm run check
npm run migrate:local
npm run dev
```

배포 절차는 [설치 후 배포 안내](STARTER.md)에 있습니다. 기본 웹 origin은 `https://agent-dashboard.5pecia1.dev`이며 다른 웹 앱을 사용하면 `ALLOWED_ORIGINS`와 `DASHBOARD_APP_ORIGIN`을 변경합니다.

기본값은 상태 메타데이터만 저장합니다. 상세 수집을 원하면 서버의 `DASHBOARD_STORE_MESSAGE=1`과 hook의 `MY_DASHBOARD_INCLUDE_CONTENT=1`을 각각 명시합니다. 선택 푸시 및 보존 설정은 [서버 안내](../../server/README.md)를 참고합니다. API와 hook 설치 스크립트는 같은 패키지 버전에서 제공됩니다.
