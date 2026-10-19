#!/usr/bin/env bash
# nimoos-update.sh 最后打印的运行版本：问 core 服务自己公布的地址
# (/var/run/nimoos/nimoos.url),不走 80 端口 —— Gateway 对未签名的本机请求回 401。
# 运行: bash nimoos-update.version.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
U="$HERE/nimoos-update.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

bash -n "$U" && ok "update: syntax" || bad "update: syntax"

# Stub curl to see which address is asked.
rv="$(awk '/^Running_Version\(\)/,/^}/' "$U")"
if [ -z "$rv" ]; then bad "update: Running_Version defined"; else
    T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/run"
    printf 'http://127.0.0.1:43659\n' >"$T/run/nimoos.url"
    cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a; do u="$a"; done
echo "$u" >>"$STUB_LOG"
case "$u" in http://127.0.0.1:43659/v1/sys/version) echo '{"data":{"current_version":"1.9.4-alpha1"}}';; *) echo '{"success":401}';; esac
STUB
    chmod +x "$T/bin/curl"
    got="$(PATH="$T/bin:$PATH" STUB_LOG="$T/log" NIMO_RUN_DIR="$T/run" bash -c "$rv; Running_Version")"
    [ "$got" = "1.9.4-alpha1" ] && ok "update: running version read from the core service" || bad "update: running version = '$got' ($(cat "$T/log" 2>/dev/null | tr '\n' ' '))"
    rm -f "$T/run/nimoos.url"
    got="$(PATH="$T/bin:$PATH" STUB_LOG="$T/log" NIMO_RUN_DIR="$T/run" bash -c "nimoos() { echo 'git commit: private build'; }; $rv; Running_Version")"
    [ -z "$got" ] && ok "update: no address file, no version guessed from noise" || bad "update: without the address file got '$got'"
    rm -rf "$T"
fi
grep -q '^running="$(Running_Version)"' "$U" && ok "update: final line uses Running_Version" || bad "update: final line still asks the binary"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
