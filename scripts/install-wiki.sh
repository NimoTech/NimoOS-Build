#!/usr/bin/env bash
# install-wiki.sh — First-time installer for nimoos-wiki.service
#
# Performs the one-time setup that `deploy.sh wiki` assumes already done:
#   - builds the binary (CGO=1)
#   - installs the systemd unit
#   - creates /etc/nimoos/wiki.conf from the sample (if absent)
#   - creates data + log directories
#   - registers the service with systemd
#
# Usage:  sudo bash install-wiki.sh [--start]
#
# By default the service is enabled but NOT started — re-run with --start, or
# `systemctl start nimoos-wiki` once you're satisfied with the config.

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

START_AFTER_INSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start) START_AFTER_INSTALL=1; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

###############################################################################
# Paths
###############################################################################

readonly APP_NAME="nimoos-wiki"
readonly APP_NAME_SHORT="wiki"
readonly SERVICE_FILE="${APP_NAME}.service"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack-fetch.sh
source "${SCRIPT_DIR}/lib/stack-fetch.sh"

# Release coordinates; without a source tree the tarball is fetched instead
readonly PROJECT="NimoOS-Wiki"
readonly TOKEN="nimoos-wiki"
readonly ARCH_MODE="arch"
readonly VERSION="${STACK_VERSION_WIKI:-${STACK_VERSION}}"
readonly WIKI_SRC_DEFAULT="$(cd "${SCRIPT_DIR}/../../NimoOS-Wiki" 2>/dev/null && pwd || true)"

# populated by acquire()
RESOLVED=""; MODE=""; SYSROOT=""; CONF_SAMPLE_SRC=""; UNIT_SRC=""; BIN_SRC=""

readonly CONF_PATH="/etc/nimoos"
readonly CONF_FILE="${CONF_PATH}/${APP_NAME_SHORT}.conf"
readonly UNIT_DST="/usr/lib/systemd/system/${SERVICE_FILE}"
readonly DATA_DIR="/var/lib/nimoos/wiki"
readonly LOG_DIR="/var/log/nimoos"
readonly BIN_DST="/usr/bin/${APP_NAME}"

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
    log_info "Resolving artifact (local source preferred, else download ${VERSION})..."
    set +e
    RESOLVED="$(stack_resolve "${WIKI_SRC_DEFAULT}" "${PROJECT}" "${VERSION}" "${ARCH_MODE}" "${TOKEN}")"
    local rc=$?
    set -e
    case "${rc}" in
        0)  MODE="source" ;;
        10) MODE="download" ;;
        *)  log_fail "Artifact fetch failed: no local source and the download failed" ;;
    esac
    SYSROOT="${RESOLVED}/build/sysroot"
    CONF_SAMPLE_SRC="${SYSROOT}/etc/nimoos/${APP_NAME_SHORT}.conf.sample"
    UNIT_SRC="${SYSROOT}/usr/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${CONF_SAMPLE_SRC}" ]] || log_fail "Sample config missing: ${CONF_SAMPLE_SRC}"
    [[ -f "${UNIT_SRC}" ]] || log_fail "Systemd unit missing: ${UNIT_SRC}"
    log_ok "mode=${MODE}  dir=${RESOLVED}"
}

build_or_locate_binary() {
    if [[ "${MODE}" == "download" ]]; then
        BIN_SRC="${SYSROOT}/usr/bin/${APP_NAME}"
        [[ -f "${BIN_SRC}" ]] || log_fail "Release package missing prebuilt binary: ${BIN_SRC}"
        log_ok "Using the prebuilt binary from the release package"
        return
    fi
    log_info "Source mode: building ${APP_NAME} (CGO=1)..."
    local go_bin="/usr/local/go/bin/go"
    [[ -x "${go_bin}" ]] || go_bin="$(command -v go || true)"
    [[ -n "${go_bin}" ]] || log_fail "go toolchain not found"
    pushd "${RESOLVED}" >/dev/null
    CGO_ENABLED=1 "${go_bin}" build -o "./${APP_NAME}" .
    popd >/dev/null
    BIN_SRC="${RESOLVED}/${APP_NAME}"
    log_ok "Built $(ls -la "${BIN_SRC}" | awk '{print $5}') bytes"
}

install_dirs() {
    log_info "Creating data + log directories..."
    ${sudo_cmd} mkdir -p "${CONF_PATH}" "${DATA_DIR}" "${LOG_DIR}"
}

install_conf() {
    ${sudo_cmd} cp -v "${CONF_SAMPLE_SRC}" "${CONF_PATH}/${APP_NAME_SHORT}.conf.sample"
    if [[ -f "${CONF_FILE}" ]]; then
        log_info "Config already exists at ${CONF_FILE} (leaving unchanged)"
    else
        log_info "Initializing ${CONF_FILE} from sample"
        ${sudo_cmd} cp -v "${CONF_SAMPLE_SRC}" "${CONF_FILE}"
    fi
}

install_binary() {
    log_info "Installing binary to ${BIN_DST}..."
    # Replace via a temp file and rename: cp over a RUNNING binary fails with
    # "Text file busy" (ETXTBSY).
    # rename only swaps the directory entry and leaves the executing inode
    # alone; maybe_start then restarts to load the new build.
    local _tmp="${BIN_DST}.new.$$"
    ${sudo_cmd} cp -f "${BIN_SRC}" "${_tmp}"
    ${sudo_cmd} chmod 0755 "${_tmp}"
    ${sudo_cmd} mv -f "${_tmp}" "${BIN_DST}"
}

install_unit() {
    log_info "Installing systemd unit to ${UNIT_DST}..."
    ${sudo_cmd} cp -v "${UNIT_SRC}" "${UNIT_DST}"
    ${sudo_cmd} systemctl daemon-reload
    log_info "Enabling ${SERVICE_FILE}..."
    ${sudo_cmd} systemctl enable --force --no-ask-password "${SERVICE_FILE}"
}

maybe_start() {
    if ${sudo_cmd} systemctl is-active --quiet "${SERVICE_FILE}"; then
        # Already running (an upgrade): restart is required to load the new
        # binary — start is a no-op for a running service and would keep the
        # old code running
        log_info "restarting ${SERVICE_FILE} to load the new build ..."
        ${sudo_cmd} systemctl restart "${SERVICE_FILE}"
        sleep 1
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    elif [[ "${START_AFTER_INSTALL}" == "1" ]]; then
        log_info "Starting ${SERVICE_FILE}..."
        ${sudo_cmd} systemctl start "${SERVICE_FILE}"
        sleep 1
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    else
        log_info "Service enabled but not started. To start now:"
        echo "    ${sudo_cmd:-sudo} systemctl start ${SERVICE_FILE}"
    fi
}

###############################################################################
# Main
###############################################################################

log_info "=== NimoOS Wiki Service Installer ==="

acquire
build_or_locate_binary
install_dirs
install_conf
install_binary
install_unit
maybe_start

echo ""
log_ok "Install complete."
echo ""
echo "  Config:   ${CONF_FILE}"
echo "  Data:     ${DATA_DIR}"
echo "  Logs:     ${LOG_DIR}/${APP_NAME}.log  (and journalctl -u ${SERVICE_FILE})"
echo "  Updates:  bash $(dirname "$0")/deploy.sh wiki"
