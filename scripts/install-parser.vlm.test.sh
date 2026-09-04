#!/usr/bin/env bash
# Tests for install-parser.sh's caption-weight selection. Run: bash scripts/install-parser.vlm.test.sh
#
# The installer runs its main flow on load, so the functions under test are
# lifted out of the file with sed and sourced into a sandbox: models land under
# mktemp, `curl` is a shim that serves fixture tarballs (or fails on demand),
# the hardware probe is overridden, and sudo is emptied. Nothing real is touched.
#
# Rule under test: an Intel GPU machine gets the OpenVINO IR and skips the
# GGUF; the GGUF is only fetched when the IR is unavailable (no Intel GPU,
# download failed, checksum mismatch) or forced with NIMO_PARSER_VLM_GGUF=1.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-parser.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v zstd >/dev/null || { echo "  skip — zstd not installed"; exit 0; }

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok   — $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL — $1"; }

# ---- lift the functions out of the installer -------------------------------
extract() { sed -n "/^$1() {/,/^}/p" "$SCRIPT"; }
LIB="$TMP/lib.sh"
for f in use_prebuilt ensure_zstd has_intel_gpu vlm_ir_present fetch_vlm_model fetch_vlm_ov_model; do
    extract "$f" >> "$LIB"
    grep -q "^$f() {" "$LIB" && ok "installer defines $f()" || bad "installer defines $f()"
done
grep -qE '^readonly DEP_VLM_OV_SHA256="[0-9a-f]{64}"$' "$SCRIPT" && ok "DEP_VLM_OV_SHA256 is a pinned sha256" || bad "DEP_VLM_OV_SHA256 is a pinned sha256"
grep -qE '^readonly DEP_VLM_OV="parser/qwen3-vl-4b-int4-ov.tar.zst"$' "$SCRIPT" && ok "DEP_VLM_OV names the IR package" || bad "DEP_VLM_OV names the IR package"
# The IR must be fetched before the GGUF decision is made.
ov_line="$(grep -n '^fetch_vlm_ov_model$' "$SCRIPT" | cut -d: -f1)"; gguf_line="$(grep -n '^fetch_vlm_model$' "$SCRIPT" | cut -d: -f1)"
[[ -n "$ov_line" && -n "$gguf_line" && "$ov_line" -lt "$gguf_line" ]] && ok "main flow runs fetch_vlm_ov_model before fetch_vlm_model" || bad "main flow runs fetch_vlm_ov_model before fetch_vlm_model"

# ---- fixtures: tiny stand-ins for the two packages -------------------------
mkdir -p "$TMP/fx/qwen3-vl-4b-int4" "$TMP/fx/qwen3-vl-4b-gguf"
echo ir > "$TMP/fx/qwen3-vl-4b-int4/openvino_language_model.xml"
echo g > "$TMP/fx/qwen3-vl-4b-gguf/model.gguf"; echo m > "$TMP/fx/qwen3-vl-4b-gguf/mmproj.gguf"
tar --zstd -cf "$TMP/fx/ov.tar.zst" -C "$TMP/fx" qwen3-vl-4b-int4
tar --zstd -cf "$TMP/fx/gguf.tar.zst" -C "$TMP/fx" qwen3-vl-4b-gguf
OV_SHA="$(sha256sum "$TMP/fx/ov.tar.zst" | cut -d' ' -f1)"

# curl shim: `curl ... -o <out> <url>`; serves the fixture matching the url,
# logs the url, fails when FAKE_CURL_FAIL matches it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) out="\$2"; shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
echo "\$url" >> "\$FAKE_CURL_LOG"
[[ -n "\${FAKE_CURL_FAIL:-}" && "\$url" == *"\$FAKE_CURL_FAIL"* ]] && exit 22
case "\$url" in *int4-ov*) cp "$TMP/fx/ov.tar.zst" "\$out";; *gguf*) cp "$TMP/fx/gguf.tar.zst" "\$out";; *) exit 22;; esac
SHIM
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export FAKE_CURL_LOG="$TMP/curl.log"

# ---- sandbox ---------------------------------------------------------------
log_info() { :; }; log_ok() { :; }; log_warn() { echo "WARN: $*" >> "$TMP/warn.log"; }
log_fail() { echo "FAIL: $*"; exit 1; }
sudo_cmd=""
NIMO_DEPS_BASE="http://deps.test"
DEP_VLM="parser/qwen3-vl-4b-gguf.tar.zst"
DEP_VLM_OV="parser/qwen3-vl-4b-int4-ov.tar.zst"
DEP_VLM_OV_SHA256="$OV_SHA"
# shellcheck disable=SC1090
source "$LIB"
use_prebuilt() { return 0; }
has_intel_gpu() { [[ "${FAKE_INTEL:-0}" == "1" ]]; }

scenario() {   # scenario <name> <env assignments...>
    VLM_MODELS_DIR="$TMP/models-$1"; mkdir -p "$VLM_MODELS_DIR"
    : > "$FAKE_CURL_LOG"; : > "$TMP/warn.log"
    unset FAKE_INTEL FAKE_CURL_FAIL NIMO_PARSER_VLM NIMO_PARSER_VLM_OV NIMO_PARSER_VLM_GGUF
    local kv; for kv in "${@:2}"; do export "$kv"; done
    fetch_vlm_ov_model; fetch_vlm_model
}
ir_present()   { [[ -f "$VLM_MODELS_DIR/qwen3-vl-4b-int4/openvino_language_model.xml" ]]; }
gguf_present() { [[ -f "$VLM_MODELS_DIR/qwen3-vl-4b-gguf/model.gguf" && -f "$VLM_MODELS_DIR/qwen3-vl-4b-gguf/mmproj.gguf" ]]; }
fetched()      { grep -q "$1" "$FAKE_CURL_LOG"; }

echo "install-parser.sh caption weights"

scenario intel FAKE_INTEL=1
ir_present   && ok "Intel GPU → IR unpacked" || bad "Intel GPU → IR unpacked"
gguf_present && bad "Intel GPU → GGUF skipped" || ok "Intel GPU → GGUF skipped"
fetched gguf.tar.zst && bad "Intel GPU → no GGUF download" || ok "Intel GPU → no GGUF download"

scenario amd FAKE_INTEL=0
ir_present   && bad "no Intel GPU → no IR" || ok "no Intel GPU → no IR"
fetched int4-ov && bad "no Intel GPU → no IR download attempted" || ok "no Intel GPU → no IR download attempted"
gguf_present && ok "no Intel GPU → GGUF unpacked" || bad "no Intel GPU → GGUF unpacked"

scenario irfail FAKE_INTEL=1 FAKE_CURL_FAIL=int4-ov
ir_present   && bad "IR download fails → no IR" || ok "IR download fails → no IR"
gguf_present && ok "IR download fails → GGUF fallback" || bad "IR download fails → GGUF fallback"
grep -q WARN "$TMP/warn.log" && ok "IR download fails → warns" || bad "IR download fails → warns"

DEP_VLM_OV_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
scenario badsha FAKE_INTEL=1
ir_present   && bad "IR checksum mismatch → not unpacked" || ok "IR checksum mismatch → not unpacked"
gguf_present && ok "IR checksum mismatch → GGUF fallback" || bad "IR checksum mismatch → GGUF fallback"
DEP_VLM_OV_SHA256="$OV_SHA"

scenario forceov FAKE_INTEL=0 NIMO_PARSER_VLM_OV=1
ir_present   && ok "NIMO_PARSER_VLM_OV=1 → IR even without Intel GPU" || bad "NIMO_PARSER_VLM_OV=1 → IR even without Intel GPU"
gguf_present && bad "NIMO_PARSER_VLM_OV=1 → GGUF skipped" || ok "NIMO_PARSER_VLM_OV=1 → GGUF skipped"

scenario skipov FAKE_INTEL=1 NIMO_PARSER_VLM_OV=0
ir_present   && bad "NIMO_PARSER_VLM_OV=0 → no IR" || ok "NIMO_PARSER_VLM_OV=0 → no IR"
gguf_present && ok "NIMO_PARSER_VLM_OV=0 → GGUF" || bad "NIMO_PARSER_VLM_OV=0 → GGUF"

scenario both FAKE_INTEL=1 NIMO_PARSER_VLM_GGUF=1
ir_present && gguf_present && ok "NIMO_PARSER_VLM_GGUF=1 → both forms" || bad "NIMO_PARSER_VLM_GGUF=1 → both forms"

scenario none FAKE_INTEL=1 NIMO_PARSER_VLM=0
ir_present || gguf_present && bad "NIMO_PARSER_VLM=0 → nothing" || ok "NIMO_PARSER_VLM=0 → nothing"
[[ -s "$FAKE_CURL_LOG" ]] && bad "NIMO_PARSER_VLM=0 → no downloads" || ok "NIMO_PARSER_VLM=0 → no downloads"

# idempotence: a second run with everything in place downloads nothing
: > "$FAKE_CURL_LOG"; VLM_MODELS_DIR="$TMP/models-intel"; export FAKE_INTEL=1
fetch_vlm_ov_model; fetch_vlm_model
[[ -s "$FAKE_CURL_LOG" ]] && bad "rerun with IR in place → no downloads" || ok "rerun with IR in place → no downloads"

echo ""; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
