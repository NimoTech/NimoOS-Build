#!/usr/bin/env bash
# nimoos-stack-install.sh — 一键安装 NimoOS 检索 / AI 栈及其依赖
#
# 按【依赖顺序】编排调用各 install-*.sh:
#   qdrant → parser → search → wiki → photos → ai
#
# 每个子脚本自带「双模式」:本机有对应 NimoOS-* 源码就用源码,否则从深圳 OSS
# 拉对应版本的 release tar(版本由 STACK_VERSION 统一注入)。
#
# 用法:
#   sudo bash nimoos-stack-install.sh [选项]
#
# 选项:
#   --start              安装后立即启动支持的服务(parser/search/wiki/photos)
#   --only a,b,c         只装这些组件(逗号分隔, key 见下)
#   --skip a,b           跳过这些组件
#   --version <ver>      指定版本(默认 v1.9.1-alpha1),透传给各子脚本
#   --continue           某组件失败后继续装后续组件(默认遇错即停)
#   -h | --help          显示帮助
#
# 组件 key:qdrant parser search wiki photos ai
#
# 说明:
#   - qdrant 是检索栈基座,parser/search 依赖它先就绪。
#   - ai 装 Ollama + Python Agent;装完需 `ollama pull <model>` 再 start-ai.sh。
#   - Photos 仅装主二进制,AI/ML 后端为单独步骤。

set -uo pipefail

# 经 `curl | bash -s` 从 stdin 运行时 BASH_SOURCE 为空,set -u 下会报 unbound;
# 用 ${BASH_SOURCE[0]:-$0} 兜底(此时无本地子脚本,后续 bootstrap 会从 OSS 拉)。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/tmp")"

((EUID)) && sudo_hint="(建议 sudo 运行)" || sudo_hint=""

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
START=0
CONTINUE=0
ONLY=""
SKIP=""
export STACK_VERSION="${STACK_VERSION:-v1.9.0-alpha1}"

usage() { sed -n '2,33p' "$0"; exit "${1:-0}"; }

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
        *) echo "未知参数: $1 (用 --help 查看)"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
C_RESET='\e[0m'; C_GREEN='\e[32m'; C_YELLOW='\e[33m'; C_RED='\e[31m'; C_CYAN='\e[36m'
log_info() { echo -e "${C_GREEN}[ INFO ]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*"; }
log_err()  { echo -e "${C_RED}[FAILED]${C_RESET} $*"; }
log_step() { echo -e "\n${C_CYAN}========== $* ==========${C_RESET}"; }

# 全程把 stdout/stderr 同时送终端与日志文件,避免安装失败后无从复盘
# (此前一键安装是静默的,某组件卡死/报错后什么都没留下)。
STACK_LOG=""
setup_logging() {
    local ts dir
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
    dir="/var/log/nimoos"
    mkdir -p "${dir}" 2>/dev/null || dir="${TMPDIR:-/tmp}"
    STACK_LOG="${dir}/stack-install-${ts}.log"
    exec > >(tee -a "${STACK_LOG}") 2>&1
    log_info "完整安装日志:${STACK_LOG}"
}

# ---------------------------------------------------------------------------
# 组件表(依赖顺序): key|脚本|是否支持 --start|描述
# ---------------------------------------------------------------------------
COMPONENTS=(
    "qdrant|install-qdrant.sh|0|向量库 qdrant(检索栈基座)"
    "parser|install-parser.sh|1|文档解析 Parser(Python, 依赖 qdrant)"
    "search|install-search.sh|1|检索 Search(依赖 parser + qdrant)"
    "wiki|install-wiki.sh|1|Wiki 服务"
    "photos|install-photos.sh|1|相册 Photos 主服务"
    "ai|install-ai.sh|0|Ollama + Python Agent"
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
# bootstrap:standalone(curl|bash)运行时本地没有兄弟脚本,从 OSS 拉取
# ---------------------------------------------------------------------------
: "${NIMO_SCRIPTS_BASE:=https://nimoos.oss-cn-shenzhen.aliyuncs.com/get/scripts}"
bootstrap_scripts() {
    [[ -f "${SCRIPT_DIR}/install-qdrant.sh" && -f "${SCRIPT_DIR}/lib/stack-fetch.sh" ]] && return 0
    local boot; boot="$(mktemp -d)"
    mkdir -p "${boot}/lib"
    log_info "未发现本地子脚本,从 OSS 拉取(${NIMO_SCRIPTS_BASE})..."
    local f
    for f in lib/stack-fetch.sh install-qdrant.sh install-parser.sh install-search.sh \
             install-wiki.sh install-photos.sh install-ai.sh start-ai.sh; do
        if ! curl -fsSL "${NIMO_SCRIPTS_BASE}/${f}" -o "${boot}/${f}"; then
            log_err "下载子脚本失败: ${f}"; rm -rf "${boot}"; exit 1
        fi
    done
    SCRIPT_DIR="${boot}"
    log_info "子脚本已就绪: ${SCRIPT_DIR}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
setup_logging
bootstrap_scripts
log_step "NimoOS 栈安装  ${sudo_hint}"
log_info "版本: ${STACK_VERSION}   start=${START}  continue=${CONTINUE}"
[[ -n "${ONLY}" ]] && log_info "仅安装: ${ONLY}"
[[ -n "${SKIP}" ]] && log_info "跳过:   ${SKIP}"

declare -a DONE=() FAILED=() SKIPPED=()

for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r key script supports_start desc <<< "${entry}"
    if ! selected "${key}"; then
        SKIPPED+=("${key}")
        continue
    fi
    local_script="${SCRIPT_DIR}/${script}"
    if [[ ! -f "${local_script}" ]]; then
        log_err "${key}: 找不到脚本 ${local_script}"
        FAILED+=("${key}")
        [[ "${CONTINUE}" == "1" ]] && continue || { log_err "中止(用 --continue 可跳过失败继续)"; break; }
    fi

    # 组装子脚本参数
    args=()
    [[ "${START}" == "1" && "${supports_start}" == "1" ]] && args+=("--start")

    log_step "[${key}] ${desc}"
    if bash "${local_script}" "${args[@]}"; then
        DONE+=("${key}")
    else
        log_err "${key} 安装失败 (exit=$?)"
        FAILED+=("${key}")
        if [[ "${CONTINUE}" != "1" ]]; then
            log_err "中止后续安装(用 --continue 可跳过失败继续)"
            break
        fi
    fi
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
log_step "安装汇总"
log_info "成功: ${DONE[*]:-(无)}"
[[ ${#SKIPPED[@]} -gt 0 ]] && log_warn "跳过: ${SKIPPED[*]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    log_err "失败: ${FAILED[*]}"
    echo ""
    echo "  排查:journalctl -u <服务名> -f ;单独重跑:bash ${SCRIPT_DIR}/install-<key>.sh"
    [[ -n "${STACK_LOG}" ]] && echo "  完整日志:${STACK_LOG}"
    exit 1
fi

echo ""
log_info "全部完成。后续:"
echo "  - AI:    ollama pull qwen2.5:7b  &&  sudo bash ${SCRIPT_DIR}/start-ai.sh"
echo "  - 检索:  确认 qdrant 在跑(127.0.0.1:6333),再 systemctl start nimoos-parser nimoos-search"
echo "  - Photos AI/ML 后端为单独部署步骤(本编排器未含)。"
