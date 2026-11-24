#!/usr/bin/env python3
"""Stage Parser releases on the data disk and switch the live path transactionally."""

import argparse
import contextlib
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request
import uuid


CHUNK = 1024 * 1024
DEFAULT_DATA_MOUNT = Path("/DATA")
VOLATILE_FILESYSTEMS = {"overlay", "tmpfs", "ramfs", "rootfs"}
COMPONENT_LINKS = {
    "runtime": ("venv", "uv-python"),
    "asr": ("asr-venv",),
    "models": ("models", "hf-cache"),
}
MODEL_METADATA = ("MANIFEST.txt", "MANIFEST.files.sha256", "VERSION", "manifest.json")
ANCHOR_ENTRIES = ("parser", "requirements.txt", *(link for links in COMPONENT_LINKS.values() for link in links), *MODEL_METADATA)
LEGACY_ENTRIES = {
    "parser", "requirements.txt", "venv", "uv-python", "asr-venv", "models",
    "hf-cache", *MODEL_METADATA, "flm",
}
DIGEST = re.compile(r"[a-f0-9]{64}")
IDENTIFIER = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._+-]{0,95}")
TX_ID = re.compile(r"[a-f0-9]{32}")
SUM_ROW = re.compile(r"([a-f0-9]{64})  (.+)")


class UpdateError(Exception):
    pass


def run_helper(command, env, lock_fds, capture):
    # Block delivery until there is a process handle and an exception path
    # that can terminate the child's independent session.
    signals = {signal.SIGTERM, signal.SIGINT}
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    try:
        process = subprocess.Popen(
            ["env", "--default-signal=INT,TERM", *command],
            env=env, pass_fds=lock_fds, start_new_session=True,
            stdout=subprocess.PIPE if capture else None, text=capture,
        )
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        raise
    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        stdout, _ = process.communicate()
    except BaseException:
        signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # Waiting for the leader alone would leave descendants alive if
            # they ignored SIGTERM. Kill the surviving group before cleanup.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if process.stdout is not None:
                process.stdout.close()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        raise
    return process.returncode, stdout


def exists(path):
    return os.path.lexists(path)


def flush_store(path):
    # A healthy candidate must survive a power cut after the durable switch
    # journal is written, including files created by the preparation helper.
    subprocess.run(["sync", "-f", "--", str(path)], check=True)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_json(path, body):
    # The fixed temporary name belongs to this single locked writer.
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(body, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    sync_dir(path.parent)


def load_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_path(value):
    if not isinstance(value, str) or "\x00" in value:
        raise UpdateError(f"invalid relative path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or value == "." or ".." in path.parts:
        raise UpdateError(f"invalid relative path: {value!r}")
    return path


def read_manifest(path, source):
    manifest = load_json(path)
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        raise UpdateError("unsupported Parser component manifest schema")
    if "architecture" in manifest:
        architecture = manifest["architecture"]
        host = os.uname().machine
        if architecture != host:
            raise UpdateError(f"Parser manifest architecture {architecture!r} does not match host {host!r}")
    components = manifest.get("components")
    if not isinstance(components, dict) or set(components) != set(COMPONENT_LINKS):
        raise UpdateError("manifest must specify runtime, asr and models")
    abi = manifest.get("python_abi")
    if not isinstance(abi, str) or not re.fullmatch(r"cp3[0-9]{1,2}", abi):
        raise UpdateError("manifest python_abi must be a CPython ABI tag")
    if manifest.get("requirements_sha256") != sha256_file(source / "requirements.txt"):
        raise UpdateError("Parser requirements.txt does not match the component manifest")
    for name, spec in components.items():
        if not isinstance(spec, dict):
            raise UpdateError(f"{name}: component must be an object")
        for field, pattern in (("id", IDENTIFIER), ("sha256", DIGEST)):
            value = spec.get(field)
            if not isinstance(value, str) or not pattern.fullmatch(value):
                raise UpdateError(f"{name}: invalid {field}")
        relative_path(spec.get("archive"))
        for field in ("size_bytes", "unpacked_bytes"):
            if type(spec.get(field)) is not int or spec[field] <= 0:
                raise UpdateError(f"{name}: invalid {field}")
        fingerprint = spec.get("content_fingerprint")
        if fingerprint is not None and (
            not isinstance(fingerprint, str) or not DIGEST.fullmatch(fingerprint)
        ):
            raise UpdateError(f"{name}: invalid content_fingerprint")
    models = components["models"]
    legacy_sums = models.get("legacy_files_manifest_sha256")
    legacy_metadata = models.get("legacy_metadata_sha256", {})
    if legacy_sums is not None and (not isinstance(legacy_sums, str) or not DIGEST.fullmatch(legacy_sums)):
        raise UpdateError("models: invalid legacy_files_manifest_sha256")
    if not isinstance(legacy_metadata, dict) or any(
        name not in MODEL_METADATA or not isinstance(pin, str) or not DIGEST.fullmatch(pin)
        for name, pin in legacy_metadata.items()
    ):
        raise UpdateError("models: invalid legacy_metadata_sha256")
    return manifest


def mount_entries():
    with open("/proc/self/mountinfo", encoding="utf-8") as stream:
        for line in stream:
            header, _, details = line.partition(" - ")
            columns = header.split()
            root, mount = (
                Path(re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value))
                for value in columns[3:5]
            )
            yield mount, details.split()[0], columns[2], root


def deepest_mount(path, entries):
    return max((entry for entry in entries if path.is_relative_to(entry[0])),
               key=lambda entry: len(entry[0].parts))


def require_data_mount(store, data_mount):
    if not store.is_relative_to(data_mount) or store == data_mount:
        raise UpdateError(f"Parser store must be inside {data_mount}")
    entries = {path: kind for path, kind, _, _ in mount_entries()}
    if data_mount not in entries:
        raise UpdateError(f"Parser data mount is not mounted: {data_mount}")
    deepest = max(
        (path for path in entries if store.is_relative_to(path)), key=lambda path: len(path.parts)
    )
    for path in (data_mount, deepest):
        if entries[path] in VOLATILE_FILESYSTEMS:
            raise UpdateError(f"Parser data mount {path} uses {entries[path]}")


def copy_stream(source, destination, limit):
    remaining = limit
    digest = hashlib.sha256()
    while True:
        chunk = source.read(CHUNK)
        if not chunk:
            break
        remaining -= len(chunk)
        if remaining < 0:
            raise UpdateError("download exceeds the manifest size")
        destination.write(chunk)
        digest.update(chunk)
    if remaining:
        raise UpdateError("download is shorter than the manifest size")
    return digest.hexdigest()


@contextlib.contextmanager
def archive_stream(base, archive):
    local = Path(base)
    if local.is_absolute():
        with (local / archive).open("rb") as stream:
            yield stream
        return
    url = urllib.parse.urlsplit(base)
    if url.scheme not in {"http", "https", "file"}:
        raise UpdateError("dependency base must be an absolute path or HTTP(S)/file URL")
    if url.query or url.fragment:
        raise UpdateError("dependency base must be a directory URL")
    address = base.rstrip("/") + "/" + urllib.parse.quote(archive, safe="/")
    with urllib.request.urlopen(address, timeout=120) as stream:
        yield stream


def fetch_archive(base, archive_dir, spec, destination):
    seeded = archive_dir is not None and (archive_dir / spec["archive"]).is_file()
    if seeded:
        print(f"Parser: reading local archive {spec['archive']}", flush=True)
        base = str(archive_dir)
    else:
        print(f"Parser: downloading {spec['archive']}", flush=True)
    with archive_stream(base, spec["archive"]) as source, destination.open("xb") as output:
        actual = copy_stream(source, output, spec["size_bytes"])
    if actual != spec["sha256"]:
        raise UpdateError(f"{spec['archive']}: SHA-256 mismatch")


def tar_member_path(name):
    while name.startswith("./"):
        name = name[2:]
    return relative_path(name.rstrip("/"))


def make_tar_parents(directory, target):
    for parent in reversed(target.relative_to(directory).parents):
        path = directory / parent
        if not exists(path):
            path.mkdir()
        elif path.is_symlink() or not path.is_dir():
            raise UpdateError(f"archive directory overlaps a non-directory: {parent}")


def extract_tar(stream, destination, limit):
    pending_links = {}
    directories = {}
    symlinks = []
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for member in archive:
            if member.isdir() and member.name in (".", "./"):
                continue
            rel = tar_member_path(member.name)
            path = destination / rel
            make_tar_parents(destination, path)
            if rel in pending_links:
                raise UpdateError(f"duplicate archive member: {member.name}")
            if member.isdir():
                if exists(path) and (path.is_symlink() or not path.is_dir()):
                    raise UpdateError(f"archive directory overlaps a non-directory: {member.name}")
                path.mkdir(exist_ok=True)
                directories[path] = member.mode & 0o777
                continue
            if exists(path):
                raise UpdateError(f"duplicate archive member: {member.name}")
            if member.isreg():
                limit -= member.size
                if limit < 0:
                    raise UpdateError("archive exceeds the manifest unpacked size")
                with archive.extractfile(member) as entry, path.open("xb") as output:
                    shutil.copyfileobj(entry, output, CHUNK)
                path.chmod(member.mode & 0o777)
            elif member.issym():
                target = posixpath.normpath(posixpath.join(str(rel.parent), member.linkname))
                if target != ".":
                    relative_path(target)
                path.symlink_to(member.linkname)
                symlinks.append(path)
            elif member.islnk():
                pending_links[rel] = tar_member_path(member.linkname)
            else:
                raise UpdateError(f"unsupported archive member: {member.name}")
    for path in symlinks:
        if not path.resolve().is_relative_to(destination):
            raise UpdateError(f"archive link escapes the component: {path.relative_to(destination)}")
    while pending_links:
        resolved = []
        for rel, target in pending_links.items():
            path, source = destination / rel, destination / target
            if target in pending_links:
                continue
            make_tar_parents(destination, path)
            if (exists(path) or not source.is_file() or source.is_symlink()
                    or source.resolve() != source):
                raise UpdateError(f"invalid archive hard link: {rel} -> {target}")
            os.link(source, path)
            resolved.append(rel)
        if not resolved:
            raise UpdateError("cyclic archive hard links")
        for rel in resolved:
            del pending_links[rel]
    for directory, mode in sorted(directories.items(), key=lambda item: -len(item[0].parts)):
        directory.chmod(mode)


def extract_archive(archive, spec, destination):
    destination.mkdir()
    if spec["archive"].endswith((".zst", ".zstd")):
        if shutil.which("zstd") is None:
            raise UpdateError("zstd is required to unpack Parser components")
        with subprocess.Popen(["zstd", "-dc", "--", str(archive)], stdout=subprocess.PIPE) as worker:
            try:
                extract_tar(worker.stdout, destination, spec["unpacked_bytes"])
                # A tar reader stops at the end marker, so drain the stream to
                # let zstd finish verifying the compressed frame and exit.
                for _ in iter(lambda: worker.stdout.read(CHUNK), b""):
                    pass
            except BaseException:
                worker.kill()
                raise
            if worker.wait():
                raise UpdateError("zstd could not unpack the Parser component")
    else:
        with archive.open("rb") as stream:
            extract_tar(stream, destination, spec["unpacked_bytes"])


def tree_entries(path):
    for entry in sorted(path.iterdir(), key=lambda item: item.name):
        if entry.name == "__pycache__" or entry.suffix == ".pyc":
            continue
        yield entry
        if not entry.is_symlink() and entry.is_dir():
            yield from tree_entries(entry)


def legacy_items(live, name, abi):
    if name == "models":
        keys = (*COMPONENT_LINKS["models"], *MODEL_METADATA)
        return [(key, live / key) for key in keys if exists(live / key)]
    version = "3." + abi[3:]
    location = live / COMPONENT_LINKS[name][0] / "lib" / ("python" + version) / "site-packages"
    if not location.is_dir() or location.is_symlink():
        return []
    return [
        (item.name, item)
        for item in location.iterdir()
        if item.name != "__pycache__" and item.suffix != ".pyc"
    ]


def legacy_digest(items):
    """Hash JSON records of relative path, type and SHA-256 or link target."""
    digest = hashlib.sha256()
    for name, root in sorted(items):
        for path in [root, *tree_entries(root)] if root.is_dir() and not root.is_symlink() else [root]:
            rel = posixpath.join(name, path.relative_to(root).as_posix()) if path != root else name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                link = os.readlink(path)
                target = posixpath.normpath(posixpath.join(posixpath.dirname(rel), link))
                if target != ".":
                    relative_path(target)
                record = (rel, "link", link)
            elif stat.S_ISDIR(mode):
                record = (rel, "directory")
            elif stat.S_ISREG(mode):
                record = (rel, "file", stat.S_IMODE(mode), sha256_file(path))
            else:
                raise UpdateError(f"unsupported file in legacy component: {path}")
            digest.update(json.dumps(record, ensure_ascii=True, separators=(",", ":")).encode() + b"\n")
    return digest.hexdigest()


def copy_legacy_items(items, destination):
    destination.mkdir()
    for name, source in items:
        target = destination / name
        if source.is_dir() and not source.is_symlink():
            shutil.copytree(source, target, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        else:
            shutil.copy2(source, target, follow_symlinks=False)


def legacy_model_target(path, trusted_roots):
    resolved = path.resolve()
    if not any(resolved.is_relative_to(root) for root in trusted_roots):
        raise UpdateError(f"legacy model path is outside Parser and its data mounts: {path}")
    return resolved


def legacy_model_items(root, spec, data_mounts=()):
    trusted_roots = (root.resolve(), *data_mounts)
    catalog_name = "MANIFEST.files.sha256"
    catalog = legacy_model_target(root / catalog_name, trusted_roots)
    metadata = [(catalog_name, catalog)]
    if not catalog.is_file():
        raise UpdateError("legacy model checksum catalog is missing")
    if sha256_file(catalog) != spec["legacy_files_manifest_sha256"]:
        raise UpdateError("legacy model checksum catalog does not match the pinned bundle")
    for name in MODEL_METADATA:
        if name == catalog_name:
            continue
        path = root / name
        pin = spec.get("legacy_metadata_sha256", {}).get(name)
        if pin:
            path = legacy_model_target(path, trusted_roots)
            if not path.is_file() or sha256_file(path) != pin:
                raise UpdateError(f"legacy model metadata does not match the pinned bundle: {name}")
            metadata.append((name, path))
        elif path.is_file() and not path.is_symlink():
            metadata.append((name, path))
    roots = {}
    for name in COMPONENT_LINKS["models"]:
        resolved = legacy_model_target(root / name, trusted_roots)
        if not resolved.is_dir():
            raise UpdateError(f"legacy model path is missing: {root / name}")
        roots[name] = resolved
    seen = set()
    with catalog.open(encoding="utf-8") as stream:
        for row in stream:
            match = SUM_ROW.fullmatch(row.rstrip("\n"))
            if match is None:
                raise UpdateError("invalid row in legacy model checksum catalog")
            pin, key = match.groups()
            relative = relative_path(key)
            if len(relative.parts) < 2 or relative.parts[0] not in roots or key in seen:
                raise UpdateError(f"invalid entry in legacy model checksum catalog: {key}")
            seen.add(key)
            model_root = roots[relative.parts[0]]
            path = model_root.joinpath(*relative.parts[1:]).resolve()
            if not path.is_relative_to(model_root) or not path.is_file() or sha256_file(path) != pin:
                raise UpdateError(f"legacy model checksum mismatch: {key}")
    if {key.split("/")[0] for key in seen} != set(roots):
        raise UpdateError("legacy model checksum catalog does not cover both model roots")
    return [*roots.items(), *metadata]


def validate_copied_model_links(path):
    for directory, subdirs, files in os.walk(path, followlinks=False):
        for name in (*subdirs, *files):
            entry = Path(directory) / name
            if entry.is_symlink() and not entry.resolve().is_relative_to(path):
                raise UpdateError(f"legacy model link escapes the copied tree: {entry.relative_to(path)}")


def tree_size(path):
    if path.is_symlink():
        return 4096
    if path.is_dir():
        return 4096 + sum(tree_size(entry) for entry in path.iterdir())
    return ((path.stat().st_size + 4095) // 4096) * 4096


class Installer:
    def __init__(self, args):
        self.args = args
        self.live = args.live.parent.resolve() / args.live.name
        self.pointer = self.live / ".current" if args.layout == "anchor" else self.live
        self.store = args.store.resolve()
        self.source = args.source.resolve()
        self.manifest_path = args.manifest.resolve()
        self.helper = args.prepare_command.resolve()
        self.archive_dir = args.archive_dir.resolve() if args.archive_dir else None
        self.journal = self.store / "transaction.json"
        self.state_path = self.store / "state.json"
        self.tx = {}
        self.profile = ""
        self.lock_fds = ()

    def run(self):
        if self.store.is_relative_to(self.live) or self.live.is_relative_to(self.store):
            raise UpdateError("Parser live path and data store must be separate")
        if self.args.allow_overlay and not self.args.no_service:
            raise UpdateError("--allow-overlay requires --no-service")
        if not self.args.allow_overlay:
            require_data_mount(self.store, self.args.data_mount.resolve())
        self.store.mkdir(mode=0o755, parents=True, exist_ok=True)
        for name in ("releases", "components", "transactions", "legacy"):
            directory = self.store / name
            directory.mkdir(exist_ok=True)
            if directory.is_symlink() or not directory.is_dir():
                raise UpdateError(f"invalid Parser store directory: {directory}")
        self.live.parent.mkdir(parents=True, exist_ok=True)
        # Keep one writer even if two administrators specify different data
        # stores for the same live path. The store lock also covers image pins.
        live_lock_path = self.live.with_name(f".{self.live.name}.update.lock")
        with live_lock_path.open("a") as live_lock, (self.store / "update.lock").open("a") as store_lock:
            fcntl.flock(live_lock, fcntl.LOCK_EX)
            fcntl.flock(store_lock, fcntl.LOCK_EX)
            self.lock_fds = (live_lock.fileno(), store_lock.fileno())
            if self.journal.exists():
                self.tx = load_json(self.journal)
                self.check_journal()
                print("Parser: recovering an interrupted update", flush=True)
                self.recover()
            self.manifest = read_manifest(self.manifest_path, self.source)
            if not (self.source / "parser").is_dir():
                raise UpdateError(f"Parser source directory is missing: {self.source / 'parser'}")
            self.update()

    @property
    def tx_dir(self):
        return self.store / "transactions" / self.tx["id"]

    @property
    def release(self):
        return self.store / "releases" / self.tx["id"]

    @property
    def legacy_backup(self):
        return self.legacy_path(self.tx["id"])

    def legacy_path(self, tx_id):
        if not isinstance(tx_id, str) or not TX_ID.fullmatch(tx_id):
            raise UpdateError("invalid Parser transaction ID")
        if self.args.layout == "anchor":
            return self.store / "legacy" / tx_id
        return self.live.with_name(f".{self.live.name}.legacy-{tx_id}")

    @property
    def pending_link(self):
        return self.pointer.with_name(f".{self.pointer.name}.link-{self.tx['id']}")

    def check_journal(self):
        self.legacy_path(self.tx["id"])
        if (self.tx["live"] != str(self.live) or self.tx["no_service"] != self.args.no_service
                or self.tx["layout"] != self.args.layout):
            raise UpdateError("interrupted Parser update requires the same live path and service mode")
        if self.tx["stage"] not in {"prepare", "switch", "commit"}:
            raise UpdateError("invalid Parser transaction stage")

    def save(self):
        write_json(self.journal, self.tx)

    def call(self, action, *, component="", candidate="", archive="", extracted="", refs=None,
             statuses=(0,), capture=False, outcome=""):
        refs = refs or self.tx.get("refs", {})
        env = {
            **os.environ,
            "PARSER_COMPONENT": component,
            "PARSER_CANDIDATE": str(candidate),
            "PARSER_ARCHIVE": str(archive),
            "PARSER_EXTRACTED": str(extracted),
            "PARSER_RUNTIME": str(self.store / refs["runtime"]) if "runtime" in refs else "",
            "PARSER_ASR": str(self.store / refs["asr"]) if "asr" in refs else "",
            "PARSER_MODELS": str(self.store / refs["models"]) if "models" in refs else "",
            "PARSER_RELEASE": str(self.release),
            "PARSER_LIVE": str(self.live),
            "PARSER_LIVE_POINTER": str(self.pointer),
            "PARSER_LEGACY": str(self.legacy_backup),
            "PARSER_STORE": str(self.store),
            "PARSER_DATA_MOUNT": str(self.args.data_mount.resolve()),
            "PARSER_MANIFEST": str(self.manifest_path),
            "PARSER_SOURCE": str(self.source),
            "PARSER_DEPS_BASE": self.args.deps_base,
            "PARSER_TX_DIR": str(self.tx_dir),
            "PARSER_PROFILE": self.profile,
            "PARSER_TX_OUTCOME": outcome,
        }
        status, stdout = run_helper([str(self.helper), action], env, self.lock_fds, capture)
        if statuses is not None and status not in statuses:
            raise UpdateError(f"Parser {action} {component} failed (exit {status})")
        return stdout.strip() if capture else status

    def service(self, action, statuses=(0,)):
        if self.args.no_service:
            return 1 if action == "active" else 0
        return self.call("service-" + action, statuses=statuses)

    def cleanup_helper(self, outcome):
        if not self.args.no_service and self.tx_dir.is_dir():
            self.call("cleanup", outcome=outcome)

    def managed(self, relative, kind):
        path = relative_path(relative)
        if kind == "releases":
            valid = len(path.parts) == 2 and TX_ID.fullmatch(path.name)
        else:
            valid = (len(path.parts) == 3 and path.parts[1] in {*COMPONENT_LINKS, "flm"}
                     and TX_ID.fullmatch(path.name[-32:]))
        if path.parts[0] != kind or not valid:
            raise UpdateError(f"invalid managed Parser path: {relative}")
        resolved = self.store / path
        if resolved.resolve() != resolved:
            raise UpdateError(f"managed Parser path contains a link: {relative}")
        return resolved

    def history(self):
        if self.state_path.exists():
            state = load_json(self.state_path)
            state.setdefault("pins", {})
            if state.get("live") != str(self.live) or state.get("layout") != self.args.layout:
                raise UpdateError("Parser store history belongs to a different live path or layout")
            return state
        return {"current": None, "previous": None, "legacy": [], "pins": {}}

    def release_metadata(self, release):
        if not release:
            return {"components": {}, "asr_runtime": None}
        return load_json(self.managed(release, "releases") / ".parser-release.json")

    def release_refs(self, release):
        return self.release_metadata(release)["components"]

    def retained_releases(self, state):
        return {release for release in (state["current"], state["previous"], *state["pins"].values())
                if release is not None}

    def component_refs(self, state):
        references = set()
        for release in self.retained_releases(state):
            metadata = self.release_metadata(release)
            references.update(metadata["components"].values())
            if metadata.get("asr_runtime"):
                references.add(metadata["asr_runtime"])
        for ref in references:
            self.managed(ref, "components")
        return references

    def component_pin(self, name):
        spec = self.manifest["components"][name]
        pin = {"id": spec["id"], "sha256": spec["sha256"]}
        if name != "models":
            pin["python_abi"] = self.manifest["python_abi"]
        if name == "runtime":
            pin["requirements_sha256"] = self.manifest["requirements_sha256"]
            pin["machine"] = os.uname().machine
            pin["profile"] = self.profile
        return pin

    def reusable(self, name, old_state, selected):
        retained = (old_state["current"], old_state["previous"], *old_state["pins"].values())
        for release in dict.fromkeys(retained):
            ref = self.release_refs(release).get(name)
            if not ref:
                continue
            candidate = self.managed(ref, "components")
            try:
                meta = load_json(candidate / ".parser-component.json")
            except (OSError, ValueError):
                continue
            if not isinstance(meta, dict) or meta.get("pin") != self.component_pin(name):
                continue
            if name == "asr" and not meta.get("runtime_base"):
                continue
            if any(not (candidate / link).is_dir() for link in COMPONENT_LINKS[name]):
                continue
            if not self.call("validate", component=name, candidate=candidate,
                             refs={**selected, name: ref}, statuses=None):
                return ref
        return None

    def preflight(self, changed, adopted, flm, backups=()):
        code_bytes = tree_size(self.source / "parser") + tree_size(self.source / "requirements.txt")
        sysroot = self.source / "build" / "sysroot"
        if sysroot.is_dir():
            code_bytes += tree_size(sysroot)
        kept = code_bytes + (tree_size(flm) if flm is not None else 0)
        kept += sum(tree_size(path) for path in backups)
        peak = kept
        for name in changed:
            spec = self.manifest["components"][name]
            if name not in adopted:
                kept += spec["unpacked_bytes"]
                peak = max(peak, kept + spec["size_bytes"])
            else:
                legacy_bytes = sum(tree_size(path) for _, path in adopted[name])
                kept += legacy_bytes
                peak = max(peak, kept)
        # The runtime archive is site-packages only. Leave room for the
        # standalone interpreter, the venv seed and the helper's scratch.
        interpreter = 512 * CHUNK if "runtime" in changed else 0
        required = peak + interpreter + max(64 * CHUNK, peak // 10)
        free = shutil.disk_usage(self.store).free
        if free < required:
            # Keep the real peak-space admission check. 8.6 GB is the owner's
            # minimum cleanup guidance, not a promise that every legacy layout
            # (including model copies and rollback) fits in that amount.
            gb = 1_000_000_000
            target = max(required, 8_600_000_000)
            def rounded_up(value):
                return ((value + gb // 10 - 1) // (gb // 10)) / 10
            raise UpdateError(
                f"insufficient free space on {self.store}: need {required} bytes, have {free} bytes. "
                f"请清理 {self.args.data_mount}，使可用空间至少达到 {rounded_up(target):.1f} GB 后重试"
                f"（最低建议 8.6 GB，本次估算需要 {rounded_up(required):.1f} GB；"
                f"当前可用 {free / gb:.1f} GB，还需释放 {rounded_up(target - free):.1f} GB）。"
            )

    def make_component(self, name, selected, adopted):
        spec = self.manifest["components"][name]
        relative = f"components/{name}/{spec['id']}-{self.tx['id']}"
        candidate = self.create_component(relative)
        extracted = self.tx_dir / "extracted"
        archive = ""
        if adopted is not None:
            try:
                if name == "models" and spec.get("legacy_files_manifest_sha256"):
                    extracted.mkdir()
                    for key, source in adopted:
                        if source.is_dir():
                            shutil.copytree(source, extracted / key, symlinks=True)
                        else:
                            shutil.copy2(source, extracted / key, follow_symlinks=False)
                    validate_copied_model_links(extracted)
                    legacy_model_items(extracted, spec)
                else:
                    copy_legacy_items(adopted, extracted)
                    copied = [(key, extracted / key) for key, _ in adopted]
                    if legacy_digest(copied) != spec["content_fingerprint"]:
                        raise UpdateError(f"legacy {name} changed while staging it")
            except (OSError, RuntimeError, UpdateError) as error:
                self.remove_tree(extracted)
                adopted = None
                print(f"Parser: legacy {name} copy could not be verified: {error}", file=sys.stderr)
                self.preflight([name], {}, None)
            else:
                print(f"Parser: migrating verified legacy {name}", flush=True)
        if adopted is None:
            archive = self.tx_dir / "component.archive"
            fetch_archive(self.args.deps_base, self.archive_dir, spec, archive)
            extract_archive(archive, spec, extracted)
        selected[name] = relative
        self.call("prepare", component=name, candidate=candidate, archive=archive,
                  extracted=extracted, refs=selected)
        if any(not (candidate / link).is_dir() for link in COMPONENT_LINKS[name]):
            raise UpdateError(f"{name}: prepared component layout is incomplete")
        self.call("validate", component=name, candidate=candidate, refs=selected)
        receipt = {"pin": self.component_pin(name)}
        if name == "asr":
            receipt["runtime_base"] = selected["runtime"]
        write_json(candidate / ".parser-component.json", receipt)
        if archive:
            archive.unlink()
        shutil.rmtree(extracted)

    def create_component(self, relative):
        candidate = self.managed(relative, "components")
        if exists(candidate):
            raise UpdateError(f"Parser candidate path already exists: {candidate}")
        candidate.parent.mkdir(exist_ok=True)
        self.tx["owned"].append(relative)
        self.save()
        candidate.mkdir()
        return candidate

    def install_release(self, selected):
        self.release.mkdir()
        shutil.copytree(
            self.source / "parser", self.release / "parser", symlinks=True,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        requirements = self.release / "requirements.txt"
        shutil.copy2(self.source / "requirements.txt", requirements)
        if sha256_file(requirements) != self.manifest["requirements_sha256"]:
            raise UpdateError("staged Parser requirements.txt does not match the component manifest")
        sysroot = self.source / "build" / "sysroot"
        if sysroot.is_dir():
            (self.release / "build").mkdir()
            shutil.copytree(sysroot, self.release / "build" / "sysroot", symlinks=True)
        for name, links in COMPONENT_LINKS.items():
            for link in links:
                (self.release / link).symlink_to(self.store / selected[name] / link)
        models = self.store / selected["models"]
        for metadata in MODEL_METADATA:
            if (models / metadata).is_file():
                (self.release / metadata).symlink_to(models / metadata)
        if "flm" in selected:
            (self.release / "flm").symlink_to(self.store / selected["flm"])
        asr_receipt = self.managed(selected["asr"], "components") / ".parser-component.json"
        write_json(self.release / ".parser-release.json", {
            "code_id": self.manifest.get("code_id"), "components": selected,
            "asr_runtime": load_json(asr_receipt)["runtime_base"],
        })
        self.call("check-release", refs=selected)

    def inspect_live(self, history):
        if self.args.layout == "anchor":
            if exists(self.live) and (self.live.is_symlink() or not self.live.is_dir()):
                raise UpdateError("anchored Parser live path must be a real directory")
            if self.pointer.is_symlink():
                for name in ANCHOR_ENTRIES:
                    entry = self.live / name
                    if not entry.is_symlink() or os.readlink(entry) != f".current/{name}":
                        raise UpdateError(f"managed Parser entry was changed: {entry}")
            elif exists(self.pointer):
                raise UpdateError("Parser .current pointer is occupied")
        if self.pointer.is_symlink():
            target = os.readlink(self.pointer)
            if history["current"] and self.pointer.resolve() != self.managed(history["current"], "releases"):
                raise UpdateError("live Parser link differs from the last committed release")
            if not history["current"]:
                raise UpdateError("live Parser link has no matching store history")
            return "symlink", target
        if history["current"] and (not self.args.pin or exists(self.live)):
            raise UpdateError("last committed Parser release is missing from the live path")
        if self.live.is_dir():
            if self.args.layout == "symlink":
                extra = sorted(set(os.listdir(self.live)) - LEGACY_ENTRIES)
                if extra:
                    raise UpdateError(f"legacy Parser has unrecognized entries: {', '.join(extra)}")
            return "directory", None
        if exists(self.live):
            raise UpdateError("Parser live path is neither a directory nor a managed link")
        return "missing", None

    def anchor_inventory(self):
        originals = {}
        for name in ANCHOR_ENTRIES:
            path = self.live / name
            if path.is_symlink():
                originals[name] = "symlink"
            elif path.is_file():
                originals[name] = "file"
            elif path.is_dir():
                originals[name] = "directory"
            elif exists(path):
                raise UpdateError(f"unsupported legacy Parser entry: {path}")
        return originals

    def same_mount_live_alias(self):
        # Linux rejects rename across mount boundaries. /opt is often a bind
        # mount of a directory already reachable inside the real data mount.
        entries = list(mount_entries())
        live_mount, live_kind, live_device, live_root = deepest_mount(self.live, entries)
        store_mount, _, store_device, store_root = deepest_mount(self.store, entries)
        if live_kind == "overlay" or live_device != store_device:
            return None
        location = live_root / self.live.relative_to(live_mount)
        if not location.is_relative_to(store_root):
            return None
        alias = store_mount / location.relative_to(store_root)
        if (alias.resolve() != alias or not alias.is_dir()
                or deepest_mount(alias, entries)[0] != store_mount
                or not os.path.samefile(alias, self.live)):
            return None
        return alias

    @property
    def anchor_mutation_path(self):
        alias = Path(self.tx["anchor_alias"])
        if not os.path.samefile(alias, self.live):
            raise UpdateError("Parser legacy backup mount changed during the transaction")
        return alias

    def prepare_anchor_backup(self):
        if self.args.layout != "anchor" or self.tx["prior_kind"] == "symlink":
            return []
        self.tx["anchor_originals"] = self.anchor_inventory()
        self.tx["anchor_touched"] = []
        alias = self.same_mount_live_alias() if self.tx["anchor_originals"] else self.live
        self.tx["anchor_alias"] = str(alias) if alias else None
        self.tx["anchor_copy"] = alias is None
        if self.tx["anchor_copy"]:
            return [self.live / name for name in self.tx["anchor_originals"]]
        return []

    def copy_anchor_backup(self):
        if not self.tx["anchor_copy"]:
            return
        self.legacy_backup.mkdir()
        for name, kind in self.tx["anchor_originals"].items():
            source, destination = self.live / name, self.legacy_backup / name
            if kind == "directory":
                shutil.copytree(source, destination, symlinks=True)
            else:
                shutil.copy2(source, destination, follow_symlinks=False)

    def update(self):
        history = self.history()
        prior_kind, prior_target = self.inspect_live(history)
        if self.args.code_only and prior_kind != "symlink":
            raise UpdateError("code-only Parser update requires an already managed installation")
        self.tx = {
            "id": uuid.uuid4().hex, "live": str(self.live), "stage": "prepare",
            "no_service": self.args.no_service, "layout": self.args.layout, "prior_kind": prior_kind,
            "prior_target": prior_target, "history": history, "owned": [], "refs": {},
            "pin": self.args.pin,
        }
        self.save()
        try:
            self.tx_dir.mkdir(mode=0o700)
            self.profile = self.call("profile", capture=True)
            if not IDENTIFIER.fullmatch(self.profile):
                raise UpdateError("Parser helper profile must be a single identifier")
            self.tx["profile"] = self.profile
            self.prepare_release(history, prior_kind)
            self.plan_commit()
            flush_store(self.store)
            self.switch_release()
            self.tx["stage"] = "commit"
            self.save()
        except BaseException:
            # Re-read the durable phase in case marking the commit raised after
            # renaming it into place.
            self.tx = load_json(self.journal)
            self.recover()
            raise
        self.finish_commit()

    def legacy_model_mounts(self):
        target_mount = self.args.data_mount.resolve()
        original_mount = DEFAULT_DATA_MOUNT.resolve()
        if original_mount == target_mount:
            return (target_mount,)
        for mount, kind, _, _ in mount_entries():
            if mount == original_mount and kind not in VOLATILE_FILESYSTEMS:
                return target_mount, original_mount
        return (target_mount,)

    def prepare_release(self, history, prior_kind):
        selected = self.tx["refs"]
        changed = []
        adopted = {}
        for name in COMPONENT_LINKS:
            ref = self.reusable(name, history, selected)
            if ref:
                print(f"Parser: reusing {name}", flush=True)
                selected[name] = ref
                continue
            if self.args.code_only:
                raise UpdateError(f"code-only Parser update requires an installed and verified {name} component")
            changed.append(name)
            spec = self.manifest["components"][name]
            if prior_kind == "directory":
                try:
                    if name == "models" and spec.get("legacy_files_manifest_sha256"):
                        adopted[name] = legacy_model_items(self.live, spec, self.legacy_model_mounts())
                    elif spec.get("content_fingerprint"):
                        items = legacy_items(self.live, name, self.manifest["python_abi"])
                        if items and legacy_digest(items) == spec["content_fingerprint"]:
                            adopted[name] = items
                except (OSError, RuntimeError, UpdateError) as error:
                    print(f"Parser: could not verify legacy {name}: {error}", file=sys.stderr)
        backups = self.prepare_anchor_backup()
        flm = self.release_refs(history["current"]).get("flm")
        legacy_flm = self.live / "flm"
        if self.args.layout == "anchor" or prior_kind != "directory" or not legacy_flm.is_dir():
            legacy_flm = None
        elif legacy_flm.is_symlink():
            raise UpdateError("legacy Parser flm is an unmanaged link")
        self.preflight(changed, adopted, legacy_flm, backups)
        if not self.args.no_service and not self.args.code_only:
            self.save()
            self.call("preflight-host")
        if self.args.layout == "anchor" and prior_kind != "symlink":
            self.copy_anchor_backup()
        for name in changed:
            self.make_component(name, selected, adopted.get(name))
        if legacy_flm is not None:
            flm = f"components/flm/{self.tx['id']}"
            candidate = self.create_component(flm)
            shutil.copytree(legacy_flm, candidate, dirs_exist_ok=True, symlinks=True)
        if flm:
            selected["flm"] = flm
        self.install_release(selected)

    def replace_live_link(self, target):
        if self.pending_link.is_symlink():
            self.pending_link.unlink()
        self.pending_link.symlink_to(target)
        os.replace(self.pending_link, self.pointer)
        sync_dir(self.pointer.parent)

    def install_anchor_entries(self):
        self.live.mkdir(exist_ok=True)
        if self.tx["anchor_originals"] and not self.tx["anchor_copy"]:
            self.legacy_backup.mkdir()
        for name in ANCHOR_ENTRIES:
            entry = self.live / name
            self.tx["anchor_touched"].append(name)
            self.save()
            if name in self.tx["anchor_originals"]:
                if self.tx["anchor_copy"]:
                    self.remove_entry(entry)
                else:
                    os.rename(self.anchor_mutation_path / name, self.legacy_backup / name)
                    sync_dir(self.legacy_backup)
            entry.symlink_to(f".current/{name}")
            sync_dir(self.live)
        sync_dir(self.live.parent)

    def switch_release(self):
        self.tx["old_active"] = self.service("active", statuses=(0, 1)) == 0
        should_run = self.tx["old_active"] or self.args.start
        self.tx["stage"] = "switch"
        self.save()
        if self.tx["old_active"]:
            self.service("stop")
        self.service("configure")
        if self.args.layout == "anchor":
            if self.tx["prior_kind"] != "symlink":
                self.install_anchor_entries()
        elif self.tx["prior_kind"] == "directory":
            os.rename(self.live, self.legacy_backup)
            sync_dir(self.live.parent)
        self.replace_live_link(self.release)
        if should_run:
            self.service("start")
            self.service("health")

    def recover(self):
        self.profile = self.tx.get("profile", "")
        if self.tx["stage"] == "commit":
            self.finish_commit()
            return
        was_switching = self.tx["stage"] == "switch"
        try:
            if was_switching:
                self.restore_live()
        finally:
            self.cleanup_helper("rollback")
        if was_switching and self.tx["old_active"]:
            self.service("start")
            self.service("health")
        self.tx["stage"] = "prepare"
        self.save()
        self.remove_transaction_candidates()

    def restore_live(self):
        if self.pointer.is_symlink() and os.readlink(self.pointer) == str(self.release):
            self.service("stop")
            if self.tx["prior_kind"] == "symlink":
                self.replace_live_link(self.tx["prior_target"])
            else:
                self.pointer.unlink()
                sync_dir(self.pointer.parent)
        if self.args.layout == "anchor" and self.tx["prior_kind"] != "symlink":
            self.restore_anchor_entries()
        elif self.args.layout == "symlink" and self.legacy_backup.is_dir():
            if exists(self.live):
                raise UpdateError("cannot restore legacy Parser while the live path is occupied")
            os.rename(self.legacy_backup, self.live)
            sync_dir(self.live.parent)
        self.service("restore")

    def restore_anchor_entries(self):
        kept = False
        for name in self.tx["anchor_touched"]:
            entry, backup = self.live / name, self.legacy_backup / name
            if name not in self.tx["anchor_originals"]:
                if entry.is_symlink() and os.readlink(entry) == f".current/{name}":
                    entry.unlink()
            elif exists(backup):
                if self.tx["anchor_copy"]:
                    # A lower-layer directory cannot be restored using rename.
                    # Link the old paths to their verified pre-switch snapshot.
                    target = os.readlink(backup) if backup.is_symlink() else str(backup)
                    if not entry.is_symlink() or os.readlink(entry) != target:
                        self.remove_entry(entry)
                        entry.symlink_to(target)
                    kept |= not backup.is_symlink()
                else:
                    self.remove_entry(entry)
                    os.rename(backup, self.anchor_mutation_path / name)
                    sync_dir(self.legacy_backup)
            sync_dir(self.live)
        if kept:
            old_state = self.tx["history"]
            legacy = [*old_state["legacy"], self.tx["id"]]
            write_json(self.state_path, {
                **old_state, "legacy": legacy, "live": str(self.live), "layout": self.args.layout,
            })
            self.tx["keep_legacy"] = True
        if self.pending_link.is_symlink():
            self.pending_link.unlink()
            sync_dir(self.live)
        if self.tx["prior_kind"] == "missing" and self.live.is_dir() and not any(self.live.iterdir()):
            self.live.rmdir()
            sync_dir(self.live.parent)

    def remove_entry(self, path):
        if not exists(path):
            return
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()

    def remove_tree(self, path):
        if exists(path):
            if path.is_symlink() or not path.is_dir():
                raise UpdateError(f"refusing to remove unexpected Parser path: {path}")
            shutil.rmtree(path)

    def remove_transaction_candidates(self):
        self.remove_tree(self.release)
        if self.args.layout == "anchor" and not self.tx.get("keep_legacy"):
            self.remove_tree(self.legacy_backup)
        for ref in self.tx["owned"]:
            target = self.managed(ref, "components")
            if not target.name.endswith(self.tx["id"]):
                raise UpdateError(f"cannot clean a candidate from another Parser transaction: {ref}")
            self.remove_tree(target)
        self.finish_cleanup()

    def finish_cleanup(self):
        self.remove_tree(self.tx_dir)
        if self.pending_link.is_symlink():
            self.pending_link.unlink()
            sync_dir(self.pointer.parent)
        for temporary in (self.journal.with_suffix(".json.tmp"), self.state_path.with_suffix(".json.tmp")):
            temporary.unlink(missing_ok=True)
        self.journal.unlink()
        sync_dir(self.store)

    def plan_commit(self):
        previous = self.tx["history"]
        state = {
            "current": f"releases/{self.tx['id']}", "previous": previous["current"],
            "legacy": [*previous["legacy"], self.tx["id"]] if self.tx["prior_kind"] == "directory" else [],
            "pins": dict(previous["pins"]), "layout": self.args.layout, "live": str(self.live),
        }
        if self.tx["pin"]:
            state["pins"][self.tx["pin"]] = state["current"]
        self.tx["next_state"] = state
        self.tx["obsolete_components"] = sorted(self.component_refs(previous) - self.component_refs(state))

    def finish_commit(self):
        previous = self.tx["history"]
        state = self.tx["next_state"]
        self.cleanup_helper("commit")
        write_json(self.state_path, state)
        for ref in self.tx["obsolete_components"]:
            self.remove_tree(self.managed(ref, "components"))
        for obsolete_release in self.retained_releases(previous) - self.retained_releases(state):
            self.remove_tree(self.managed(obsolete_release, "releases"))
        for old_legacy in set(previous["legacy"]) - set(state["legacy"]):
            self.remove_tree(self.legacy_path(old_legacy))
        self.finish_cleanup()
        print(f"Parser: activated {self.release}", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    update = subcommands.add_parser("update")
    for option in ("source", "manifest", "live", "store", "prepare-command"):
        update.add_argument("--" + option, type=Path, required=True)
    update.add_argument("--deps-base", default=os.environ.get("NIMO_DEPS_BASE", ""))
    update.add_argument("--data-mount", type=Path, default=DEFAULT_DATA_MOUNT)
    service = update.add_mutually_exclusive_group()
    service.add_argument("--start", action="store_true")
    service.add_argument("--no-service", action="store_true")
    update.add_argument("--allow-overlay", action="store_true")
    update.add_argument("--code-only", action="store_true")
    update.add_argument("--archive-dir", type=Path)
    update.add_argument("--pin")
    update.add_argument("--layout", choices=("anchor", "symlink"), default="anchor")
    args = parser.parse_args(argv)
    if not args.deps_base and not args.archive_dir:
        parser.error("--deps-base, NIMO_DEPS_BASE or --archive-dir is required")
    if args.pin and not IDENTIFIER.fullmatch(args.pin):
        parser.error("--pin must be an identifier")

    def interrupt(signum, _frame):
        raise UpdateError(f"interrupted by {signal.Signals(signum).name}")

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        Installer(args).run()
    except (OSError, RuntimeError, ValueError, KeyError, http.client.HTTPException,
            subprocess.SubprocessError, tarfile.TarError, UpdateError) as error:
        print(f"Parser update failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
