#!/usr/bin/env bash
# Tests for install-parser.sh's OpenVINO runtime provisioning.
# Run: bash scripts/install-parser.openvino.test.sh
#
# Same sandbox trick as install-parser.vlm.test.sh: the functions under test are
# lifted out with sed and sourced, `pip` and `python` inside the venv are shims
# that log their arguments and answer import probes from the environment, and
# sudo is emptied. Nothing real is installed.
#
# Rule under test: the venv ends up with the OpenVINO runtime whenever OpenVINO
# weights are on disk, on BOTH venv paths. The prebuilt venv is a site-packages
# snapshot taken on a build machine, so it can predate a requirements.txt that
# added openvino / openvino-genai — as the v1.9.4-alpha1 snapshot did, leaving
# every caption on an Intel machine dead with ModuleNotFoundError while the
# installer reported success. Topping the snapshot up is what keeps the two
# paths equivalent; version specs are read from requirements.txt so they cannot
# drift from the pip path.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-parser.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

# ---- lift the functions out of the installer -------------------------------
extract() { sed -n "/^$1() {/,/^}/p" "$SCRIPT"; }
LIB="$TMP/lib.sh"
: > "$LIB"
for f in use_prebuilt vlm_ir_present text_ov_present pip_install req_spec \
         ensure_openvino_runtime ensure_onnxruntime_openvino setup_venv; do
    extract "$f" >> "$LIB"
    grep -q "^$f() {" "$LIB" && ok "installer defines $f()" || bad "installer defines $f()"
done

# ---- sandbox ---------------------------------------------------------------
log_info() { :; }; log_ok() { :; }; log_warn() { echo "WARN: $*" >> "$TMP/warn.log"; }
log_fail() { echo "FAIL: $*"; exit 1; }
sudo_cmd=""
INSTALL_DIR="$TMP/install"
VENV_DIR="$INSTALL_DIR/venv"
VLM_MODELS_DIR="$INSTALL_DIR/models"
PARSER_PY="/nonexistent/python3.11"
mkdir -p "$VENV_DIR/bin" "$VLM_MODELS_DIR"

# requirements.txt stand-in: the specs the top-up must honour, plus noise around
# them so the lookup has to anchor on the distribution name.
cat > "$INSTALL_DIR/requirements.txt" <<'REQ'
# comment mentioning openvino should not be picked up
uvicorn>=0.30
onnxruntime-openvino>=1.24.1
openvino>=2026.1
openvino-genai>=2026.1
openvino-telemetry
REQ

# pip shim: logs the full argument list, one invocation per line.
cat > "$VENV_DIR/bin/pip" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$TMP/pip.log"
[[ -n "\${FAKE_PIP_FAIL:-}" && "\$*" == *"\${FAKE_PIP_FAIL}"* ]] && exit 1
exit 0
SHIM
# python shim: answers the installer's import probes from the environment.
cat > "$VENV_DIR/bin/python" <<'SHIM'
#!/usr/bin/env bash
code=""
while [[ $# -gt 0 ]]; do case "$1" in -c) code="$2"; shift 2;; *) shift;; esac; done
case "$code" in
  *OpenVINOExecutionProvider*) [[ "${FAKE_HAS_OV_EP:-0}" == 1 ]] && exit 0 || exit 1;;
  *openvino_genai*)            [[ "${FAKE_HAS_GENAI:-0}" == 1 ]] && exit 0 || exit 1;;
  *"import openvino"*)         [[ "${FAKE_HAS_OV:-0}" == 1 ]] && exit 0 || exit 1;;
  *torch*)                     [[ "${FAKE_HAS_TORCH:-1}" == 1 ]] && exit 0 || exit 1;;
esac
exit 0
SHIM
chmod +x "$VENV_DIR/bin/pip" "$VENV_DIR/bin/python"

# The download itself is another function's job; stub it so these cases exercise
# setup_venv's control flow rather than curl and tar.
fetch_prebuilt_venv() { [[ "${FAKE_PREBUILT_OK:-1}" == 1 ]]; }

# shellcheck disable=SC1090
source "$LIB"

scenario() {   # scenario <name> <env assignments...>
    : > "$TMP/pip.log"; : > "$TMP/warn.log"
    rm -rf "$VLM_MODELS_DIR"; mkdir -p "$VLM_MODELS_DIR"
    unset FAKE_HAS_OV_EP FAKE_HAS_GENAI FAKE_HAS_OV FAKE_PREBUILT_OK FAKE_PIP_FAIL NIMO_PARSER_BUILD NIMO_PIP_INDEX
    local kv; for kv in "${@:2}"; do export "$kv"; done
}
with_caption_ir() {
    mkdir -p "$VLM_MODELS_DIR/qwen3-vl-4b-int4"
    echo ir > "$VLM_MODELS_DIR/qwen3-vl-4b-int4/openvino_language_model.xml"
}
with_text_ir() {
    mkdir -p "$VLM_MODELS_DIR/bge-m3-ov" "$VLM_MODELS_DIR/bge-reranker-v2-m3-ov"
    echo ir > "$VLM_MODELS_DIR/bge-m3-ov/openvino_model.xml"
    echo ir > "$VLM_MODELS_DIR/bge-reranker-v2-m3-ov/openvino_model.xml"
}
pip_ran()   { grep -q -- "$1" "$TMP/pip.log"; }
pip_quiet() { [[ ! -s "$TMP/pip.log" ]]; }

echo ""
echo "install-parser.sh OpenVINO runtime"

# --- the regression: the prebuilt snapshot can lack what requirements.txt pins
scenario prebuilt_needs_genai
with_caption_ir
setup_venv
pip_ran "openvino-genai>=2026.1" \
    && ok "prebuilt venv + caption IR + no openvino_genai → installs the requirements.txt spec" \
    || bad "prebuilt venv + caption IR + no openvino_genai → installs the requirements.txt spec"
pip_ran "requirements.txt" \
    && bad "prebuilt venv → tops up without a full requirements install" \
    || ok "prebuilt venv → tops up without a full requirements install"

# --- offline safety: a snapshot that already has it must not reach for pip
scenario prebuilt_has_genai FAKE_HAS_GENAI=1 FAKE_HAS_OV_EP=1
with_caption_ir
setup_venv
pip_quiet && ok "prebuilt venv already complete → no pip call at all" \
          || bad "prebuilt venv already complete → no pip call at all"

# --- no OpenVINO weights on disk → nothing to accelerate, nothing to install
scenario prebuilt_no_ir FAKE_HAS_OV_EP=1
setup_venv
pip_ran openvino-genai && bad "no OpenVINO weights → no openvino-genai install" \
                       || ok "no OpenVINO weights → no openvino-genai install"

# --- text IRs alone need the core runtime, not the generation runtime
scenario prebuilt_text_only FAKE_HAS_OV_EP=1
with_text_ir
setup_venv
pip_ran "openvino>=2026.1" && ok "text IRs only → installs openvino" \
                           || bad "text IRs only → installs openvino"
pip_ran openvino-genai && bad "text IRs only → no openvino-genai" \
                       || ok "text IRs only → no openvino-genai"

# --- the onnxruntime swap must happen on the prebuilt path too
scenario prebuilt_swap
setup_venv
pip_ran "onnxruntime-openvino>=1.24.1" \
    && ok "prebuilt venv without the OpenVINO EP → onnxruntime swap runs" \
    || bad "prebuilt venv without the OpenVINO EP → onnxruntime swap runs"
pip_ran -- "--force-reinstall --no-deps" \
    && ok "onnxruntime swap keeps --force-reinstall --no-deps" \
    || bad "onnxruntime swap keeps --force-reinstall --no-deps"

scenario prebuilt_swap_skip FAKE_HAS_OV_EP=1
setup_venv
pip_ran onnxruntime-openvino && bad "OpenVINO EP already active → swap skipped" \
                             || ok "OpenVINO EP already active → swap skipped"

# --- the pip path must keep doing what it already did
scenario pip_path FAKE_PREBUILT_OK=0
with_caption_ir
setup_venv
pip_ran "requirements.txt" && ok "pip path → still installs requirements.txt" \
                           || bad "pip path → still installs requirements.txt"
pip_ran "onnxruntime-openvino>=1.24.1" \
    && ok "pip path → still runs the onnxruntime swap" \
    || bad "pip path → still runs the onnxruntime swap"

# --- a pip mirror must reach the top-up too, not just the bulk install
scenario mirror FAKE_PREBUILT_OK=1 NIMO_PIP_INDEX=http://mirror.test/simple/
with_caption_ir
setup_venv
grep -q -- "-i http://mirror.test/simple/.*openvino-genai" "$TMP/pip.log" \
    && ok "NIMO_PIP_INDEX applies to the openvino top-up" \
    || bad "NIMO_PIP_INDEX applies to the openvino top-up"

# --- a failed top-up degrades the feature, it never fails the install
scenario topup_fails FAKE_PIP_FAIL=openvino-genai
with_caption_ir
setup_venv
rc=$?
[[ $rc -eq 0 ]] && ok "openvino-genai install failure → setup_venv still succeeds" \
               || bad "openvino-genai install failure → setup_venv still succeeds (rc=$rc)"
grep -q WARN "$TMP/warn.log" && ok "openvino-genai install failure → warns" \
                             || bad "openvino-genai install failure → warns"

# --- specs are read from requirements.txt, so they cannot drift from pip's
scenario spec_lookup
[[ "$(req_spec openvino-genai)" == "openvino-genai>=2026.1" ]] \
    && ok "req_spec reads the openvino-genai pin from requirements.txt" \
    || bad "req_spec reads the openvino-genai pin from requirements.txt (got '$(req_spec openvino-genai)')"
[[ "$(req_spec openvino)" == "openvino>=2026.1" ]] \
    && ok "req_spec anchors on the exact distribution name" \
    || bad "req_spec anchors on the exact distribution name (got '$(req_spec openvino)')"
[[ "$(req_spec not-listed-anywhere)" == "not-listed-anywhere" ]] \
    && ok "req_spec falls back to the bare name when unpinned" \
    || bad "req_spec falls back to the bare name when unpinned (got '$(req_spec not-listed-anywhere)')"

echo ""; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
