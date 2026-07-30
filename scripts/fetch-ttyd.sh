#!/bin/bash
# Usage: fetch-ttyd.sh <arch> <dest-path>
# arch is one of amd64, arm64, armv7; dest is the target file path
set -euo pipefail
TTYD_VERSION="1.7.7"   # pinned; check for a newer stable tag when bumping
ARCH="${1:?arch required}"
DEST="${2:?dest required}"
declare -A ASSET=(
  [amd64]="ttyd.x86_64"
  [arm64]="ttyd.aarch64"
  [armv7]="ttyd.arm"
)
name="${ASSET[$ARCH]:?unknown arch $ARCH}"
# Prefer the NimoOS mirror, fall back to GitHub
OSS_URL="${NIMO_OSS_BASE:-https://get.nimoos.example/ttyd}/${TTYD_VERSION}/${name}"
GH_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${name}"
mkdir -p "$(dirname "$DEST")"
if curl -fsSL "$OSS_URL" -o "$DEST" 2>/dev/null; then
  echo "fetched ttyd from OSS: $OSS_URL"
elif curl -fsSL "$GH_URL" -o "$DEST"; then
  echo "fetched ttyd from GitHub: $GH_URL"
else
  echo "FATAL: cannot fetch ttyd for $ARCH" >&2; exit 1
fi
chmod 755 "$DEST"
"$DEST" --version >/dev/null 2>&1 && echo "ttyd OK" || { echo "FATAL: ttyd not executable/mismatched arch" >&2; exit 1; }
