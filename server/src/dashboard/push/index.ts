/**
 * push 계층의 바깥 문. dispatch.ts와 라우트는 이 파일만 import한다 - 채널이 늘거나
 * 파일이 쪼개져도 바깥은 다시 열지 않게 하기 위해서다.
 */
export {
  DEFAULT_TRANSPORT,
  FAILURE_DISABLE_THRESHOLD,
  TRANSPORT_IDS,
  activeChannelIds,
  isKnownTransport,
  loadTargets,
  resolveChannels,
  summarizeTarget,
  type ChannelStatus,
  type PushEnv,
  type PushMessage,
  type PushTarget,
  type PushTransport,
  type SendOutcome,
  type TransportDeps,
  type TransportId,
} from "./transport";

export {
  PUSH_TTL_SECONDS,
  buildFcmMessage,
  createFcmTransport,
  parseServiceAccount,
  resetAccessTokenCache,
  resolveFcmChannel,
  type ServiceAccount,
} from "./fcm";

export { pushRoutes } from "./routes";
