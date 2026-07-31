#!/usr/bin/env bash
# install-photos.sh — First-time installer for nimoos-photos.service
#
# Sets up the main Go Photos binary in one pass:
#   - builds from source with go build (CGO=1, sqlite-vec) when a source tree is
#     present, otherwise downloads the prebuilt release package
#   - installs it to /usr/bin/nimoos-photos
#   - installs the systemd unit
#   - initialises /etc/nimoos/photos.conf from photos.conf.sample if absent
#   - creates /var/lib/nimoos/photos and /var/log/nimoos
#
# Usage: sudo bash install-photos.sh [--start]
#
# By default the service is enabled but not started; pass --start to bring it up
# immediately.
#
# Note: the offline AI/ML backend for Photos (the face and CLIP models) is a
# separate deployment step. This script installs only the main service binary,
# and without the ML backend the people and semantic search features do not work.

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

START_AFTER_INSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start) START_AFTER_INSTALL=1; shift ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

###############################################################################
# Paths and release coordinates
###############################################################################

readonly APP_NAME="nimoos-photos"
readonly APP_NAME_SHORT="photos"
readonly SERVICE_FILE="${APP_NAME}.service"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack-fetch.sh
source "${SCRIPT_DIR}/lib/stack-fetch.sh"

readonly PROJECT="NimoOS-Photos"
readonly TOKEN="nimoos-photos"
readonly ARCH_MODE="arch"
readonly VERSION="${STACK_VERSION_PHOTOS:-${STACK_VERSION}}"
readonly PHOTOS_SRC_DEFAULT="$(cd "${SCRIPT_DIR}/../../NimoOS-Photos" 2>/dev/null && pwd || true)"

# Filled in by acquire()
RESOLVED=""; MODE=""; SYSROOT=""; CONF_SAMPLE_SRC=""; UNIT_SRC=""; BIN_SRC=""

readonly CONF_PATH="/etc/nimoos"
readonly CONF_FILE="${CONF_PATH}/${APP_NAME_SHORT}.conf"
readonly UNIT_DST="/usr/lib/systemd/system/${SERVICE_FILE}"
readonly DATA_DIR="/var/lib/nimoos/photos"
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
    RESOLVED="$(stack_resolve "${PHOTOS_SRC_DEFAULT}" "${PROJECT}" "${VERSION}" "${ARCH_MODE}" "${TOKEN}")"
    local rc=$?
    set -e
    case "${rc}" in
        0)  MODE="source" ;;
        10) MODE="download" ;;
        *)  log_fail "could not obtain the payload: no local source tree and the download failed" ;;
    esac
    SYSROOT="${RESOLVED}/build/sysroot"
    CONF_SAMPLE_SRC="${SYSROOT}/etc/nimoos/${APP_NAME_SHORT}.conf.sample"
    UNIT_SRC="${SYSROOT}/usr/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${CONF_SAMPLE_SRC}" ]] || log_fail "sample configuration missing: ${CONF_SAMPLE_SRC}"
    [[ -f "${UNIT_SRC}" ]] || log_fail "systemd unit missing: ${UNIT_SRC}"
    log_ok "mode=${MODE}  payload=${RESOLVED}"
}

build_or_locate_binary() {
    if [[ "${MODE}" == "download" ]]; then
        BIN_SRC="${SYSROOT}/usr/bin/${APP_NAME}"
        [[ -f "${BIN_SRC}" ]] || log_fail "the downloaded package has no prebuilt binary: ${BIN_SRC}"
        log_ok "using the prebuilt binary from the release package"
        return
    fi
    log_info "source mode: building ${APP_NAME} (CGO=1, sqlite-vec) ..."
    # The sqlite-vec bindings need the system sqlite3.h
    if ! ls /usr/include/sqlite3.h >/dev/null 2>&1; then
        log_warn "sqlite3.h is missing, trying to install libsqlite3-dev ..."
        [ -x "$(command -v apt-get)" ] && ${sudo_cmd} apt-get install -y libsqlite3-dev || \
            log_fail "install libsqlite3-dev first; sqlite-vec cannot compile without it"
    fi
    local go_bin="/usr/local/go/bin/go"
    [[ -x "${go_bin}" ]] || go_bin="$(command -v go || true)"
    [[ -n "${go_bin}" ]] || log_fail "no go toolchain found (looked in /usr/local/go/bin/go and \$PATH)"
    pushd "${RESOLVED}" >/dev/null
    CGO_ENABLED=1 "${go_bin}" build -o "./${APP_NAME}" .
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

log_info "=== NimoOS Photos Installer ==="

acquire
build_or_locate_binary
install_dirs
install_conf
install_binary
install_unit
maybe_start

echo ""
log_ok "Photos installed (main binary)."
echo ""
echo "  config: ${CONF_FILE}"
echo "  data:   ${DATA_DIR}"
echo "  logs:   journalctl -u ${SERVICE_FILE} -f"
echo "  update: bash $(dirname "$0")/deploy.sh ...  (or re-run this script)"
echo "  note:   the AI/ML backend (face and CLIP models) is a separate step and"
echo "          was not installed here."
