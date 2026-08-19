#!/usr/bin/env bash
# Regression test: a Vue2 UI deploy must not delete NimoOS-New-UI's /app/.
#
# `deploy-ui.sh` rsyncs its build output over /var/lib/nimoos/www with --delete,
# and that output never contains an app/ directory — so before the protect
# filter, every Vue2 deploy removed the whole of New-UI. Silently: no error, no
# missing-file warning, just a section of the product that stopped existing
# until someone redeployed New-UI. Deploy ORDER (Vue2 first, New-UI second) was
# the only thing keeping them coexisting, and nothing wrote that down.
#
# The filter is READ OUT OF THE SCRIPT rather than repeated here: a test that
# hardcodes its own copy of the flag passes happily after someone edits the
# script, which is the failure this file is supposed to catch.
#
# Run: bash scripts/deploy-ui.protect.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/deploy-ui.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

echo "deploy-ui.sh /app protection"

command -v rsync >/dev/null || { echo "  skip — rsync not installed"; exit 0; }

# Pull the real rsync flags out of the deploy script.
# The invocation line, not the `command -v rsync` probe above it: match on the
# flag that identifies it, then strip the command and the source/target operands.
FLAGS="$(grep -E 'rsync .*--delete' "$SCRIPT" | head -1 \
         | sed -e 's/.*rsync //' -e 's/"\$BUILD_OUT.*//' )"
if [[ -n "$FLAGS" && "$FLAGS" == *--delete* ]]; then
  ok "read the rsync flags from deploy-ui.sh: $FLAGS"
else
  bad "read the rsync flags from deploy-ui.sh"
  echo ""; echo "$pass passed, $fail failed"; exit 1
fi

# Stand in for the two sides: a build output with no app/, and a live www that
# already has New-UI deployed into app/.
mkdir -p "$TMP/build" "$TMP/live/app/assets"
echo vue2 > "$TMP/build/index.html"
echo "chunk" > "$TMP/live/app/assets/main-abc123.js"
echo "new-ui" > "$TMP/live/app/index.html"
echo stale > "$TMP/live/old-chunk.js"

# eval into an array, NOT bare word-splitting: the filter argument contains a
# quoted phrase ('protect app/***'), and splitting on whitespace hands rsync two
# broken arguments. That failed the transfer outright — and the app/ survival
# check then PASSED, because nothing had happened at all. A green that means
# "the command never ran" is worse than a red one.
declare -a ARGS
eval "ARGS=($FLAGS)"
if ! rsync_out="$(rsync "${ARGS[@]}" "$TMP/build/" "$TMP/live/" 2>&1)"; then
  bad "rsync ran cleanly with the script's own flags"
  echo "        rsync said: $rsync_out"
else
  ok "rsync ran cleanly with the script's own flags"
fi

[[ -f "$TMP/live/app/index.html" && -f "$TMP/live/app/assets/main-abc123.js" ]] \
  && ok "New-UI under app/ survives a Vue2 deploy" \
  || bad "New-UI under app/ survives a Vue2 deploy"

# --delete must still do its job for everything the Vue2 build DOES own,
# otherwise "protect" has been widened into "never delete anything" and stale
# hashed chunks accumulate forever.
[[ ! -f "$TMP/live/old-chunk.js" ]] \
  && ok "stale root files are still deleted" \
  || bad "stale root files are still deleted"

[[ -f "$TMP/live/index.html" ]] \
  && ok "the Vue2 build itself lands" || bad "the Vue2 build itself lands"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
