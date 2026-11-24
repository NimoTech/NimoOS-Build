#!/usr/bin/env bash
# Tests for install-qdrant.sh's readiness check (qdrant_health_url + start_and_verify). Run:
#   bash scripts/install-qdrant.ready.test.sh
#
# Rules under test:
#   - readiness is an answering /healthz, not a listening port;
#   - the native mode probes the address its config.yaml listens on (an
#     existing config is kept): a custom http_port is followed, a wildcard host
#     is probed on loopback, IPv6 hosts are bracketed, NIMO_QDRANT_HEALTH_URL
#     overrides; no config means 127.0.0.1:6333; docker keeps 127.0.0.1:6333;
#   - Qdrant that never answers within NIMO_QDRANT_READY_TIMEOUT fails the
#     install (non-zero), so a caller such as nimoos-stack-install.sh stops
#     before Parser; the message names the URL and how to point it elsewhere;
#   - the budget is strict: every probe's --max-time is capped by the time
#     left, so probes that hang cannot stretch it;
#   - Qdrant that answers after a few tries passes.
#
# The real functions run, extracted from the script with its log helpers;
# curl and systemctl are stubs. Nothing real is started.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/install-qdrant.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

{ sed -n '/^log_info()/,/^log_fail()/p' "$SRC"
  sed -n '/^qdrant_health_url() {/,/^}/p' "$SRC"
  sed -n '/^start_and_verify() {/,/^}/p' "$SRC"; } > "$TMP/fn.sh"
grep -q '^start_and_verify() {' "$TMP/fn.sh" && grep -q '^qdrant_health_url() {' "$TMP/fn.sh" \
  || { echo "  FAIL — could not extract the readiness functions"; exit 1; }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$TMP/calls"
SHIM
# FAKE_READY_URL: the only URL that answers; FAKE_READY_AFTER: answer from that probe on;
# FAKE_HANG=1: every probe hangs until its --max-time.
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$TMP/calls"
url="${!#}"
case "$url" in */healthz) ;; *) exit 0 ;; esac
max=""; prev=""; for a in "$@"; do [[ "$prev" == --max-time ]] && max="$a"; prev="$a"; done
if [[ "${FAKE_HANG:-0}" == 1 ]]; then sleep "$max"; exit 28; fi
n=$(( $(cat "$TMP/probes" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/probes"
[[ "$url" == "${FAKE_READY_URL:-http://127.0.0.1:6333/healthz}" ]] || exit 7
[[ "${FAKE_READY_AFTER:-never}" != never && "$n" -ge "$FAKE_READY_AFTER" ]]
SHIM
chmod +x "$TMP/bin/systemctl" "$TMP/bin/curl"
export TMP
CONF="$TMP/config.yaml"
url_for() {   # url_for <env...>: what qdrant_health_url prints for $CONF
  env "$@" bash -c 'CONF_FILE="$1"; source "$2"; qdrant_health_url' _ "$CONF" "$TMP/fn.sh"
}
run() {   # run <env...>: native start_and_verify "$(qdrant_health_url)" in a subshell; sets rc, secs
  rm -f "$TMP/calls" "$TMP/probes"
  local start=$SECONDS
  env "$@" PATH="$TMP/bin:$PATH" bash -c 'set -e; SERVICE_FILE=qdrant.service; CONF_FILE="$1"; sudo_cmd=""; source "$2"; start_and_verify "$(qdrant_health_url)"' _ "$CONF" "$TMP/fn.sh" > "$TMP/out" 2>&1
  rc=$?; secs=$((SECONDS - start))
}

echo "qdrant_health_url"
rm -f "$CONF"
[[ "$(url_for)" == "http://127.0.0.1:6333/healthz" ]] && ok "no config: 127.0.0.1:6333" || bad "no config: $(url_for)"
printf 'log_level: INFO\nstorage:\n  storage_path: /x\nservice:\n  host: 127.0.0.1\n  http_port: 6335\n  grpc_port: 6336\ntelemetry_disabled: true\n' > "$CONF"
[[ "$(url_for)" == "http://127.0.0.1:6335/healthz" ]] && ok "custom http_port is followed" || bad "custom port: $(url_for)"
printf 'service:\n  host: 0.0.0.0\n  http_port: "6340"\n' > "$CONF"
[[ "$(url_for)" == "http://127.0.0.1:6340/healthz" ]] && ok "wildcard host → loopback, quoted port" || bad "wildcard: $(url_for)"
printf 'service:\n  host: ::1\n' > "$CONF"
[[ "$(url_for)" == "http://[::1]:6333/healthz" ]] && ok "IPv6 host is bracketed" || bad "ipv6: $(url_for)"
printf 'storage:\n  http_port: 7000\nservice:\n  grpc_port: 6334\n' > "$CONF"
[[ "$(url_for)" == "http://127.0.0.1:6333/healthz" ]] && ok "keys outside service: are ignored" || bad "scoping: $(url_for)"
[[ "$(url_for NIMO_QDRANT_HEALTH_URL=http://10.0.0.5:7333/healthz)" == "http://10.0.0.5:7333/healthz" ]] && ok "NIMO_QDRANT_HEALTH_URL overrides" || bad "override ignored"
grep -q '^    start_and_verify "$(qdrant_health_url)"$' "$SRC" && ok "native mode probes the configured address" || bad "native mode does not use qdrant_health_url"
grep -q '^    start_and_verify "${NIMO_QDRANT_HEALTH_URL:-http://127.0.0.1:6333/healthz}"$' "$SRC" && ok "docker mode keeps its fixed 127.0.0.1:6333 mapping" || bad "docker mode wiring"

echo "start_and_verify"
rm -f "$CONF"
run FAKE_READY_AFTER=3 NIMO_QDRANT_READY_TIMEOUT=20
[[ $rc -eq 0 ]] && grep -q 'qdrant is up' "$TMP/out" && ok "answers on the 3rd probe: succeeds" || { bad "ready Qdrant: rc=$rc"; cat "$TMP/out"; }
[[ "$(cat "$TMP/probes")" -eq 3 ]] && ok "stops probing once it answers" || bad "probes: $(cat "$TMP/probes")"

printf 'service:\n  host: 127.0.0.1\n  http_port: 6335\n' > "$CONF"
run FAKE_READY_URL=http://127.0.0.1:6335/healthz FAKE_READY_AFTER=1 NIMO_QDRANT_READY_TIMEOUT=5
[[ $rc -eq 0 ]] && ! grep -q '6333/healthz' "$TMP/calls" && ok "a healthy Qdrant on its configured port 6335 passes (6333 never probed)" || { bad "custom port: rc=$rc"; cat "$TMP/out"; }
rm -f "$CONF"

run FAKE_READY_AFTER=never NIMO_QDRANT_READY_TIMEOUT=3
[[ $rc -ne 0 ]] && grep -q 'did not answer http://127.0.0.1:6333/healthz within 3s' "$TMP/out" && ok "never answers: fails (rc=$rc)" || { bad "unready Qdrant returned rc=$rc"; cat "$TMP/out"; }
grep -q 'NIMO_QDRANT_HEALTH_URL' "$TMP/out" && ok "the failure says how to point the check elsewhere" || bad "no hint in the failure"
[[ $secs -le 5 ]] && ok "gives up within the budget (${secs}s for a 3s budget)" || bad "took ${secs}s"
grep -q 'systemctl status qdrant.service' "$TMP/calls" && ok "shows the unit status on failure" || bad "no status on failure"

run FAKE_HANG=1 NIMO_QDRANT_READY_TIMEOUT=4
maxes="$(grep '/healthz' "$TMP/calls" | sed -E 's/.*--max-time ([0-9]+).*/\1/' | tr '\n' ' ')"
[[ $rc -ne 0 && $secs -le 5 ]] && ok "hanging probes: still gives up on time (${secs}s for 4s; --max-time: ${maxes})" || bad "hanging probes: rc=$rc ${secs}s (--max-time: ${maxes})"
grep '/healthz' "$TMP/calls" | grep -vq -- '--max-time' && bad "a /healthz probe without --max-time" || ok "every /healthz probe carries --max-time"
grep -q 'ss -tln' "$TMP/fn.sh" && bad "still judges readiness by a listening port" || ok "readiness is /healthz, not a listening port"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
