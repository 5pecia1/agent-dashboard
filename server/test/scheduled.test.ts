import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

// 로컬 protocol.v1.json의 retention.cron은 "hourly"로 도는 cron 핸들러를
// 전제한다. 그런데 지금 src/index.ts에는 실제 `scheduled` export가 아직 없다(그 cron/보존
// 구현은 이 TASK의 파일 소유 범위 밖이다 - final report의 followups 참고).
//
// 이 테스트가 증명하려는 것은 그 cron 로직의 내용이 아니라 "vitest-pool-workers 하네스가
// ScheduledController + waitUntil을 인프로세스로 굴릴 수 있다"는 하네스 능력 자체다(완료 판정 c).
// 그래서 실제 워커 계약과 똑같은 시그니처((controller, env, ctx) => void, ctx.waitUntil로
// 응답 이후 비동기 작업 예약)를 지키는 최소 핸들러를 이 파일 안에서만 정의해 호출한다.
// 나중에 src/index.ts가 진짜 scheduled export를 갖게 되면, 이 자리를
// `import worker from "./worker"; worker.scheduled(...)`로 바꿔 끼우면 된다.
interface TestEnv {
  DB: D1Database;
}

function fakeScheduledHandler(controller: ScheduledController, workerEnv: TestEnv, ctx: ExecutionContext): void {
  // 실제 cron 핸들러도 이렇게 한다: 응답을 막지 않기 위해 D1 쓰기를 waitUntil 뒤로 예약한다.
  ctx.waitUntil(
    workerEnv.DB.prepare(
      `INSERT INTO dashboard_meta (key, value) VALUES ('last_cron_run', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
      .bind(String(controller.scheduledTime))
      .run(),
  );
}

describe("scheduled 핸들러 호출 + waitUntil이 인프로세스로 끝까지 돈다", () => {
  it("완료 판정(c): createScheduledController로 만든 컨트롤러를 넘겨 호출하면, waitUntil된 D1 쓰기가 실제로 반영된다", async () => {
    const testEnv = env as unknown as TestEnv;

    const before = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'last_cron_run'").first<{
      value: string;
    }>();
    expect(before).toBeNull();

    const scheduledTime = Date.UTC(2026, 0, 1, 3, 0, 0);
    const controller = createScheduledController({ scheduledTime: new Date(scheduledTime), cron: "0 * * * *" });
    const ctx = createExecutionContext();

    expect(controller.scheduledTime).toBe(scheduledTime);
    expect(controller.cron).toBe("0 * * * *");

    fakeScheduledHandler(controller, testEnv, ctx);
    // fetch 핸들러의 c.executionCtx.waitUntil()과 같은 API다: 응답(여기서는 핸들러 호출 자체)이
    // 끝난 뒤에도 이어지는 비동기 작업이 실제로 완료되기를 기다린다.
    await waitOnExecutionContext(ctx);

    const after = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'last_cron_run'").first<{
      value: string;
    }>();
    expect(after?.value).toBe(String(scheduledTime));
  });

  it("waitOnExecutionContext 전에는 아직 반영되지 않을 수 있다 (waitUntil이 진짜 비동기임을 보인다)", async () => {
    const testEnv = env as unknown as TestEnv;
    const controller = createScheduledController({ scheduledTime: new Date(Date.UTC(2026, 0, 2, 3, 0, 0)) });
    const ctx = createExecutionContext();

    // D1 쓰기 앞에 진짜 microtask 지연을 하나 끼워 넣어서, waitUntil 안 기다리면 아직 안 끝났을
    // 여지가 있게 만든다. (지연이 없으면 워커 안 D1은 충분히 빨라 우연히도 동기처럼 보일 수 있다.)
    ctx.waitUntil(
      Promise.resolve()
        .then(() => Promise.resolve())
        .then(() =>
          testEnv.DB.prepare(
            `INSERT INTO dashboard_meta (key, value) VALUES ('last_cron_run', ?)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
          )
            .bind(String(controller.scheduledTime))
            .run(),
        ),
    );

    await waitOnExecutionContext(ctx);

    const after = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'last_cron_run'").first<{
      value: string;
    }>();
    expect(after?.value).toBe(String(controller.scheduledTime));
  });
});
