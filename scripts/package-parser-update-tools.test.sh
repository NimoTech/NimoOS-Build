#!/usr/bin/env bash
# Tests for package-parser-update-tools.sh. Run:
#   bash scripts/package-parser-update-tools.test.sh
#
# Rules under test:
#   - the bundle holds exactly the five updater files, the helper at 0755, and
#     its .sha256 verifies;
#   - two runs over the same checkout give byte-identical bundles;
#   - a helper without its execute bit, or a missing file, fails the packager
#     and publishes nothing;
#   - an existing bundle is never overwritten.
#
# The packager runs from a copy of this checkout's scripts/ in a sandbox.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

box() {   # box <name>: a copy of the five files plus the packager, modes kept
  local d="$TMP/$1/scripts"; mkdir -p "$d/lib"
  cp -p "$HERE/package-parser-update-tools.sh" "$HERE/install-parser.sh" "$d/"
  cp -p "$HERE/lib/stack-fetch.sh" "$HERE/lib/parser-gpu-branch.sh" "$HERE/lib/parser_components.py" "$HERE/lib/parser-component-helper.sh" "$d/lib/"
  echo "$d"
}

echo "package-parser-update-tools.sh"
d="$(box good)"
bash "$d/package-parser-update-tools.sh" "$TMP/out1" > /dev/null 2>&1 && ok "packages a complete checkout" || bad "failed on a complete checkout"
list="$(tar -tzf "$TMP/out1/parser-update-tools.tar.gz" | LC_ALL=C sort | tr '\n' ' ')"
[[ "$list" == "install-parser.sh lib/parser-component-helper.sh lib/parser-gpu-branch.sh lib/parser_components.py lib/stack-fetch.sh " ]] \
  && ok "exactly the five updater files" || bad "contents: $list"
tar -tvzf "$TMP/out1/parser-update-tools.tar.gz" | awk '$6=="lib/parser-component-helper.sh"{print $1}' | grep -qx -- '-rwxr-xr-x' \
  && ok "helper is 0755 inside the bundle" || bad "helper mode: $(tar -tvzf "$TMP/out1/parser-update-tools.tar.gz" | grep helper)"
(cd "$TMP/out1" && sha256sum -c --quiet parser-update-tools.tar.gz.sha256) && ok ".sha256 verifies" || bad ".sha256 does not verify"
bash "$d/package-parser-update-tools.sh" "$TMP/out2" > /dev/null 2>&1
cmp -s "$TMP/out1/parser-update-tools.tar.gz" "$TMP/out2/parser-update-tools.tar.gz" && ok "reproducible: a second run is byte-identical" || bad "two runs differ"
bash "$d/package-parser-update-tools.sh" "$TMP/out1" > "$TMP/log" 2>&1 && bad "overwrote an existing bundle" || ok "refuses to overwrite an existing bundle"

d="$(box nox)"; chmod 644 "$d/lib/parser-component-helper.sh"
bash "$d/package-parser-update-tools.sh" "$TMP/out3" > "$TMP/log" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'must be executable: lib/parser-component-helper.sh' "$TMP/log" && ok "helper without +x: fails (rc=$rc)" || { bad "helper without +x: rc=$rc"; cat "$TMP/log"; }
[[ -z "$(ls -A "$TMP/out3" 2>/dev/null)" ]] && ok "helper without +x: publishes nothing" || bad "left: $(ls -A "$TMP/out3")"

d="$(box missing)"; rm "$d/lib/parser-gpu-branch.sh"
bash "$d/package-parser-update-tools.sh" "$TMP/out4" > "$TMP/log" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'missing updater file: lib/parser-gpu-branch.sh' "$TMP/log" && [[ -z "$(ls -A "$TMP/out4" 2>/dev/null)" ]] \
  && ok "missing file: fails and publishes nothing" || bad "missing file: rc=$rc left=$(ls -A "$TMP/out4" 2>/dev/null)"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
