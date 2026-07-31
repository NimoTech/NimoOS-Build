#!/usr/bin/bash
#
#           NimoOS Update Script v0.4.17
#   GitHub: https://github.com/NimoTech/NimoOS
#   Issues: https://github.com/NimoTech/NimoOS/issues
#   Requires: bash, curl/wget, tar, systemd
#
#   Upgrade an ALREADY INSTALLED NimoOS to a given version:
#     - core:  fetch each component's release tar, stop services, overlay the
#              sysroot, run migration/setup scripts, daemon-reload, restart.
#     - stack: call nimoos-stack-install.sh to refresh qdrant/parser/agent/
#              ollama and models idempotently; existing models and venvs are
#              reused rather than downloaded again.
#
#   Unlike install, this does NOT install Docker or system dependencies and
#   performs no interactive checks. It only swaps binaries, frontend and
#   configuration for a newer version and restarts.
#
#   Usage:
#     curl -fsSL https://nimoos-public.s3.us-east-2.amazonaws.com/get/nimoos-update.sh | sudo bash
#       core only, skip the heavy stack:
#     curl -fsSL .../get/nimoos-update.sh | sudo NIMO_SKIP_STACK=1 bash
#       pick a version / stack only:
#     sudo bash nimoos-update.sh --version v1.9.1-alpha1
#     sudo bash nimoos-update.sh --only-stack
#
clear
echo -e "\e[0m\c"

export PATH=/usr/sbin:$PATH
export DEBIAN_FRONTEND=noninteractive

set -e

###############################################################################
# GLOBALS                                                                     #
###############################################################################

((EUID)) && sudo_cmd="sudo"

UNAME_M="$(uname -m)"
readonly UNAME_M
UNAME_U="$(uname -s)"
readonly UNAME_U

TARGET_ARCH=""
TMP_ROOT=/tmp/nimoos-updater
NIMO_DOWNLOAD_DOMAIN="https://nimoos-public.s3.us-east-2.amazonaws.com/"

# Version, overridable via --version or the environment. AppStore has its own line.
NIMO_UPDATE_VERSION="${NIMO_UPDATE_VERSION:-v1.9.4-alpha1}"
NIMO_APPSTORE_VERSION="${NIMO_APPSTORE_VERSION:-v1.0.9}"

# Update scope
DO_CORE=1
DO_STACK=1

# COLORS
readonly COLOUR_RESET='\e[0m'
readonly aCOLOUR=(
    '\e[38;5;154m' # green
    '\e[1m'        # bold white
    '\e[90m'       # grey
    '\e[91m'       # red
    '\e[33m'       # yellow
)

trap 'onCtrlC' INT
onCtrlC() { echo -e "${COLOUR_RESET}"; exit 1; }

# $1 0:OK 1:FAILED 2:INFO 3:NOTICE ; $2 message
Show() {
    if (($1 == 0)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[0]}  OK  $COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
    elif (($1 == 1)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[3]}FAILED$COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
        exit 1
    elif (($1 == 2)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[0]} INFO $COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
    elif (($1 == 3)); then
        echo -e "${aCOLOUR[2]}[$COLOUR_RESET${aCOLOUR[4]}NOTICE$COLOUR_RESET${aCOLOUR[2]}]$COLOUR_RESET $2"
    fi
}

GreyStart() { echo -e "${aCOLOUR[2]}\c"; }
ColorReset() { echo -e "$COLOUR_RESET\c"; }

usage() {
    sed -n '2,33p' "$0"
    exit "${1:-0}"
}

###############################################################################
# Args                                                                        #
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    NIMO_UPDATE_VERSION="$2"; shift 2 ;;
        --version=*)  NIMO_UPDATE_VERSION="${1#*=}"; shift ;;
        --only-core)  DO_STACK=0; shift ;;
        --only-stack) DO_CORE=0; shift ;;
        --skip-stack) DO_STACK=0; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown argument: $1 (see --help)"; exit 1 ;;
    esac
done
# Accept the same environment switches as the install scripts
[[ "${NIMO_SKIP_STACK:-0}" == "1" ]] && DO_STACK=0

###############################################################################
# Core update                                                                 #
###############################################################################

# Package order must match NIMO_PACKAGES in nimoos-install.sh: the nimoos core
# goes last so a UI-triggered update still works.
# Fields: project|tar token|arch_mode(arch/all)
core_components() {
    cat <<'EOF'
NimoOS-Gateway|nimoos-gateway|arch
NimoOS-MessageBus|nimoos-message-bus|arch
NimoOS-UserService|nimoos-user-service|arch
NimoOS-LocalStorage|nimoos-local-storage|arch
NimoOS-AppManagement|nimoos-app-management|arch
NimoOS-CLI|nimoos-cli|arch
NimoOS-UI|nimoos|all
NimoOS-AppStore|appstore|all
NimoOS-AI|nimoos-ai|arch
NimoOS-Wiki|nimoos-wiki|arch
NimoOS-Search|nimoos-search|arch
NimoOS-Photos|nimoos-photos|arch
NimoOS-Terminal|nimoos-terminal|arch
NimoOS|nimoos|arch
EOF
}

# Ensure the terminal component's dependencies are present. Idempotent.
# tmux comes from apt; ttyd is fetched per architecture (mirror first, GitHub
# as a fallback) into /usr/lib/nimoos/ttyd.
Ensure_Terminal_Deps() {
    if ! command -v tmux >/dev/null 2>&1; then
        Show 2 "installing tmux (terminal dependency)..."
        ${sudo_cmd} apt-get install -y tmux || Show 3 "tmux install failed; the terminal will be degraded."
    fi
    if [ ! -x /usr/lib/nimoos/ttyd ]; then
        local ttyd_ver="1.7.7" ttyd_asset=""
        case "${UNAME_M}" in
            *aarch64*) ttyd_asset="ttyd.aarch64" ;;
            *64*)      ttyd_asset="ttyd.x86_64" ;;
            *armv7*)   ttyd_asset="ttyd.arm" ;;
            *) Show 3 "unsupported architecture ${UNAME_M}; skipping ttyd, the terminal will be degraded." ;;
        esac
        if [ -n "${ttyd_asset}" ]; then
            local ttyd_gh="https://github.com/tsl0922/ttyd/releases/download/${ttyd_ver}/${ttyd_asset}"
            local ttyd_primary="${NIMO_DOWNLOAD_DOMAIN}ttyd/${ttyd_ver}/${ttyd_asset}"
            ${sudo_cmd} mkdir -p /usr/lib/nimoos
            Show 2 "fetching ttyd ${ttyd_ver} (${ttyd_asset})..."
            if ${sudo_cmd} curl -fsSL --connect-timeout 20 -o /usr/lib/nimoos/ttyd "${ttyd_primary}" 2>/dev/null \
               || ${sudo_cmd} curl -fsSL --connect-timeout 20 -o /usr/lib/nimoos/ttyd "${ttyd_gh}"; then
                ${sudo_cmd} chmod 755 /usr/lib/nimoos/ttyd
            else
                Show 3 "ttyd fetch failed; the terminal will be degraded."
            fi
        fi
    fi
}

# Restart order must match install: the nimoos core last
NIMO_SERVICES=(
    "nimoos-gateway.service"
    "nimoos-message-bus.service"
    "nimoos-user-service.service"
    "nimoos-local-storage.service"
    "nimoos-app-management.service"
    "nimoos-ai.service"
    "nimoos-wiki.service"
    "nimoos-search.service"
    "nimoos-photos.service"
    "nimoos-terminal.service"
    # nimoos-agent is a Docker container rather than a systemd service; the
    # stack stage restarts it, so it is deliberately absent here.
    "nimoos.service"
)

Check_Arch() {
    case $UNAME_M in
    *aarch64*) TARGET_ARCH="arm64" ;;
    *64*)      TARGET_ARCH="amd64" ;;
    *armv7*)   TARGET_ARCH="arm-7" ;;
    *) Show 1 "Aborted, unsupported or unknown architecture: $UNAME_M" ;;
    esac
    Show 0 "Architecture: ${UNAME_M} (${TARGET_ARCH})"
}

# Build the download URL for one component
core_pkg_url() {
    local project="$1" token="$2" archmode="$3"
    local ver arch
    if [ "${token}" = "appstore" ]; then ver="${NIMO_APPSTORE_VERSION}"; else ver="${NIMO_UPDATE_VERSION}"; fi
    if [ "${archmode}" = "all" ]; then arch="all"; else arch="${TARGET_ARCH}"; fi
    echo "${NIMO_DOWNLOAD_DOMAIN}NimoTech/${project}/releases/download/${ver}/linux-${arch}-${token}-${ver}.tar.gz"
}

Update_Core() {
    Show 2 "updating core components to ${NIMO_UPDATE_VERSION} (AppStore ${NIMO_APPSTORE_VERSION})"
    ${sudo_cmd} rm -rf "${TMP_ROOT}"
    ${sudo_cmd} mkdir -p "${TMP_ROOT}"
    local TMP_DIR
    TMP_DIR=$(${sudo_cmd} mktemp -d -p "${TMP_ROOT}") || Show 1 "cannot create a temporary directory"

    # 1) download every core package
    local line project token archmode url
    while IFS='|' read -r project token archmode; do
        [ -n "${project}" ] || continue
        url="$(core_pkg_url "${project}" "${token}" "${archmode}")"
        # Keep the URL's real filename, which is already unique. Using
        # linux-${token}.tar.gz breaks: UI and core share the token "nimoos" and
        # would collide, and with wget -c the smaller core would be skipped as
        # 'already present and larger', silently leaving the core un-updated.
        local fname; fname="$(basename "${url}")"
        Show 2 "downloading ${url}"
        GreyStart
        ${sudo_cmd} wget -t 3 -q --show-progress -O "${TMP_DIR}/${fname}" "${url}" \
            || Show 1 "download failed: ${url}"
        ColorReset
    done < <(core_components)

    # 2) unpack
    pushd "${TMP_DIR}" >/dev/null
    local f
    for f in linux-*.tar.gz; do
        Show 2 "unpacking ${f}..."
        GreyStart
        ${sudo_cmd} tar zxf "${f}" || Show 1 "unpack failed: ${f}"
        ColorReset
    done
    popd >/dev/null

    local BUILD_DIR
    BUILD_DIR=$(${sudo_cmd} realpath -e "${TMP_DIR}/build") || Show 1 "build directory not found"

    # 3) stop the running core services
    local SERVICE
    for SERVICE in "${NIMO_SERVICES[@]}"; do
        if ${sudo_cmd} systemctl --quiet is-active "${SERVICE}" 2>/dev/null; then
            Show 2 "stopping ${SERVICE}..."
            ${sudo_cmd} systemctl stop "${SERVICE}" || Show 3 "${SERVICE} not present (ignored)."
        fi
    done

    # 4) migration scripts (data and schema changes between versions)
    local MIGRATION_SCRIPT_DIR="${BUILD_DIR}/scripts/migration/script.d"
    if [ -d "${MIGRATION_SCRIPT_DIR}" ]; then
        local MIGRATION_SCRIPT
        for MIGRATION_SCRIPT in "${MIGRATION_SCRIPT_DIR}"/*.sh; do
            if [ -f "${MIGRATION_SCRIPT}" ]; then
                chmod +x "${MIGRATION_SCRIPT}"
                Show 2 "running migration ${MIGRATION_SCRIPT}..."
                ${sudo_cmd} "${MIGRATION_SCRIPT}" || Show 1 "migration failed: ${MIGRATION_SCRIPT}"
            fi
        done
    fi

    # 5) overlay the sysroot onto /
    local SYSROOT_DIR
    SYSROOT_DIR=$(realpath -e "${BUILD_DIR}/sysroot") || Show 1 "sysroot directory not found"
    Show 2 "installing the new files..."
    GreyStart
    # Use tar rather than cp: on usrmerge systems /lib and /bin are symlinks
    # into /usr/*, so cp -rf fails trying to replace a symlink with a
    # directory; --keep-directory-symlink follows them instead.
    ${sudo_cmd} tar -cf - -C "${SYSROOT_DIR}" . | ${sudo_cmd} tar -C / --keep-directory-symlink -xf - \
        || Show 1 "install failed"
    ${sudo_cmd} systemctl daemon-reload || Show 3 "daemon-reload failed (ignored)."
    ColorReset

    # 6) setup scripts, once the files are in place
    local SETUP_SCRIPT_DIR="${BUILD_DIR}/scripts/setup/script.d"
    if [ -d "${SETUP_SCRIPT_DIR}" ]; then
        local SETUP_SCRIPT
        for SETUP_SCRIPT in "${SETUP_SCRIPT_DIR}"/*.sh; do
            if [ -f "${SETUP_SCRIPT}" ]; then
                chmod +x "${SETUP_SCRIPT}"
                Show 2 "running ${SETUP_SCRIPT}..."
                ${sudo_cmd} "${SETUP_SCRIPT}" || Show 1 "failed: ${SETUP_SCRIPT}"
            fi
        done
    fi

    # 7) service.d is deliberately not walked separately. The script.d
    #    dispatcher in step 6 already picks the right OS variant from
    #    /etc/os-release. Walking all of service.d would run every service's
    #    debian/arch/ubuntu variant, including Arch scripts on Debian, and
    #    would re-download the ~443MB Photos ML bundle.

    # 7.5) ensure the terminal dependencies exist, for updates that introduce
    #      the terminal component
    Ensure_Terminal_Deps

    # 8) enable and restart the core services
    for SERVICE in "${NIMO_SERVICES[@]}"; do
        ${sudo_cmd} systemctl enable "${SERVICE}" 2>/dev/null || true
        Show 2 "starting ${SERVICE}..."
        ${sudo_cmd} systemctl start "${SERVICE}" 2>/dev/null || Show 3 "${SERVICE} not present (ignored)."
    done

    # 9) clean up
    ${sudo_cmd} rm -rf "${TMP_DIR}"
    Show 0 "core update complete."
}

###############################################################################
# Stack update (qdrant / parser / search / wiki / photos / ai)                #
###############################################################################
Update_Stack() {
    Show 2 "updating the retrieval and AI stack (qdrant/parser/search/wiki/photos/ai)"
    Show 3 "  (idempotent: existing models and venvs are reused, saving ~3GB)"
    local SCRIPT_DIR stack_sh
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/tmp")"

    # Prefer a sibling script (development tree or unpacked directory);
    # otherwise fetch it from get/
    if [ -f "${SCRIPT_DIR}/scripts/nimoos-stack-install.sh" ]; then
        stack_sh="${SCRIPT_DIR}/scripts/nimoos-stack-install.sh"
    elif [ -f "${SCRIPT_DIR}/nimoos-stack-install.sh" ]; then
        stack_sh="${SCRIPT_DIR}/nimoos-stack-install.sh"
    else
        stack_sh="${TMP_ROOT}/nimoos-stack-install.sh"
        ${sudo_cmd} mkdir -p "${TMP_ROOT}"
        if ! ${sudo_cmd} curl -fsSL "${NIMO_DOWNLOAD_DOMAIN}get/nimoos-stack-install.sh" -o "${stack_sh}"; then
            Show 3 "could not download the stack installer; skipping the stack (core is updated)."
            return
        fi
    fi

    # Pass the version through and keep going on error: a stack failure is not
    # fatal because the core is already updated.
    # Do NOT write `${sudo_cmd} STACK_VERSION=val bash ...`: when sudo_cmd is
    # empty (running as root) bash treats VAR=val as the command name and fails
    # with 'command not found'. --version already exports STACK_VERSION inside
    # the stack script.
    if ${sudo_cmd} bash "${stack_sh}" --version "${NIMO_UPDATE_VERSION}" --start --continue; then
        Show 0 "stack update complete."
    else
        Show 3 "the stack update reported errors (non-fatal); the core is updated."
    fi
}

###############################################################################
# Main                                                                        #
###############################################################################
echo '
░███    ░██ ░██                             ░██████     ░██████
░████   ░██                                ░██   ░██   ░██   ░██
░██░██  ░██ ░██░█████████████   ░███████  ░██     ░██ ░██
░██ ░██ ░██ ░██░██   ░██   ░██ ░██    ░██ ░██     ░██  ░████████
░██  ░██░██ ░██░██   ░██   ░██ ░██    ░██ ░██     ░██         ░██
░██   ░████ ░██░██   ░██   ░██ ░██    ░██  ░██   ░██   ░██   ░██
░██    ░███ ░██░██   ░██   ░██  ░███████    ░██████     ░██████
                                  Update → '"${NIMO_UPDATE_VERSION}"'
'

[[ "${UNAME_U}" == *Linux* ]] || Show 1 "this script supports Linux only."
Check_Arch

[[ "${DO_CORE}" == "1" ]]  && Update_Core  || Show 3 "skipping the core update (--only-stack)."
[[ "${DO_STACK}" == "1" ]] && Update_Stack || Show 3 "skipping the stack update (--only-core / NIMO_SKIP_STACK=1)."

echo ""
Show 0 "NimoOS updated to ${NIMO_UPDATE_VERSION}."
if command -v nimoos >/dev/null 2>&1; then
    Show 2 "core version now: $(nimoos -v 2>/dev/null || echo unknown)"
fi
