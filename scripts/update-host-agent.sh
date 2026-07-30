#!/usr/bin/env bash
###############################################################################
# update-host-agent.sh —— host venv 形态 nimoos-agent 的就地更新 (非 Docker)。
#
# 适用: agent 以 systemd 直跑 (ExecStart=/var/lib/nimoos/ai/agent/venv/bin/python
#       main.py) 的机器, 如 192.168.1.138。Docker 形态请用 agent 包内自带 install.sh。
#
# 用法: sudo ./update-host-agent.sh /path/to/nimoos-agent-<ver>.tar.gz
#   NIMO_PIP_SKIP=1   跳过 pip 补依赖 (完全离线机器)
#   NIMO_PIP_INDEX=…  覆盖 PyPI 镜像 (默认清华)
#
# 行为:
#   1. 解包 agent docker 镜像 tar, 按 manifest 顺序应用镜像层得到 rootfs;
#   2. rsync 镜像内 /usr/share/nimoos/agent -> 本机同路径,
#      ⚠ 必须排除 agent.db (镜像里烤了一个种子 db, 覆盖真机 = 灭数据) 和 __pycache__;
#      venv 与 /var/lib/nimoos/ai/agent/ 下的真实数据永不触碰;
#   3. 安装镜像内 /usr/local/bin/egress-proxy -> 本机同路径
#      (缺它 agent 会以"无 netns 隔离"降级启动, 日志有明确警告);
#   4. venv 补 pip 依赖 (可跳过);
#   5. 重启 nimoos-agent 并轮询 /agent/health 到 200。
###############################################################################
set -euo pipefail

PKG="${1:?用法: $0 <nimoos-agent-*.tar.gz>}"
AGENT_DIR=/usr/share/nimoos/agent
VENV=/var/lib/nimoos/ai/agent/venv
PIP_INDEX="${NIMO_PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

systemctl cat nimoos-agent.service 2>/dev/null | grep -q "agent/venv/bin/python" || {
  echo "✗ 本机 nimoos-agent 不是 host venv 形态 (或未安装), 请用 agent 包内 install.sh (Docker 路径)" >&2
  exit 1
}
[ -f "$PKG" ] || { echo "✗ 找不到包: $PKG" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "==> [1/5] 解包 $(basename "$PKG")"
tar -xzf "$PKG" -C "$tmp" agent-image.tar
mkdir -p "$tmp/img" "$tmp/rootfs"
tar -xf "$tmp/agent-image.tar" -C "$tmp/img"

echo "==> [2/5] 按 manifest 顺序应用镜像层"
python3 - "$tmp" <<'PY'
import json, subprocess, sys
tmp = sys.argv[1]
manifest = json.load(open(f"{tmp}/img/manifest.json"))
for layer in manifest[0]["Layers"]:
    subprocess.run(["tar", "--no-same-owner", "-xf", f"{tmp}/img/{layer}",
                    "-C", f"{tmp}/rootfs"], check=True)
PY
[ -f "$tmp/rootfs$AGENT_DIR/main.py" ] || { echo "✗ 镜像内无 $AGENT_DIR/main.py" >&2; exit 1; }

echo "==> [3/5] 同步源码到 $AGENT_DIR (排除 agent.db/__pycache__; venv 与数据不受影响)"
rsync -a --delete --exclude=__pycache__ --exclude=agent.db \
  "$tmp/rootfs$AGENT_DIR/" "$AGENT_DIR/"
if [ -f "$tmp/rootfs/usr/local/bin/egress-proxy" ]; then
  install -m 0755 "$tmp/rootfs/usr/local/bin/egress-proxy" /usr/local/bin/egress-proxy
  echo "    egress-proxy 已更新"
else
  echo "    [WARN] 镜像内无 egress-proxy, 保持现状"
fi

if [ "${NIMO_PIP_SKIP:-0}" != "1" ]; then
  echo "==> [4/5] venv 补依赖 ($PIP_INDEX)"
  "$VENV/bin/pip" install -q -r "$AGENT_DIR/requirements.txt" -i "$PIP_INDEX" \
    || echo "    [WARN] pip 失败 —— 若本次无新增依赖可忽略; 离线机器用 NIMO_PIP_SKIP=1"
else
  echo "==> [4/5] 跳过 pip (NIMO_PIP_SKIP=1)"
fi

echo "==> [5/5] 重启 nimoos-agent 并健康检查"
systemctl restart nimoos-agent
for _ in $(seq 1 15); do
  sleep 2
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8282/agent/health || true)"
  if [ "$code" = "200" ]; then echo "✓ agent 健康 (/agent/health 200)"; exit 0; fi
done
echo "✗ 健康检查未通过, 查看: journalctl -u nimoos-agent -n 50" >&2
exit 1
