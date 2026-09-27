# 단독 Worker 예제

이 폴더는 첫 npm 발행 전의 템플릿입니다. 아직 `package.json`과 lockfile을 커밋하지 않았으므로 여기에서 곧바로 `npm ci`를 실행하지 않습니다. 다음 명령으로 검사할 tarball을 설치한 독립 프로젝트를 생성합니다.

```sh
npm --prefix server ci
npm --prefix server run build
(cd server && npm pack --pack-destination /tmp)
node server/scripts/create-example.mjs \
  --package-tgz /tmp/5pecia1-agent-dashboard-server-0.1.0-alpha.1.tgz \
  --out /tmp/agent-dashboard-worker
```

생성된 프로젝트에서 `.dev.vars.example`을 `.dev.vars`로 복사하고 서로 다른 수집용·클라이언트용 토큰을 입력합니다. 이 파일은 Git에 추가하지 않습니다.

```sh
cd /tmp/agent-dashboard-worker
npm run check
npm run migrate:local
npm run dev
```

배포할 때는 `npx wrangler d1 create agent-dashboard`로 자신의 DB를 만들고, `wrangler.jsonc`의 placeholder `database_id`를 생성 결과로 교체합니다. `ALLOWED_ORIGINS`와 `DASHBOARD_APP_ORIGIN`도 자신의 웹 앱 origin으로 바꿉니다. `npx wrangler secret put INGEST_TOKEN`과 `npx wrangler secret put CLIENT_TOKEN`으로 배포 secret을 설정한 뒤 `npm run deploy`를 실행합니다. 배포 명령은 마이그레이션이 성공한 뒤 Worker를 배포합니다.

기본값은 상태 메타데이터만 저장합니다. 상세 수집을 원하면 서버의 `DASHBOARD_STORE_MESSAGE=1`과 hook의 `MY_DASHBOARD_INCLUDE_CONTENT=1`을 각각 명시합니다. 선택 푸시 및 보존 설정은 [서버 안내](../../server/README.md)를 참고합니다. API와 hook 설치 스크립트는 같은 패키지 버전에서 제공됩니다.
