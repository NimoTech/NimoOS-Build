#!/usr/bin/env bash
# Tests for install-qdrant.sh's start_and_verify. Run:
#   bash scripts/install-qdrant.ready.test.sh
#
# Rules under test:
#   - readiness is an answering /healthz, not a listening port;
#   - Qdrant that never answers within NIMO_QDRANT_READY_TIMEOUT fails the
#     install (non-zero), so a caller such as nimoos-stack-install.sh stops
#     before Parser;
#   - every probe carries --max-time, so a port that accepts and never answers
#     cannot stall the wait past its budget;
#   - Qdrant that answers after a few tries passes.
#
# The real function runs, extracted from the script with its log helpers;
# curl and systemctl are stubs. Nothing real is started.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/install-qdrant.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

{ sed -n '/^log_info()/,/^log_fail()/p' "$SRC"; sed -n '/^start_and_verify() {/,/^}/p' "$SRC"; } > "$TMP/fn.sh"
grep -q '^start_and_verify() {' "$TMP/fn.sh" || { echo "  FAIL — could not extract start_and_verify"; exit 1; }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$TMP/calls"
SHIM
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$TMP/calls"
case "$*" in *6333/healthz*) ;; *) exit 0 ;; esac
n=$(( $(cat "$TMP/probes" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/probes"
[[ "${FAKE_READY_AFTER:-never}" != never && "$n" -ge "$FAKE_READY_AFTER" ]]
SHIM
chmod +x "$TMP/bin/systemctl" "$TMP/bin/curl"
export TMP
run() {   # run <env...>: start_and_verify in a subshell; sets rc, secs, out
  rm -f "$TMP/calls" "$TMP/probes"
  local start=$SECONDS
  env "$@" PATH="$TMP/bin:$PATH" bash -c 'set -e; SERVICE_FILE=qdrant.service; sudo_cmd=""; source "$1"; start_and_verify' _ "$TMP/fn.sh" > "$TMP/out" 2>&1
  rc=$?; secs=$((SECONDS - start))
}

echo "start_and_verify"
run FAKE_READY_AFTER=3 NIMO_QDRANT_READY_TIMEOUT=20
[[ $rc -eq 0 ]] && grep -q 'qdrant is up' "$TMP/out" && ok "answers on the 3rd probe: succeeds" || { bad "ready Qdrant: rc=$rc"; cat "$TMP/out"; }
[[ "$(cat "$TMP/probes")" -eq 3 ]] && ok "stops probing once it answers" || bad "probes: $(cat "$TMP/probes")"

run FAKE_READY_AFTER=never NIMO_QDRANT_READY_TIMEOUT=3
[[ $rc -ne 0 ]] && grep -q 'did not answer /healthz within 3s' "$TMP/out" && ok "never answers: fails (rc=$rc)" || { bad "unready Qdrant returned rc=$rc"; cat "$TMP/out"; }
[[ $secs -le 8 ]] && ok "gives up within the budget (${secs}s for a 3s budget)" || bad "took ${secs}s"
grep -q 'systemctl status qdrant.service' "$TMP/calls" && ok "shows the unit status on failure" || bad "no status on failure"

grep '6333/healthz' "$TMP/calls" | grep -vq -- '--max-time' && bad "a /healthz probe without --max-time" || ok "every /healthz probe carries --max-time"
grep -q 'ss -tln' "$TMP/fn.sh" && bad "still judges readiness by a listening port" || ok "readiness is /healthz, not a listening port"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
