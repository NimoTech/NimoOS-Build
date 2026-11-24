#!/usr/bin/env bash
# install-parser.sh — First-time installer for nimoos-parser.service
#
# Sets up the Python Parser in one pass:
#   - prepares Python 3.11 and a venv
#   - creates /opt/nimoos-parser/{parser,venv,hf-cache}
#   - installs requirements.txt (docling / rapidocr / FlagEmbedding / torch)
#   - installs the systemd unit and /etc/nimoos/parser.conf
#   - creates /var/lib/nimoos/parser, /var/log/nimoos, /var/run/nimoos
#   - checks whether Qdrant is running (127.0.0.1:6333)
#   - on machines with the AMD NPU (1022:17f0), places the AMD NPU package
#     (FastFlowLM + Whisper) under /opt/nimoos-parser/flm
#
# Usage: sudo bash install-parser.sh [--start]
#
# By default the service is enabled but not started; pass --start to bring it up
# immediately. Use deploy-parser.sh for subsequent code updates.

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

PARSER_INSTALL_ARGS=("$@")
START_AFTER_INSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start) START_AFTER_INSTALL=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

###############################################################################
# Paths
###############################################################################

readonly APP_NAME="nimoos-parser"
readonly APP_NAME_SHORT="parser"
readonly SERVICE_FILE="${APP_NAME}.service"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack-fetch.sh
source "${SCRIPT_DIR}/lib/stack-fetch.sh"

# Release coordinates. The Python package is architecture-independent
# (linux-all); with no local source tree it is downloaded from the mirror.
readonly PROJECT="NimoOS-Parser"
readonly TOKEN="nimoos-parser"
readonly ARCH_MODE="all"
readonly VERSION="${STACK_VERSION_PARSER:-${STACK_VERSION}}"
readonly PARSER_SRC_DEFAULT="${DEPLOY_SRC_DIR:-$(cd "${SCRIPT_DIR}/../../NimoOS-Parser" 2>/dev/null && pwd || true)}"

# Filled in by acquire()
RESOLVED=""; MODE=""; SYSROOT=""; UNIT_SRC=""; CONF_SAMPLE_SRC=""

# Set by fetch_models_bundle when it takes one of the two legitimate skips
# (NIMO_PARSER_MODELS=0 or a non-x86_64 host); read by verify_models_bundle at
# the end of the run to tell "skipped on purpose" from "should have a marker
# but does not".
MODELS_SKIPPED=0

readonly INSTALL_DIR="${NIMO_PARSER_INSTALL_DIR:-/opt/nimoos-parser}"
readonly VENV_DIR="${INSTALL_DIR}/venv"
readonly HF_CACHE_DIR="${INSTALL_DIR}/hf-cache"
# Where uv puts its standalone CPython: system-wide and root-owned, so it does
# not depend on any one user's home directory.
readonly UV_PY_DIR="${INSTALL_DIR}/uv-python"

# The interpreter used to build the venv, filled in by check_python(). Defaults
# to the system python3, and is replaced by a uv-provided 3.11 on systems whose
# python is 3.12 or newer.
PARSER_PY="python3"
UV_BIN=""

# Prebuilt fast path: on x86_64 a ready-made venv plus models is pulled from
# deps/parser/, skipping pip (slow, and unreachable on some networks) and the
# first-run Hugging Face model download. The venv is cp311 manylinux, ABI
# compatible with the uv-provided 3.11, and requires the target glibc to be at
# least as new as the build machine's (2.36).
#
# All parser models ship in ONE bundle (2026-09-18, owner's call): a dozen
# separately pinned model tarballs, each with its own sha/gate/publish step,
# was unreadable to anyone but the person who packed them. See
# scripts/package-parser-models.sh for what is inside and why. Bumping any
# model now means bumping PARSER_MODELS_VERSION; there is no per-model knob
# any more — every box that fetches the bundle gets the same set, and the
# parser picks what it needs at runtime.
#   NIMO_PARSER_BUILD=1   force a pip install from source, ignoring the prebuilt venv
#   NIMO_PARSER_MODELS=0  skip the models bundle download entirely (the only
#                         other legitimate skip is running on a non-x86_64
#                         host; any other failure to obtain the bundle is now
#                         fatal — see fetch_models_bundle)
#   NIMO_PARSER_VIDEO=0   skip the ASR sidecar venv (a code dependency, not a
#                         model; the video models themselves still land with
#                         the bundle either way — this only disables the
#                         sidecar interpreter that runs them)
#   NIMO_DL_TMPDIR=<dir>  scratch directory to download the bundle into,
#                         instead of the auto-picked one (see dl_tmp()). This
#                         is a choice, not a hint: it is only ever checked for
#                         free space here, never silently swapped out for
#                         another directory when it is too small.
readonly DEP_VENV="parser/parser-venv-${VERSION}-cp311-linux-x86_64.tar.zst"
# dl_tmp() sizes its scratch-directory search off the download it is about to
# do. The prebuilt venv and the ASR sidecar site-packages carry no size pin of
# their own (unlike the models bundle below), so these are conservative,
# hand-picked estimates — used only to prefer a roomier candidate directory,
# never compared against what actually downloads.
readonly DL_SIZE_ESTIMATE_PREBUILT_VENV=$((2 * 1024 * 1024 * 1024))   # a few GB of cp311 site-packages
readonly DL_SIZE_ESTIMATE_ASR_VENV=$((600 * 1024 * 1024))             # ~455M per the log line below, rounded up
# The one models bundle: every weight the parser reads, at one pinned version.
# PARSER_MODELS_SHA256 and PARSER_MODELS_SIZE_BYTES are repinned together with
# PARSER_MODELS_VERSION by scripts/package-parser-models.sh's output — never
# hand-edited independently.
readonly PARSER_MODELS_VERSION="1.2.0"
readonly PARSER_MODELS_SHA256="5810a1d9f57a6e13d9da39aaf44bc3b1da8a72537d53a01fd76c9687a0230904"
readonly PARSER_MODELS_SIZE_BYTES="18388955123"
readonly DEP_MODELS_BUNDLE="parser/nimoos-parser-models-${PARSER_MODELS_VERSION}.tar.zst"
readonly MODELS_BUNDLE_MARKER="${INSTALL_DIR}/models/.bundle-version"
# Site-packages only, not a whole venv: the venv is created here with the same
# interpreter the main venv uses, so it works whatever 3.11.x uv provisioned.
# A tarball of a complete venv carries the build machine's interpreter path in
# pyvenv.cfg and breaks on any machine whose uv-python patch version differs.
readonly DEP_ASR_VENV="parser/asr-venv-site-packages-cp311-linux-x86_64.tar.zst"
readonly DEP_ASR_VENV_SHA256="23226470ef0c7027f4760f7314117d40aaecbf93149a1d392e283589e24146ca"
# Built by us from llama-cpp-python 0.3.34 without dynamic backends (AVX2 + OpenMP,
# Vulkan; the build also needs spirv-headers). 160 MiB unpacked. AMD machines only.
readonly DEP_LLAMA_VULKAN_WHEEL="parser/llama-cpp-python-0.3.34-vulkan/llama_cpp_python-0.3.34-py3-none-linux_x86_64.whl"
readonly DEP_LLAMA_VULKAN_SHA256="541d1688d58e6047a3154fa140829a72c238e054b3c3812b44ef16f9a07b7fbb"
# Holds every model weight the parser reads, unpacked from the models bundle
# (fetch_models_bundle): the caption forms (qwen3-vl-4b-int4/, qwen3-vl-4b-gguf/),
# the OpenVINO text IRs (bge-m3-ov/, bge-reranker-v2-m3-ov/), and the rest of
# COMPONENTS in scripts/package-parser-models.sh.
readonly VLM_MODELS_DIR="${INSTALL_DIR}/models"
# The ASR sidecar interpreter (parser/config.py: asr_sidecar_python).
readonly ASR_VENV_DIR="${INSTALL_DIR}/asr-venv"
# The AMD NPU package for video speech recognition: FastFlowLM 1.0.12, the
# Whisper-V3-Turbo-NPU2 model and a private XRT, built by
# scripts/package-parser-npu-amd.sh and placed by ensure_amd_npu_package on
# machines with the 1022:17f0 NPU only. The pins below are repinned together
# from that script's output; lib/parser-npu-amd.sh carries the same values.
# PARSER_NPU_AMD_VERSION must move in the same release as, or later than,
# core's AMD NPU spec (its RuntimeVersion and acceptance record): a package
# newer than core's spec is installed but not accepted, and video speech
# recognition waits for the NPU instead of using it.
#   NIMO_PARSER_NPU_AMD=0  skip the AMD NPU package
readonly PARSER_NPU_AMD_VERSION="1.0.12-2"
readonly PARSER_NPU_AMD_SHA256="0019e6e65d2c3f429321829d47e318ec8ffc454d126ac2d80683e8d1b85c5b26"
readonly PARSER_NPU_AMD_SIZE_BYTES="681825825"
readonly PARSER_NPU_AMD_UNPACKED_BYTES="1084101561"
readonly DEP_NPU_AMD_BUNDLE="parser/nimoos-parser-npu-amd-${PARSER_NPU_AMD_VERSION}.tar.zst"
readonly NPU_AMD_DIR="${INSTALL_DIR}/flm"

readonly CONF_PATH="/etc/nimoos"
readonly CONF_FILE="${CONF_PATH}/${APP_NAME_SHORT}.conf"
readonly UNIT_DST="/usr/lib/systemd/system/${SERVICE_FILE}"
readonly DATA_DIR="/var/lib/nimoos/parser"
readonly LOG_DIR="/var/log/nimoos"
readonly RUN_DIR="/var/run/nimoos"

###############################################################################
# Helpers
###############################################################################

log_info()  { echo -e "\e[32m[ INFO ]\e[0m $*"; }
log_ok()    { echo -e "\e[32m[  OK  ]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[ WARN ]\e[0m $*"; }
log_fail()  { echo -e "\e[31m[FAILED]\e[0m $*"; exit 1; }

###############################################################################
# Steps
###############################################################################

acquire() {
    log_info "acquiring the payload (local source first, otherwise download ${VERSION}) ..."
    set +e
    RESOLVED="$(stack_resolve "${PARSER_SRC_DEFAULT}" "${PROJECT}" "${VERSION}" "${ARCH_MODE}" "${TOKEN}")"
    local rc=$?
    set -e
    case "${rc}" in
        0)  MODE="source" ;;
        10) MODE="download" ;;
        *)  log_fail "could not obtain the payload: no local source tree and the download failed" ;;
    esac
    SYSROOT="${RESOLVED}/build/sysroot"
    # The repository template lives under usr/lib/. Writing it to lib/ instead was
    # one cause of the "changed in the repo, never took effect on the machine"
    # class of deployment drift; the lib/ fallback stays for older payload layouts.
    UNIT_SRC="${SYSROOT}/usr/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${UNIT_SRC}" ]] || UNIT_SRC="${SYSROOT}/lib/systemd/system/${SERVICE_FILE}"
    CONF_SAMPLE_SRC="${SYSROOT}/etc/nimoos/${APP_NAME_SHORT}.conf"
    [[ -d "${RESOLVED}/parser" ]] || log_fail "parser package directory missing: ${RESOLVED}/parser"
    [[ -f "${RESOLVED}/requirements.txt" ]] || log_fail "requirements.txt missing: ${RESOLVED}/requirements.txt"
    [[ -f "${UNIT_SRC}" ]] || log_fail "systemd unit missing: ${UNIT_SRC}"
    [[ -f "${CONF_SAMPLE_SRC}" ]] || log_fail "sample configuration missing: ${CONF_SAMPLE_SRC}"
    log_ok "mode=${MODE}  payload=${RESOLVED}"
}

# Make sure venv/ensurepip works for the given interpreter — Debian ships venv
# as a separate package.
ensure_venv_module() {
    local py="$1"
    [ -x "$(command -v apt-get)" ] || { "${py}" -c 'import ensurepip' >/dev/null 2>&1 || log_fail "${py} has no venv support (import ensurepip failed)"; return; }
    "${py}" -c 'import ensurepip' >/dev/null 2>&1 && return
    local pyver
    pyver="$("${py}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    log_info "installing venv support (python${pyver}-venv, falling back to python3-venv) ..."
    # apt's exit status can be polluted by unrelated broken packages on the
    # system, so swallow it with `|| true` and judge the result by ensurepip.
    ${sudo_cmd} apt-get update -qq || true
    ${sudo_cmd} apt-get install -y "python${pyver}-venv" 2>/dev/null \
        || ${sudo_cmd} apt-get install -y python3-venv || true
    "${py}" -c 'import ensurepip' >/dev/null 2>&1 \
        || log_fail "venv is still unavailable (import ensurepip failed); fix apt/venv by hand and retry"
}

# Locate or install uv (astral.sh). It goes in /usr/local/bin so that both root
# and the service can use it.
ensure_uv() {
    UV_BIN="$(command -v uv 2>/dev/null || true)"
    [ -z "${UV_BIN}" ] && [ -x /usr/local/bin/uv ] && UV_BIN=/usr/local/bin/uv
    [ -z "${UV_BIN}" ] && [ -x "${HOME}/.local/bin/uv" ] && UV_BIN="${HOME}/.local/bin/uv"
    [ -z "${UV_BIN}" ] && [ -x /root/.local/bin/uv ] && UV_BIN=/root/.local/bin/uv
    if [ -n "${UV_BIN}" ]; then log_ok "uv is available: ${UV_BIN} ($(${UV_BIN} --version 2>/dev/null))"; return; fi

    log_info "installing uv from astral.sh into /usr/local/bin ..."
    local tmp_uv; tmp_uv="$(mktemp)"
    curl -fLsS --connect-timeout 10 https://astral.sh/uv/install.sh -o "${tmp_uv}" \
        || log_fail "could not download the uv installer (astral.sh unreachable); install uv manually and retry"
    ${sudo_cmd} env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh "${tmp_uv}" \
        || log_fail "uv installation failed"
    rm -f "${tmp_uv}"
    UV_BIN=/usr/local/bin/uv
    [ -x "${UV_BIN}" ] || log_fail "uv was installed but ${UV_BIN} is missing"
    log_ok "uv installed: $(${UV_BIN} --version 2>/dev/null)"
}

check_python() {
    log_info "preparing a Python 3.11 runtime (rapidocr, docling and friends only publish wheels for 3.11 and older) ..."

    local sysver
    sysver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"

    # 1) The system python3 happens to be 3.11 — use it directly
    if [ "${sysver}" = "3.11" ]; then
        ensure_venv_module python3
        PARSER_PY="python3"
        log_ok "using the system Python ${sysver}"
        return
    fi
    # 2) A separate python3.11 command exists — use that
    if command -v python3.11 >/dev/null 2>&1; then
        ensure_venv_module python3.11
        PARSER_PY="$(command -v python3.11)"
        log_ok "using python3.11: $(python3.11 --version)"
        return
    fi
    # 3) The system python is too new (3.12+, e.g. Debian 13's 3.13) or too old,
    #    and rapidocr has no matching wheel. Have uv provide a standalone,
    #    self-contained CPython 3.11 for the venv, leaving the system python alone.
    log_warn "system Python is ${sysver:-unknown}, which is incompatible with parser's dependencies. Using a standalone Python 3.11 from uv instead."
    ensure_uv
    ${sudo_cmd} mkdir -p "${UV_PY_DIR}"
    log_info "installing a standalone CPython 3.11 via uv (into ${UV_PY_DIR}) ..."
    ${sudo_cmd} env "UV_PYTHON_INSTALL_DIR=${UV_PY_DIR}" "${UV_BIN}" python install 3.11 \
        || log_fail "uv python install 3.11 failed"
    PARSER_PY="$(${sudo_cmd} env "UV_PYTHON_INSTALL_DIR=${UV_PY_DIR}" "${UV_BIN}" python find 3.11 2>/dev/null)"
    [ -n "${PARSER_PY}" ] && ${sudo_cmd} test -x "${PARSER_PY}" \
        || log_fail "uv did not provide a usable Python 3.11 (find returned: ${PARSER_PY:-empty})"
    log_ok "using uv's Python 3.11: ${PARSER_PY}"
}

check_libreoffice() {
    # NimoOS-Parser needs `soffice --headless` to convert legacy OLE office
    # formats (.doc / .ppt / .xls / .wps) to modern Open XML before docling
    # ingests them. Without these packages those formats record as
    # "skipped" — their content is not searchable.
    # See parser/legacy_office_extractor.py.
    local pkgs=(libreoffice-core libreoffice-writer libreoffice-impress libreoffice-calc)
    local missing=()
    for p in "${pkgs[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        log_ok "LibreOffice is available (soffice headless)"
        return
    fi
    log_info "installing the LibreOffice headless dependencies: ${missing[*]} (~300-400MB) ..."
    if [ -x "$(command -v apt-get)" ]; then
        # apt's exit status can be polluted by unrelated broken packages (a custom
        # kernel whose postinst fails, say), so it cannot be trusted here. Swallow
        # it with `|| true` and check the real outcome with dpkg afterwards.
        ${sudo_cmd} apt-get update -qq || true
        ${sudo_cmd} apt-get install -y "${missing[@]}" || true
        local still=()
        for p in "${missing[@]}"; do
            dpkg -s "$p" >/dev/null 2>&1 || still+=("$p")
        done
        if (( ${#still[@]} == 0 )); then
            log_ok "LibreOffice installed."
        else
            log_warn "these packages are still missing: ${still[*]}"
            log_warn ".doc/.ppt/.xls/.wps files will not be indexed (you can install them later)."
        fi
    else
        log_warn "no apt-get; install these by hand: ${missing[*]}"
        log_warn ".doc/.ppt/.xls/.wps files will not be indexed."
    fi
}

check_ffmpeg() {
    # The video pipeline shells out to ffmpeg/ffprobe for every clip it touches
    # (parser/video_media.py): probing duration, cutting window audio, sampling
    # frames. Nothing in the NimoOS package set pulls it in — `nimoos` does not
    # depend on it — so a machine can pass every other check and still fail on
    # the first video. Non-fatal: everything except video works without it.
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
        log_ok "ffmpeg/ffprobe are available"
        return
    fi
    log_info "installing ffmpeg (the video pipeline shells out to ffmpeg/ffprobe) ..."
    if [ -x "$(command -v apt-get)" ]; then
        # Same reasoning as check_libreoffice: apt's exit status can be polluted
        # by unrelated broken packages, so check the real outcome afterwards.
        ${sudo_cmd} apt-get update -qq || true
        ${sudo_cmd} apt-get install -y ffmpeg || true
    elif [ -x "$(command -v pacman)" ]; then
        ${sudo_cmd} pacman -S --noconfirm --needed ffmpeg || true
    fi
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
        log_ok "ffmpeg installed."
    else
        log_warn "ffmpeg/ffprobe are still missing; video indexing will fail on every clip until they are installed."
    fi
}

check_qdrant() {
    log_info "checking Qdrant (127.0.0.1:6333) ..."
    if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:(6333|6334)'; then
        log_ok "Qdrant is listening on 6333/6334"
    else
        log_warn "Qdrant is not listening on 6333, so Parser will fail to start."
        cat <<'EOF'
        Suggested Docker command:
          docker run -d --restart=always --name qdrant \
            --memory=4g --memory-swap=4g \
            -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 \
            -v /var/lib/qdrant:/qdrant/storage \
            qdrant/qdrant:latest
EOF
    fi
}

install_dirs() {
    log_info "creating ${INSTALL_DIR} / ${DATA_DIR} / ${LOG_DIR} / ${RUN_DIR} ..."
    ${sudo_cmd} mkdir -p \
        "${INSTALL_DIR}" "${HF_CACHE_DIR}" \
        "${CONF_PATH}" "${DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}"
}

# Release packages and the dependency bundles recorded their CI builder's owner,
# 1000:1001, on every entry, and this script unpacked and synced them as root
# without dropping it: a parser tree a root service runs, writable by whoever
# is uid 1000 on the machine. Everything below now lands as root's
# (--no-same-owner, rsync --no-owner --no-group). This gives root back what an
# earlier run left behind, including bundles that are already in place and so
# are never unpacked again. Only the exact CI pair is changed.
repair_ci_ownership() {
    local n
    n="$(${sudo_cmd} find "${INSTALL_DIR}" -xdev -uid 1000 -gid 1001 -print 2>/dev/null | wc -l)"
    [[ "${n}" -gt 0 ]] || return 0
    log_info "giving root back ${n} path(s) under ${INSTALL_DIR} left owned by uid 1000 by an earlier install ..."
    ${sudo_cmd} find "${INSTALL_DIR}" -xdev -uid 1000 -gid 1001 -exec chown -h 0:0 {} + 2>/dev/null \
        || log_warn "could not restore every owner under ${INSTALL_DIR}; check with: find ${INSTALL_DIR} -uid 1000"
}

install_source() {
    log_info "syncing the parser package to ${INSTALL_DIR}/parser/ ..."
    if command -v rsync &>/dev/null; then
        ${sudo_cmd} rsync -a --no-owner --no-group --delete \
            --exclude='__pycache__' --exclude='*.pyc' \
            "${RESOLVED}/parser/" "${INSTALL_DIR}/parser/"
    else
        ${sudo_cmd} rm -rf "${INSTALL_DIR}/parser"
        ${sudo_cmd} cp -r "${RESOLVED}/parser" "${INSTALL_DIR}/parser"
    fi
    ${sudo_cmd} cp "${RESOLVED}/requirements.txt" "${INSTALL_DIR}/requirements.txt"
}

ensure_zstd() {
    command -v zstd >/dev/null 2>&1 && return 0
    log_info "installing zstd (needed to unpack the prebuilt archives) ..."
    if [ -x "$(command -v apt-get)" ]; then
        ${sudo_cmd} apt-get update -qq || true
        ${sudo_cmd} apt-get install -y zstd || true
    fi
    command -v zstd >/dev/null 2>&1
}

# x86_64 and not forced to build from source, so the prebuilt path applies
use_prebuilt() {
    [[ "$(uname -m)" == "x86_64" && "${NIMO_PARSER_BUILD:-0}" != "1" ]]
}

# KB a site-packages archive takes once unpacked: every entry rounded up to
# whole 4K blocks, plus one block for its inode/directory entry. tar stream
# sizes alone undercount a tree of many small .py/.pyc files. Fails when the
# archive cannot be listed in full (missing, truncated, not zstd).
site_packages_need_kb() {
    # pipefail in the command substitution only: a tar that dies part-way
    # through the listing must not pass for a small archive.
    (set -o pipefail
     tar --zstd -tvf "$1" 2>/dev/null | awk '
        { s = $3; kb += 4; if (s ~ /^[0-9]+$/) kb += int((s + 4095) / 4096) * 4 }
        END { if (NR == 0) exit 1; printf "%d\n", kb }')
}

# State for the EXIT/INT/TERM trap swap_in_site_packages sets while it works.
# The installer sets no other trap, so the swap owns them and clears them when
# it is done (re-arming a caller's trap from `trap -p` is not safe: inside a
# subshell it would arm the parent's EXIT trap there too).
SP_SWAP_DIR=""; SP_SWAP_STAGE=""; SP_SWAP_OLD=""

# Undo a swap that did not finish: drop the half-built stage and, when the live
# directory was already moved aside but the new one never took its place, put
# the old one back. Runs from the trap and from every failure path.
sp_swap_rollback() {
    [[ -n "${SP_SWAP_STAGE}" ]] && ${sudo_cmd} rm -rf "${SP_SWAP_STAGE}" 2>/dev/null
    if [[ -n "${SP_SWAP_OLD}" && -e "${SP_SWAP_OLD}" && ! -e "${SP_SWAP_DIR}" ]]; then
        ${sudo_cmd} mv -T "${SP_SWAP_OLD}" "${SP_SWAP_DIR}" 2>/dev/null
    fi
    SP_SWAP_DIR=""; SP_SWAP_STAGE=""; SP_SWAP_OLD=""
    trap - EXIT INT TERM
    return 0
}

# swap_in_site_packages <archive> <site-packages dir> <venv python> <modules>
#
# Replaces <site-packages dir> with the archive's contents without ever
# leaving it half-written. BUG-0163 (121, 2026-11-17): the old code removed the
# live site-packages of a running Parser and unpacked over it in place; /opt
# filled up part-way and Parser kept running on a tree with files missing, so
# every job failed with ENOENT. Now:
#   1. leftovers of an interrupted earlier run are cleared (an "old" copy whose
#      live directory is gone is put back first);
#   2. the unpacked size is checked against the free space on the filesystem
#      that holds the directory, with the current copy still in place;
#   3. the archive is unpacked into a sibling (same filesystem, so the swap is
#      a rename) and the venv's interpreter imports <modules> from it there,
#      with -S so the current site-packages is not on the path;
#   4. only then is the current copy renamed aside, the new one renamed into
#      place, and the old one deleted.
# Any failure before step 4 completes leaves the current directory exactly as
# it was. rc 0: new tree in place; rc 1: the archive could not be used (listing,
# unpack or import check failed, or a rename failed); rc 2: not enough free
# space next to the current tree.
swap_in_site_packages() {
    local archive="$1" sp="$2" py="$3" mods="$4"
    local parent need_kb min_kb avail_kb leftover
    parent="$(dirname "${sp}")"
    ${sudo_cmd} mkdir -p "${parent}" || return 1

    for leftover in "${sp}".old.*; do
        [[ -e "${leftover}" ]] || continue
        if [[ ! -e "${sp}" ]]; then
            log_warn "restoring ${sp} from ${leftover}, left behind by an interrupted earlier run ..."
            ${sudo_cmd} mv -T "${leftover}" "${sp}" || return 1
        else
            ${sudo_cmd} rm -rf "${leftover}" || true
        fi
    done
    ${sudo_cmd} rm -rf "${sp}".new.* || true

    log_info "measuring the unpacked size of $(basename "${archive}") ..."
    need_kb="$(site_packages_need_kb "${archive}")" \
        || { log_warn "could not list ${archive} (truncated or not a zstd tarball?)"; return 1; }
    min_kb=$(( need_kb * 11 / 10 ))
    avail_kb="$(avail_kb_of "${parent}")"
    if [[ ! "${avail_kb}" =~ ^[0-9]+$ ]] || (( avail_kb < min_kb )); then
        log_warn "not enough free space next to ${sp}: the new tree needs $(kb_human "${min_kb}") (with a 10% margin) and only $(kb_human "${avail_kb:-0}") is free; the current one stays as it is."
        return 2
    fi

    SP_SWAP_DIR="${sp}"; SP_SWAP_STAGE="${sp}.new.$$"; SP_SWAP_OLD="${sp}.old.$$"
    trap 'sp_swap_rollback' EXIT
    trap 'sp_swap_rollback; exit 130' INT TERM
    log_info "unpacking into ${SP_SWAP_STAGE} ($(kb_human "${need_kb}")) ..."
    if ! ${sudo_cmd} mkdir -p "${SP_SWAP_STAGE}" \
        || ! ${sudo_cmd} tar --zstd --no-same-owner -xf "${archive}" -C "${SP_SWAP_STAGE}"; then
        log_warn "could not unpack ${archive}; the current ${sp} is unchanged."
        sp_swap_rollback; return 1
    fi
    # -I: no PYTHONPATH, user site or cwd; -S: the current site-packages stays
    # off the path, so only the staged tree can satisfy the imports. addsitedir
    # still runs the staged .pth files, as the real site-packages will.
    if ! ${sudo_cmd} "${py}" -I -S -c "import site, sys; site.addsitedir(sys.argv[1]); import ${mods}" \
        "${SP_SWAP_STAGE}" >/dev/null 2>&1; then
        log_warn "the unpacked tree failed its import check (${mods}); the current ${sp} is unchanged."
        sp_swap_rollback; return 1
    fi
    if [[ -e "${sp}" || -L "${sp}" ]] && ! ${sudo_cmd} mv -T "${sp}" "${SP_SWAP_OLD}"; then
        log_warn "could not move ${sp} aside; it is unchanged."
        sp_swap_rollback; return 1
    fi
    if ! ${sudo_cmd} mv -T "${SP_SWAP_STAGE}" "${sp}"; then
        log_warn "could not move the new tree into ${sp}; the previous one is back."
        sp_swap_rollback; return 1
    fi
    SP_SWAP_STAGE=""
    ${sudo_cmd} rm -rf "${SP_SWAP_OLD}" || log_warn "could not remove ${SP_SWAP_OLD}; the next run removes it."
    SP_SWAP_OLD=""
    sp_swap_rollback
    return 0
}

# Download the prebuilt venv's site-packages and swap it in. rc 0 on success;
# rc 2 when there is not enough free space to unpack it next to the current
# one (the caller stops: pip needs the same room, and the current venv is left
# as it was); any other status tells the caller to fall back to pip, again on
# an untouched venv.
fetch_prebuilt_venv() {
    ensure_zstd || { log_warn "zstd is unavailable, cannot use the prebuilt venv"; return 1; }
    local url="${NIMO_DEPS_BASE}/${DEP_VENV}"
    local tmp rc=0
    tmp="$(dl_tmp "${DL_SIZE_ESTIMATE_PREBUILT_VENV}")" \
        || { log_warn "no download scratch directory has enough free space for the prebuilt venv; falling back to pip"; return 1; }
    log_info "downloading the prebuilt venv: ${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"; log_warn "prebuilt venv download failed (this version may not publish one)"; return 1
    fi
    local sp="${VENV_DIR}/lib/python3.11/site-packages"
    # The import check runs on the staged tree, before it replaces anything:
    # can the key compiled extensions be imported by this machine's
    # interpreter? A glibc or ABI mismatch shows up here, and we fall back.
    # ctranslate2 (query translation) and scenedetect (shot-detection fallback)
    # are in the list because they were added to requirements.txt after the
    # published venv was last built: an older package imports torch fine and
    # then leaves Parser with translation permanently disabled. Treating that
    # as "the prebuilt venv is stale" sends it down the pip path, which honours
    # requirements.txt.
    swap_in_site_packages "${tmp}" "${sp}" "${VENV_DIR}/bin/python" \
        'torch, onnxruntime, uvicorn, ctranslate2, scenedetect' || rc=$?
    rm -f "${tmp}"
    case "${rc}" in
        0) log_ok "prebuilt venv in place (pip skipped)." ;;
        2) return 2 ;;
        *) log_warn "the prebuilt venv could not be used (glibc/ABI mismatch, a package older than requirements.txt, or a bad download), falling back to pip"; return 1 ;;
    esac
}

# KB of free space on the filesystem that holds $1 (which must exist). A
# separate function so tests can shim it directly instead of faking `df`.
avail_kb_of() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Render a KB count as a short human string ("15.1G", "733G", "480M") for log
# messages only; every actual comparison in dl_tmp uses the raw KB integer.
kb_human() {
    awk -v kb="$1" 'BEGIN {
        u[0]="K"; u[1]="M"; u[2]="G"; u[3]="T"; v = kb + 0; i = 0
        while (v >= 1024 && i < 3) { v /= 1024; i++ }
        printf "%.1f%s", v, u[i]
    }'
}

# Scratch directory for a download of $1 bytes: hand back a fresh empty file
# (mktemp -p) in the first candidate directory with room, or fail.
#
# Candidates, in order: an explicit NIMO_DL_TMPDIR (a choice, not a hint — it
# is only ever checked for space here, never silently swapped out for another
# directory), then /tmp, /var/tmp, then ${INSTALL_DIR}/.download (created on
# demand, so there is always a last resort on the disk the install itself
# lives on). "Room" means avail >= need * 11/10, a 10% margin for filesystem
# block rounding.
#
# This replaces the old hardcoded default of /var/tmp: on every real NimoOS
# box /var/tmp sits on the 7.5G overlayroot while /tmp is a bind mount of the
# real data disk, the exact opposite of the comment this function used to
# carry. A ~14.7G models bundle there always ENOSPCs (2026-09-18, two
# production boxes) — and on the owner's own box even /tmp has too little
# room and the bundle has to land on a RAID mount, so failing loudly with the
# candidates' actual free space is the point, not an edge case.
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

# Best-effort HTTP HEAD to learn a download's size before committing scratch
# space to it. Echoes the Content-Length in bytes, or fails (many mirrors, and
# the fixture curl shim tests run against, do not implement HEAD — callers
# fall back to a pinned size).
head_content_length() {
    local url="$1" headers
    headers="$(curl -fsSI --connect-timeout 10 "${url}" 2>/dev/null)" || return 1
    echo "${headers}" | tr -d '\r' \
        | awk 'tolower($0) ~ /^content-length:/ {print $2; found=1} END{exit !found}'  # tolower(): IGNORECASE is gawk-only, Debian ships mawk
}

# Note when a HEAD-reported size and a pinned size disagree by more than 10%
# — either the pin is stale (the bundle changed and PARSER_MODELS_SIZE_BYTES
# was not bumped alongside it) or the mirror is serving something unexpected.
# Non-fatal either way: the HEAD value (the more current of the two) is what
# scratch selection uses.
report_size_mismatch() {
    local head="$1" pin="$2" diff pct
    diff=$(( head > pin ? head - pin : pin - head ))
    pct=$(( diff * 100 / pin ))
    if (( pct > 10 )); then
        log_warn "models bundle size mismatch: HEAD reports $(kb_human $((head / 1024))) but PARSER_MODELS_SIZE_BYTES pins $(kb_human $((pin / 1024))) (${pct}% apart); using the HEAD value."
    fi
}

# Caption (Qwen3-VL) weights come in two forms and the parser's backend
# select picks candidates by which form is actually on disk — both now ship
# in the models bundle, so both land on every box regardless of hardware:
#   - OpenVINO int4 IR (qwen3-vl-4b-int4/): Intel iGPU/dGPU via openvino-genai.
#   - GGUF (qwen3-vl-4b-gguf/): llama.cpp, any hardware, CPU included.
# ensure_openvino_runtime below still needs to know which forms are on disk
# to decide what to top the venv up with.
vlm_ir_present() {
    [[ -f "${VLM_MODELS_DIR}/qwen3-vl-4b-int4/openvino_language_model.xml" ]]
}

text_ov_present() {
    [[ -f "${VLM_MODELS_DIR}/bge-m3-ov/openvino_model.xml" \
    && -f "${VLM_MODELS_DIR}/bge-reranker-v2-m3-ov/openvino_model.xml" ]]
}

# Download and unpack the ONE models bundle (nimoos-parser-models-<version>.tar.zst):
# every weight the parser reads, at one pinned version — see
# scripts/package-parser-models.sh.
#
# Unlike the per-model packages this replaced, a failure to obtain the bundle
# is now FATAL (exit 1), not a warning: the old "warn and return 0" let
# nimoos-update.sh print `[ OK ] NimoOS updated ...` with not one model byte
# on disk (2026-09-18, two production boxes — /var/tmp sat on the 7.5G
# overlayroot, the ~14.7G download always ENOSPC'd, and the failure was
# silently swallowed here). The only two legitimate reasons to skip the
# bundle stay non-fatal and explicit, and both set MODELS_SKIPPED=1 so
# verify_models_bundle at the end of the run does not also complain:
#   NIMO_PARSER_MODELS=0   the operator asked to skip it
#   non-x86_64             no prebuilt bundle is published for this arch
# Everything past that — no scratch directory with room, the download itself
# failing, a checksum mismatch, or a failed extract — now stops the install,
# because the parser is not going to work without these weights.
fetch_models_bundle() {
    if [[ "${NIMO_PARSER_MODELS:-1}" == "0" ]]; then
        log_info "NIMO_PARSER_MODELS=0: skipping the models bundle download."
        MODELS_SKIPPED=1; return 0
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_info "not x86_64: skipping the models bundle."
        MODELS_SKIPPED=1; return 0
    fi
    if [[ -f "${MODELS_BUNDLE_MARKER}" && "$(cat "${MODELS_BUNDLE_MARKER}")" == "${PARSER_MODELS_VERSION}" ]]; then
        log_ok "models bundle ${PARSER_MODELS_VERSION} already in place, skipping the download."; return 0
    fi
    ensure_zstd || log_fail "zstd is unavailable and is required to unpack the models bundle; install zstd and retry."

    local url="${NIMO_DEPS_BASE}/${DEP_MODELS_BUNDLE}" need
    if need="$(head_content_length "${url}")"; then
        report_size_mismatch "${need}" "${PARSER_MODELS_SIZE_BYTES}"
    else
        need="${PARSER_MODELS_SIZE_BYTES}"
    fi

    local tmp
    tmp="$(dl_tmp "${need}")" || log_fail "no download scratch directory has $(kb_human $(( need * 11 / 10 / 1024 ))) free for the $(kb_human $(( need / 1024 ))) models bundle. Set NIMO_DL_TMPDIR=<dir with enough free space> (e.g. a RAID mount) and retry."

    log_info "downloading the parser models bundle ${PARSER_MODELS_VERSION} (~$(kb_human $(( need / 1024 )))): ${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"
        log_fail "could not fetch the models bundle (${url}). Check connectivity to NIMO_DEPS_BASE=${NIMO_DEPS_BASE} and retry."
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        rm -f "${tmp}"
        log_fail "sha256sum is unavailable, cannot verify the models bundle; install coreutils and retry."
    fi
    if ! echo "${PARSER_MODELS_SHA256}  ${tmp}" | sha256sum -c --status -; then
        rm -f "${tmp}"
        log_fail "models bundle checksum mismatch (stale CDN copy or a truncated download?) for ${url}; retry, or set NIMO_DL_TMPDIR to a roomier disk if the previous attempt may have run out of space mid-download."
    fi
    if ! ${sudo_cmd} mkdir -p "${VLM_MODELS_DIR}" "${HF_CACHE_DIR}" \
        || ! ${sudo_cmd} tar --zstd --no-same-owner -xf "${tmp}" -C "${INSTALL_DIR}"; then
        rm -f "${tmp}"
        log_fail "could not unpack the models bundle into ${INSTALL_DIR}; check free space there and retry."
    fi
    rm -f "${tmp}"
    echo "${PARSER_MODELS_VERSION}" | ${sudo_cmd} tee "${MODELS_BUNDLE_MARKER}" >/dev/null
    log_ok "models bundle ${PARSER_MODELS_VERSION} in place."
}

# End-of-run guard against a future "returned 0 without writing the marker"
# regression in fetch_models_bundle: if the bundle was not legitimately
# skipped, the marker must exist and read the pinned version, or something is
# wrong even though nothing above caught it.
verify_models_bundle() {
    if [[ "${MODELS_SKIPPED}" == "1" ]]; then
        return 0
    fi
    if [[ -f "${MODELS_BUNDLE_MARKER}" && "$(cat "${MODELS_BUNDLE_MARKER}")" == "${PARSER_MODELS_VERSION}" ]]; then
        return 0
    fi
    log_fail "models were not skipped but ${MODELS_BUNDLE_MARKER} does not read ${PARSER_MODELS_VERSION}; this is an installer bug (fetch_models_bundle returned without writing the marker) — please report it."
}

# The ASR sidecar venv (a code dependency pinned to the parser release, not a
# model — see the DEP_ASR_VENV comment above) is switched off on its own; the
# video model weights themselves ship unconditionally with the bundle.
video_enabled() {
    [[ "${NIMO_PARSER_VIDEO:-1}" != "0" ]]
}

# The ASR sidecar runs in its own venv: its optimum-intel/transformers pins
# conflict with the main venv's (see NimoOS-Parser scripts/asr/setup_sidecar_venv.sh,
# which is the by-hand version of this function). Only site-packages is
# published; the venv itself is created here with PARSER_PY so pyvenv.cfg points
# at this machine's interpreter.
fetch_asr_venv() {
    if ! video_enabled; then
        log_info "NIMO_PARSER_VIDEO=0: skipping the ASR sidecar venv."; return
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_info "not x86_64: skipping the ASR sidecar venv."; return
    fi
    if [[ -e "${ASR_VENV_DIR}/.ready" ]]; then
        log_ok "ASR sidecar venv already in place, skipping the download."; return
    fi
    ensure_zstd || { log_warn "zstd is unavailable, skipping the ASR sidecar venv"; return; }
    local url="${NIMO_DEPS_BASE}/${DEP_ASR_VENV}"
    local tmp
    tmp="$(dl_tmp "${DL_SIZE_ESTIMATE_ASR_VENV}")" \
        || { log_warn "no download scratch directory has enough free space for the ASR sidecar; video transcription stays off."; return; }
    log_info "downloading the ASR sidecar site-packages (~455M): ${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        log_warn "could not fetch the ASR sidecar site-packages; video transcription stays off."
        rm -f "${tmp}"; return
    fi
    if ! command -v sha256sum >/dev/null 2>&1 \
        || ! echo "${DEP_ASR_VENV_SHA256}  ${tmp}" | sha256sum -c --status -; then
        log_warn "ASR sidecar site-packages checksum mismatch or sha256sum missing; video transcription stays off."
        rm -f "${tmp}"; return
    fi
    if [[ ! -x "${ASR_VENV_DIR}/bin/python" ]]; then
        log_info "creating the ASR sidecar venv at ${ASR_VENV_DIR} (interpreter: ${PARSER_PY}) ..."
        if ! ${sudo_cmd} "${PARSER_PY}" -m venv "${ASR_VENV_DIR}"; then
            log_warn "could not create the ASR sidecar venv; video transcription stays off."
            rm -f "${tmp}"; return
        fi
    fi
    local sp
    sp="$(${sudo_cmd} "${ASR_VENV_DIR}/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)"
    if [[ -z "${sp}" ]]; then
        log_warn "could not locate the ASR sidecar venv's site-packages; video transcription stays off."
        rm -f "${tmp}"; return
    fi
    # Same staged swap and import check the prebuilt main venv gets: a full
    # disk, a glibc/ABI mismatch or a repackaged tarball leaves the current
    # site-packages as it was, and a sidecar that cannot import its deps must
    # not be left looking ready.
    if ! swap_in_site_packages "${tmp}" "${sp}" "${ASR_VENV_DIR}/bin/python" \
        'optimum.intel, transformers, librosa, soundfile, silero_vad'; then
        log_warn "the ASR sidecar site-packages could not be put in place (see above); video transcription stays off."
        rm -f "${tmp}"; return
    fi
    rm -f "${tmp}"
    ${sudo_cmd} touch "${ASR_VENV_DIR}/.ready"
    log_ok "ASR sidecar venv in place (video transcription enabled)."
}

# The AMD NPU package. Same functions as lib/parser-npu-amd.sh (deploy-parser.sh
# --amd-npu-package, which also carries copies of avail_kb_of, kb_human and
# dl_tmp); kept inline because a `curl | bash` stack install bootstraps only a
# fixed list of sub-scripts, and install-parser.npu-amd.test.sh checks the
# copies are identical.

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

# Every pip invocation goes through here so the optional mirror
# (NIMO_PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple/, say) applies to all
# of them by construction. sudo scrubs the environment, so the index has to be
# an argument rather than PIP_INDEX_URL.
pip_install() {
    local args=()
    [[ -n "${NIMO_PIP_INDEX:-}" ]] && args+=(-i "${NIMO_PIP_INDEX}")
    ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${args[@]}" "$@"
}

# The pin requirements.txt carries for one distribution, so a targeted install
# below can never specify a different version than the bulk install would.
# Anchored on the exact name (openvino must not match openvino-genai), drops a
# trailing comment, and falls back to the bare name when the distribution is
# unpinned or absent.
req_spec() {
    local dist="$1" line
    line="$(grep -m1 -E "^${dist}([<>=!~[:space:]]|$)" "${INSTALL_DIR}/requirements.txt" 2>/dev/null)"
    line="${line%%#*}"
    echo "${line:-${dist}}" | tr -d '[:space:]'
}

# OpenVINO IRs on disk are useless without the runtime that loads them, and the
# prebuilt venv is a site-packages snapshot from a build machine: it can predate
# a requirements.txt that added these, which is exactly what shipped in
# v1.9.4-alpha1 — the installer fetched the Qwen3-VL IR on every Intel machine
# and then reported success while each caption died with
# `ModuleNotFoundError: No module named 'openvino_genai'` and the embedder sat on
# CPU. So top the snapshot up rather than trusting it.
#
# Keyed on the weights actually present, not on the hardware probe: the IRs also
# arrive by hand on air-gapped installs, and a machine with no IR has nothing to
# accelerate. The import probe comes first so a complete snapshot needs no
# network — the prebuilt path exists for hosts that cannot reach PyPI, and a
# missing accelerator must degrade the feature, never fail the install.
ensure_openvino_runtime() {
    local dist=""
    if vlm_ir_present; then
        dist="openvino-genai"          # captions: openvino-genai pulls openvino in
    elif text_ov_present; then
        dist="openvino"                # embedder and reranker only need the core runtime
    else
        return 0
    fi

    local probe="${dist//-/_}" spec
    spec="$(req_spec "${dist}")"
    if ${sudo_cmd} "${VENV_DIR}/bin/python" -c "import ${probe}" >/dev/null 2>&1; then
        log_ok "${dist} already present, skipping the install"
    elif pip_install "${spec}"; then
        log_ok "${spec} installed (the OpenVINO weights on disk are now loadable)."
    else
        log_warn "could not install ${spec}; the OpenVINO weights on disk cannot be loaded, so captions stay unavailable and the text backend stays on torch CPU."
    fi
}

# onnxruntime-openvino and onnxruntime share the same import path; pip happily
# installs both and whichever wrote last wins. Make the OV build deterministic.
# Intel and CPU-only machines only; see reconcile_parser_gpu_runtime.
#
# Deliberately no `pip uninstall onnxruntime` here: the plain wheel's dist-info
# is stale after the force-reinstall below (cosmetic `pip check` noise only),
# but its RECORD still lists the very same site-packages/onnxruntime/ paths the
# OV build just wrote — uninstalling by that stale RECORD deletes the OV
# build's files right back out from under it, silently corrupting a swap that
# just succeeded. Since this block reruns on every deploy, a plain-wheel stomp
# from some other requirements bump self-corrects on the next run's probe.
ensure_onnxruntime_openvino() {
    if ${sudo_cmd} "${VENV_DIR}/bin/python" -c "
import onnxruntime, sys
sys.exit(0 if 'OpenVINOExecutionProvider' in onnxruntime.get_available_providers() else 1)
" >/dev/null 2>&1; then
        log_ok "onnxruntime-openvino already active, skipping swap"
    elif pip_install --force-reinstall --no-deps "$(req_spec onnxruntime-openvino)"; then
        log_ok "onnxruntime-openvino swap complete."
    else
        log_warn "onnxruntime-openvino swap failed; OCR will run on CPU EP"
    fi
}

# Pick the ONNX Runtime, llama.cpp wheel and host Vulkan packages by GPU vendor:
# any Intel card → intel, otherwise any AMD card → amd, otherwise cpu. Every step
# degrades to CPU; none of this may fail the install. Same functions as
# lib/parser-gpu-branch.sh (deploy-parser.sh); kept inline because a `curl | bash`
# stack install bootstraps only a fixed list of sub-scripts (nimoos-stack-install.sh
# bootstrap_scripts), and install-parser.unit.test.sh checks the copies are identical.
detect_parser_gpu_branch() {
    local root="${1:-${NIMO_DRM_ROOT:-/sys/class/drm}}" f vendor branch="cpu"
    for f in "${root}"/card*/device/vendor; do
        [[ -r "${f}" ]] || continue
        vendor="$(cat "${f}" 2>/dev/null)" || continue
        case "${vendor}" in
            0x8086) echo "intel"; return 0 ;;
            0x1002) branch="amd" ;;
        esac
    done
    echo "${branch}"
}

# Packages already in place mean no apt call, and a missing one is installed with
# --no-upgrade: a deploy must not move Mesa, because a new version changes the
# self-test fingerprint and sends every model through self-test again.
ensure_amd_host_vulkan() {
    local -a pkgs=(mesa-vulkan-drivers libvulkan1 libgomp1)
    local pkg status missing=0
    for pkg in "${pkgs[@]}"; do
        status="$(dpkg-query -W -f='${db:Status-Abbrev}' "${pkg}" 2>/dev/null)" || status=""
        [[ "${status}" == ii* ]] || missing=1
    done
    if (( missing == 0 )); then
        log_ok "Mesa Vulkan driver, Vulkan loader and libgomp already installed."
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get not found; install Mesa's Vulkan driver, the Vulkan loader and libgomp by hand, or models stay on CPU."
        return 0
    fi
    if ${sudo_cmd} apt-get install -y --no-upgrade "${pkgs[@]}"; then
        log_ok "Mesa Vulkan driver, Vulkan loader and libgomp are in place."
        return 0
    fi
    # A fresh image can have stale or no package lists.
    ${sudo_cmd} apt-get update -qq || true
    if ${sudo_cmd} apt-get install -y --no-upgrade "${pkgs[@]}"; then
        log_ok "Mesa Vulkan driver, Vulkan loader and libgomp are in place."
    else
        log_warn "could not install ${pkgs[*]}; models stay on CPU."
    fi
}

# The Vulkan wheel links libgomp and libvulkan directly: without either, `import
# llama_cpp` raises RuntimeError, GGML_DISABLE_VULKAN does not help, and even the
# CPU path is gone. It also needs glibc 2.38. So the current wheel is only replaced
# once all three are confirmed. /sbin is appended because ldconfig is not on a
# normal user's PATH on Debian. The library cache goes through a variable, not a
# `| grep -q`: under pipefail an early grep exit reads as a failed pipeline.
llama_vulkan_prereqs_met() {
    local cache glibc lib
    cache="$(PATH="${PATH}:/sbin:/usr/sbin" ldconfig -p 2>/dev/null)" || cache=""
    for lib in libgomp.so.1 libvulkan.so.1; do
        if [[ "${cache}" != *"${lib} (libc6,x86-64"* ]]; then
            log_warn "${lib} is missing; keeping the CPU llama.cpp wheel (the Vulkan wheel cannot even import without it)."
            return 1
        fi
    done
    glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null)" || glibc=""
    glibc="${glibc##* }"
    if [[ ! "${glibc}" =~ ^([0-9]+)\.([0-9]+) ]] \
        || (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 38) )); then
        log_warn "glibc ${glibc:-unknown} is older than the 2.38 the Vulkan wheel needs; keeping the CPU llama.cpp wheel."
        return 1
    fi
    return 0
}

# rc 0 when the machine ends on plain onnxruntime + WebGPU, rc 1 otherwise. The two
# distributions share one directory, so both have to go before the install, which
# is why nothing is removed until the wheels are safely on disk. That includes the
# onnxruntime-openvino wheel: once the old runtime is gone the restore cannot count
# on the network, or a machine that lost it would be left with no ONNX Runtime.
amd_swap_onnxruntime() {
    local ort="onnxruntime==1.27.0" ep="onnxruntime-ep-webgpu==0.5.0" scratch
    local -a index=()
    if ${sudo_cmd} "${VENV_DIR}/bin/python" -c "
import onnxruntime, onnxruntime_ep_webgpu, sys
sys.exit(0 if onnxruntime.__version__ == '1.27.0' else 1)
" >/dev/null 2>&1; then
        log_ok "onnxruntime 1.27.0 with the WebGPU plugin already active, skipping swap"
        return 0
    fi
    if ! scratch="$(mktemp -d -p "${NIMO_DL_TMPDIR:-${TMPDIR:-/tmp}}")"; then
        log_warn "could not create a scratch directory; onnxruntime is unchanged and models stay on CPU."
        return 1
    fi
    [[ -n "${NIMO_PIP_INDEX:-}" ]] && index=(-i "${NIMO_PIP_INDEX}")
    if ! ${sudo_cmd} "${VENV_DIR}/bin/pip" download "${index[@]}" --no-deps -d "${scratch}" "${ort}" "${ep}" "$(req_spec onnxruntime-openvino)"; then
        ${sudo_cmd} rm -rf "${scratch}"
        log_warn "could not download ${ort}, ${ep} and $(req_spec onnxruntime-openvino); onnxruntime is unchanged and models stay on CPU."
        return 1
    fi
    if ! ${sudo_cmd} "${VENV_DIR}/bin/pip" uninstall -y onnxruntime-openvino onnxruntime \
        || ! pip_install --no-deps --no-index "--find-links=${scratch}" "${ort}" "${ep}"; then
        if pip_install --force-reinstall --no-deps --no-index "--find-links=${scratch}" "$(req_spec onnxruntime-openvino)"; then
            log_warn "could not install ${ort} and ${ep}; onnxruntime-openvino is back and models stay on CPU."
        else
            log_warn "could not install ${ort} and ${ep}, and could not restore onnxruntime-openvino; OCR and shot detection are unavailable until the next successful deploy."
        fi
        ${sudo_cmd} rm -rf "${scratch}"
        return 1
    fi
    ${sudo_cmd} rm -rf "${scratch}"
    log_ok "${ort} and ${ep} installed."
    return 0
}

amd_swap_llama_wheel() {
    local offload="import llama_cpp, sys; sys.exit(0 if llama_cpp.llama_supports_gpu_offload() else 1)"
    local url="${NIMO_DEPS_BASE}/${DEP_LLAMA_VULKAN_WHEEL}" scratch wheel
    if ${sudo_cmd} "${VENV_DIR}/bin/python" -c "${offload}" >/dev/null 2>&1; then
        log_ok "llama.cpp already has GPU offload, skipping the Vulkan wheel"
        return 0
    fi
    llama_vulkan_prereqs_met || return 0
    if ! scratch="$(mktemp -d -p "${NIMO_DL_TMPDIR:-${TMPDIR:-/tmp}}")"; then
        log_warn "could not create a scratch directory; keeping the CPU llama.cpp wheel."
        return 0
    fi
    wheel="${scratch}/${DEP_LLAMA_VULKAN_WHEEL##*/}"
    # The speed floor matters: a deploy runs this with the service stopped.
    if ! curl -fSL --retry 3 --connect-timeout 10 --speed-limit 1024 --speed-time 60 -o "${wheel}" "${url}"; then
        log_warn "could not download the Vulkan llama.cpp wheel from ${url}; keeping the CPU wheel."
    elif ! echo "${DEP_LLAMA_VULKAN_SHA256}  ${wheel}" | sha256sum -c --status -; then
        log_warn "the Vulkan llama.cpp wheel failed its checksum; keeping the CPU wheel."
    elif ! pip_install --force-reinstall --no-deps "${wheel}"; then
        log_warn "could not install the Vulkan llama.cpp wheel; keeping the CPU wheel."
    elif ! ${sudo_cmd} "${VENV_DIR}/bin/python" -c "import llama_cpp" >/dev/null 2>&1; then
        log_warn "the Vulkan llama.cpp wheel is installed but llama_cpp does not import, so captions do not work at all, not even on CPU; check its system libraries or reinstall $(req_spec llama-cpp-python)."
    elif ${sudo_cmd} "${VENV_DIR}/bin/python" -c "${offload}" >/dev/null 2>&1; then
        log_ok "Vulkan llama.cpp wheel installed."
    else
        log_warn "the Vulkan llama.cpp wheel is installed but reports no GPU offload (no Mesa driver?); captions run on CPU."
    fi
    ${sudo_cmd} rm -rf "${scratch}"
    return 0
}

# Idempotent, and the order is fixed: a machine whose ONNX Runtime step failed stops
# there, in a known state, and the next run retries from the top.
ensure_amd_runtime() {
    amd_swap_onnxruntime || return 0
    amd_swap_llama_wheel
    return 0
}

# Any version change is a VLM change, so what is installed has to be what
# requirements.txt says. --no-deps: only these three versions may move. A spec that
# is not an exact pin (an older Parser's requirements.txt) has nothing to enforce.
ensure_openvino_pins() {
    local dist spec have
    local -a todo=()
    for dist in openvino openvino-genai openvino-tokenizers; do
        spec="$(req_spec "${dist}")"
        [[ "${spec}" == "${dist}=="* ]] || continue
        have="$(${sudo_cmd} "${VENV_DIR}/bin/python" -c "import importlib.metadata as m; print(m.version('${dist}'))" 2>/dev/null)" || have=""
        [[ "${have}" == "${spec#*==}" ]] || todo+=("${spec}")
    done
    (( ${#todo[@]} > 0 )) || return 0
    if pip_install --no-deps "${todo[@]}"; then
        log_ok "OpenVINO pins installed: ${todo[*]}"
    else
        log_warn "could not install ${todo[*]}; captions may differ from a machine on the pinned versions."
    fi
}

reconcile_parser_gpu_runtime() {
    local branch
    branch="$(detect_parser_gpu_branch)"
    log_info "Parser GPU branch: ${branch}"
    # An exact pin marks a Parser built for the AMD stack. An older one has no
    # GGML_DISABLE_VULKAN, so under the Vulkan wheel its CPU VLM would reach a GPU
    # nothing verified: it keeps the runtime it was written for.
    if [[ "${branch}" == amd && "$(req_spec onnxruntime-openvino)" != *==* ]]; then
        log_info "this Parser pins no exact onnxruntime-openvino version; keeping onnxruntime-openvino and the CPU llama.cpp wheel on this AMD machine."
        branch="no-exact-pin"
    fi
    case "${branch}" in
        amd)
            ensure_amd_host_vulkan
            ensure_amd_runtime
            ;;
        *)
            ensure_onnxruntime_openvino
            ;;
    esac
    ensure_openvino_pins
}

setup_venv() {
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        log_info "creating the venv at ${VENV_DIR} (interpreter: ${PARSER_PY}) ..."
        ${sudo_cmd} "${PARSER_PY}" -m venv "${VENV_DIR}"
    else
        log_info "venv already exists: ${VENV_DIR}"
    fi

    # On x86_64 prefer the prebuilt venv from the mirror — it unpacks in seconds
    # and avoids the bulk pip install — then fall back to a pip install from
    # source. Either way the accelerator packages are reconciled afterwards, so
    # the two paths end up equivalent.
    local prebuilt_rc=1
    if use_prebuilt; then
        prebuilt_rc=0; fetch_prebuilt_venv || prebuilt_rc=$?
    fi
    if (( prebuilt_rc == 2 )); then
        log_fail "not enough free space on the filesystem holding ${VENV_DIR} to unpack the new venv next to the current one (see above). The current venv is unchanged and the running Parser keeps using it; free up space there and rerun. A pip install needs the same room, so it is not attempted."
    fi
    if (( prebuilt_rc != 0 )); then
        use_prebuilt && log_warn "falling back to a pip install from source (the prebuilt venv is unavailable)."
        log_info "upgrading pip ..."
        pip_install --quiet --upgrade pip
        log_info "installing the dependencies (docling, rapidocr, torch and more; the first run downloads roughly 3GB of wheels, so expect a wait) ..."
        pip_install --upgrade -r "${INSTALL_DIR}/requirements.txt"
        log_ok "Python dependencies installed."
    fi

    ensure_openvino_runtime
    reconcile_parser_gpu_runtime || log_warn "GPU runtime reconcile failed; continuing on CPU"
}

install_conf() {
    ${sudo_cmd} cp -v "${CONF_SAMPLE_SRC}" "${CONF_PATH}/${APP_NAME_SHORT}.conf.sample"
    if [[ -f "${CONF_FILE}" ]]; then
        log_info "keeping the existing configuration: ${CONF_FILE}"
    else
        log_info "initialising ${CONF_FILE} from the sample"
        ${sudo_cmd} cp -v "${CONF_SAMPLE_SRC}" "${CONF_FILE}"
    fi
}

# unit_template_delegates <template>: rc 0 when the template turns cgroup
# delegation on (the last Delegate= assignment is a true boolean or a
# controller list), rc 1 otherwise. The same rule as
# lib/parser-unit.sh's parser_unit_template_delegates (deploy-parser.sh);
# kept inline because a `curl | bash` stack install bootstraps only a fixed
# list of sub-scripts (nimoos-stack-install.sh bootstrap_scripts), and
# install-parser.unit.test.sh checks the two copies agree.
unit_template_delegates() {
    [[ -f "$1" ]] || return 1
    awk '
        /^[ \t]*[#;]/ { next }
        /^[ \t]*Delegate[ \t]*=/ {
            v = $0
            sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            last = tolower(v)
        }
        END { exit (last == "" || last == "no" || last == "false" || last == "off" || last == "0") ? 1 : 0 }
    ' "$1"
}

install_unit() {
    log_info "installing the systemd unit to ${UNIT_DST} ..."
    ${sudo_cmd} cp -v "${UNIT_SRC}" "${UNIT_DST}"
    ${sudo_cmd} systemctl daemon-reload
    log_info "enabling ${SERVICE_FILE} ..."
    ${sudo_cmd} systemctl enable --force --no-ask-password "${SERVICE_FILE}"
    # Guards against the "changed but never installed" kind of deployment drift
    # (from the 2026-07-28 OOM post-mortem): after installing, verify that the
    # cgroup memory ceiling really took effect. systemd reports infinity when the
    # unit does not set MemoryMax.
    local mem_max
    mem_max=$(${sudo_cmd} systemctl show "${SERVICE_FILE}" -p MemoryMax --value)
    if [[ -z "${mem_max}" || "${mem_max}" == "infinity" ]]; then
        log_fail "the unit's memory ceiling is not in effect (MemoryMax=${mem_max:-empty}); check ${UNIT_DST}"
    fi
    log_ok "memory ceiling in effect: MemoryMax=${mem_max}"
    # Dynamic allocation phase 2: parser moves its background children into
    # <unit>/batch so the core scheduler can squeeze them; that needs the unit
    # to delegate its cgroup (Delegate=yes + DelegateSubgroup=serve). The rule
    # follows the template, as in lib/parser-unit.sh (deploy-parser.sh): a
    # template that delegates must take effect, a template that does not (a
    # Parser release before phase 2, or a rollback to one) is not held to it.
    if unit_template_delegates "${UNIT_SRC}"; then
        local delegate
        delegate=$(${sudo_cmd} systemctl show "${SERVICE_FILE}" -p Delegate --value)
        if [[ "${delegate}" != "yes" ]]; then
            log_fail "the template delegates the unit's cgroup but systemd does not (Delegate=${delegate:-empty}); check ${UNIT_DST} and its drop-ins"
        fi
        log_ok "cgroup delegation in effect: Delegate=${delegate}"
    else
        log_info "the unit template does not delegate its cgroup (Parser before dynamic allocation phase 2); not checking Delegate"
    fi
}

maybe_start() {
    if ${sudo_cmd} systemctl is-active --quiet "${SERVICE_FILE}"; then
        # Already running (the upgrade case): it must be restarted to pick up the
        # source that was just synced. `start` is a no-op on a running service,
        # so parser would keep running the old code and miss the new routes.
        log_info "restarting ${SERVICE_FILE} to load the new code ..."
        ${sudo_cmd} systemctl restart "${SERVICE_FILE}"
        sleep 2
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    elif [[ "${START_AFTER_INSTALL}" == "1" ]]; then
        log_info "starting ${SERVICE_FILE} ..."
        ${sudo_cmd} systemctl start "${SERVICE_FILE}"
        sleep 2
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    else
        log_info "the service is enabled but not started. To bring it up now:"
        echo "    ${sudo_cmd:-sudo} systemctl start ${SERVICE_FILE}"
    fi
}

###############################################################################
# Main
###############################################################################

# The component preparer uses the existing, platform-specific setup functions
# against a private candidate. Sourcing must never install or restart anything.
if [[ "${NIMO_PARSER_LIBRARY_ONLY:-0}" == 1 ]]; then
    return 0
fi
if [[ -f /usr/share/nimoos/parser/parser/component-manifest.json && -f /usr/lib/systemd/system/nimoos-parser-prepare.service ]]; then
    log_fail "this image manages Parser components with its system slot; use the image/OTA update route so code and dependencies remain paired"
fi

component_update() {
    local engine="${SCRIPT_DIR}/lib/parser_components.py"
    local helper="${SCRIPT_DIR}/lib/parser-component-helper.sh"
    [[ -f "$engine" && -f "$helper" ]] || log_fail "this installer is missing the component update tools; no installed files were changed"
    local store="${NIMO_PARSER_STORE:-/DATA/.system_data/assets/parser-runtime}"
    local mount="${NIMO_PARSER_DATA_MOUNT:-/DATA}"
    local -a options=(update --source "$RESOLVED"
        --manifest "$RESOLVED/parser/component-manifest.json"
        --live "$INSTALL_DIR" --store "$store" --data-mount "$mount"
        --prepare-command "$helper" --deps-base "$NIMO_DEPS_BASE")
    [[ "$START_AFTER_INSTALL" == 1 ]] && options+=(--start)
    [[ "${NIMO_PARSER_CODE_ONLY:-0}" == 1 ]] && options+=(--code-only)
    [[ -n "${NIMO_PARSER_ARCHIVE_DIR:-}" ]] && options+=(--archive-dir "$NIMO_PARSER_ARCHIVE_DIR")
    ${sudo_cmd} python3 "$engine" "${options[@]}"
}

parser_install_main() {
log_info "=== NimoOS Parser Installer ==="
log_info "target: ${INSTALL_DIR}"

acquire
if [[ -f "${RESOLVED}/parser/component-manifest.json" ]]; then
    component_update
    return
fi
# The legacy path below writes into INSTALL_DIR in place. Hold the component
# engine's writer lock (the live path's sibling .<name>.update.lock) from the
# managed check to the end, so a migration that lands meanwhile is refused
# rather than overwritten through its new links.
update_lock="$(dirname "${INSTALL_DIR}")/.$(basename "${INSTALL_DIR}").update.lock"
exec 8>>"${update_lock}"
if ! flock -n 8; then
    log_info "waiting for another Parser update to finish (${update_lock}) ..."
    flock 8
fi
if [[ -L "${INSTALL_DIR}/.current" ]]; then
    log_fail "this Parser uses component updates; a payload without component-manifest.json cannot overwrite it. Use a complete compatible release or restore its recorded rollback."
fi
check_python
check_libreoffice
check_ffmpeg
check_qdrant
install_dirs
repair_ci_ownership
install_source
setup_venv
fetch_models_bundle
fetch_asr_venv
ensure_amd_npu_package || true
install_conf
install_unit
maybe_start
verify_models_bundle

echo ""
log_ok "Parser installed."
echo ""
echo "  code:      ${INSTALL_DIR}/parser/"
echo "  venv:      ${VENV_DIR}"
echo "  HF cache:  ${HF_CACHE_DIR}  (docling and BGE-M3 models live here)"
echo "  config:    ${CONF_FILE}"
echo "  data:      ${DATA_DIR}/parser.db"
echo "  logs:      journalctl -u ${SERVICE_FILE} -f"
echo "  update:    bash $(dirname "$0")/deploy-parser.sh"

}

# All payload/bootstrap scratch belongs to this invocation under a dedicated,
# locked directory. SIGKILL recovery cleans the previous owned work directory
# before acquiring a new payload; it never scans arbitrary /tmp/tmp.* files.
if (( EUID != 0 )); then
    exec sudo --preserve-env=DEPLOY_SRC_DIR,NIMO_DOWNLOAD_DOMAIN,NIMO_KEY_PREFIX,NIMO_DEPS_BASE,STACK_VERSION,STACK_VERSION_PARSER,NIMO_PARSER_STORE,NIMO_PARSER_DATA_MOUNT,NIMO_PARSER_ARCHIVE_DIR,NIMO_PARSER_CODE_ONLY,NIMO_DL_TMPDIR bash "$0" "${PARSER_INSTALL_ARGS[@]}"
fi
installer_root="${NIMO_PARSER_SCRATCH_ROOT:-/var/lib/nimoos/.parser-installer}"
[[ ! -L "$installer_root" ]] || log_fail "installer scratch root must not be a symlink"
mkdir -p -m 0700 "$installer_root"
exec 9>"$installer_root/lock"
flock -x 9
installer_work="$installer_root/work"
rm -rf -- "$installer_work"
mkdir -m 0700 "$installer_work"
parser_install_cleanup() { rm -rf -- "$installer_work"; }
trap parser_install_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export TMPDIR="$installer_work"
# Run legacy steps in a subshell: their local swap trap cannot replace the
# outer payload-cleanup trap. Managed updates keep large scratch in their store.
(parser_install_main)
