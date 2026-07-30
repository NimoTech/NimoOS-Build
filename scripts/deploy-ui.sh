#!/bin/bash
# 前端一键构建+部署
# 构建输出: NimoOS-UI/build/sysroot/var/lib/nimoos/www/
# 部署目标: /var/lib/nimoos/www/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UI_DIR="$REPO_ROOT/NimoOS-UI"
BUILD_OUT="$UI_DIR/build/sysroot/var/lib/nimoos/www"
DEPLOY_TARGET="/var/lib/nimoos/www"

source "$REPO_ROOT/NimoOS-Build/release/versions.conf"
source "$REPO_ROOT/NimoOS-Build/release/lib/version_inject.sh"
export NIMOOS_VERSION
# 把解析出的 build 段(FULL 去掉 "版本+" 前缀)导给 gen-version.js
_full="$(cd "$UI_DIR" && resolve_full_version)"
export NIMOOS_BUILD="${_full#${NIMOOS_VERSION}+}"

echo "==> [1/3] 同步依赖 (pnpm install --frozen-lockfile) ..."
cd "$UI_DIR"
pnpm install --frozen-lockfile

echo "==> [2/3] 构建前端 ..."
pnpm run build

echo "==> [3/3] 部署到 $DEPLOY_TARGET ..."
sudo mkdir -p "$DEPLOY_TARGET"

if command -v rsync &>/dev/null; then
  sudo rsync -a --delete "$BUILD_OUT/" "$DEPLOY_TARGET/"
else
  sudo rm -rf "$DEPLOY_TARGET"/*
  sudo cp -r "$BUILD_OUT/." "$DEPLOY_TARGET/"
fi

echo ""
echo "完成! 前端已部署到 $DEPLOY_TARGET"
