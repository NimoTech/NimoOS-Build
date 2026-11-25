#!/usr/bin/env python3
"""Run the production core-update flow with downloads and host writes isolated."""

from pathlib import Path
import re
import shlex
import subprocess
from tempfile import TemporaryDirectory
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "nimoos-update.sh").read_text()


def function(name):
    return re.search(rf"(?ms)^{name}\(\) \{{\n.*?^\}}", SOURCE).group()


class CoreWorkspaceTests(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory(prefix="core-update-workspace-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.work = self.root / "workspace with spaces"
        self.unrelated = self.root / "unrelated"
        self.unrelated.write_text("keep")

    def run_update(self, mode):
        # Run the entire real Update_Core function. No real network, services,
        # package managers or sysroot writes are allowed by these replacements.
        script = r'''
set -e
sudo_cmd=
CORE_TMP_DIR=""
CORE_DEGRADED=0
NIMO_SERVICES=()
NIMO_OPTIONAL_SERVICES=()
NIMO_DOWNLOAD_PREFIX=fixture
NIMO_DEV_PREFIX=dev
core_components(){ printf 'fixture|fixture|all\n'; }
optional_components(){ :; }
core_pkg_url(){ printf 'http://no-network.invalid/linux-fixture.tar.gz\n'; }
Show(){ if [ "$1" = 1 ]; then exit 1; fi; }
GreyStart(){ :; }
ColorReset(){ :; }
onCtrlC(){ exit 1; }
wget(){
    test ! -e "$TMP_ROOT/stale" || exit 98
    printf partial > "$TMP_DIR/linux-fixture.tar.gz"
    case "$MODE" in
        download) return 22 ;;
        term) kill -TERM "$BASHPID" ;;
        interrupt) kill -INT "$BASHPID" ;;
        kill) kill -KILL "$BASHPID" ;;
    esac
    mkdir -p "$TMP_DIR/build/sysroot"
    printf fixture > "$TMP_DIR/build/sysroot/fixture"
}
tar(){ test "$MODE" != unpack || return 1; if [ "$1:$2:$3" = "-C:/:--keep-directory-symlink" ]; then test "$MODE" != overlay; fi; }
systemctl(){ :; }
Overlay_Sysroot(){ test "$MODE" != overlay; }
Repair_CI_Ownership(){ :; }
Refresh_Uninstaller(){ :; }
Ensure_Terminal_Deps(){ :; }
Install_Memory_Backstops(){ :; }
Install_Hardware_Watchdog(){ :; }
Ensure_Disk_Tools(){ :; }
Apply_Memory_Policy(){ :; }
Check_Core_Services(){ CORE_DEGRADED=1; }
'''
        script += "\nTMP_ROOT=" + shlex.quote(str(self.work))
        script += "\nNIMO_MANIFEST=" + shlex.quote(str(self.root / "manifest"))
        script += "\nMODE=" + shlex.quote(mode) + "\n"
        script += function("Cleanup_Core_Workspace") + "\n"
        script += "\n".join(re.findall(r"(?m)^trap .*", SOURCE)) + "\n"
        script += function("Update_Core") + "\nUpdate_Core\n"
        script += r'''
# Cleanup must already be complete before the next stack stage, and the
# public baseline has no core health flag mutation.
test -z "$CORE_TMP_DIR"
test "$CORE_DEGRADED" = 0
test -z "$(find "$TMP_ROOT" -mindepth 1 -print -quit)"
'''
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)

    def assert_clean(self):
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(self.unrelated.read_text(), "keep")

    def test_failed_download_unpack_and_overlay_clean_before_exit(self):
        for mode in ("download", "unpack", "overlay"):
            with self.subTest(mode=mode):
                result = self.run_update(mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assert_clean()

    def test_term_and_interrupt_preserve_failure_status_and_clean(self):
        for mode, code in (("term", 143), ("interrupt", 1)):
            with self.subTest(mode=mode):
                result = self.run_update(mode)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assert_clean()

    def test_success_cleans_before_next_stage(self):
        result = self.run_update("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean()

    def test_kill_leftovers_reclaimed_by_next_normal_attempt(self):
        result = self.run_update("kill")
        self.assertEqual(result.returncode, -9, result.stderr)
        self.assertTrue(list(self.work.rglob("*.tar.gz")))
        (self.work / "stale").write_text("partial")
        result = self.run_update("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean()


if __name__ == "__main__":
    unittest.main()
