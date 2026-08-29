#!/usr/bin/env bash
# Regression test: a UI deploy must not delete either generation of hashed chunks.
#
# `deploy-ui.sh` rsyncs the build output over /var/lib/nimoos/www with --delete.
# Two directories in the live tree are deliberately NOT in any fresh build output
# and must survive:
#   assets/  — the previous build's hashed chunks (open tabs still lazy-load them
#              per the old index.html; deleting them makes lazy routes 404)
#   app/     — the legacy /app/ mount from the Vue2-coexistence era (old bookmarks
#              and still-open tabs; deploy-ui.sh overlays a redirect page on it)
# Before these filters existed, a bare --delete removed the whole of the other
# side silently — no error, just a section of the product that stopped existing.
#
# The filters are READ OUT OF THE SCRIPT rather than repeated here: a test that
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

echo "deploy-ui.sh asset/legacy protection"

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

# Stand in for the two sides: a fresh build output (new index + new hashed
# chunks), and a live www carrying the previous build's chunks plus the legacy
# app/ mount.
mkdir -p "$TMP/build/assets" "$TMP/live/assets" "$TMP/live/app/assets"
echo new-index > "$TMP/build/index.html"
echo new-chunk > "$TMP/build/assets/main-new456.js"
echo old-chunk > "$TMP/live/assets/main-old123.js"
echo legacy-chunk > "$TMP/live/app/assets/main-abc123.js"
echo legacy-index > "$TMP/live/app/index.html"
echo stale > "$TMP/live/old-vue2-chunk.js"

# eval into an array, NOT bare word-splitting: the filter arguments contain
# quoted phrases ('protect app/***'), and splitting on whitespace hands rsync
# broken arguments. That failed the transfer outright — and the survival checks
# then PASSED, because nothing had happened at all. A green that means "the
# command never ran" is worse than a red one.
declare -a ARGS
eval "ARGS=($FLAGS)"
if ! rsync_out="$(rsync "${ARGS[@]}" "$TMP/build/" "$TMP/live/" 2>&1)"; then
  bad "rsync ran cleanly with the script's own flags"
  echo "        rsync said: $rsync_out"
else
  ok "rsync ran cleanly with the script's own flags"
fi

[[ -f "$TMP/live/assets/main-old123.js" ]] \
  && ok "the previous build's hashed chunks survive (open tabs keep lazy-loading)" \
  || bad "the previous build's hashed chunks survive (open tabs keep lazy-loading)"

[[ -f "$TMP/live/app/index.html" && -f "$TMP/live/app/assets/main-abc123.js" ]] \
  && ok "the legacy app/ mount survives" \
  || bad "the legacy app/ mount survives"

# --delete must still do its job for everything the build DOES own at the root,
# otherwise "protect" has been widened into "never delete anything" and the
# retired Vue 2 panel's leftovers stay forever.
[[ ! -f "$TMP/live/old-vue2-chunk.js" ]] \
  && ok "stale root files are still deleted" \
  || bad "stale root files are still deleted"

[[ -f "$TMP/live/index.html" && -f "$TMP/live/assets/main-new456.js" ]] \
  && ok "the fresh build itself lands" || bad "the fresh build itself lands"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
