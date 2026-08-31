#!/bin/bash
# Build and deploy the frontend in one step.
# The web UI is NimoOS-UI (Vue 3, renamed from NimoOS-New-UI on 2026-08-30), served
# at the site root since 2026-08-29:
#   Build output: NimoOS-UI/dist/
#   Deploy target: /var/lib/nimoos/www/
#   URL: http://<host>/#/
# The retired Vue 2 panel (now NimoOS-Old-UI, archived) is no longer built or deployed
# by anything; the first root deploy's --delete clears whatever it left at the root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UI_DIR="$REPO_ROOT/NimoOS-UI"
BUILD_OUT="$UI_DIR/dist"
DEPLOY_TARGET="/var/lib/nimoos/www"

source "$REPO_ROOT/NimoOS-Build/release/versions.conf"
source "$REPO_ROOT/NimoOS-Build/release/lib/version_inject.sh"
export NIMOOS_VERSION
# Hand the build segment (FULL minus the version prefix) to the UI build — its
# vite config emits version.json from NIMOOS_VERSION(+NIMOOS_BUILD), the same
# contract gen-version.js used to satisfy on the Vue 2 side. The gateway's
# component probe reads that file from the www root.
_full="$(cd "$UI_DIR" && resolve_full_version)"
export NIMOOS_BUILD="${_full#${NIMOOS_VERSION}+}"

# Provenance guard — see lib/deploy-stamp.sh. /var/lib/nimoos/www is a global
# singleton: an unstamped deploy from another tree once replaced a build and
# took another line's pages with it.
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
  # protect assets/*: tabs opened before the deploy still lazy-load old hashed
  # chunks per the old index.html; deleting them makes lazy routes 404 with no
  # self-healing. The find below ages them out by mtime instead.
  # protect app/***: the legacy /app/ mount from the era when this app coexisted
  # with the Vue 2 panel. Old bookmarks and still-open tabs point there; the
  # redirect written below keeps them landing at the root, and their old chunks
  # age out on the same mtime schedule.
  sudo rsync -a --delete --filter='protect assets/*' --filter='protect app/***' "$BUILD_OUT/" "$DEPLOY_TARGET/"
else
  sudo rm -rf "$DEPLOY_TARGET"/*
  sudo cp -r "$BUILD_OUT/." "$DEPLOY_TARGET/"
fi
sudo find "$DEPLOY_TARGET/assets" "$DEPLOY_TARGET/app/assets" -type f -mtime +14 -delete 2>/dev/null || true

# Keep /app/#/… bookmarks working: the UI ships a script that turns the legacy
# mount into a redirect page carrying the query string and hash over verbatim.
sudo bash "$UI_DIR/scripts/write-app-redirect.sh" "$DEPLOY_TARGET"

echo ""
stamp_write ui "$UI_DIR" "$DEPLOY_TARGET/index.html"
echo "done — frontend deployed to $DEPLOY_TARGET  →  http://<host>/#/"
