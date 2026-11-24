#!/bin/bash
# Redeploy and restart nimoos-parser (Python).
# Source: NimoOS-Parser/{parser/, requirements.txt, build/sysroot/.../nimoos-parser.service}
# Target: /opt/nimoos-parser/{parser/, venv/}, /usr/lib/systemd/system/nimoos-parser.service
#
# Usage: bash deploy-parser.sh [--no-deps] [--reconcile-gpu-runtime] [--amd-npu-package]
#   --no-deps  skip pip install, for when the code changed but requirements did not
#   --no-deps --reconcile-gpu-runtime
#              skip `pip install -r` but still bring ONNX Runtime, the llama.cpp
#              wheel, Mesa and the OpenVINO pins in line with this machine's GPU
#              vendor (see lib/parser-gpu-branch.sh)
#   --amd-npu-package
#              also place the AMD NPU package (FastFlowLM + Whisper) under
#              /opt/nimoos-parser/flm on a machine with the 1022:17f0 NPU, as
#              install-parser.sh does (see lib/parser-npu-amd.sh); a no-op
#              elsewhere or when the pinned version is already there
#   DEPLOY_SRC_DIR=<dir>  deploy the Parser from this tree, such as a worktree
#
# Run install-parser.sh for a first-time install; this script requires the target
# directories to exist already.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Next to this script, not under $REPO_ROOT/NimoOS-Build: a Build worktree deploys
# with its own release/ and scripts/lib/.
BUILD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER_SRC="$REPO_ROOT/NimoOS-Parser"
[[ -n "${DEPLOY_SRC_DIR:-}" ]] && PARSER_SRC="$DEPLOY_SRC_DIR"
INSTALL_DIR="/opt/nimoos-parser"
VENV="$INSTALL_DIR/venv"
SERVICE="nimoos-parser.service"

SKIP_DEPS=0
RECONCILE_GPU=0
AMD_NPU_PACKAGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-deps) SKIP_DEPS=1; shift ;;
        --reconcile-gpu-runtime) RECONCILE_GPU=1; shift ;;
        --amd-npu-package) AMD_NPU_PACKAGE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -f /usr/share/nimoos/parser/parser/component-manifest.json && -f /usr/lib/systemd/system/nimoos-parser-prepare.service ]]; then
    echo "this image manages Parser components with its system slot; use the image/OTA update route so code and dependencies remain paired" >&2
    exit 1
fi

if [[ ! -d "$PARSER_SRC/parser" ]]; then
    echo "source not found: $PARSER_SRC/parser" >&2; exit 1
fi
source "$BUILD_ROOT/release/versions.conf"
source "$BUILD_ROOT/release/lib/version_inject.sh"
# shellcheck source=lib/parser-unit.sh
source "$BUILD_ROOT/scripts/lib/parser-unit.sh"
# shellcheck source=lib/parser-gpu-branch.sh
source "$BUILD_ROOT/scripts/lib/parser-gpu-branch.sh"
sudo_cmd="sudo"
VENV_DIR="$VENV"
UNIT_SRC="$PARSER_SRC/build/sysroot/usr/lib/systemd/system/$SERVICE"
UNIT_DST="/usr/lib/systemd/system/$SERVICE"
FULL_VERSION="$(cd "$PARSER_SRC" && resolve_full_version)"
echo "==> [0/5] writing parser/_version.py (version: ${FULL_VERSION}) ..."
printf 'VERSION = "%s"\n' "$FULL_VERSION" > "$PARSER_SRC/parser/_version.py"

# Versioned payloads use the same transaction and receipts as normal updates.
# Never rsync or pip into an immutable managed component in place.
if [[ -f "$PARSER_SRC/parser/component-manifest.json" ]]; then
    if (( SKIP_DEPS && (RECONCILE_GPU || AMD_NPU_PACKAGE) )); then
        echo "--no-deps forbids runtime changes; omit it to reconcile or repair managed components" >&2
        exit 1
    fi
    export DEPLOY_SRC_DIR="$PARSER_SRC"
    export NIMO_PARSER_CODE_ONLY="$SKIP_DEPS"
    bash "$BUILD_ROOT/scripts/install-parser.sh" --start
    exit $?
fi
# Everything below writes into $INSTALL_DIR in place. Take the component
# engine's writer lock first (parser_components.py: the live path's sibling
# .<name>.update.lock) and keep it until exit, so the managed check and the
# writes see one state: a migration that finishes while this deploy waits is
# refused here instead of being written through its new parser/ link.
UPDATE_LOCK="$(dirname "$INSTALL_DIR")/.$(basename "$INSTALL_DIR").update.lock"
sudo touch "$UPDATE_LOCK"
exec 8<"$UPDATE_LOCK"
if ! flock -n 8; then
    echo "==> waiting for another Parser update to finish ($UPDATE_LOCK) ..."
    flock 8
fi
if [[ -L "$INSTALL_DIR/.current" ]]; then
    echo "managed Parser requires a payload with component-manifest.json; live installation is unchanged" >&2
    exit 1
fi
if [[ ! -d "$INSTALL_DIR" ]] || [[ ! -x "$VENV/bin/python" ]]; then
    echo "no existing installation found ($INSTALL_DIR or $VENV is missing) — run install-parser.sh first" >&2
    exit 1
fi

# The unit is part of the deploy: a template change (memory ceiling, env,
# ordering) that only lands on fresh installs is drift waiting to bite. Done
# before the stop so a bad template aborts while the old service still runs
# (daemon-reload on a running unit is harmless).
#
# There is deliberately no switch to skip this step. Since dynamic allocation
# phase 2 the code and the unit form one contract: the unit opts in with
# PARSER_CGROUP_SPLIT=1 and delegates its cgroup (Delegate=yes +
# DelegateSubgroup=serve), and the code then moves background children into
# <unit>/batch. Shipping new code over a stale unit would leave the
# split silently off. Every non-zero rc aborts the deploy before the stop
# (1 = template missing, 2 = no memory ceiling, 3 = could not install, 4 = the
# template delegates but systemd does not; see lib/parser-unit.sh). An older
# Parser tree whose template does not delegate still deploys, so a rollback
# that takes code and unit back together keeps working.
echo "==> [1/5] syncing the systemd unit from $UNIT_SRC ..."
unit_rc=0
unit_state="$(sync_parser_unit "$UNIT_SRC" "$UNIT_DST" "$SERVICE")" || unit_rc=$?
if [[ $unit_rc -ne 0 ]]; then
    echo "unit sync failed (rc $unit_rc); leaving $SERVICE untouched" >&2
    exit 1
fi
echo "    unit $unit_state"

# Before the stop: the download (~650 MB) must not lengthen the outage, and the
# tree is swapped in with two renames, which a running Parser tolerates (the
# installer does the same while the service runs).
if [[ "$AMD_NPU_PACKAGE" -eq 1 ]]; then
    echo "==> [1/5] --amd-npu-package: placing the AMD NPU package (1022:17f0 machines only) ..."
    # shellcheck source=lib/parser-npu-amd.sh
    source "$BUILD_ROOT/scripts/lib/parser-npu-amd.sh"
    # Every failure inside already warns and returns 0; the `||` also keeps
    # set -e out of it.
    ensure_amd_npu_package || echo "WARNING: AMD NPU package step failed; continuing" >&2
fi

echo "==> [2/5] stopping $SERVICE ..."
sudo systemctl stop "$SERVICE"

echo "==> [3/5] syncing parser/ to $INSTALL_DIR/parser/ ..."
if command -v rsync &>/dev/null; then
    sudo rsync -a --no-owner --no-group --delete \
        --exclude='__pycache__' --exclude='*.pyc' \
        "$PARSER_SRC/parser/" "$INSTALL_DIR/parser/"
else
    sudo rm -rf "$INSTALL_DIR/parser"
    sudo cp -r "$PARSER_SRC/parser" "$INSTALL_DIR/parser"
fi
sudo cp "$PARSER_SRC/requirements.txt" "$INSTALL_DIR/requirements.txt"
# --no-owner --no-group stops new owners coming in, but files already in the
# tree keep theirs. Earlier installs could leave it all owned by the CI
# builder, 1000:1001 (see repair_ci_ownership in install-parser.sh): code a
# root service runs, writable by whoever is uid 1000. Give root back exactly
# that pair. Skipped when sudo is not really root (the test sandbox).
if [[ "$(sudo id -u 2>/dev/null)" == "0" ]]; then
    n="$(sudo find "$INSTALL_DIR" -xdev -uid 1000 -gid 1001 -print 2>/dev/null | wc -l)"
    if [[ "$n" -gt 0 ]]; then
        echo "    giving root back $n path(s) under $INSTALL_DIR left owned by uid 1000 by an earlier install"
        sudo find "$INSTALL_DIR" -xdev -uid 1000 -gid 1001 -exec chown -h 0:0 {} + 2>/dev/null \
            || echo "WARNING: could not restore every owner under $INSTALL_DIR; check with: find $INSTALL_DIR -uid 1000" >&2
    fi
fi

if [[ "$SKIP_DEPS" -eq 0 ]]; then
    echo "==> [4/5] installing requirements.txt; already-satisfied packages are skipped ..."
    sudo "$VENV/bin/pip" install --upgrade -r "$INSTALL_DIR/requirements.txt"
    # The `||` also keeps set -e out of the branch functions: nothing there may
    # abort this script while the service is stopped.
    reconcile_parser_gpu_runtime || echo "WARNING: GPU runtime reconcile failed; continuing" >&2
elif [[ "$RECONCILE_GPU" -eq 1 ]]; then
    echo "==> [4/5] --no-deps --reconcile-gpu-runtime: skipping pip install -r, reconciling the GPU runtime ..."
    reconcile_parser_gpu_runtime || echo "WARNING: GPU runtime reconcile failed; continuing" >&2
else
    echo "==> [4/5] --no-deps: skipping pip install"
fi

echo "==> [5/5] starting $SERVICE ..."
sudo systemctl start "$SERVICE"

echo ""
echo "Done. Status:"
sudo systemctl status "$SERVICE" --no-pager -l --lines=8
