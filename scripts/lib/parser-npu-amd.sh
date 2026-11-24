#!/usr/bin/env bash
# parser-npu-amd.sh — install the AMD NPU package for the Parser's video speech
# recognition (FastFlowLM 1.0.12 + Whisper-V3-Turbo-NPU2 + a private XRT, built
# by scripts/package-parser-npu-amd.sh) on machines with the 1022:17f0 NPU.
# Sourced by deploy-parser.sh --amd-npu-package.
#
#   ensure_amd_npu_package   → download, verify and place the package under
#                              ${INSTALL_DIR}/flm; every failure warns and
#                              returns 0
#
# Caller provides: sudo_cmd (may be empty) and INSTALL_DIR, before sourcing.
# Optional: NIMO_DEPS_BASE, NIMO_DL_TMPDIR, NIMO_PARSER_NPU_AMD=0 (skip),
# NIMO_PCI_ROOT (tests).
#
# install-parser.sh keeps an inline copy of these functions and pins because a
# `curl | bash` install fetches only a fixed list of sub-scripts
# (nimoos-stack-install.sh bootstrap_scripts); install-parser.npu-amd.test.sh
# checks the copies are identical.

# Repinned together by scripts/package-parser-npu-amd.sh's output.
# PARSER_NPU_AMD_VERSION must move in the same release as, or later than,
# core's AMD NPU spec (its RuntimeVersion and acceptance record): a package
# newer than core's spec is installed but not accepted, and video speech
# recognition waits for the NPU instead of using it.
PARSER_NPU_AMD_VERSION="1.0.12-2"
PARSER_NPU_AMD_SHA256="0019e6e65d2c3f429321829d47e318ec8ffc454d126ac2d80683e8d1b85c5b26"
PARSER_NPU_AMD_SIZE_BYTES="681825825"
PARSER_NPU_AMD_UNPACKED_BYTES="1084101561"
DEP_NPU_AMD_BUNDLE="parser/nimoos-parser-npu-amd-${PARSER_NPU_AMD_VERSION}.tar.zst"
NPU_AMD_DIR="${INSTALL_DIR}/flm"

# Same defaults as lib/stack-fetch.sh, which deploy-parser.sh does not load.
: "${NIMO_DOWNLOAD_DOMAIN:=https://get.nimotech.ai/}"
: "${NIMO_DEPS_BASE:=${NIMO_DOWNLOAD_DOMAIN%/}/deps}"

declare -F log_info >/dev/null || log_info() { echo "    $*"; }
declare -F log_ok   >/dev/null || log_ok()   { echo "    $*"; }
declare -F log_warn >/dev/null || log_warn() { echo "WARNING: $*" >&2; }

avail_kb_of() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

kb_human() {
    awk -v kb="$1" 'BEGIN {
        u[0]="K"; u[1]="M"; u[2]="G"; u[3]="T"; v = kb + 0; i = 0
        while (v >= 1024 && i < 3) { v /= 1024; i++ }
        printf "%.1f%s", v, u[i]
    }'
}

dl_tmp() {
    local need="$1" need_kb min_kb want_kb dir avail
    local -a candidates=() tried=()

    need_kb=$(( (need + 1023) / 1024 ))
    min_kb=$(( need_kb * 11 / 10 ))

    if [[ -n "${NIMO_DL_TMPDIR:-}" ]]; then
        candidates=("${NIMO_DL_TMPDIR}")
    else
        candidates=("/tmp" "/var/tmp" "${INSTALL_DIR}/.download")
    fi

    for dir in "${candidates[@]}"; do
        if [[ "${dir}" == "${INSTALL_DIR}/.download" ]]; then
            ${sudo_cmd} mkdir -p "${dir}" 2>/dev/null || true
        fi
        if [[ ! -d "${dir}" ]]; then
            tried+=("${dir}=(no such directory)"); continue
        fi
        avail="$(avail_kb_of "${dir}")"
        if [[ ! "${avail}" =~ ^[0-9]+$ ]]; then
            tried+=("${dir}=(could not stat)"); continue
        fi
        tried+=("${dir}=$(kb_human "${avail}")")
        # ${INSTALL_DIR}/.download shares a filesystem with the extract target,
        # so it has to hold the archive AND its unpacked copy: ~2.1x, not 1.1x.
        want_kb="${min_kb}"
        [[ "${dir}" == "${INSTALL_DIR}/.download" ]] && want_kb=$(( need_kb * 21 / 10 ))
        if (( avail >= want_kb )); then
            # Logs go to stderr on purpose: every caller does tmp="$(dl_tmp ...)",
            # so anything this function writes to stdout becomes part of "the path".
            log_info "download scratch: ${dir} (need $(kb_human "${need_kb}"), have $(kb_human "${avail}"))" >&2
            mktemp -p "${dir}" || { log_warn "could not create a scratch file under ${dir} (permissions?)" >&2; return 1; }
            return 0
        fi
    done

    log_warn "no download scratch directory has $(kb_human "${min_kb}") free for a $(kb_human "${need_kb}") download — candidates: ${tried[*]}" >&2
    return 1
}

# rc 0 when a PCI device is the AMD NPU, 1022:17f0 (the only hardware the
# package's acceptance record names). NIMO_PCI_ROOT points tests at a fake tree.
amd_npu_present() {
    local dev
    for dev in "${NIMO_PCI_ROOT:-/sys/bus/pci/devices}"/*; do
        [[ "$(cat "${dev}/vendor" 2>/dev/null)" == "0x1022" && "$(cat "${dev}/device" 2>/dev/null)" == "0x17f0" ]] && return 0
    done
    return 1
}

# rc 0 when glibc is at least 2.39, which FastFlowLM 1.0.12 is built against.
amd_npu_glibc_ok() {
    local glibc
    glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null)" || glibc=""
    glibc="${glibc##* }"
    [[ "${glibc}" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 39) ))
}

# Prints the 64-bit host libraries FastFlowLM links that the dynamic linker
# cannot find (empty when all are there). /sbin is appended because ldconfig is
# not on a normal user's PATH on Debian; the cache goes through a variable, not
# a `| grep -q`, which pipefail would report as a failure on an early exit.
amd_npu_missing_libs() {
    local cache lib out=""
    cache="$(PATH="${PATH}:/sbin:/usr/sbin" ldconfig -p 2>/dev/null)" || cache=""
    for lib in libcurl.so.4 libedit.so.2 libgomp.so.1; do
        [[ "${cache}" == *$'\t'"${lib} (libc6,x86-64"* ]] || out="${out}${out:+ }${lib}"
    done
    echo "${out}"
}

# rc 0 when the host can run FastFlowLM. A missing library is installed with
# --no-upgrade (these three packages only, nothing else moves); glibc cannot be
# fixed that way, so an old one is only reported.
amd_npu_ensure_host_libs() {
    local -a pkgs=(libcurl4t64 libedit2 libgomp1)
    local missing
    if ! amd_npu_glibc_ok; then
        log_warn "glibc $(getconf GNU_LIBC_VERSION 2>/dev/null || echo unknown) is older than the 2.39 FastFlowLM needs; skipping the AMD NPU package (video speech recognition stays on CPU)."
        return 1
    fi
    missing="$(amd_npu_missing_libs)"
    [[ -z "${missing}" ]] && return 0
    if command -v apt-get >/dev/null 2>&1; then
        log_info "installing ${pkgs[*]} for FastFlowLM (missing: ${missing}) ..."
        if ! ${sudo_cmd} apt-get install -y --no-upgrade "${pkgs[@]}"; then
            # A fresh image can have stale or no package lists.
            ${sudo_cmd} apt-get update -qq || true
            ${sudo_cmd} apt-get install -y --no-upgrade "${pkgs[@]}" || true
        fi
        missing="$(amd_npu_missing_libs)"
    fi
    if [[ -n "${missing}" ]]; then
        log_warn "${missing} still missing; skipping the AMD NPU package (video speech recognition stays on CPU)."
        return 1
    fi
    return 0
}

# amd_npu_verify_tree <dir> <flm version>: rc 0 when the unpacked package is
# exactly what its nimoos-flm.json and model-root/SHA256SUMS say: every pinned
# file hashes to its pin, every link is the named same-directory link and ends
# at a pinned file, and nothing unlisted is there. Core and the Parser verify
# the installed tree again on their own; this keeps a damaged unpack from ever
# replacing a working one.
amd_npu_verify_tree() {
    ${sudo_cmd} python3 -I - "$1" "$2" <<'PY'
import hashlib, json, os, posixpath, re, stat, sys

root, version = sys.argv[1], sys.argv[2]


def fail(why):
    print(f"AMD NPU package check failed: {why}", file=sys.stderr)
    sys.exit(1)


def unique(pairs):
    body = dict(pairs)
    if len(body) != len(pairs):
        raise ValueError("duplicate key")
    return body


def regular(path):
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def digest_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entry_name(name):
    return (isinstance(name, str) and "\0" not in name and posixpath.normpath(name) == name
            and not name.startswith(("/", "../")) and name.split("/", 1)[0] in ("runtime", "xrt"))


try:
    manifest_path = os.path.join(root, "nimoos-flm.json")
    if not regular(manifest_path):
        fail("nimoos-flm.json is missing")
    with open(manifest_path, "rb") as stream:
        manifest = json.loads(stream.read().decode("utf-8"), object_pairs_hook=unique)
    if not isinstance(manifest, dict) or not set(manifest) <= {"schema_version", "runtime_id", "version", "files", "links"}:
        fail("nimoos-flm.json has unknown fields")
    files, links = manifest.get("files"), manifest.get("links") or {}
    if (manifest.get("schema_version") != 1 or manifest.get("runtime_id") != "amd-flm"
            or manifest.get("version") != version or not isinstance(files, dict) or not files
            or not isinstance(links, dict)):
        fail("nimoos-flm.json is not the amd-flm " + version + " manifest")
    pin = re.compile(r"[0-9a-f]{64}")
    for name, value in files.items():
        if not entry_name(name) or not isinstance(value, str) or not pin.fullmatch(value):
            fail(f"bad files entry {name!r}")
        path = os.path.join(root, name)
        if not regular(path):
            fail(f"{name} is not a regular file")
        if digest_of(path) != value:
            fail(f"{name} does not match nimoos-flm.json")
    for name, target in links.items():
        if (not entry_name(name) or name in files or not isinstance(target, str)
                or target in ("", ".", "..") or "/" in target or "\0" in target):
            fail(f"bad links entry {name!r}")
        path = os.path.join(root, name)
        if not os.path.islink(path) or os.readlink(path) != target:
            fail(f"{name} is not the link nimoos-flm.json names")
        current, ends = name, False
        for _ in range(len(links) + 1):
            following = posixpath.join(posixpath.dirname(current), links[current])
            if following in files:
                ends = True
                break
            if following not in links:
                break
            current = following
        if not ends:
            fail(f"{name} does not end at a pinned file")
    sums = os.path.join(root, "model-root", "SHA256SUMS")
    if not regular(sums):
        fail("model-root/SHA256SUMS is missing")
    listed = set()
    row = re.compile(r"([0-9a-f]{64})  (\S.*)")
    with open(sums, encoding="utf-8") as stream:
        for line in stream.read().splitlines():
            match = row.fullmatch(line)
            if not match:
                fail("model-root/SHA256SUMS has a malformed line")
            rel = match.group(2)
            if posixpath.normpath(rel) != rel or rel.startswith(("/", "../")) or rel == "SHA256SUMS":
                fail(f"model-root/SHA256SUMS names {rel!r}")
            path = os.path.join(root, "model-root", rel)
            if not regular(path) or digest_of(path) != match.group(1):
                fail(f"model-root/{rel} does not match SHA256SUMS")
            listed.add("model-root/" + rel)
    if not listed:
        fail("model-root/SHA256SUMS lists nothing")
    for dirpath, dirnames, filenames in os.walk(root):
        for entry in dirnames + filenames:
            path = os.path.join(dirpath, entry)
            rel = os.path.relpath(path, root)
            top = rel.split("/", 1)[0]
            mode = os.lstat(path).st_mode
            if stat.S_ISDIR(mode):
                continue
            if stat.S_ISLNK(mode):
                if rel not in links:
                    fail(f"unlisted link {rel}")
            elif not stat.S_ISREG(mode):
                fail(f"{rel} is not a file, a directory or a link")
            elif top in ("runtime", "xrt"):
                if rel not in files:
                    fail(f"unlisted file {rel}")
            elif top == "model-root":
                if rel != "model-root/SHA256SUMS" and rel not in listed:
                    fail(f"unlisted file {rel}")
            elif rel not in ("nimoos-flm.json", ".package-version"):
                fail(f"unexpected file {rel}")
except (OSError, ValueError) as exc:
    fail(str(exc))
PY
}

# The filesystem (device number) a path lives on; empty when it cannot be read.
amd_npu_dev_of() {
    stat -c %d "$1" 2>/dev/null || true
}

# amd_npu_set_modes <dir>: root:root, directories 00755 (which also clears a
# setgid bit inherited from INSTALL_DIR), files 0644, runtime/bin/flm 0755 --
# the modes core and the Parser require. flm must be a regular file before it
# is made executable, so a link can never pass the chmod on to its target.
amd_npu_set_modes() {
    ${sudo_cmd} chown -R root:root "$1" \
        && ${sudo_cmd} find "$1" -type d -exec chmod 00755 {} + \
        && ${sudo_cmd} find "$1" -type f -exec chmod 0644 {} + \
        && ${sudo_cmd} test -f "$1/runtime/bin/flm" \
        && ! ${sudo_cmd} test -L "$1/runtime/bin/flm" \
        && ${sudo_cmd} chmod 0755 "$1/runtime/bin/flm"
}

# amd_npu_modes_drifted <dir>: rc 0 when anything under <dir> is not what
# amd_npu_set_modes leaves (an owner or group other than root, a group/other
# writable file or directory, a directory that is not exactly 0755, or
# runtime/bin/flm not a regular 0755 file). Links are skipped for the write
# bits: a symlink's own mode is always 0777 and means nothing.
amd_npu_modes_drifted() {
    local hit
    hit="$(${sudo_cmd} find "$1" \( ! -user root -o ! -group root -o \( ! -type l -perm /022 \) -o \( -type d ! -perm 0755 \) \) -print -quit 2>/dev/null)" || return 0
    [[ -z "${hit}" ]] || return 0
    if [[ -f "$1/runtime/bin/flm" && ! -L "$1/runtime/bin/flm" && "$(${sudo_cmd} stat -c %a "$1/runtime/bin/flm" 2>/dev/null)" == "755" ]]; then
        return 1
    fi
    return 0
}

# The AMD NPU package (FastFlowLM + Whisper-V3-Turbo-NPU2 + a private XRT; see
# scripts/package-parser-npu-amd.sh) for video speech recognition on the NPU.
# Only machines with the 1022:17f0 NPU get it, under ${NPU_AMD_DIR} only:
# nothing goes to /usr, /etc or /opt/xilinx, and FLM is never installed with
# apt. Every failure warns and returns 0, leaving whatever was installed before
# untouched; the Parser then keeps transcribing on CPU (or keeps waiting for
# the NPU, on a machine that already had a working package).
#   NIMO_PARSER_NPU_AMD=0  skip it
ensure_amd_npu_package() {
    local url="${NIMO_DEPS_BASE}/${DEP_NPU_AMD_BUNDLE}" marker="${NPU_AMD_DIR}/.package-version"
    local stage="${INSTALL_DIR}/.flm-staging-$$" old="${INSTALL_DIR}/.flm-old-$$" tmp got t avail need_kb
    if [[ "${NIMO_PARSER_NPU_AMD:-1}" == "0" ]]; then
        log_info "NIMO_PARSER_NPU_AMD=0: skipping the AMD NPU package."
        return 0
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_info "not x86_64: skipping the AMD NPU package."
        return 0
    fi
    if ! amd_npu_present; then
        log_info "no AMD NPU (PCI 1022:17f0): skipping the AMD NPU package."
        return 0
    fi
    # Before the marker check, so a missing tool is reported as such and not
    # as a tree that "does not match".
    for t in zstd sha256sum python3; do
        if ! command -v "${t}" >/dev/null 2>&1; then
            log_warn "${t} is unavailable; skipping the AMD NPU package (video speech recognition stays as it was)."
            return 0
        fi
    done
    # A marker at the pin is trusted only for a tree that still matches its
    # manifest: a damaged file would otherwise keep an accepted machine waiting
    # for the NPU however often the installer reruns. Owner and modes are set
    # again too (idempotent): core and the Parser distrust a group-writable
    # file or directory even when its content is right.
    if [[ -f "${marker}" && "$(cat "${marker}" 2>/dev/null)" == "${PARSER_NPU_AMD_VERSION}" ]]; then
        log_info "AMD NPU package ${PARSER_NPU_AMD_VERSION} is marked as installed; checking it ..."
        if amd_npu_verify_tree "${NPU_AMD_DIR}" "${PARSER_NPU_AMD_VERSION%-*}"; then
            # Only on drift: chmod and chown move ctime, which core's and the
            # Parser's runtime and model signatures include, so touching an
            # unchanged tree would make both re-hash it and fail a running
            # AMD task.
            if amd_npu_modes_drifted "${NPU_AMD_DIR}"; then
                log_info "resetting the owner and modes of ${NPU_AMD_DIR} ..."
                if ! amd_npu_set_modes "${NPU_AMD_DIR}"; then
                    log_warn "could not reset the owner and modes of ${NPU_AMD_DIR}; core and the Parser may not trust it."
                    return 0
                fi
            fi
            log_ok "AMD NPU package ${PARSER_NPU_AMD_VERSION} already in place, skipping the download."
            return 0
        fi
        log_info "the installed AMD NPU package does not match its manifest; installing it again."
    fi
    amd_npu_ensure_host_libs || return 0
    if ! tmp="$(dl_tmp "${PARSER_NPU_AMD_SIZE_BYTES}")"; then
        log_warn "no download scratch directory has room for the AMD NPU package; skipping it (set NIMO_DL_TMPDIR to a roomier disk and rerun)."
        return 0
    fi
    # The unpacked tree with a 10% margin, plus the archive itself when the
    # download sits on the same filesystem (both exist until the unpack ends).
    avail="$(avail_kb_of "${INSTALL_DIR}")" || avail=""
    need_kb=$(( (PARSER_NPU_AMD_UNPACKED_BYTES + 1023) / 1024 * 11 / 10 ))
    if [[ "$(amd_npu_dev_of "${tmp%/*}")" == "$(amd_npu_dev_of "${INSTALL_DIR}")" ]]; then
        need_kb=$(( need_kb + (PARSER_NPU_AMD_SIZE_BYTES + 1023) / 1024 ))
    fi
    if [[ ! "${avail}" =~ ^[0-9]+$ ]] || (( avail < need_kb )); then
        rm -f "${tmp}"
        log_warn "${INSTALL_DIR} has $(kb_human "${avail:-0}") free, the AMD NPU package needs $(kb_human "${need_kb}") there; skipping it (video speech recognition stays as it was)."
        return 0
    fi
    log_info "downloading the AMD NPU package ${PARSER_NPU_AMD_VERSION} (~$(kb_human $(( PARSER_NPU_AMD_SIZE_BYTES / 1024 )))): ${url} ..."
    # Bounded: ~650 MB needs >= ~0.4 MB/s per attempt; a stalled mirror is cut off
    # by the speed floor sooner.
    if ! curl -fSL --retry 3 --connect-timeout 10 --speed-limit 1024 --speed-time 60 --max-time 1800 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"
        log_warn "could not fetch the AMD NPU package (${url}); video speech recognition stays as it was."
        return 0
    fi
    got="$(stat -c%s "${tmp}" 2>/dev/null)" || got=""
    if [[ "${got}" != "${PARSER_NPU_AMD_SIZE_BYTES}" ]]; then
        rm -f "${tmp}"
        log_warn "the AMD NPU package is ${got:-of unknown size} bytes, not the pinned ${PARSER_NPU_AMD_SIZE_BYTES}; not installing it."
        return 0
    fi
    if ! echo "${PARSER_NPU_AMD_SHA256}  ${tmp}" | sha256sum -c --status -; then
        rm -f "${tmp}"
        log_warn "the AMD NPU package failed its checksum (stale mirror copy?); not installing it."
        return 0
    fi
    # Other invocations' leftovers are owned by their own recovery journal.
    [[ ! -e "${stage}" && ! -e "${old}" ]] || { log_warn "FLM transaction path already exists; refusing to overwrite it"; rm -f "${tmp}"; return 0; }
    if ! ${sudo_cmd} mkdir -p -m 0755 "${stage}" \
        || ! ${sudo_cmd} tar --zstd --no-same-owner -xf "${tmp}" -C "${stage}"; then
        rm -f "${tmp}"
        ${sudo_cmd} rm -rf "${stage}" || true
        log_warn "could not unpack the AMD NPU package into ${stage}; check free space there. Nothing was changed."
        return 0
    fi
    rm -f "${tmp}"
    if ! amd_npu_set_modes "${stage}"; then
        ${sudo_cmd} rm -rf "${stage}" || true
        log_warn "could not set the AMD NPU package's owner and modes (or runtime/bin/flm is not a regular file); nothing was changed."
        return 0
    fi
    if ! amd_npu_verify_tree "${stage}" "${PARSER_NPU_AMD_VERSION%-*}"; then
        ${sudo_cmd} rm -rf "${stage}" || true
        log_warn "the unpacked AMD NPU package does not match its own manifest; nothing was changed."
        return 0
    fi
    [[ "${NIMO_PARSER_TRANSACTIONAL_NPU:-0}" == 1 ]] || ${sudo_cmd} rm -rf "${old}" || true
    if [[ -e "${NPU_AMD_DIR}" || -L "${NPU_AMD_DIR}" ]] && ! ${sudo_cmd} mv -T "${NPU_AMD_DIR}" "${old}"; then
        ${sudo_cmd} rm -rf "${stage}" || true
        log_warn "could not move the installed AMD NPU package aside; nothing was changed."
        return 0
    fi
    if ! ${sudo_cmd} mv -T "${stage}" "${NPU_AMD_DIR}"; then
        if [[ -e "${old}" ]]; then ${sudo_cmd} mv -T "${old}" "${NPU_AMD_DIR}" || true; fi
        ${sudo_cmd} rm -rf "${stage}" || true
        log_warn "could not move the new AMD NPU package into ${NPU_AMD_DIR}; the previous one is back."
        return 0
    fi
    [[ "${NIMO_PARSER_TRANSACTIONAL_NPU:-0}" == 1 ]] || ${sudo_cmd} rm -rf "${old}" || true
    # Written last: a run that stopped anywhere above is retried next time.
    if ! echo "${PARSER_NPU_AMD_VERSION}" | ${sudo_cmd} tee "${marker}" >/dev/null \
        || ! ${sudo_cmd} chmod 0644 "${marker}"; then
        log_warn "the AMD NPU package is in place but ${marker} could not be written; the next run installs it again."
        return 0
    fi
    log_ok "AMD NPU package ${PARSER_NPU_AMD_VERSION} in place at ${NPU_AMD_DIR}."
    return 0
}
