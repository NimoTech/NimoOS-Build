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
#   - Qdrant that answers after a few tries passes;
#   - a Qdrant whose config.yaml sets service.api_key (or only read_only_api_key)
#     is probed with that key, NIMO_QDRANT_API_KEY overrides (also with
#     NIMO_QDRANT_HEALTH_URL); the key goes to curl on stdin, never as an
#     argument and never into the output; no key means no auth header. One case
#     runs the real curl against a local server that only answers the right key.
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
  sed -n '/^qdrant_api_key() {/,/^}/p' "$SRC"
  sed -n '/^qdrant_curl() {/,/^}/p' "$SRC"
  sed -n '/^start_and_verify() {/,/^}/p' "$SRC"; } > "$TMP/fn.sh"
grep -q '^start_and_verify() {' "$TMP/fn.sh" && grep -q '^qdrant_health_url() {' "$TMP/fn.sh" && grep -q '^qdrant_curl() {' "$TMP/fn.sh" \
  || { echo "  FAIL — could not extract the readiness functions"; exit 1; }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$TMP/calls"
SHIM
# FAKE_READY_URL: the only URL that answers; FAKE_READY_AFTER: answer from that probe on;
# FAKE_HANG=1: every probe hangs until its --max-time.
# FAKE_REQUIRE_KEY: /healthz answers only when curl got `header = "api-key: <key>"` on stdin.
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$TMP/calls"
cfg=""; [[ " $* " == *" --config - "* ]] && cfg="$(cat)" && echo "stdin: $cfg" >> "$TMP/stdin"
url="${!#}"
case "$url" in */healthz) ;; *) exit 0 ;; esac
if [[ -n "${FAKE_REQUIRE_KEY:-}" && "$cfg" != "header = \"api-key: ${FAKE_REQUIRE_KEY}\"" ]]; then exit 22; fi
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
  rm -f "$TMP/calls" "$TMP/probes" "$TMP/stdin"
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

echo "API key"
printf 'service:\n  host: 127.0.0.1\n  http_port: 6333\n  api_key: s3cret-key-1  # keep\n' > "$CONF"
run FAKE_REQUIRE_KEY=s3cret-key-1 FAKE_READY_AFTER=1 NIMO_QDRANT_READY_TIMEOUT=5
[[ $rc -eq 0 ]] && ok "service.api_key in config.yaml: the probe authenticates and passes" || { bad "keyed Qdrant: rc=$rc"; cat "$TMP/out"; }
! grep -q 's3cret-key-1' "$TMP/calls" && ok "the key is never a curl argument (ps-visible)" || bad "the key is on the command line"
! grep -q 's3cret-key-1' "$TMP/out" && ok "the key is never in the output" || bad "the key is in the output"
grep -q '/collections' "$TMP/calls" && [[ "$(grep -c 'api-key' "$TMP/stdin")" -ge 2 ]] && ok "the /collections peek authenticates too" || bad "/collections without the key"
printf 'service:\n  read_only_api_key: "ro-key-2"\n' > "$CONF"
run FAKE_REQUIRE_KEY=ro-key-2 FAKE_READY_AFTER=1 NIMO_QDRANT_READY_TIMEOUT=5
[[ $rc -eq 0 ]] && ok "only read_only_api_key: used for the probe" || bad "read-only key: rc=$rc"
printf 'storage:\n  api_key: not-this\nservice:\n  http_port: 6333\n' > "$CONF"
run FAKE_READY_AFTER=1 NIMO_QDRANT_READY_TIMEOUT=5
[[ $rc -eq 0 ]] && [[ ! -s "$TMP/stdin" ]] && ! grep -q -- '--config' "$TMP/calls" && ok "no key under service: → no auth header, plain probe" || bad "sent a header without a key"
rm -f "$CONF"
run NIMO_QDRANT_API_KEY=env-key-3 NIMO_QDRANT_HEALTH_URL=http://10.9.9.9:7333/healthz FAKE_READY_URL=http://10.9.9.9:7333/healthz FAKE_REQUIRE_KEY=env-key-3 FAKE_READY_AFTER=1 NIMO_QDRANT_READY_TIMEOUT=5
[[ $rc -eq 0 ]] && ! grep -q 'env-key-3' "$TMP/calls" && ok "NIMO_QDRANT_API_KEY with NIMO_QDRANT_HEALTH_URL: authenticated, key off the command line" || bad "env key + URL override: rc=$rc"
printf 'service:\n  api_key: s3cret-key-1\n' > "$CONF"
run FAKE_REQUIRE_KEY=s3cret-key-1 FAKE_READY_AFTER=never NIMO_QDRANT_READY_TIMEOUT=2
[[ $rc -ne 0 ]] && grep -q 'NIMO_QDRANT_API_KEY' "$TMP/out" && ! grep -q 's3cret-key-1' "$TMP/out" && ok "a failure mentions NIMO_QDRANT_API_KEY, still without the key" || bad "failure message: $(tail -2 "$TMP/out")"

echo "API key, real curl"
if command -v python3 >/dev/null; then
  KEY='k"e\y-4'
  cat > "$TMP/srv.py" <<'PY'
import http.server, sys
want = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.headers.get("api-key") == want
        self.send_response(200 if ok else 401); self.end_headers(); self.wfile.write(b"ok" if ok else b"no")
        open(sys.argv[3], "a").write(("good" if ok else "bad:" + repr(self.headers.get("api-key"))) + "\n")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
  python3 -I "$TMP/srv.py" "$TMP/port" "$KEY" "$TMP/seen" & srv=$!
  for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  printf "service:\n  host: 127.0.0.1\n  http_port: %s\n  api_key: '%s'\n" "$(cat "$TMP/port")" "$KEY" > "$CONF"
  rm -f "$TMP/seen"
  env NIMO_QDRANT_READY_TIMEOUT=5 bash -c 'set -e; SERVICE_FILE=qdrant.service; CONF_FILE="$1"; sudo_cmd=""; source "$2"
      systemctl() { :; }; start_and_verify "$(qdrant_health_url)"' _ "$CONF" "$TMP/fn.sh" > "$TMP/out" 2>&1; rc=$?
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  [[ $rc -eq 0 ]] && grep -qx good "$TMP/seen" && ! grep -q bad "$TMP/seen" \
    && ok "real curl sends the exact key (quote and backslash escaped) and passes" || { bad "real curl: rc=$rc seen=$(cat "$TMP/seen" 2>/dev/null)"; cat "$TMP/out"; }
  rm -f "$CONF"
else
  ok "(no python3: real-curl case skipped)"
fi

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
