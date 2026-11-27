"""Exercise the bundled update helpers using disposable installations only."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]
WINDOWS = sys.platform == "win32"
WATCHER_START_TIMEOUT = 60 if WINDOWS else 15


class UpdaterHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pagashell update ' 测试 ")
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.stage = self.work / "stage"
        self.source = self.stage / "bundle"
        self.target = self.root / "installed app"
        self.source.mkdir(parents=True)
        self.target.mkdir()
        (self.target / "version").write_text("old", encoding="utf-8")
        (self.source / "version").write_text("new", encoding="utf-8")
        # A long-lived disposable process represents the running application.
        self.parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
        self.children = []
        self.config = self.work / "install.json"
        self.archive = self.work / "package.zip"
        self.archive.write_bytes(b"fixture download")
        self.script = self.work / ("install_windows.ps1" if WINDOWS else "install_posix.sh")
        shutil.copy2(REPO / "assets" / "updater" / self.script.name, self.script)
        self.config.write_text(json.dumps({
            "source": str(self.source), "target": str(self.target), "work": str(self.work),
            "parentPid": self.parent.pid, "requiresAdmin": False,
            "archive": str(self.archive), "stage": str(self.stage), "prefix": "bundle",
        }), encoding="utf-8")

    def tearDown(self):
        (self.work / "cancel").touch(exist_ok=True)
        for child in [*self.children, self.parent]:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=10)
        # The restarted Windows fixture may still be closing its final write.
        # Wait for those handles, rather than leaving a detached test process
        # or treating its short lifetime as an installer failure.
        deadline = time.monotonic() + 5
        while True:
            try:
                self.temp.cleanup()
                break
            except PermissionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)

    def command(self, mode, platform="linux"):
        if WINDOWS:
            powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            return [str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                    "-File", str(self.script), "-Mode", mode, "-ConfigPath", str(self.config)]
        return ["/bin/sh", str(self.script), mode.lower(), platform, str(self.source),
                str(self.target), str(self.work), str(self.parent.pid), "false"]

    def run_helper(self, mode, *, success=True, platform="linux", env=None):
        result = subprocess.run(self.command(mode, platform), capture_output=True, timeout=20, env=env)
        if success:
            if result.returncode != 0:
                self.fail(
                    f"Helper exited with {result.returncode}\n"
                    f"stdout: {result.stdout.decode(errors='replace')}\n"
                    f"stderr: {result.stderr.decode(errors='replace')}\n"
                    f"{self.watcher_log()}"
                )
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def start_watcher(self, platform="linux"):
        started = time.monotonic()
        with (self.work / "watcher.log").open("wb") as log:
            child = subprocess.Popen(self.command("Watch", platform), stdout=log, stderr=subprocess.STDOUT)
        self.children.append(child)
        # The first Windows PowerShell startup on a hosted runner can be slow.
        self.wait_for(self.work / "ready", timeout=WATCHER_START_TIMEOUT, child=child)
        elapsed = time.monotonic() - started
        if WINDOWS and elapsed >= 15:
            print(f"Update helper ready after {elapsed:.1f}s", flush=True)
        return child

    def watcher_log(self):
        return "\n".join(file.read_text(encoding="utf-8", errors="replace")
                         for file in [self.work / "watcher.log", self.work / "helper.log"] if file.exists())

    def wait_for(self, file, *, timeout=15, child=None):
        deadline = time.monotonic() + timeout
        while not file.exists():
            exit_code = child.poll() if child is not None else None
            if exit_code is not None:
                self.fail(f"Watcher exited with {exit_code} while waiting for {file.name}\n{self.watcher_log()}")
            if time.monotonic() >= deadline:
                self.fail(f"Missing {file.name} after {timeout}s\n{self.watcher_log()}")
            time.sleep(0.05)

    @property
    def backup(self):
        return Path(str(self.target) + ".pagashell-backup")

    @property
    def marker(self):
        return Path(str(self.backup) + ".marker")

    @property
    def macos_backup(self):
        return self.target.with_name(f".{self.target.name}.pagashell-backup.noindex")

    @property
    def macos_marker(self):
        return Path(str(self.macos_backup) + ".marker")

    def test_complete_directory_replacement_and_rollback(self):
        (self.target / "old-only").touch()
        (self.source / "new-only").touch()
        self.run_helper("Apply")
        self.assertEqual((self.target / "version").read_text(), "new")
        self.assertFalse((self.target / "old-only").exists())
        self.assertTrue((self.target / "new-only").exists())
        self.assertEqual((self.backup / "version").read_text(), "old")
        self.run_helper("Rollback")
        self.assertEqual((self.target / "version").read_text(), "old")
        self.assertTrue((self.target / "old-only").exists())

    def test_copy_failure_keeps_current_installation(self):
        shutil.rmtree(self.source)
        self.run_helper("Apply", success=False)
        self.assertEqual((self.target / "version").read_text(), "old")
        self.assertFalse(self.backup.exists())
        self.assertFalse(Path(str(self.target) + ".pagashell-update-lock").exists())

    def test_unmanaged_backup_is_preserved(self):
        self.backup.mkdir()
        (self.backup / "keep").touch()
        self.run_helper("Apply", success=False)
        self.assertTrue((self.backup / "keep").exists())
        self.assertEqual((self.target / "version").read_text(), "old")

    def test_cancel_before_commit_never_modifies_installation(self):
        child = self.start_watcher()
        (self.work / "cancel").touch()
        self.assertEqual(child.wait(timeout=10), 0)
        self.assertEqual((self.target / "version").read_text(), "old")

    def test_parent_exit_without_commit_does_not_install(self):
        child = self.start_watcher()
        self.parent.terminate()
        self.parent.wait(timeout=10)
        self.assertEqual(child.wait(timeout=10), 0)
        self.assertEqual((self.target / "version").read_text(), "old")

    def test_cancel_revokes_commit_while_application_is_running(self):
        child = self.start_watcher()
        (self.work / "commit").touch()
        time.sleep(0.3)
        (self.work / "cancel").touch()
        self.assertEqual(child.wait(timeout=10), 0)
        self.assertEqual((self.target / "version").read_text(), "old")

    def test_later_update_rotates_only_managed_backup(self):
        self.run_helper("Apply")
        (self.source / "version").write_text("newer", encoding="utf-8")
        self.run_helper("Apply")
        self.assertEqual((self.target / "version").read_text(), "newer")
        self.assertEqual((self.backup / "version").read_text(), "new")

    def make_restart_fixture(self, directory, *, crash=False):
        if WINDOWS:
            body = (
                'Environment.Exit(17);' if crash else
                'File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "launched"), "ok"); '
                'System.Threading.Thread.Sleep(2000);'
            )
            code = 'using System; using System.IO; public class Fixture { public static void Main() { ' + body + ' } }'
            compile_script = self.work / "compile.ps1"
            compile_script.write_text(
                "param([string]$Output)\n$ErrorActionPreference = 'Stop'\nAdd-Type -TypeDefinition '" + code +
                "' -OutputAssembly $Output -OutputType WindowsApplication\n", encoding="utf-8")
            compiler = self.command("Apply")[:5]
            subprocess.run([*compiler, "-File", str(compile_script), "-Output", str(directory / "pagashell.exe")],
                           check=True, capture_output=True, timeout=30)
        else:
            executable = directory / "pagashell"
            body = 'exit 17\n' if crash else 'cd "$(dirname "$0")"\n: > launched\nsleep 2\n'
            executable.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            executable.chmod(0o755)

    def pause_first_parent_probe(self):
        # Hold the first liveness probe while the app commits and exits.
        if WINDOWS:
            hook = "New-Item -ItemType File -Path (Join-Path $work 'ready')"
            barrier = r"""
function Get-Process {
  [CmdletBinding()]
  param([int]$Id)
  $probe = Join-Path $work 'checking-parent'
  if (-not (Test-Path -LiteralPath $probe)) {
    New-Item -ItemType File -Path $probe | Out-Null
    while (-not (Test-Path -LiteralPath (Join-Path $work 'resume-parent-probe'))) {
      Start-Sleep -Milliseconds 20
    }
  }
  Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction SilentlyContinue
}
"""
        else:
            hook = ': > "$work/ready"'
            barrier = """
kill() {
  if [ "$2" = "$parent_process" ] && [ ! -f "$work/checking-parent" ]; then
    : > "$work/checking-parent"
    while [ ! -f "$work/resume-parent-probe" ]; do sleep 0.02; done
  fi
  command kill "$@"
}
"""
        script = self.script.read_text(encoding="utf-8")
        self.assertEqual(script.count(hook), 1)
        self.script.write_text(script.replace(hook, barrier + hook, 1), encoding="utf-8")

    def test_commit_waits_for_application_exit_then_restarts_and_removes_backup(self):
        self.make_restart_fixture(self.source)
        child = self.start_watcher()
        (self.work / "commit").touch()
        time.sleep(0.3)
        self.assertEqual((self.target / "version").read_text(), "old")
        self.parent.terminate()
        self.parent.wait(timeout=10)
        self.assertEqual(child.wait(timeout=20), 0, self.watcher_log())
        self.wait_for(self.target / "launched")
        self.assertTrue((self.work / "complete").exists())
        self.assertEqual((self.target / "version").read_text(), "new")
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.work / "error").exists())

    def test_early_launch_exit_restores_original_installation(self):
        self.make_restart_fixture(self.target)
        self.make_restart_fixture(self.source, crash=True)
        self.pause_first_parent_probe()
        child = self.start_watcher()
        self.wait_for(self.work / "checking-parent", child=child)
        resume = self.work / "resume-parent-probe"
        self.assertNotEqual(self.commit_and_exit(child, resume=resume), 0, self.watcher_log())
        self.wait_for(self.target / "launched")
        self.assertEqual((self.target / "version").read_text(), "old")
        self.assertEqual((self.work / "error").read_text().strip(), "launch-failed")
        self.assertFalse((self.work / "complete").exists())
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.marker.exists())

    def test_cleanup_requires_current_installation_and_managed_marker(self):
        self.target.rename(self.backup)
        self.marker.touch()
        self.run_helper("Cleanup", success=False)
        self.assertEqual((self.backup / "version").read_text(), "old")
        self.assertTrue(self.marker.exists())
        self.marker.unlink()
        self.target.mkdir()
        self.run_helper("Cleanup", success=False)
        self.assertEqual((self.backup / "version").read_text(), "old")

    @unittest.skipUnless(sys.platform == "darwin", "macOS copy operation")
    def test_macos_bundle_copy_and_rollback(self):
        applications = self.root / "Applications"
        applications.mkdir()
        self.target = self.target.rename(applications / "PagaShell.app")
        for bundle in [self.source, self.target]:
            (bundle / "Contents").mkdir()
            (bundle / "Contents/Info.plist").touch()

        # Observe the installation directory immediately before each rename,
        # when a visible application scanner could discover either copy.
        visible_apps = self.work / "visible-apps"
        mv = self.work / "mv"
        mv.write_text(
            '#!/bin/sh\nset -eu\n'
            'find "$PAGASHELL_TEST_APPLICATIONS" -name \'.*\' -prune -o -type f '
            '-path \'*/Contents/Info.plist\' '
            '! -path "$PAGASHELL_TEST_APPLICATIONS/PagaShell.app/Contents/Info.plist" '
            '-print >> "$PAGASHELL_TEST_VISIBLE_APPS"\n'
            'exec /bin/mv "$@"\n',
            encoding="utf-8",
        )
        mv.chmod(0o755)
        env = {
            **os.environ,
            "PATH": str(self.work) + os.pathsep + os.environ.get("PATH", os.defpath),
            "PAGASHELL_TEST_APPLICATIONS": str(applications),
            "PAGASHELL_TEST_VISIBLE_APPS": str(visible_apps),
        }
        self.run_helper("Apply", platform="macos", env=env)
        self.assertEqual((self.target / "version").read_text(), "new")
        self.run_helper("Rollback", platform="macos", env=env)
        self.assertEqual((self.target / "version").read_text(), "old")
        self.assertEqual(visible_apps.read_text(), "")
        self.assertEqual(list(applications.iterdir()), [self.target])

    @unittest.skipIf(WINDOWS, "POSIX backup cleanup")
    def test_cleanup_preserves_unmanaged_backup(self):
        self.macos_backup.mkdir()
        (self.macos_backup / "keep").touch()
        self.run_helper("Cleanup", success=False, platform="macos")
        self.assertTrue((self.macos_backup / "keep").exists())
        self.assertEqual((self.target / "version").read_text(), "old")

    @unittest.skipIf(WINDOWS, "POSIX backup cleanup")
    def test_cleanup_requires_current_installation(self):
        self.target.rename(self.macos_backup)
        self.macos_marker.touch()
        self.run_helper("Cleanup", success=False, platform="macos")
        self.assertEqual((self.macos_backup / "version").read_text(), "old")
        self.assertTrue(self.macos_marker.exists())

    @unittest.skipIf(WINDOWS, "POSIX backup cleanup")
    def test_macos_cleanup_preserves_unmanaged_legacy_backup(self):
        self.backup.mkdir()
        (self.backup / "keep").touch()
        self.macos_backup.mkdir()
        self.macos_marker.touch()
        self.run_helper("Cleanup", platform="macos")
        self.assertFalse(self.macos_backup.exists())
        self.assertFalse(self.macos_marker.exists())
        self.assertTrue((self.backup / "keep").exists())

    def stub_macos_launch(self, body):
        # Exercise the macOS watcher without depending on a GUI session. Only
        # LaunchServices is stubbed in this disposable copy of the real helper.
        launcher = self.work / "open"
        launcher.write_text("#!/bin/sh\nset -eu\ntarget=$2\n" + body, encoding="utf-8")
        launcher.chmod(0o755)
        self.script.write_text(
            self.script.read_text(encoding="utf-8").replace('/usr/bin/open -n "$target"',
                                                         '"$work/open" -n "$target"'),
            encoding="utf-8")

    def commit_and_exit(self, child, *, resume=None):
        (self.work / "commit").touch()
        self.parent.terminate()
        self.parent.wait(timeout=10)
        if resume is not None:
            resume.touch()
        return child.wait(timeout=20)

    @unittest.skipUnless(sys.platform == "darwin", "macOS watcher cleanup")
    def test_macos_success_removes_backup_after_launch(self):
        self.backup.mkdir()
        self.marker.touch()
        self.stub_macos_launch(
            f'[ -f {shlex.quote(str(self.macos_marker))} ]\n'
            f'[ "$(cat {shlex.quote(str(self.macos_backup / "version"))})" = old ]\n'
            ': > "$target/launched"\n')
        child = self.start_watcher(platform="macos")
        self.assertEqual(self.commit_and_exit(child), 0, self.watcher_log())
        self.assertTrue((self.target / "launched").exists())
        self.assertTrue((self.work / "complete").exists())
        self.assertEqual((self.target / "version").read_text(), "new")
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.macos_backup.exists())
        self.assertFalse(self.macos_marker.exists())
        self.assertFalse(self.stage.exists())

    @unittest.skipUnless(sys.platform == "darwin", "macOS watcher rollback")
    def test_macos_launch_failure_rolls_back(self):
        self.stub_macos_launch(
            '[ "$(cat "$target/version")" = old ] || exit 1\n'
            ': > "$target/restarted"\n')
        child = self.start_watcher(platform="macos")
        self.assertNotEqual(self.commit_and_exit(child), 0, self.watcher_log())
        self.assertEqual((self.target / "version").read_text(), "old")
        self.assertTrue((self.target / "restarted").exists())
        self.assertEqual((self.work / "error").read_text().strip(), "launch-failed")
        self.assertFalse((self.work / "complete").exists())
        self.assertFalse(self.macos_backup.exists())
        self.assertFalse(self.macos_marker.exists())

    @unittest.skipUnless(sys.platform == "darwin", "macOS watcher cleanup failure")
    def test_macos_cleanup_failure_keeps_running_update(self):
        self.stub_macos_launch(': > "$target/launched"\n')
        self.script.write_text(
            self.script.read_text(encoding="utf-8").replace('rm -rf "$backup"', 'false'),
            encoding="utf-8")
        child = self.start_watcher(platform="macos")
        self.assertEqual(self.commit_and_exit(child), 0, self.watcher_log())
        self.assertTrue((self.target / "launched").exists())
        self.assertTrue((self.work / "complete").exists())
        self.assertEqual((self.work / "error").read_text().strip(), "backup-cleanup-failed")
        self.assertEqual((self.target / "version").read_text(), "new")
        self.assertEqual((self.macos_backup / "version").read_text(), "old")
        self.assertTrue(self.macos_marker.exists())

    @unittest.skipUnless(WINDOWS, "Windows ZIP extraction")
    def test_windows_extract_rejects_traversal(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("bundle/../../escape", "invalid")
        self.run_helper("Extract", success=False)
        self.assertFalse((self.root / "escape").exists())
        (self.work / "helper.log").unlink(missing_ok=True)
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("bundle/data/flutter_assets/asset", "valid")
        self.run_helper("Extract")
        self.assertEqual((self.source / "data/flutter_assets/asset").read_text(), "valid")

    @unittest.skipUnless(WINDOWS, "Windows ZIP extraction")
    def test_windows_extract_works_with_broken_archive_module(self):
        # Simulate a host whose Expand-Archive module calls an unavailable .NET overload.
        self.script.write_text(
            self.script.read_text(encoding="utf-8").replace(
                "$ErrorActionPreference = 'Stop'\n",
                "$ErrorActionPreference = 'Stop'\n"
                "function Expand-Archive { throw 'Archive module unavailable' }\n",
                1,
            ),
            encoding="utf-8",
        )
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("bundle/data/flutter_assets/asset", "valid")
        self.run_helper("Extract")
        self.assertEqual((self.source / "data/flutter_assets/asset").read_text(), "valid")

    @unittest.skipUnless(WINDOWS, "Windows ZIP extraction")
    def test_windows_extract_does_not_overwrite_existing_files(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("bundle/version", "overwritten")
        self.run_helper("Extract", success=False)
        self.assertEqual((self.source / "version").read_text(), "new")


if __name__ == "__main__":
    unittest.main(verbosity=2)
