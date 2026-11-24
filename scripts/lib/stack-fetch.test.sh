#!/usr/bin/env bash
# stack-fetch.sh: NIMO_DEPS_BASE 必须跟随 NIMO_DOWNLOAD_DOMAIN, 显式值优先。
# 运行: bash scripts/lib/stack-fetch.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

got="$(bash -c "source '$HERE/stack-fetch.sh'; echo \"\$NIMO_DEPS_BASE\"")"
[ "$got" = "https://get.nimotech.ai/deps" ] && ok "default deps base unchanged" || bad "default: $got"

got="$(NIMO_DOWNLOAD_DOMAIN=http://192.168.1.118:9800/dl/ bash -c "source '$HERE/stack-fetch.sh'; echo \"\$NIMO_DEPS_BASE\"")"
[ "$got" = "http://192.168.1.118:9800/dl/deps" ] && ok "deps base follows LAN domain" || bad "lan: $got"

got="$(NIMO_DOWNLOAD_DOMAIN=http://x/ NIMO_DEPS_BASE=http://explicit/d bash -c "source '$HERE/stack-fetch.sh'; echo \"\$NIMO_DEPS_BASE\"")"
[ "$got" = "http://explicit/d" ] && ok "explicit deps base wins" || bad "explicit: $got"

# install-qdrant.sh 独立运行 (无 lib) 时的兜底也要跟随域名
got="$(NIMO_DOWNLOAD_DOMAIN=http://lan/ bash -c "$(sed -n '/^: "\${NIMO_DEPS_BASE:=/p' "$HERE/../install-qdrant.sh"); echo \"\$NIMO_DEPS_BASE\"")"
[ "$got" = "http://lan/deps" ] && ok "install-qdrant fallback follows domain" || bad "qdrant fallback: $got"

got="$(NIMO_DOWNLOAD_DOMAIN=http://lan/ bash -c "$(sed -n '/^: "\${NIMO_SCRIPTS_BASE:=/p' "$HERE/../nimoos-stack-install.sh"); echo \"\$NIMO_SCRIPTS_BASE\"")"
[ "$got" = "http://lan/get/scripts" ] && ok "stack-install scripts base follows domain" || bad "scripts base: $got"

# 校验 NIMO_DOWNLOAD_DOMAIN 缺省行确实存在, 且紧邻派生行的正上方
# (防止上面两条断言在未新增该行的情况下也能"假通过", 因为测试提前把
#  NIMO_DOWNLOAD_DOMAIN 塞进了环境变量)
if grep -B1 '^: "\${NIMO_DEPS_BASE:=' "$HERE/../install-qdrant.sh" | head -1 | grep -qx ': "${NIMO_DOWNLOAD_DOMAIN:=https://get.nimotech.ai/}"'; then
    ok "install-qdrant has adjacent NIMO_DOWNLOAD_DOMAIN default"
else
    bad "install-qdrant: NIMO_DOWNLOAD_DOMAIN default line missing or not adjacent"
fi

if grep -B1 '^: "\${NIMO_SCRIPTS_BASE:=' "$HERE/../nimoos-stack-install.sh" | head -1 | grep -qx ': "${NIMO_DOWNLOAD_DOMAIN:=https://get.nimotech.ai/}"'; then
    ok "nimoos-stack-install has adjacent NIMO_DOWNLOAD_DOMAIN default"
else
    bad "nimoos-stack-install: NIMO_DOWNLOAD_DOMAIN default line missing or not adjacent"
fi

# 独立脚本裸跑(未设置任何相关环境变量)时的生产缺省值必须字节不变
lines="$(grep -A1 '^: "\${NIMO_DOWNLOAD_DOMAIN:=' "$HERE/../install-qdrant.sh")"
got="$(env -u NIMO_DOWNLOAD_DOMAIN -u NIMO_DEPS_BASE -u NIMO_SCRIPTS_BASE bash -c "$lines; echo \$NIMO_DEPS_BASE")"
[ "$got" = "https://get.nimotech.ai/deps" ] && ok "install-qdrant bare production default" || bad "qdrant bare default: $got"

lines="$(grep -A1 '^: "\${NIMO_DOWNLOAD_DOMAIN:=' "$HERE/../nimoos-stack-install.sh")"
got="$(env -u NIMO_DOWNLOAD_DOMAIN -u NIMO_DEPS_BASE -u NIMO_SCRIPTS_BASE bash -c "$lines; echo \$NIMO_SCRIPTS_BASE")"
[ "$got" = "https://get.nimotech.ai/get/scripts" ] && ok "stack-install bare production default" || bad "stack-install bare default: $got"

# 域名末尾无斜杠时也要正确拼接 (不产生双斜杠或漏斜杠)
got="$(NIMO_DOWNLOAD_DOMAIN=http://lan bash -c "source '$HERE/stack-fetch.sh'; echo \"\$NIMO_DEPS_BASE\"")"
[ "$got" = "http://lan/deps" ] && ok "deps base handles domain with no trailing slash" || bad "no-trailing-slash: $got"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
