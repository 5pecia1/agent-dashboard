import {
  loadTargets,
  resolveChannels,
  summarizeTarget,
  type PushEnv,
  type PushMessage,
  type PushTarget,
  type PushTransport,
  type TransportDeps,
} from "./push";
import { normalizeDisplayTitle } from "./display-title";
import { PUSH_STATES, STATE_LABEL, type SessionState } from "./state";

/**
 * 채널 중립 push 발송 계층.
 *
 * 호출하는 쪽(routes.ts, cron)은 "어떤 전이가 일어났다"만 알려주고, 어떤 트랜스포트로
 * 무엇을 보낼지는 이 파일이 정한다. 안쪽은 push/ 의 트랜스포트 레지스트리(resolveChannels)로
 * 갈아끼웠다 - 활성 채널마다 대상 목록을 갈라 Promise.allSettled로 팬아웃하고, 채널별
 * 요약({sent, removed, failed})과 실패한 대상 줄을 dashboard_push_log에 남긴다.
 * 채널을 하나 더 붙이는 일은 push/transport.ts의 레지스트리에서 끝나고 이 파일은 그대로 둔다.
 *
 * 밖으로 보이는 계약(dispatchPush 시그니처, dashboard_push_log 기록, push data 키)은
 * 스텁 시절과 같다. 자격증명이 없는 채널이 사유를 담아 skipped로 남는 것도 그대로다.
 *
 * 어휘의 정본은 같은 디렉터리의 protocol.v1.json.
 */

/** protocol.v1.json states.enum. state.ts가 아직 stalled를 모르므로 여기서 얹는다. */
export type DashboardState = SessionState | "stalled";

/**
 * 표시 라벨. 0001의 STATE_LABEL 5개를 그대로 쓰고 stalled만 더한다.
 * state.ts가 stalled를 품게 되면 이 덮어쓰기는 자연히 무해해진다.
 */
export const STATE_LABEL_V2: Record<string, string> = { ...STATE_LABEL, stalled: "멈춘 듯" };

/** protocol.v1.json push_states. state.ts의 PUSH_STATES에 stalled를 더한 것이다. */
export const PUSH_STATES_V2: ReadonlySet<string> = new Set<string>([...PUSH_STATES, "stalled"]);

/**
 * dispatch가 읽는 env. 아직 env.ts에 없는 값은 선택 필드로 둔다
 * 채널 자격증명 관련 필드는
 * push/transport.ts의 PushEnv가 들고 있고 여기서는 그 위에 얹기만 한다.
 */
export type DispatchEnv = PushEnv;

/** 발송의 근거가 되는 전이 한 줄. dashboard_transitions의 부분집합이다. */
export interface PushTransition {
  /** dashboard_transitions.id. 아직 저장되지 않은 합성 전이(test-push)는 0을 준다. */
  id: number;
  session_key: string;
  from_state: DashboardState | null;
  to_state: DashboardState;
  source: string;
  project: string | null;
  host: string | null;
  message: string | null;
  display_title?: string | null;
  /** 이벤트 발생 시각(epoch ms). */
  occurred_at: number;
}

/** dashboard_push_log.result 어휘. */
export type PushResult = "sent" | "skipped" | "muted" | "failed" | "no_target";

/** 트랜스포트 하나의 발송 결과. 그대로 dashboard_push_log 한 줄이 된다. */
export interface TransportOutcome {
  transport: string;
  result: PushResult;
  /** 대상 식별자. 묶음 발송이면 "all". */
  target: string;
  detail?: string;
}

/** protocol.v1.json push.data_keys. 값은 전부 문자열이다. */
export interface PushPayload {
  title: string;
  body: string;
  data: {
    transition_id: string;
    session_key: string;
    state: string;
    source: string;
    project: string;
    host: string;
    display_title: string;
    title: string;
    body: string;
    link: string;
  };
}

export interface DispatchResult {
  /** 한 트랜스포트라도 발송을 시도했는가. */
  queued: boolean;
  /** 음소거 때문에 건너뛰었는가. */
  muted: boolean;
  outcomes: TransportOutcome[];
  payload: PushPayload;
}

export interface DispatchOptions {
  /** test-push처럼 음소거를 무시해야 할 때. */
  ignoreMute?: boolean;
  /** 시각 주입(테스트용). 기본은 Date.now(). */
  now?: number;
  /** 발송을 시도했을 때 dashboard_transitions.notified_at을 채울지. 기본은 id > 0이면 채운다. */
  markNotified?: boolean;
  /** 본문을 통째로 갈아끼운다(test-push 문구 등). */
  bodyOverride?: string;
  /** 트랜스포트에 주입할 fetch·시계(테스트용). 운영에서는 비워 둔다. */
  deps?: TransportDeps;
}

/** cwd 절대경로에서 표시용 이름(마지막 조각)만 뽑는다. */
function projectName(project: string | null): string {
  if (!project) return "(프로젝트 없음)";
  return project.split("/").filter(Boolean).pop() ?? project;
}

function storeMessage(env: DispatchEnv): boolean {
  return env.DASHBOARD_STORE_MESSAGE === "1";
}

/**
 * 전이 하나를 표시용 payload로 만든다.
 * 트랜스포트마다 포장은 달라도 title/body/data는 같아야 하므로 여기 한 곳에서만 만든다.
 */
export function buildPushPayload(
  env: DispatchEnv,
  transition: PushTransition,
  opts: DispatchOptions = {},
): PushPayload {
  const label = STATE_LABEL_V2[transition.to_state] ?? transition.to_state;
  const name = projectName(transition.project);
  const displayTitle = storeMessage(env) ? normalizeDisplayTitle(transition.display_title) : null;
  // 정본 i18n.ko.push.title = "{project} · {host} · {label}" (계약 i18n 절의 $note 참고).
  // project가 맨 앞이다: 알림 센터는 제목의 뒤쪽부터 잘라내고 host는 한 기계의 모든
  // 세션이 공유하는 값이라, 배너끼리 구분되는 유일한 조각인 project가 잘리면 안 된다.
  // 앱 로컬 알림(app/flutter_app/.../notify_provider.dart의 payloadForAlert)도 같은 이유로
  // project를 맨 앞에 둔다 - 두 경로의 제목 순서가 갈리면 같은 전이가 기기마다 다른
  // 제목으로 보인다.
  const title = displayTitle
    ? displayTitle === name
      ? name
      : `${name} · ${displayTitle}`
    : transition.host
      ? `${name} · ${transition.host} · ${label}`
      : `${name} · ${label}`;
  const fallback = `${transition.source} 세션이 '${label}' 상태가 되었습니다.`;
  const titledBody = [
    transition.host,
    label,
    transition.message && transition.message.length > 0 ? transition.message : null,
  ]
    .filter((part): part is string => part !== null && part.length > 0)
    .join(" · ");
  const body =
    opts.bodyOverride ??
    (displayTitle
      ? titledBody
      : storeMessage(env) && transition.message
        ? transition.message
        : fallback);
  const link = `/?session=${encodeURIComponent(transition.session_key)}`;

  return {
    title,
    body,
    data: {
      transition_id: String(transition.id),
      session_key: transition.session_key,
      state: transition.to_state,
      source: transition.source,
      project: transition.project ?? "",
      host: transition.host ?? "",
      display_title: displayTitle ?? "",
      title,
      body,
      link,
    },
  };
}

/** 음소거 종료 시각(epoch ms)을 읽는다. 테이블이 아직 없으면 음소거 아님으로 본다. */
async function readMuteUntil(env: DispatchEnv): Promise<number> {
  try {
    const row = await env.DB.prepare("SELECT value FROM dashboard_settings WHERE key = 'mute_until'")
      .first<{ value: string | null }>();
    return Number(row?.value ?? 0) || 0;
  } catch (err) {
    console.log(`mute_until 조회 실패(무시): ${String(err)}`);
    return 0;
  }
}

/** 발송 결과를 감사 로그에 남긴다. 로그 실패가 요청을 망치지 않게 삼킨다. */
async function logOutcome(
  env: DispatchEnv,
  transitionId: number,
  outcome: TransportOutcome,
  now: number,
): Promise<void> {
  try {
    await env.DB.prepare(
      `INSERT INTO dashboard_push_log (transition_id, transport, target, result, detail, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        transitionId > 0 ? transitionId : null,
        outcome.transport,
        outcome.target,
        outcome.result,
        outcome.detail ?? null,
        now,
      )
      .run();
  } catch (err) {
    console.log(`push 로그 기록 실패(무시): ${String(err)}`);
  }
}

/** 채널 하나의 대상별 결과를 접은 값. 그대로 dashboard_push_log.detail(JSON)이 된다. */
interface ChannelTally {
  sent: number;
  removed: number;
  failed: number;
}

/**
 * 채널 하나를 그 채널이 맡은 대상들로 팬아웃한다.
 *
 * 대상 하나의 실패가 다른 대상을 막지 않도록 Promise.allSettled로 모은다. 실패·삭제된 대상은
 * 그 자리에서 한 줄씩 로그로 남기고(왜 이 기기만 조용한지 나중에 답할 수 있어야 한다),
 * 돌려주는 것은 채널 요약 한 줄이다 - 채널당 outcome이 정확히 하나여야 test-push의
 * 채널별 응답(channels[transport])이 서로를 덮어쓰지 않는다.
 */
async function fanOutChannel(
  env: DispatchEnv,
  transport: PushTransport,
  targets: PushTarget[],
  msg: PushMessage,
  transitionId: number,
  now: number,
): Promise<TransportOutcome> {
  if (targets.length === 0) {
    return {
      transport: transport.id,
      result: "no_target",
      target: "all",
      detail: JSON.stringify({ sent: 0, removed: 0, failed: 0 } satisfies ChannelTally),
    };
  }

  const settled = await Promise.allSettled(targets.map((target) => transport.send(target, msg)));
  const tally: ChannelTally = { sent: 0, removed: 0, failed: 0 };

  for (let i = 0; i < settled.length; i++) {
    const target = targets[i];
    const settledOne = settled[i];

    if (settledOne.status === "rejected") {
      tally.failed++;
      await logOutcome(
        env,
        transitionId,
        {
          transport: transport.id,
          result: "failed",
          target: summarizeTarget(target),
          detail: String(settledOne.reason).slice(0, 300),
        },
        now,
      );
      continue;
    }

    const outcome = settledOne.value;
    if (outcome.ok) {
      tally.sent++;
      continue;
    }

    // 등록 해제(remove)는 트랜스포트가 이미 행을 지웠다는 뜻이다. 여기서는 세고 남기기만 한다.
    if (outcome.remove) tally.removed++;
    else tally.failed++;
    await logOutcome(
      env,
      transitionId,
      {
        transport: transport.id,
        result: "failed",
        target: summarizeTarget(target),
        detail: outcome.remove
          ? `대상 삭제: ${outcome.detail ?? "등록 해제"}`
          : (outcome.detail ?? "발송 실패"),
      },
      now,
    );
  }

  const result: PushResult =
    tally.sent > 0 ? "sent" : tally.removed + tally.failed > 0 ? "failed" : "no_target";
  return { transport: transport.id, result, target: "all", detail: JSON.stringify(tally) };
}

/**
 * 활성 채널 전체로 내보낸다. 채널당 outcome 하나.
 *
 * 자격증명이 없는 채널은 보내지 않고 사유를 담아 skipped로 남긴다(스텁 시절 동작 계승 -
 * "FCM_SERVICE_ACCOUNT 미설정" 문구는 test-push 응답의 계약이다). 활성 채널이 하나도 없으면
 * 대상 테이블은 읽지도 않는다.
 */
async function dispatchChannels(
  env: DispatchEnv,
  payload: PushPayload,
  transitionId: number,
  now: number,
  deps: TransportDeps,
): Promise<TransportOutcome[]> {
  const outcomes: TransportOutcome[] = [];
  const active: { id: string; transport: PushTransport }[] = [];

  for (const channel of resolveChannels(env, deps)) {
    if (channel.transport) {
      active.push({ id: channel.id, transport: channel.transport });
    } else {
      outcomes.push({
        transport: channel.id,
        result: "skipped",
        target: "all",
        detail: channel.skipped ?? "자격증명 미설정",
      });
    }
  }
  if (active.length === 0) return outcomes;

  let targets: PushTarget[];
  try {
    targets = await loadTargets(env);
  } catch (err) {
    for (const channel of active) {
      outcomes.push({
        transport: channel.id,
        result: "failed",
        target: "all",
        detail: `대상 조회 실패: ${String(err).slice(0, 200)}`,
      });
    }
    return outcomes;
  }

  const msg: PushMessage = {
    title: payload.title,
    body: payload.body,
    data: payload.data,
    link: payload.data.link,
  };

  // 채널끼리 서로를 기다리지 않는다. 한 채널이 통째로 터져도 나머지는 나간다.
  const settled = await Promise.allSettled(
    active.map((channel) =>
      fanOutChannel(
        env,
        channel.transport,
        targets.filter((target) => channel.transport.supports(target)),
        msg,
        transitionId,
        now,
      ),
    ),
  );

  settled.forEach((settledOne, i) => {
    if (settledOne.status === "fulfilled") {
      outcomes.push(settledOne.value);
      return;
    }
    outcomes.push({
      transport: active[i].id,
      result: "failed",
      target: "all",
      detail: String(settledOne.reason).slice(0, 300),
    });
  });

  return outcomes;
}

/**
 * 전이 하나를 등록된 채널들로 내보낸다.
 *
 * - 보낼지 말지(push_states 필터)는 호출하는 쪽이 정한다. 여기 오면 보낸다는 뜻이다.
 * - 음소거 중이면 발송만 건너뛴다. 전이 적재는 이미 끝나 있고 여기서 되돌리지 않는다.
 * - 실패는 정상 상황이다. push는 힌트고 정합성은 GET /dashboard/sync 커서 재조회가 담보한다.
 *   그래서 이 함수는 예외를 밖으로 던지지 않는다.
 */
export async function dispatchPush(
  env: DispatchEnv,
  transition: PushTransition,
  opts: DispatchOptions = {},
): Promise<DispatchResult> {
  const now = opts.now ?? Date.now();
  const payload = buildPushPayload(env, transition, opts);

  if (!opts.ignoreMute) {
    const muteUntil = await readMuteUntil(env);
    if (muteUntil > now) {
      const outcome: TransportOutcome = {
        transport: "none",
        result: "muted",
        target: "all",
        detail: `mute_until=${muteUntil}`,
      };
      await logOutcome(env, transition.id, outcome, now);
      return { queued: false, muted: true, outcomes: [outcome], payload };
    }
  }

  const outcomes = await dispatchChannels(env, payload, transition.id, now, opts.deps ?? {});
  // 채널 요약은 대상별 줄보다 뒤에 남는다 - diagnostics가 마지막 한 줄만 읽어도 결론이 보이게.
  for (const outcome of outcomes) await logOutcome(env, transition.id, outcome, now);

  const markNotified = opts.markNotified ?? transition.id > 0;
  if (markNotified && transition.id > 0) {
    try {
      await env.DB.prepare("UPDATE dashboard_transitions SET notified_at = ? WHERE id = ?")
        .bind(now, transition.id)
        .run();
    } catch (err) {
      console.log(`notified_at 갱신 실패(무시): ${String(err)}`);
    }
  }

  return { queued: true, muted: false, outcomes, payload };
}
