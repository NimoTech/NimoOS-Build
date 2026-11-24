#!/usr/bin/env bash
# parser-gpu-branch.sh — pick the Parser's ONNX Runtime, llama.cpp wheel and host
# Vulkan packages by GPU vendor. Sourced by deploy-parser.sh.
#
# All machines share one requirements.txt, which carries the OpenVINO stack and
# onnxruntime-openvino. Intel and CPU-only machines use exactly that. AMD machines
# replace three things on top of it, because OpenVINO has no AMD GPU path:
#   - onnxruntime-openvino → plain onnxruntime plus the WebGPU plugin
#   - the CPU llama.cpp wheel → a Vulkan build we publish on the deps mirror
#   - host packages: Mesa's Vulkan driver, the Vulkan loader and libgomp
#
# Every step degrades. A machine that cannot get the AMD stack keeps running on
# CPU with what it had; nothing here fails a deploy or an install.
#
#   detect_parser_gpu_branch [drm_root]   → intel | amd | cpu
#     Any Intel card wins, otherwise any AMD card, otherwise cpu. mlserver's image
#     choice uses the same table. drm_root defaults to $NIMO_DRM_ROOT, then
#     /sys/class/drm.
#   reconcile_parser_gpu_runtime          → runs the functions for this machine's branch;
#     an AMD machine on a Parser whose onnxruntime-openvino is not an exact pin
#     runs the intel and cpu functions
#   ensure_amd_host_vulkan                → apt-get the missing host packages (warns without apt)
#   ensure_amd_runtime                    → idempotent ONNX Runtime and wheel swap
#   ensure_onnxruntime_openvino           → the swap for intel and cpu
#   ensure_openvino_pins                  → exact OpenVINO pins, on every branch
#
# Caller provides: sudo_cmd (may be empty), VENV_DIR, INSTALL_DIR (holding
# requirements.txt). Optional: NIMO_PIP_INDEX, NIMO_DL_TMPDIR, NIMO_DEPS_BASE.
#
# install-parser.sh keeps an inline copy of these functions because a `curl | bash`
# install fetches only a fixed list of sub-scripts (nimoos-stack-install.sh
# bootstrap_scripts); install-parser.unit.test.sh checks the copies are identical.

# Built by us from llama-cpp-python 0.3.34 without dynamic backends (AVX2 + OpenMP,
# Vulkan; the build also needs spirv-headers). 160 MiB unpacked.
DEP_LLAMA_VULKAN_WHEEL="parser/llama-cpp-python-0.3.34-vulkan/llama_cpp_python-0.3.34-py3-none-linux_x86_64.whl"
DEP_LLAMA_VULKAN_SHA256="541d1688d58e6047a3154fa140829a72c238e054b3c3812b44ef16f9a07b7fbb"

# Same defaults as lib/stack-fetch.sh, which deploy-parser.sh does not load.
: "${NIMO_DOWNLOAD_DOMAIN:=https://get.nimotech.ai/}"
: "${NIMO_DEPS_BASE:=${NIMO_DOWNLOAD_DOMAIN%/}/deps}"

declare -F log_info >/dev/null || log_info() { echo "    $*"; }
declare -F log_ok   >/dev/null || log_ok()   { echo "    $*"; }
declare -F log_warn >/dev/null || log_warn() { echo "WARNING: $*" >&2; }

# Every pip install goes through here so the optional mirror applies to all of them.
pip_install() {
    local args=()
    [[ -n "${NIMO_PIP_INDEX:-}" ]] && args+=(-i "${NIMO_PIP_INDEX}")
    ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${args[@]}" "$@"
}

# The pin requirements.txt carries for one distribution. Anchored on the exact
# name (openvino must not match openvino-genai); a trailing comment is dropped;
# falls back to the bare name when the distribution is unpinned or absent.
req_spec() {
    local dist="$1" line
    line="$(grep -m1 -E "^${dist}([<>=!~[:space:]]|$)" "${INSTALL_DIR}/requirements.txt" 2>/dev/null)"
    line="${line%%#*}"
    echo "${line:-${dist}}" | tr -d '[:space:]'
}

# onnxruntime-openvino and onnxruntime share the same import path; pip happily
# installs both and whichever wrote last wins. Make the OV build deterministic.
#
# Probe first: if OpenVINOExecutionProvider is already active, the swap is a
# no-op — skip it entirely (also avoids redoing it needlessly on every deploy).
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
