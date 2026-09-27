import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// setupFiles는 per-test-file storage isolation "밖"에서 돌고 여러 번 불릴 수 있다.
// applyD1Migrations()는 이미 적용된 마이그레이션 이름을 기록해두고 건너뛰므로 반복 호출에 안전하다.
// vitest.config.ts가 TEST_MIGRATIONS 바인딩으로 0001_dashboard.sql·0002_dashboard_v2.sql을 주입한다.
const testEnv = env as unknown as {
  DB: D1Database;
  TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
};

await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
