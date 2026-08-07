#!/usr/bin/env bash
# nimoos-stack-install.sh — one-shot installer for the NimoOS retrieval / AI stack
#
# Calls each install-*.sh in dependency order:
#   qdrant -> parser -> search -> wiki -> photos -> ai
#
# Every sub-script is dual-mode: it builds from the matching NimoOS-* source tree
# when one is present on this machine, and otherwise downloads the release
# tarball for that version. STACK_VERSION selects the version for all of them.
#
# Usage:
#   sudo bash nimoos-stack-install.sh [options]
#
# Options:
#   --start              start the services that support it after installing
#                        (parser, search, wiki, photos)
#   --only a,b,c         install only these components (comma separated, keys below)
#   --skip a,b           skip these components
#   --version <ver>      version to install, passed through to every sub-script
#   --continue           keep going after a component fails (default: stop)
#   -h | --help          show this help
#
# Component keys: qdrant parser search wiki photos ai
#
# Notes:
#   - qdrant underpins the retrieval stack; parser and search need it up first.
#   - ai installs Ollama plus the Python agent. Afterwards run
#     `ollama pull <model>` and then start-ai.sh.
#   - photos installs only the main binary; its AI/ML backend is a separate step.

set -uo pipefail

# BASH_SOURCE is empty when this runs from stdin via `curl | bash -s`, which
# trips set -u. Fall back to $0. In that case there are no sibling scripts on
# disk either, so bootstrap_scripts downloads them below.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/tmp")"

((EUID)) && sudo_hint="(running with sudo is recommended)" || sudo_hint=""

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
START=0
CONTINUE=0
ONLY=""
SKIP=""
# Deliberately not defaulted here. lib/stack-fetch.sh resolves the version from
# release/versions.conf, which is the single source of truth; a second default in
# this file went stale by four releases before anyone noticed. Only export when
# the caller actually asked for a specific version.
[ -n "${STACK_VERSION:-}" ] && export STACK_VERSION

usage() { sed -n '2,30p' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)     START=1; shift ;;
        --continue)  CONTINUE=1; shift ;;
        --only)      ONLY="$2"; shift 2 ;;
        --only=*)    ONLY="${1#*=}"; shift ;;
        --skip)      SKIP="$2"; shift 2 ;;
        --skip=*)    SKIP="${1#*=}"; shift ;;
        --version)   export STACK_VERSION="$2"; shift 2 ;;
        --version=*) export STACK_VERSION="${1#*=}"; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "unknown argument: $1 (see --help)"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
C_RESET='\e[0m'; C_GREEN='\e[32m'; C_YELLOW='\e[33m'; C_RED='\e[31m'; C_CYAN='\e[36m'
log_info() { echo -e "${C_GREEN}[ INFO ]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*"; }
log_err()  { echo -e "${C_RED}[FAILED]${C_RESET} $*"; }
log_step() { echo -e "\n${C_CYAN}========== $* ==========${C_RESET}"; }

# Send stdout and stderr to both the terminal and a log file, so a failed install
# can be investigated afterwards. This used to be silent, which left nothing
# behind when a component hung or errored out.
STACK_LOG=""
setup_logging() {
    local ts dir
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
    dir="/var/log/nimoos"
    mkdir -p "${dir}" 2>/dev/null || dir="${TMPDIR:-/tmp}"
    STACK_LOG="${dir}/stack-install-${ts}.log"
    exec > >(tee -a "${STACK_LOG}") 2>&1
    log_info "full install log: ${STACK_LOG}"
}

# ---------------------------------------------------------------------------
# Components, in dependency order: key|script|supports --start|description
# ---------------------------------------------------------------------------
COMPONENTS=(
    "qdrant|install-qdrant.sh|0|qdrant vector database (foundation of the retrieval stack)"
    "parser|install-parser.sh|1|document parser (Python, needs qdrant)"
    "search|install-search.sh|1|search service (needs parser and qdrant)"
    "wiki|install-wiki.sh|1|wiki service"
    "photos|install-photos.sh|1|photos main service"
    "ai|install-ai.sh|0|Ollama plus the Python agent"
)

in_csv() { # in_csv <needle> <csv>
    local needle="$1" csv="$2" item
    IFS=',' read -ra _arr <<< "${csv}"
    for item in "${_arr[@]}"; do [[ "${item}" == "${needle}" ]] && return 0; done
    return 1
}

selected() { # selected <key>
    local key="$1"
    [[ -n "${ONLY}" ]] && { in_csv "${key}" "${ONLY}" || return 1; }
    [[ -n "${SKIP}" ]] && { in_csv "${key}" "${SKIP}" && return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Bootstrap: run standalone via `curl | bash` there are no sibling scripts on
# disk, so fetch them from the download mirror.
# ---------------------------------------------------------------------------
: "${NIMO_SCRIPTS_BASE:=https://get.nimotech.ai/get/scripts}"
bootstrap_scripts() {
    [[ -f "${SCRIPT_DIR}/install-qdrant.sh" && -f "${SCRIPT_DIR}/lib/stack-fetch.sh" ]] && return 0
    local boot; boot="$(mktemp -d)"
    mkdir -p "${boot}/lib"
    log_info "no local sub-scripts found, downloading from ${NIMO_SCRIPTS_BASE} ..."
    local f
    for f in lib/stack-fetch.sh install-qdrant.sh install-parser.sh install-search.sh \
             install-wiki.sh install-photos.sh install-ai.sh start-ai.sh; do
        if ! curl -fsSL "${NIMO_SCRIPTS_BASE}/${f}" -o "${boot}/${f}"; then
            log_err "could not download the sub-script: ${f}"; rm -rf "${boot}"; exit 1
        fi
    done
    SCRIPT_DIR="${boot}"
    log_info "sub-scripts ready: ${SCRIPT_DIR}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
setup_logging
bootstrap_scripts
log_step "NimoOS stack install  ${sudo_hint}"
log_info "version: ${STACK_VERSION:-(from release/versions.conf)}   start=${START}  continue=${CONTINUE}"
[[ -n "${ONLY}" ]] && log_info "installing only: ${ONLY}"
[[ -n "${SKIP}" ]] && log_info "skipping:        ${SKIP}"

declare -a DONE=() FAILED=() SKIPPED=()

for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r key script supports_start desc <<< "${entry}"
    if ! selected "${key}"; then
        SKIPPED+=("${key}")
        continue
    fi
    local_script="${SCRIPT_DIR}/${script}"
    if [[ ! -f "${local_script}" ]]; then
        log_err "${key}: script not found at ${local_script}"
        FAILED+=("${key}")
        [[ "${CONTINUE}" == "1" ]] && continue || { log_err "stopping (pass --continue to carry on past failures)"; break; }
    fi

    # Assemble the sub-script arguments
    args=()
    [[ "${START}" == "1" && "${supports_start}" == "1" ]] && args+=("--start")

    log_step "[${key}] ${desc}"
    if bash "${local_script}" "${args[@]}"; then
        DONE+=("${key}")
    else
        log_err "${key} failed to install (exit=$?)"
        FAILED+=("${key}")
        if [[ "${CONTINUE}" != "1" ]]; then
            log_err "stopping the remaining installs (pass --continue to carry on past failures)"
            break
        fi
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_step "Summary"
log_info "installed: ${DONE[*]:-(none)}"
[[ ${#SKIPPED[@]} -gt 0 ]] && log_warn "skipped:   ${SKIPPED[*]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    log_err "failed:    ${FAILED[*]}"
    echo ""
    echo "  to investigate: journalctl -u <service> -f"
    echo "  to retry one:   bash ${SCRIPT_DIR}/install-<key>.sh"
    [[ -n "${STACK_LOG}" ]] && echo "  full log:       ${STACK_LOG}"
    exit 1
fi

echo ""
log_info "All done. Next steps:"
echo "  - AI:        ollama pull qwen2.5:7b  &&  sudo bash ${SCRIPT_DIR}/start-ai.sh"
echo "  - retrieval: confirm qdrant is running on 127.0.0.1:6333, then"
echo "               systemctl start nimoos-parser nimoos-search"
echo "  - the Photos AI/ML backend is a separate step, not covered here."
