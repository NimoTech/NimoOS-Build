#!/usr/bin/env bash
# install-parser.sh — First-time installer for nimoos-parser.service
#
# 一次性把 Python Parser 装好:
#   - 准备 Python 3.11+ 和 venv
#   - 创建 /opt/nimoos-parser/{parser,venv,hf-cache}
#   - 装 requirements.txt(含 docling / rapidocr / FlagEmbedding / torch)
#   - 装 systemd unit 和 /etc/nimoos/parser.conf
#   - 创建 /var/lib/nimoos/parser、/var/log/nimoos、/var/run/nimoos
#   - 检查 Qdrant 是否在跑(127.0.0.1:6333)
#
# 用法:sudo bash install-parser.sh [--start]
#
# 默认只 enable 不 start;加 --start 立刻拉起服务。
# 之后的代码迭代用 deploy-parser.sh 热部署。

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

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

# release 坐标(python 源码包, 架构无关 linux-all; 无源码时从 OSS 拉)
readonly PROJECT="NimoOS-Parser"
readonly TOKEN="nimoos-parser"
readonly ARCH_MODE="all"
readonly VERSION="${STACK_VERSION_PARSER:-${STACK_VERSION}}"
readonly PARSER_SRC_DEFAULT="$(cd "${SCRIPT_DIR}/../../NimoOS-Parser" 2>/dev/null && pwd || true)"

# 由 acquire() 填充
RESOLVED=""; MODE=""; SYSROOT=""; UNIT_SRC=""; CONF_SAMPLE_SRC=""

readonly INSTALL_DIR="/opt/nimoos-parser"
readonly VENV_DIR="${INSTALL_DIR}/venv"
readonly HF_CACHE_DIR="${INSTALL_DIR}/hf-cache"
# uv 托管的独立 CPython 落盘处(系统级、root 拥有,不依赖某个用户的 home)
readonly UV_PY_DIR="${INSTALL_DIR}/uv-python"

# 建 venv 用的解释器(check_python 填充);默认系统 python3,
# 在 python≥3.12 的系统上会被换成 uv 提供的 3.11。
PARSER_PY="python3"
UV_BIN=""

# 预编译快速通道:x86_64 默认从 OSS deps/parser/ 拉预装好的 venv + 模型,
# 跳过 pip(慢/被墙)与首次运行的 HF 模型下载。venv 是 cp311 manylinux,
# 与 uv 提供的 3.11 ABI 兼容;要求目标 glibc ≥ 打包机(2.36)。
#   NIMO_PARSER_BUILD=1   强制走 pip 源码安装(不用预编译 venv)
#   NIMO_PARSER_MODELS=0  跳过模型下载(parser 首次运行时再从 HF 拉)
readonly DEP_VENV="parser/parser-venv-${VERSION}-cp311-linux-x86_64.tar.zst"
readonly DEP_HFCACHE="parser/hf-cache.tar.zst"

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
    log_info "获取产物(优先本地源码,否则从 OSS 拉 ${VERSION})..."
    set +e
    RESOLVED="$(stack_resolve "${PARSER_SRC_DEFAULT}" "${PROJECT}" "${VERSION}" "${ARCH_MODE}" "${TOKEN}")"
    local rc=$?
    set -e
    case "${rc}" in
        0)  MODE="source" ;;
        10) MODE="oss" ;;
        *)  log_fail "产物获取失败:本地无源码且 OSS 下载失败" ;;
    esac
    SYSROOT="${RESOLVED}/build/sysroot"
    # 仓库模板在 usr/lib/(此前误写成 lib/ 是"仓库改了、真机没生效"型
    # 部署漂移的成因之一);保留 lib/ 回退兼容旧 OSS 产物布局。
    UNIT_SRC="${SYSROOT}/usr/lib/systemd/system/${SERVICE_FILE}"
    [[ -f "${UNIT_SRC}" ]] || UNIT_SRC="${SYSROOT}/lib/systemd/system/${SERVICE_FILE}"
    CONF_SAMPLE_SRC="${SYSROOT}/etc/nimoos/${APP_NAME_SHORT}.conf"
    [[ -d "${RESOLVED}/parser" ]] || log_fail "缺 parser 包目录:${RESOLVED}/parser"
    [[ -f "${RESOLVED}/requirements.txt" ]] || log_fail "缺 requirements.txt:${RESOLVED}/requirements.txt"
    [[ -f "${UNIT_SRC}" ]] || log_fail "缺 systemd unit:${UNIT_SRC}"
    [[ -f "${CONF_SAMPLE_SRC}" ]] || log_fail "缺 conf 样例:${CONF_SAMPLE_SRC}"
    log_ok "模式=${MODE}  产物目录=${RESOLVED}"
}

# 确保给定解释器的 venv/ensurepip 可用(Debian 把 venv 拆成独立 deb)。
ensure_venv_module() {
    local py="$1"
    [ -x "$(command -v apt-get)" ] || { "${py}" -c 'import ensurepip' >/dev/null 2>&1 || log_fail "${py} 缺 venv(import ensurepip 失败)"; return; }
    "${py}" -c 'import ensurepip' >/dev/null 2>&1 && return
    local pyver
    pyver="$("${py}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    log_info "安装 venv 支持 (python${pyver}-venv,失败则回退 python3-venv) ..."
    # apt 退出码可能被系统里其它损坏包污染,用 `|| true` 兜住,最后以 ensurepip 为准。
    ${sudo_cmd} apt-get update -qq || true
    ${sudo_cmd} apt-get install -y "python${pyver}-venv" 2>/dev/null \
        || ${sudo_cmd} apt-get install -y python3-venv || true
    "${py}" -c 'import ensurepip' >/dev/null 2>&1 \
        || log_fail "venv 仍不可用(import ensurepip 失败),请手动修复 apt/venv 后重试"
}

# 定位或安装 uv(astral.sh)。装到 /usr/local/bin 让 root 与服务都能用。
ensure_uv() {
    UV_BIN="$(command -v uv 2>/dev/null || true)"
    [ -z "${UV_BIN}" ] && [ -x /usr/local/bin/uv ] && UV_BIN=/usr/local/bin/uv
    [ -z "${UV_BIN}" ] && [ -x "${HOME}/.local/bin/uv" ] && UV_BIN="${HOME}/.local/bin/uv"
    [ -z "${UV_BIN}" ] && [ -x /root/.local/bin/uv ] && UV_BIN=/root/.local/bin/uv
    if [ -n "${UV_BIN}" ]; then log_ok "uv 已就绪:${UV_BIN} ($(${UV_BIN} --version 2>/dev/null))"; return; fi

    log_info "安装 uv(从 astral.sh)→ /usr/local/bin ..."
    local tmp_uv; tmp_uv="$(mktemp)"
    curl -fLsS --connect-timeout 10 https://astral.sh/uv/install.sh -o "${tmp_uv}" \
        || log_fail "uv 安装脚本下载失败(astral.sh 不可达)。请手动装 uv 后重试。"
    ${sudo_cmd} env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh "${tmp_uv}" \
        || log_fail "uv 安装失败"
    rm -f "${tmp_uv}"
    UV_BIN=/usr/local/bin/uv
    [ -x "${UV_BIN}" ] || log_fail "uv 安装后未找到 ${UV_BIN}"
    log_ok "uv 安装完成:$(${UV_BIN} --version 2>/dev/null)"
}

check_python() {
    log_info "准备 Python 3.11 运行时(parser 依赖 rapidocr/docling 等只有 ≤3.11 的 wheel)..."

    local sysver
    sysver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"

    # 1) 系统 python3 恰好是 3.11 → 直接用
    if [ "${sysver}" = "3.11" ]; then
        ensure_venv_module python3
        PARSER_PY="python3"
        log_ok "用系统 Python ${sysver}"
        return
    fi
    # 2) 有独立的 python3.11 命令 → 用它
    if command -v python3.11 >/dev/null 2>&1; then
        ensure_venv_module python3.11
        PARSER_PY="$(command -v python3.11)"
        log_ok "用 python3.11:$(python3.11 --version)"
        return
    fi
    # 3) 系统 python 太新(≥3.12,如 Debian 13 的 3.13)或太旧:rapidocr 无对应 wheel,
    #    用 uv 拉一个独立、自包含的 CPython 3.11 建 venv,不动系统 python。
    log_warn "系统 Python=${sysver:-未知},与 parser 依赖不兼容。改用 uv 提供独立 Python 3.11。"
    ensure_uv
    ${sudo_cmd} mkdir -p "${UV_PY_DIR}"
    log_info "uv 安装独立 CPython 3.11(落盘 ${UV_PY_DIR})..."
    ${sudo_cmd} env "UV_PYTHON_INSTALL_DIR=${UV_PY_DIR}" "${UV_BIN}" python install 3.11 \
        || log_fail "uv python install 3.11 失败"
    PARSER_PY="$(${sudo_cmd} env "UV_PYTHON_INSTALL_DIR=${UV_PY_DIR}" "${UV_BIN}" python find 3.11 2>/dev/null)"
    [ -n "${PARSER_PY}" ] && ${sudo_cmd} test -x "${PARSER_PY}" \
        || log_fail "uv 未能提供可用的 Python 3.11(find 返回:${PARSER_PY:-空})"
    log_ok "用 uv 的 Python 3.11:${PARSER_PY}"
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
        log_ok "LibreOffice 已就绪(soffice headless)"
        return
    fi
    log_info "安装 LibreOffice headless 依赖:${missing[*]} (~300-400MB) ..."
    if [ -x "$(command -v apt-get)" ]; then
        # apt 的退出码可能被系统里其它损坏包(如自定义内核 postinst 失败)污染,
        # 不能据此判断成败;用 `|| true` 兜住,装完按 dpkg 复查真实结果。
        ${sudo_cmd} apt-get update -qq || true
        ${sudo_cmd} apt-get install -y "${missing[@]}" || true
        local still=()
        for p in "${missing[@]}"; do
            dpkg -s "$p" >/dev/null 2>&1 || still+=("$p")
        done
        if (( ${#still[@]} == 0 )); then
            log_ok "LibreOffice 安装完成。"
        else
            log_warn "这些包仍未装上:${still[*]}"
            log_warn ".doc/.ppt/.xls/.wps 文件将无法被索引(可稍后手动补装)。"
        fi
    else
        log_warn "无 apt-get,请手动安装:${missing[*]}"
        log_warn ".doc/.ppt/.xls/.wps 文件将无法被索引。"
    fi
}

check_qdrant() {
    log_info "检查 Qdrant (127.0.0.1:6333) ..."
    if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:(6333|6334)'; then
        log_ok "Qdrant 监听 6333/6334 ✓"
    else
        log_warn "Qdrant 没在监听 6333,Parser 会启动失败。"
        cat <<'EOF'
        建议跑(Docker):
          docker run -d --restart=always --name qdrant \
            --memory=4g --memory-swap=4g \
            -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 \
            -v /var/lib/qdrant:/qdrant/storage \
            qdrant/qdrant:latest
EOF
    fi
}

install_dirs() {
    log_info "创建目录 ${INSTALL_DIR} / ${DATA_DIR} / ${LOG_DIR} / ${RUN_DIR} ..."
    ${sudo_cmd} mkdir -p \
        "${INSTALL_DIR}" "${HF_CACHE_DIR}" \
        "${CONF_PATH}" "${DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}"
}

install_source() {
    log_info "同步 parser 包 → ${INSTALL_DIR}/parser/ ..."
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
    log_info "安装 zstd(解压预编译包需要)..."
    if [ -x "$(command -v apt-get)" ]; then
        ${sudo_cmd} apt-get update -qq || true
        ${sudo_cmd} apt-get install -y zstd || true
    fi
    command -v zstd >/dev/null 2>&1
}

# x86_64 且未强制源码构建 → 走预编译快速通道
use_prebuilt() {
    [[ "$(uname -m)" == "x86_64" && "${NIMO_PARSER_BUILD:-0}" != "1" ]]
}

# 下载并铺开预编译 venv 的 site-packages。成功返回 0,失败非 0(调用方回退 pip)。
fetch_prebuilt_venv() {
    ensure_zstd || { log_warn "zstd 不可用,无法用预编译 venv"; return 1; }
    local url="${NIMO_DEPS_BASE}/${DEP_VENV}"
    local tmp; tmp="$(mktemp)"
    log_info "下载预编译 venv:${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"; log_warn "预编译 venv 下载失败(该版本可能未发布预编译包)"; return 1
    fi
    local sp="${VENV_DIR}/lib/python3.11/site-packages"
    log_info "铺开 site-packages → ${sp} ..."
    ${sudo_cmd} rm -rf "${sp}" && ${sudo_cmd} mkdir -p "${sp}" || return 1
    if ! ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${sp}"; then
        rm -f "${tmp}"; log_warn "预编译 venv 解包失败"; return 1
    fi
    rm -f "${tmp}"
    # 冒烟校验:关键编译扩展能否在本机解释器导入(glibc/ABI 不兼容则回退)
    if ! ${sudo_cmd} "${VENV_DIR}/bin/python" -c 'import torch, onnxruntime, uvicorn' >/dev/null 2>&1; then
        log_warn "预编译 venv 导入校验失败(glibc/ABI 不兼容?),回退 pip"; return 1
    fi
    log_ok "预编译 venv 就位(跳过 pip)。"
}

# 下载并铺开预编译模型到 hf-cache(bge-m3 / reranker / docling)。
fetch_models() {
    if [[ "${NIMO_PARSER_MODELS:-1}" == "0" ]]; then
        log_info "NIMO_PARSER_MODELS=0:跳过模型下载(parser 首次运行时再由 HF 拉)。"; return
    fi
    if ! use_prebuilt; then
        log_info "非 x86_64 或强制构建:模型将在 parser 首次运行时由 HF 下载。"; return
    fi
    if [[ -d "${HF_CACHE_DIR}/hub" ]]; then
        log_ok "hf-cache 已有模型,跳过下载。"; return
    fi
    ensure_zstd || { log_warn "zstd 不可用,跳过预编译模型"; return; }
    local url="${NIMO_DEPS_BASE}/${DEP_HFCACHE}"
    local tmp; tmp="$(mktemp)"
    log_info "下载预编译模型 hf-cache(解压后 ~7G):${url} ..."
    if ${sudo_cmd} mkdir -p "${HF_CACHE_DIR}" \
        && curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}" \
        && ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${HF_CACHE_DIR}"; then
        log_ok "模型就位(跳过 HF 下载)。"
    else
        log_warn "预编译模型获取失败,parser 首次运行会尝试从 HF 拉(可能慢/被墙)。"
    fi
    rm -f "${tmp}"
}

setup_venv() {
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        log_info "创建 venv:${VENV_DIR}(解释器:${PARSER_PY})..."
        ${sudo_cmd} "${PARSER_PY}" -m venv "${VENV_DIR}"
    else
        log_info "venv 已存在:${VENV_DIR}"
    fi

    # x86_64 优先用 OSS 预编译 venv(秒级铺开、免 pip);失败再回退 pip 源码安装。
    if use_prebuilt && fetch_prebuilt_venv; then
        return
    fi
    use_prebuilt && log_warn "回退到 pip 源码安装(预编译 venv 不可用)。"

    # 可选 pip 国内镜像加速(如 NIMO_PIP_INDEX=https://mirrors.aliyun.com/pypi/simple/);
    # sudo 会清环境,故以参数形式传入而非依赖 PIP_INDEX_URL。
    local pip_args=()
    [[ -n "${NIMO_PIP_INDEX:-}" ]] && pip_args+=(-i "${NIMO_PIP_INDEX}")
    log_info "升级 pip ..."
    ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${pip_args[@]}" --quiet --upgrade pip
    log_info "安装依赖 (docling + rapidocr + torch 等,首次会下 ~3GB wheel,慢请耐心) ..."
    ${sudo_cmd} "${VENV_DIR}/bin/pip" install "${pip_args[@]}" --upgrade -r "${INSTALL_DIR}/requirements.txt"
    log_ok "Python 依赖装好。"
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

install_unit() {
    log_info "安装 systemd unit → ${UNIT_DST} ..."
    ${sudo_cmd} cp -v "${UNIT_SRC}" "${UNIT_DST}"
    ${sudo_cmd} systemctl daemon-reload
    log_info "Enable ${SERVICE_FILE} ..."
    ${sudo_cmd} systemctl enable --force --no-ask-password "${SERVICE_FILE}"
    # 防"改了没装上"型部署漂移(2026-07-28 OOM 复盘):装完必须验证
    # cgroup 内存兜底真实生效,unit 没写 MemoryMax 时 systemd 返回 infinity。
    local mem_max
    mem_max=$(${sudo_cmd} systemctl show "${SERVICE_FILE}" -p MemoryMax --value)
    if [[ -z "${mem_max}" || "${mem_max}" == "infinity" ]]; then
        log_fail "unit 内存兜底未生效(MemoryMax=${mem_max:-empty}),检查 ${UNIT_DST}"
    fi
    log_ok "内存兜底已生效:MemoryMax=${mem_max}"
}

maybe_start() {
    if ${sudo_cmd} systemctl is-active --quiet "${SERVICE_FILE}"; then
        # 已在运行(升级场景): 必须 restart 以加载刚同步的新源码
        # (start 对已运行服务是 no-op → parser 会继续跑旧代码, 缺新路由)
        log_info "重启 ${SERVICE_FILE} 以加载新代码 ..."
        ${sudo_cmd} systemctl restart "${SERVICE_FILE}"
        sleep 2
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    elif [[ "${START_AFTER_INSTALL}" == "1" ]]; then
        log_info "启动 ${SERVICE_FILE} ..."
        ${sudo_cmd} systemctl start "${SERVICE_FILE}"
        sleep 2
        ${sudo_cmd} systemctl status "${SERVICE_FILE}" --no-pager -l --lines=10 || true
    else
        log_info "服务已 enable 未 start。要立刻拉起:"
        echo "    ${sudo_cmd:-sudo} systemctl start ${SERVICE_FILE}"
    fi
}

###############################################################################
# Main
###############################################################################

log_info "=== NimoOS Parser Installer ==="
log_info "目标:${INSTALL_DIR}"

acquire
check_python
check_libreoffice
check_qdrant
install_dirs
install_source
setup_venv
fetch_models
install_conf
install_unit
maybe_start

echo ""
log_ok "Parser 安装完成。"
echo ""
echo "  代码:   ${INSTALL_DIR}/parser/"
echo "  venv:   ${VENV_DIR}"
echo "  HF 缓存:${HF_CACHE_DIR}  (docling / BGE-M3 模型落盘在这)"
echo "  配置:   ${CONF_FILE}"
echo "  数据:   ${DATA_DIR}/parser.db"
echo "  日志:   journalctl -u ${SERVICE_FILE} -f"
echo "  更新:   bash $(dirname "$0")/deploy-parser.sh"
