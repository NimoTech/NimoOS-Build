#!/usr/bin/env bash
# install-ai.sh — Install Ollama and NimoOS Agent (container bundle)
# Usage: sudo bash install-ai.sh [--ollama-only]
#
# Installs Ollama from an offline bundle on the dependency mirror, then deploys
# the NimoOS Agent as a Docker container (offline image tarball plus compose).
# No host Python venv or apt python packages are required.
#
#   --ollama-only   Install Ollama only, leaving the Agent alone. This is what
#                   the build's install.sh uses when filling in the stack: it has
#                   already deployed the agent itself, from a local offline image
#                   and in a way that recognises a host-venv layout. Running
#                   setup_agent again would re-download the 300MB bundle and stop
#                   nimoos-agent.service on host-layout machines.

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

    # Unpack the official bundle from the deps/ mirror rather than running
    # `curl ollama.com/install.sh | sh`, which hangs or times out on machines
    # with no direct route to ollama.com.
    # Bundle layout is bin/ollama plus lib/ollama/..., so unpacking into
    # /usr/local yields /usr/local/bin/ollama and /usr/local/lib/ollama — the
    # binary finds its runtime libraries by relative path.
    log_info "Installing Ollama from the dependency mirror (offline-friendly, skips ollama.com)..."

    local arch
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_fail "Ollama: unsupported arch $(uname -m)" ;;
    esac
    local tarfile="ollama-linux-${arch}.tar.zst"
    local url="${NIMO_DEPS_BASE}/ollama/${tarfile}"

    # .tar.zst needs zstd to unpack
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
    # The install prefix is configurable. On a NAS /usr/local often sits on a
    # small overlay root partition, while the ollama bundle unpacks to several GB
    # once the GPU libraries are included — enough to fill that partition. Set
    # NIMO_OLLAMA_PREFIX=/opt/ollama to put it on a larger disk. The binary
    # resolves its runtime libraries via the relative path ../lib/ollama, so bin/
    # and lib/ only need to share a prefix.
    local prefix="${NIMO_OLLAMA_PREFIX:-/usr/local}"
    log_info "Unpacking → ${prefix} ..."
    ${sudo_cmd} mkdir -p "${prefix}"
    ${sudo_cmd} tar --zstd -xf "${tmp}" -C "${prefix}"
    rm -f "${tmp}"
    local ollama_bin="${prefix}/bin/ollama"
    [ -x "${ollama_bin}" ] || log_fail "no binary at ${ollama_bin} (unexpected bundle layout)"
    # For a non-default prefix, symlink into /usr/local/bin so `ollama` stays on PATH
    if [ "${prefix}" != "/usr/local" ]; then
        ${sudo_cmd} ln -sf "${ollama_bin}" /usr/local/bin/ollama
    fi

    # The ollama system user and group, matching the official install.sh
    getent group ollama >/dev/null 2>&1 || ${sudo_cmd} groupadd -r ollama
    id ollama >/dev/null 2>&1 || \
        ${sudo_cmd} useradd -r -s /bin/false -g ollama -d /usr/share/ollama ollama
    ${sudo_cmd} mkdir -p /usr/share/ollama
    ${sudo_cmd} chown ollama:ollama /usr/share/ollama

    # systemd unit. Listens on 127.0.0.1 only, as every NimoOS service does.
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
    log_ok "Ollama installed from the dependency mirror."
}

###############################################################################
# 2. Deploy the Agent container (offline image plus compose), replacing the
#    older host-venv installation
###############################################################################

AGENT_BUNDLE_PROJECT="NimoOS-AI"
AGENT_BUNDLE_VERSION="${STACK_VERSION_AIAGENT:-${STACK_VERSION}}"

setup_agent() {
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "docker is not installed, skipping the Agent container (the core install stage should have provided it)."
        return 0
    fi

    # Development: use the bundle already built in the repository if present,
    # otherwise download the agent-<ver> bundle
    local bundle_tar=""
    local local_bundle="${SCRIPT_DIR}/../../NimoOS-AI/dist/nimoos-agent-${AGENT_BUNDLE_VERSION}.tar.gz"
    if [ -f "${local_bundle}" ]; then
        bundle_tar="${local_bundle}"
        log_info "Agent bundle (local): ${bundle_tar}"
    else
        local url="${NIMO_DOWNLOAD_DOMAIN}${NIMO_KEY_PREFIX}/${AGENT_BUNDLE_PROJECT}/releases/download/agent-${AGENT_BUNDLE_VERSION}/nimoos-agent-${AGENT_BUNDLE_VERSION}.tar.gz"
        bundle_tar="$(mktemp)"
        log_info "Downloading the Agent offline bundle: ${url}"
        if ! curl -fSL --retry 3 --connect-timeout 10 -o "${bundle_tar}" "${url}"; then
            rm -f "${bundle_tar}"
            log_fail "Agent offline bundle download failed: ${url}"
        fi
    fi

    local stage; stage="$(mktemp -d)"
    tar -xzf "${bundle_tar}" -C "${stage}"
    [[ "${bundle_tar}" == /tmp/* ]] && rm -f "${bundle_tar}"

    # Disable the old host-venv systemd unit if present; compose takes over
    if systemctl list-unit-files 2>/dev/null | grep -q '^nimoos-agent\.service'; then
        log_info "Disabling the old nimoos-agent.service; the container takes over ..."
        ${sudo_cmd} systemctl disable --now nimoos-agent.service 2>/dev/null || true
    fi

    log_info "Deploying the Agent container via ${stage}/install.sh ..."
    ${sudo_cmd} bash "${stage}/install.sh"
    rm -rf "${stage}"
    log_ok "Agent container deployed."
}

###############################################################################
# Main
###############################################################################

log_info "=== NimoOS AI Services Installer ==="
install_ollama
if [ "${OLLAMA_ONLY}" = "1" ]; then
    log_ok "--ollama-only: skipping the Agent deployment."
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
