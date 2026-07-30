#!/bin/bash
# 后端服务一键构建+部署+重启
# 用法: ./deploy.sh <service>
# 可用服务: nimoos | gateway | message-bus | user-service | local-storage | app-management | ai | wiki | search | photos | terminal
set -euo pipefail

# Claude Code Stop hook 的 PATH 不含 /usr/local/go/bin，显式补上。
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

# nimoos 依赖 SQLite (CGO)，ai 依赖 go-systemd (CGO)，wiki 依赖 SQLite+go-systemd (CGO)，
# photos 依赖 SQLite+sqlite-vec (CGO，需系统 sqlite3.h)，其余纯 Go
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
  echo "用法: $0 <service>"
  echo "可用服务: ${!SERVICE_DIR[*]}"
  exit 1
fi

if [[ -z "${SERVICE_DIR[$SERVICE]+x}" ]]; then
  echo "未知服务: $SERVICE"
  echo "可用服务: ${!SERVICE_DIR[*]}"
  exit 1
fi

DIR="$REPO_ROOT/${SERVICE_DIR[$SERVICE]}"
BINARY="${SERVICE_BINARY[$SERVICE]}"
SYSTEMD="${SERVICE_SYSTEMD[$SERVICE]}"
CGO="${SERVICE_CGO[$SERVICE]}"

echo "==> [1/3] 构建 $SERVICE ..."
cd "$DIR"
FULL_VERSION="$(resolve_full_version)"   # 在 $DIR 内取本地 git sha
SYM="${GO_VERSION_SYM[$SERVICE]:-}"
[ -n "$SYM" ] || { echo "no version symbol for service '$SERVICE' (add to GO_VERSION_SYM)"; exit 1; }
echo "    version: ${FULL_VERSION} (-X ${SYM})"
CGO_ENABLED=$CGO go build -ldflags "-X ${SYM}=${FULL_VERSION}" -o "./$BINARY" .

echo "==> [2/3] 停止 $SYSTEMD 并部署 /usr/bin/$BINARY ..."
sudo systemctl stop "$SYSTEMD"
sudo cp "./$BINARY" "/usr/bin/$BINARY"

echo "==> [3/3] 启动 $SYSTEMD ..."
sudo systemctl enable "$SYSTEMD" 2>/dev/null || true   # 确保开机自启(新服务默认未 enable)
sudo systemctl start "$SYSTEMD"

echo ""
echo "完成! $SERVICE 已重启。状态:"
sudo systemctl status "$SYSTEMD" --no-pager -l --lines=8
