#!/usr/bin/env bash
# install-ai.sh — Install Ollama and NimoOS Agent (container bundle)
# Usage: sudo bash install-ai.sh [--ollama-only]
#
# Installs Ollama from an offline OSS bundle, then deploys the NimoOS Agent
# as a Docker container (offline image tarball + compose).  No host Python
# venv or apt python packages are required.
#
#   --ollama-only   只装 Ollama, 不动 Agent。供 build install.sh 补栈用:
#                   agent 已由 install.sh 自己部署(本地离线镜像包, 且能识别
#                   host venv 形态), 这里再跑 setup_agent 会重复下 300MB 包、
#                   还会把 host 形态机器的 nimoos-agent.service 停掉。

set -e

((EUID)) && sudo_cmd="sudo"

OLLAMA_ONLY=0
for arg in "$@"; do
    case "${arg}" in
        --ollama-only) OLLAMA_ONLY=1 ;;
    esac
done

AGENT_INSTALL_DIR="/usr/share/nimoos/agent"
AGENT_DATA_DIR="/var/lib/nimoos/ai/agent"
SERVICE_NAME="nimoos-agent"
SERVICE_FILE="/usr/lib/systemd/system/nimoos-agent.service"

# Find source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack-fetch.sh
source "${SCRIPT_DIR}/lib/stack-fetch.sh"

###############################################################################
# Helpers
###############################################################################

log_info()  { echo -e "\e[32m[ INFO ]\e[0m $*"; }
log_ok()    { echo -e "\e[32m[  OK  ]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[ WARN ]\e[0m $*"; }
log_fail()  { echo -e "\e[31m[FAILED]\e[0m $*"; exit 1; }

###############################################################################
# 1. Install Ollama
###############################################################################

install_ollama() {
    if [ -x "$(command -v ollama)" ] || [ -x /usr/local/bin/ollama ]; then
        log_ok "Ollama already installed: $(/usr/local/bin/ollama --version 2>/dev/null | head -1 || echo 'present')"
        return
    fi

    # 从 OSS deps/ 下官方 bundle 解包安装,而不是 `curl ollama.com/install.sh | sh`
    # —— 后者在无法直连 ollama.com 的机器(国内 NAS)上会卡死/超时。
    # bundle 布局:bin/ollama + lib/ollama/...,解到 /usr/local 即得
    # /usr/local/bin/ollama 与 /usr/local/lib/ollama(二进制按相对路径找运行库)。
    log_info "Installing Ollama from OSS deps (offline-friendly, skips ollama.com)..."

    local arch
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_fail "Ollama: unsupported arch $(uname -m)" ;;
    esac
    local tarfile="ollama-linux-${arch}.tar.zst"
    local url="${NIMO_DEPS_BASE}/ollama/${tarfile}"

    # .tar.zst 需要 zstd 才能解
    if ! command -v zstd >/dev/null 2>&1; then
        log_info "Installing zstd (needed to unpack the ollama bundle)..."
        if [ -x "$(command -v apt-get)" ]; then
            ${sudo_cmd} apt-get update -qq || true
            ${sudo_cmd} apt-get install -y zstd || true
        fi
    fi
    command -v zstd >/dev/null 2>&1 || log_fail "zstd unavailable; cannot unpack ${tarfile}"

    local tmp; tmp="$(mktemp)"
    log_info "Downloading ${url} ..."
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"
        log_fail "Ollama bundle download failed: ${url}"
    fi
    # 安装前缀可配置:NAS 的 /usr/local 常在很小的 overlay 根分区上,而 ollama
    # bundle 含 GPU 库解压后数 GB,塞进去会撑爆根分区。可设 NIMO_OLLAMA_PREFIX=/opt/ollama
    # 把它放到大盘。二进制按相对路径 ../lib/ollama 找运行库,故 bin/ 与 lib/ 同前缀即可。
    local prefix="${NIMO_OLLAMA_PREFIX:-/usr/local}"
    log_info "Unpacking → ${prefix} ..."
    ${sudo_cmd} mkdir -p "${prefix}"
    ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${prefix}"
    rm -f "${tmp}"
    local ollama_bin="${prefix}/bin/ollama"
    [ -x "${ollama_bin}" ] || log_fail "未在 ${ollama_bin} 找到二进制(bundle 布局异常)"
    # 非默认前缀时,在 /usr/local/bin 放个软链,保证 `ollama` 命令在 PATH 上
    if [ "${prefix}" != "/usr/local" ]; then
        ${sudo_cmd} ln -sf "${ollama_bin}" /usr/local/bin/ollama
    fi

    # ollama 系统用户/组(与官方 install.sh 一致)
    getent group ollama >/dev/null 2>&1 || ${sudo_cmd} groupadd -r ollama
    id ollama >/dev/null 2>&1 || \
        ${sudo_cmd} useradd -r -s /bin/false -g ollama -d /usr/share/ollama ollama
    ${sudo_cmd} mkdir -p /usr/share/ollama
    ${sudo_cmd} chown ollama:ollama /usr/share/ollama

    # systemd unit(只监听 127.0.0.1,与 NimoOS 各服务绑 localhost 的约定一致)
    ${sudo_cmd} tee /etc/systemd/system/ollama.service >/dev/null <<UNIT
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${ollama_bin} serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_HOST=127.0.0.1:11434"

[Install]
WantedBy=multi-user.target
UNIT
    ${sudo_cmd} systemctl daemon-reload
    # Enable but don't start yet — user can pull models after
    ${sudo_cmd} systemctl enable ollama 2>/dev/null || true
    log_ok "Ollama installed from OSS."
}

###############################################################################
# 2. 部署 Agent 容器(离线镜像包 + compose),取代旧的 host venv 安装
###############################################################################

AGENT_BUNDLE_PROJECT="NimoOS-AI"
AGENT_BUNDLE_VERSION="${STACK_VERSION_AIAGENT:-${STACK_VERSION}}"

setup_agent() {
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "docker 未安装,跳过 Agent 容器部署(核心安装阶段应已装 docker)。"
        return 0
    fi

    # 本地开发:仓库内已有打好的包则用之;否则从 OSS 下 agent-<ver> 包
    local bundle_tar=""
    local local_bundle="${SCRIPT_DIR}/../../NimoOS-AI/dist/nimoos-agent-${AGENT_BUNDLE_VERSION}.tar.gz"
    if [ -f "${local_bundle}" ]; then
        bundle_tar="${local_bundle}"
        log_info "Agent 包(本地): ${bundle_tar}"
    else
        local url="${NIMO_DOWNLOAD_DOMAIN}${NIMO_OSS_PREFIX}/${AGENT_BUNDLE_PROJECT}/releases/download/agent-${AGENT_BUNDLE_VERSION}/nimoos-agent-${AGENT_BUNDLE_VERSION}.tar.gz"
        bundle_tar="$(mktemp)"
        log_info "下载 Agent 离线包: ${url}"
        if ! curl -fSL --retry 3 --connect-timeout 10 -o "${bundle_tar}" "${url}"; then
            rm -f "${bundle_tar}"
            log_fail "Agent 离线包下载失败: ${url}"
        fi
    fi

    local stage; stage="$(mktemp -d)"
    tar -xzf "${bundle_tar}" -C "${stage}"
    [[ "${bundle_tar}" == /tmp/* ]] && rm -f "${bundle_tar}"

    # 停用旧的 host venv systemd unit(若存在),交给 compose 接管
    if systemctl list-unit-files 2>/dev/null | grep -q '^nimoos-agent\.service'; then
        log_info "停用旧 nimoos-agent.service(改由容器接管)..."
        ${sudo_cmd} systemctl disable --now nimoos-agent.service 2>/dev/null || true
    fi

    log_info "部署 Agent 容器(${stage}/install.sh)..."
    ${sudo_cmd} bash "${stage}/install.sh"
    rm -rf "${stage}"
    log_ok "Agent 容器已部署。"
}

###############################################################################
# Main
###############################################################################

log_info "=== NimoOS AI Services Installer ==="
install_ollama
if [ "${OLLAMA_ONLY}" = "1" ]; then
    log_ok "--ollama-only: 跳过 Agent 部署。"
else
    setup_agent
fi

echo ""
log_ok "Installation complete."
echo ""
echo "  Next steps:"
echo "  1. Pull an Ollama model:      ollama pull qwen2.5:7b"
echo "  2. Start all AI services:     sudo bash $(dirname "$0")/start-ai.sh"
echo "  3. Check status:              sudo bash $(dirname "$0")/start-ai.sh status"
