#!/bin/bash
# Build, deploy and restart one backend service.
# Usage: ./deploy.sh <service>
# Services: nimoos | gateway | message-bus | user-service | local-storage | app-management | ai | wiki | search | photos | terminal
set -euo pipefail

# The Claude Code Stop hook runs with a PATH that omits /usr/local/go/bin, so add it explicitly.
export PATH="/usr/local/go/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

source "$REPO_ROOT/NimoOS-Build/release/versions.conf"
source "$REPO_ROOT/NimoOS-Build/release/lib/version_inject.sh"

declare -A SERVICE_DIR=(
  ["nimoos"]="NimoOS"
  ["gateway"]="NimoOS-Gateway"
  ["message-bus"]="NimoOS-MessageBus"
  ["user-service"]="NimoOS-UserService"
  ["local-storage"]="NimoOS-LocalStorage"
  ["app-management"]="NimoOS-AppManagement"
  ["ai"]="NimoOS-AI"
  ["wiki"]="NimoOS-Wiki"
  ["search"]="NimoOS-Search"
  ["photos"]="NimoOS-Photos"
  ["terminal"]="NimoOS-Terminal"
)

declare -A SERVICE_BINARY=(
  ["nimoos"]="nimoos"
  ["gateway"]="nimoos-gateway"
  ["message-bus"]="nimoos-message-bus"
  ["user-service"]="nimoos-user-service"
  ["local-storage"]="nimoos-local-storage"
  ["app-management"]="nimoos-app-management"
  ["ai"]="nimoos-ai"
  ["wiki"]="nimoos-wiki"
  ["search"]="nimoos-search"
  ["photos"]="nimoos-photos"
  ["terminal"]="nimoos-terminal"
)

declare -A SERVICE_SYSTEMD=(
  ["nimoos"]="nimoos.service"
  ["gateway"]="nimoos-gateway.service"
  ["message-bus"]="nimoos-message-bus.service"
  ["user-service"]="nimoos-user-service.service"
  ["local-storage"]="nimoos-local-storage.service"
  ["app-management"]="nimoos-app-management.service"
  ["ai"]="nimoos-ai.service"
  ["wiki"]="nimoos-wiki.service"
  ["search"]="nimoos-search.service"
  ["photos"]="nimoos-photos.service"
  ["terminal"]="nimoos-terminal.service"
)

# nimoos needs SQLite (CGO), ai needs go-systemd (CGO), wiki needs both
# SQLite and go-systemd (CGO), photos needs SQLite plus sqlite-vec (CGO, and the
# system sqlite3.h). Everything else is pure Go.
declare -A SERVICE_CGO=(
  ["nimoos"]="1"
  ["gateway"]="0"
  ["message-bus"]="0"
  ["user-service"]="0"
  ["local-storage"]="0"
  ["app-management"]="0"
  ["ai"]="1"
  ["wiki"]="1"
  ["search"]="0"
  ["photos"]="1"
  ["terminal"]="0"
)

SERVICE="${1:-}"

if [[ -z "$SERVICE" ]]; then
  echo "Usage: $0 <service>"
  echo "Services: ${!SERVICE_DIR[*]}"
  exit 1
fi

if [[ -z "${SERVICE_DIR[$SERVICE]+x}" ]]; then
  echo "Unknown service: $SERVICE"
  echo "Services: ${!SERVICE_DIR[*]}"
  exit 1
fi

DIR="$REPO_ROOT/${SERVICE_DIR[$SERVICE]}"
BINARY="${SERVICE_BINARY[$SERVICE]}"
SYSTEMD="${SERVICE_SYSTEMD[$SERVICE]}"
CGO="${SERVICE_CGO[$SERVICE]}"

echo "==> [1/3] building $SERVICE ..."
cd "$DIR"
FULL_VERSION="$(resolve_full_version)"   # reads the local git sha from inside $DIR
SYM="${GO_VERSION_SYM[$SERVICE]:-}"
[ -n "$SYM" ] || { echo "no version symbol for service '$SERVICE' (add to GO_VERSION_SYM)"; exit 1; }
echo "    version: ${FULL_VERSION} (-X ${SYM})"
CGO_ENABLED=$CGO go build -ldflags "-X ${SYM}=${FULL_VERSION}" -o "./$BINARY" .

echo "==> [2/3] stopping $SYSTEMD and installing /usr/bin/$BINARY ..."
sudo systemctl stop "$SYSTEMD"
sudo cp "./$BINARY" "/usr/bin/$BINARY"

echo "==> [3/3] starting $SYSTEMD ..."
sudo systemctl enable "$SYSTEMD" 2>/dev/null || true   # a freshly added service is not enabled by default
sudo systemctl start "$SYSTEMD"

echo ""
echo "Done. $SERVICE restarted. Status:"
sudo systemctl status "$SYSTEMD" --no-pager -l --lines=8
