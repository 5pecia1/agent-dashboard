// my_dashboard PWA bootstrap (Flutter의 기본 `flutter_bootstrap.js` 템플릿을 대체한다).
//
// 왜 손으로 쓰는가 — 이유는 둘이다.
//
// 1. Service worker를 우리가 등록한다. Flutter 3.29부터 생성되는
//    `flutter_service_worker.js`는 캐싱을 버리고 자기 자신을 unregister 하는
//    청소용 SW다. `serviceWorkerSettings`를 넘기지 않으면 Flutter loader는
//    SW를 전혀 건드리지 않으므로, 그 자리에 `web/my_dashboard_service_worker.js`를
//    등록한다. 앱을 띄우기 *전에* SW가 이 페이지를 제어하게 만드는 것이
//    핵심이다 — 그래야 셸 리소스(main.dart.js · canvaskit · pkg/*.wasm)가
//    전부 SW를 거쳐 캐시에 들어가고 다음 방문이 오프라인에서도 뜬다.
//
// 2. CanvasKit을 우리 origin에서 받는다. 기본값은 gstatic CDN인데, CDN에서
//    받는 렌더러는 캐시할 수 없고(cross-origin opaque) 오프라인에서 앱을
//    부팅 불가능하게 만든다. 오프라인 계약이 있는 PWA는 렌더러를 남의 집에
//    두면 안 된다.
//
// ── 금기 ──────────────────────────────────────────────────────────
// 빌드에 `--pwa-strategy`를 절대 추가하지 않는다 — `none`도 금지다.
// 이유: 이 플래그가 아래 `{{flutter_service_worker_version}}` 토큰 치환을
// 끊는다. 값이 채워지지 않으면(=null) 이 파일 뒤쪽의
// `solAppAwaitServiceWorkerControl()`이 즉시 리턴해 SW 등록을 건너뛴다.
// `flutter build web`은 그대로 성공(초록)하고, 콘솔 경고도 없다 — 그런데
// 오프라인 계약은 조용히 사라진다. 증상은 배포 뒤 오프라인에서 앱이 백지로
// 뜰 때에야 보인다. 이 계약은 빌드 성공 여부가 아니라 별도 스모크 체크로
// 검증한다.
{{flutter_js}}
{{flutter_build_config}}

// Flutter가 자기 SW를 켜고 끄던 신호를 그대로 쓴다. 정확히는:
// `--pwa-strategy`(숨김 · deprecated · 기본 `offline-first`)가 `none`이
// 아닐 때만 Flutter가 이 자리에 값을 넣고, 그 값은 콘텐츠 해시가 아니라
// **빌드마다 새로 뽑는 난수**다(flutter_tools `targets/web.dart`의
// `Random().nextInt(1 << 32)`). dev 서버(`flutter run -d chrome`)와
// `--pwa-strategy none`에서는 `null`이 되고, 그때는 SW를 아예 등록하지
// 않는다 — dev 루프에서 캐시가 낡은 코드를 되돌려주면 안 되기 때문이다.
// 빌드마다 값이 갈리는 덕에 셸 캐시 이름도 빌드 단위로 갈린다
// (`my_dashboard_service_worker.js`의 `APP_SHELL_CACHE_PREFIX` 주석).
const SOL_APP_SERVICE_WORKER_VERSION = {{flutter_service_worker_version}};
const SOL_APP_SERVICE_WORKER_URL = `my_dashboard_service_worker.js?v=${SOL_APP_SERVICE_WORKER_VERSION}`;
const SOL_APP_CANVASKIT_BASE_URL = 'canvaskit/';
// SW 등록이 어떤 이유로든 늦어져도 앱은 떠야 한다. Flutter loader가 자기
// SW에 쓰던 4초와 같은 자릿수.
const SOL_APP_SERVICE_WORKER_CONTROL_TIMEOUT_MS = 5000;

async function solAppAwaitServiceWorkerControl() {
  if (!('serviceWorker' in navigator) || SOL_APP_SERVICE_WORKER_VERSION === null) {
    return;
  }
  const expectedUrl = new URL(SOL_APP_SERVICE_WORKER_URL, document.baseURI).href;
  await navigator.serviceWorker.register(expectedUrl);
  await navigator.serviceWorker.ready;
  // An existing controller can still belong to the previous build. Loading
  // Flutter before the new worker claims this page leaves new assets in the
  // old cache, which activation then deletes and breaks an offline reload.
  await new Promise((resolve) => {
    const checkController = () => {
      if (navigator.serviceWorker.controller?.scriptURL === expectedUrl) {
        navigator.serviceWorker.removeEventListener('controllerchange', checkController);
        resolve();
      }
    };
    navigator.serviceWorker.addEventListener('controllerchange', checkController);
    checkController();
  });
}

function solAppWithTimeout(promise, timeoutMs, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${timeoutMs}ms`)),
      timeoutMs,
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

solAppWithTimeout(
  solAppAwaitServiceWorkerControl(),
  SOL_APP_SERVICE_WORKER_CONTROL_TIMEOUT_MS,
  'my_dashboard service worker control',
)
  .catch((error) => {
    console.warn('my_dashboard: service worker did not take control:', error);
  })
  .finally(() => {
    _flutter.loader.load({
      config: {
        canvasKitBaseUrl: SOL_APP_CANVASKIT_BASE_URL,
      },
    });
  });
