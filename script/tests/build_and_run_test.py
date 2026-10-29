import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest


class BuildAndRunTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pagashell-debug-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'checkout with spaces'
        (self.root / 'script').mkdir(parents=True)
        self.script = self.root / 'script/build_and_run.sh'
        shutil.copyfile(Path(__file__).parents[1] / 'build_and_run.sh', self.script)
        self.bin = self.root / 'fake-bin'
        self.bin.mkdir()
        self.executable('flutter', '''import json, os, sys
print(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd(),
    'env': {key: os.environ.get(key) for key in
        ['no_proxy', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']}}))
''')
        self.executable('pgrep', '''import os
for key in ['TEST_DEBUG_PID', 'TEST_RELEASE_PID', 'TEST_OTHER_PID']:
    if os.environ.get(key):
        print(os.environ[key])
''')
        self.executable('ps', '''import os, sys
pid = sys.argv[sys.argv.index('-p') + 1]
prefix = os.environ['TEST_PROJECT_ROOT']
if pid == os.environ.get('TEST_RELEASE_PID'):
    suffix = 'Release'
elif pid == os.environ.get('TEST_OTHER_PID'):
    prefix += '/other-checkout'
    suffix = 'Debug'
else:
    suffix = 'Debug'
print(prefix + '/build/macos/Build/Products/' + suffix
    + '/pagashell.app/Contents/MacOS/pagashell')
''')

    def executable(self, name, body):
        target = self.bin / name
        target.write_text(f'#!{sys.executable}\n{body}')
        target.chmod(0o755)

    def run_script(self, *args, extra=None):
        environment = os.environ.copy()
        environment.update({
            'PATH': str(self.bin) + os.pathsep + environment.get('PATH', ''),
            'FLUTTER_BIN': str(self.bin / 'flutter'),
            'TEST_PROJECT_ROOT': str(self.root),
            'no_proxy': '',
            'NO_PROXY': '',
            'TEST_DEBUG_PID': '',
            'TEST_RELEASE_PID': '',
            'TEST_OTHER_PID': '',
        })
        environment['TEST_PROJECT_ROOT'] = str(self.root.resolve())
        environment.update(extra or {})
        return subprocess.run(
            ['/bin/bash', str(self.script), *args],
            cwd=self.temporary.name,
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_merges_both_bypass_lists_and_preserves_proxies_and_arguments(self):
        result = self.run_script(
            '--verbose', '--dart-define=label=literal shell value',
            extra={
                'no_proxy': 'lower.example.test',
                'NO_PROXY': 'upper.example.test',
                'http_proxy': 'http://127.0.0.1:7897',
                'https_proxy': 'http://127.0.0.1:7897',
                'all_proxy': 'socks5://127.0.0.1:7897',
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(payload['cwd'], str(self.root.resolve()))
        self.assertEqual(payload['args'], [
            'run', '-d', 'macos', '--verbose',
            '--dart-define=label=literal shell value',
        ])
        environment = payload['env']
        self.assertEqual(environment['no_proxy'], environment['NO_PROXY'])
        self.assertTrue({
            'lower.example.test', 'upper.example.test',
            'localhost', '127.0.0.1', '::1', '[::1]',
        }.issubset(set(environment['no_proxy'].split(','))))
        self.assertEqual(environment['http_proxy'], 'http://127.0.0.1:7897')
        self.assertEqual(environment['https_proxy'], 'http://127.0.0.1:7897')
        self.assertEqual(environment['all_proxy'], 'socks5://127.0.0.1:7897')

    def sleeper(self):
        process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])

        def cleanup():
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=3)

        self.addCleanup(cleanup)
        return process

    def test_stops_only_this_checkouts_debug_app(self):
        debug, release, other = self.sleeper(), self.sleeper(), self.sleeper()
        reaper = threading.Thread(target=debug.wait, daemon=True)
        reaper.start()
        try:
            result = self.run_script(extra={
                'TEST_DEBUG_PID': str(debug.pid),
                'TEST_RELEASE_PID': str(release.pid),
                'TEST_OTHER_PID': str(other.pid),
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            reaper.join(timeout=2)
            self.assertIsNotNone(debug.poll())
            self.assertIsNone(release.poll())
            self.assertIsNone(other.poll())
        finally:
            for process in [debug, release, other]:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=3)

    def test_help_does_not_start_flutter(self):
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stdout)
        self.assertNotIn('Starting macOS Debug', result.stdout)

    def test_missing_flutter_fails_before_stopping_apps(self):
        result = self.run_script(extra={'FLUTTER_BIN': '/does/not/exist/flutter'})
        self.assertEqual(result.returncode, 127)
        self.assertIn('Flutter was not found', result.stderr)


if __name__ == '__main__':
    unittest.main()
