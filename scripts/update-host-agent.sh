#!/usr/bin/env bash
###############################################################################
# update-host-agent.sh — in-place update of a host-venv nimoos-agent (not Docker).
#
# For machines where the agent runs directly under systemd, i.e.
# ExecStart=/var/lib/nimoos/ai/agent/venv/bin/python main.py. For the Docker
# layout, use the install.sh that ships inside the agent bundle instead.
#
# Usage: sudo ./update-host-agent.sh /path/to/nimoos-agent-<ver>.tar.gz
#   NIMO_PIP_SKIP=1   skip the pip dependency top-up (fully offline machines)
#   NIMO_PIP_INDEX=…  override the PyPI mirror
#
# What it does:
#   1. Unpacks the agent docker image tar and applies the image layers in
#      manifest order to reconstruct a rootfs.
#   2. rsyncs /usr/share/nimoos/agent out of the image onto the same path here.
#      agent.db MUST be excluded: the image carries a seed database, and copying
#      it over a live machine destroys that machine's data. __pycache__ is
#      excluded too. The venv and the real data under /var/lib/nimoos/ai/agent/
#      are never touched.
#   3. Installs /usr/local/bin/egress-proxy from the image. Without it the agent
#      starts in a degraded mode with no netns isolation, and says so in the log.
#   4. Tops up the venv's pip dependencies (skippable).
#   5. Restarts nimoos-agent and polls /agent/health until it returns 200.
###############################################################################
set -euo pipefail

PKG="${1:?usage: $0 <nimoos-agent-*.tar.gz>}"
AGENT_DIR=/usr/share/nimoos/agent
VENV=/var/lib/nimoos/ai/agent/venv
PIP_INDEX="${NIMO_PIP_INDEX:-https://pypi.org/simple}"

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

systemctl cat nimoos-agent.service 2>/dev/null | grep -q "agent/venv/bin/python" || {
  echo "x nimoos-agent on this machine is not the host-venv layout (or is not installed); use the install.sh inside the agent bundle for the Docker path" >&2
  exit 1
}
[ -f "$PKG" ] || { echo "x package not found: $PKG" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "==> [1/5] unpacking $(basename "$PKG")"
tar -xzf "$PKG" -C "$tmp" agent-image.tar
mkdir -p "$tmp/img" "$tmp/rootfs"
tar -xf "$tmp/agent-image.tar" -C "$tmp/img"

echo "==> [2/5] applying the image layers in manifest order"
python3 - "$tmp" <<'PY'
import json, subprocess, sys
tmp = sys.argv[1]
manifest = json.load(open(f"{tmp}/img/manifest.json"))
for layer in manifest[0]["Layers"]:
    subprocess.run(["tar", "--no-same-owner", "-xf", f"{tmp}/img/{layer}",
                    "-C", f"{tmp}/rootfs"], check=True)
PY
[ -f "$tmp/rootfs$AGENT_DIR/main.py" ] || { echo "x the image has no $AGENT_DIR/main.py" >&2; exit 1; }

echo "==> [3/5] syncing the source to $AGENT_DIR (excluding agent.db and __pycache__; the venv and data are untouched)"
rsync -a --delete --exclude=__pycache__ --exclude=agent.db \
  "$tmp/rootfs$AGENT_DIR/" "$AGENT_DIR/"
if [ -f "$tmp/rootfs/usr/local/bin/egress-proxy" ]; then
  install -m 0755 "$tmp/rootfs/usr/local/bin/egress-proxy" /usr/local/bin/egress-proxy
  echo "    egress-proxy updated"
else
  echo "    [WARN] no egress-proxy in the image, leaving the current one in place"
fi

if [ "${NIMO_PIP_SKIP:-0}" != "1" ]; then
  echo "==> [4/5] topping up the venv dependencies from $PIP_INDEX"
  "$VENV/bin/pip" install -q -r "$AGENT_DIR/requirements.txt" -i "$PIP_INDEX" \
    || echo "    [WARN] pip failed; safe to ignore if this update adds no dependencies. On an offline machine use NIMO_PIP_SKIP=1"
else
  echo "==> [4/5] skipping pip (NIMO_PIP_SKIP=1)"
fi

echo "==> [5/5] restarting nimoos-agent and checking health"
systemctl restart nimoos-agent
for _ in $(seq 1 15); do
  sleep 2
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8282/agent/health || true)"
  if [ "$code" = "200" ]; then echo "OK agent is healthy (/agent/health returned 200)"; exit 0; fi
done
echo "x health check did not pass; see journalctl -u nimoos-agent -n 50" >&2
exit 1
