#!/usr/bin/env python3
"""Run the component engine with its production helper against local fixtures."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


LIB = Path(__file__).resolve().parent / "lib"
HELPER = LIB / "parser-component-helper.sh"
ENGINE = LIB / "parser_components.py"
RUNTIME_MODULES = (
    "torch", "torchvision", "torchaudio", "torchcodec", "docling", "rapidocr",
    "onnxruntime", "openvino", "openvino_genai", "openvino_tokenizers", "llama_cpp",
    "FlagEmbedding", "transformers", "ctranslate2", "scenedetect", "qdrant_client",
    "fastapi", "uvicorn", "pyannote",
)
MODEL_METADATA = ("VERSION", "MANIFEST.txt", "MANIFEST.files.sha256", "manifest.json")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


def standalone_python():
    custom = os.environ.get("PARSER_TEST_STANDALONE_PYTHON")
    candidates = [Path(custom)] if custom else Path("/opt/nimoos-parser/uv-python").glob("*/bin/python3.11")
    for path in candidates:
        root = path.parent.parent
        if os.access(path, os.X_OK) and (root / "lib/python3.11/ensurepip").is_dir():
            return root.resolve()
    return None


class ParserComponentHelperTest(unittest.TestCase):
    def setUp(self):
        standalone = standalone_python()
        if standalone is None:
            self.skipTest("no standalone CPython 3.11; set PARSER_TEST_STANDALONE_PYTHON to its bin/python3.11")
        if not shutil.which("zstd"):
            self.skipTest("zstd is needed to exercise the actual archive extractor")
        temp = TemporaryDirectory(prefix="parser-component-helper-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.source = self.root / "source"
        self.live = self.root / "live"
        self.store = self.root / "store"
        self.archive_dir = self.root / "archives"
        self.manifest = self.source / "parser/component-manifest.json"
        self.models = self.root / "models-fixture"
        self.runtime = self.root / "runtime-fixture"
        self.asr = self.root / "asr-fixture"
        self.offline_calls = self.root / "forbidden-host-calls"
        for path in (self.archive_dir, self.manifest.parent, self.models, self.runtime, self.asr / "optimum"):
            path.mkdir(parents=True)
        self.requirements = self.source / "requirements.txt"
        self.requirements.write_text("fixture-runtime>=1\n", encoding="utf-8")
        (self.source / "parser/main.py").write_text("RELEASE = 1\n", encoding="utf-8")
        self.env = self.isolated_environment(standalone)
        self.create_runtime_modules()
        self.create_models("1.2.0", "initial weight")
        self.specs = {
            "runtime": self.archive("runtime", self.runtime, "1.0.0"),
            "asr": self.archive("asr", self.asr, "1.0.0"),
            "models": self.archive("models", self.models, "1.2.0"),
        }

    def isolated_environment(self, standalone):
        shims = self.root / "shims"
        shims.mkdir()
        drm = self.root / "drm"
        drm.mkdir()
        forbidden = shlex.quote(str(self.offline_calls))
        store = shlex.quote(str(self.store))
        for name in ("apt-get", "systemctl", "curl", "sudo"):
            command = "#!/bin/bash\n"
            if name == "sudo":
                # The helper's probes may use sudo when the test user is unprivileged.
                # Permit only execution of the venv interpreter that the fixture owns.
                command += f'case "$1" in {store}/components/runtime/*/venv/bin/python) exec "$@" ;; esac\n'
            command += f"printf '%s\\n' {name} >> {forbidden}\nexit 90\n"
            shim = shims / name
            shim.write_text(command, encoding="utf-8")
            shim.chmod(0o755)
        uv = shims / "uv"
        uv.write_text(
            '#!/bin/bash\nset -eu\n'
            'case "$*" in\n'
            '  --version) echo "uv (local test fixture)" ;;\n'
            '  "python install --no-bin 3.11")\n'
            '    mkdir -p "$UV_PYTHON_INSTALL_DIR"\n'
            f'    cp -a -- {shlex.quote(str(standalone))} "$UV_PYTHON_INSTALL_DIR/cp311" ;;\n'
            f'  *) printf "%s\\n" uv >> {forbidden}; exit 90 ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        uv.chmod(0o755)
        return {
            **os.environ,
            "PATH": str(shims) + os.pathsep + os.environ["PATH"],
            "NIMO_DRM_ROOT": str(drm),
            "NIMO_PARSER_IMAGE_RUNTIME": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def create_runtime_modules(self):
        for module in RUNTIME_MODULES:
            (self.runtime / (module + ".py")).touch()
        (self.runtime / "onnxruntime.py").write_text(
            'def get_available_providers(): return ["OpenVINOExecutionProvider", "CPUExecutionProvider"]\n',
            encoding="utf-8",
        )
        packaging = self.runtime / "packaging"
        packaging.mkdir()
        (packaging / "__init__.py").touch()
        (packaging / "requirements.py").write_text(
            "from pip._vendor.packaging.requirements import Requirement\n", encoding="utf-8",
        )
        runtime_metadata = self.runtime / "fixture_runtime-1.1.dist-info"
        runtime_metadata.mkdir()
        (runtime_metadata / "METADATA").write_text("Name: fixture-runtime\nVersion: 1.1\n", encoding="utf-8")
        for module in ("optimum/intel", "transformers", "librosa", "soundfile", "silero_vad"):
            (self.asr / (module + ".py")).touch()

    def create_models(self, version, weight, bad_checksum=False):
        entries = []
        for directory, contents in (("models", weight), ("hf-cache", "cached weights")):
            path = self.models / directory / "weight"
            path.parent.mkdir(exist_ok=True)
            path.write_text(contents, encoding="utf-8")
            checksum = "0" * 64 if bad_checksum and directory == "models" else digest(path)
            entries.append(f"{checksum}  {directory}/weight\n")
        (self.models / "MANIFEST.files.sha256").write_text("".join(entries), encoding="utf-8")
        (self.models / "VERSION").write_text(version + "\n", encoding="utf-8")
        (self.models / "MANIFEST.txt").write_text(f"nimoos-parser-models {version}\n", encoding="utf-8")
        write_json(self.models / "manifest.json", {"schema": 1, "bundle": version, "models": []})

    def archive(self, name, payload, version):
        archive = self.archive_dir / f"{name}-{version}.tar.zst"
        subprocess.run(["tar", "--zstd", "-cf", archive, "-C", payload, "."], check=True)
        return {
            "id": version,
            "archive": archive.name,
            "sha256": digest(archive),
            "size_bytes": archive.stat().st_size,
            "unpacked_bytes": 8 * 1024 * 1024,
        }

    def update(self, *options, succeeds=True):
        write_json(self.manifest, {
            "schema": 1,
            "python_abi": "cp311",
            "requirements_sha256": digest(self.requirements),
            "components": self.specs,
        })
        result = subprocess.run([
            sys.executable, ENGINE, "update", "--source", self.source, "--manifest", self.manifest,
            "--live", self.live, "--store", self.store, "--data-mount", self.root,
            "--prepare-command", HELPER, "--allow-overlay", "--no-service",
            "--archive-dir", self.archive_dir, "--deps-base", self.root / "offline-mirror", *options,
        ], env=self.env, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        self.assertFalse(self.offline_calls.exists(), result.stdout + result.stderr)
        release = (self.live / ".current").resolve(strict=True)
        components = json.loads((release / ".parser-release.json").read_text())["components"]
        return result, release, components

    def test_fresh_install_and_independent_updates(self):
        self.assertFalse(self.live.exists())
        _, initial, pins = self.update()
        for venv, module, component in (("venv", "onnxruntime", "runtime"), ("asr-venv", "optimum.intel", "asr")):
            code = f"import sys, pathlib, {module}; print(pathlib.Path(sys.prefix).resolve()); print(pathlib.Path(sys.executable).resolve())"
            prefix, interpreter = subprocess.check_output(
                [self.live / venv / "bin/python", "-I", "-c", code], env=self.env, text=True,
            ).splitlines()
            self.assertEqual(Path(prefix), self.store / pins[component] / venv)
            self.assertTrue(Path(interpreter).is_relative_to(self.store / pins["runtime"] / "uv-python"))
        for name in MODEL_METADATA:
            self.assertEqual((self.live / name).read_bytes(), (self.models / name).read_bytes())
        self.assertEqual((self.live / "models/.bundle-version").read_text(), "1.2.0\n")

        for archive in self.archive_dir.iterdir():
            archive.unlink()
        (self.source / "parser/main.py").write_text("RELEASE = 2\n", encoding="utf-8")
        result, code_release, code_pins = self.update("--code-only")
        self.assertNotEqual(code_release, initial)
        self.assertEqual(code_pins, pins)
        for name in pins:
            self.assertIn(f"reusing {name}", result.stdout)
        self.assertEqual((self.live / "parser/main.py").read_text(), "RELEASE = 2\n")

        self.create_models("1.2.1", "changed weight")
        good_model_spec = self.archive("models", self.models, "1.2.1")
        self.specs["models"] = good_model_spec
        _, model_release, model_pins = self.update()
        self.assertNotEqual(model_release, code_release)
        self.assertEqual(model_pins["runtime"], pins["runtime"])
        self.assertEqual(model_pins["asr"], pins["asr"])
        self.assertNotEqual(model_pins["models"], pins["models"])
        self.assertEqual((self.live / "models/weight").read_text(), "changed weight")

        self.create_models("1.2.2", "should not become active", bad_checksum=True)
        self.specs["models"] = self.archive("models", self.models, "1.2.2")
        result, recovered, recovered_pins = self.update(succeeds=False)
        self.assertIn("model checksum mismatch: models/weight", result.stdout + result.stderr)
        self.assertEqual(recovered, model_release)
        self.assertEqual(recovered_pins, model_pins)
        self.assertFalse((self.store / "transaction.json").exists())
        self.assertEqual(list((self.store / "transactions").iterdir()), [])
        self.assertFalse(any((self.store / "components/models").glob("1.2.2-*")))

        self.specs["models"] = good_model_spec
        weight = self.live / "models/weight"
        weight.write_text("changed bytes!", encoding="utf-8")
        result, recovered, recovered_pins = self.update("--code-only", succeeds=False)
        self.assertIn("model checksum mismatch: models/weight", result.stdout + result.stderr)
        self.assertEqual(recovered, model_release)
        self.assertEqual(recovered_pins, model_pins)
        self.assertEqual(list((self.store / "transactions").iterdir()), [])

    def test_first_legacy_migration_reuses_verified_models_and_preserves_flm(self):
        shutil.copytree(self.models, self.live)
        flm = self.live / "flm"
        flm.mkdir()
        (flm / "payload").write_text("existing FLM", encoding="utf-8")
        legacy_code = self.live / "parser"
        legacy_code.mkdir()
        (legacy_code / "main.py").write_text("RELEASE = 0\n", encoding="utf-8")
        spec = self.specs["models"]
        spec["legacy_files_manifest_sha256"] = digest(self.live / "MANIFEST.files.sha256")
        spec["legacy_metadata_sha256"] = {
            name: digest(self.live / name) for name in MODEL_METADATA if name != "MANIFEST.files.sha256"
        }
        (self.archive_dir / spec["archive"]).unlink()

        result, _, pins = self.update()
        self.assertIn("migrating verified legacy models", result.stdout)
        self.assertEqual((self.live / "parser/main.py").read_text(), "RELEASE = 1\n")
        self.assertEqual((self.live / "models/weight").resolve(), self.store / pins["models"] / "models/weight")
        self.assertEqual((self.live / "models/weight").read_text(), "initial weight")
        self.assertFalse(flm.is_symlink())
        self.assertEqual((flm / "payload").read_text(), "existing FLM")


class ParserFLMCleanupTest(unittest.TestCase):
    def test_commit_and_rollback_cleanup(self):
        cases = (
            ("rollback", False, True, None),
            ("rollback", True, True, "old"),
            ("rollback", True, False, "old"),
            ("commit", True, True, "new"),
        )
        for outcome, prior_exists, new_installed, expected in cases:
            with self.subTest(outcome=outcome, prior_exists=prior_exists, new_installed=new_installed), TemporaryDirectory(prefix="parser-flm-cleanup-") as temp:
                root = Path(temp)
                live, transaction = root / "live", root / "transaction"
                live.mkdir()
                transaction.mkdir()
                flm, old, stage = live / "flm", live / ".flm-old-123", live / ".flm-staging-123"
                for path, payload, exists in ((flm, "new", new_installed), (old, "old", prior_exists), (stage, "partial", True)):
                    if exists:
                        path.mkdir()
                        (path / "payload").write_text(payload, encoding="utf-8")
                record = transaction / "host-flm.json"
                write_json(record, {"root": str(live), "stage": str(stage), "old": str(old), "prior_exists": prior_exists})
                env = {**os.environ, "PARSER_TX_DIR": str(transaction), "PARSER_LIVE": str(live), "PARSER_TX_OUTCOME": outcome}
                subprocess.run([HELPER, "cleanup"], env=env, check=True, timeout=10)
                self.assertEqual((flm / "payload").read_text() if flm.exists() else None, expected)
                self.assertFalse(any(path.exists() for path in (record, old, stage)))
                subprocess.run([HELPER, "cleanup"], env=env, check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
