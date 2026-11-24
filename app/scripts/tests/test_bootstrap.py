import json
from pathlib import Path
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bootstrap


NAME = 'my_dashboard'
ORG = 'io.github.5pecia1'
TARGETS = ['macos', 'web']
FEATURES = ['model-codegen']
DISPLAY_NAME = 'Agent Dashboard'


def identity():
    result = bootstrap.identity_for(NAME, ORG, TARGETS, 'enforce', FEATURES)
    result['display_name'] = DISPLAY_NAME
    return result


def initialize(project):
    bootstrap.initialize(
        project,
        NAME,
        ORG,
        prepare_only=True,
        targets=TARGETS,
        features=FEATURES,
    )


class BootstrapIdentityTest(unittest.TestCase):
    def test_기존_표시명을_보존하고_초기화를_다시_실행한다(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            state = project / bootstrap.STATE
            state.write_text(json.dumps(identity()), encoding='utf-8')

            initialize(project)

            self.assertEqual(json.loads(state.read_text(encoding='utf-8'))['display_name'], DISPLAY_NAME)

    def test_다른_identity_옵션_누락_추가_비정상_표시명은_거부한다(self):
        cases = (
            ('app_id', {**identity(), 'app_id': 'io.github.5pecia1.otherdashboard'}),
            ('features', {**identity(), 'features': []}),
            ('missing targets', {key: value for key, value in identity().items() if key != 'targets'}),
            ('unknown key', {**identity(), 'unknown': True}),
            ('empty display name', {**identity(), 'display_name': ' '}),
        )
        for name, state in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                (project / bootstrap.STATE).write_text(json.dumps(state), encoding='utf-8')

                with self.assertRaisesRegex(ValueError, 'different identity/options'):
                    initialize(project)


if __name__ == '__main__':
    unittest.main()
