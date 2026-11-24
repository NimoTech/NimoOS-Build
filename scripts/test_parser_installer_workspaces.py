#!/usr/bin/env python3
"""Exercise installer cleanup and status propagation without touching a host."""

from contextlib import suppress
import io
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tarfile
from tempfile import TemporaryDirectory
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent
ON_DISK_EVIDENCE = "docs/bugs/evidence/parser-component-update-20261123"

CURL_SHIM = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
import time

args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith("http"))
output = Path(args[args.index("-o") + 1])
fixture = Path(os.environ["FIXTURE_BASE"])
marker = fixture / "transfer-ready"
work = Path(os.environ["FIXTURE_WORK"])
if (work / "stale-download").exists():
    (fixture / "stale-observed").touch()
    sys.exit(99)
if os.environ["FIXTURE_PHASE"] == "stack":
    name = url.split("/get/scripts/", 1)[1]
    target = name == "lib/stack-fetch.sh"
else:
    target = True
mode = os.environ["FIXTURE_MODE"]
if target and mode in {"download-fails", "download-holds"}:
    output.write_text("incomplete download")
    if mode == "download-holds":
        (work / "stale-download").touch()
        marker.touch()
        time.sleep(60)
    sys.exit(22)
if os.environ["FIXTURE_PHASE"] == "stack":
    if mode == "component-tools-missing":
        if name == "lib/parser-gpu-branch.sh":
            output.write_text("partial component tool")
            sys.exit(22)
        fixtures = {"install-parser.sh": "stack-fixture-install.sh", "lib/stack-fetch.sh": "stack-fixture-fetch.sh"}
        if name in fixtures:
            shutil.copyfile(fixture / fixtures[name], output)
            sys.exit(0)
    body = ":\n"
    if name == "install-parser.sh":
        body = (
            'if [[ "$FIXTURE_MODE" == child-holds ]]; then\n'
            '  touch "$FIXTURE_BASE/transfer-ready"; sleep 60\n'
            'fi\nexit "${FIXTURE_CHILD_RC:-0}"\n'
        )
    output.write_text(body)
else:
    shutil.copyfile(fixture / "payload.tar.gz", output)
'''


class InstallerFixture(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory(prefix="parser-installer-workspace-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.shims = self.root / "shims"
        self.shims.mkdir()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.owned = self.root / "owned"
        self.owned.mkdir(mode=0o700)
        self.work = self.owned / "work"
        self.unrelated = (self.root / "unrelated", self.owned / "unrelated")
        for marker in self.unrelated:
            marker.write_text("leave alone", encoding="utf-8")
        self.script_root = self.root / "scripts"
        self.script_root.mkdir()
        self.shell_env = {
            **os.environ,
            "PATH": str(self.shims) + os.pathsep + os.environ["PATH"],
            "FIXTURE_BASE": str(self.root),
            "FIXTURE_WORK": str(self.work),
            "TMPDIR": str(self.logs),
            "NIMO_DOWNLOAD_DOMAIN": "http://no-network.invalid/",
            "NIMO_SCRIPTS_BASE": "http://no-network.invalid/get/scripts",
            "NIMO_KEY_PREFIX": "fixture",
            "NIMO_PARSER_SCRATCH_ROOT": str(self.owned),
            "NIMO_STACK_WORK_ROOT": str(self.owned),
            "NIMO_PARSER_INSTALL_DIR": str(self.root / "live"),
            "NIMO_PARSER_LIBRARY_ONLY": "0",
            "DEPLOY_SRC_DIR": "",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.shim("curl", CURL_SHIM)
        self.shim("mkdir", '#!/bin/bash\n'
                  'for arg; do\n'
                  '  case "$arg" in\n'
                  '    "$FIXTURE_BASE"|"$FIXTURE_BASE"/*) ;;\n'
                  '    /var/log/nimoos) exit 1 ;;\n'
                  '    /etc/*|/opt/*|/run/*|/var/*|/usr/*)\n'
                  '      echo mkdir >> "$FIXTURE_BASE/host-call"; exit 98 ;;\n'
                  '  esac\n'
                  'done\nexec /bin/mkdir "$@"\n')
        for command in ("apt-get", "systemctl", "sudo"):
            allow = 'case "$1:$2" in python3:"$FIXTURE_BASE"/scripts/lib/parser_components.py) exec "$@" ;; esac\n' if command == "sudo" else ""
            self.shim(command, f'#!/bin/bash\n{allow}echo {command} >> "$FIXTURE_BASE/host-call"\nexit 98\n')

    def shim(self, name, body):
        path = self.shims / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def make_payload(self, path=None):
        archive = path or self.root / "payload.tar.gz"
        files = {
            "parser/main.py": b"import sys\n",
            "parser/component-manifest.json": b"{}\n",
            "requirements.txt": b"# local fixture\n",
            "build/sysroot/usr/lib/systemd/system/nimoos-parser.service": b"",
            "build/sysroot/etc/nimoos/parser.conf": b"",
        }
        with tarfile.open(archive, "w:gz") as tar:
            for name, contents in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(contents)
                tar.addfile(member, io.BytesIO(contents))

    def installer(self, phase):
        if phase == "stack":
            path = shutil.copyfile(SCRIPTS / "nimoos-stack-install.sh", self.script_root / "stack.sh")
            return ["bash", path, "--only", "parser", "--version", "vfixture", "--start"]
        path = self.script_root / "install-parser.sh"
        original = (SCRIPTS / path.name).read_text()
        # Skip privilege elevation in the copied test script. All other wrapper
        # and payload functions, including traps, run exactly as checked in.
        guard = "if (( EUID != 0 )); then"
        self.assertEqual(original.count(guard), 1)
        path.write_text(original.replace(guard, "if false; then"), encoding="utf-8")
        lib = self.script_root / "lib"
        lib.mkdir(exist_ok=True)
        shutil.copyfile(SCRIPTS / "lib/stack-fetch.sh", lib / "stack-fetch.sh")
        (lib / "parser-component-helper.sh").touch()
        (lib / "parser_components.py").write_text(
            "import os, sys, time\nfrom pathlib import Path\n"
            "source = Path(sys.argv[sys.argv.index('--source') + 1])\n"
            "assert source.parent == Path(os.environ['FIXTURE_WORK'])\n"
            "assert (source / 'parser/component-manifest.json').is_file()\n"
            "print('fixture updater called')\n"
            "if os.environ['FIXTURE_MODE'] == 'child-holds':\n"
            "    (Path(os.environ['FIXTURE_BASE']) / 'transfer-ready').touch()\n"
            "    time.sleep(60)\n"
            "sys.exit(int(os.environ.get('FIXTURE_CHILD_RC', '0')))\n",
            encoding="utf-8",
        )
        return ["bash", path]

    def scenario(self, argv, phase, mode="ok", signal_to_send=None, child_rc=0):
        marker = self.root / "transfer-ready"
        marker.unlink(missing_ok=True)
        env = {
            **self.shell_env, "FIXTURE_PHASE": phase, "FIXTURE_MODE": mode,
            "FIXTURE_CHILD_RC": str(child_rc),
        }
        with subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, start_new_session=True) as process:
            try:
                if signal_to_send:
                    deadline = time.monotonic() + 10
                    while not marker.exists() and time.monotonic() < deadline:
                        self.assertIsNone(process.poll(), f"installer exited before signal: {phase}/{mode}")
                        time.sleep(0.02)
                    self.assertTrue(marker.exists(), "installer did not reach its blocking point")
                    os.killpg(process.pid, signal_to_send)
                stdout, _ = process.communicate(timeout=15)
            except BaseException:
                with suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise
        self.assertFalse((self.root / "host-call").exists(), stdout)
        return process.returncode, stdout

    def assert_owned_work_clean(self):
        self.assertFalse(self.work.exists())
        for marker in self.unrelated:
            self.assertEqual(marker.read_text(), "leave alone")
        self.assertFalse((self.root / "stale-observed").exists())


class StackBootstrapWorkspaceTest(InstallerFixture):
    def fixture_parser_release(self, versioned):
        self.make_payload()
        source = self.root / "payload"
        source.mkdir()
        with tarfile.open(self.root / "payload.tar.gz") as archive:
            # The archive is this fixture's own payload. Python before 3.11.4
            # (Debian 12 ships 3.11.2) has no extraction filters.
            if hasattr(tarfile, "data_filter"):
                archive.extractall(source, filter="data")
            else:
                archive.extractall(source)
        if not versioned:
            (source / "parser/component-manifest.json").unlink()
        self.shell_env["DEPLOY_SRC_DIR"] = str(source)
        self.shell_env["NIMO_PARSER_SCRATCH_ROOT"] = str(self.root / "parser-scratch")
        shutil.copyfile(SCRIPTS / "lib/stack-fetch.sh", self.root / "stack-fixture-fetch.sh")
        installer = (SCRIPTS / "install-parser.sh").read_text()
        installer = installer.replace("if (( EUID != 0 )); then", "if false; then")
        entry = "parser_install_main() {"
        legacy_probe = '''
for tool in parser_components.py parser-component-helper.sh parser-gpu-branch.sh; do
    [[ ! -e "$SCRIPT_DIR/lib/$tool" ]] || { echo "incomplete tool set survived: $tool"; exit 97; }
done
check_python() { echo "fixture legacy installer called"; exit 0; }
'''
        self.assertEqual(installer.count(entry), 1)
        (self.root / "stack-fixture-install.sh").write_text(installer.replace(entry, legacy_probe + entry))

    def test_partial_component_tool_publication_preserves_legacy_install(self):
        argv = self.installer("stack")
        self.fixture_parser_release(versioned=False)
        rc, output = self.scenario(argv, "stack", "component-tools-missing")
        self.assertEqual(rc, 0, output)
        self.assertIn("could not download Parser component tool: lib/parser-gpu-branch.sh", output)
        self.assertIn("fixture legacy installer called", output)
        self.assert_owned_work_clean()

    def test_partial_component_tool_publication_blocks_versioned_install(self):
        argv = self.installer("stack")
        self.fixture_parser_release(versioned=True)
        rc, output = self.scenario(argv, "stack", "component-tools-missing")
        self.assertEqual(rc, 1, output)
        self.assertIn("missing the component update tools; no installed files were changed", output)
        self.assertNotIn("fixture legacy installer called", output)
        self.assert_owned_work_clean()

    def test_bootstrap_and_child_failures_clean_workspace(self):
        argv = self.installer("stack")
        rc, output = self.scenario(argv, "stack", mode="download-fails")
        self.assertEqual(rc, 1, output)
        self.assertIn("could not download the sub-script: lib/stack-fetch.sh", output)
        self.assert_owned_work_clean()

        rc, output = self.scenario(argv, "stack", child_rc=23)
        self.assertEqual(rc, 1, output)
        self.assertIn("parser failed to install (exit=23)", output)
        self.assertIn("--only parser --version vfixture --start", output)
        self.assert_owned_work_clean()

    def test_term_cleans_workspace(self):
        argv = self.installer("stack")
        for mode in ("download-holds", "child-holds"):
            with self.subTest(mode=mode):
                rc, output = self.scenario(argv, "stack", mode, signal.SIGTERM)
                self.assertEqual(rc, 143, output)
                self.assert_owned_work_clean()

    def test_reentry_recovers_only_its_own_interrupted_workspace(self):
        argv = self.installer("stack")
        rc, output = self.scenario(argv, "stack", "download-holds", signal.SIGKILL)
        self.assertEqual(rc, -signal.SIGKILL, output)
        self.assertTrue((self.work / "stale-download").is_file())
        rc, output = self.scenario(argv, "stack")
        self.assertEqual(rc, 0, output)
        self.assert_owned_work_clean()


class ParserPayloadWorkspaceTest(InstallerFixture):
    def test_download_extract_and_nested_failure_clean_workspace(self):
        argv = self.installer("parser")
        rc, output = self.scenario(argv, "parser", mode="download-fails")
        self.assertEqual(rc, 1, output)
        self.assertIn("download failed", output)
        self.assert_owned_work_clean()

        (self.root / "payload.tar.gz").write_text("invalid archive", encoding="utf-8")
        rc, output = self.scenario(argv, "parser")
        self.assertEqual(rc, 1, output)
        self.assertIn("could not unpack", output)
        self.assert_owned_work_clean()

        self.make_payload()
        rc, output = self.scenario(argv, "parser", child_rc=23)
        self.assertEqual(rc, 23, output)
        self.assertIn("fixture updater called", output)
        self.assert_owned_work_clean()

    def test_term_cleans_workspace(self):
        argv = self.installer("parser")
        self.make_payload()
        for mode in ("download-holds", "child-holds"):
            with self.subTest(mode=mode):
                rc, output = self.scenario(argv, "parser", mode, signal.SIGTERM)
                self.assertEqual(rc, 143, output)
                self.assert_owned_work_clean()

    def test_reentry_recovers_only_its_own_interrupted_workspace(self):
        argv = self.installer("parser")
        rc, output = self.scenario(argv, "parser", "download-holds", signal.SIGKILL)
        self.assertEqual(rc, -signal.SIGKILL, output)
        self.assertTrue((self.work / "stale-download").is_file())
        self.make_payload()
        rc, output = self.scenario(argv, "parser")
        self.assertEqual(rc, 0, output)
        self.assertIn("fixture updater called", output)
        self.assert_owned_work_clean()


class GeneratedParserInstallerTest(InstallerFixture):
    def generated_installer(self):
        custom = os.environ.get("PARSER_HOST118_EVIDENCE")
        candidates = [Path(custom)] if custom else [p / ON_DISK_EVIDENCE for p in SCRIPTS.parents]
        evidence = next((p for p in candidates if (p / "host118-parser-component-update.patch").is_file()), None)
        if evidence is None or not shutil.which("patch"):
            self.skipTest("118 generator snapshots and patch are required; set PARSER_HOST118_EVIDENCE")
        source = self.root / "host118"
        (source / "scripts").mkdir(parents=True)
        (source / "release/lib").mkdir(parents=True)
        snapshot = evidence / "host118-local-package.sh.txt"
        packaging = source / "scripts/local-package.sh"
        shutil.copyfile(snapshot, packaging)
        shutil.copyfile(evidence / "host118-entry-scripts.sh.txt", source / "release/lib/entry-scripts.sh")
        subprocess.run(["patch", "--batch", "-p1", "-i", evidence / "host118-parser-component-update.patch"],
                       cwd=source, check=True, capture_output=True, text=True)
        patched = packaging.read_text()
        generator = re.search(r"(?ms)^gen_install_script\(\) \{\n.*?^BODY\n.*?^}\n", patched)
        self.assertIsNotNone(generator)
        entry = self.root / "generator.sh"
        entry.write_text(generator[0], encoding="utf-8")
        out = self.root / "build"
        (out / "parser").mkdir(parents=True)
        subprocess.run(["bash", "-c", 'source "$1"; gen_install_script "$2" fixture amd64', "fixture", entry, out],
                       check=True, capture_output=True, text=True)
        generated = (out / "install.sh").read_text()
        install_parser = re.search(r"(?ms)^install_parser\(\) \(.*?^\)\n", generated)
        self.assertIsNotNone(install_parser)
        end = generated.split("\ninstall_toolbox_deps\n", 1)[1]
        fixture = out / "sandbox-install.sh"
        # Use the actual generated Parser function and outer dispatcher. Omit
        # unrelated host bootstrap, and change only the function's scratch path.
        body = install_parser[0].replace("root=/var/lib/nimoos/.parser-build-payload", "root=\"$NIMO_PARSER_SCRATCH_ROOT\"")
        self.assertIn('root="$NIMO_PARSER_SCRATCH_ROOT"', body)
        fixture.write_text(
            "set -uo pipefail\n"
            f"HERE={shlex.quote(str(out))}\n"
            'targets=(parser); declare -A GOSVC=(); RUN_STACK=0; SETUP_FAILED=(); UI_NOT_SERVED=0\n'
            'main_tar() { printf "%s\\n" "$1/payload.tar.gz"; }\n' + body + end,
            encoding="utf-8",
        )
        stage = out / "deps/stack"
        stage.mkdir(parents=True)
        (stage / "install-parser.sh").write_text(
            '[[ "$*" == --start && -f "$DEPLOY_SRC_DIR/parser/component-manifest.json" ]] || exit 97\n'
            'echo "fixture updater called"\nexit "${FIXTURE_CHILD_RC:-0}"\n', encoding="utf-8",
        )
        return ["bash", fixture], out / "parser/payload.tar.gz"

    def test_generated_install_propagates_parser_failure_and_cleans_payload(self):
        argv, archive = self.generated_installer()
        self.make_payload(archive)
        rc, output = self.scenario(argv, "generated", child_rc=23)
        self.assertEqual(rc, 23, output)
        self.assertIn("fixture updater called", output)
        self.assert_owned_work_clean()

        rc, output = self.scenario(argv, "generated")
        self.assertEqual(rc, 0, output)
        self.assertIn("fixture updater called", output)
        self.assert_owned_work_clean()

        archive.write_text("invalid archive", encoding="utf-8")
        rc, output = self.scenario(argv, "generated")
        self.assertEqual(rc, 1, output)
        self.assertNotIn("fixture updater called", output)
        self.assert_owned_work_clean()


if __name__ == "__main__":
    unittest.main()
