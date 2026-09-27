import { describe, expect, it } from "vitest";
import { buildPushPayload, type DispatchEnv, type PushTransition } from "../src/dashboard/dispatch";

/**
 * push.title의 project 표시 규칙(basename) 완료 판정.
 *
 * buildPushPayload는 순수 함수라 D1 등 실제 바인딩이 필요 없다 - env는 최소 모양으로
 * 캐스팅해서 쓴다(storeMessage()가 보는 DASHBOARD_STORE_MESSAGE 외에는 읽지 않는다).
 *
 * 확인 대상: title에는 project의 마지막 경로 세그먼트만 들어가고(배너 잘림 방지),
 * data.project에는 원래 전체 경로가 그대로 남는다 - 표시만 바뀌고 데이터는 안 바뀐다.
 *
 * 순서도 함께 고정한다: 정본 i18n.ko.push.title = "{project} · {host} · {label}"이라
 * project가 맨 앞이다(계약 i18n 절의 $note 참고 - 알림 센터는 제목 뒤쪽부터 잘라내고
 * host는 한 기계의 모든 세션이 공유하는 값이라 배너 구분에 쓸모가 없다). 앱 로컬
 * 알림(payloadForAlert)도 같은 순서를 쓰므로, 여기가 흔들리면 같은 전이가 기기마다
 * 다른 제목으로 보인다.
 */

const FAKE_ENV = {} as DispatchEnv;

function transition(project: string | null, host: string | null = "example-host"): PushTransition {
  return {
    id: 1,
    session_key: "s1",
    from_state: null,
    to_state: "done",
    source: "claude-code",
    project,
    host,
    message: null,
    occurred_at: Date.now(),
  };
}

describe("buildPushPayload — push.title의 project basename 표시", () => {
  it("절대경로는 마지막 세그먼트만 title에 쓰고 data.project는 전체 경로를 유지한다", () => {
    const payload = buildPushPayload(FAKE_ENV, transition("/workspace/example"));
    expect(payload.title).toBe("example · example-host · 실행 마침");
    expect(payload.data.project).toBe("/workspace/example");
  });

  it("끝 슬래시가 있어도 마지막 세그먼트를 뽑는다", () => {
    const payload = buildPushPayload(FAKE_ENV, transition("/workspace/example/"));
    expect(payload.title).toBe("example · example-host · 실행 마침");
    expect(payload.data.project).toBe("/workspace/example/");
  });

  it("루트('/')는 세그먼트가 없으므로 원래 값을 그대로 쓴다", () => {
    const payload = buildPushPayload(FAKE_ENV, transition("/"));
    expect(payload.title).toBe("/ · example-host · 실행 마침");
    expect(payload.data.project).toBe("/");
  });

  it("빈 문자열은 '프로젝트 없음'으로 표시하고 data.project는 빈 문자열을 유지한다", () => {
    const payload = buildPushPayload(FAKE_ENV, transition(""));
    expect(payload.title).toBe("(프로젝트 없음) · example-host · 실행 마침");
    expect(payload.data.project).toBe("");
  });

  it("project가 null이면 '프로젝트 없음'으로 표시하고 data.project는 빈 문자열이다", () => {
    const payload = buildPushPayload(FAKE_ENV, transition(null));
    expect(payload.title).toBe("(프로젝트 없음) · example-host · 실행 마침");
    expect(payload.data.project).toBe("");
  });

  it("host가 없으면 host 없이 project · label만 쓴다", () => {
    const payload = buildPushPayload(FAKE_ENV, transition("/a/b/c", null));
    expect(payload.title).toBe("c · 실행 마침");
  });

  it("제목의 첫 조각은 항상 project다 - host가 있어도 앞자리를 뺏지 않는다", () => {
    const withHost = buildPushPayload(FAKE_ENV, transition("/a/b/my-dashboard"));
    const withoutHost = buildPushPayload(FAKE_ENV, transition("/a/b/my-dashboard", null));

    // host 유무와 무관하게 첫 조각이 같다 = push.title과 push.title_no_host가
    // 같은 순서를 쓴다는 정본 계약의 관찰 가능한 결과다.
    expect(withHost.title.split(" · ")[0]).toBe("my-dashboard");
    expect(withoutHost.title.split(" · ")[0]).toBe("my-dashboard");
    expect(withHost.title.split(" · ")).toEqual(["my-dashboard", "example-host", "실행 마침"]);
  });
});
