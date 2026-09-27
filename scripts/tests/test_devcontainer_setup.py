"""Check bootstrap routing for development and public repository layouts."""

import contextlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('container_setup', ROOT / '.devcontainer/setup.py')
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


class DevcontainerSetupTests(unittest.TestCase):
    def run_setup(self, private, missing=False):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory).resolve()
            (workspace / 'app').mkdir()
            (workspace / 'app/.mise.toml').write_text('[tasks.bootstrap]\nrun = "true"\n')
            if private:
                (workspace / '.mise.toml').write_text('[tasks."platform:bootstrap"]\nrun = "true"\n')
            calls = []

            def run(command, **kwargs):
                cwd = kwargs.get('cwd', workspace)
                calls.append((command, cwd.relative_to(workspace)))
                if command[1] == 'ls':
                    output = {'flutter': ['missing']} if missing else {}
                elif command[1] == 'tasks':
                    output = [{'name': 'platform:bootstrap' if cwd == workspace else 'bootstrap'}]
                else:
                    output = None
                return subprocess.CompletedProcess(command, 0, json.dumps(output))

            with contextlib.chdir(workspace), patch.object(SETUP.subprocess, 'run', side_effect=run), patch.object(SETUP, 'container_mounts', return_value=None):
                result = SETUP.main()
            return result, calls

    def test_private_checkout_uses_root_bootstrap(self):
        result, calls = self.run_setup(private=True)
        self.assertEqual(result, 0)
        self.assertEqual(calls[0][1], Path('app'))
        self.assertEqual(calls[-1], (['mise', 'run', 'platform:bootstrap'], Path('.')))

    def test_public_checkout_without_root_mise_uses_app_bootstrap(self):
        result, calls = self.run_setup(private=False)
        self.assertEqual(result, 0)
        self.assertEqual(calls[-1], (['mise', 'run', 'bootstrap'], Path('app')))

    def test_missing_app_tools_stop_before_bootstrap(self):
        result, calls = self.run_setup(private=False, missing=True)
        self.assertEqual(result, 1)
        self.assertFalse(any(command[1] == 'run' for command, _ in calls))


if __name__ == '__main__':
    unittest.main()
