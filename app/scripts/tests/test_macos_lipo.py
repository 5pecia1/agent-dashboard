import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


LIPO = Path(__file__).resolve().parents[2] / 'flutter_app/rust_builder/macos/flutter-tools/lipo'


@unittest.skipUnless(sys.platform == 'darwin', 'requires the macOS developer tools')
class FlutterLipoTests(unittest.TestCase):
    def test_모든_실제_슬라이스를_확인하고_없는_아키텍처는_거부한다(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            slices = []
            for arch in ('arm64', 'x86_64'):
                output = root / (arch + '.o')
                subprocess.run(['xcrun', 'clang', '-arch', arch, '-x', 'c', '-',
                                '-c', '-o', output], input=b'int test(void) { return 0; }', check=True)
                slices.append(output)
            universal = root / 'universal.o'
            subprocess.run([LIPO, '-create', *slices, '-output', universal], check=True)
            subprocess.run([LIPO, universal, '-verify_arch', 'arm64', 'x86_64'], check=True)
            absent = subprocess.run([LIPO, slices[0], '-verify_arch', 'arm64', 'x86_64'],
                                    capture_output=True)
            self.assertNotEqual(absent.returncode, 0)
