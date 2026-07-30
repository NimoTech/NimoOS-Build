#!/usr/bin/env bash
###############################################################################
# NimoOS 发布脚本 —— 共享库
#
# 提供:配置加载、组件注册表、日志、架构映射、ossutil 封装。
# 被 release.sh / sync-install-script.sh 通过 `source` 引入。
###############################################################################

# ---------------------------------------------------------------------------
# 路径定位 (不依赖调用时的工作目录)
# ---------------------------------------------------------------------------
# RELEASE_DIR  = 本目录 (NimoOS-Build/release)
# DOCS_DIR     = 仓库根 (NimoOS-Build)
# WORKSPACE_ROOT = 仓库根目录 (各 NimoOS-* 子项目所在处)
RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$(cd "${RELEASE_DIR}/.." && pwd)"
# 允许通过环境变量覆盖源码工作区(在 Debian 机器上目录结构可能不同)
WORKSPACE_ROOT="${NIMO_WORKSPACE_ROOT:-$(cd "${DOCS_DIR}/.." && pwd)}"

VERSIONS_FILE="${RELEASE_DIR}/versions.conf"
INSTALL_SCRIPT="${DOCS_DIR}/nimoos-install.sh"

# ---------------------------------------------------------------------------
# 颜色与日志
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'
    C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

log_info()  { echo -e "${C_BLUE}==>${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_err()   { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
log_step()  { echo -e "\n${C_CYAN}========== $* ==========${C_RESET}"; }
die()       { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 配置加载与校验
# ---------------------------------------------------------------------------
load_versions() {
    [ -f "${VERSIONS_FILE}" ] || die "找不到版本文件: ${VERSIONS_FILE}"

    # NIMOOS_VERSION_OVERRIDE 让调用方(CI 的 tag 构建)指定版本, 而不必就地改写
    # versions.conf。用进程替换重新 source, 使 VERSION_* 这些派生值一并重算;
    # VERSION_APPSTORE / VERSION_INSTALLER / TTYD_VERSION 不派生, 保持原值。
    # versions.conf 一旦迁入公开仓, 私有 CI 就不该再去写它 —— 这是那条依赖的解法。
    if [ -n "${NIMOOS_VERSION_OVERRIDE:-}" ]; then
        # shellcheck source=/dev/null
        source <(sed 's/^NIMOOS_VERSION=.*/NIMOOS_VERSION="'"${NIMOOS_VERSION_OVERRIDE}"'"/' "${VERSIONS_FILE}")
        [ "${NIMOOS_VERSION}" = "${NIMOOS_VERSION_OVERRIDE}" ] \
            || die "版本覆盖失败: 期望 ${NIMOOS_VERSION_OVERRIDE}, 实得 ${NIMOOS_VERSION}"
    else
        # shellcheck source=/dev/null
        source "${VERSIONS_FILE}"
    fi

    local required=(OSS_BUCKET OSS_ENDPOINT OSS_PREFIX DOWNLOAD_DOMAIN)
    local key
    for key in "${required[@]}"; do
        [ -n "${!key}" ] || die "版本文件缺少必需配置: ${key}"
    done
}

# 校验下载域名与上传 bucket/endpoint 同区 (强制走深圳, 避免上传与安装走不同区)
assert_same_region() {
    case "${OSS_ENDPOINT}" in
        oss-cn-shenzhen.aliyuncs.com) ;;
        *) log_warn "OSS_ENDPOINT=${OSS_ENDPOINT} 不是深圳 endpoint" ;;
    esac
    case "${DOWNLOAD_DOMAIN}" in
        *oss-cn-shenzhen.aliyuncs.com*) ;;
        *) die "DOWNLOAD_DOMAIN=${DOWNLOAD_DOMAIN} 与深圳 endpoint 不一致, 上传与安装会走不同区!" ;;
    esac
}

# ---------------------------------------------------------------------------
# 组件注册表
# 字段 (以 | 分隔):
#   key          : 命令行 --only 使用的短名
#   source_dir   : 源码目录 (相对 WORKSPACE_ROOT)
#   project      : OSS 路径中的项目名 (NimoTech/<project>/...)
#   type         : go (需编译) | static (仅打包 build 目录) | python (parser 选择性源码包) | pyagent (打包整个 agent 子目录) | script (调用项目内打包脚本)
#   arch_mode    : arch (按目标架构) | all (架构无关, linux-all)
#   bin_name     : go=编译产物在 sysroot/usr/bin 下的名字; script=项目内打包脚本名; static/python=-
#   token        : tar 包名中的组件标识 linux-<arch>-<token>-<ver>.tar.gz
#   version_var  : 在 versions.conf 中对应的变量名
#   migration    : 1=该组件含 cmd/migration-tool, 需额外构建上传迁移工具包; 0=否
#
# 顺序与安装脚本 NIMO_PACKAGES 一致 (nimoos 核心放最后)。
# ---------------------------------------------------------------------------
component_registry() {
    cat <<'EOF'
gateway|NimoOS-Gateway|NimoOS-Gateway|go|arch|nimoos-gateway|nimoos-gateway|VERSION_GATEWAY|1
messagebus|NimoOS-MessageBus|NimoOS-MessageBus|go|arch|nimoos-message-bus|nimoos-message-bus|VERSION_MESSAGEBUS|1
userservice|NimoOS-UserService|NimoOS-UserService|go|arch|nimoos-user-service|nimoos-user-service|VERSION_USERSERVICE|1
localstorage|NimoOS-LocalStorage|NimoOS-LocalStorage|go|arch|nimoos-local-storage|nimoos-local-storage|VERSION_LOCALSTORAGE|1
appmanagement|NimoOS-AppManagement|NimoOS-AppManagement|go|arch|nimoos-app-management|nimoos-app-management|VERSION_APPMANAGEMENT|1
cli|NimoOS-CLI|NimoOS-CLI|go|arch|nimoos-cli|nimoos-cli|VERSION_CLI|0
ai|NimoOS-AI|NimoOS-AI|go|arch|nimoos-ai|nimoos-ai|VERSION_AI|0
wiki|NimoOS-Wiki|NimoOS-Wiki|go|arch|nimoos-wiki|nimoos-wiki|VERSION_WIKI|0
search|NimoOS-Search|NimoOS-Search|go|arch|nimoos-search|nimoos-search|VERSION_SEARCH|0
photos|NimoOS-Photos|NimoOS-Photos|go|arch|nimoos-photos|nimoos-photos|VERSION_PHOTOS|0
terminal|NimoOS-Terminal|NimoOS-Terminal|go|arch|nimoos-terminal|nimoos-terminal|VERSION_TERMINAL|0
parser|NimoOS-Parser|NimoOS-Parser|python|all|-|nimoos-parser|VERSION_PARSER|0
aiagent|NimoOS-AI|NimoOS-AI|dockeragent|all|-|nimoos-agent|VERSION_AIAGENT|0
ui|NimoOS-UI|NimoOS-UI|static|all|-|nimoos|VERSION_UI|0
appstore|NimoOS-AppStore|NimoOS-AppStore|script|all|package_appstore.sh|appstore|VERSION_APPSTORE|0
core|NimoOS|NimoOS|go|arch|nimoos|nimoos|VERSION_CORE|1
EOF
}

# 根据 key 取出注册表中某一行 (找不到返回非 0)
registry_line() {
    local want="$1"
    component_registry | awk -F'|' -v k="$want" '$1==k {print; found=1} END{exit !found}'
}

# 所有组件 key
all_component_keys() {
    component_registry | awk -F'|' '{print $1}'
}

# ---------------------------------------------------------------------------
# 架构映射: 目标架构 -> GOARCH / GOARM / 交叉编译器 CC
# 与各项目 .goreleaser.yaml 保持一致
# ---------------------------------------------------------------------------
arch_to_goarch() {
    case "$1" in
        amd64)   echo "amd64" ;;
        arm64)   echo "arm64" ;;
        arm-7)   echo "arm" ;;
        riscv64) echo "riscv64" ;;
        *) return 1 ;;
    esac
}
arch_to_goarm() { [ "$1" = "arm-7" ] && echo "7" || echo ""; }
arch_to_cc() {
    case "$1" in
        amd64)   echo "x86_64-linux-gnu-gcc" ;;
        arm64)   echo "aarch64-linux-gnu-gcc" ;;
        arm-7)   echo "arm-linux-gnueabihf-gcc" ;;
        riscv64) echo "riscv64-linux-gnu-gcc" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# ossutil 定位
# ---------------------------------------------------------------------------
resolve_ossutil() {
    if [ -n "${OSSUTIL_BIN:-}" ] && [ -x "${OSSUTIL_BIN:-}" ]; then
        echo "${OSSUTIL_BIN}"; return 0
    fi
    if [ -x "${WORKSPACE_ROOT}/bin/ossutil" ]; then
        echo "${WORKSPACE_ROOT}/bin/ossutil"; return 0
    fi
    if command -v ossutil >/dev/null 2>&1; then
        command -v ossutil; return 0
    fi
    return 1
}

# 用 OSS 公网 url 计算对应的 oss:// 上传地址
# 路径规则: oss://<bucket>/<prefix>/<project>/releases/download/<ver>/<file>
oss_target_url() {
    local project="$1" version="$2" file="$3"
    echo "oss://${OSS_BUCKET}/${OSS_PREFIX}/${project}/releases/download/${version}/${file}"
}
