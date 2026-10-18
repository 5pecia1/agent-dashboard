// OpenCode CLI v2 전역 플러그인. api.event.subscribe 이벤트를 계약 어휘로 번역해
// agent-event-hook.sh opencode 에 stdin JSON으로 넘긴다. 번역 규칙의 정본은 계약의
// event_state_map.opencode_plugin_translation 이다.
//
// 설치: 설치기(install.sh --opencode)가 $OPENCODE_CONFIG_DIR/plugins/my-dashboard.js 에
//   import plugin from "file:///<이 파일의 절대경로>"; export default plugin;
// 두 줄짜리 래퍼를 쓴다. 이 파일은 agent-event-hook.sh 와 같은 디렉터리에 있으므로 hook
// 경로는 import.meta.url 기준으로 계산한다(공유 서비스의 process.cwd()는 /Users/<user>라 쓰지 않는다).
//
// OpenCode 2.0.31 플러그인 계약(실측): default export { id, setup(api) } 만 호출된다. v1의
// named export 훅 형태는 무시된다. setup(api)가 반환한 함수는 dispose(hot-reload·location
// 종료) 때 호출된다. 이벤트는 api.event.subscribe({ signal }) 이 돌려주는 AsyncIterable 이다.
//
// 원칙:
//   - 절대 throw 하지 않고 어떤 훅의 반환값도 바꾸지 않는다. hook 프로세스가 끝나기를 기다리지
//     않으며 실패도 무시한다(stdio: pipe/ignore/ignore, unref).
//   - 환경변수(MY_DASHBOARD_INCLUDE_CONTENT 등)를 읽지 않는다. 프라이버시 게이트·하트비트
//     스로틀·스풀·멱등 event_id 는 전부 hook 스크립트가 적용한다.
//   - 전역 플러그인은 location(디렉터리)마다 인스턴스가 하나씩 생기고 모든 인스턴스가 서버의
//     모든 이벤트를 받는다(실측). 중복 전송을 막기 위해 프로세스 전역 레지스트리
//     globalThis[Symbol.for("my-dashboard.opencode")] 로 세션의 소유 location 을 판정한다.
//   - 번역·소유 판정·서브에이전트 로직은 I/O 없는 translate() 에 모여 있고 테스트가 직접 부른다.
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PLUGIN_ID = "my-dashboard";
export const REGISTRY_KEY = Symbol.for("my-dashboard.opencode");
export const SOURCE = "opencode";
export const PROMPT_MAX_CHARS = 300;
export const MESSAGE_MAX_CHARS = 300;

// 계약 opencode_plugin_translation.heartbeat_types / stop_types 와 같아야 한다(contract_check 가 대조한다).
export const HEARTBEAT_TYPES = [
  "session.step.started",
  "session.tool.called",
  "session.tool.success",
  "session.tool.failed",
];
export const STOP_TYPES = [
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
];
// 자식(서브에이전트) 세션에서도 루트 세션 ID로 바꿔 보내는 이벤트 - 사용자가 부모 화면에서 답해야 한다.
export const CHILD_FORWARDED_TYPES = [
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
];

export const DEFAULT_HOOK_SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "agent-event-hook.sh");

// ---------- 레지스트리 ----------

// sessionID -> { directory, parentID, ended, prompt }. 같은 프로세스의 모든 인스턴스가 공유한다.
export function createRegistry() {
  return new Map();
}

export function sharedRegistry() {
  const existing = globalThis[REGISTRY_KEY];
  if (existing instanceof Map) return existing;
  const created = createRegistry();
  try {
    globalThis[REGISTRY_KEY] = created;
  } catch (_) {
    // globalThis 가 동결돼 있으면 이 인스턴스만의 레지스트리로 동작한다.
  }
  return created;
}

function isString(value) {
  return typeof value === "string" && value.length > 0;
}

function clip(value, max) {
  if (!isString(value)) return null;
  const text = value.replace(/\s+/g, " ").trim();
  if (!text) return null;
  return text.length > max ? text.slice(0, max) : text;
}

function ensureEntry(registry, sessionID, directory, parentID) {
  let entry = registry.get(sessionID);
  if (!entry) {
    entry = { directory, parentID: isString(parentID) ? parentID : null, ended: false, prompt: null };
    registry.set(sessionID, entry);
    return entry;
  }
  if (!isString(entry.directory) && isString(directory)) entry.directory = directory;
  if (!entry.parentID && isString(parentID)) entry.parentID = parentID;
  return entry;
}

// 부모를 거슬러 루트 세션 ID를 찾는다. 부모가 레지스트리에 없어도(standalone 은 루트 created 를
// 못 본다) 마지막으로 알려진 부모를 루트로 본다. 순환은 방어적으로 끊는다.
export function rootSessionOf(registry, sessionID) {
  let current = sessionID;
  const seen = new Set();
  for (;;) {
    const entry = registry.get(current);
    if (!entry || !isString(entry.parentID) || seen.has(current)) return current;
    seen.add(current);
    current = entry.parentID;
  }
}

function sessionIdOf(type, data) {
  if (type === "form.created") return isString(data?.form?.sessionID) ? data.form.sessionID : null;
  return isString(data?.sessionID) ? data.sessionID : null;
}

function permissionMessage(data) {
  const action = isString(data?.action) ? data.action : "permission";
  const resources = Array.isArray(data?.resources) ? data.resources.filter(isString) : [];
  return clip(resources.length ? `${action}: ${resources.join(", ")}` : action, MESSAGE_MAX_CHARS);
}

function formMessage(form) {
  const first = Array.isArray(form?.fields) ? form.fields[0] : null;
  return clip(first?.description ?? first?.title ?? form?.title ?? null, MESSAGE_MAX_CHARS);
}

function payload(event, sessionID, cwd, meta, extra) {
  const out = { session_id: sessionID, cwd: isString(cwd) ? cwd : "unknown", hook_event_name: event };
  if (extra && isString(extra.prompt)) out.prompt = extra.prompt;
  if (extra && isString(extra.message)) out.message = extra.message;
  const opencode = {};
  for (const [key, value] of Object.entries(meta)) {
    if (value !== undefined && value !== null && value !== "") opencode[key] = value;
  }
  out.opencode = opencode;
  return out;
}

// ---------- 번역(순수) ----------

// 이벤트 하나를 hook stdin 페이로드 0개 이상으로 바꾼다. registry 는 세션 상태(소유 location·부모·
// 마지막 프롬프트·종료 여부)이고 이 함수만 고친다. ownDir 는 이 인스턴스의 api.location.directory.
export function translate(event, registry, ownDir) {
  if (!event || typeof event !== "object" || !isString(event.type) || !isString(ownDir)) return [];
  const type = event.type;
  const data = event.data && typeof event.data === "object" ? event.data : {};
  const eventDir = isString(event.location?.directory) ? event.location.directory : null;
  const eventId = isString(event.id) ? event.id : null;

  if (type === "location.shutdown") {
    if (eventDir !== ownDir) return [];
    const out = [];
    for (const [sessionID, entry] of registry) {
      if (entry.directory !== ownDir || entry.ended || isString(entry.parentID)) continue;
      entry.ended = true;
      out.push(payload("SessionEnd", sessionID, ownDir, { type, event_id: eventId }));
    }
    return out;
  }

  const sessionID = sessionIdOf(type, data);
  if (!sessionID) return [];

  if (type === "session.created") {
    const directory = isString(data.location?.directory) ? data.location.directory : eventDir;
    if (directory !== ownDir) return [];
    ensureEntry(registry, sessionID, directory, data.parentID);
    return [];
  }

  // 소유 판정: location 이 있으면 그것으로, 없으면 레지스트리에 기록된 location 으로.
  if (eventDir !== null) {
    if (eventDir !== ownDir) return [];
    ensureEntry(registry, sessionID, eventDir, null);
  } else {
    const known = registry.get(sessionID);
    if (!known || known.directory !== ownDir) return [];
  }
  const entry = registry.get(sessionID);
  const rootID = rootSessionOf(registry, sessionID);
  const isChild = rootID !== sessionID;
  const childMeta = isChild ? { child_session_id: sessionID, parent_session_id: entry.parentID } : {};

  if (type === "session.inbox.enqueued") {
    const text = clip(data.item?.payload?.text, PROMPT_MAX_CHARS);
    if (text) entry.prompt = text;
    return [];
  }

  if (CHILD_FORWARDED_TYPES.includes(type)) {
    const cwd = entry.directory;
    switch (type) {
      case "permission.asked":
        return [payload("UserInputRequest", rootID, cwd,
          { type, event_id: eventId, request_id: data.id, ...childMeta }, { message: permissionMessage(data) })];
      case "permission.replied":
        return [payload("UserInputResolved", rootID, cwd,
          { type, event_id: eventId, request_id: data.requestID, reply: data.reply, ...childMeta })];
      case "form.created":
        return [payload("UserInputRequest", rootID, cwd,
          { type, event_id: eventId, form_id: data.form?.id, form_kind: data.form?.metadata?.kind, ...childMeta },
          { message: formMessage(data.form) })];
      case "form.replied":
      case "form.cancelled":
        return [payload("UserInputResolved", rootID, cwd, { type, event_id: eventId, form_id: data.id, ...childMeta })];
      default:
        return [];
    }
  }

  // 아래는 루트 세션만 보낸다. 부모의 상태는 부모 자신의 execution.* 으로만 정해진다.
  if (isChild) {
    if (type === "session.deleted") registry.delete(sessionID);
    return [];
  }

  if (type === "session.execution.started") {
    entry.ended = false;
    return [payload("UserPromptSubmit", sessionID, entry.directory, { type, event_id: eventId }, { prompt: entry.prompt })];
  }

  if (STOP_TYPES.includes(type)) {
    return [payload("Stop", sessionID, entry.directory, {
      type,
      event_id: eventId,
      error_type: type === "session.execution.failed" && isString(data.error?.type) ? data.error.type : undefined,
      reason: type === "session.execution.interrupted" && isString(data.reason) ? data.reason : undefined,
    })];
  }

  if (type === "session.deleted") {
    const wasEnded = entry.ended;
    registry.delete(sessionID);
    if (wasEnded) return [];
    return [payload("SessionEnd", sessionID, entry.directory, { type, event_id: eventId })];
  }

  if (HEARTBEAT_TYPES.includes(type)) {
    const tool = isString(data.name) ? data.name : isString(data.tool) ? data.tool : undefined;
    return [payload("PostToolUse", sessionID, entry.directory, { type, event_id: eventId, tool })];
  }

  return [];
}

// ---------- hook 실행 ----------

// detached: standalone(opencode run --standalone)은 location.shutdown 직후 자식 서버의 프로세스 그룹을
// SIGTERM 으로 정리한다(실측: Stop 의 hook 이 시작도 못 하고, PostToolUse 의 hook 이 1초 만에 TERM 을
// 받았다). hook 을 자기 프로세스 그룹으로 떼어 놓아야 Stop·SessionEnd 가 서버(또는 스풀)에 닿는다.
export function sendToHook(hookScript, stdinPayload) {
  try {
    const child = spawn("bash", [hookScript, SOURCE], { stdio: ["pipe", "ignore", "ignore"], detached: true });
    child.on("error", () => {});
    if (child.stdin) {
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(stdinPayload));
    }
    child.unref();
  } catch (_) {
    // hook 을 띄우지 못해도 OpenCode 를 방해하지 않는다.
  }
}

// ---------- 플러그인 진입점 ----------

export function setup(api, options = {}) {
  const hookScript = isString(options.hookScript) ? options.hookScript : DEFAULT_HOOK_SCRIPT;
  const send = typeof options.send === "function" ? options.send : (p) => sendToHook(hookScript, p);
  const registry = options.registry instanceof Map ? options.registry : sharedRegistry();
  const ownDir = api?.location?.directory;
  const abort = new AbortController();

  (async () => {
    try {
      const iterator = api.event.subscribe({ signal: abort.signal });
      for await (const event of iterator) {
        let payloads = [];
        try {
          payloads = translate(event, registry, ownDir);
        } catch (_) {
          payloads = [];
        }
        for (const item of payloads) {
          try {
            send(item);
          } catch (_) {}
        }
      }
    } catch (_) {
      // 구독이 끊기거나(abort) 실패해도 조용히 끝낸다.
    }
  })();

  return () => {
    try {
      abort.abort();
    } catch (_) {}
  };
}

export default {
  id: PLUGIN_ID,
  setup(api) {
    try {
      return setup(api);
    } catch (_) {
      return () => {};
    }
  },
};
