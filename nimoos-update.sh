#!/usr/bin/bash
#
#           NimoOS Update Script v0.4.17
#   GitHub: https://github.com/NimoTech/NimoOS
#   Issues: https://github.com/NimoTech/NimoOS/issues
#   Requires: bash, curl/wget, tar, systemd
#
#   把【已安装】的 NimoOS 升级到指定版本(默认 v1.9.1-alpha1):
#     - 核心: 从深圳 OSS 拉各组件 release tar,停服务 → 覆盖 sysroot → 跑
#             migration/setup/service 脚本 → daemon-reload → 重启服务。
#     - 全栈: 调用 nimoos-stack-install.sh 幂等刷新 qdrant/parser/agent/ollama
#             /模型并重启检索/AI 栈(模型与 venv 已存在则复用,不重复下载)。
#
#   与 install 不同: 本脚本【不】装 Docker / 系统依赖 / 也不做交互式检查,
#   只负责"把已装好的 NimoOS 换成新版本的二进制 + 前端 + 配置并重启"。
#
#   用法:
#     curl -fsSL https://nimoos.oss-cn-shenzhen.aliyuncs.com/get/nimoos-update.sh | sudo bash
#       仅更新核心(跳过重栈):
#     curl -fsSL .../get/nimoos-update.sh | sudo NIMO_SKIP_STACK=1 bash
#       指定版本 / 只更新栈:
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
NIMO_DOWNLOAD_DOMAIN="https://nimoos.oss-cn-shenzhen.aliyuncs.com/"

# 版本(可被 --version / 环境变量覆盖)。AppStore 走独立版本线。
NIMO_UPDATE_VERSION="${NIMO_UPDATE_VERSION:-v1.9.4-alpha1}"
NIMO_APPSTORE_VERSION="${NIMO_APPSTORE_VERSION:-v1.0.9}"

# 更新范围
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
        *) echo "未知参数: $1 (用 --help 查看)"; exit 1 ;;
    esac
done
# 兼容 install 系列的环境开关
[[ "${NIMO_SKIP_STACK:-0}" == "1" ]] && DO_STACK=0

###############################################################################
# Core update                                                                 #
###############################################################################

# 核心组件包顺序须与 nimoos-install.sh 的 NIMO_PACKAGES 一致(nimoos 核心放最后,
# 以便从 UI 触发的更新逻辑可用)。字段: OSS项目名|tar token|arch_mode(arch/all)
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

# 确保终端组件依赖(tmux + ttyd)就位。幂等:已装则跳过。
# tmux 走 apt;ttyd 按架构拉取(OSS 优先,GitHub 兜底),放 /usr/lib/nimoos/ttyd。
Ensure_Terminal_Deps() {
    if ! command -v tmux >/dev/null 2>&1; then
        Show 2 "安装 tmux(终端依赖)..."
        ${sudo_cmd} apt-get install -y tmux || Show 3 "tmux 安装失败;终端将降级。"
    fi
    if [ ! -x /usr/lib/nimoos/ttyd ]; then
        local ttyd_ver="1.7.7" ttyd_asset=""
        case "${UNAME_M}" in
            *aarch64*) ttyd_asset="ttyd.aarch64" ;;
            *64*)      ttyd_asset="ttyd.x86_64" ;;
            *armv7*)   ttyd_asset="ttyd.arm" ;;
            *) Show 3 "不支持的架构 ${UNAME_M},ttyd 跳过,终端将降级。" ;;
        esac
        if [ -n "${ttyd_asset}" ]; then
            local ttyd_gh="https://github.com/tsl0922/ttyd/releases/download/${ttyd_ver}/${ttyd_asset}"
            local ttyd_primary="${NIMO_DOWNLOAD_DOMAIN}ttyd/${ttyd_ver}/${ttyd_asset}"
            ${sudo_cmd} mkdir -p /usr/lib/nimoos
            Show 2 "拉取 ttyd ${ttyd_ver}(${ttyd_asset})..."
            if ${sudo_cmd} curl -fsSL --connect-timeout 20 -o /usr/lib/nimoos/ttyd "${ttyd_primary}" 2>/dev/null \
               || ${sudo_cmd} curl -fsSL --connect-timeout 20 -o /usr/lib/nimoos/ttyd "${ttyd_gh}"; then
                ${sudo_cmd} chmod 755 /usr/lib/nimoos/ttyd
            else
                Show 3 "ttyd 拉取失败;终端将降级。"
            fi
        fi
    fi
}

# 重启顺序须与 install 一致(nimoos 核心最后)
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
    # nimoos-agent 现为 Docker 容器(非 systemd 服务),由栈阶段 install-ai.sh/compose 重启,不在此列
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

# 构造某组件的下载 URL
core_pkg_url() {
    local project="$1" token="$2" archmode="$3"
    local ver arch
    if [ "${token}" = "appstore" ]; then ver="${NIMO_APPSTORE_VERSION}"; else ver="${NIMO_UPDATE_VERSION}"; fi
    if [ "${archmode}" = "all" ]; then arch="all"; else arch="${TARGET_ARCH}"; fi
    echo "${NIMO_DOWNLOAD_DOMAIN}NimoTech/${project}/releases/download/${ver}/linux-${arch}-${token}-${ver}.tar.gz"
}

Update_Core() {
    Show 2 "更新核心组件到 ${NIMO_UPDATE_VERSION} (AppStore ${NIMO_APPSTORE_VERSION})"
    ${sudo_cmd} rm -rf "${TMP_ROOT}"
    ${sudo_cmd} mkdir -p "${TMP_ROOT}"
    local TMP_DIR
    TMP_DIR=$(${sudo_cmd} mktemp -d -p "${TMP_ROOT}") || Show 1 "无法创建临时目录"

    # 1) 下载所有核心包
    local line project token archmode url
    while IFS='|' read -r project token archmode; do
        [ -n "${project}" ] || continue
        url="$(core_pkg_url "${project}" "${token}" "${archmode}")"
        # 用 URL 真实文件名(含 arch/all 前缀,天然唯一)。不能用 linux-${token}.tar.gz:
        # UI 与 core 共用 token "nimoos",会写到同一文件;再叠加 wget -c 续传语义,
        # 后下载的 core(较小)会因"文件已存在且更大"被跳过,导致 core 二进制不更新。
        local fname; fname="$(basename "${url}")"
        Show 2 "下载 ${url}"
        GreyStart
        ${sudo_cmd} wget -t 3 -q --show-progress -O "${TMP_DIR}/${fname}" "${url}" \
            || Show 1 "下载失败: ${url}"
        ColorReset
    done < <(core_components)

    # 2) 解包
    pushd "${TMP_DIR}" >/dev/null
    local f
    for f in linux-*.tar.gz; do
        Show 2 "解包 ${f}..."
        GreyStart
        ${sudo_cmd} tar zxf "${f}" || Show 1 "解包失败: ${f}"
        ColorReset
    done
    popd >/dev/null

    local BUILD_DIR
    BUILD_DIR=$(${sudo_cmd} realpath -e "${TMP_DIR}/build") || Show 1 "未找到 build 目录"

    # 3) 停止核心服务(只停在跑的)
    local SERVICE
    for SERVICE in "${NIMO_SERVICES[@]}"; do
        if ${sudo_cmd} systemctl --quiet is-active "${SERVICE}" 2>/dev/null; then
            Show 2 "停止 ${SERVICE}..."
            ${sudo_cmd} systemctl stop "${SERVICE}" || Show 3 "${SERVICE} 不存在(忽略)。"
        fi
    done

    # 4) migration 脚本(版本间的数据/schema 迁移)
    local MIGRATION_SCRIPT_DIR="${BUILD_DIR}/scripts/migration/script.d"
    if [ -d "${MIGRATION_SCRIPT_DIR}" ]; then
        local MIGRATION_SCRIPT
        for MIGRATION_SCRIPT in "${MIGRATION_SCRIPT_DIR}"/*.sh; do
            if [ -f "${MIGRATION_SCRIPT}" ]; then
                chmod +x "${MIGRATION_SCRIPT}"
                Show 2 "运行迁移 ${MIGRATION_SCRIPT}..."
                ${sudo_cmd} "${MIGRATION_SCRIPT}" || Show 1 "迁移失败: ${MIGRATION_SCRIPT}"
            fi
        done
    fi

    # 5) 覆盖 sysroot 到 /
    local SYSROOT_DIR
    SYSROOT_DIR=$(realpath -e "${BUILD_DIR}/sysroot") || Show 1 "未找到 sysroot 目录"
    Show 2 "安装新版本文件..."
    GreyStart
    # 用 tar 铺到 /(usrmerge 系统上 /lib /bin 是指向 /usr/* 的符号链接,
    # cp -rf 会因"用目录覆盖符号链接"失败;--keep-directory-symlink 顺着合并)
    ${sudo_cmd} tar -cf - -C "${SYSROOT_DIR}" . | ${sudo_cmd} tar -C / --keep-directory-symlink -xf - \
        || Show 1 "安装失败"
    ${sudo_cmd} systemctl daemon-reload || Show 3 "daemon-reload 失败(忽略)。"
    ColorReset

    # 6) setup 脚本(文件已就位后再跑)
    local SETUP_SCRIPT_DIR="${BUILD_DIR}/scripts/setup/script.d"
    if [ -d "${SETUP_SCRIPT_DIR}" ]; then
        local SETUP_SCRIPT
        for SETUP_SCRIPT in "${SETUP_SCRIPT_DIR}"/*.sh; do
            if [ -f "${SETUP_SCRIPT}" ]; then
                chmod +x "${SETUP_SCRIPT}"
                Show 2 "运行 ${SETUP_SCRIPT}..."
                ${sudo_cmd} "${SETUP_SCRIPT}" || Show 1 "运行失败: ${SETUP_SCRIPT}"
            fi
        done
    fi

    # 7) 不再单独遍历 service.d:script.d 的 NN-setup-<svc>.sh 分发器(步骤6)已按
    #    /etc/os-release 调用正确 OS 的 service.d/<svc>/<os>/setup-<svc>.sh。再 find
    #    整个 service.d 会把每个服务的 debian/arch/ubuntu 变体全部重复执行(在 Debian
    #    上跑 Arch 脚本),还会让 Photos ML(~443MB)被重复下载。故此处刻意省略。

    # 7.5) 确保终端依赖(tmux/ttyd)就位——更新引入 terminal 组件时需要
    Ensure_Terminal_Deps

    # 8) enable + 重启核心服务
    for SERVICE in "${NIMO_SERVICES[@]}"; do
        ${sudo_cmd} systemctl enable "${SERVICE}" 2>/dev/null || true
        Show 2 "启动 ${SERVICE}..."
        ${sudo_cmd} systemctl start "${SERVICE}" 2>/dev/null || Show 3 "${SERVICE} 不存在(忽略)。"
    done

    # 9) 清理
    ${sudo_cmd} rm -rf "${TMP_DIR}"
    Show 0 "核心更新完成。"
}

###############################################################################
# Stack update (qdrant / parser / search / wiki / photos / ai)                #
###############################################################################
Update_Stack() {
    Show 2 "更新检索/AI 栈(qdrant/parser/search/wiki/photos/ai)"
    Show 3 "  (幂等: 已存在的模型/venv 复用,不重复下载 ~3GB)"
    local SCRIPT_DIR stack_sh
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/tmp")"

    # 本地有兄弟脚本(开发机/解包目录)就用本地,否则从 OSS get/ 拉
    if [ -f "${SCRIPT_DIR}/scripts/nimoos-stack-install.sh" ]; then
        stack_sh="${SCRIPT_DIR}/scripts/nimoos-stack-install.sh"
    elif [ -f "${SCRIPT_DIR}/nimoos-stack-install.sh" ]; then
        stack_sh="${SCRIPT_DIR}/nimoos-stack-install.sh"
    else
        stack_sh="${TMP_ROOT}/nimoos-stack-install.sh"
        ${sudo_cmd} mkdir -p "${TMP_ROOT}"
        if ! ${sudo_cmd} curl -fsSL "${NIMO_DOWNLOAD_DOMAIN}get/nimoos-stack-install.sh" -o "${stack_sh}"; then
            Show 3 "下载栈安装器失败,跳过栈更新(核心已更新)。"
            return
        fi
    fi

    # 透传版本 + 启动 + 遇错继续;栈失败不致命(核心已更新)。
    # 注意:不要写 `${sudo_cmd} STACK_VERSION=val bash ...`——root 下 sudo_cmd 为空时,
    # bash 在展开前已把首词当命令名,VAR=val 会被当成参数;空前缀移除后 VAR=val 反而
    # 成了命令名 → "command not found"。--version 已在栈脚本内 export STACK_VERSION。
    if ${sudo_cmd} bash "${stack_sh}" --version "${NIMO_UPDATE_VERSION}" --start --continue; then
        Show 0 "栈更新完成。"
    else
        Show 3 "栈更新报告了错误(非致命);核心已更新。"
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

[[ "${UNAME_U}" == *Linux* ]] || Show 1 "本脚本仅支持 Linux。"
Check_Arch

[[ "${DO_CORE}" == "1" ]]  && Update_Core  || Show 3 "跳过核心更新(--only-stack)。"
[[ "${DO_STACK}" == "1" ]] && Update_Stack || Show 3 "跳过栈更新(--only-core / NIMO_SKIP_STACK=1)。"

echo ""
Show 0 "NimoOS 已更新到 ${NIMO_UPDATE_VERSION}。"
if command -v nimoos >/dev/null 2>&1; then
    Show 2 "当前核心版本: $(nimoos -v 2>/dev/null || echo unknown)"
fi
