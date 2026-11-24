#!/usr/bin/env bash
# install-qdrant.sh — move qdrant from a docker container to a native systemd service
#
# Why:
#   - The Parser unit declares After=qdrant.service / Wants=qdrant.service, but
#     while qdrant runs as a bare `docker run` there is no such unit, so that
#     dependency is a no-op and parser can come up before qdrant after a reboot
#     and fail to connect.
#   - AppManagement lists the standalone container as if it were a user app,
#     which clutters the NAS UI.
#
# What it does:
#   - Downloads the qdrant binary (default v1.18.1, the same version as the
#     docker image currently in use)
#   - Installs it to /usr/local/bin/qdrant
#   - Writes /etc/qdrant/config.yaml (listens on 127.0.0.1 only, keeps using
#     the existing /opt/qdrant/storage data directory)
#   - Installs /usr/lib/systemd/system/qdrant.service
#   - Stops the old docker container without deleting it, so the migration can
#     be verified before `docker rm`
#   - Starts the service and checks ports 6333 / 6334
#
# On hosts whose GLIBC is too old for the native binary (Debian 12 ships 2.36,
# qdrant v1.10+ needs 2.38) it falls back to running the same qdrant version in
# docker, wrapped in the same qdrant.service unit — so the parser dependency and
# the data directory work identically either way.
#
# Usage:
#   sudo bash install-qdrant.sh [--version v1.18.1] [--tarball <path>] [--docker] [--remove-docker]
#
#   --version        install a different version
#   --tarball PATH   use a locally downloaded qdrant-*.tar.gz instead of fetching
#   --docker         skip the native path and use the docker engine even when
#                    the host GLIBC could run the native binary
#   --remove-docker  `docker rm` the old container once native qdrant is verified
#
# Data compatibility: same version plus same storage_path means the native
# service starts on the existing data as-is; no dump/restore needed.

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

QDRANT_VERSION="v1.18.1"
LOCAL_TARBALL=""
REMOVE_DOCKER=0
FORCE_DOCKER=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) QDRANT_VERSION="$2"; shift 2 ;;
        --tarball) LOCAL_TARBALL="$2"; shift 2 ;;
        --docker) FORCE_DOCKER=1; shift ;;
        --remove-docker) REMOVE_DOCKER=1; shift ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

###############################################################################
# Paths
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the dependency mirror base from stack-fetch.sh. Run standalone the lib
# may be missing, so fall back to the built-in default.
if [[ -f "${SCRIPT_DIR}/lib/stack-fetch.sh" ]]; then
    # shellcheck source=lib/stack-fetch.sh
    source "${SCRIPT_DIR}/lib/stack-fetch.sh"
fi
: "${NIMO_DOWNLOAD_DOMAIN:=https://get.nimotech.ai/}"
: "${NIMO_DEPS_BASE:=${NIMO_DOWNLOAD_DOMAIN%/}/deps}"

readonly SERVICE_FILE="qdrant.service"
readonly UNIT_DST="/usr/lib/systemd/system/${SERVICE_FILE}"
readonly BIN_DST="/usr/local/bin/qdrant"
readonly CONF_DIR="/etc/qdrant"
readonly CONF_FILE="${CONF_DIR}/config.yaml"
readonly STORAGE_DIR="/opt/qdrant/storage"
readonly SNAPSHOT_DIR="/opt/qdrant/snapshots"

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

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64)  TARBALL_ARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) TARBALL_ARCH="aarch64-unknown-linux-gnu" ;;
        *) log_fail "unsupported architecture: $m" ;;
    esac
    log_ok "architecture: $m -> $TARBALL_ARCH"
}

check_glibc() {
    # The -gnu builds of qdrant v1.10+ need GLIBC 2.38 or newer, and Debian 12
    # ships 2.36. On those systems the native binary cannot run at all, so the
    # decision is recorded here and main() takes the docker path instead of
    # installing something that dies on startup. This used to be a hard failure
    # telling the user to "stay on docker" — useless on a fresh machine where
    # there is no docker qdrant to stay on, and it meant a supported distribution
    # had no working route to a running qdrant through this script.
    NATIVE_OK=1
    local need="2.38"
    local have
    have="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$have" ]]; then
        log_warn "cannot determine the GLIBC version, assuming the native binary works (may fail)"
        return
    fi
    # true when have >= need
    if [[ "$(printf '%s\n%s' "$need" "$have" | sort -V | head -1)" != "$need" ]]; then
        log_warn "host GLIBC $have < $need: the native qdrant binary cannot run here (Debian 12 ships 2.36)"
        NATIVE_OK=0
        return
    fi
    log_ok "GLIBC $have >= $need"
}

# Docker fallback: same qdrant version, same data directory, same loopback-only
# exposure — but the engine runs in a container, wrapped in the same
# qdrant.service unit name the native path installs. That unit name is the whole
# point of this script (parser declares After=qdrant.service), so the fallback
# must provide it too, not a bare `docker run` that evaporates on reboot.
install_docker_qdrant() {
    command -v docker >/dev/null 2>&1 \
        || log_fail "host GLIBC is too old for the native qdrant binary and docker is not installed, so there is no way to run qdrant on this machine. Install docker (the NimoOS core installer does) and rerun."

    local image="qdrant/qdrant:${QDRANT_VERSION}"
    local docker_bin; docker_bin="$(command -v docker)"

    log_info "=== docker fallback: ${image} wrapped in ${SERVICE_FILE} ==="

    # Pull at install time so startup never blocks on the registry. On networks
    # that cannot reach docker.io, configure registry-mirrors in
    # /etc/docker/daemon.json first — the error below is the pull failing.
    if ! ${sudo_cmd} docker image inspect "${image}" >/dev/null 2>&1; then
        log_info "pulling ${image} (one-time) ..."
        ${sudo_cmd} docker pull "${image}" \
            || log_fail "could not pull ${image}. If this machine cannot reach docker.io, add a registry mirror to /etc/docker/daemon.json and rerun."
    fi
    log_ok "image present: ${image}"

    log_info "writing the systemd unit to $UNIT_DST"
    ${sudo_cmd} tee "$UNIT_DST" >/dev/null <<EOF
[Unit]
Description=Qdrant vector database (docker)
Documentation=https://qdrant.tech/documentation/
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=simple
# A leftover container from an unclean stop would make docker run fail on the
# duplicate name; remove it first ("-" ignores the error when there is none).
ExecStartPre=-${docker_bin} rm -f qdrant
# --pull=never: the image was pulled above; startup must not depend on the
# registry being reachable.
ExecStart=${docker_bin} run --rm --name qdrant --pull=never \\
    -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 \\
    -v ${STORAGE_DIR}:/qdrant/storage \\
    -v ${SNAPSHOT_DIR}:/qdrant/snapshots \\
    -e QDRANT__TELEMETRY_DISABLED=true \\
    ${image}
ExecStop=${docker_bin} stop qdrant
Restart=on-failure
RestartSec=5s
SyslogIdentifier=qdrant

[Install]
WantedBy=multi-user.target
EOF
    ${sudo_cmd} systemctl daemon-reload
    ${sudo_cmd} systemctl enable --force --no-ask-password "$SERVICE_FILE"
}

stop_docker_qdrant() {
    if ! command -v docker >/dev/null 2>&1; then
        log_info "docker is not installed, nothing to stop"
        return
    fi
    local cid
    cid="$(${sudo_cmd} docker ps -q --filter "ancestor=qdrant/qdrant" 2>/dev/null | head -1)"
    if [[ -z "$cid" ]]; then
        cid="$(${sudo_cmd} docker ps -q --filter "name=^/qdrant$" 2>/dev/null | head -1)"
    fi
    if [[ -n "$cid" ]]; then
        log_info "stopping the docker qdrant container $cid ..."
        ${sudo_cmd} docker stop "$cid" >/dev/null
        log_ok "docker qdrant stopped (container kept; remove it later or pass --remove-docker)"
    else
        log_info "no running docker qdrant container found"
    fi
}

verify_storage() {
    if [[ ! -d "$STORAGE_DIR" ]]; then
        log_warn "data directory $STORAGE_DIR does not exist; qdrant will create an empty database on first start. If the docker container used a different path, migrating this way loses the data — check before continuing."
        ${sudo_cmd} mkdir -p "$STORAGE_DIR"
    else
        log_ok "keeping the existing data directory: $STORAGE_DIR"
    fi
    ${sudo_cmd} mkdir -p "$SNAPSHOT_DIR" "$CONF_DIR"
}

download_binary() {
    if [[ -x "$BIN_DST" ]]; then
        local cur
        cur="$($BIN_DST --version 2>/dev/null | head -1 || echo '')"
        log_info "$BIN_DST already present ($cur), overwriting with $QDRANT_VERSION ..."
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    local src
    if [[ -n "$LOCAL_TARBALL" ]]; then
        [[ -f "$LOCAL_TARBALL" ]] || log_fail "local tarball not found: $LOCAL_TARBALL"
        log_info "using the local tarball: $LOCAL_TARBALL"
        src="$LOCAL_TARBALL"
    else
        # Prefer the NimoOS dependency mirror — it is reachable on machines with
        # no direct GitHub access — and fall back to the official release.
        local depfile="qdrant-${TARBALL_ARCH}.tar.gz"
        local mirror_url="${NIMO_DEPS_BASE}/qdrant/${depfile}"
        local gh_url="https://github.com/qdrant/qdrant/releases/download/${QDRANT_VERSION}/${depfile}"
        log_info "downloading the qdrant binary (mirror first) ..."
        if curl -fL --retry 3 --connect-timeout 10 -o "$tmpdir/qdrant.tar.gz" "$mirror_url"; then
            log_ok "downloaded from the dependency mirror: $mirror_url"
        elif curl -fL --connect-timeout 10 -o "$tmpdir/qdrant.tar.gz" "$gh_url"; then
            log_ok "mirror unavailable, downloaded from GitHub: $gh_url"
        else
            log_fail "download failed (neither the mirror nor GitHub is reachable); download it manually and pass --tarball <path>"
        fi
        src="$tmpdir/qdrant.tar.gz"
    fi

    log_info "extracting ..."
    tar --no-same-owner -xzf "$src" -C "$tmpdir"
    local extracted
    extracted="$(find "$tmpdir" -maxdepth 2 -type f -name qdrant -executable | head -1)"
    [[ -n "$extracted" ]] || log_fail "no qdrant binary inside the tarball"

    ${sudo_cmd} install -m 0755 "$extracted" "$BIN_DST"
    log_ok "installed $BIN_DST ($($BIN_DST --version 2>/dev/null | head -1))"
}

write_config() {
    if [[ -f "$CONF_FILE" ]]; then
        log_info "keeping the existing configuration: $CONF_FILE"
        return
    fi
    log_info "writing a minimal configuration to $CONF_FILE"
    ${sudo_cmd} tee "$CONF_FILE" >/dev/null <<EOF
# /etc/qdrant/config.yaml — generated by install-qdrant.sh
# Listening on 127.0.0.1 matches the previous docker behaviour. For LAN access,
# change the host and add a firewall rule.
log_level: INFO

storage:
  storage_path: ${STORAGE_DIR}
  snapshots_path: ${SNAPSHOT_DIR}

service:
  host: 127.0.0.1
  http_port: 6333
  grpc_port: 6334
  enable_tls: false

telemetry_disabled: true
EOF
}

write_unit() {
    log_info "writing the systemd unit to $UNIT_DST"
    ${sudo_cmd} tee "$UNIT_DST" >/dev/null <<EOF
[Unit]
Description=Qdrant vector database (native)
Documentation=https://qdrant.tech/documentation/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${BIN_DST} --config-path ${CONF_FILE}
WorkingDirectory=/opt/qdrant
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=qdrant

[Install]
WantedBy=multi-user.target
EOF
    ${sudo_cmd} systemctl daemon-reload
    ${sudo_cmd} systemctl enable --force --no-ask-password "$SERVICE_FILE"
}

# The /healthz URL of the Qdrant this script just started. Native mode keeps an
# existing config.yaml (write_config), so read its service.host / http_port
# rather than assuming 127.0.0.1:6333; a wildcard listen address is probed on
# loopback. NIMO_QDRANT_HEALTH_URL overrides both, for setups this cannot read.
qdrant_health_url() {
    if [[ -n "${NIMO_QDRANT_HEALTH_URL:-}" ]]; then echo "$NIMO_QDRANT_HEALTH_URL"; return; fi
    local host=127.0.0.1 port=6333 h="" p=""
    if [[ -f "$CONF_FILE" ]]; then
        read -r h p < <(awk '
            /^service:[[:space:]]*(#.*)?$/ { s = 1; next }
            /^[^[:space:]#]/              { s = 0 }
            s && $1 == "host:"            { h = $2 }
            s && $1 == "http_port:"       { p = $2 }
            END { print (h == "" ? "-" : h), (p == "" ? "-" : p) }' "$CONF_FILE")
        h="${h//[\"\']/}"; p="${p//[\"\']/}"
        [[ "$h" != "-" ]] && host="$h"
        [[ "$p" =~ ^[0-9]+$ ]] && port="$p"
    fi
    case "$host" in
        0.0.0.0|::|"[::]") host=127.0.0.1 ;;
        \[*\])             ;;
        *:*)               host="[$host]" ;;
    esac
    echo "http://${host}:${port}/healthz"
}

# The API key the readiness probe has to send. write_config keeps an existing
# config.yaml, and a Qdrant with service.api_key (or only read_only_api_key)
# answers /healthz with 401 to an anonymous probe. NIMO_QDRANT_API_KEY overrides
# (e.g. a key set through QDRANT__SERVICE__API_KEY, or with NIMO_QDRANT_HEALTH_URL).
# Prints the key on stdout for a caller to capture; never log it.
qdrant_api_key() {
    if [[ -n "${NIMO_QDRANT_API_KEY:-}" ]]; then printf '%s' "$NIMO_QDRANT_API_KEY"; return 0; fi
    [[ -f "$CONF_FILE" ]] || return 0
    local text
    if [[ -r "$CONF_FILE" ]]; then text="$(cat "$CONF_FILE")"; else text="$(${sudo_cmd} cat "$CONF_FILE" 2>/dev/null)"; fi
    awk '
        /^service:[[:space:]]*(#.*)?$/ { s = 1; next }
        /^[^[:space:]#]/              { s = 0 }
        s && $1 == "api_key:"           { k = $2 }
        s && $1 == "read_only_api_key:" { r = $2 }
        END { printf "%s", (k != "" ? k : r) }' <<<"$text" | sed -E "s/^[\"']//; s/[\"']\$//"
}

# curl for Qdrant probes. With a key ($_qdrant_key, set by the caller), the
# header goes to curl as a config on stdin from a shell builtin: it is never an
# argument (ps shows every argument) and never in a log line.
qdrant_curl() {
    if [[ -z "${_qdrant_key:-}" ]]; then curl "$@"; return; fi
    local k="${_qdrant_key//\\/\\\\}"
    k="${k//\"/\\\"}"
    printf 'header = "api-key: %s"\n' "$k" | curl --config - "$@"
}

start_and_verify() {   # [health URL]; default: the docker mapping 127.0.0.1:6333
    local url="${1:-http://127.0.0.1:6333/healthz}"
    log_info "starting $SERVICE_FILE ..."
    ${sudo_cmd} systemctl start "$SERVICE_FILE"

    # A listening port is not readiness, and a warning is not a failure: callers
    # (nimoos-stack-install.sh, the build's install.sh) go on to install Parser,
    # whose post-start health check needs a Qdrant that answers. So wait for
    # /healthz under one wall-clock budget and exit non-zero if it never answers.
    # Every probe and every pause is capped by the time left, so neither a port
    # that accepts but never answers nor a late reply can stretch the budget.
    local budget="${NIMO_QDRANT_READY_TIMEOUT:-120}" deadline left probe _qdrant_key
    _qdrant_key="$(qdrant_api_key)"
    deadline=$((SECONDS + budget))
    log_info "waiting for ${url} to answer (up to ${budget}s) ..."
    while :; do
        left=$((deadline - SECONDS))
        if (( left > 0 )); then
            probe=$(( left < 3 ? left : 3 ))
            qdrant_curl -sf -o /dev/null --connect-timeout "$(( probe < 2 ? probe : 2 ))" --max-time "$probe" "$url" \
                && (( SECONDS <= deadline )) && break
            left=$((deadline - SECONDS))
        fi
        if (( left <= 0 )); then
            ${sudo_cmd} systemctl status "$SERVICE_FILE" --no-pager -l --lines=8 || true
            log_fail "qdrant did not answer ${url} within ${budget}s; check journalctl -u $SERVICE_FILE -n 50. If this Qdrant listens elsewhere on purpose, set service.host / http_port in $CONF_FILE or NIMO_QDRANT_HEALTH_URL; if it requires an API key that is not in $CONF_FILE, set NIMO_QDRANT_API_KEY"
        fi
        sleep 1
    done
    log_ok "qdrant is up (${url%/healthz})"
    qdrant_curl -sf --max-time 5 "${url%/healthz}/collections" 2>/dev/null | head -c 200; echo

    ${sudo_cmd} systemctl status "$SERVICE_FILE" --no-pager -l --lines=8 || true
}

maybe_remove_docker() {
    if [[ "$REMOVE_DOCKER" -ne 1 ]]; then
        log_info "once native qdrant looks healthy, remove the old container:"
        echo "    sudo docker rm qdrant"
        return
    fi
    if ! command -v docker >/dev/null 2>&1; then return; fi
    local cid
    cid="$(${sudo_cmd} docker ps -aq --filter "name=^/qdrant$" 2>/dev/null | head -1)"
    if [[ -n "$cid" ]]; then
        log_info "removing the docker qdrant container $cid ..."
        ${sudo_cmd} docker rm -f "$cid" >/dev/null
        log_ok "container removed; the NAS app list will refresh"
    fi
}

restart_dependents() {
    # parser loses its connection the moment the docker qdrant stops, so give it
    # a restart to reconnect to the native service.
    if systemctl is-active --quiet nimoos-parser 2>/dev/null; then
        log_info "restarting nimoos-parser so it reconnects to the new qdrant ..."
        ${sudo_cmd} systemctl restart nimoos-parser.service || true
    fi
}

###############################################################################
# Main
###############################################################################

log_info "=== Qdrant native install / docker migration ==="
log_info "version: $QDRANT_VERSION"
log_info "data:    $STORAGE_DIR (reusing the docker data directory)"

detect_arch
check_glibc

if [[ "${NATIVE_OK}" -eq 1 && "${FORCE_DOCKER}" -eq 0 ]]; then
    verify_storage
    download_binary
    write_config
    stop_docker_qdrant
    write_unit
    start_and_verify "$(qdrant_health_url)"
    restart_dependents
    maybe_remove_docker
    MODE_NOTE="binary:      $BIN_DST
  config:      $CONF_FILE"
else
    # Native binary cannot run (or --docker was passed): same service name, same
    # data directory, same 127.0.0.1-only exposure, engine in a container.
    verify_storage
    install_docker_qdrant
    start_and_verify "${NIMO_QDRANT_HEALTH_URL:-http://127.0.0.1:6333/healthz}"
    restart_dependents
    MODE_NOTE="engine:      docker (qdrant/qdrant:${QDRANT_VERSION}, wrapped in ${SERVICE_FILE})"
fi

echo ""
log_ok "Qdrant install complete."
echo ""
echo "  ${MODE_NOTE}"
echo "  data:        $STORAGE_DIR"
echo "  logs:        journalctl -u $SERVICE_FILE -f"
echo "  collections: curl http://127.0.0.1:6333/collections"
