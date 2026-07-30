#!/bin/bash
# nimoos-parser (Python) 热部署 + 重启
# 源:NimoOS-Parser/{parser/, requirements.txt}
# 目标:/opt/nimoos-parser/{parser/, venv/}
#
# 用法:bash deploy-parser.sh [--no-deps]
#   --no-deps  跳过 pip install(代码改动且 requirements 没变时用)
#
# 首次安装请先跑 install-parser.sh,本脚本要求目标目录已存在。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARSER_SRC="$REPO_ROOT/NimoOS-Parser"
INSTALL_DIR="/opt/nimoos-parser"
VENV="$INSTALL_DIR/venv"
SERVICE="nimoos-parser.service"

SKIP_DEPS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-deps) SKIP_DEPS=1; shift ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ ! -d "$PARSER_SRC/parser" ]]; then
    echo "未找到源码:$PARSER_SRC/parser" >&2; exit 1
fi
if [[ ! -d "$INSTALL_DIR" ]] || [[ ! -x "$VENV/bin/python" ]]; then
    echo "未检测到首次安装(缺 $INSTALL_DIR 或 $VENV)— 请先跑 install-parser.sh" >&2
    exit 1
fi

source "$REPO_ROOT/NimoOS-Build/release/versions.conf"
source "$REPO_ROOT/NimoOS-Build/release/lib/version_inject.sh"
FULL_VERSION="$(cd "$PARSER_SRC" && resolve_full_version)"
echo "==> [0/4] 生成 parser/_version.py (version: ${FULL_VERSION}) ..."
printf 'VERSION = "%s"\n' "$FULL_VERSION" > "$PARSER_SRC/parser/_version.py"

echo "==> [1/4] 停止 $SERVICE ..."
sudo systemctl stop "$SERVICE"

echo "==> [2/4] 同步 parser/ → $INSTALL_DIR/parser/ ..."
if command -v rsync &>/dev/null; then
    sudo rsync -a --delete \
        --exclude='__pycache__' --exclude='*.pyc' \
        "$PARSER_SRC/parser/" "$INSTALL_DIR/parser/"
else
    sudo rm -rf "$INSTALL_DIR/parser"
    sudo cp -r "$PARSER_SRC/parser" "$INSTALL_DIR/parser"
fi
sudo cp "$PARSER_SRC/requirements.txt" "$INSTALL_DIR/requirements.txt"

if [[ "$SKIP_DEPS" -eq 0 ]]; then
    echo "==> [3/4] 同步并安装 requirements.txt 增量(已装的会 skip)..."
    sudo "$VENV/bin/pip" install --upgrade -r "$INSTALL_DIR/requirements.txt"
else
    echo "==> [3/4] --no-deps 跳过 pip install"
fi

echo "==> [4/4] 启动 $SERVICE ..."
sudo systemctl start "$SERVICE"

echo ""
echo "完成。状态:"
sudo systemctl status "$SERVICE" --no-pager -l --lines=8
