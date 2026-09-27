# 패키지 이전 DB 기준 fixture

`database.sql`, `expected.json`, `requests.json`은 서버 패키지 추출 전 revision `adb92a6b829477d36bda8301f05da7278372258e`의 격리 Worker에 합성 HTTP 요청을 보내 생성했습니다. 운영 DB·실제 토큰·사용자 프롬프트는 사용하지 않았습니다. Worker의 DB ID·이름·토큰·origin은 예제 값으로 교체했고 같은 persisted D1을 새 패키지 Worker에 연결해 검사했습니다.

보존 대상은 기존 SQL 다섯 개의 migration ledger, generic working/waiting/ended 세션, Devin 복수 대기, 읽음 표시, 음소거·언어, 기기 등록, hook revision입니다. `expected.json`의 SHA256은 SQL fixture 자체를 고정합니다. `npm run test:upgrade`는 이 fixture를 복원하여 패키지 SQL 적용이 무변경이고 조회·추가 수집이 기존 커서를 이어 가는지 검사합니다.

기대값을 현재 패키지로 다시 만들어 맞추지 않습니다. `scripts/verify-upgrade.mjs --capture-legacy <격리된 이전 Worker>`는 출처를 가진 이전 구현으로 기준을 새로 만들 때만 사용하는 명시적 도구입니다. 이 옵션은 대상 디렉터리의 Wrangler 설정을 로컬 예제 값으로 교체하므로 반드시 별도 임시 복사본을 지정합니다.
