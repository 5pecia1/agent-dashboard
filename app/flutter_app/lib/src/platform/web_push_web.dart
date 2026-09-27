/// `web_push.dart`의 웹 구현 — FCM 등록 토큰을 실제로 받아 온다.
///
/// 흐름 넷, 순서가 곧 계약이다:
///
/// 1. **서비스 워커 등록.** `push_sw.js`를 `push-scope/`에 등록한다. app
///    shell SW(scope `/`)는 건드리지 않는다 — 이 앱의 등록은 그래서 정확히
///    둘이고, 페이지의 controller는 언제나 app shell SW다.
/// 2. **권한 확인(요청 아님).** `Notification.permission`이 `granted`가
///    아니면 [WebPushTokenStatus.permissionRequired]로 **즉시 돌아선다**.
///    Firebase의 `getToken()`은 권한이 `default`면 스스로 프롬프트를 띄우기
///    때문에(`web/vendor/firebase-messaging.js`), 이 확인을 건너뛰면 앱이
///    부팅하자마자 알림 권한 팝업을 던지는 앱이 된다. 프롬프트는 설정 화면의
///    버튼이 [requestWebPushPermission]을 부를 때만 뜬다.
/// 3. **SDK 어댑터 로드.** `push_token_bridge.js`(ESM)를 `<script
///    type="module">`로 한 번만 붙인다. `dart:js_interop`에는 dynamic
///    `import()`가 없어서 이 우회가 필요하다.
/// 4. **토큰 요청.** 우리가 등록한 registration을 그대로 넘긴다 — 넘기지
///    않으면 SDK가 `firebase-messaging-sw.js`를 자기 손으로 등록해 세 번째
///    등록이 생긴다.
///
/// **이 파일은 예외를 던지지 않는다.** 모든 실패가 [WebPushTokenResult]다.
/// 푸시는 깨우기 힌트일 뿐이고 정합성은 `GET /dashboard/sync` 폴링이
/// 담보한다(정본 `push` 절) — 푸시 실패로 앱이 멈추면 그 원칙이 깨진다.
///
/// `flutter test`(VM 타깃)는 이 파일을 절대 실행하지 않는다. 실제 검증은
/// `app/scripts/web_push_smoke.py`가 헤드리스 브라우저에서 한다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/platform/web_push.dart';

/// `push_token_bridge.js`가 로드를 마치면 `globalThis`에 얹는 이름.
const String _bridgeGlobal = 'solAppPushBridge';

/// 모듈은 페이지당 한 번만 붙인다. 두 번 부르면 SDK 인스턴스가 둘이 된다.
Future<bool>? _bridgeLoad;

Future<WebPushTokenResult> acquireWebPushToken(PushConfigDto config) async {
  final vapidKey = config.vapidKey;
  if (vapidKey == null || vapidKey.isEmpty || config.firebaseConfig.isEmpty) {
    // push_provider가 이미 canSubscribeOnWeb으로 걸렀어야 하는 자리다.
    return const WebPushTokenResult.unsupported('push-config에 자격증명이 없다');
  }
  if (!_hasServiceWorker() || !_hasNotification()) {
    return const WebPushTokenResult.unsupported(
      '이 브라우저에는 ServiceWorker/Notification이 없다',
    );
  }

  final web.ServiceWorkerRegistration registration;
  try {
    // 1. 별도 scope. app shell SW와 절대 겹치지 않는다.
    registration = await web.window.navigator.serviceWorker
        .register(
          kPushServiceWorkerUrl.toJS,
          web.RegistrationOptions(scope: kPushServiceWorkerScope),
        )
        .toDart;
  } on Object catch (error) {
    return WebPushTokenResult.failed('push_sw.js 등록 실패: $error');
  }

  // 2. 확인만 한다. 여기서 requestPermission을 부르지 않는다.
  if (currentWebPushPermission() != 'granted') {
    return WebPushTokenResult(
      WebPushTokenStatus.permissionRequired,
      detail: 'Notification.permission=${currentWebPushPermission()}',
    );
  }

  // 3.
  final bridge = await _loadBridge();
  if (bridge == null) {
    return const WebPushTokenResult.failed('push_token_bridge.js를 불러오지 못했다');
  }

  // 4.
  try {
    final promise = bridge.callMethodVarArgs<JSPromise<JSObject>>(
      'requestFcmToken'.toJS,
      <JSAny?>[
        jsonEncode(config.firebaseConfig).toJS,
        vapidKey.toJS,
        registration,
      ],
    );
    return _resultFrom(await promise.toDart);
  } on Object catch (error) {
    return WebPushTokenResult.failed('requestFcmToken 호출 실패: $error');
  }
}

/// 설정 화면의 명시적 버튼만 부른다. 부팅 경로에서는 절대 부르지 않는다.
Future<bool> requestWebPushPermission() async {
  if (!_hasNotification()) return false;
  try {
    final granted = await web.Notification.requestPermission().toDart;
    return granted.toDart == 'granted';
  } on Object {
    return false;
  }
}

/// 지금의 알림 권한(`default` | `granted` | `denied`). API 자체가 없으면
/// `unsupported`를 돌려준다 — 화면이 상태를 그대로 보여줄 수 있게.
String currentWebPushPermission() {
  if (!_hasNotification()) return 'unsupported';
  try {
    return web.Notification.permission;
  } on Object {
    return 'unsupported';
  }
}

// ─── 내부 ────────────────────────────────────────────────────────────────

bool _hasServiceWorker() => web.window.navigator.has('serviceWorker');

bool _hasNotification() => globalContext.has('Notification');

/// `<script type="module">`을 한 번만 붙이고, 모듈이 `globalThis`에 얹는
/// 손잡이가 나타날 때까지 기다린다. 실패해도 던지지 않는다.
Future<JSObject?> _loadBridge() async {
  final existing = globalContext.getProperty<JSObject?>(_bridgeGlobal.toJS);
  if (existing != null) return existing;

  _bridgeLoad ??= _appendBridgeScript();
  final loaded = await _bridgeLoad!;
  if (!loaded) {
    // 다음 시도가 다시 붙여 볼 수 있게 실패는 기억하지 않는다.
    _bridgeLoad = null;
    return null;
  }
  return globalContext.getProperty<JSObject?>(_bridgeGlobal.toJS);
}

Future<bool> _appendBridgeScript() {
  final completer = Completer<bool>();
  final script = web.HTMLScriptElement()
    ..type = 'module'
    ..src = kPushBridgeModuleUrl;
  script.addEventListener(
    'load',
    ((web.Event _) {
      if (!completer.isCompleted) completer.complete(true);
    }).toJS,
  );
  script.addEventListener(
    'error',
    ((web.Event _) {
      if (!completer.isCompleted) completer.complete(false);
    }).toJS,
  );
  web.document.head?.appendChild(script);
  return completer.future;
}

WebPushTokenResult _resultFrom(JSObject? response) {
  if (response == null) {
    return const WebPushTokenResult.failed('브리지가 빈 응답을 돌려줬다');
  }
  final status = webPushTokenStatusFromWire(
    response.getProperty<JSString?>('status'.toJS)?.toDart ?? '',
  );
  final token = response.getProperty<JSString?>('token'.toJS)?.toDart;
  final detail = response.getProperty<JSString?>('detail'.toJS)?.toDart ?? '';
  if (status == WebPushTokenStatus.acquired && (token == null || token.isEmpty)) {
    return const WebPushTokenResult.failed('acquired인데 토큰이 비어 있다');
  }
  return WebPushTokenResult(status, token: token, detail: detail);
}
