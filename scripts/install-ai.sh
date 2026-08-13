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
AGENT_GHCR_IMAGE="ghcr.io/nimotech/nimoos-agent"

# Shared tail of both install paths: retire the old host-venv unit, then run the
# bundle's own install.sh (docker load if an image tar is present, compose up,
# health wait) from the staged directory.
deploy_agent_stage() {
    local stage="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q '^nimoos-agent\.service'; then
        log_info "Disabling the old nimoos-agent.service; the container takes over ..."
        ${sudo_cmd} systemctl disable --now nimoos-agent.service 2>/dev/null || true
    fi
    log_info "Deploying the Agent container via ${stage}/install.sh ..."
    ${sudo_cmd} bash "${stage}/install.sh"
}

# GHCR fast path: docker pull the image (layer-incremental on upgrades) plus the
# few-KB compose tarball, instead of the ~1GB docker-save bundle. Every failure
# returns 1 and the caller falls back to the S3 bundle — this path must never be
# the reason an install fails. The manifest probe up front matters twice over:
# ghcr.io is unreachable from most mainland-China networks, and releases before
# v1.9.5 were never pushed there; both must bail in seconds, not sit in a
# docker pull. NIMO_AGENT_NO_GHCR=1 skips the attempt entirely.
try_agent_ghcr() {
    [ "${NIMO_AGENT_NO_GHCR:-0}" = "1" ] && { log_info "NIMO_AGENT_NO_GHCR=1: skipping the GHCR fast path."; return 1; }
    local tag="${AGENT_BUNDLE_VERSION}"
    local image="${AGENT_GHCR_IMAGE}:${tag}"

    # Anonymous existence probe: two small capped HTTPS requests (no jq on a
    # fresh machine, hence sed).
    local tok
    tok="$(curl -sf -m 10 "https://ghcr.io/token?scope=repository:nimotech/nimoos-agent:pull" \
             | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')" || tok=""
    [ -n "${tok}" ] || { log_info "ghcr.io not reachable; using the S3 bundle."; return 1; }
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
              -H "Authorization: Bearer ${tok}" \
              -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
              "https://ghcr.io/v2/nimotech/nimoos-agent/manifests/${tag}")" || code=""
    [ "${code}" = "200" ] || { log_info "GHCR has no ${image} (HTTP ${code:-none}); using the S3 bundle."; return 1; }

    log_info "Pulling ${image} (GHCR fast path) ..."
    if ! ${sudo_cmd} timeout 900 docker pull "${image}"; then
        log_warn "docker pull ${image} failed; falling back to the S3 bundle."
        return 1
    fi

    # compose + install.sh travel in a tiny tarball next to the full bundle on S3.
    local curl_url="${NIMO_DOWNLOAD_DOMAIN}${NIMO_KEY_PREFIX}/${AGENT_BUNDLE_PROJECT}/releases/download/agent-${AGENT_BUNDLE_VERSION}/nimoos-agent-compose-${AGENT_BUNDLE_VERSION}.tar.gz"
    local ctar; ctar="$(mktemp)"
    if ! curl -fSL --retry 3 --connect-timeout 10 -m 120 -o "${ctar}" "${curl_url}"; then
        rm -f "${ctar}"
        log_warn "compose tarball download failed: ${curl_url}; falling back to the S3 bundle."
        return 1
    fi
    local stage; stage="$(mktemp -d)"
    tar -xzf "${ctar}" -C "${stage}"
    rm -f "${ctar}"

    # The compose file expects the image under this name (pull_policy: never),
    # and the bundle's install.sh accepts it as pre-loaded; tagging the pulled
    # image satisfies both without a docker load.
    ${sudo_cmd} docker tag "${image}" "localhost/nimoos-agent:bundled"

    deploy_agent_stage "${stage}"
    rm -rf "${stage}"
    log_ok "Agent container deployed (image pulled from GHCR)."
    return 0
}

setup_agent() {
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "docker is not installed, skipping the Agent container (the core install stage should have provided it)."
        return 0
    fi

    # Development: use the bundle already built in the repository if present,
    # then try the GHCR fast path, otherwise download the agent-<ver> bundle
    local bundle_tar=""
    local local_bundle="${SCRIPT_DIR}/../../NimoOS-AI/dist/nimoos-agent-${AGENT_BUNDLE_VERSION}.tar.gz"
    if [ -f "${local_bundle}" ]; then
        bundle_tar="${local_bundle}"
        log_info "Agent bundle (local): ${bundle_tar}"
    else
        if try_agent_ghcr; then return 0; fi
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

    deploy_agent_stage "${stage}"
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
