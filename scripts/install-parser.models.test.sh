#!/usr/bin/env bash
# Tests for install-parser.sh's models bundle, the download-scratch-directory
# selection it (and the ASR sidecar venv) now goes through, and the OpenVINO
# runtime top-up. Run: bash scripts/install-parser.models.test.sh
#
# 2026-09-18: two real NimoOS boxes ENOSPC'd downloading the ~14.7G models
# bundle. dl_tmp() hardcoded /var/tmp, which on every real box sits on the
# 7.5G overlayroot (/tmp is the bind mount of the real data disk — the
# opposite of what dl_tmp's old comment claimed), and fetch_models_bundle
# treated the resulting download failure as a WARN + `return 0`, so
# nimoos-update.sh printed `[ OK ] NimoOS updated ...` with not one model byte
# on disk. This file now covers, on top of the existing bundle/ASR-venv/
# OpenVINO coverage:
#   - dl_tmp() picking a scratch directory by free space (NIMO_DL_TMPDIR,
#     then /tmp, /var/tmp, then INSTALL_DIR/.download), never silently
#     falling back off an explicit NIMO_DL_TMPDIR that lacks room;
#   - sizing that search off a HEAD Content-Length when the mirror serves
#     one, falling back to the PARSER_MODELS_SIZE_BYTES pin otherwise;
#   - fetch_models_bundle treating anything past the two legitimate skips
#     (NIMO_PARSER_MODELS=0, non-x86_64) as FATAL: no scratch directory with
#     room, a download failure, a checksum mismatch;
#   - verify_models_bundle, the end-of-run guard against a future
#     "returned 0 without writing the marker" regression.
#
# Same sandbox trick throughout: functions are lifted out of the installer
# with sed and sourced into a sandbox where INSTALL_DIR lands under mktemp,
# `curl` is a shim that serves fixture tarballs/headers (or fails on demand),
# and sudo is emptied. Nothing real is touched.
#
# Rules under test:
#   - fetch_models_bundle downloads once, verifies sha256, extracts into
#     INSTALL_DIR and only then writes MODELS_BUNDLE_MARKER;
#   - a marker already at the pinned version skips the download; any other
#     marker content (including "no marker at all", i.e. a box installed from
#     the old per-model packages) re-downloads the whole bundle;
#   - NIMO_PARSER_MODELS=0 skips it outright (and marks MODELS_SKIPPED so the
#     end-of-run guard does not also fail); a bad sha, a failed download, or
#     no scratch directory with room is now FATAL (exit non-zero), unlike the
#     packages this bundle replaced;
#   - dl_tmp sizes its search off need bytes, prefers the first candidate
#     with avail >= need*11/10, and an explicit NIMO_DL_TMPDIR is checked,
#     never bypassed;
#   - head_content_length is best-effort (many mirrors do not implement
#     HEAD); report_size_mismatch only speaks up when HEAD and the pin
#     disagree by more than 10%;
#   - fetch_asr_venv (unchanged behaviour, now routed through the same
#     dl_tmp): the venv is CREATED with the installer's Python and only its
#     site-packages come from the package, so it works whatever 3.11.x uv
#     provided; a failed import smoke test is never marked ready;
#   - setup_venv/ensure_openvino_runtime (unchanged): the venv ends up with
#     the OpenVINO runtime whenever OpenVINO weights are on disk, on both the
#     prebuilt and pip venv paths, with specs read from requirements.txt.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-parser.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v zstd >/dev/null    || { echo "  skip — zstd not installed"; exit 0; }
command -v python3 >/dev/null || { echo "  skip — python3 not installed"; exit 0; }

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

# ---- lift the functions out of the installer -------------------------------
extract() { sed -n "/^$1() {/,/^}/p" "$SCRIPT"; }
LIB="$TMP/lib.sh"
: > "$LIB"
for f in ensure_zstd avail_kb_of kb_human dl_tmp head_content_length \
         report_size_mismatch vlm_ir_present text_ov_present fetch_models_bundle \
         verify_models_bundle video_enabled site_packages_need_kb sp_swap_rollback swap_in_site_packages \
         fetch_asr_venv use_prebuilt pip_install \
         req_spec ensure_openvino_runtime ensure_onnxruntime_openvino detect_parser_gpu_branch \
         ensure_amd_host_vulkan llama_vulkan_prereqs_met amd_swap_onnxruntime amd_swap_llama_wheel \
         ensure_amd_runtime ensure_openvino_pins reconcile_parser_gpu_runtime setup_venv; do
    extract "$f" >> "$LIB"
    grep -q "^$f() {" "$LIB" && ok "installer defines $f()" || bad "installer defines $f()"
done

# every per-model fetcher the bundle replaces, and the helpers only they used,
# must actually be gone — not just unused
for f in fetch_models fetch_vlm_ov_model fetch_vlm_model fetch_text_ov_models \
         fetch_translate_model fetch_transnetv2_model fetch_asr_ir \
         fetch_video_embed_ov fetch_model_pkg has_intel_gpu; do
    grep -q "^$f() {" "$SCRIPT" && bad "removed: $f() still defined" || ok "removed: $f() no longer defined"
done
for v in DEP_HFCACHE DEP_VLM DEP_VLM_OV DEP_TEXT_OV DEP_TRANSLATE DEP_TRANSNET DEP_ASR_IR DEP_VIDEO_EMBED_OV; do
    grep -q "readonly ${v}=" "$SCRIPT" && bad "removed: ${v} still pinned" || ok "removed: ${v} no longer pinned"
done
for k in NIMO_PARSER_VLM NIMO_PARSER_VLM_OV NIMO_PARSER_VLM_GGUF NIMO_PARSER_OV NIMO_PARSER_VIDEO_EMBED; do
    grep -q "${k}" "$SCRIPT" && bad "removed: ${k} knob still referenced" || ok "removed: ${k} knob no longer referenced"
done

# ---- pins for the one bundle ------------------------------------------------
grep -qE '^readonly PARSER_MODELS_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$SCRIPT" \
    && ok "PARSER_MODELS_VERSION is pinned" || bad "PARSER_MODELS_VERSION is pinned"
grep -qE '^readonly PARSER_MODELS_SHA256="[0-9a-f]{64}"$' "$SCRIPT" \
    && ok "PARSER_MODELS_SHA256 is a pinned sha256" || bad "PARSER_MODELS_SHA256 is a pinned sha256"
grep -qE '^readonly PARSER_MODELS_SIZE_BYTES="[0-9]+"$' "$SCRIPT" \
    && ok "PARSER_MODELS_SIZE_BYTES is pinned" || bad "PARSER_MODELS_SIZE_BYTES is pinned"
grep -qE '^readonly DEP_MODELS_BUNDLE="parser/nimoos-parser-models-\$\{PARSER_MODELS_VERSION\}\.tar\.zst"$' "$SCRIPT" \
    && ok "DEP_MODELS_BUNDLE names the one bundle" || bad "DEP_MODELS_BUNDLE names the one bundle"
grep -qE '^readonly MODELS_BUNDLE_MARKER=' "$SCRIPT" \
    && ok "MODELS_BUNDLE_MARKER is defined" || bad "MODELS_BUNDLE_MARKER is defined"

# ---- main flow: fetch_models_bundle + fetch_asr_venv between setup_venv and install_conf,
#      verify_models_bundle after maybe_start
venv_line="$(grep -n '^setup_venv$' "$SCRIPT" | cut -d: -f1)"
conf_line="$(grep -n '^install_conf$' "$SCRIPT" | cut -d: -f1)"
start_line="$(grep -n '^maybe_start$' "$SCRIPT" | cut -d: -f1)"
for f in fetch_models_bundle fetch_asr_venv; do
    l="$(grep -n "^$f\$" "$SCRIPT" | cut -d: -f1)"
    [[ -n "$l" && -n "$venv_line" && -n "$conf_line" && "$l" -gt "$venv_line" && "$l" -lt "$conf_line" ]] \
        && ok "main flow runs $f between setup_venv and install_conf" \
        || bad "main flow runs $f between setup_venv and install_conf"
done
l="$(grep -n '^verify_models_bundle$' "$SCRIPT" | cut -d: -f1)"
[[ -n "$l" && -n "$start_line" && "$l" -gt "$start_line" ]] \
    && ok "main flow runs verify_models_bundle after maybe_start" \
    || bad "main flow runs verify_models_bundle after maybe_start"

###############################################################################
# Section 1: fetch_models_bundle + dl_tmp scratch selection + fetch_asr_venv
###############################################################################

# ---- fixture: a tiny stand-in for the real bundle ---------------------------
# Carries VERSION at the root and at least one file under models/ and
# hf-cache/hub/, so the extraction path is exercised, not just the download.
mkdir -p "$TMP/fx/bundle/models/bge-m3-ov" "$TMP/fx/bundle/hf-cache/hub/models--BAAI--bge-m3"
echo "1.0.0" > "$TMP/fx/bundle/VERSION"
echo "nimoos-parser-models 1.0.0" > "$TMP/fx/bundle/MANIFEST.txt"
echo '{"schema":1,"bundle":"1.0.0","models":[]}' > "$TMP/fx/bundle/manifest.json"
echo ir > "$TMP/fx/bundle/models/bge-m3-ov/openvino_model.xml"
echo cfg > "$TMP/fx/bundle/hf-cache/hub/models--BAAI--bge-m3/config.json"
tar --zstd -cf "$TMP/fx/bundle.tar.zst" -C "$TMP/fx/bundle" VERSION MANIFEST.txt manifest.json models hf-cache
BUNDLE_SHA="$(sha256sum "$TMP/fx/bundle.tar.zst" | cut -d' ' -f1)"
BUNDLE_SIZE="$(stat -c%s "$TMP/fx/bundle.tar.zst")"

# ASR sidecar site-packages fixture (same shape install-parser.video.test.sh used).
mkdir -p "$TMP/fx/sp"
for pkg in optimum/intel transformers librosa soundfile silero_vad; do mkdir -p "$TMP/fx/sp/$pkg"; touch "$TMP/fx/sp/$pkg/__init__.py"; done
touch "$TMP/fx/sp/optimum/__init__.py"
tar --zstd -cf "$TMP/fx/asr-venv.tar.zst" -C "$TMP/fx/sp" .
# a package with the wrong contents: unpacks fine, fails the import smoke test
mkdir -p "$TMP/fx/wrong/nothing-here"; touch "$TMP/fx/wrong/nothing-here/file"
tar --zstd -cf "$TMP/fx/asr-venv-wrong.tar.zst" -C "$TMP/fx/wrong" .
sha() { sha256sum "$1" | cut -d' ' -f1; }

# curl shim: `curl ... -o <out> <url>` serves the fixture matching the url;
# `curl -I ...` (any flag containing "I") serves fake HEAD headers instead,
# controlled by FAKE_HEAD_CONTENT_LENGTH / FAKE_HEAD_FAIL. Fails when
# FAKE_CURL_FAIL matches the url (by substring).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""; head_req=0
for a in "\$@"; do [[ "\$a" == -* && "\$a" == *I* ]] && head_req=1; done
while [[ \$# -gt 0 ]]; do case "\$1" in -o) out="\$2"; shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
if [[ "\$head_req" == 1 ]]; then echo "HEAD \$url" >> "\$FAKE_CURL_LOG"; else echo "GET \$url" >> "\$FAKE_CURL_LOG"; fi
if [[ "\$head_req" == 1 ]]; then
    [[ -n "\${FAKE_HEAD_FAIL:-}" ]] && exit 22
    case "\$url" in
      *nimoos-parser-models*) printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "\${FAKE_HEAD_CONTENT_LENGTH:-$BUNDLE_SIZE}";;
      *) exit 22;;
    esac
    exit 0
fi
[[ -n "\${FAKE_CURL_FAIL:-}" && "\$url" == *"\$FAKE_CURL_FAIL"* ]] && exit 22
case "\$url" in
  *nimoos-parser-models*) cp "\${FAKE_BUNDLE_TARBALL:-$TMP/fx/bundle.tar.zst}" "\$out";;
  *asr-venv*)             cp "\${FAKE_ASR_VENV_TARBALL:-$TMP/fx/asr-venv.tar.zst}" "\$out";;
  *) exit 22;;
esac
SHIM
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export FAKE_CURL_LOG="$TMP/curl.log"

# ---- sandbox -----------------------------------------------------------------
# Stubs write to stdout exactly like the real log_* helpers do, so a function that
# leaks a log line into a "$(...)" capture fails here the way it fails on a real box.
log_info() { echo "INFO: $*"; }; log_ok() { echo "OK: $*"; }; log_warn() { echo "WARN: $*" | tee -a "$TMP/warn.log"; }
log_fail() { echo "FAIL: $*"; exit 1; }
sudo_cmd=""
NIMO_DEPS_BASE="http://deps.test"
DEP_MODELS_BUNDLE="parser/nimoos-parser-models-1.0.0.tar.zst"
DEP_ASR_VENV="parser/asr-venv-site-packages-cp311-linux-x86_64.tar.zst"
DL_SIZE_ESTIMATE_ASR_VENV=$((600 * 1024 * 1024))
PARSER_MODELS_VERSION="1.0.0"
PARSER_MODELS_SHA256="$BUNDLE_SHA"
PARSER_MODELS_SIZE_BYTES="$BUNDLE_SIZE"
DEP_ASR_VENV_SHA256="$(sha "$TMP/fx/asr-venv.tar.zst")"
PARSER_PY="python3"
MODELS_SKIPPED=0
# shellcheck disable=SC1090
source "$LIB"
export NIMO_DL_TMPDIR="$TMP"

scenario() {   # scenario <name> <env assignments...>
    INSTALL_DIR="$TMP/inst-$1"
    VLM_MODELS_DIR="$INSTALL_DIR/models"
    HF_CACHE_DIR="$INSTALL_DIR/hf-cache"
    MODELS_BUNDLE_MARKER="$INSTALL_DIR/models/.bundle-version"
    ASR_VENV_DIR="$INSTALL_DIR/asr-venv"
    mkdir -p "$VLM_MODELS_DIR" "$HF_CACHE_DIR"
    : > "$FAKE_CURL_LOG"; : > "$TMP/warn.log"
    unset FAKE_CURL_FAIL FAKE_BUNDLE_TARBALL FAKE_ASR_VENV_TARBALL NIMO_PARSER_MODELS NIMO_PARSER_VIDEO \
          PARSER_MODELS_SHA256 FAKE_HEAD_FAIL FAKE_HEAD_CONTENT_LENGTH
    PARSER_MODELS_SHA256="$BUNDLE_SHA"
    PARSER_MODELS_SIZE_BYTES="$BUNDLE_SIZE"
    MODELS_SKIPPED=0
    local kv; for kv in "${@:2}"; do export "$kv"; done
}
version_present()   { [[ -f "$INSTALL_DIR/VERSION" ]]; }
model_present()     { [[ -f "$VLM_MODELS_DIR/bge-m3-ov/openvino_model.xml" ]]; }
hfcache_present()   { [[ -f "$HF_CACHE_DIR/hub/models--BAAI--bge-m3/config.json" ]]; }
marker_version()    { cat "$MODELS_BUNDLE_MARKER" 2>/dev/null; }
asr_venv_present()  { [[ -x "$ASR_VENV_DIR/bin/python" ]] && compgen -G "$ASR_VENV_DIR/lib/python3.*/site-packages/optimum/intel/__init__.py" >/dev/null; }
fetched()           { grep -q "$1" "$FAKE_CURL_LOG"; }
downloads()         { grep -c '^GET ' "$FAKE_CURL_LOG"; }
heads()             { grep -c '^HEAD ' "$FAKE_CURL_LOG"; }

echo "install-parser.sh models bundle"

scenario fresh
fetch_models_bundle
version_present   && ok "fresh box → VERSION lands under INSTALL_DIR" || bad "fresh box → VERSION lands under INSTALL_DIR"
model_present      && ok "fresh box → models/<x>/... lands under INSTALL_DIR" || bad "fresh box → models/<x>/... lands under INSTALL_DIR"
hfcache_present    && ok "fresh box → hf-cache/hub/... lands under INSTALL_DIR" || bad "fresh box → hf-cache/hub/... lands under INSTALL_DIR"
# The Parser reads ModelsCatalogPath=<INSTALL_DIR>/manifest.json; unpacking is all the installer does for it.
[[ -f "$INSTALL_DIR/manifest.json" ]] && ok "fresh box → manifest.json lands at the root of INSTALL_DIR" || bad "fresh box → manifest.json lands at the root of INSTALL_DIR"
[[ "$(marker_version)" == "1.0.0" ]] && ok "fresh box → marker written with the version" || bad "fresh box → marker written with the version (got '$(marker_version)')"
[[ "$(downloads)" -eq 1 ]] && ok "fresh box → downloaded exactly once" || bad "fresh box → downloaded exactly once (got $(downloads))"
[[ "$MODELS_SKIPPED" == "0" ]] && ok "fresh box → not marked skipped" || bad "fresh box → not marked skipped"

scenario current
echo "1.0.0" > "$MODELS_BUNDLE_MARKER"
fetch_models_bundle
[[ -z "$(cat "$FAKE_CURL_LOG")" ]] && ok "marker equals pinned version → zero downloads" || bad "marker equals pinned version → zero downloads"

scenario older
echo "0.9.0" > "$MODELS_BUNDLE_MARKER"
fetch_models_bundle
[[ "$(downloads)" -eq 1 ]] && ok "marker holds an older version → downloaded again" || bad "marker holds an older version → downloaded again"
[[ "$(marker_version)" == "1.0.0" ]] && ok "marker holds an older version → marker updated" || bad "marker holds an older version → marker updated"

scenario disabled NIMO_PARSER_MODELS=0
fetch_models_bundle
[[ -z "$(cat "$FAKE_CURL_LOG")" ]] && ok "NIMO_PARSER_MODELS=0 → nothing downloaded" || bad "NIMO_PARSER_MODELS=0 → nothing downloaded"
[[ -e "$MODELS_BUNDLE_MARKER" ]] && bad "NIMO_PARSER_MODELS=0 → no marker" || ok "NIMO_PARSER_MODELS=0 → no marker"
[[ "$MODELS_SKIPPED" == "1" ]] && ok "NIMO_PARSER_MODELS=0 → marked skipped" || bad "NIMO_PARSER_MODELS=0 → marked skipped"

echo ""
echo "install-parser.sh models bundle — fatal contract"
# Unlike the packages this bundle replaced, these three are now hard stops:
# no scratch space, a download failure, and a checksum mismatch. Each is run
# via command substitution, which bash always forks as a subshell — so
# log_fail's `exit 1` only ends that subshell, and $? / the captured output
# are both observable without killing the rest of this test script.

scenario badsha PARSER_MODELS_SHA256=0000000000000000000000000000000000000000000000000000000000000000
out="$(fetch_models_bundle 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "sha mismatch → fatal (non-zero exit)" || bad "sha mismatch → fatal (non-zero exit, got rc=$rc)"
echo "$out" | grep -qi "checksum" && ok "sha mismatch → names the cause" || bad "sha mismatch → names the cause (got: $out)"
version_present && bad "sha mismatch → nothing extracted" || ok "sha mismatch → nothing extracted"
[[ -e "$MODELS_BUNDLE_MARKER" ]] && bad "sha mismatch → marker absent" || ok "sha mismatch → marker absent"

scenario dlfail FAKE_CURL_FAIL=nimoos-parser-models
out="$(fetch_models_bundle 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "download failure → fatal (non-zero exit)" || bad "download failure → fatal (non-zero exit, got rc=$rc)"
echo "$out" | grep -qi "could not fetch" && ok "download failure → names the cause" || bad "download failure → names the cause (got: $out)"
version_present && bad "download failure → nothing extracted" || ok "download failure → nothing extracted"
[[ -e "$MODELS_BUNDLE_MARKER" ]] && bad "download failure → marker absent" || ok "download failure → marker absent"

# download scratch goes to NIMO_DL_TMPDIR and is never left behind
[[ -z "$(find "$TMP" -mindepth 1 -maxdepth 1 -name "tmp.*" -print -quit)" ]] && ok "no download scratch left behind" || bad "no download scratch left behind"

echo ""
echo "install-parser.sh models bundle — size: HEAD Content-Length vs. the pin"

scenario headmismatch
: > "$TMP/warn.log"
report_size_mismatch 20000000000 14710471303
grep -qi "size mismatch" "$TMP/warn.log" && ok "report_size_mismatch → warns when HEAD and the pin differ by >10%" \
    || bad "report_size_mismatch → warns when HEAD and the pin differ by >10%"
: > "$TMP/warn.log"
report_size_mismatch 14710471303 14710471303
[[ ! -s "$TMP/warn.log" ]] && ok "report_size_mismatch → silent when HEAD and the pin agree" \
    || bad "report_size_mismatch → silent when HEAD and the pin agree (got: $(cat "$TMP/warn.log"))"

got="$(FAKE_HEAD_CONTENT_LENGTH=123456789 head_content_length "http://deps.test/parser/nimoos-parser-models-1.0.0.tar.zst")"
[[ "$got" == "123456789" ]] && ok "head_content_length → reads Content-Length from the HEAD response" \
    || bad "head_content_length → reads Content-Length from the HEAD response (got '$got')"
FAKE_HEAD_FAIL=1 head_content_length "http://deps.test/parser/nimoos-parser-models-1.0.0.tar.zst" >/dev/null
rc=$?
[[ $rc -ne 0 ]] && ok "head_content_length → fails when the HEAD request fails" \
    || bad "head_content_length → fails when the HEAD request fails (rc=$rc)"

# fetch_models_bundle actually USES the HEAD value to size the scratch search,
# not just the pin: an absurdly large (but real disks cannot satisfy) HEAD
# size must make it fail even though the pin alone would have fit easily.
scenario headoversized FAKE_HEAD_CONTENT_LENGTH=999999999999999
out="$(fetch_models_bundle 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "oversized HEAD Content-Length → drives scratch sizing (fails where the pin would have fit)" \
    || bad "oversized HEAD Content-Length → drives scratch sizing (got rc=$rc)"
expect_human="$(kb_human $((999999999999999 / 1024)))"
echo "$out" | grep -qF "${expect_human}" \
    && ok "oversized HEAD Content-Length → failure message reflects the HEAD size" \
    || bad "oversized HEAD Content-Length → failure message reflects the HEAD size (expected '${expect_human}', got: $out)"

# the mirror not implementing HEAD (the fixture curl shim's default when the
# caller asks it to fail) must not stop the install: fetch_models_bundle
# falls back to the pin and proceeds exactly like a normal run.
scenario headfails_fallsback FAKE_HEAD_FAIL=1
fetch_models_bundle
[[ "$(marker_version)" == "1.0.0" ]] && ok "HEAD failure → falls back to the pin and still succeeds" \
    || bad "HEAD failure → falls back to the pin and still succeeds (marker='$(marker_version)')"

echo ""
echo "install-parser.sh dl_tmp scratch selection"

DLT_INSTALL_DIR="$TMP/inst-dltmp"
mkdir -p "$DLT_INSTALL_DIR"
DLT_SMALL="$TMP/fake-small"; DLT_BIG="$TMP/fake-big"
mkdir -p "$DLT_SMALL" "$DLT_BIG"
declare -A FAKE_AVAIL_KB
avail_kb_of() { echo "${FAKE_AVAIL_KB[$1]:-}"; }

unset NIMO_DL_TMPDIR
INSTALL_DIR="$DLT_INSTALL_DIR"
: > "$TMP/warn.log"
FAKE_AVAIL_KB=( ["/tmp"]="1" ["/var/tmp"]="1" ["${DLT_INSTALL_DIR}/.download"]="99999999" )
got="$(dl_tmp $((100*1024*1024)))"; rc=$?
[[ $rc -eq 0 && -n "$got" && "$(dirname "$got")" == "${DLT_INSTALL_DIR}/.download" ]] \
    && ok "dl_tmp → skips undersized candidates, picks the first with room" \
    || bad "dl_tmp → skips undersized candidates, picks the first with room (rc=$rc got='$got')"
[[ -f "$got" ]] && ok "dl_tmp → hands back a real, empty scratch file" || bad "dl_tmp → hands back a real, empty scratch file"
[[ "$got" != *$'\n'* && "$got" != *INFO* && "$got" != *WARN* ]] \
    && ok "dl_tmp → stdout carries only the scratch path (log lines go to stderr)" \
    || bad "dl_tmp → stdout carries only the scratch path (log lines go to stderr) (got='$got')"

# ${INSTALL_DIR}/.download shares a filesystem with the extract target: 1.5x the
# archive is not enough there (archive + unpacked copy), 2.2x is.
FAKE_AVAIL_KB=( ["/tmp"]="1" ["/var/tmp"]="1" ["${DLT_INSTALL_DIR}/.download"]="$(( 100*1024 * 15 / 10 ))" )
dl_tmp $((100*1024*1024)) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "dl_tmp → install-dir scratch needs room for the unpacked copy too (1.5x rejected)" \
    || bad "dl_tmp → install-dir scratch needs room for the unpacked copy too (1.5x rejected) (rc=$rc)"
FAKE_AVAIL_KB=( ["/tmp"]="1" ["/var/tmp"]="1" ["${DLT_INSTALL_DIR}/.download"]="$(( 100*1024 * 22 / 10 ))" )
dl_tmp $((100*1024*1024)) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "dl_tmp → install-dir scratch accepted at 2.2x" || bad "dl_tmp → install-dir scratch accepted at 2.2x (rc=$rc)"

if [[ $EUID -ne 0 ]]; then
    DLT_RO="$TMP/fake-ro"; mkdir -p "$DLT_RO"; chmod 555 "$DLT_RO"
    export NIMO_DL_TMPDIR="$DLT_RO"
    FAKE_AVAIL_KB=( ["$DLT_RO"]="99999999" )
    got="$(dl_tmp $((100*1024*1024)) 2>/dev/null)"; rc=$?
    [[ $rc -ne 0 && -z "$got" ]] && ok "dl_tmp → mktemp failure returns non-zero instead of an empty path" \
        || bad "dl_tmp → mktemp failure returns non-zero instead of an empty path (rc=$rc got='$got')"
    chmod 755 "$DLT_RO"; unset NIMO_DL_TMPDIR
fi

FAKE_AVAIL_KB=( ["/tmp"]="99999999" ["/var/tmp"]="99999999" ["${DLT_INSTALL_DIR}/.download"]="99999999" )
: > "$TMP/warn.log"
dl_tmp $((100*1024*1024)) >/dev/null
rc=$?
[[ $rc -eq 0 ]] && ok "dl_tmp → no NIMO_DL_TMPDIR, plenty of room everywhere → succeeds" \
    || bad "dl_tmp → no NIMO_DL_TMPDIR, plenty of room everywhere → succeeds (rc=$rc)"

FAKE_AVAIL_KB=( ["/tmp"]="1" ["/var/tmp"]="1" ["${DLT_INSTALL_DIR}/.download"]="1" )
: > "$TMP/warn.log"
dl_tmp $((100*1024*1024)) >/dev/null
rc=$?
[[ $rc -ne 0 ]] && ok "dl_tmp → no candidate has room anywhere → fails" || bad "dl_tmp → no candidate has room anywhere → fails (rc=$rc)"
grep -qi "no download scratch" "$TMP/warn.log" && ok "dl_tmp → no candidate has room → warns with every candidate's avail" \
    || bad "dl_tmp → no candidate has room → warns with every candidate's avail (got: $(cat "$TMP/warn.log"))"

export NIMO_DL_TMPDIR="$DLT_SMALL"
FAKE_AVAIL_KB=( ["$DLT_SMALL"]="1" ["/tmp"]="99999999" ["/var/tmp"]="99999999" ["${DLT_INSTALL_DIR}/.download"]="99999999" )
: > "$TMP/warn.log"
dl_tmp $((100*1024*1024)) >/dev/null
rc=$?
[[ $rc -ne 0 ]] && ok "dl_tmp → explicit NIMO_DL_TMPDIR without room fails rather than falling back" \
    || bad "dl_tmp → explicit NIMO_DL_TMPDIR without room fails rather than falling back (rc=$rc)"
fetched_tmp=$(find "$DLT_BIG" -mindepth 1 2>/dev/null | head -1)
[[ -z "$fetched_tmp" ]] && ok "dl_tmp → explicit NIMO_DL_TMPDIR without room never touches /tmp or /var/tmp" \
    || bad "dl_tmp → explicit NIMO_DL_TMPDIR without room never touches /tmp or /var/tmp"
grep -q "$DLT_SMALL" "$TMP/warn.log" && ! grep -q "/tmp=" "$TMP/warn.log" \
    && ok "dl_tmp → failure message names only the explicit directory, not the ones it skipped" \
    || bad "dl_tmp → failure message names only the explicit directory, not the ones it skipped (got: $(cat "$TMP/warn.log"))"

# restore the real implementation for every later dl_tmp caller (fetch_asr_venv below)
avail_kb_of() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
export NIMO_DL_TMPDIR="$TMP"

echo ""
echo "install-parser.sh ASR sidecar venv"

scenario asr_ok
fetch_asr_venv
asr_venv_present && ok "ASR sidecar venv created + site-packages unpacked" || bad "ASR sidecar venv created + site-packages unpacked"
[[ -f "$ASR_VENV_DIR/pyvenv.cfg" ]] && grep -q "^home = " "$ASR_VENV_DIR/pyvenv.cfg" \
    && ok "sidecar venv points at this machine's interpreter" \
    || bad "sidecar venv points at this machine's interpreter"
[[ -e "$ASR_VENV_DIR/.ready" ]] && ok "ready sidecar is marked ready" || bad "ready sidecar is marked ready"

scenario asr_disabled NIMO_PARSER_VIDEO=0
fetch_asr_venv
asr_venv_present && bad "NIMO_PARSER_VIDEO=0 → no sidecar venv" || ok "NIMO_PARSER_VIDEO=0 → no sidecar venv"

scenario asr_rerun
fetch_asr_venv
: > "$FAKE_CURL_LOG"
fetch_asr_venv
[[ "$(downloads)" -eq 0 ]] && ok "rerun with sidecar in place → no downloads" || bad "rerun with sidecar in place → no downloads"

scenario asr_broken FAKE_ASR_VENV_TARBALL="$TMP/fx/asr-venv-wrong.tar.zst"
DEP_ASR_VENV_SHA256="$(sha "$TMP/fx/asr-venv-wrong.tar.zst")"
fetch_asr_venv
grep -qi "import" "$TMP/warn.log" && ok "sidecar import smoke test failure → warns" || bad "sidecar import smoke test failure → warns: $(cat "$TMP/warn.log")"
[[ -e "$ASR_VENV_DIR/.ready" ]] && bad "broken sidecar → not marked ready" || ok "broken sidecar → not marked ready"
DEP_ASR_VENV_SHA256="$(sha "$TMP/fx/asr-venv.tar.zst")"

echo ""
echo "install-parser.sh verify_models_bundle (end-of-run guard)"

scenario guard_ok
fetch_models_bundle
out="$(verify_models_bundle 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "marker present at the pinned version → guard passes" || bad "marker present at the pinned version → guard passes (rc=$rc, out=$out)"

scenario guard_skipped NIMO_PARSER_MODELS=0
fetch_models_bundle
out="$(verify_models_bundle 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "legitimately skipped → guard passes with no marker" || bad "legitimately skipped → guard passes with no marker (rc=$rc, out=$out)"

scenario guard_missing
# fetch_models_bundle deliberately not called: simulates a future code path
# that returns 0 without ever reaching the marker write.
out="$(verify_models_bundle 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "not skipped but marker missing → guard fails" || bad "not skipped but marker missing → guard fails (rc=$rc)"
echo "$out" | grep -qi "installer bug" && ok "guard failure → names it as an installer bug" || bad "guard failure → names it as an installer bug (got: $out)"

###############################################################################
# Section 2: setup_venv / ensure_openvino_runtime (OpenVINO runtime top-up)
###############################################################################
#
# Rule under test: the venv ends up with the OpenVINO runtime whenever
# OpenVINO weights are on disk, on BOTH venv paths. The prebuilt venv is a
# site-packages snapshot taken on a build machine, so it can predate a
# requirements.txt that added openvino / openvino-genai — as the v1.9.4-alpha1
# snapshot did, leaving every caption on an Intel machine dead with
# ModuleNotFoundError while the installer reported success. Topping the
# snapshot up is what keeps the two paths equivalent; version specs are read
# from requirements.txt so they cannot drift from the pip path. Unaffected by
# the models-bundle redesign (vlm_ir_present/text_ov_present just read what
# fetch_models_bundle unpacked instead of what a per-model fetch left behind).

log_info() { :; }; log_ok() { :; }; log_warn() { echo "WARN: $*" >> "$TMP/warn2.log"; }
INSTALL_DIR="$TMP/install2"
VENV_DIR="$INSTALL_DIR/venv"
# The vendor branch has its own tests; these run the cpu branch on any host.
export NIMO_DRM_ROOT="$TMP/no-drm"
VLM_MODELS_DIR="$INSTALL_DIR/models"
PARSER_PY="/nonexistent/python3.11"
mkdir -p "$VENV_DIR/bin" "$VLM_MODELS_DIR"

cat > "$INSTALL_DIR/requirements.txt" <<'REQ'
# comment mentioning openvino should not be picked up
uvicorn>=0.30
onnxruntime-openvino>=1.24.1
openvino>=2026.1
openvino-genai>=2026.1
openvino-telemetry
REQ

cat > "$VENV_DIR/bin/pip" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$TMP/pip.log"
[[ -n "\${FAKE_PIP_FAIL:-}" && "\$*" == *"\${FAKE_PIP_FAIL}"* ]] && exit 1
exit 0
SHIM
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

fetch_prebuilt_venv() { [[ "${FAKE_PREBUILT_OK:-1}" == 1 ]]; }

scenario2() {   # scenario2 <name> <env assignments...>
    : > "$TMP/pip.log"; : > "$TMP/warn2.log"
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
echo "install-parser.sh OpenVINO runtime top-up"

scenario2 prebuilt_needs_genai
with_caption_ir
setup_venv
pip_ran "openvino-genai>=2026.1" \
    && ok "prebuilt venv + caption IR + no openvino_genai → installs the requirements.txt spec" \
    || bad "prebuilt venv + caption IR + no openvino_genai → installs the requirements.txt spec"
pip_ran "requirements.txt" \
    && bad "prebuilt venv → tops up without a full requirements install" \
    || ok "prebuilt venv → tops up without a full requirements install"

scenario2 prebuilt_has_genai FAKE_HAS_GENAI=1 FAKE_HAS_OV_EP=1
with_caption_ir
setup_venv
pip_quiet && ok "prebuilt venv already complete → no pip call at all" \
          || bad "prebuilt venv already complete → no pip call at all"

scenario2 prebuilt_no_ir FAKE_HAS_OV_EP=1
setup_venv
pip_ran openvino-genai && bad "no OpenVINO weights → no openvino-genai install" \
                       || ok "no OpenVINO weights → no openvino-genai install"

scenario2 prebuilt_text_only FAKE_HAS_OV_EP=1
with_text_ir
setup_venv
pip_ran "openvino>=2026.1" && ok "text IRs only → installs openvino" \
                           || bad "text IRs only → installs openvino"
pip_ran openvino-genai && bad "text IRs only → no openvino-genai" \
                       || ok "text IRs only → no openvino-genai"

scenario2 prebuilt_swap
setup_venv
pip_ran "onnxruntime-openvino>=1.24.1" \
    && ok "prebuilt venv without the OpenVINO EP → onnxruntime swap runs" \
    || bad "prebuilt venv without the OpenVINO EP → onnxruntime swap runs"
pip_ran -- "--force-reinstall --no-deps" \
    && ok "onnxruntime swap keeps --force-reinstall --no-deps" \
    || bad "onnxruntime swap keeps --force-reinstall --no-deps"

scenario2 prebuilt_swap_skip FAKE_HAS_OV_EP=1
setup_venv
pip_ran onnxruntime-openvino && bad "OpenVINO EP already active → swap skipped" \
                             || ok "OpenVINO EP already active → swap skipped"

scenario2 pip_path FAKE_PREBUILT_OK=0
with_caption_ir
setup_venv
pip_ran "requirements.txt" && ok "pip path → still installs requirements.txt" \
                           || bad "pip path → still installs requirements.txt"
pip_ran "onnxruntime-openvino>=1.24.1" \
    && ok "pip path → still runs the onnxruntime swap" \
    || bad "pip path → still runs the onnxruntime swap"

scenario2 mirror FAKE_PREBUILT_OK=1 NIMO_PIP_INDEX=http://mirror.test/simple/
with_caption_ir
setup_venv
grep -q -- "-i http://mirror.test/simple/.*openvino-genai" "$TMP/pip.log" \
    && ok "NIMO_PIP_INDEX applies to the openvino top-up" \
    || bad "NIMO_PIP_INDEX applies to the openvino top-up"

scenario2 topup_fails FAKE_PIP_FAIL=openvino-genai
with_caption_ir
setup_venv
rc=$?
[[ $rc -eq 0 ]] && ok "openvino-genai install failure → setup_venv still succeeds" \
               || bad "openvino-genai install failure → setup_venv still succeeds (rc=$rc)"
grep -q WARN "$TMP/warn2.log" && ok "openvino-genai install failure → warns" \
                              || bad "openvino-genai install failure → warns"

scenario2 spec_lookup
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
