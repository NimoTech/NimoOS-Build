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
# Usage:
#   sudo bash install-qdrant.sh [--version v1.18.1] [--tarball <path>] [--remove-docker]
#
#   --version        install a different version
#   --tarball PATH   use a locally downloaded qdrant-*.tar.gz instead of fetching
#   --remove-docker  `docker rm` the old container once native qdrant is verified
#
# Data compatibility: same version plus same storage_path means the native
# service starts on the existing data as-is; no dump/restore needed.

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

QDRANT_VERSION="v1.18.1"
LOCAL_TARBALL=""
REMOVE_DOCKER=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) QDRANT_VERSION="$2"; shift 2 ;;
        --tarball) LOCAL_TARBALL="$2"; shift 2 ;;
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
: "${NIMO_DEPS_BASE:=https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/deps}"

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
    # ships 2.36. Bail out early rather than install something that cannot run;
    # staying on docker is the right answer on those systems.
    local need="2.38"
    local have
    have="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$have" ]]; then
        log_warn "cannot determine the GLIBC version, continuing anyway (may fail)"
        return
    fi
    # true when have >= need
    if [[ "$(printf '%s\n%s' "$need" "$have" | sort -V | head -1)" != "$need" ]]; then
        log_fail "host GLIBC $have < $need. The qdrant binary is incompatible; stay on docker, this script does not suit your distribution."
    fi
    log_ok "GLIBC $have >= $need"
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
    tar -xzf "$src" -C "$tmpdir"
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

start_and_verify() {
    log_info "starting $SERVICE_FILE ..."
    ${sudo_cmd} systemctl start "$SERVICE_FILE"

    log_info "waiting for port 6333 to listen (up to 15s) ..."
    local ok=0
    for _ in $(seq 1 15); do
        if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:6333'; then ok=1; break; fi
        sleep 1
    done
    if [[ "$ok" -eq 1 ]]; then
        log_ok "qdrant is up (127.0.0.1:6333)"
        curl -sf http://127.0.0.1:6333/collections 2>/dev/null | head -c 200; echo
    else
        log_warn "port 6333 is not listening after 15s; check journalctl -u $SERVICE_FILE -n 50"
    fi

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
verify_storage
download_binary
write_config
stop_docker_qdrant
write_unit
start_and_verify
restart_dependents
maybe_remove_docker

echo ""
log_ok "Migration complete."
echo ""
echo "  binary:      $BIN_DST"
echo "  config:      $CONF_FILE"
echo "  data:        $STORAGE_DIR"
echo "  logs:        journalctl -u $SERVICE_FILE -f"
echo "  collections: curl http://127.0.0.1:6333/collections"
echo "  rollback:    sudo systemctl disable --now qdrant && sudo docker start qdrant"
