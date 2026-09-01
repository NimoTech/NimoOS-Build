#!/bin/bash
# Redeploy and restart nimoos-parser (Python).
# Source: NimoOS-Parser/{parser/, requirements.txt}
# Target: /opt/nimoos-parser/{parser/, venv/}
#
# Usage: bash deploy-parser.sh [--no-deps]
#   --no-deps  skip pip install, for when the code changed but requirements did not
#
# Run install-parser.sh for a first-time install; this script requires the target
# directories to exist already.
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
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ ! -d "$PARSER_SRC/parser" ]]; then
    echo "source not found: $PARSER_SRC/parser" >&2; exit 1
fi
if [[ ! -d "$INSTALL_DIR" ]] || [[ ! -x "$VENV/bin/python" ]]; then
    echo "no existing installation found ($INSTALL_DIR or $VENV is missing) — run install-parser.sh first" >&2
    exit 1
fi

source "$REPO_ROOT/NimoOS-Build/release/versions.conf"
source "$REPO_ROOT/NimoOS-Build/release/lib/version_inject.sh"
FULL_VERSION="$(cd "$PARSER_SRC" && resolve_full_version)"
echo "==> [0/4] writing parser/_version.py (version: ${FULL_VERSION}) ..."
printf 'VERSION = "%s"\n' "$FULL_VERSION" > "$PARSER_SRC/parser/_version.py"

echo "==> [1/4] stopping $SERVICE ..."
sudo systemctl stop "$SERVICE"

echo "==> [2/4] syncing parser/ to $INSTALL_DIR/parser/ ..."
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
    echo "==> [3/4] installing requirements.txt; already-satisfied packages are skipped ..."
    sudo "$VENV/bin/pip" install --upgrade -r "$INSTALL_DIR/requirements.txt"
    # onnxruntime-openvino and onnxruntime share the same import path; pip happily
    # installs both and whichever wrote last wins. Make the OV build deterministic.
    sudo "$VENV/bin/pip" uninstall -y onnxruntime >/dev/null 2>&1 || true
    sudo "$VENV/bin/pip" install --force-reinstall --no-deps "onnxruntime-openvino>=1.24.1"
else
    echo "==> [3/4] --no-deps: skipping pip install"
fi

echo "==> [4/4] starting $SERVICE ..."
sudo systemctl start "$SERVICE"

echo ""
echo "Done. Status:"
sudo systemctl status "$SERVICE" --no-pager -l --lines=8
