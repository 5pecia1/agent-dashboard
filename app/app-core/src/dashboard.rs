//! 대시보드 세션 상태 어휘 — 정본은 `contracts/dashboard-protocol.v1.json`이다.
//!
//! 이 모듈은 그 계약을 Rust 도메인 타입으로 옮긴 것일 뿐 새 규칙을 만들지
//! 않는다: [`SessionState`]의 코드 문자열, [`label_key`]의 i18n 키,
//! [`EVENT_STATE_MAP`]의 (source, event) → state 매핑, [`SessionState::is_push_state`]의
//! push 대상 상태 2종(`done`은 2026-09-14 Sol 확정으로 제외)이 모두 계약 파일 값과
//! 바이트 단위로 같아야 하고,
//! 아래 `tests` 모듈이 계약 파일을 직접 읽어 대조한다 — 둘이 갈라지면
//! `cargo test --workspace`가 실패해 드리프트를 잡는다.
//!
//! `stalled`는 계약상 "derived"(서버 cron이 만드는) 상태라 이 크레이트가
//! 직접 만들어내지 않는다 — [`is_stale`]는 그 파생 조건과 같은 부등호
//! (엄격한 `>`)를 쓰는 순수 판정 함수일 뿐, 실제로 상태를 바꾸는 결정은
//! 서버 cron의 몫이다.

use core::cmp::Ordering;

/// 세션이 가질 수 있는 상태 6종. 계약의 `states.enum`이 어휘의 전부다.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum SessionState {
    /// 세션이 열려 있고 사람의 입력을 기다린다.
    Idle,
    /// 에이전트가 실행 중이다.
    Working,
    /// 질문·승인 대기. 사람이 답해야 진행된다.
    WaitingInput,
    /// 턴 실행을 마쳤다. 세션 자체는 살아 있다.
    Done,
    /// 세션이 끝났다. `SessionStart`로만 되살아난다.
    Ended,
    /// working이었는데 `DASHBOARD_STALL_MS` 동안 신호가 없다(서버가 만드는
    /// derived 상태 — 이 크레이트는 판정 부등호만 [`is_stale`]로 제공한다).
    Stalled,
}

impl SessionState {
    /// 상태 6종 전부, 계약의 `states.enum` 순서 그대로.
    pub const ALL: [Self; 6] = [
        Self::Idle,
        Self::Working,
        Self::WaitingInput,
        Self::Done,
        Self::Ended,
        Self::Stalled,
    ];

    /// 프로토콜 코드 문자열. `contracts/dashboard-protocol.v1.json`의
    /// `states.enum` 값과 바이트 단위로 같다 — 서버·hook·PWA와 이 문자열로
    /// 상태를 주고받는다.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::WaitingInput => "waiting_input",
            Self::Done => "done",
            Self::Ended => "ended",
            Self::Stalled => "stalled",
        }
    }

    /// [`code`](Self::code)의 역방향 조회. 계약 어휘에 없는 문자열은 `None` —
    /// 오타난 상태 문자열이 조용히 `Idle` 같은 기본값으로 떨어지지 않는다.
    #[must_use]
    pub fn from_code(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|state| state.code() == code)
    }

    /// 계약의 `push_states.enum` — 이 상태로 "전이"했을 때만 push를 보낸다.
    /// 화면 목록 정렬([`compare_session_order`])도 같은 집합을 "먼저 보여줄
    /// 상태"로 재사용한다 — 사람이 반응해야 하는 상태라는 뜻이 같기 때문이다.
    ///
    /// `Done`은 없다(2026-09-14, Sol 확정) — done은 "턴 실행을 마쳤다"일
    /// 뿐인데, 백그라운드 서브에이전트가 계속 일하면 조건부 승격이 곧바로
    /// working으로 되돌려 "끝났다" 알림 직후 "진행 중"이 이어지는 소음을
    /// 만들었다. 자세한 사유는 계약 `push_states.$note_done_excluded` 참고.
    #[must_use]
    pub const fn is_push_state(self) -> bool {
        matches!(self, Self::WaitingInput | Self::Stalled)
    }

    /// `ended`는 계약상 종결(terminal) 상태다 — `SessionStart` 이벤트로만
    /// 나갈 수 있고, 늦게 도착한 다른 이벤트가 되돌리지 못한다.
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Ended)
    }
}

/// 상태 → i18n 키. 계약의 `i18n.state_keys`와 값이 같다(`"state.<code>"`
/// 형태). `app_core::i18n`의 `EN`/`KO` 카탈로그가 이 키들을 정의해야 한다.
#[must_use]
pub const fn label_key(state: SessionState) -> &'static str {
    match state {
        SessionState::Idle => "state.idle",
        SessionState::Working => "state.working",
        SessionState::WaitingInput => "state.waiting_input",
        SessionState::Done => "state.done",
        SessionState::Ended => "state.ended",
        SessionState::Stalled => "state.stalled",
    }
}

/// 이벤트를 낸 에이전트 종류. 계약의 `sources.registered` 키와 같다.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum EventSource {
    /// Claude Code. lifecycle hook이 stdin JSON으로 이벤트를 준다.
    ClaudeCode,
    /// Codex CLI. lifecycle hook, 구버전은 notify(argv JSON) fallback.
    Codex,
    /// Devin CLI. lifecycle hook, JSONC config.json (주석 허용).
    Devin,
    /// 임의의 스크립트·CI가 직접 상태를 신고하는 통로. 고정된 이벤트
    /// 어휘가 없다 — [`EVENT_STATE_MAP`]에 이 소스의 행이 없는 이유다.
    Generic,
}

impl EventSource {
    /// 프로토콜 코드 문자열. 계약의 `sources.registered` 키와 같다.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
            Self::Devin => "devin",
            Self::Generic => "generic",
        }
    }
}

/// (source, event) → state 매핑 표. `contracts/dashboard-protocol.v1.json`의
/// `event_state_map.by_source`와 값이 완전히 같다 — 이 표를 데이터로 둔 이유는
/// hook 원본 이벤트 로그를 나중에 다시 훑어 상태를 재계산(replay)할 때도
/// (하드코딩된 `match` 분기가 아니라) 같은 표 하나만 순회하면 되게 하려는
/// 것이다("generic 재계산용"). `generic`은 이벤트 어휘가 없어 표에 행이
/// 없다 — 그 소스의 상태는 요청의 `state` 필드를 그대로 쓴다(계약의
/// `generic_rule`).
pub static EVENT_STATE_MAP: &[(EventSource, &str, SessionState)] = &[
    (EventSource::ClaudeCode, "SessionStart", SessionState::Idle),
    (
        EventSource::ClaudeCode,
        "UserPromptSubmit",
        SessionState::Working,
    ),
    (
        EventSource::ClaudeCode,
        "Notification",
        SessionState::WaitingInput,
    ),
    (EventSource::ClaudeCode, "Stop", SessionState::Done),
    (EventSource::ClaudeCode, "SessionEnd", SessionState::Ended),
    (EventSource::Codex, "SessionStart", SessionState::Idle),
    (
        EventSource::Codex,
        "UserPromptSubmit",
        SessionState::Working,
    ),
    (
        EventSource::Codex,
        "PermissionRequest",
        SessionState::WaitingInput,
    ),
    (EventSource::Codex, "Stop", SessionState::Done),
    (EventSource::Codex, "SessionEnd", SessionState::Ended),
    (
        EventSource::Codex,
        "agent-turn-complete",
        SessionState::Done,
    ),
    (
        EventSource::Codex,
        "UserInputRequest",
        SessionState::WaitingInput,
    ),
    (
        EventSource::Codex,
        "UserInputResolved",
        SessionState::Working,
    ),
    (EventSource::Devin, "SessionStart", SessionState::Idle),
    (
        EventSource::Devin,
        "UserPromptSubmit",
        SessionState::Working,
    ),
    (
        EventSource::Devin,
        "PermissionRequest",
        SessionState::WaitingInput,
    ),
    (EventSource::Devin, "Stop", SessionState::Done),
    (EventSource::Devin, "SessionEnd", SessionState::Ended),
    (
        EventSource::Devin,
        "UserInputRequest",
        SessionState::WaitingInput,
    ),
];

/// `EVENT_STATE_MAP`에서 `(source, event)`를 조회한다. 표에 없는 조합은
/// 계약(`event_state_map.description`, `heartbeat_events.rule`)에 따라
/// 상태를 바꾸지 않는다는 뜻의 `None`이다 — 기록만 하고 넘어간다.
#[must_use]
pub fn state_for_event(source: EventSource, event: &str) -> Option<SessionState> {
    EVENT_STATE_MAP
        .iter()
        .find(|(candidate_source, candidate_event, _)| {
            *candidate_source == source && *candidate_event == event
        })
        .map(|(_, _, state)| *state)
}

/// `updated_at`(epoch ms)부터 `now`까지 `stale_ms`를 **초과**해 지났으면
/// `true`. 계약의 stalled 파생 조건(`now - last_occurred_at > DASHBOARD_STALL_MS`)과
/// 같은 엄격한 부등호를 쓴다 — 경계값(정확히 `stale_ms`만큼 지난 순간)은
/// 아직 stale이 아니다. `now < updated_at`(시계 역전·경합)이면 음수 대신
/// 0으로 포화시켜 stale로 잘못 판정하지 않는다.
#[must_use]
pub const fn is_stale(now: i64, updated_at: i64, stale_ms: i64) -> bool {
    now.saturating_sub(updated_at) > stale_ms
}

/// 화면 목록 정렬에 필요한 최소 필드 — 상태와 마지막 갱신 시각.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionOrderKey {
    /// 현재 세션 상태.
    pub state: SessionState,
    /// 마지막 갱신 시각(epoch ms).
    pub updated_at: i64,
}

/// 정렬 비교자 — push 대상 상태(alert, [`SessionState::is_push_state`])가
/// 먼저 오고, 그 안에서는 `updated_at` 내림차순이다. `bool`의 `Ord`는
/// `false < true`라 그대로 비교하면 순서가 뒤집히므로 `b`를 기준으로
/// 비교해 뒤집는다. [`sort_sessions`]의 안정 정렬과 함께 쓰면 같은
/// 우선순위 항목은 입력 순서를 그대로 보존한다.
#[must_use]
pub fn compare_session_order(a: &SessionOrderKey, b: &SessionOrderKey) -> Ordering {
    b.state
        .is_push_state()
        .cmp(&a.state.is_push_state())
        .then_with(|| b.updated_at.cmp(&a.updated_at))
}

/// `sessions`를 "alert 우선 → `updated_at` 내림차순"으로 안정 정렬한다.
/// `slice::sort_by`가 안정 정렬이라 동일 우선순위 항목의 원래 순서(예:
/// 서버가 보내온 순서)는 그대로 유지된다.
pub fn sort_sessions(sessions: &mut [SessionOrderKey]) {
    sessions.sort_by(compare_session_order);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 정본 계약 파일. `app-core/src`에서 세 단계 위가 레포 루트다
    /// (`app-core/src` → `app-core` → `app` → repo root).
    const CONTRACT_JSON: &str = include_str!("../../../contracts/dashboard-protocol.v1.json");

    fn contract() -> serde_json::Value {
        serde_json::from_str(CONTRACT_JSON).expect("계약 파일은 유효한 JSON이어야 한다")
    }

    fn contract_str_array(value: &serde_json::Value, path: &[&str]) -> Vec<String> {
        let mut cursor = value;
        for key in path {
            cursor = cursor
                .get(key)
                .unwrap_or_else(|| panic!("계약 파일에 {path:?} 경로가 없다"));
        }
        cursor
            .as_array()
            .unwrap_or_else(|| panic!("{path:?}는 배열이어야 한다"))
            .iter()
            .map(|entry| {
                entry
                    .as_str()
                    .unwrap_or_else(|| panic!("{path:?} 원소는 문자열이어야 한다"))
                    .to_owned()
            })
            .collect()
    }

    #[test]
    fn 상태_코드는_계약의_states_enum과_순서까지_같다() {
        let expected = contract_str_array(&contract(), &["states", "enum"]);
        let ours: Vec<String> = SessionState::ALL
            .iter()
            .map(|s| s.code().to_owned())
            .collect();
        assert_eq!(ours, expected);
    }

    #[test]
    fn push_대상_상태는_계약의_push_states_enum과_같다() {
        let expected = contract_str_array(&contract(), &["push_states", "enum"]);
        let ours: Vec<String> = SessionState::ALL
            .iter()
            .filter(|s| s.is_push_state())
            .map(|s| s.code().to_owned())
            .collect();
        assert_eq!(ours, expected);
    }

    #[test]
    fn label_key는_계약의_i18n_state_keys와_전부_같다() {
        let contract = contract();
        let map = contract["i18n"]["state_keys"]
            .as_object()
            .expect("i18n.state_keys는 객체여야 한다");
        for state in SessionState::ALL {
            let expected = map[state.code()]
                .as_str()
                .unwrap_or_else(|| panic!("{}의 i18n 키가 문자열이 아니다", state.code()));
            assert_eq!(label_key(state), expected, "state={}", state.code());
        }
    }

    #[test]
    fn 이벤트_상태_매핑은_계약의_event_state_map과_완전히_같다() {
        let contract = contract();
        for (source_code, source) in [
            ("claude-code", EventSource::ClaudeCode),
            ("codex", EventSource::Codex),
            ("devin", EventSource::Devin),
            ("generic", EventSource::Generic),
        ] {
            let entries = contract["event_state_map"]["by_source"][source_code]
                .as_array()
                .unwrap_or_else(|| {
                    panic!("{source_code}의 event_state_map 항목은 배열이어야 한다")
                });
            let mut expected: Vec<(String, String)> = entries
                .iter()
                .map(|entry| {
                    (
                        entry["event"].as_str().expect("event는 문자열").to_owned(),
                        entry["state"].as_str().expect("state는 문자열").to_owned(),
                    )
                })
                .collect();
            expected.sort();

            let mut ours: Vec<(String, String)> = EVENT_STATE_MAP
                .iter()
                .filter(|(candidate_source, _, _)| *candidate_source == source)
                .map(|(_, event, state)| ((*event).to_owned(), state.code().to_owned()))
                .collect();
            ours.sort();

            assert_eq!(ours, expected, "source={source_code}");
        }
    }

    #[test]
    fn 표에_없는_이벤트는_상태를_바꾸지_않는다() {
        assert_eq!(
            state_for_event(EventSource::ClaudeCode, "PostToolUse"),
            None
        );
        assert_eq!(state_for_event(EventSource::Generic, "anything"), None);
    }

    #[test]
    fn from_code는_역방향_조회를_돌려주고_모르는_코드는_none이다() {
        assert_eq!(
            SessionState::from_code("waiting_input"),
            Some(SessionState::WaitingInput)
        );
        assert_eq!(SessionState::from_code("no-such-state"), None);
    }

    #[test]
    fn ended만_종결_상태다() {
        for state in SessionState::ALL {
            assert_eq!(
                state.is_terminal(),
                state == SessionState::Ended,
                "state={}",
                state.code()
            );
        }
    }

    #[test]
    fn is_stale_경계값은_stale이_아니고_한_틱_넘으면_stale이다() {
        assert!(!is_stale(1_000, 700, 300));
        assert!(is_stale(1_001, 700, 300));
        assert!(!is_stale(1_000, 1_000, 0));
        assert!(is_stale(1_000, 999, 0));
    }

    #[test]
    fn is_stale는_시계가_거슬러도_음수_경과로_stale이_되지_않는다() {
        assert!(!is_stale(500, 1_000, 0));
    }

    #[test]
    fn 정렬은_alert_우선_updated_at_내림차순이며_안정적이다() {
        let mut sessions = vec![
            SessionOrderKey {
                state: SessionState::Idle,
                updated_at: 100,
            },
            SessionOrderKey {
                state: SessionState::WaitingInput,
                updated_at: 50,
            },
            SessionOrderKey {
                state: SessionState::Done,
                updated_at: 200,
            },
            SessionOrderKey {
                state: SessionState::Working,
                updated_at: 300,
            },
            SessionOrderKey {
                state: SessionState::Stalled,
                updated_at: 50,
            },
        ];
        sort_sessions(&mut sessions);
        let ordered: Vec<SessionState> = sessions.iter().map(|s| s.state).collect();
        // alert(WaitingInput/Stalled) 그룹이 먼저, updated_at 내림차순. `Done`은
        // 2026-09-14(Sol 확정)부터 alert이 아니다 — 조건부 승격이 곧 working으로
        // 되돌리는 done을 push/정렬 우선순위로 올리면 오히려 소음이었다. 대신
        // 2순위 규칙(updated_at 내림차순)이 방금 끝난 세션을 여전히 위쪽에 둔다.
        // WaitingInput과 Stalled는 둘 다 50이라 동률 — 안정 정렬이 입력에서의
        // 원래 순서(WaitingInput이 Stalled보다 앞)를 그대로 지킨다.
        assert_eq!(
            ordered,
            vec![
                SessionState::WaitingInput,
                SessionState::Stalled,
                SessionState::Working,
                SessionState::Done,
                SessionState::Idle,
            ]
        );
    }
}
