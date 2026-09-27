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


if __name__ == "__main__":
    unittest.main()
