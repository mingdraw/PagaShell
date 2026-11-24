import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'setup_pub_mirror.sh'
OFFICIAL = b'''packages:
  example:
    description:
      name: example
      sha256: "original-hash"
      url: "https://pub.dev"
    source: hosted
    version: "1.3.6"
  private_package:
    description:
      url: "https://pub.dev/custom"
'''


class PubMirrorSetupTest(unittest.TestCase):
    def test_git_stores_official_url_and_keeps_real_lock_changes(self):
        for newline in (b'\n', b'\r\n'):
            with self.subTest(newline=newline), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'checkout with spaces'
                (root / 'script').mkdir(parents=True)
                script = root / 'script' / SCRIPT.name
                shutil.copyfile(SCRIPT, script)
                lockfile = root / 'pubspec.lock'
                official = OFFICIAL.replace(b'\n', newline)
                mirror = official.replace(b'"https://pub.dev"', b'"https://pub.flutter-io.cn"')
                lockfile.write_bytes(official)
                env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)

                def git(*args):
                    return subprocess.check_output(['git', *args], cwd=root, env=env)

                def setup():
                    subprocess.check_output(['bash', str(script)], cwd=tmp, env=env)

                git('init', '-q')
                git('config', 'core.autocrlf', 'false')
                git('add', '--', 'pubspec.lock')
                setup()
                self.assertEqual(lockfile.read_bytes(), mirror)
                self.assertEqual(git('diff', '--', 'pubspec.lock'), b'')
                self.assertEqual(git('status', '--porcelain', '--', 'pubspec.lock'), b'A  pubspec.lock\n')
                self.assertEqual(git('show', ':pubspec.lock'), official)

                changed = mirror.replace(b'1.3.6', b'1.3.7').replace(b'original-hash', b'new-hash')
                lockfile.write_bytes(changed)
                setup()
                self.assertEqual(lockfile.read_bytes(), changed)
                attributes = (root / '.git/info/attributes').read_text()
                self.assertEqual(attributes.splitlines().count('/pubspec.lock filter=pagashell-lock'), 1)
                diff = git('diff', '--', 'pubspec.lock')
                self.assertIn(b'1.3.7', diff)
                self.assertIn(b'new-hash', diff)
                self.assertNotIn(b'pub.flutter-io.cn', diff)

                git('add', '--', 'pubspec.lock')
                expected = changed.replace(b'"https://pub.flutter-io.cn"', b'"https://pub.dev"')
                self.assertEqual(git('show', ':pubspec.lock'), expected)
                lockfile.unlink()
                git('checkout-index', '--', 'pubspec.lock')
                self.assertEqual(lockfile.read_bytes(), changed)


if __name__ == '__main__':
    unittest.main()
