#!/usr/bin/env python3
"""Exercise Parser component transactions with small local artifacts and a fake service."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest

sys.dont_write_bytecode = True
from lib import parser_components as engine


HELPER = """#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ["FIXTURE"])
action = sys.argv[1]
name = os.environ["PARSER_COMPONENT"]
candidate = Path(os.environ["PARSER_CANDIDATE"])
extract = Path(os.environ["PARSER_EXTRACTED"])
release = Path(os.environ["PARSER_RELEASE"])
pointer = Path(os.environ["PARSER_LIVE_POINTER"])
tx = Path(os.environ["PARSER_TX_DIR"])
with (root / "calls").open("a") as stream:
    stream.write((action + " " + name).rstrip() + "\\n")
fail = os.environ.get("FAIL", "")
if action == "profile":
    print(os.environ.get("PROFILE", "cpu"))
elif action == "preflight-host":
    (root / "host-staging").touch()
    if fail == "mutate-requirements":
        source = Path(os.environ["PARSER_SOURCE"])
        (source / "requirements.txt").write_text("parser-package==2\\n")
    if fail == "preflight-host":
        sys.exit(18)
    if fail == "kill-with-pending-helper":
        (root / "helper-holds-lock").touch()
        os.close(1)
        os.close(2)
        os.kill(os.getppid(), signal.SIGKILL)
        time.sleep(0.8)
        (root / "helper-finished").touch()
    if fail == "terminate-helper":
        child = root / "child-ready"
        target = root / "late-write"
        code = (
            "import pathlib, signal, sys, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "pathlib.Path(sys.argv[1]).touch(); time.sleep(0.6); "
            "pathlib.Path(sys.argv[2]).touch()"
        )
        subprocess.Popen([sys.executable, "-c", code, str(child), str(target)])
        while not child.exists():
            time.sleep(0.01)
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(30)
elif action == "cleanup":
    if (root / "helper-holds-lock").exists():
        assert (root / "helper-finished").exists()
    (root / "host-staging").unlink(missing_ok=True)
    with (root / "outcomes").open("a") as stream:
        stream.write(os.environ["PARSER_TX_OUTCOME"] + "\\n")
elif action == "prepare":
    if fail == action + "-" + name:
        (candidate / "partial").write_text("incomplete")
        sys.exit(13)
    if name == "models":
        for entry in extract.iterdir():
            entry.rename(candidate / entry.name)
    else:
        for slot in {"runtime": ("venv", "uv-python"), "asr": ("asr-venv",)}[name]:
            (candidate / slot).mkdir()
        slot = candidate / ("venv" if name == "runtime" else "asr-venv")
        (extract / "payload").rename(slot / "payload")
        if name == "asr":
            (slot / "interpreter").symlink_to(Path(os.environ["PARSER_RUNTIME"]) / "venv" / "payload")
elif action == "validate":
    if fail == action + "-" + name:
        sys.exit(14)
    if name == "asr":
        assert (candidate / "asr-venv" / "interpreter").read_text()
    if name == "runtime":
        assert (candidate / "venv" / "payload").read_text()
    if name == "models":
        assert (candidate / "models" / "payload").read_text()
elif action == "check-release":
    assert (release / "asr-venv" / "interpreter").read_text()
    assert (release / "models" / "payload").is_file()
    assert (release / "MANIFEST.txt").read_text()
    if fail == action:
        sys.exit(15)
elif action == "service-active":
    sys.exit(0 if (root / "running").is_file() else 1)
elif action == "service-stop":
    (root / "running").unlink(missing_ok=True)
elif action == "service-configure":
    (tx / "old-config").write_text((root / "unit").read_text())
    (root / "unit").write_text((release / "parser" / "code").read_text())
    if fail == action:
        sys.exit(16)
elif action == "service-restore":
    if (tx / "old-config").exists():
        (root / "unit").write_text((tx / "old-config").read_text())
elif action == "service-start":
    (root / "running").touch()
elif action == "service-health":
    if pointer.is_symlink() and pointer.resolve() == release:
        if fail == "kill":
            os.kill(os.getppid(), signal.SIGKILL)
        if fail == action:
            sys.exit(17)
"""


class MirrorHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append(self.path)
        target = self.server.directory / self.path.lstrip("/")
        if not target.is_file():
            self.send_error(404)
            return
        body = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ParserTransactionTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="parser-component-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / "source"
        self.live = self.root / "opt" / "nimoos-parser"
        self.store = self.root / "data" / "store"
        self.archives = self.root / "mirror"
        self.manifest = self.source / "component-manifest.json"
        self.helper = self.root / "helper"
        self.helper.write_text(HELPER)
        self.helper.chmod(0o755)
        (self.source / "parser").mkdir(parents=True)
        self.live.parent.mkdir()
        self.archives.mkdir()
        (self.source / "requirements.txt").write_text("parser-package==1\n")
        self.set_code("code-v1")
        (self.root / "unit").write_text("old-unit")
        (self.root / "calls").touch()
        self.body = {
            "schema": 1,
            "python_abi": "cp311",
            "requirements_sha256": engine.sha256_file(self.source / "requirements.txt"),
            "components": {},
        }
        self.specs = self.body["components"]
        for component in engine.COMPONENT_LINKS:
            self.artifact(component, "v1")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MirrorHandler)
        self.server.directory = self.archives
        self.server.requests = []
        self.mirror = f"http://127.0.0.1:{self.server.server_port}"
        thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.wrapper = self.root / "run-engine"
        self.wrapper.write_text(
            'import os, sys\n'
            'from pathlib import Path\n'
            'from unittest.mock import patch\n'
            'sys.dont_write_bytecode = True\n'
            f'sys.path.insert(0, {str(Path(engine.__file__).parent)!r})\n'
            'import parser_components as engine\n'
            'free = os.getenv("FIXTURE_FREE")\n'
            'original_mount = os.getenv("FIXTURE_LEGACY_DATA_MOUNT")\n'
            'if original_mount:\n'
            '    engine.DEFAULT_DATA_MOUNT = Path(original_mount)\n'
            '    real_mounts = engine.mount_entries\n'
            '    engine.mount_entries = lambda: (*real_mounts(), (Path(original_mount), "ext4", "fixture", Path("/")))\n'
            'with patch.object(engine, "require_data_mount"):\n'
            '    if free is not None:\n'
            '        usage = engine.shutil.disk_usage("/")\n'
            '        engine.shutil.disk_usage = lambda _: usage._replace(free=int(free))\n'
            '    if os.getenv("DIRECT_LEGACY") == "1":\n'
            '        engine.Installer.same_mount_live_alias = lambda self: self.live\n'
            '    elif os.getenv("DIRECT_LEGACY") == "0":\n'
            '        engine.Installer.same_mount_live_alias = lambda self: None\n'
            '    sys.exit(engine.main(sys.argv[1:]))\n'
        )

    def set_code(self, value):
        (self.source / "parser" / "code").write_text(value)

    def artifact(self, component, version, *, bad=None):
        archive = f"{component}/{component}-{version}.tar"
        path = self.archives / archive
        path.parent.mkdir(exist_ok=True)
        data = f"{component}-{version}".encode()
        if bad == "non-tar":
            path.write_bytes(data)
        else:
            with tarfile.open(path, "w") as output:
                files = {"payload": data}
                if component == "models":
                    files = {"models/payload": data, "hf-cache/payload": data, "MANIFEST.txt": data}
                if bad == "traversal":
                    files = {"../escaped": data}
                for name, body in files.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(body)
                    output.addfile(info, io.BytesIO(body))
        self.specs[component] = {
            "id": version,
            "archive": archive,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size_bytes": path.stat().st_size,
            "unpacked_bytes": 64 * 1024,
        }
        if bad == "sha":
            self.specs[component]["sha256"] = "0" * 64
        if bad == "http":
            path.unlink()
        if bad == "short":
            path.write_bytes(path.read_bytes()[:1024])
        return path

    def update(self, *, fail="", free="", args=(), mount_check=False, profile="cpu",
               layout="symlink", direct_legacy="", legacy_data_mount=None):
        self.manifest.write_text(json.dumps(self.body))
        executable = engine.__file__ if mount_check else self.wrapper
        env = {**os.environ, "FIXTURE": str(self.root), "FAIL": fail, "PROFILE": profile,
               "DIRECT_LEGACY": direct_legacy}
        if free:
            env["FIXTURE_FREE"] = free
        if legacy_data_mount is not None:
            env["FIXTURE_LEGACY_DATA_MOUNT"] = str(legacy_data_mount)
        return subprocess.run(
            [sys.executable, str(executable), "update", "--source", str(self.source),
             "--manifest", str(self.manifest), "--live", str(self.live), "--store",
             str(self.store), "--prepare-command", str(self.helper), "--deps-base",
             self.mirror, "--layout", layout, *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, timeout=30,
        )

    def success(self, **kwargs):
        result = self.update(**kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_clean()
        return result

    def error(self, message, **kwargs):
        result = self.update(**kwargs)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assert_clean()
        return result

    def assert_clean(self):
        if (self.store / "transactions").is_dir():
            self.assertEqual(list((self.store / "transactions").iterdir()), [])
        self.assertFalse((self.store / "transaction.json").exists())
        self.assertFalse(any(self.live.parent.glob(".nimoos-parser.link-*")))
        self.assertFalse(any(self.live.glob("..current.link-*")))

    def calls(self):
        return (self.root / "calls").read_text().splitlines()

    def requests(self):
        requests = self.server.requests.copy()
        self.server.requests.clear()
        return requests

    def refs(self):
        release = self.live / ".current" if (self.live / ".current").is_symlink() else self.live
        return json.loads((release / ".parser-release.json").read_text())["components"]

    def legacy(self):
        self.live.mkdir()
        (self.live / "parser").mkdir()
        (self.live / "parser" / "code").write_text("legacy")
        (self.live / "flm").mkdir()
        (self.live / "flm" / "old-runtime").write_text("flm")
        for name in ("venv", "asr-venv", "models", "hf-cache"):
            (self.live / name).mkdir()
        (self.live / "models" / ".bundle-version").write_text("v1")
        (self.root / "running").touch()

    def test_code_only_and_independent_components(self):
        self.success()
        self.assertEqual(len(self.requests()), 3)
        first = self.refs()
        self.set_code("new code only")
        self.success()
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.refs(), first)
        self.assertEqual((self.live / "parser" / "code").read_text(), "new code only")
        self.artifact("runtime", "v2")
        self.success()
        second = self.refs()
        self.assertEqual(self.requests(), ["/runtime/runtime-v2.tar"])
        self.assertEqual(second["asr"], first["asr"])
        self.assertEqual(second["models"], first["models"])
        self.assertNotEqual(second["runtime"], first["runtime"])
        self.success()
        self.assertTrue((self.store / first["runtime"]).exists())
        self.assertEqual((self.live / "asr-venv" / "interpreter").read_text(), "runtime-v1")
        self.artifact("asr", "v2")
        self.success()
        self.assertEqual(self.requests(), ["/asr/asr-v2.tar"])
        self.assertEqual(self.refs()["runtime"], second["runtime"])
        self.assertEqual((self.live / "asr-venv" / "interpreter").read_text(), "runtime-v2")
        self.success()
        self.assertFalse((self.store / first["runtime"]).exists())
        self.artifact("models", "v2")
        self.success()
        self.assertEqual(self.requests(), ["/models/models-v2.tar"])
        self.assertEqual((self.live / "MANIFEST.txt").read_text(), "models-v2")

    def test_unknown_legacy_migrates_and_retains_owned_rollback(self):
        self.legacy()
        unrelated = self.live.parent / ".nimoos-parser.legacy-unrelated"
        unrelated.mkdir()
        (unrelated / "keep").touch()
        self.success()
        self.assertEqual(len(self.requests()), 3)
        self.assertTrue(self.live.is_symlink())
        self.assertEqual((self.live / "flm" / "old-runtime").read_text(), "flm")
        self.assertEqual(len(list(self.live.parent.glob(".nimoos-parser.legacy-*"))), 2)
        self.success()
        self.assertEqual(list(self.live.parent.glob(".nimoos-parser.legacy-*")), [unrelated])
        self.assertTrue((unrelated / "keep").exists())

    def test_fingerprinted_legacy_runtime_adopts_without_download(self):
        self.legacy()
        site = self.live / "venv/lib/python3.11/site-packages"
        site.mkdir(parents=True)
        (site / "payload").write_text("known runtime bytes")
        (site / "ignored.pyc").write_text("machine specific")
        items = engine.legacy_items(self.live, "runtime", "cp311")
        self.specs["runtime"]["content_fingerprint"] = engine.legacy_digest(items)
        self.success()
        self.assertEqual(self.requests(), ["/asr/asr-v1.tar", "/models/models-v1.tar"])
        self.assertEqual((self.live / "venv" / "payload").read_text(), "known runtime bytes")

    def test_host_preflight_follows_disk_check_and_cleanup_covers_failures_and_commit(self):
        self.legacy()
        self.error("insufficient free space", free="1")
        self.assertNotIn("preflight-host", self.calls())
        self.assertEqual(self.requests(), [])
        self.error("preflight-host", fail="preflight-host")
        self.assertEqual(self.requests(), [])
        self.assertFalse((self.root / "host-staging").exists())
        self.assertEqual((self.root / "outcomes").read_text().splitlines(), ["rollback", "rollback"])
        self.success()
        self.assertFalse((self.root / "host-staging").exists())
        self.assertEqual((self.root / "outcomes").read_text().splitlines()[-1], "commit")
        self.assertLess(self.calls().index("preflight-host"), self.calls().index("prepare runtime"))

    def test_space_failure_names_data_and_minimum_cleanup_target(self):
        self.legacy()
        result = self.error("请清理 /DATA", free="1")
        self.assertIn("至少达到 8.6 GB", result.stderr)
        self.assertIn("还需释放 8.6 GB", result.stderr)
        self.assertEqual(self.requests(), [])
        self.assertNotIn("preflight-host", self.calls())
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")

    def test_space_guidance_does_not_claim_8_6_gb_always_suffices(self):
        self.legacy()
        self.specs["runtime"]["unpacked_bytes"] = 12_000_000_000
        result = self.error("请清理 /DATA", free="8600000000")
        import re
        required = int(re.search(r"need (\d+) bytes", result.stderr).group(1))
        target = float(re.search(r"至少达到 ([0-9.]+) GB", result.stderr).group(1))
        self.assertGreater(target, 8.6)
        self.assertGreaterEqual(round(target * 1_000_000_000), required)
        self.assertEqual(self.requests(), [])
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")

    def test_signal_terminates_helper_group_before_cleanup(self):
        self.legacy()
        self.error("interrupted by SIGTERM", fail="terminate-helper")
        self.assertTrue((self.root / "child-ready").exists())
        self.assertFalse((self.root / "host-staging").exists())
        time.sleep(0.7)
        self.assertFalse((self.root / "late-write").exists())
        self.assertEqual((self.root / "outcomes").read_text(), "rollback\n")
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")
        self.assertEqual(self.requests(), [])

    def test_sigkill_recovery_waits_for_lock_held_by_helper(self):
        self.legacy()
        result = self.update(fail="kill-with-pending-helper")
        self.assertEqual(result.returncode, -9, result.stdout + result.stderr)
        self.assertTrue((self.root / "host-staging").exists())
        self.error("insufficient free space", free="1")
        self.assertTrue((self.root / "helper-finished").exists())
        self.assertFalse((self.root / "host-staging").exists())
        self.assertEqual(self.requests(), [])

    def test_rebuilds_damaged_managed_component_after_failed_validation(self):
        self.success()
        previous = self.refs()
        self.requests()
        (self.live / "models" / "payload").unlink()
        self.success()
        self.assertEqual(self.requests(), ["/models/models-v1.tar"])
        current = self.refs()
        self.assertNotEqual(previous["models"], current["models"])
        self.assertEqual(previous["runtime"], current["runtime"])
        self.assertEqual(previous["asr"], current["asr"])

    def test_requirements_changed_after_preflight_cannot_be_activated(self):
        self.success(args=("--start",))
        old_release = self.live.resolve()
        self.requests()
        self.set_code("edited source")
        self.error("staged Parser requirements.txt does not match", fail="mutate-requirements")
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.live.resolve(), old_release)
        self.assertEqual((self.live / "requirements.txt").read_text(), "parser-package==1\n")
        self.assertTrue((self.root / "running").exists())

    def test_no_service_skips_host_hooks(self):
        self.success(args=("--no-service",))
        self.assertNotIn("preflight-host", self.calls())
        self.assertNotIn("cleanup", self.calls())
        self.assertNotIn("service-active", self.calls())

    def test_low_space_and_unmounted_store_leave_legacy_running(self):
        self.legacy()
        self.error("insufficient free space", free="1")
        self.assertEqual(self.requests(), [])
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")
        self.assertTrue((self.root / "running").is_file())
        self.error("is not mounted", mount_check=True, args=("--data-mount", str(self.store.parent)))
        self.assertEqual(self.requests(), [])

    def test_failed_download_extract_or_validation_cleans_own_candidates(self):
        self.success()
        original = self.live.resolve()
        untouched = self.store / "components" / "models" / "unrelated"
        untouched.mkdir()
        cases = (
            ("http", "", "HTTP Error 404"),
            ("sha", "", "SHA-256 mismatch"),
            ("short", "", "shorter than the manifest size"),
            ("non-tar", "", "truncated header"),
            ("traversal", "", "invalid relative path"),
            (None, "prepare-models", "prepare models failed"),
            (None, "validate-models", "validate models failed"),
            (None, "check-release", "check-release"),
        )
        for count, (bad, fail, message) in enumerate(cases):
            with self.subTest(bad=bad, fail=fail):
                self.artifact("models", f"bad{count}", bad=bad)
                self.error(message, fail=fail)
                self.assertEqual(self.live.resolve(), original)
                self.assertEqual(len(list(untouched.parent.iterdir())), 2)
                self.assertTrue(untouched.is_dir())
                self.assertEqual(self.requests()[-1:], [f"/models/models-bad{count}.tar"])

    def test_legacy_service_health_and_configuration_failures_rollback(self):
        self.legacy()
        self.error("service-configure", fail="service-configure")
        self.assertEqual((self.root / "unit").read_text(), "old-unit")
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")
        self.error("service-health", fail="service-health")
        self.assertFalse(self.live.is_symlink())
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")
        self.assertEqual((self.root / "unit").read_text(), "old-unit")
        self.assertTrue((self.root / "running").exists())

    def test_failed_managed_update_keeps_old_anchor_pointer_and_release(self):
        self.legacy()
        self.success(layout="anchor", direct_legacy="1")
        old_pointer = (self.live / ".current").readlink()
        old_refs = self.refs()
        self.requests()
        self.artifact("runtime", "v2")
        self.set_code("failed managed update")
        self.error("service-health", fail="service-health", layout="anchor", direct_legacy="1")
        self.assertEqual((self.live / ".current").readlink(), old_pointer)
        self.assertEqual((self.live / "parser" / "code").read_text(), "code-v1")
        self.assertEqual(self.refs(), old_refs)
        self.assertEqual((self.root / "unit").read_text(), "code-v1")
        self.assertEqual(self.requests(), ["/runtime/runtime-v2.tar"])

    def test_failed_first_start_preserves_inactive_state(self):
        self.error("service-health", fail="service-health", args=("--start",))
        self.assertFalse(self.live.exists())
        self.assertFalse((self.root / "running").exists())
        self.assertEqual((self.root / "unit").read_text(), "old-unit")

    def test_sigkill_while_switched_recovers_before_next_attempt(self):
        self.legacy()
        interrupted = self.update(fail="kill")
        self.assertLess(interrupted.returncode, 0)
        self.assertTrue(self.live.is_symlink())
        self.assertTrue((self.store / "transaction.json").exists())
        self.error("insufficient free space", free="1")
        self.assertFalse(self.live.is_symlink())
        self.assertEqual((self.live / "parser" / "code").read_text(), "legacy")
        self.assertEqual((self.root / "unit").read_text(), "old-unit")
        self.assertTrue((self.root / "running").exists())
        self.success()

    def test_pins_survive_other_slot_updates_and_volatile_live_link(self):
        self.success(args=("--pin", "image-A"))
        release_a = self.live.resolve()
        original = self.refs()
        self.requests()
        self.artifact("models", "v2")
        self.success(args=("--pin", "image-B"))
        self.artifact("models", "v3")
        self.success(args=("--pin", "image-B"))
        self.live.unlink()
        self.success(args=("--pin", "image-B"))
        self.assertEqual(len(self.requests()), 2)
        self.assertTrue(release_a.exists())
        self.assertTrue((self.store / original["models"]).exists())
        self.artifact("models", "v1")
        self.success(args=("--pin", "image-A"))
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.refs()["models"], original["models"])
        self.assertFalse(release_a.exists())

    def test_code_only_flag_refuses_migration_or_component_refresh(self):
        self.legacy()
        self.error("already managed", args=("--code-only",))
        self.assertEqual(self.requests(), [])
        self.success()
        self.requests()
        original = self.live.resolve()
        self.artifact("models", "v2")
        self.error("verified models component", args=("--code-only",))
        self.assertEqual(self.live.resolve(), original)
        self.assertEqual(self.requests(), [])
        self.artifact("models", "v1")
        self.set_code("code-only-flag")
        checks = self.calls().count("preflight-host")
        self.success(args=("--code-only",))
        self.assertEqual(self.calls().count("preflight-host"), checks)
        self.assertEqual(self.requests(), [])
        self.assertEqual((self.live / "parser" / "code").read_text(), "code-only-flag")

    @unittest.skipUnless(shutil.which("zstd"), "zstd is unavailable")
    def test_extracts_zstd_archive_with_relative_hugging_face_link(self):
        path = self.artifact("models", "v2")
        with tarfile.open(path, "a") as archive:
            link = tarfile.TarInfo("hf-cache/snapshots/alias")
            link.type = tarfile.SYMTYPE
            link.linkname = "../payload"
            archive.addfile(link)
            hard_link = tarfile.TarInfo("models/hardlink")
            hard_link.type = tarfile.LNKTYPE
            hard_link.linkname = "models/payload"
            archive.addfile(hard_link)
        compressed = path.with_suffix(".tar.zst")
        subprocess.run(["zstd", "-q", str(path), "-o", str(compressed)], check=True)
        self.specs["models"].update({
            "archive": f"models/{compressed.name}",
            "sha256": engine.sha256_file(compressed),
            "size_bytes": compressed.stat().st_size,
        })
        self.success()
        self.assertEqual((self.live / "hf-cache" / "snapshots" / "alias").read_text(), "models-v2")
        self.assertTrue((self.live / "models" / "payload").samefile(self.live / "models" / "hardlink"))

    def test_seed_and_profile_change(self):
        self.success(args=("--archive-dir", str(self.archives)))
        first = self.refs()
        self.assertEqual(self.requests(), [])
        self.success(profile="intel")
        self.assertEqual(self.requests(), ["/runtime/runtime-v1.tar"])
        self.assertEqual(self.refs()["asr"], first["asr"])
        self.assertNotEqual(self.refs()["runtime"], first["runtime"])

    def pin_legacy_models(self, data_dir=None):
        roots = (self.live / "models", self.live / "hf-cache")
        data_dir = data_dir or self.root / "data"
        data_dir.mkdir(parents=True)
        for path in roots:
            destination = data_dir / path.name
            path.rename(destination)
            path.symlink_to(destination)
            (destination / "payload").write_text(f"verified {path.name}")
        (roots[1] / "relative-link").symlink_to("payload")
        (roots[0] / "custom").write_text("existing application cache")
        (self.live / "MANIFEST.txt").write_text("verified metadata")
        rows = "".join(f"{engine.sha256_file(root / 'payload')}  {root.name}/payload\n" for root in roots)
        catalog = self.live / "MANIFEST.files.sha256"
        catalog.write_text(rows)
        self.specs["models"]["legacy_files_manifest_sha256"] = engine.sha256_file(catalog)
        self.specs["models"]["legacy_metadata_sha256"] = {
            "MANIFEST.txt": engine.sha256_file(self.live / "MANIFEST.txt")
        }
        return data_dir

    def test_verified_models_ignore_bundle_version_and_copy_relative_links(self):
        self.legacy()
        data_dir = self.pin_legacy_models()
        self.success(args=("--data-mount", str(data_dir)))
        self.assertEqual(self.requests(), ["/runtime/runtime-v1.tar", "/asr/asr-v1.tar"])
        self.assertEqual((self.live / "models" / "custom").read_text(), "existing application cache")
        self.assertEqual((self.live / "hf-cache" / "relative-link").read_text(), "verified hf-cache")
        self.assertEqual((self.live / "MANIFEST.txt").read_text(), "verified metadata")
        models = self.store / self.refs()["models"]
        self.assertFalse((models / "models").is_symlink())
        self.assertEqual((models / "hf-cache" / "relative-link").readlink(), Path("payload"))

    def test_legacy_image_model_metadata_and_assets_resolve_on_original_data_mount(self):
        self.legacy()
        original_mount = self.root / "DATA"
        old_bundle = original_mount / ".system_data" / "assets" / "parser-models" / "current"
        self.pin_legacy_models(old_bundle)
        spec = self.specs["models"]
        for name in ("VERSION", "manifest.json"):
            path = self.live / name
            path.write_text(f"original image {name}")
            spec["legacy_metadata_sha256"][name] = engine.sha256_file(path)
        for name in engine.MODEL_METADATA:
            entry = self.live / name
            real = old_bundle / name
            entry.rename(real)
            entry.symlink_to(real)
        self.success(
            args=("--data-mount", str(self.store.parent)),
            legacy_data_mount=original_mount,
        )
        self.assertEqual(self.requests(), ["/runtime/runtime-v1.tar", "/asr/asr-v1.tar"])
        new_bundle = self.store / self.refs()["models"]
        self.assertTrue(new_bundle.is_relative_to(self.store.parent))
        for name in engine.MODEL_METADATA:
            self.assertFalse((new_bundle / name).is_symlink())
            self.assertEqual((new_bundle / name).read_bytes(), (old_bundle / name).read_bytes())
        self.assertFalse((new_bundle / "models").is_symlink())
        self.assertFalse((new_bundle / "hf-cache").is_symlink())
        self.assertEqual((new_bundle / "hf-cache" / "relative-link").readlink(), Path("payload"))

    def test_model_catalog_symlink_outside_approved_mounts_downloads_reference(self):
        self.legacy()
        data_dir = self.pin_legacy_models()
        catalog = self.live / "MANIFEST.files.sha256"
        outside_path = self.root / "unrelated-catalog"
        catalog.rename(outside_path)
        catalog.symlink_to(outside_path)
        self.success(args=("--data-mount", str(data_dir)))
        self.assertEqual(len(self.requests()), 3)
        self.assertTrue(outside_path.is_file())

    def test_architecture_mismatch_rejected_before_download_or_host_preflight(self):
        self.body["architecture"] = "fixture-mismatched-architecture"
        self.error("does not match host")
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.calls(), [])
        self.body["architecture"] = os.uname().machine
        self.success()
        self.assertEqual(len(self.requests()), 3)

    def test_model_catalog_matched_but_file_mismatch_downloads_reference(self):
        self.legacy()
        data_dir = self.pin_legacy_models()
        (data_dir / "hf-cache" / "payload").write_text("corrupt")
        self.success(args=("--data-mount", str(data_dir)))
        self.assertEqual(len(self.requests()), 3)
        self.assertEqual((self.live / "models" / "payload").read_text(), "models-v1")

    def test_anchored_layout_keeps_flm_and_unknown_paths_real(self):
        self.legacy()
        flm = self.live / "flm"
        flm_inode = flm.stat().st_ino
        unrelated = self.live / "unknown"
        unrelated.write_text("owner data")
        self.success(layout="anchor", direct_legacy="1")
        original = self.refs()
        pointer = self.live / ".current"
        first = pointer.resolve()
        code = self.live / "parser"
        self.assertFalse(self.live.is_symlink())
        self.assertFalse(flm.is_symlink())
        self.assertEqual(flm.stat().st_ino, flm_inode)
        self.assertEqual(code.readlink(), Path(".current/parser"))
        self.assertEqual(len(list((self.store / "legacy").iterdir())), 1)
        self.assertEqual(len(self.requests()), 3)
        self.set_code("anchored-v2")
        self.success(layout="anchor", direct_legacy="1")
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.refs(), original)
        self.assertEqual(unrelated.read_text(), "owner data")
        self.assertNotEqual(pointer.resolve(), first)
        self.assertEqual(list((self.store / "legacy").iterdir()), [])
        self.assertEqual((code / "code").read_text(), "anchored-v2")

    def test_anchored_rollback_restores_same_mount_legacy_entries(self):
        self.legacy()
        parser = self.live / "parser"
        old_inode = parser.stat().st_ino
        self.error("service-health", fail="service-health", layout="anchor", direct_legacy="1")
        self.assertFalse((self.live / ".current").is_symlink())
        self.assertEqual(parser.stat().st_ino, old_inode)
        self.assertEqual((parser / "code").read_text(), "legacy")
        self.assertEqual(list((self.store / "legacy").iterdir()), [])
        self.assertTrue((self.root / "running").exists())

    def test_anchored_cross_mount_rollback_keeps_only_required_backup(self):
        self.legacy()
        parser = self.live / "parser"
        self.error("service-health", fail="service-health", layout="anchor", direct_legacy="0")
        self.assertFalse((self.live / ".current").is_symlink())
        self.assertTrue(parser.is_symlink())
        self.assertTrue(parser.resolve().is_relative_to(self.store / "legacy"))
        self.assertEqual((parser / "code").read_text(), "legacy")
        self.assertTrue((self.root / "running").exists())
        self.success(layout="anchor", direct_legacy="0")
        self.success(layout="anchor", direct_legacy="0")
        self.assertEqual(list((self.store / "legacy").iterdir()), [])

    def test_refuses_to_move_unrecognized_legacy_contents(self):
        self.legacy()
        (self.live / "unknown").write_text("owner data")
        self.error("unrecognized entries: unknown")
        self.assertEqual(self.requests(), [])
        self.assertEqual((self.live / "unknown").read_text(), "owner data")


if __name__ == "__main__":
    unittest.main()
