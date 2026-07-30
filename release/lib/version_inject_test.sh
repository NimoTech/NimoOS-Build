#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../versions.conf"
source "$HERE/version_inject.sh"

# 1) 派生
[ "$VERSION_GATEWAY" = "v${NIMOOS_VERSION}" ] || { echo "FAIL derive: $VERSION_GATEWAY"; exit 1; }
[ "$NIMOOS_VERSION" = "1.9.2-alpha1" ] || { echo "FAIL NIMOOS_VERSION: $NIMOOS_VERSION"; exit 1; }
# 2) NIMOOS_BUILD 已设 -> 直接用
out="$(NIMOOS_BUILD=42 resolve_full_version)"
[ "$out" = "1.9.2-alpha1+42" ] || { echo "FAIL env build: $out"; exit 1; }
# 3) 未设 -> g<sha> 前缀
out="$(resolve_full_version)"
case "$out" in "1.9.2-alpha1+g"*) : ;; *) echo "FAIL sha build: $out"; exit 1;; esac
# 4) 符号表
[ "${GO_VERSION_SYM[gateway]}" = "github.com/NimoTech/NimoOS-Gateway/common.Version" ] || { echo "FAIL sym"; exit 1; }
echo "PASS"
