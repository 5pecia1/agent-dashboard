"""Product gates require only local server source and reject independently changed inputs."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(root=ROOT):
    spec = importlib.util.spec_from_file_location("contract_check_test", root / "scripts/contract_check.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ContractConsumerTests(unittest.TestCase):
    @unittest.skipUnless((ROOT / ".github/workflows/sol-platform.yml").is_file(),
                         "Internal platform workflow is not part of the public product")
    def test_ci_uploads_only_bounded_failure_diagnostics_for_one_day(self):
        workflow = (ROOT / ".github/workflows/sol-platform.yml").read_text(encoding="utf-8")
        artifact = workflow.split("- uses: actions/upload-artifact@", 1)[1]
        self.assertIn("if: failure()", artifact)
        self.assertIn("retention-days: 1", artifact)
        for path in (
            "${{ runner.temp }}/platform-evidence/image.json",
            "${{ runner.temp }}/platform-evidence/execution/*.log",
            "${{ runner.temp }}/platform-evidence/checks/*.log",
            "${{ runner.temp }}/platform-evidence/checks/wasm-sha256.json",
            "${{ runner.temp }}/platform-evidence/checks/headers.txt",
            "${{ runner.temp }}/platform-evidence/checks/web/result.json",
            "${{ runner.temp }}/platform-evidence/checks/web/*.png",
            "${{ runner.temp }}/platform-evidence/checks/flutter-test/**/*.png",
        ):
            self.assertIn(path, artifact)
        self.assertNotIn("path: ${{ runner.temp }}/platform-evidence/", artifact)

    def test_standalone_checkout_passes_without_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in ("scripts/contract_check.py", "server/src", "server/contracts",
                             "contracts", "hooks", "app/app-core/src/dashboard.rs",
                             "app/flutter_app/lib/src/data/dashboard_api.dart",
                             "app/flutter_app/web/push_sw.js"):
                source, target = ROOT / relative, root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target)
                else:
                    shutil.copyfile(source, target)
            self.assertFalse((root / "unrelated-private-checkout").exists())
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(load(root).main([]), 0)
            self.assertIn("no private checkout required", output.getvalue())

    def test_changed_package_contract_is_rejected(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "contracts").mkdir()
            (root / "contracts/dashboard-protocol.v1.json").write_bytes(checker.CANONICAL_PATH.read_bytes() + b" ")
            with self.assertRaisesRegex(checker.CheckFailure, "differs"):
                checker.check_package_assets(root)

    def test_changed_rust_mapping_fails_even_when_snapshot_is_unchanged(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "dashboard.rs"
            text = checker.DASHBOARD_RS_PATH.read_text()
            original = '"UserPromptSubmit",\n        SessionState::Working'
            self.assertIn(original, text)
            changed.write_text(text.replace(original, '"UserPromptSubmit",\n        SessionState::Done', 1))
            with patch.object(checker, "DASHBOARD_RS_PATH", changed):
                with self.assertRaises(checker.CheckFailure):
                    checker.check_dashboard_rs(checker.load_canonical())

    def test_changed_client_wire_key_fails(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "api.dart"
            text = checker.DASHBOARD_API_DART_PATH.read_text()
            self.assertIn("'lang': value", text)
            changed.write_text(text.replace("'lang': value", "'ui_lang': value"))
            with patch.object(checker, "DASHBOARD_API_DART_PATH", changed):
                with self.assertRaises(checker.CheckFailure):
                    checker.check_client_ui_lang_wire_keys(checker.load_canonical())

    def test_explicit_missing_server_fails_instead_of_skipping(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(checker.main(["--server-root", temporary]), 1)

    def test_changed_hook_manifest_is_rejected(self):
        checker = load()
        checker.configure_server_root(ROOT / "server")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "hooks-manifest.json"
            manifest = json.loads(checker.HOOK_MANIFEST_PATH.read_text())
            manifest["sha256"]["setup.sh"] = "0" * 64
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(checker.CheckFailure, "SHA256"):
                checker.check_hook_manifest(path)

    def test_generated_hook_payload_drift_is_rejected(self):
        checker = load()
        checker.configure_server_root(ROOT / "server")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "hooks.ts"
            content = checker.GENERATED_HOOKS_PATH.read_text()
            self.assertIn("#!/usr/bin/env bash", content)
            path.write_text(content.replace("#!/usr/bin/env bash", "#!/bin/false", 1))
            with patch.object(checker, "GENERATED_HOOKS_PATH", path):
                with self.assertRaisesRegex(checker.CheckFailure, "strings differ"):
                    checker.check_hooks_dist_byte_identical()

    def test_devin_input_check_skips_when_pinned_contract_lacks_tracking(self):
        checker = load()
        contract = checker.load_canonical()
        contract.get("event_state_map", {}).pop("devin_input_tracking", None)
        result = checker.check_devin_input_translation(contract)
        self.assertIsInstance(result, tuple)
        self.assertTrue(result[1])

    def test_devin_input_check_passes_with_tracking_contract(self):
        checker = load()
        result = checker.check_devin_input_translation(checker.load_canonical())
        self.assertIsInstance(result, str)

    def test_devin_metadata_field_removal_fails(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "agent-event-hook.sh"
            text = checker.AGENT_EVENT_HOOK_PATH.read_text()
            self.assertIn("prompt_id: (.prompt_id | corr_id)", text)
            changed.write_text(text.replace("prompt_id: (.prompt_id | corr_id)", "prompt_id: .prompt_id"))
            with patch.object(checker, "AGENT_EVENT_HOOK_PATH", changed):
                with self.assertRaises(checker.CheckFailure):
                    checker.check_devin_input_translation(checker.load_canonical())

    def test_devin_throttle_exemption_removal_fails(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "agent-event-hook.sh"
            text = checker.AGENT_EVENT_HOOK_PATH.read_text()
            self.assertIn('"$IS_DEVIN_COMPLETION" = "true"', text)
            changed.write_text(text.replace('"$IS_DEVIN_COMPLETION" = "true"', '"$IS_DEVIN_COMPLETION" = "maybe"'))
            with patch.object(checker, "AGENT_EVENT_HOOK_PATH", changed):
                with self.assertRaises(checker.CheckFailure):
                    checker.check_devin_input_translation(checker.load_canonical())

    def test_devin_exact_match_must_not_use_normalized_tool_name(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "agent-event-hook.sh"
            text = checker.AGENT_EVENT_HOOK_PATH.read_text()
            self.assertIn('.tool_name == "ask_user_question"', text)
            changed.write_text(text.replace('.tool_name == "ask_user_question"', '$norm_tool == "askuserquestion"'))
            with patch.object(checker, "AGENT_EVENT_HOOK_PATH", changed):
                with self.assertRaises(checker.CheckFailure):
                    checker.check_devin_input_translation(checker.load_canonical())

    def test_devin_installer_matcher_removal_fails(self):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / "install.sh"
            text = checker.INSTALL_SH_PATH.read_text()
            self.assertIn('"^ask_user_question$"', text)
            changed.write_text(text.replace('"^ask_user_question$"', '"^ask_user_question"'))
            with patch.object(checker, "INSTALL_SH_PATH", changed):
                with self.assertRaises(checker.CheckFailure):
                    checker.check_devin_input_translation(checker.load_canonical())

    def test_devin_contract_field_definition_removal_fails(self):
        checker = load()
        contract = checker.load_canonical()
        del contract["event_payload"]["fields"]["tool_use_id"]
        with self.assertRaises(checker.CheckFailure):
            checker.check_devin_input_translation(contract)


class AntigravityHookTranslationTests(unittest.TestCase):
    """agent-event-hook.sh의 antigravity 분기가 정본 antigravity_hook_translation을 따르는가."""

    def assert_hook_change_fails(self, original, changed, message=None):
        checker = load()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "agent-event-hook.sh"
            text = checker.AGENT_EVENT_HOOK_PATH.read_text()
            self.assertIn(original, text)
            path.write_text(text.replace(original, changed))
            with patch.object(checker, "AGENT_EVENT_HOOK_PATH", path):
                with self.assertRaisesRegex(checker.CheckFailure, message or "."):
                    checker.check_antigravity_hook_translation(checker.load_canonical())

    def test_passes_with_canonical_contract(self):
        checker = load()
        self.assertIsInstance(checker.check_antigravity_hook_translation(checker.load_canonical()), str)

    def test_rust_mapping_covers_antigravity(self):
        self.assertEqual(load().EVENT_SOURCE_VARIANT_TO_CODE["Antigravity"], "antigravity")

    def test_skips_when_pinned_contract_lacks_antigravity(self):
        checker = load()
        contract = checker.load_canonical()
        del contract["event_state_map"]["antigravity_hook_translation"]
        del contract["sources"]["registered"]["antigravity"]
        result = checker.check_antigravity_hook_translation(contract)
        self.assertIsInstance(result, tuple)
        self.assertTrue(result[1])

    def test_registered_source_without_translation_fails(self):
        checker = load()
        contract = checker.load_canonical()
        del contract["event_state_map"]["antigravity_hook_translation"]
        with self.assertRaises(checker.CheckFailure):
            checker.check_antigravity_hook_translation(contract)

    def test_contract_question_tools_drift_fails(self):
        checker = load()
        contract = checker.load_canonical()
        contract["event_state_map"]["antigravity_hook_translation"]["question_tools"].append("ask_user")
        with self.assertRaisesRegex(checker.CheckFailure, "question_tools"):
            checker.check_antigravity_hook_translation(contract)

    def test_hook_question_tools_change_fails(self):
        self.assert_hook_change_fails('["ask_question", "ask_permission"]', '["ask_question"]', "question_tools")

    def test_normalized_tool_name_fails(self):
        self.assert_hook_change_fails(
            "(try .toolCall.name catch null) as $antigravity_tool",
            "(try (.toolCall.name | ascii_downcase) catch null) as $antigravity_tool",
        )

    def test_turn_start_rule_change_fails(self):
        self.assert_hook_change_fails(
            '(.invocationNum | antigravity_num) >= 1 then "AntigravityIgnored"',
            '(.invocationNum | antigravity_num) >= 2 then "AntigravityIgnored"',
            "턴 시작",
        )

    def test_numeric_guard_removal_fails(self):
        self.assert_hook_change_fails(
            'if type == "number" then . else null end;', "if type == \"number\" then . else . end;"
        )

    def test_subagent_rule_change_fails(self):
        self.assert_hook_change_fails(
            "(.initialNumSteps | antigravity_num) == 0", "(.initialNumSteps | antigravity_num) <= 1", "서브에이전트"
        )

    def test_fully_idle_drop_in_jq_fails(self):
        self.assert_hook_change_fails(
            'elif $raw_event == "Stop" then\n               "Stop"',
            'elif $raw_event == "Stop" then\n'
            '               (if .fullyIdle == false then "AntigravityIgnored" else "Stop" end)',
            "fullyIdle",
        )

    def test_fully_idle_drop_in_bash_fails(self):
        self.assert_hook_change_fails(
            "    Stop)\n      # 래치는",
            "    Stop)\n      printf '%s' \"$INPUT\" | jq -e '.fullyIdle == false' >/dev/null && return 1\n"
            "      # 래치는",
            "fullyIdle",
        )

    def test_contract_stop_rule_must_send_every_stop(self):
        checker = load()
        contract = checker.load_canonical()
        rules = contract["event_state_map"]["antigravity_hook_translation"]["rules"]
        index = next(i for i, rule in enumerate(rules) if rule.startswith("Stop:"))
        rules[index] = "Stop: fullyIdle이 정확히 false면 보내지 않는다(도구 단계 사이의 Stop). 그 밖에는 Stop을 보낸다."
        with self.assertRaisesRegex(checker.CheckFailure, "Stop 규칙"):
            checker.check_antigravity_hook_translation(contract)

    def test_contract_latch_rule_must_cover_every_stop(self):
        checker = load()
        contract = checker.load_canonical()
        rules = contract["event_state_map"]["antigravity_hook_translation"]["rules"]
        index = next(i for i, rule in enumerate(rules) if "기록용" in rule)
        rules[index] = rules[index].replace("모든 Stop(fullyIdle 값과 상관없이)을", "fullyIdle Stop을")
        with self.assertRaisesRegex(checker.CheckFailure, "래치 규칙"):
            checker.check_antigravity_hook_translation(contract)

    def test_latched_restart_removal_fails(self):
        self.assert_hook_change_fails(
            '                elif $antigravity_latched == "1" then "UserPromptSubmit"\n', "", "래치")

    def test_subagent_detection_must_precede_latched_restart(self):
        subagent = ('(if (.invocationNum | antigravity_num) == 0 and (.initialNumSteps | antigravity_num) == 0 '
                    'then "AntigravitySubagentStart"\n')
        latched = '                elif $antigravity_latched == "1" then "UserPromptSubmit"\n'
        self.assert_hook_change_fails(
            subagent + latched,
            '(if $antigravity_latched == "1" then "UserPromptSubmit"\n                elif '
            + subagent.removeprefix("(if "),
            "서브에이전트",
        )

    def test_latched_flag_must_come_from_latch_file(self):
        self.assert_hook_change_fails(
            '&& ANTIGRAVITY_LATCHED=1', '&& ANTIGRAVITY_LATCHED=0', "ANTIGRAVITY_LATCHED")

    def test_contract_turn_start_rule_must_cover_latched_restart(self):
        checker = load()
        contract = checker.load_canonical()
        rules = contract["event_state_map"]["antigravity_hook_translation"]["rules"]
        index = next(i for i, rule in enumerate(rules) if rule.startswith("PreInvocation:"))
        rules[index] = rules[index].split(" Stop을 처리한 뒤", 1)[0]
        with self.assertRaisesRegex(checker.CheckFailure, "턴 시작 규칙"):
            checker.check_antigravity_hook_translation(contract)

    def test_every_stop_must_set_latch(self):
        self.assert_hook_change_fails(
            '      mkdir -p "$ANTIGRAVITY_DIR/stopped" 2>/dev/null && : > "$ANTIGRAVITY_DIR/stopped/$key" 2>/dev/null\n',
            "",
            "래치를 건다",
        )

    def test_non_question_pre_tool_use_must_be_dropped(self):
        self.assert_hook_change_fails(
            'then "UserInputRequest" else "AntigravityIgnored" end',
            'then "UserInputRequest" else "PreToolUse" end',
            "PreToolUse",
        )

    def test_unknown_events_must_be_dropped(self):
        self.assert_hook_change_fails(
            'else\n               "AntigravityIgnored"\n             end)',
            "else\n               $raw_event\n             end)",
            "그 밖의 이벤트",
        )

    def test_stdout_answer_change_fails(self):
        self.assert_hook_change_fails(
            """PreToolUse) ANTIGRAVITY_ANSWER='{"decision":"ask"}' ;;""",
            """PreToolUse) ANTIGRAVITY_ANSWER='{"decision":"allow"}' ;;""",
            "stdout_contract",
        )

    def test_answer_after_stdin_fails(self):
        checker = load()
        text = checker.AGENT_EVENT_HOOK_PATH.read_text()
        answer = "  ( printf '%s\\n' \"$ANTIGRAVITY_ANSWER\" ) 2>/dev/null\n"
        read_stdin = 'INPUT="$(cat 2>/dev/null)"\n'
        self.assertIn(answer, text)
        self.assertIn(read_stdin, text)
        moved = text.replace(answer, "").replace(read_stdin, read_stdin + answer.strip() + "\n")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "agent-event-hook.sh"
            path.write_text(moved)
            with patch.object(checker, "AGENT_EVENT_HOOK_PATH", path):
                with self.assertRaisesRegex(checker.CheckFailure, "순서"):
                    checker.check_antigravity_hook_translation(checker.load_canonical())

    def test_dropped_names_must_not_reach_server(self):
        self.assert_hook_change_fails("antigravity_admit || exit 0", "antigravity_admit || true", "admit")

    def test_project_must_not_fall_back_to_hook_cwd(self):
        self.assert_hook_change_fails(
            'if type == "string" and . != "" then . else "unknown" end',
            'if type == "string" and . != "" then . else $project_fallback end',
            "project",
        )

    def test_print_flag_removal_fails(self):
        self.assert_hook_change_fails("p|print|prompt) return 0 ;;", "p|print) return 0 ;;", "print 모드 플래그")

    def test_interactive_prompt_must_stop_flag_scan(self):
        self.assert_hook_change_fails("i|prompt-interactive) return 1 ;;", "i) return 1 ;;", "대화형")

    def test_single_dash_go_flags_must_be_read(self):
        self.assert_hook_change_fails('          -*) name="${arg#-}" ;;\n', "", "Go flag")

    def test_contract_print_flags_are_names(self):
        checker = load()
        contract = checker.load_canonical()
        contract["event_state_map"]["antigravity_hook_translation"]["print_mode"]["flags"] = ["-p", "--print", "--prompt"]
        with self.assertRaisesRegex(checker.CheckFailure, "print 모드 플래그"):
            checker.check_antigravity_hook_translation(contract)

    def test_contract_interactive_flags_required(self):
        checker = load()
        contract = checker.load_canonical()
        del contract["event_state_map"]["antigravity_hook_translation"]["print_mode"]["interactive_flags"]
        with self.assertRaisesRegex(checker.CheckFailure, "대화형"):
            checker.check_antigravity_hook_translation(contract)

    def test_latch_must_cover_question_tool_resolution(self):
        self.assert_hook_change_fails("PostToolUse|UserInputResolved)", "PostToolUse)", "UserInputResolved")

    def test_contract_latch_rule_must_cover_question_tools(self):
        checker = load()
        contract = checker.load_canonical()
        rules = contract["event_state_map"]["antigravity_hook_translation"]["rules"]
        index = next(i for i, rule in enumerate(rules) if "기록용" in rule)
        rules[index] = rules[index].replace("(질문 도구 포함)", "")
        with self.assertRaisesRegex(checker.CheckFailure, "래치 규칙"):
            checker.check_antigravity_hook_translation(contract)

    def test_budget_call_site_in_acquire_lock_required(self):
        self.assert_hook_change_fails("    antigravity_budget_spent && return 1\n", "", "acquire_lock")

    def test_budget_call_site_in_flush_required(self):
        self.assert_hook_change_fails(
            'if [ "$stop_on_failure" -eq 1 ] || antigravity_budget_spent; then',
            'if [ "$stop_on_failure" -eq 1 ]; then',
            "flush_spool",
        )

    def test_spool_order_call_site_required(self):
        self.assert_hook_change_fails("! antigravity_spool_behind && ", "", "스풀 순서")

    def test_spool_behind_only_when_no_response(self):
        self.assert_hook_change_fails(' && [ "${LAST_SEND_CODE:-}" = "000" ]', "", "000")

    def test_last_send_code_must_be_initialised(self):
        self.assert_hook_change_fails('\nLAST_SEND_CODE=""\n', "\n", "LAST_SEND_CODE")

    CARRY_OVER = (
        '  local taken\n'
        '  taken="$(wc -l < "$head_file" 2>/dev/null | tr -d \' \')"\n'
        '  case "$taken" in\n'
        "    ''|*[!0-9]*) taken=0 ;;\n"
        '  esac\n'
        '  tail -n +"$((taken + 1))" "$SPOOL_FILE" >> "$remaining_file" 2>/dev/null\n'
    )

    def test_flush_must_carry_lines_appended_during_replay(self):
        self.assert_hook_change_fails(
            self.CARRY_OVER,
            '  if [ "$total" -gt "$FLUSH_MAX_LINES" ]; then\n'
            '    tail -n +"$((FLUSH_MAX_LINES + 1))" "$SPOOL_FILE" >> "$remaining_file" 2>/dev/null\n'
            '  fi\n',
            "flush_spool",
        )

    def test_flush_must_count_lines_actually_taken(self):
        self.assert_hook_change_fails(
            self.CARRY_OVER,
            '  local taken="$total"\n'
            '  [ "$taken" -gt "$FLUSH_MAX_LINES" ] && taken="$FLUSH_MAX_LINES"\n'
            '  tail -n +"$((taken + 1))" "$SPOOL_FILE" >> "$remaining_file" 2>/dev/null\n',
            "head_file",
        )

    def test_contract_budget_rule_must_queue_behind_spool(self):
        checker = load()
        contract = checker.load_canonical()
        rules = contract["event_state_map"]["antigravity_hook_translation"]["rules"]
        index = next(i for i, rule in enumerate(rules) if "스풀 재전송" in rule)
        rules[index] = rules[index].split(" 재전송이 서버 응답을", 1)[0]
        with self.assertRaisesRegex(checker.CheckFailure, "스풀 규칙"):
            checker.check_antigravity_hook_translation(contract)

    def test_replay_budget_must_match_contract(self):
        self.assert_hook_change_fails(
            "ANTIGRAVITY_REPLAY_BUDGET_SECONDS=4\n", "ANTIGRAVITY_REPLAY_BUDGET_SECONDS=6\n", "예산"
        )

    def test_budget_must_fit_registered_timeout(self):
        checker = load()
        contract = checker.load_canonical()
        contract["event_state_map"]["antigravity_hook_translation"]["registration"]["timeout_seconds"] = 7
        with self.assertRaisesRegex(checker.CheckFailure, "timeout_seconds"):
            checker.check_antigravity_hook_translation(contract)


if __name__ == "__main__":
    unittest.main()
