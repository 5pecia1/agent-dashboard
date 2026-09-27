import type { Env } from "../../env";
import { resolveFcmChannel } from "./fcm";

/**
 * 채널 중립 push 트랜스포트 계층.
 *
 * dispatch.ts는 "이 전이를 알려라"까지만 알고, 어떤 채널로 어떤 대상에게 나가는지는 이 파일이
 * 정의한 인터페이스 뒤에 숨는다. 채널을 하나 더 붙이는 일은
 *   (1) PushTransport를 구현하는 파일을 push/ 아래 만들고
 *   (2) 아래 resolveChannels에 한 줄 더하고
 *   (3) 그 채널의 대상 테이블을 loadTargets가 읽게 하는
 * 세 단계로 끝나야 한다 - dispatch.ts는 다시 열지 않는다.
 *
 * 지금 구현된 채널은 fcm(FCM HTTP v1) 하나다. FCM을 우선 지원하며,
 * 표준 Web Push(RFC 8292 VAPID + RFC 8291 aes128gcm 직접 발송)는 "나중에 붙일 수 있게"만
 * 열어 둔다 - 그 자리가 아래 TRANSPORT_IDS의 "vapid-web" 주석과 resolveChannels의 주석이다.
 *
 * 어휘의 정본은 contracts/dashboard-protocol.v1.json의 push 절이다.
 */

/**
 * 연속 실패가 이 횟수에 닿으면 그 대상을 enabled=0으로 내린다(행은 남긴다 - 왜 조용해졌는지
 * 나중에 답할 수 있어야 하므로). 클라이언트가 다시 등록하면(POST /dashboard/devices) 되살아난다.
 */
export const FAILURE_DISABLE_THRESHOLD = 10;

/** 대상 식별자를 로그에 남길 때 쓰는 요약 길이(앞/뒤). 토큰 원문을 감사 로그에 통째로 남기지 않는다. */
const TARGET_SUMMARY_HEAD = 12;
const TARGET_SUMMARY_TAIL = 6;

/**
 * 트랜스포트가 쓰는 "바깥 세계". 테스트는 여기에 스텁을 넣어 실제 구글 엔드포인트 없이
 * 서명·요청 본문·캐시 동작을 검증한다. 운영에서는 전부 기본값(전역 fetch, Date.now)이다.
 */
export interface TransportDeps {
  fetch?: typeof fetch;
  now?: () => number;
}

/** 채널과 무관한 발송 대상 한 줄. dashboard_devices(또는 미래의 구독 테이블) 한 행에서 만든다. */
export interface PushTarget {
  /** 이 대상이 속한 채널 id. dashboard_devices.transport. */
  transport: string;
  /** 대상 식별자. fcm이면 등록 토큰, 미래의 web push면 endpoint URL. */
  id: string;
  /** web | android | ios ... 메시지 포장(webpush/android 블록)을 고르는 데 쓴다. */
  platform: string | null;
  /** 사람이 붙인 이름. 로그·진단에만 쓴다. */
  label: string | null;
  /** 지금까지의 연속 실패 횟수. */
  failure_count: number;
}

/** 트랜스포트에 넘기는 표시용 메시지. 채널이 달라도 이 내용은 같아야 한다. */
export interface PushMessage {
  title: string;
  body: string;
  /** protocol.v1.json push.data_keys. 값은 전부 문자열이다. */
  data: Record<string, string>;
  /** 알림을 탭했을 때 열 클라이언트 상대 경로(예: "/?session=..."). */
  link: string;
}

/** 대상 하나에 대한 발송 결과. */
export interface SendOutcome {
  ok: boolean;
  /** true면 이 대상은 죽었다(등록 해제 등). 트랜스포트가 이미 행을 지웠다는 뜻이다. */
  remove?: boolean;
  detail?: string;
}

/**
 * 채널 하나의 구현. 자격증명이 있어서 "지금 보낼 수 있는" 채널만 이 모양으로 만들어진다
 * (자격증명이 없으면 ChannelStatus.skipped로 사유만 남는다).
 */
export interface PushTransport {
  readonly id: string;
  /** 이 대상을 이 채널이 맡는가. dispatch는 대상 목록을 채널별로 이걸로 갈라준다. */
  supports(target: PushTarget): boolean;
  send(target: PushTarget, msg: PushMessage): Promise<SendOutcome>;
}

/** Push configuration uses the public DashboardEnv binding schema. */
export type PushEnv = Env;

/** 레지스트리가 돌려주는 채널 한 줄. transport가 null이면 skipped에 사유가 들어 있다. */
export interface ChannelStatus {
  id: string;
  transport: PushTransport | null;
  /** transport가 null일 때의 사유(자격증명 미설정 등). 그대로 dashboard_push_log.detail이 된다. */
  skipped?: string;
}

/**
 * 등록 가능한 채널 id 목록. "지금 보낼 수 있는" 채널이 아니라 "이 서버가 아는" 채널이다
 * (기기 등록은 자격증명보다 먼저 일어날 수 있으므로 POST /dashboard/devices는 이 목록으로 검증한다).
 *
 * "fcm-apns"는 별도 채널이 아니라 fcm 채널이 다루는 두 번째 대상 모양이다(자격증명·엔드포인트가
 * 같다 - push/fcm.ts의 supports()가 둘 다 받고, buildFcmMessage가 포장만 갈아 끼운다).
 * TRANSPORT_IDS에 있어야 POST /dashboard/devices가 이 값으로 오는 등록을 받아 준다.
 *
 * 앞으로 늘어날 자리:
 *   - "vapid-web": 표준 Web Push 직접 발송(dashboard_push_subscriptions).
 */
export const TRANSPORT_IDS = ["fcm", "fcm-apns"] as const;
export type TransportId = (typeof TRANSPORT_IDS)[number];

/** 기기가 transport를 안 알려줄 때의 기본값. 0001 시절 행(전부 FCM 토큰)과 같은 뜻이다. */
export const DEFAULT_TRANSPORT: TransportId = "fcm";

export function isKnownTransport(id: string): id is TransportId {
  return (TRANSPORT_IDS as readonly string[]).includes(id);
}

/**
 * 채널 레지스트리. 활성(발송 가능) 여부까지 판정해서 돌려준다.
 * 채널이 늘면 여기 배열에 한 줄 더한다:
 *   return [resolveFcmChannel(env, deps), resolveVapidWebChannel(env, deps)];
 */
export function resolveChannels(env: PushEnv, deps: TransportDeps = {}): ChannelStatus[] {
  return [resolveFcmChannel(env, deps)];
}

/** 지금 실제로 발송할 수 있는 채널 id만. GET /dashboard/push-config와 진단이 쓴다. */
export function activeChannelIds(env: PushEnv): string[] {
  return resolveChannels(env)
    .filter((channel) => channel.transport !== null)
    .map((channel) => channel.id);
}

/** dashboard_devices 한 행. */
interface DeviceRow {
  token: string;
  platform: string | null;
  transport: string | null;
  label: string | null;
  failure_count: number | null;
}

/**
 * 발송 대상 전체를 읽는다. enabled=0(연속 실패로 내려간 대상)은 제외한다.
 *
 * 지금은 dashboard_devices 한 테이블뿐이다. vapid-web을 붙이는 날
 * dashboard_push_subscriptions를 읽어 transport:"vapid-web" 대상으로 이어 붙이면 되고,
 * dispatch.ts는 그대로 둔다(채널별 분배는 PushTransport.supports가 한다).
 */
export async function loadTargets(env: PushEnv): Promise<PushTarget[]> {
  const { results } = await env.DB.prepare(
    `SELECT token, platform, transport, label, failure_count
       FROM dashboard_devices
      WHERE enabled = 1
      ORDER BY last_seen_at DESC`,
  ).all<DeviceRow>();

  return (results ?? []).map((row) => ({
    transport: row.transport ?? DEFAULT_TRANSPORT,
    id: row.token,
    platform: row.platform ?? null,
    label: row.label ?? null,
    failure_count: Number(row.failure_count ?? 0),
  }));
}

/** 감사 로그에 남길 대상 요약. 토큰 원문을 통째로 남기지 않는다. */
export function summarizeTarget(target: PushTarget): string {
  const id = target.id;
  if (id.length <= TARGET_SUMMARY_HEAD + TARGET_SUMMARY_TAIL + 1) return id;
  return `${id.slice(0, TARGET_SUMMARY_HEAD)}…${id.slice(-TARGET_SUMMARY_TAIL)}`;
}

/**
 * 발송 성공. 연속 실패 카운트를 되돌린다(이전 실패가 남아 있을 때만 쓴다 - 성공할 때마다
 * UPDATE를 날리면 매 발송이 쓰기 한 번씩 늘어난다).
 * last_seen_at은 건드리지 않는다: 그건 "클라이언트가 자기를 갱신한 시각"이라 발송과 다른 사실이다.
 */
export async function markTargetSuccess(env: PushEnv, target: PushTarget): Promise<void> {
  if (target.failure_count <= 0) return;
  try {
    await env.DB.prepare(
      "UPDATE dashboard_devices SET failure_count = 0, last_error = NULL, last_error_at = NULL WHERE token = ?",
    )
      .bind(target.id)
      .run();
  } catch (err) {
    console.log(`기기 성공 기록 실패(무시): ${String(err)}`);
  }
}

/** 발송 실패. 연속 실패를 세고 임계값에 닿으면 대상을 내린다. */
export async function markTargetFailure(
  env: PushEnv,
  target: PushTarget,
  detail: string,
  now: number,
): Promise<void> {
  try {
    await env.DB.prepare(
      `UPDATE dashboard_devices
          SET failure_count = failure_count + 1,
              last_error = ?,
              last_error_at = ?,
              enabled = CASE WHEN failure_count + 1 >= ? THEN 0 ELSE enabled END
        WHERE token = ?`,
    )
      .bind(detail.slice(0, 300), now, FAILURE_DISABLE_THRESHOLD, target.id)
      .run();
  } catch (err) {
    console.log(`기기 실패 기록 실패(무시): ${String(err)}`);
  }
}

/** 등록이 해제된 대상을 그 자리에서 지운다(FCM UNREGISTERED 등). */
export async function deleteTarget(env: PushEnv, target: PushTarget): Promise<void> {
  try {
    await env.DB.prepare("DELETE FROM dashboard_devices WHERE token = ?").bind(target.id).run();
  } catch (err) {
    console.log(`기기 삭제 실패(무시): ${String(err)}`);
  }
}
