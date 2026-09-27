/*
 * FCM 웹 토큰 취득 어댑터 — 벤더링한 Firebase SDK와 Dart 사이의 얇은 한 겹.
 *
 * 이 파일은 **우리 코드**다(서드파티는 `vendor/`에만 있다). ESM이라
 * `<script type="module">`로만 로드되고, 로드가 끝나면 `globalThis`에
 * 함수 하나를 얹는다 — `dart:js_interop`에서 dynamic `import()`를 직접 쓸 수
 * 없기 때문에 필요한 손잡이다(`lib/src/platform/web_push_web.dart` 참고).
 *
 * 계약 셋:
 *
 * 1. **`Notification.requestPermission()`을 여기서 절대 먼저 부르지 않는다.**
 *    Firebase의 `getToken()`은 권한이 `default`면 스스로 프롬프트를 띄운다
 *    (`vendor/firebase-messaging.js`의 `"default"===Notification.permission&&
 *    await Notification.requestPermission()`). 그래서 이 파일은 권한이
 *    `granted`가 **아닐 때 getToken을 호출하지 않고** `permission-required`로
 *    돌아선다. 프롬프트는 설정 화면의 명시적 버튼 뒤에서만 뜬다.
 * 2. **서비스 워커를 여기서 등록하지 않는다.** 호출자가 이미 등록한
 *    `push_sw.js` registration을 그대로 받아 `getToken`에 넘긴다. 넘기지
 *    않으면 SDK가 `firebase-messaging-sw.js`를 자기 손으로 등록해 버려
 *    등록이 셋이 된다(완료 기준 (a)의 "정확히 2개"가 깨진다).
 * 3. **던지지 않는다.** 모든 결과가 `{status, token, detail}` 한 모양이다.
 *    푸시는 "있으면 좋은 깨우기 힌트"고, 없으면 폴링이 정합성을 담보한다
 *    (정본 `push` 절). 실패가 앱을 멈추게 두지 않는다.
 */

// same-origin import만 쓴다. CDN에서 받으면 (1) app shell SW가 cross-origin
// 응답을 캐시할 수 없어 오프라인에서 사라지고 (2) COEP require-corp를 켜는
// 순간 조용히 차단된다. 벤더링 근거·갱신 절차는 vendor/NOTICE.md,
// COI 판정(현재 coiRequired=false)과 재측정 조건은 app/README.md 참고.
import { deleteApp, getApps, initializeApp } from './vendor/firebase-app.js';
import { getMessaging, getToken, isSupported } from './vendor/firebase-messaging.js';

/** 이 페이지가 쓰는 Firebase app 인스턴스 이름. 호스트 앱의 다른 인스턴스와 섞이지 않게 한다. */
const APP_NAME = 'my-dashboard-push';

/** `status` 값. Dart 쪽 `WebPushTokenStatus`와 문자열이 1:1로 맞아야 한다. */
const STATUS = {
  acquired: 'acquired',
  permissionRequired: 'permission-required',
  unsupported: 'unsupported',
  failed: 'failed',
};

function result(status, token, detail) {
  return { status, token: token ?? null, detail: detail ?? '' };
}

/** 이미 만들어 둔 인스턴스가 있으면 재사용하고, 설정이 바뀌었으면 버리고 새로 만든다. */
function appFor(webConfig) {
  const existing = getApps().find((app) => app.name === APP_NAME);
  if (existing) {
    const same = JSON.stringify(existing.options) === JSON.stringify(webConfig);
    if (same) return existing;
    // 서버가 키를 회전했다. 낡은 인스턴스를 들고 있으면 새 프로젝트의 토큰을
    // 받을 수 없다. 정리 실패는 무시한다(다음 줄에서 어차피 새로 만든다).
    try {
      deleteApp(existing);
    } catch (error) {
      /* 무시 */
    }
  }
  return initializeApp(webConfig, APP_NAME);
}

/**
 * 설정 맵을 JSON **문자열**로 받는다.
 *
 * Dart(`dart:js_interop`)에서 `Map<String, Object?>`를 JS 객체로 옮기려면
 * dart2js/dart2wasm 양쪽에서 다르게 동작하는 변환을 타야 한다. 문자열 하나는
 * 두 컴파일러에서 똑같이 안전하다 — 경계를 좁게 유지한다.
 */
function parseWebConfig(webConfigJson) {
  if (webConfigJson && typeof webConfigJson === 'object') return webConfigJson;
  if (typeof webConfigJson !== 'string' || !webConfigJson) return null;
  try {
    const parsed = JSON.parse(webConfigJson);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (error) {
    return null;
  }
}

/**
 * FCM 웹 등록 토큰을 받아 온다.
 *
 * @param {string} webConfigJson  서버 `GET /dashboard/push-config`의 `fcm.web_config`를 JSON으로 직렬화한 문자열.
 * @param {string} vapidKey   같은 응답의 `fcm.vapid_key`.
 * @param {ServiceWorkerRegistration} registration  호출자가 등록한 `push_sw.js`.
 * @returns {Promise<{status: string, token: string|null, detail: string}>}
 */
async function requestFcmToken(webConfigJson, vapidKey, registration) {
  try {
    const webConfig = parseWebConfig(webConfigJson);
    if (!webConfig || Object.keys(webConfig).length === 0 || !vapidKey) {
      return result(STATUS.unsupported, null, 'push-config에 web_config/vapid_key가 없다');
    }
    if (!registration) {
      return result(STATUS.failed, null, 'push_sw.js registration이 없다');
    }
    if (typeof Notification === 'undefined' || !('serviceWorker' in navigator)) {
      return result(STATUS.unsupported, null, '이 브라우저에는 Notification/ServiceWorker가 없다');
    }
    if (!(await isSupported())) {
      return result(STATUS.unsupported, null, 'firebase-messaging이 이 브라우저를 지원하지 않는다');
    }
    // 계약 1. 여기서 돌아서지 않으면 SDK가 프롬프트를 띄운다.
    if (Notification.permission !== 'granted') {
      return result(STATUS.permissionRequired, null, `Notification.permission=${Notification.permission}`);
    }

    const messaging = getMessaging(appFor(webConfig));
    const token = await getToken(messaging, {
      vapidKey,
      serviceWorkerRegistration: registration, // 계약 2.
    });
    if (!token) return result(STATUS.failed, null, 'getToken이 빈 토큰을 돌려줬다');
    return result(STATUS.acquired, token, '');
  } catch (error) {
    // 계약 3.
    return result(STATUS.failed, null, String((error && error.message) || error));
  }
}

globalThis.solAppPushBridge = { requestFcmToken, STATUS };
