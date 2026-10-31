"""Exercise the bundled update helpers using disposable installations only."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]
WINDOWS = sys.platform == "win32"


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
        self.parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(90)"])
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

    def run_helper(self, mode, *, success=True, platform="linux"):
        result = subprocess.run(self.command(mode, platform), capture_output=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def start_watcher(self):
        with (self.work / "watcher.log").open("wb") as log:
            child = subprocess.Popen(self.command("Watch"), stdout=log, stderr=subprocess.STDOUT)
        self.children.append(child)
        self.wait_for(self.work / "ready")
        return child

    def watcher_log(self):
        return "\n".join(file.read_text(encoding="utf-8", errors="replace")
                         for file in [self.work / "watcher.log", self.work / "helper.log"] if file.exists())

    def wait_for(self, file):
        deadline = time.monotonic() + 15
        while not file.exists():
            if time.monotonic() > deadline:
                log = self.work / "helper.log"
                self.fail(f"Missing {file.name}: {log.read_text() if log.exists() else ''}")
            time.sleep(0.05)

    @property
    def backup(self):
        return Path(str(self.target) + ".pagashell-backup")

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

    def test_commit_waits_for_application_exit_then_restarts(self):
        if WINDOWS:
            # A tiny managed GUI executable records restart without using PagaShell.
            code = ('using System; using System.IO; public class Fixture { '
                    'public static void Main() { File.WriteAllText(Path.Combine('
                    'AppDomain.CurrentDomain.BaseDirectory, "launched"), "ok"); }}')
            compile_script = self.work / "compile.ps1"
            compile_script.write_text(
                "param([string]$Output)\n$ErrorActionPreference = 'Stop'\nAdd-Type -TypeDefinition '" + code +
                "' -OutputAssembly $Output -OutputType WindowsApplication\n", encoding="utf-8")
            compiler = self.command("Apply")[:5]
            subprocess.run([*compiler, "-File", str(compile_script), "-Output", str(self.source / "pagashell.exe")],
                           check=True, capture_output=True, timeout=30)
        else:
            executable = self.source / "pagashell"
            executable.write_text('#!/bin/sh\ncd "$(dirname "$0")"\n: > launched\nsleep 2\n', encoding="utf-8")
            executable.chmod(0o755)
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
        self.assertEqual((self.backup / "version").read_text(), "old")

    @unittest.skipUnless(sys.platform == "darwin", "macOS copy operation")
    def test_macos_bundle_copy_and_rollback(self):
        self.run_helper("Apply", platform="macos")
        self.assertEqual((self.target / "version").read_text(), "new")
        self.run_helper("Rollback", platform="macos")
        self.assertEqual((self.target / "version").read_text(), "old")

    @unittest.skipUnless(WINDOWS, "Windows ZIP extraction")
    def test_windows_extract_rejects_traversal(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("bundle/../../escape", "invalid")
        self.run_helper("Extract", success=False)
        self.assertFalse((self.root / "escape").exists())
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("bundle/data/flutter_assets/asset", "valid")
        self.run_helper("Extract")
        self.assertEqual((self.source / "data/flutter_assets/asset").read_text(), "valid")


if __name__ == "__main__":
    unittest.main(verbosity=2)
