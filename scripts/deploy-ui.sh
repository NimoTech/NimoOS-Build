#!/bin/bash
# Build and deploy the frontend in one step
# Build output: NimoOS-UI/build/sysroot/var/lib/nimoos/www/
# Deploy target: /var/lib/nimoos/www/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UI_DIR="$REPO_ROOT/NimoOS-UI"
BUILD_OUT="$UI_DIR/build/sysroot/var/lib/nimoos/www"
DEPLOY_TARGET="/var/lib/nimoos/www"

source "$REPO_ROOT/NimoOS-Build/release/versions.conf"
source "$REPO_ROOT/NimoOS-Build/release/lib/version_inject.sh"
export NIMOOS_VERSION
# Hand the build segment (FULL minus the version prefix) to gen-version.js
_full="$(cd "$UI_DIR" && resolve_full_version)"
export NIMOOS_BUILD="${_full#${NIMOOS_VERSION}+}"

# Provenance guard — see lib/deploy-stamp.sh. /var/lib/nimoos/www is a global
# singleton too: the same incident that replaced the agent's routes also
# replaced the UI build, taking another tree's settings pages with it.
source "$REPO_ROOT/NimoOS-Build/scripts/lib/deploy-stamp.sh"
stamp_verify ui "$UI_DIR" "frontend build" "$DEPLOY_TARGET/index.html" || exit 1

echo "==> [1/3] syncing dependencies (pnpm install --frozen-lockfile) ..."
cd "$UI_DIR"
pnpm install --frozen-lockfile

echo "==> [2/3] building the frontend ..."
pnpm run build

echo "==> [3/3] deploying to $DEPLOY_TARGET ..."
sudo mkdir -p "$DEPLOY_TARGET"

if command -v rsync &>/dev/null; then
  sudo rsync -a --delete "$BUILD_OUT/" "$DEPLOY_TARGET/"
else
  sudo rm -rf "$DEPLOY_TARGET"/*
  sudo cp -r "$BUILD_OUT/." "$DEPLOY_TARGET/"
fi

echo ""
stamp_write ui "$UI_DIR" "$DEPLOY_TARGET/index.html"
echo "done — frontend deployed to $DEPLOY_TARGET"
