#!/bin/bash
# Development hot-deploy for nimoos-agent: sync the local agent source into the
# RUNNING container and restart it.
# Source: NimoOS-AI/agent/{*.py, skills/, fs/, attachments/}
# Target container: nimoos-agent-agent-1, the compose app started by
# install-ai.sh or by the offline bundle's install.sh.
#
# This updates CODE ONLY. The source goes in via a tar pipe through docker exec
# and the container is restarted, which takes seconds and rebuilds nothing. When
# requirements.txt changes, a code-only update is not enough and the image has to
# be rebuilt:
#   cd NimoOS-AI && bash script/package-agent.sh <ver>
#   then docker load followed by compose up
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_SRC="$REPO_ROOT/NimoOS-AI/agent"
CONTAINER="${NIMOOS_AGENT_CONTAINER:-nimoos-agent-agent-1}"
AGENT_DIR_IN_CONTAINER="/usr/share/nimoos/agent"
# Package directories synced into the container. Add new top-level packages here;
# the list must stay in step with the agent/ directory the Dockerfile COPYs.
# Three of these have caused crash-loops by being left out, because main.py or a
# skill imports them at start-up:
#   netns       egress-DLP executor/bootstrap/client; shell.py does
#               `from netns import client` (missed 2026-06-24)
#   mcp_server  the MCP server adapter, imported by main.py (missed 2026-06-30)
#   shell_guard L1 command gating, imported by skills/shell.py (missed 2026-07-15)
PKG_DIRS=(skills fs attachments mcp_client netns egress mcp_server channels shell_guard notes)

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

if [[ ! -d "$AGENT_SRC" ]]; then
  echo "agent source directory not found: $AGENT_SRC" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found." >&2
  exit 1
fi

# The container has to be running; for a first deployment use install-ai.sh or
# the offline bundle's install.sh.
if ! $SUDO docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "container $CONTAINER is not running — complete a first deployment with install-ai.sh or the offline bundle's install.sh." >&2
  echo "(or set NIMOOS_AGENT_CONTAINER=<name> to point at a different container)" >&2
  exit 1
fi

# Build the list to sync: the *.py files that exist, plus the package directories
# that exist.
mapfile -t PY_FILES < <(cd "$AGENT_SRC" && ls -1 *.py 2>/dev/null || true)
SYNC_ITEMS=("${PY_FILES[@]}")
for d in "${PKG_DIRS[@]}"; do
  [[ -d "$AGENT_SRC/$d" ]] && SYNC_ITEMS+=("$d") || echo "  skipping missing source directory: $d"
done
if [[ ${#SYNC_ITEMS[@]} -eq 0 ]]; then
  echo "nothing to sync (*.py / ${PKG_DIRS[*]})." >&2
  exit 1
fi

echo "==> [1/3] syncing the source into $CONTAINER:$AGENT_DIR_IN_CONTAINER ..."
echo "    items: ${SYNC_ITEMS[*]}"
# A tar pipe: stream the selected items in and unpack them inside the container.
# More reliable than a docker cp per item, and it crosses the boundary once.
tar -C "$AGENT_SRC" -cf - "${SYNC_ITEMS[@]}" \
  | $SUDO docker exec -i "$CONTAINER" tar -C "$AGENT_DIR_IN_CONTAINER" -xf -

echo "==> [2/3] restarting $CONTAINER ..."
$SUDO docker restart "$CONTAINER" >/dev/null

# L4 audit log tamper resistance: keep the host-side audit.log append-only, the
# same hardening install.sh applies, so the dev hot-update path also gets
# OS-level protection against truncation and deletion. Best effort — skipped on
# filesystems that do not support the attribute.
AUDIT_LOG="/var/lib/nimoos/ai/agent/audit.log"
if [[ -e "$AUDIT_LOG" ]] || $SUDO touch "$AUDIT_LOG" 2>/dev/null; then
  if $SUDO chattr +a "$AUDIT_LOG" 2>/dev/null; then
    echo "    audit log set to append-only: $AUDIT_LOG"
  else
    echo "    [WARN] could not set append-only on the audit log (the filesystem may not support it), skipping." >&2
  fi
fi

echo "==> [3/3] waiting for /healthz (up to 30s) ..."
deadline=$(( SECONDS + 30 ))
while (( SECONDS < deadline )); do
  if curl -fsS http://127.0.0.1:8282/healthz 2>/dev/null | grep -q '"ok"'; then
    echo "Done. The nimoos-agent container was updated and restarted, and /healthz is responding."
    exit 0
  fi
  sleep 2
done
echo "!! timed out: /healthz did not come up after the restart. Investigate with: $SUDO docker logs --tail 50 $CONTAINER" >&2
exit 1
