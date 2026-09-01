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
#
# Usage: sudo bash install-parser.sh [--start]
#
# By default the service is enabled but not started; pass --start to bring it up
# immediately. Use deploy-parser.sh for subsequent code updates.

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

START_AFTER_INSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start) START_AFTER_INSTALL=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
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
readonly PARSER_SRC_DEFAULT="$(cd "${SCRIPT_DIR}/../../NimoOS-Parser" 2>/dev/null && pwd || true)"

# Filled in by acquire()
RESOLVED=""; MODE=""; SYSROOT=""; UNIT_SRC=""; CONF_SAMPLE_SRC=""

readonly INSTALL_DIR="/opt/nimoos-parser"
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
#   NIMO_PARSER_BUILD=1   force a pip install from source, ignoring the prebuilt venv
#   NIMO_PARSER_MODELS=0  skip the model download; parser fetches from HF on first run
#   NIMO_PARSER_VLM=0     skip the caption (Qwen3-VL) model download
#   NIMO_PARSER_OV=0/1    skip / force the OpenVINO text-model IR download
#                         (default: auto — only when an Intel GPU is detected)
readonly DEP_VENV="parser/parser-venv-${VERSION}-cp311-linux-x86_64.tar.zst"
readonly DEP_HFCACHE="parser/hf-cache.tar.zst"
readonly DEP_VLM="parser/qwen3-vl-4b-gguf.tar.zst"
readonly DEP_TEXT_OV="parser/bge-text-ov-fp16.tar.zst"
# sha256 of the published bge-text-ov package; bump together with the artifact.
readonly DEP_TEXT_OV_SHA256="9e58b1e1a6f588983a0d04f754be7e426761288a245e1d957b0af8fca2631039"
# Holds the caption (Qwen3-VL) weights and, on Intel GPU machines, the
# OpenVINO text IRs (bge-m3-ov/, bge-reranker-v2-m3-ov/).
readonly VLM_MODELS_DIR="${INSTALL_DIR}/models"

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

install_source() {
    log_info "syncing the parser package to ${INSTALL_DIR}/parser/ ..."
    if command -v rsync &>/dev/null; then
        ${sudo_cmd} rsync -a --delete \
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

# Download and unpack the prebuilt venv's site-packages. Returns 0 on success;
# any other status tells the caller to fall back to pip.
fetch_prebuilt_venv() {
    ensure_zstd || { log_warn "zstd is unavailable, cannot use the prebuilt venv"; return 1; }
    local url="${NIMO_DEPS_BASE}/${DEP_VENV}"
    local tmp; tmp="$(mktemp)"
    log_info "downloading the prebuilt venv: ${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"; log_warn "prebuilt venv download failed (this version may not publish one)"; return 1
    fi
    local sp="${VENV_DIR}/lib/python3.11/site-packages"
    log_info "unpacking site-packages into ${sp} ..."
    ${sudo_cmd} rm -rf "${sp}" && ${sudo_cmd} mkdir -p "${sp}" || return 1
    if ! ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${sp}"; then
        rm -f "${tmp}"; log_warn "could not unpack the prebuilt venv"; return 1
    fi
    rm -f "${tmp}"
    # Smoke test: can the key compiled extensions be imported by this machine's
    # interpreter? A glibc or ABI mismatch shows up here, and we fall back.
    if ! ${sudo_cmd} "${VENV_DIR}/bin/python" -c 'import torch, onnxruntime, uvicorn' >/dev/null 2>&1; then
        log_warn "the prebuilt venv failed its import check (glibc/ABI mismatch?), falling back to pip"; return 1
    fi
    log_ok "prebuilt venv in place (pip skipped)."
}

# Download and unpack the prebuilt models into hf-cache (bge-m3, reranker, docling).
fetch_models() {
    if [[ "${NIMO_PARSER_MODELS:-1}" == "0" ]]; then
        log_info "NIMO_PARSER_MODELS=0: skipping the model download; parser will fetch from HF on first run."; return
    fi
    if ! use_prebuilt; then
        log_info "not x86_64, or building from source: parser will download the models from HF on first run."; return
    fi
    if [[ -d "${HF_CACHE_DIR}/hub" ]]; then
        log_ok "hf-cache already holds the models, skipping the download."; return
    fi
    ensure_zstd || { log_warn "zstd is unavailable, skipping the prebuilt models"; return; }
    local url="${NIMO_DEPS_BASE}/${DEP_HFCACHE}"
    local tmp; tmp="$(mktemp)"
    log_info "downloading the prebuilt hf-cache (~7G unpacked): ${url} ..."
    if ${sudo_cmd} mkdir -p "${HF_CACHE_DIR}" \
        && curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}" \
        && ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${HF_CACHE_DIR}"; then
        log_ok "models in place (HF download skipped)."
    else
        log_warn "could not fetch the prebuilt models; parser will try Hugging Face on first run, which may be slow or blocked."
    fi
    rm -f "${tmp}"
}

# Download and unpack the Qwen3-VL caption weights (photo captions). Only the
# GGUF form is shipped: it is pure data that llama.cpp can serve on any
# hardware, CPU included — parser's backendselect picks candidates by which
# weight form is actually on disk. The OpenVINO IR form is an on-machine
# conversion for Intel GPUs (NimoOS-Parser scripts/vlm/README.md), never a
# download. Non-fatal by design: without the weights the parser runs fine,
# photo captions just stay off.
fetch_vlm_model() {
    if [[ "${NIMO_PARSER_VLM:-1}" == "0" ]]; then
        log_info "NIMO_PARSER_VLM=0: skipping the caption model download."; return
    fi
    if [[ -f "${VLM_MODELS_DIR}/qwen3-vl-4b-gguf/model.gguf" \
       && -f "${VLM_MODELS_DIR}/qwen3-vl-4b-gguf/mmproj.gguf" ]]; then
        log_ok "caption model already in place, skipping the download."; return
    fi
    ensure_zstd || { log_warn "zstd is unavailable, skipping the caption model"; return; }
    local url="${NIMO_DEPS_BASE}/${DEP_VLM}"
    local tmp; tmp="$(mktemp)"
    log_info "downloading the Qwen3-VL caption model (~3G): ${url} ..."
    if ${sudo_cmd} mkdir -p "${VLM_MODELS_DIR}" \
        && curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}" \
        && ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${VLM_MODELS_DIR}"; then
        log_ok "caption model in place."
    else
        log_warn "could not fetch the caption model; photo captions stay off until ${VLM_MODELS_DIR}/qwen3-vl-4b-gguf/ is provisioned."
    fi
    rm -f "${tmp}"
}

# Intel GPU (OpenVINO-capable) present? Vendor 0x8086 on any DRM render node
# is the cheapest reliable install-time signal; the parser re-probes at
# runtime and falls back to torch CPU on its own either way.
has_intel_gpu() {
    local v
    for v in /sys/class/drm/renderD*/device/vendor; do
        [[ -r "${v}" ]] && grep -qi '0x8086' "${v}" && return 0
    done
    return 1
}

# Download and unpack the OpenVINO IR weights for the text pipeline (bge-m3
# embedding incl. its sparse head, bge-reranker-v2-m3 reranker). Only useful
# on Intel GPU machines; without the IR the parser's text backend stays on
# torch CPU, so every failure here is a warning, never a stop.
fetch_text_ov_models() {
    if [[ "${NIMO_PARSER_OV:-auto}" == "0" ]]; then
        log_info "NIMO_PARSER_OV=0: skipping the OpenVINO text models."; return
    fi
    if ! use_prebuilt; then
        log_info "not x86_64, or building from source: skipping the OpenVINO text models."; return
    fi
    if [[ "${NIMO_PARSER_OV:-auto}" != "1" ]] && ! has_intel_gpu; then
        log_info "no Intel GPU detected: skipping the OpenVINO text models (NIMO_PARSER_OV=1 forces the download)."; return
    fi
    if [[ -f "${VLM_MODELS_DIR}/bge-m3-ov/openvino_model.xml" \
       && -f "${VLM_MODELS_DIR}/bge-reranker-v2-m3-ov/openvino_model.xml" ]]; then
        log_ok "OpenVINO text models already in place, skipping the download."; return
    fi
    ensure_zstd || { log_warn "zstd is unavailable, skipping the OpenVINO text models"; return; }
    local url="${NIMO_DEPS_BASE}/${DEP_TEXT_OV}"
    local tmp; tmp="$(mktemp)"
    log_info "downloading the OpenVINO text models (~2G): ${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        log_warn "could not fetch the OpenVINO text models; the parser stays on torch CPU until ${VLM_MODELS_DIR}/bge-m3-ov/ is provisioned."
        rm -f "${tmp}"; return
    fi
    if ! echo "${DEP_TEXT_OV_SHA256}  ${tmp}" | sha256sum -c --status -; then
        log_warn "OpenVINO text models checksum mismatch (stale CDN copy?); skipping — the parser stays on torch CPU."
        rm -f "${tmp}"; return
    fi
    if ${sudo_cmd} mkdir -p "${VLM_MODELS_DIR}" \
        && ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${VLM_MODELS_DIR}"; then
        log_ok "OpenVINO text models in place (GPU text backend enabled)."
    else
        log_warn "could not unpack the OpenVINO text models; the parser stays on torch CPU."
    fi
    rm -f "${tmp}"
}

setup_venv() {
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        log_info "creating the venv at ${VENV_DIR} (interpreter: ${PARSER_PY}) ..."
        ${sudo_cmd} "${PARSER_PY}" -m venv "${VENV_DIR}"
    else
        log_info "venv already exists: ${VENV_DIR}"
    fi

    # On x86_64 prefer the prebuilt venv from the mirror — it unpacks in seconds
    # and avoids pip entirely — then fall back to a pip install from source.
    if use_prebuilt && fetch_prebuilt_venv; then
        return
    fi
    use_prebuilt && log_warn "falling back to a pip install from source (the prebuilt venv is unavailable)."

    # Optional pip mirror, e.g. NIMO_PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple/.
    # sudo scrubs the environment, so pass it as an argument rather than relying
    # on PIP_INDEX_URL.
    local pip_args=()
    [[ -n "${NIMO_PIP_INDEX:-}" ]] && pip_args+=(-i "${NIMO_PIP_INDEX}")
    log_info "upgrading pip ..."
    ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${pip_args[@]}" --quiet --upgrade pip
    log_info "installing the dependencies (docling, rapidocr, torch and more; the first run downloads roughly 3GB of wheels, so expect a wait) ..."
    ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${pip_args[@]}" --upgrade -r "${INSTALL_DIR}/requirements.txt"
    log_ok "Python dependencies installed."

    # onnxruntime-openvino and onnxruntime share the same import path; pip happily
    # installs both and whichever wrote last wins. Make the OV build deterministic
    # (mirrors deploy-parser.sh's swap logic).
    if ${sudo_cmd} "${VENV_DIR}/bin/python" -c "
import onnxruntime, sys
sys.exit(0 if 'OpenVINOExecutionProvider' in onnxruntime.get_available_providers() else 1)
" >/dev/null 2>&1; then
        log_ok "onnxruntime-openvino already active, skipping swap"
    else
        # Never uninstall before the replacement is confirmed installed: a network
        # failure here must not leave the venv with NO onnxruntime module at all.
        # --force-reinstall --no-deps overwrites the plain wheel's files in place
        # (its RECORD becomes stale, a known cosmetic cost) without ever removing
        # the module, so install-then-uninstall is safe in either order of success.
        if ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${pip_args[@]}" --force-reinstall --no-deps "onnxruntime-openvino>=1.24.1"; then
            ${sudo_cmd} "${VENV_DIR}/bin/pip" uninstall -y onnxruntime >/dev/null 2>&1 || true
            log_ok "onnxruntime-openvino swap complete."
        else
            log_warn "onnxruntime-openvino swap failed; OCR will run on CPU EP"
        fi
    fi
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

log_info "=== NimoOS Parser Installer ==="
log_info "target: ${INSTALL_DIR}"

acquire
check_python
check_libreoffice
check_qdrant
install_dirs
install_source
setup_venv
fetch_models
fetch_vlm_model
fetch_text_ov_models
install_conf
install_unit
maybe_start

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
