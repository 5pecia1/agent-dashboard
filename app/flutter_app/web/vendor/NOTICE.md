# `web/vendor/` — Firebase JavaScript SDK (벤더링)

이 디렉토리에는 **서드파티 코드가 원본 그대로** 들어 있다. 우리 코드는 여기에
두지 않는다(웹 푸시 토큰 취득 어댑터는 한 층 위 `web/push_token_bridge.js`다).

## 왜 CDN이 아니라 벤더링인가

1. **오프라인 계약**. `web/my_dashboard_service_worker.js`는 same-origin GET만
   캐시한다(cross-origin 응답은 opaque라 셸에 넣을 수 없다). CDN에서 받는 SDK는
   오프라인 리로드에서 사라진다.
2. **COEP**. 로컬 검증 서버(`app/scripts/serve_web.py`)와 배포 헤더가
   `Cross-Origin-Embedder-Policy: require-corp`를 켤 수 있는 구성이다. CORP 헤더가
   없는 cross-origin 스크립트는 그 순간 조용히 차단된다.
3. **공급망**. 배포 시점의 바이트가 아래 SHA-256으로 고정된다.

## 무엇을 받았나

| 파일 | 업스트림 | 업스트림 SHA-256 (변환 전) |
|---|---|---|
| `firebase-app.js` | `https://www.gstatic.com/firebasejs/12.18.0/firebase-app.js` | `2fddac0600772c36b848b6b9651e52d00eb8f0a3656b5c24246cd8380b0e452a` |
| `firebase-messaging.js` | `https://www.gstatic.com/firebasejs/12.18.0/firebase-messaging.js` | `706471bb9556d9d1db301c6f48b015cbe507b80cdc6b6a07a438c1fbc53db6f6` |

라이선스: **Apache-2.0** (Copyright Google LLC). 원문은
<https://www.apache.org/licenses/LICENSE-2.0>. 각 파일 선두 배너에도 적어 두었다.

## 적용한 변환 (딱 둘)

1. 두 파일 모두 선두에 위 표와 같은 내용의 라이선스·출처 배너 주석을 붙였다.
   ESM 모듈에서 선두 주석은 의미를 바꾸지 않는다.
2. `firebase-messaging.js`의 **단 하나뿐인 import 지정자**를 same-origin
   상대 경로로 바꿨다. 이것을 하지 않으면 벤더링이 무의미하다 — 모듈이 실행되는
   순간 다시 gstatic으로 나간다.

   ```diff
   -import{...}from"https://www.gstatic.com/firebasejs/12.18.0/firebase-app.js";
   +import{...}from"./firebase-app.js";
   ```

   `firebase-app.js`에 남아 있는 `gstatic.com` 문자열 두 개는 네트워크 참조가
   아니라 SDK가 자기 자신을 부르는 **패키지 이름 상수**다(`name$q`, `logger`
   이름). 건드리지 않는다.

## 갱신 절차 (버전 올릴 때)

```sh
V=<새 버전>
curl -sSf "https://www.gstatic.com/firebasejs/$V/firebase-app.js"       -o /tmp/fb-app.orig.js
curl -sSf "https://www.gstatic.com/firebasejs/$V/firebase-messaging.js" -o /tmp/fb-msg.orig.js
shasum -a 256 /tmp/fb-app.orig.js /tmp/fb-msg.orig.js   # 이 표를 갱신한다
# 배너를 붙이고, 위 diff의 import 지정자 하나만 './firebase-app.js'로 바꾼다.
# 그 다음 반드시: python3 app/scripts/web_push_smoke.py 로 등록 2개·오프라인을 재확인한다.
grep -o '[^"]*gstatic\.com[^"]*' firebase-messaging.js   # 배너 밖에 남으면 실패다
```

두 파일은 서로의 버전을 가정한다. **항상 같은 버전으로 짝을 맞춰 받는다.**
