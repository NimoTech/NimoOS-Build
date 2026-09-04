#!/usr/bin/env bash
# Tests for lib/parser-unit.sh. Run: bash scripts/lib/parser-unit.test.sh
#
# Touches nothing real: unit files live under mktemp, `systemctl` is a shim on
# PATH that records its calls and answers MemoryMax from FAKE_MEMMAX, and
# NIMO_SUDO is emptied so nothing escalates.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_CALLS}"
if [[ "$1" == "show" ]]; then echo "${FAKE_MEMMAX-12884901888}"; fi
exit 0
SHIM
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"
export FAKE_CALLS="$TMP/calls"
export NIMO_SUDO=""

# shellcheck source=parser-unit.sh
source "$HERE/parser-unit.sh" || { echo "  FAIL — source parser-unit.sh"; exit 1; }

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok   — $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL — $1"; }
reset() { : > "$FAKE_CALLS"; unset FAKE_MEMMAX; }
calls() { cat "$FAKE_CALLS" 2>/dev/null; }

SRC="$TMP/template.service"
DST="$TMP/installed/nimoos-parser.service"
printf '[Service]\nMemoryMax=12G\n' > "$SRC"

echo "parser-unit.sh"

# 1. no installed unit yet: install it and daemon-reload
reset; rm -rf "$(dirname "$DST")"
out="$(sync_parser_unit "$SRC" "$DST" nimoos-parser.service)"; rc=$?
[[ $rc -eq 0 && "$out" == "updated" ]] && ok "missing unit → updated (rc 0)" || bad "missing unit → updated (got rc=$rc out=$out)"
cmp -s "$SRC" "$DST" && ok "missing unit → file copied" || bad "missing unit → file copied"
calls | grep -q '^daemon-reload$' && ok "missing unit → daemon-reload" || bad "missing unit → daemon-reload"

# 2. identical unit: touch nothing
reset
out="$(sync_parser_unit "$SRC" "$DST" nimoos-parser.service)"; rc=$?
[[ $rc -eq 0 && "$out" == "unchanged" ]] && ok "identical unit → unchanged (rc 0)" || bad "identical unit → unchanged (got rc=$rc out=$out)"
calls | grep -q 'daemon-reload' && bad "identical unit → no daemon-reload" || ok "identical unit → no daemon-reload"

# 3. drifted unit: overwrite with the template and daemon-reload
reset; printf '[Service]\n' > "$DST"
out="$(sync_parser_unit "$SRC" "$DST" nimoos-parser.service)"; rc=$?
[[ $rc -eq 0 && "$out" == "updated" ]] && ok "drifted unit → updated (rc 0)" || bad "drifted unit → updated (got rc=$rc out=$out)"
cmp -s "$SRC" "$DST" && ok "drifted unit → template wins" || bad "drifted unit → template wins"
calls | grep -q '^daemon-reload$' && ok "drifted unit → daemon-reload" || bad "drifted unit → daemon-reload"

# 4. the memory ceiling must be in effect afterwards (the 2026-07-28 OOM lesson)
reset; export FAKE_MEMMAX=infinity
sync_parser_unit "$SRC" "$DST" nimoos-parser.service >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "MemoryMax=infinity → rc 2" || bad "MemoryMax=infinity → rc 2 (got $rc)"
reset; export FAKE_MEMMAX=""
sync_parser_unit "$SRC" "$DST" nimoos-parser.service >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "MemoryMax empty → rc 2" || bad "MemoryMax empty → rc 2 (got $rc)"

# 5. missing template is a hard error, and the installed unit is left alone
reset; cp "$SRC" "$DST"
sync_parser_unit "$TMP/nope.service" "$DST" nimoos-parser.service >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "missing template → rc 1" || bad "missing template → rc 1 (got $rc)"
cmp -s "$SRC" "$DST" && ok "missing template → installed unit untouched" || bad "missing template → installed unit untouched"

echo ""; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
