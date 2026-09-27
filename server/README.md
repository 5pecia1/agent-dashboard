# Agent Dashboard server

Cloudflare Workers와 D1에서 실행하는 에이전트 상태 서버입니다. Hono 앱에 마운트하거나 [단독 Worker 예제](https://github.com/5pecia1/agent-dashboard/tree/main/examples/cloudflare-worker)를 생성할 수 있습니다. API prefix는 `/dashboard`를 사용합니다.

```ts
import { Hono } from 'hono';
import {
  createDashboardApp,
  createDashboardHooksApp,
  runDashboardMaintenance,
  type DashboardEnv,
} from '@5pecia1/agent-dashboard-server';

const app = new Hono<{ Bindings: DashboardEnv }>();
app.get('/healthz', c => c.json({ ok: true }));
app.route('/', createDashboardHooksApp());
app.route('/dashboard', createDashboardApp());

export default {
  fetch: app.fetch,
  scheduled(_event: ScheduledController, env: DashboardEnv, ctx: ExecutionContext) {
    ctx.waitUntil(runDashboardMaintenance(env, Date.now()));
  },
};
```

`DB`는 D1 바인딩입니다. `INGEST_TOKEN`은 수집과 `GET /dashboard/auth/ingest-check`만 허용합니다. `CLIENT_TOKEN`은 조회·읽음·수동 확인·삭제·설정을 허용합니다. 두 값은 별도로 생성하고 Worker secret으로 설정합니다. 호환용 `AUTH_TOKEN`은 두 역할을 모두 허용하므로 신규 설치에서는 사용하지 않습니다. `ALLOWED_ORIGINS`는 웹 앱의 origin을 쉼표로 구분합니다.

기본값은 메시지와 hook 원문을 저장하지 않습니다. `DASHBOARD_STORE_MESSAGE=1`을 명시하면 이전의 상세 보존 동작을 사용합니다. hook에서도 `MY_DASHBOARD_INCLUDE_CONTENT=1`을 선택해야 원문이 전송됩니다. 기본 보존 대상은 상태 재생에 필요한 source, session/event 식별자, project, host, 시각, generic 상태, hook revision, Devin 상관 식별자입니다. project와 host는 식별·창 연결에 사용하므로 기본값에서도 남습니다. 정규화된 메타데이터가 UTF-8 16KiB를 넘으면 요청 전체를 400으로 거절해 재생 정보가 잘리지 않도록 합니다. 상세 수집은 원문 4096바이트와 메시지 300자 상한을 유지합니다.

FCM은 선택 기능입니다. `FCM_SERVICE_ACCOUNT`, `FIREBASE_WEB_CONFIG`, `FIREBASE_APPLE_CONFIG`, `FCM_WEB_VAPID_KEY`, `DASHBOARD_APP_ORIGIN`을 필요한 채널에 맞게 설정합니다. 미설정 시 상태 수집·조회는 계속 동작합니다. stalled 기준과 보존 일수는 `DashboardEnv`의 `DASHBOARD_STALL_MS`, `DASHBOARD_RETAIN_*_DAYS`로 조정합니다.

설치 시 DB를 자동 변경하지 않습니다. 소비 Worker의 Wrangler 설정에서 `migrations_dir`를 `node_modules/@5pecia1/agent-dashboard-server/migrations`로 지정하고, 배포 전에 `npx wrangler d1 migrations apply DB --remote`를 명시적으로 실행합니다. 기존 `0001`~`0005` SQL은 이름과 내용이 동일합니다. 마이그레이션 ledger를 보존하고 전환 중 `/admin/rebuild`를 실행하지 않습니다. 패키지 버전 되돌리기는 DB 되돌리기가 아닙니다.

개발과 검증은 저장소 루트에서 실행합니다.

```sh
npm --prefix server ci
npm --prefix server run check
npm --prefix server test
npm --prefix server run verify:package
npm --prefix server run test:upgrade
```

`verify:package`는 임시 tarball을 별도 디렉터리에 실제 설치하여 타입, Worker 번들, D1, API, hook 배포, 유지관리와 hook 통합을 검사합니다. 검사한 archive와 로그는 출력된 임시 경로에 남습니다. `-- --tarball /path/package.tgz --receipt /path/receipt.json`을 넘기면 해당 archive를 재빌드하지 않고 검증합니다. `test:upgrade`도 같은 `--tarball`·`--receipt` 옵션을 받아 릴리스할 정확한 archive를 검사할 수 있습니다. 이전 Worker가 HTTP 요청으로 만든 합성 DB fixture를 복원해 migration ledger·커서·읽음·상관 정보를 확인합니다. fixture 기대값은 현재 구현으로 재생성하지 않습니다.

`hono`는 호스트와 라우터 구현을 공유하기 위한 peer dependency이며 현재 검사한 버전으로 고정합니다. esbuild와 TypeScript는 빌드 도구이고 패키지 설치 후 실행하지 않습니다. SQL·API 계약·hook manifest는 각각 `migrations/`, `contracts/` 경로에 포함됩니다. hook 원본과 API 계약은 저장소 루트에서만 편집합니다.

라이선스 조건은 [LICENSE](LICENSE), 기존 배포물 및 제삼자 고지는 [NOTICE](NOTICE)를 확인합니다. 현재 prerelease 패키지는 공개 registry 발행 전이므로 검증한 `.tgz`로 소비합니다.
