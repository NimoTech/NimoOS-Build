#!/bin/bash
# nimoos-agent 开发热部署:把本地 agent 源码同步进【运行中的容器】并重启容器。
# 源: NimoOS-AI/agent/{*.py, skills/, fs/, attachments/}
# 目标容器: nimoos-agent-agent-1(由 install-ai.sh / 离线包 install.sh 起的 compose 应用)
#
# 仅热更【代码】:用 docker cp(tar 管道)把源码灌进容器,再 docker restart,秒级生效,
# 不重建镜像。依赖(requirements.txt)有增减时,代码热更不够,需重建镜像:
#   cd NimoOS-AI && bash script/package-agent.sh <ver>  再 docker load + compose up
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_SRC="$REPO_ROOT/NimoOS-AI/agent"
CONTAINER="${NIMOOS_AGENT_CONTAINER:-nimoos-agent-agent-1}"
AGENT_DIR_IN_CONTAINER="/usr/share/nimoos/agent"
# 容器内同步的包目录(新增包目录时加这里,与 Dockerfile COPY 的 agent/ 对齐)
# netns:executor/bootstrap/client(egress-DLP);热更源码须带上,否则 shell.py 的
# `from netns import client` 在容器内 ModuleNotFoundError(2026-06-24 曾因漏它致 crash-loop)。
# mcp_server:MCP server 适配器(main.py 导入);漏它同样 crash-loop(2026-06-30)。
# shell_guard:L1 命令门控(skills/shell.py 导入 `import shell_guard`);漏它同样 crash-loop(2026-07-15)。
PKG_DIRS=(skills fs attachments mcp_client netns egress mcp_server channels shell_guard notes)

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

if [[ ! -d "$AGENT_SRC" ]]; then
  echo "未找到 agent 源目录: $AGENT_SRC" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "未找到 docker。" >&2
  exit 1
fi

# 容器必须在跑(首次部署请先跑 install-ai.sh 或离线包 install.sh)
if ! $SUDO docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "容器 $CONTAINER 未运行 — 请先用 install-ai.sh / 离线包 install.sh 完成首次部署。" >&2
  echo "(或设 NIMOOS_AGENT_CONTAINER=<容器名> 指定)" >&2
  exit 1
fi

# 组装要同步的条目:存在的 *.py 文件 + 存在的包目录
mapfile -t PY_FILES < <(cd "$AGENT_SRC" && ls -1 *.py 2>/dev/null || true)
SYNC_ITEMS=("${PY_FILES[@]}")
for d in "${PKG_DIRS[@]}"; do
  [[ -d "$AGENT_SRC/$d" ]] && SYNC_ITEMS+=("$d") || echo "  跳过缺失的源目录: $d"
done
if [[ ${#SYNC_ITEMS[@]} -eq 0 ]]; then
  echo "没有可同步的内容(*.py / ${PKG_DIRS[*]})。" >&2
  exit 1
fi

echo "==> [1/3] 同步源码进容器 $CONTAINER:$AGENT_DIR_IN_CONTAINER ..."
echo "    条目: ${SYNC_ITEMS[*]}"
# tar 管道:把选定条目打成流,在容器内解开。比逐个 docker cp 稳,且一次进出。
tar -C "$AGENT_SRC" -cf - "${SYNC_ITEMS[@]}" \
  | $SUDO docker exec -i "$CONTAINER" tar -C "$AGENT_DIR_IN_CONTAINER" -xf -

echo "==> [2/3] 重启容器 $CONTAINER ..."
$SUDO docker restart "$CONTAINER" >/dev/null

# L4 审计日志防篡改:确保宿主侧 audit.log 为 append-only(与 install.sh 同一加固,
# 保证 dev 热更路径也有 OS 级不可截断/删除保护)。尽力而为,文件系统不支持则跳过。
AUDIT_LOG="/var/lib/nimoos/ai/agent/audit.log"
if [[ -e "$AUDIT_LOG" ]] || $SUDO touch "$AUDIT_LOG" 2>/dev/null; then
  if $SUDO chattr +a "$AUDIT_LOG" 2>/dev/null; then
    echo "    审计日志已设为 append-only:$AUDIT_LOG"
  else
    echo "    ⚠ 无法为审计日志设置 append-only(文件系统可能不支持),已跳过。" >&2
  fi
fi

echo "==> [3/3] 等待 /healthz 就绪(最多 30s)..."
deadline=$(( SECONDS + 30 ))
while (( SECONDS < deadline )); do
  if curl -fsS http://127.0.0.1:8282/healthz 2>/dev/null | grep -q '"ok"'; then
    echo "完成! nimoos-agent 容器已热更并重启,/healthz 正常。"
    exit 0
  fi
  sleep 2
done
echo "!! 超时:容器重启后 /healthz 未就绪。排查: $SUDO docker logs --tail 50 $CONTAINER" >&2
exit 1
