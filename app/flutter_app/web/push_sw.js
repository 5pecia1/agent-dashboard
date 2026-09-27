'use strict';

// my_dashboard 웹 푸시 서비스 워커 — **표시 전담**. 캐싱은 한 줄도 없다.
//
// ── 왜 별도 파일·별도 scope인가 ──────────────────────────────────────
// 이 앱에는 이미 오프라인 계약을 지는 app shell SW가 있다
// (`my_dashboard_service_worker.js`, scope `/`, 등록은 `flutter_bootstrap.js`).
// 그 파일은 이 템플릿의 표준 산출물이고 한 바이트도 건드리지 않는다.
// 푸시 표시를 거기에 얹으면 (a) 표준 파일을 고쳐야 하고 (b) 캐시 수명과 푸시
// 수명이 한 등록에 묶여 서로를 망가뜨린다 — app shell SW는 빌드마다 새
// 캐시 이름으로 갈리는 물건이라 등록이 흔들리는 것이 정상이고, 푸시 구독은
// 그 반대로 안정적이어야 한다.
//
// 그래서 이 워커는 `scope: 'push-scope/'`로 따로 등록한다
// (`lib/src/platform/web_push_web.dart`). 그 scope에는 실제 문서가 하나도
// 없다 — 의도한 바다. 이 워커는 **어떤 페이지도 제어하지 않는다.**
// `fetch` 리스너가 없으므로 네트워크 경로에 끼어들 여지 자체가 없고,
// `clients.claim()`도 부르지 않는다. 페이지의 controller는 언제나 app shell
// SW 하나뿐이고, `getRegistrations()`는 정확히 둘(`/`, `/push-scope/`)이다.
//
// ── 금기 ────────────────────────────────────────────────────────────
// * `importScripts` 금지. Firebase SDK를 이 안으로 끌어오지 않는다. FCM
//   data 전용 메시지는 표준 Web Push 이벤트로 그대로 도착하므로 SDK 없이
//   읽을 수 있고, SDK를 넣는 순간 이 파일은 순수하지 않게 된다(자체 fetch·
//   IndexedDB·백그라운드 핸들러가 딸려 온다).
// * 캐싱 로직 금지. `fetch` 리스너를 절대 추가하지 않는다 — 추가하는 순간
//   두 SW가 같은 origin에서 캐시 주인 다툼을 시작한다.
//
// ── 서버 계약 ───────────────────────────────────────────────────────
// 서버는 FCM data 전용 push를 보낸다(`notification` 블록 없음 —
// dashboard-server `push/fcm.ts`의 `buildFcmMessage`). 그래서 배너는 이 파일이
// 직접 띄운다. push 이벤트 본문은 FCM 봉투다:
//
//   {"data": {...contracts/dashboard-protocol.v1.json push.data_keys...},
//    "from": "...", "fcmMessageId": "...", "priority": "normal"}
//
// 우리는 **`data` 키만** 읽는다. 봉투의 나머지는 전송 계층의 사정이다.
// data_keys: transition_id · session_key · state · source · project · host ·
// title · body · link (값은 전부 문자열).
//
// ── 테스트 가능성 ───────────────────────────────────────────────────
// 전역을 전부 `self.`로 접근한다(`clients`가 아니라 `self.clients`,
// `BroadcastChannel`이 아니라 `self.BroadcastChannel`). 그 덕에
// `app/scripts/web_push_smoke.py`가 이 파일의 소스를 그대로 받아
// `new Function('self', src)`로 가짜 `self`에 실행해, **배포되는 바로 그
// 바이트**의 파싱·tag 교체·클릭 분기를 브라우저 밖에서 검증할 수 있다.
// 이 규칙을 깨면(맨몸 `clients` 사용 등) 그 검증이 조용히 죽는다.

/** 알림 클릭·푸시 도착을 페이지에 알리는 통로. 페이지 쪽 수신자와 이름이 같아야 한다. */
const BROADCAST_CHANNEL_NAME = 'dashboard';

/** 열려 있는 창이 없을 때 여는 기본 경로. `data.link`가 비었을 때만 쓴다. */
const DEFAULT_LINK = '/';

/** 같은 세션의 알림은 쌓지 않고 갈아 끼운다 — `tag`가 그 열쇠다. */
function notificationTagFor(data) {
  const key = data.session_key;
  return typeof key === 'string' && key ? key : '';
}

/**
 * FCM 봉투에서 표시에 쓸 `data` 맵만 꺼낸다.
 * 봉투가 아니거나 `data`가 객체가 아니면 빈 맵이다(던지지 않는다 — push
 * 이벤트에서 던지면 브라우저가 "이 사이트가 백그라운드에서 갱신됨" 같은
 * 대체 알림을 대신 띄운다).
 */
function pushDataOf(event) {
  if (!event.data) return {};
  let envelope = null;
  try {
    envelope = event.data.json();
  } catch (error) {
    return {};
  }
  if (!envelope || typeof envelope !== 'object') return {};
  const data = envelope.data;
  return data && typeof data === 'object' ? data : {};
}

/** `data`를 showNotification 인자 한 쌍으로 옮긴다. */
function notificationFor(data) {
  const tag = notificationTagFor(data);
  const options = {
    body: typeof data.body === 'string' ? data.body : '',
    data: {
      link: typeof data.link === 'string' && data.link ? data.link : DEFAULT_LINK,
      transition_id: typeof data.transition_id === 'string' ? data.transition_id : '',
      session_key: typeof data.session_key === 'string' ? data.session_key : '',
    },
  };
  if (tag) {
    options.tag = tag;
    // `renotify`는 `tag` 없이 쓰면 TypeError다. 같은 세션의 새 전이가
    // 조용히 갈리지 않고 다시 알리게 한다.
    options.renotify = true;
  }
  const title = typeof data.title === 'string' && data.title ? data.title : '';
  return { title, options };
}

self.addEventListener('install', () => {
  // 새 워커가 곧바로 활성이 되게 한다. 이 scope에는 제어할 문서가 없으므로
  // 기다릴 클라이언트도 없다.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  // `clients.claim()`은 일부러 부르지 않는다 — 이 워커는 어떤 페이지도
  // 제어하지 않는다(파일 상단 주석 참고).
  event.waitUntil(Promise.resolve());
});

self.addEventListener('push', (event) => {
  const { title, options } = notificationFor(pushDataOf(event));
  // 정확히 한 번. push 이벤트 하나 = 배너 하나다.
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const payload = event.notification.data || {};
  const link = typeof payload.link === 'string' && payload.link ? payload.link : DEFAULT_LINK;

  event.waitUntil(
    (async () => {
      // `includeUncontrolled: true`가 핵심이다. 이 워커는 아무 페이지도
      // 제어하지 않으므로(scope가 다르다), 이 옵션이 없으면 목록이 항상
      // 비어서 클릭이 매번 새 창을 연다.
      const windows = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true,
      });

      // 열린 창이 있으면 그쪽으로 신호를 보낸다. 라우팅과 재동기화는
      // 페이지가 한다 — SW는 "이 세션을 열어라"까지만 말한다.
      if (windows.length > 0) {
        const channel = new self.BroadcastChannel(BROADCAST_CHANNEL_NAME);
        channel.postMessage({
          type: 'notification-click',
          // 페이지는 이 신호를 받으면 커서 재조회를 당긴다(push는 힌트일 뿐
          // 이고 정합성은 sync가 담보한다 — 정본 `push` 절).
          refresh: true,
          link,
          session_key: typeof payload.session_key === 'string' ? payload.session_key : '',
          transition_id: typeof payload.transition_id === 'string' ? payload.transition_id : '',
        });
        channel.close();

        const target = windows[0];
        if (typeof target.focus === 'function') await target.focus();
        return;
      }

      // 창이 하나도 없으면 새로 연다. 이때는 딥링크가 URL에 실린다.
      if (self.clients && typeof self.clients.openWindow === 'function') {
        await self.clients.openWindow(link);
      }
    })(),
  );
});
