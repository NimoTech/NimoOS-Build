#!/usr/bin/env bash
# install-search.sh — First-time installer for nimoos-search.service
#
# 一次性把 Go 写的 Search 服务装好:
#   - 用 /usr/local/go/bin/go build 出二进制
#   - 装到 /usr/bin/nimoos-search
#   - 安装 systemd unit
#   - 从 search.conf.sample 初始化 /etc/nimoos/search.conf(如不存在)
#   - 创建 /var/lib/nimoos/search、/var/log/nimoos
#
# 用法:sudo bash install-search.sh [--start]
#
# 默认只 enable 不 start;加 --start 立刻拉起服务。
# 之后的代码迭代用 deploy.sh search。

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

# release 坐标(无源码时从 OSS 拉 linux-<arch>-<token>-<ver>.tar.gz)
readonly PROJECT="NimoOS-Search"
readonly TOKEN="nimoos-search"
readonly ARCH_MODE="arch"
readonly VERSION="${STACK_VERSION_SEARCH:-${STACK_VERSION}}"
readonly SEARCH_SRC_DEFAULT="$(cd "${SCRIPT_DIR}/../../NimoOS-Search" 2>/dev/null && pwd || true)"

# 由 acquire() 填充
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
    log_info "获取产物(优先本地源码,否则从 OSS 拉 ${VERSION})..."
    set +e
    RESOLVED="$(stack_resolve "${SEARCH_SRC_DEFAULT}" "${PROJECT}" "${VERSION}" "${ARCH_MODE}" "${TOKEN}")"
    local rc=$?
    set -e
    case "${rc}" in
        0)  MODE="source" ;;
        10) MODE="oss" ;;
        *)  log_fail "产物获取失败:本地无源码且 OSS 下载失败" ;;
    esac
    SYSROOT="${RESOLVED}/build/sysroot"
    CONF_SAMPLE_SRC="${SYSROOT}/etc/nimoos/${APP_NAME_SHORT}.conf.sample"
    UNIT_SRC="${SYSROOT}/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${CONF_SAMPLE_SRC}" ]] || log_fail "缺 conf 样例:${CONF_SAMPLE_SRC}"
    [[ -f "${UNIT_SRC}" ]] || log_fail "缺 systemd unit:${UNIT_SRC}"
    log_ok "模式=${MODE}  产物目录=${RESOLVED}"
}

check_qdrant() {
    log_info "检查 Qdrant (127.0.0.1:6333) ..."
    if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:(6333|6334)'; then
        log_ok "Qdrant 监听 6333/6334 ✓"
    else
        log_warn "Qdrant 没在监听 6333,Search 会启动失败(依赖 parser + qdrant 都得在)。"
    fi
}

build_or_locate_binary() {
    if [[ "${MODE}" == "oss" ]]; then
        BIN_SRC="${SYSROOT}/usr/bin/${APP_NAME}"
        [[ -f "${BIN_SRC}" ]] || log_fail "OSS 包缺预编译二进制:${BIN_SRC}"
        log_ok "使用 OSS 预编译二进制"
        return
    fi
    log_info "源码模式:构建 ${APP_NAME}(CGO=0,纯 Go)..."
    local go_bin="/usr/local/go/bin/go"
    [[ -x "${go_bin}" ]] || go_bin="$(command -v go || true)"
    [[ -n "${go_bin}" ]] || log_fail "找不到 go 工具链(/usr/local/go/bin/go 或 \$PATH)"

    pushd "${RESOLVED}" >/dev/null
    CGO_ENABLED=0 "${go_bin}" build -o "./${APP_NAME}" .
    popd >/dev/null
    BIN_SRC="${RESOLVED}/${APP_NAME}"
    log_ok "Built $(ls -la "${BIN_SRC}" | awk '{print $5}') bytes"
}

install_dirs() {
    log_info "创建目录 ${CONF_PATH} / ${DATA_DIR} / ${LOG_DIR} / ${RUN_DIR} ..."
    ${sudo_cmd} mkdir -p "${CONF_PATH}" "${DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}"
}

install_conf() {
    ${sudo_cmd} cp -v "${CONF_SAMPLE_SRC}" "${CONF_PATH}/${APP_NAME_SHORT}.conf.sample"
    if [[ -f "${CONF_FILE}" ]]; then
        log_info "保留已有配置:${CONF_FILE}"
    else
        log_info "用样例初始化 ${CONF_FILE}"
        ${sudo_cmd} cp -v "${CONF_SAMPLE_SRC}" "${CONF_FILE}"
    fi
}

install_binary() {
    log_info "安装二进制 → ${BIN_DST} ..."
    # 用临时文件 + mv(rename)替换: 直接 cp 覆盖【正在运行】的二进制会 "Text file busy"(ETXTBSY);
    # rename 只换目录项、不动正在执行的旧 inode, 新二进制就位后由 maybe_start 重启加载。
    local _tmp="${BIN_DST}.new.$$"
    ${sudo_cmd} cp -f "${BIN_SRC}" "${_tmp}"
    ${sudo_cmd} chmod 0755 "${_tmp}"
    ${sudo_cmd} mv -f "${_tmp}" "${BIN_DST}"
}

install_unit() {
    log_info "安装 systemd unit → ${UNIT_DST} ..."
    ${sudo_cmd} cp -v "${UNIT_SRC}" "${UNIT_DST}"
    ${sudo_cmd} systemctl daemon-reload
    log_info "Enable ${SERVICE_FILE} ..."
    ${sudo_cmd} systemctl enable --force --no-ask-password "${SERVICE_FILE}"
}

maybe_start() {
    if ${sudo_cmd} systemctl is-active --quiet "${SERVICE_FILE}"; then
        # 已在运行(升级场景): 必须 restart 以加载新二进制(start 对已运行服务是 no-op → 会继续跑旧代码)
        log_info "重启 ${SERVICE_FILE} 以加载新版本 ..."
        ${sudo_cmd} systemctl restart "${SERVICE_FILE}"
        sleep 1
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    elif [[ "${START_AFTER_INSTALL}" == "1" ]]; then
        log_info "启动 ${SERVICE_FILE} ..."
        ${sudo_cmd} systemctl start "${SERVICE_FILE}"
        sleep 1
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    else
        log_info "服务已 enable 未 start。要立刻拉起:"
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
log_ok "Search 安装完成。"
echo ""
echo "  配置:   ${CONF_FILE}"
echo "  数据:   ${DATA_DIR}"
echo "  日志:   journalctl -u ${SERVICE_FILE} -f"
echo "  更新:   bash $(dirname "$0")/deploy.sh search"
