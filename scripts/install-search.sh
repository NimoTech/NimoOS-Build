#!/usr/bin/env bash
# install-search.sh — First-time installer for nimoos-search.service
#
# Sets up the Go Search service in one pass:
#   - builds the binary with /usr/local/go/bin/go build
#   - installs it to /usr/bin/nimoos-search
#   - installs the systemd unit
#   - initialises /etc/nimoos/search.conf from search.conf.sample if absent
#   - creates /var/lib/nimoos/search and /var/log/nimoos
#
# Usage: sudo bash install-search.sh [--start]
#
# By default the service is enabled but not started; pass --start to bring it up
# immediately. Use `deploy.sh search` for subsequent code updates.

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

readonly APP_NAME="nimoos-search"
readonly APP_NAME_SHORT="search"
readonly SERVICE_FILE="${APP_NAME}.service"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack-fetch.sh
source "${SCRIPT_DIR}/lib/stack-fetch.sh"

# Release coordinates. With no local source tree,
# linux-<arch>-<token>-<ver>.tar.gz is downloaded instead.
readonly PROJECT="NimoOS-Search"
readonly TOKEN="nimoos-search"
readonly ARCH_MODE="arch"
readonly VERSION="${STACK_VERSION_SEARCH:-${STACK_VERSION}}"
readonly SEARCH_SRC_DEFAULT="$(cd "${SCRIPT_DIR}/../../NimoOS-Search" 2>/dev/null && pwd || true)"

# Filled in by acquire()
RESOLVED=""; MODE=""; SYSROOT=""; CONF_SAMPLE_SRC=""; UNIT_SRC=""; BIN_SRC=""

readonly CONF_PATH="/etc/nimoos"
readonly CONF_FILE="${CONF_PATH}/${APP_NAME_SHORT}.conf"
readonly UNIT_DST="/usr/lib/systemd/system/${SERVICE_FILE}"
readonly DATA_DIR="/var/lib/nimoos/search"
readonly LOG_DIR="/var/log/nimoos"
readonly RUN_DIR="/var/run/nimoos"
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
    log_info "acquiring the payload (local source first, otherwise download ${VERSION}) ..."
    set +e
    RESOLVED="$(stack_resolve "${SEARCH_SRC_DEFAULT}" "${PROJECT}" "${VERSION}" "${ARCH_MODE}" "${TOKEN}")"
    local rc=$?
    set -e
    case "${rc}" in
        0)  MODE="source" ;;
        10) MODE="download" ;;
        *)  log_fail "could not obtain the payload: no local source tree and the download failed" ;;
    esac
    SYSROOT="${RESOLVED}/build/sysroot"
    CONF_SAMPLE_SRC="${SYSROOT}/etc/nimoos/${APP_NAME_SHORT}.conf.sample"
    # NimoOS-Search ships its unit at sysroot/usr/lib/systemd/system, like every
    # other component; this looked under sysroot/lib and so could never find it,
    # which made a source-mode install fail every time. The lib/ fallback stays
    # for older payload layouts, matching install-parser.sh.
    UNIT_SRC="${SYSROOT}/usr/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${UNIT_SRC}" ]] || UNIT_SRC="${SYSROOT}/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${CONF_SAMPLE_SRC}" ]] || log_fail "sample configuration missing: ${CONF_SAMPLE_SRC}"
    [[ -f "${UNIT_SRC}" ]] || log_fail "systemd unit missing: ${UNIT_SRC}"
    log_ok "mode=${MODE}  payload=${RESOLVED}"
}

check_qdrant() {
    log_info "checking Qdrant (127.0.0.1:6333) ..."
    if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:(6333|6334)'; then
        log_ok "Qdrant is listening on 6333/6334"
    else
        log_warn "Qdrant is not listening on 6333, so Search will fail to start (it needs both parser and qdrant up)."
    fi
}

build_or_locate_binary() {
    if [[ "${MODE}" == "download" ]]; then
        BIN_SRC="${SYSROOT}/usr/bin/${APP_NAME}"
        [[ -f "${BIN_SRC}" ]] || log_fail "the downloaded package has no prebuilt binary: ${BIN_SRC}"
        log_ok "using the prebuilt binary from the release package"
        return
    fi
    log_info "source mode: building ${APP_NAME} (CGO=0, pure Go) ..."
    local go_bin="/usr/local/go/bin/go"
    [[ -x "${go_bin}" ]] || go_bin="$(command -v go || true)"
    [[ -n "${go_bin}" ]] || log_fail "no go toolchain found (looked in /usr/local/go/bin/go and \$PATH). Source mode was chosen because a local ${PROJECT} tree is present, and building it needs Go. Install Go, or move/rename that tree so the installer downloads the release tarball instead."

    pushd "${RESOLVED}" >/dev/null
    CGO_ENABLED=0 "${go_bin}" build -o "./${APP_NAME}" .
    popd >/dev/null
    BIN_SRC="${RESOLVED}/${APP_NAME}"
    log_ok "Built $(ls -la "${BIN_SRC}" | awk '{print $5}') bytes"
}

install_dirs() {
    log_info "creating ${CONF_PATH} / ${DATA_DIR} / ${LOG_DIR} / ${RUN_DIR} ..."
    ${sudo_cmd} mkdir -p "${CONF_PATH}" "${DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}"
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

install_binary() {
    log_info "installing the binary to ${BIN_DST} ..."
    # Write to a temporary name and rename over the target. Copying straight onto
    # a binary that is currently executing fails with "Text file busy" (ETXTBSY);
    # rename only swaps the directory entry and leaves the running inode alone,
    # and maybe_start then restarts the service to pick up the new one.
    local _tmp="${BIN_DST}.new.$$"
    ${sudo_cmd} cp -f "${BIN_SRC}" "${_tmp}"
    ${sudo_cmd} chmod 0755 "${_tmp}"
    ${sudo_cmd} mv -f "${_tmp}" "${BIN_DST}"
}

install_unit() {
    log_info "installing the systemd unit to ${UNIT_DST} ..."
    ${sudo_cmd} cp -v "${UNIT_SRC}" "${UNIT_DST}"
    ${sudo_cmd} systemctl daemon-reload
    log_info "enabling ${SERVICE_FILE} ..."
    ${sudo_cmd} systemctl enable --force --no-ask-password "${SERVICE_FILE}"
}

maybe_start() {
    if ${sudo_cmd} systemctl is-active --quiet "${SERVICE_FILE}"; then
        # Already running (the upgrade case): it must be restarted to pick up the
        # new binary. `start` is a no-op on a running service, which would leave
        # the old code in place.
        log_info "restarting ${SERVICE_FILE} to load the new version ..."
        ${sudo_cmd} systemctl restart "${SERVICE_FILE}"
        sleep 1
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    elif [[ "${START_AFTER_INSTALL}" == "1" ]]; then
        log_info "starting ${SERVICE_FILE} ..."
        ${sudo_cmd} systemctl start "${SERVICE_FILE}"
        sleep 1
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    else
        log_info "the service is enabled but not started. To bring it up now:"
        echo "    ${sudo_cmd:-sudo} systemctl start ${SERVICE_FILE}"
    fi
}

###############################################################################
# Main
###############################################################################

log_info "=== NimoOS Search Installer ==="

acquire
check_qdrant
build_or_locate_binary
install_dirs
install_conf
install_binary
install_unit
maybe_start

echo ""
log_ok "Search installed."
echo ""
echo "  config: ${CONF_FILE}"
echo "  data:   ${DATA_DIR}"
echo "  logs:   journalctl -u ${SERVICE_FILE} -f"
echo "  update: bash $(dirname "$0")/deploy.sh search"
