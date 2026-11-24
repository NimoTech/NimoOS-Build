#!/usr/bin/env bash
# Tests for deploy-parser.sh and lib/parser-gpu-branch.sh. Run:
#   bash scripts/deploy-parser.test.sh
#
# Rules under test (dynamic allocation phase 3 B2-2):
#   - the Parser dependency branch comes from the DRM table: any Intel GPU →
#     intel, otherwise any AMD GPU → amd, otherwise cpu; card order is irrelevant;
#   - intel and cpu keep today's pip sequence (the swap pin is the exact
#     requirements.txt value), and never touch Mesa;
#   - amd runs download → uninstall both → install from the download directory,
#     never the onnxruntime-openvino swap, and a second run makes no pip call;
#   - no failure on the amd path fails the deploy or leaves the service stopped:
#     a failed download leaves the old ONNX Runtime untouched, a failed install
#     restores the onnxruntime-openvino pin from the download directory without
#     the network, a bad checksum or a missing system library keeps the CPU
#     llama.cpp wheel;
#   - host packages already installed mean no apt call at all, and a missing one
#     never upgrades the others (a Mesa upgrade would change the self-test
#     fingerprint on a plain deploy);
#   - a Parser whose onnxruntime-openvino is not an exact pin predates the AMD
#     stack: amd takes the intel and cpu path, with one log line;
#   - --no-deps alone makes no pip call (the Stop hook relies on this);
#     --no-deps --reconcile-gpu-runtime skips `pip install -r` only.
#
# deploy-parser.sh runs for real, from a copy inside a sandbox: INSTALL_DIR and
# UNIT_DST are rewritten to sandbox paths in that copy (the rewrite is checked
# before anything runs), `sudo` is a shim that just executes its arguments, and
# pip, python, systemctl, apt-get, dpkg-query, curl, ldconfig and getconf are stubs. Stub
# pip and python share a small state directory so that a probe sees what an
# earlier install did. Nothing real is touched. A last section runs the Python
# probes on a real interpreter against fake modules, because a stub cannot tell
# whether the probe code itself is right.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB_SRC="$HERE/lib/parser-gpu-branch.sh"
NPU_LIB_SRC="$HERE/lib/parser-npu-amd.sh"
DEPLOY_SRC="$HERE/deploy-parser.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

###############################################################################
# Sandbox
###############################################################################

BOX="$TMP/box"
BUILD="$BOX/repo/NimoOS-Build"
PARSER="$BOX/repo/NimoOS-Parser"
INSTALL="$BOX/opt"
VENV="$INSTALL/venv"
STATE="$BOX/state"
DRM="$BOX/drm"
SCRATCH="$BOX/scratch"
export CALLS="$BOX/calls"
export STATE
mkdir -p "$BOX/bin" "$BUILD/scripts/lib" "$BUILD/release/lib" "$VENV/bin" "$INSTALL/parser" "$STATE" "$SCRATCH" \
         "$PARSER/parser" "$PARSER/build/sysroot/usr/lib/systemd/system" "$BOX/unit"

cat > "$BOX/bin/sudo" <<'SHIM'
#!/usr/bin/env bash
exec "$@"
SHIM
cat > "$BOX/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
if [[ "$1" == "show" ]]; then
  case "$*" in
    *"-p MemoryMax"*) echo 12884901888 ;;
    *"-p Delegate"*)  echo yes ;;
  esac
fi
exit 0
SHIM
cat > "$BOX/bin/apt-get" <<'SHIM'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CALLS"
[[ -n "${FAKE_APT_FAIL:-}" ]] && exit 1
exit 0
SHIM
cat > "$BOX/bin/dpkg-query" <<'SHIM'
#!/usr/bin/env bash
# FAKE_DPKG="pkg:ii pkg:rc ...": status per package; anything else is unknown (rc 1).
pkg="${!#}"
for entry in ${FAKE_DPKG-}; do
    if [[ "${entry%%:*}" == "$pkg" ]]; then echo -n "${entry#*:} "; exit 0; fi
done
echo "dpkg-query: no packages found matching $pkg" >&2
exit 1
SHIM
cat > "$BOX/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
[[ -n "${FAKE_CURL_FAIL:-}" ]] && exit 22
out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
if [[ -n "${FAKE_BAD_WHEEL:-}" ]]; then echo tampered > "$out"; else cp "$FAKE_WHEEL" "$out"; fi
SHIM
cat > "$BOX/bin/ldconfig" <<'SHIM'
#!/usr/bin/env bash
[[ "${FAKE_LDCONFIG_FAIL:-}" == 1 ]] && exit 1
echo "$(wc -w <<< "${FAKE_LIBS-libgomp.so.1 libvulkan.so.1}") libs found in cache"
for lib in ${FAKE_LIBS-libgomp.so.1 libvulkan.so.1}; do
    printf '\t%s (libc6,x86-64) => /lib/x86_64-linux-gnu/%s\n' "$lib" "$lib"
done
for lib in ${FAKE_LIBS32-}; do
    printf '\t%s (libc6) => /lib/i386-linux-gnu/%s\n' "$lib" "$lib"
done
SHIM
cat > "$BOX/bin/getconf" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == GNU_LIBC_VERSION ]] || exit 1
echo "glibc ${FAKE_GLIBC:-2.41}"
SHIM
cat > "$VENV/bin/pip" <<'SHIM'
#!/usr/bin/env bash
echo "pip $*" >> "$CALLS"
s() { echo "$2" > "$STATE/$1"; }
case "$1" in
  download)
    [[ -n "${FAKE_DOWNLOAD_FAIL:-}" ]] && exit 1
    d=""; prev=""
    for a in "$@"; do [[ "$prev" == "-d" ]] && d="$a"; prev="$a"; done
    [[ -d "$d" ]] || exit 1
    [[ -n "${FAKE_DOWNLOAD_FAIL_OV:-}" && "$*" == *onnxruntime-openvino* ]] && exit 1
    touch "$d/onnxruntime-1.27.0.whl" "$d/onnxruntime_ep_webgpu-0.5.0.whl"
    [[ "$*" == *onnxruntime-openvino* ]] && touch "$d/onnxruntime_openvino-1.24.1.whl"
    ;;
  uninstall)
    [[ -n "${FAKE_UNINSTALL_FAIL:-}" ]] && exit 1
    s ort none; s ort_ver none; s ep none
    ;;
  install)
    # FAKE_OFFLINE: the network went away after the download.
    [[ -n "${FAKE_OFFLINE:-}" && "$*" != *--no-index* ]] && exit 1
    case "$*" in
      *--find-links=*onnxruntime-openvino*)
        [[ -n "${FAKE_RESTORE_FAIL:-}" ]] && exit 1
        for a in "$@"; do
          if [[ "$a" == --find-links=* ]]; then [[ -f "${a#--find-links=}/onnxruntime_openvino-1.24.1.whl" ]] || exit 1; fi
        done
        s ort ov; s ort_ver 1.24.1
        ;;
      *--find-links=*)
        [[ -n "${FAKE_INSTALL_FAIL:-}" ]] && exit 1
        for a in "$@"; do
          if [[ "$a" == --find-links=* ]]; then [[ -f "${a#--find-links=}/onnxruntime-1.27.0.whl" ]] || exit 1; fi
        done
        s ort plain; s ort_ver 1.27.0; s ep 0.5.0
        ;;
      *"--upgrade -r "*)
        # A bulk install writes the OpenVINO build over onnxruntime/, unless a
        # stray dependency brought the plain wheel in on top (FAKE_BULK_PLAIN).
        if [[ -n "${FAKE_BULK_PLAIN:-}" ]]; then s ort plain; s ort_ver 1.27.0; else s ort ov; s ort_ver 1.24.1; fi
        ;;
      *--force-reinstall*onnxruntime-openvino*)
        [[ -n "${FAKE_RESTORE_FAIL:-}" ]] && exit 1
        s ort ov; s ort_ver 1.24.1
        ;;
      *--force-reinstall*llama_cpp_python*)
        [[ -n "${FAKE_WHEEL_INSTALL_FAIL:-}" ]] && exit 1
        [[ -f "${!#}" ]] || exit 1
        s llama vulkan
        ;;
      *)
        [[ -n "${FAKE_PIN_FAIL:-}" ]] && exit 1
        for a in "$@"; do
          [[ "$a" == openvino*==* ]] && s "${a%%==*}" "${a#*==}"
        done
        ;;
    esac
    ;;
esac
exit 0
SHIM
cat > "$VENV/bin/python" <<'SHIM'
#!/usr/bin/env bash
code=""
while [[ $# -gt 0 ]]; do case "$1" in -c) code="$2"; shift 2;; *) shift;; esac; done
g() { cat "$STATE/$1" 2>/dev/null; }
case "$code" in
  *onnxruntime_ep_webgpu*)
    echo "python ort-webgpu-probe" >> "$CALLS"
    [[ "$(g ort_ver)" == 1.27.0 && "$(g ep)" != none ]] ;;
  *OpenVINOExecutionProvider*)
    echo "python ov-ep-probe" >> "$CALLS"
    [[ "$(g ort)" == ov ]] ;;
  *llama_supports_gpu_offload*)
    echo "python offload-probe" >> "$CALLS"
    [[ "$(g llama)" == vulkan && "${FAKE_NO_MESA:-}" != 1 && "${FAKE_LLAMA_BROKEN:-}" != 1 ]] ;;
  *"import llama_cpp"*)
    echo "python llama-import-probe" >> "$CALLS"
    [[ "${FAKE_LLAMA_BROKEN:-}" != 1 ]] ;;
  *importlib.metadata*)
    echo "python pin-probe" >> "$CALLS"
    for d in openvino-genai openvino-tokenizers openvino; do
      if [[ "$code" == *"'$d'"* ]]; then v="$(g "$d")"; [[ -n "$v" && "$v" != none ]] && echo "$v" && exit 0; exit 1; fi
    done
    exit 1 ;;
  *"import onnxruntime"*)
    [[ "$(g ort)" != none ]] ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$BOX/bin/"* "$VENV/bin/"*
export PATH="$BOX/bin:$PATH"

[[ "$(command -v sudo)" == "$BOX/bin/sudo" ]] || { echo "  FAIL — sudo shim is not first on PATH; refusing to run"; exit 1; }

# Fixture requirements: the shape the Parser repo ships, deliberately not read from it.
cat > "$PARSER/requirements.txt" <<'REQ'
# comment mentioning openvino==1.0 should not be picked up
uvicorn>=0.30
onnxruntime-openvino==1.24.1
openvino==2026.4.0  # bumping this is a VLM change
openvino-genai==2026.4.0.0
openvino-tokenizers==2026.4.0.0
openvino-telemetry
llama-cpp-python==0.3.34
REQ
cat > "$PARSER/build/sysroot/usr/lib/systemd/system/nimoos-parser.service" <<'UNIT'
[Service]
MemoryMax=12G
UNIT
touch "$PARSER/parser/main.py"
cat > "$BUILD/release/versions.conf" <<'CONF'
NIMOOS_VERSION="0.0.0-test"
CONF
cat > "$BUILD/release/lib/version_inject.sh" <<'INJECT'
resolve_full_version() { printf '0.0.0-test+1'; }
INJECT

# The wheel the curl stub serves, and the checksum the sandboxed lib pins for it.
export FAKE_WHEEL="$BOX/fixture.whl"
echo "fixture wheel" > "$FAKE_WHEEL"
FIXTURE_SHA="$(sha256sum "$FAKE_WHEEL" | cut -d' ' -f1)"

cp "$HERE/lib/parser-unit.sh" "$BUILD/scripts/lib/"
redirect_slot_markers() {
    sed -e "s#/usr/share/nimoos/parser/parser/component-manifest.json#$BOX/slot-component-manifest.json#g" \
        -e "s#/usr/lib/systemd/system/nimoos-parser-prepare.service#$BOX/slot-prepare.service#g" "$1"
}
install_box_scripts() {   # install_box_scripts <deploy script> <build root>: copy and redirect paths
    local src="$1" root="$2" dst="$2/scripts/deploy-parser.sh"
    mkdir -p "$root/scripts/lib"
    redirect_slot_markers "$src" | sed -e "s#^INSTALL_DIR=\"/opt/nimoos-parser\"\$#INSTALL_DIR=\"$INSTALL\"#" \
        -e "s#^UNIT_DST=\"/usr/lib/systemd/system/\$SERVICE\"\$#UNIT_DST=\"$BOX/unit/\$SERVICE\"#" \
        > "$dst"
    grep -q "^INSTALL_DIR=\"$INSTALL\"\$" "$dst" && grep -q "^UNIT_DST=\"$BOX/unit/" "$dst" \
        || { echo "  FAIL — could not redirect the sandbox copy of deploy-parser.sh; refusing to run"; exit 1; }
    if [[ -f "$LIB_SRC" ]]; then
        sed "s/^DEP_LLAMA_VULKAN_SHA256=.*/DEP_LLAMA_VULKAN_SHA256=\"$FIXTURE_SHA\"/" "$LIB_SRC" > "$root/scripts/lib/parser-gpu-branch.sh"
        grep -q "$FIXTURE_SHA" "$root/scripts/lib/parser-gpu-branch.sh" \
            || { echo "  FAIL — could not pin the fixture checksum in the sandbox lib"; exit 1; }
    fi
    cp "$HERE/lib/parser-unit.sh" "$root/scripts/lib/"
    # Small size pins, so the scratch and unpack space checks never depend on free space here.
    if [[ -f "$NPU_LIB_SRC" ]]; then
        sed -e 's/^PARSER_NPU_AMD_SIZE_BYTES=.*/PARSER_NPU_AMD_SIZE_BYTES="1000"/' \
            -e 's/^PARSER_NPU_AMD_UNPACKED_BYTES=.*/PARSER_NPU_AMD_UNPACKED_BYTES="1000"/' "$NPU_LIB_SRC" > "$root/scripts/lib/parser-npu-amd.sh"
    fi
}
install_box_scripts "$DEPLOY_SRC" "$BUILD"

card() {   # card <drm root> <cardN> <vendor id>
    mkdir -p "$1/$2/device"
    echo "$3" > "$1/$2/device/vendor"
}

# new_box <intel|amd|cpu> <env assignments...>: fresh venv state, one card of the
# vendor (none for cpu), and every FAKE_ knob cleared. The venv starts the way a
# prebuilt one is: OpenVINO ONNX Runtime, CPU llama.cpp, OpenVINO at the pins.
new_box() {
    rm -rf "$STATE" "$DRM" "$SCRATCH"
    mkdir -p "$STATE" "$DRM" "$SCRATCH"
    : > "$CALLS"
    unset FAKE_APT_FAIL FAKE_CURL_FAIL FAKE_BAD_WHEEL FAKE_LDCONFIG_FAIL FAKE_LIBS FAKE_LIBS32 FAKE_GLIBC \
          FAKE_DOWNLOAD_FAIL FAKE_UNINSTALL_FAIL FAKE_INSTALL_FAIL FAKE_RESTORE_FAIL FAKE_WHEEL_INSTALL_FAIL \
          FAKE_PIN_FAIL FAKE_NO_MESA FAKE_BULK_PLAIN FAKE_DPKG FAKE_OFFLINE FAKE_DOWNLOAD_FAIL_OV \
          FAKE_LLAMA_BROKEN DEPLOY_SRC_DIR NIMO_PIP_INDEX
    echo ov > "$STATE/ort"; echo 1.24.1 > "$STATE/ort_ver"; echo none > "$STATE/ep"
    echo cpu > "$STATE/llama"
    echo 2026.4.0 > "$STATE/openvino"
    echo 2026.4.0.0 > "$STATE/openvino-genai"
    echo 2026.4.0.0 > "$STATE/openvino-tokenizers"
    case "$1" in
        intel) card "$DRM" card0 0x8086 ;;
        amd)   card "$DRM" card0 0x1002 ;;
    esac
    local kv; for kv in "${@:2}"; do export "$kv"; done
}
# deploy <args...>: run the sandbox copy; sets rc and leaves stdout+stderr in $BOX/out
deploy() {
    NIMO_DRM_ROOT="$DRM" TMPDIR="$SCRATCH" bash "$BUILD/scripts/deploy-parser.sh" "$@" > "$BOX/out" 2>&1
    rc=$?
}
called()     { grep -qF -- "$1" "$CALLS"; }
line_of()    { grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
pip_calls()  { grep -c '^pip ' "$CALLS"; }
in_order()   {   # in_order <a> <b>: first a comes before first b, both present
    local a b; a="$(line_of "$1")"; b="$(line_of "$2")"
    [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]
}
stopped_then_started() { in_order "systemctl stop" "systemctl start"; }
state()      { cat "$STATE/$1"; }
warned()     { grep -qi -- "warn" "$BOX/out"; }
scratch_empty() { [[ -z "$(ls -A "$SCRATCH")" ]]; }

UNINSTALL="pip uninstall -y onnxruntime-openvino onnxruntime"
ORT_SPECS="onnxruntime==1.27.0 onnxruntime-ep-webgpu==0.5.0"
OV_SWAP="pip install --force-reinstall --no-deps onnxruntime-openvino==1.24.1"
BULK="pip install --upgrade -r $INSTALL/requirements.txt"
HOST_PKGS="mesa-vulkan-drivers libvulkan1 libgomp1"
ALL_DPKG_II="mesa-vulkan-drivers:ii libvulkan1:ii libgomp1:ii"
# ORT installs that are not a plain download: the swap on intel and cpu, or a restore on amd.
ov_installed() { grep -qE '^pip install .*onnxruntime-openvino' "$CALLS"; }
# restored_from <dir>: the OV pin came back from the download directory, offline
restored_from() { called "pip install --force-reinstall --no-deps --no-index --find-links=$1 onnxruntime-openvino==1.24.1"; }
dl_dir_of() { grep '^pip download' "$CALLS" | sed -E 's/.* -d ([^ ]+) .*/\1/'; }

###############################################################################
echo "lib/parser-gpu-branch.sh constants"
###############################################################################
check "lib exists" "[[ -f '$LIB_SRC' ]]"
check "lib pins the T1 wheel path" \
    "grep -qx 'DEP_LLAMA_VULKAN_WHEEL=\"parser/llama-cpp-python-0.3.34-vulkan/llama_cpp_python-0.3.34-py3-none-linux_x86_64.whl\"' '$LIB_SRC'"
check "lib pins the T1 wheel checksum" \
    "grep -qx 'DEP_LLAMA_VULKAN_SHA256=\"541d1688d58e6047a3154fa140829a72c238e054b3c3812b44ef16f9a07b7fbb\"' '$LIB_SRC'"

###############################################################################
echo ""
echo "detect_parser_gpu_branch"
###############################################################################
detect() { bash -c 'source "$1" && detect_parser_gpu_branch "$2"' _ "$LIB_SRC" "$1" 2>/dev/null; }
detect_table() {   # detect_table <name> <want> <card:vendor>...
    local name="$1" want="$2" root="$TMP/table/$1" pair
    mkdir -p "$root"
    for pair in "${@:3}"; do card "$root" "${pair%%:*}" "${pair#*:}"; done
    local got; got="$(detect "$root")"
    [[ "$got" == "$want" ]] && ok "$name → $want" || bad "$name → $want (got '$got')"
}
detect_table "Intel iGPU"                 intel card0:0x8086
detect_table "Intel iGPU + AMD dGPU"      intel card0:0x8086 card1:0x1002
detect_table "AMD dGPU on card0 + Intel"  intel card0:0x1002 card1:0x8086
detect_table "AMD iGPU"                   amd   card0:0x1002
detect_table "AMD iGPU + AMD dGPU"        amd   card0:0x1002 card1:0x1002
detect_table "Nvidia"                     cpu   card0:0x10de
detect_table "Nvidia + AMD"               amd   card0:0x10de card1:0x1002
detect_table "no cards"                   cpu
# a connector node has no device/vendor of its own; it must not confuse the glob
mkdir -p "$TMP/table/connector/card0-DP-1/device"
card "$TMP/table/connector" card0 0x1002
[[ "$(detect "$TMP/table/connector")" == amd ]] && ok "connector nodes are ignored" || bad "connector nodes are ignored"
[[ "$(detect "$TMP/table/does-not-exist")" == cpu ]] && ok "missing DRM root → cpu" || bad "missing DRM root → cpu"

###############################################################################
echo ""
echo "deploy-parser.sh, intel"
###############################################################################
new_box intel
deploy
check "full deploy exits 0" "[[ $rc -eq 0 ]]"
# The pre-change sequence, entry by entry; only the pin spelling may differ.
want_seq="$(printf '%s\n' "$BULK" "python ov-ep-probe" "$OV_SWAP")"
got_seq="$(grep -E '^(pip |python ov-ep-probe|apt-get |curl )' "$CALLS")"
# The bulk stub leaves the OV build active, so the swap is skipped here ...
[[ "$got_seq" == "$(printf '%s\n' "$BULK" "python ov-ep-probe")" ]] \
    && ok "OV EP active → bulk install, probe, no swap" || bad "OV EP active → bulk install, probe, no swap: $got_seq"
stopped_then_started && ok "service stopped, then started" || bad "service stopped, then started"

# ... and runs once a stray plain wheel is on top.
new_box intel FAKE_BULK_PLAIN=1
deploy
got_seq="$(grep -E '^(pip |python ov-ep-probe|apt-get |curl )' "$CALLS")"
[[ "$got_seq" == "$want_seq" ]] \
    && ok "plain wheel on top → bulk install, probe, swap to the exact pin" || bad "plain wheel on top → bulk install, probe, swap to the exact pin: $got_seq"
check "intel never installs Mesa" "! called apt-get"
check "intel never uninstalls" "! called 'pip uninstall'"
check "intel never downloads" "! called 'pip download'"
check "intel never fetches the Vulkan wheel" "! called curl"
[[ "$(state openvino)" == 2026.4.0 ]] && ok "OpenVINO pin unchanged" || bad "OpenVINO pin unchanged"

new_box intel
deploy --no-deps
check "--no-deps exits 0" "[[ $rc -eq 0 ]]"
check "--no-deps makes no pip call" "[[ $(pip_calls) -eq 0 ]]"
check "--no-deps makes no python call" "! grep -q '^python ' '$CALLS'"
check "--no-deps installs nothing with apt" "! called apt-get"
check "--no-deps still restarts the service" "stopped_then_started"

new_box intel
echo plain > "$STATE/ort"
deploy --no-deps --reconcile-gpu-runtime
check "reconcile exits 0" "[[ $rc -eq 0 ]]"
check "reconcile skips pip install -r" "! called 'install --upgrade -r'"
check "reconcile on intel runs the swap" "called '$OV_SWAP'"
check "reconcile runs inside the stop window" "in_order 'systemctl stop' '$OV_SWAP' && in_order '$OV_SWAP' 'systemctl start'"

new_box intel
deploy --no-deps --reconcile-gpu-runtime
check "reconcile with everything in place makes no pip call" "[[ $(pip_calls) -eq 0 ]]"

new_box intel
deploy --reconcile-gpu-runtime
check "--reconcile-gpu-runtime alone is a full deploy" "called '$BULK' && called 'python ov-ep-probe'"

new_box intel FAKE_RESTORE_FAIL=1
echo plain > "$STATE/ort"
deploy --no-deps --reconcile-gpu-runtime
check "swap failure does not fail the deploy" "[[ $rc -eq 0 ]]"
check "swap failure warns" "warned"

###############################################################################
echo ""
echo "deploy-parser.sh, cpu"
###############################################################################
new_box cpu FAKE_BULK_PLAIN=1
deploy
got_seq="$(grep -E '^(pip |python ov-ep-probe|apt-get |curl )' "$CALLS")"
[[ "$got_seq" == "$want_seq" ]] && ok "cpu runs the same sequence as intel" || bad "cpu runs the same sequence as intel: $got_seq"
check "cpu never installs Mesa" "! called apt-get"
check "cpu never uninstalls" "! called 'pip uninstall'"
check "cpu never fetches the Vulkan wheel" "! called curl"

new_box cpu
card "$DRM" card0 0x10de
deploy --no-deps --reconcile-gpu-runtime
check "Nvidia box stays on the cpu branch" "! called apt-get && ! called 'pip download'"

###############################################################################
echo ""
echo "deploy-parser.sh, amd"
###############################################################################
new_box amd
deploy --no-deps --reconcile-gpu-runtime
check "first reconcile exits 0" "[[ $rc -eq 0 ]]"
check "Mesa and its loader are installed without upgrading anything" "called 'apt-get install -y --no-upgrade $HOST_PKGS'"
dl_dir="$(dl_dir_of)"
check "download takes the exact pins and the restore wheel, without dependencies" \
    "called 'pip download --no-deps -d $dl_dir $ORT_SPECS onnxruntime-openvino==1.24.1'"
check "both distributions are uninstalled in one call" "called '$UNINSTALL'"
check "install comes from the download directory only" \
    "called 'pip install --no-deps --no-index --find-links=$dl_dir $ORT_SPECS'"
check "order: download, uninstall, install" \
    "in_order 'pip download' '$UNINSTALL' && in_order '$UNINSTALL' '--find-links=$dl_dir'"
check "Mesa is installed before the wheel gate reads the library cache" "in_order 'apt-get install' 'curl '"
check "wheel comes from the deps mirror path" \
    "called 'parser/llama-cpp-python-0.3.34-vulkan/llama_cpp_python-0.3.34-py3-none-linux_x86_64.whl'"
check "wheel is force-reinstalled without dependencies" \
    "grep -qE '^pip install --force-reinstall --no-deps .*/llama_cpp_python-0.3.34-py3-none-linux_x86_64.whl\$' '$CALLS'"
check "order: ONNX Runtime first, wheel after" "in_order '--find-links=$dl_dir' 'curl '"
check "the onnxruntime-openvino swap never runs on amd" "! ov_installed && ! called 'ov-ep-probe'"
check "the wheel download cannot stall the stop window" "called '--speed-limit 1024 --speed-time 60'"
[[ "$(state ort_ver)" == 1.27.0 && "$(state ep)" == 0.5.0 && "$(state llama)" == vulkan ]] \
    && ok "venv ends on ORT 1.27.0 + WebGPU plugin + Vulkan wheel" || bad "venv ends on ORT 1.27.0 + WebGPU plugin + Vulkan wheel"
check "scratch directories are cleaned up" "scratch_empty"
check "service restarted" "stopped_then_started"

: > "$CALLS"
deploy --no-deps --reconcile-gpu-runtime
check "second reconcile exits 0" "[[ $rc -eq 0 ]]"
check "second reconcile makes no pip call" "[[ $(pip_calls) -eq 0 ]]"
check "second reconcile fetches nothing" "! called curl"

: > "$CALLS"
deploy --no-deps
check "--no-deps on amd makes no pip call" "[[ $(pip_calls) -eq 0 ]]"
check "--no-deps on amd installs nothing with apt" "! called apt-get"
[[ "$(state ort_ver)" == 1.27.0 ]] && ok "--no-deps leaves the amd runtime in place" || bad "--no-deps leaves the amd runtime in place"

# A bulk install writes the OV build back over onnxruntime/; the branch step that
# follows has to bring the amd stack back, and still not run the swap.
: > "$CALLS"
deploy
check "full deploy on amd exits 0" "[[ $rc -eq 0 ]]"
check "full deploy on amd still installs requirements" "called '$BULK'"
check "full deploy on amd re-converges after the bulk install" "in_order '$BULK' 'pip download'"
[[ "$(state ort_ver)" == 1.27.0 && "$(state ep)" == 0.5.0 ]] && ok "full deploy on amd ends on ORT 1.27.0" || bad "full deploy on amd ends on ORT 1.27.0"
check "full deploy on amd never runs the swap" "! ov_installed"

new_box amd NIMO_PIP_INDEX=http://mirror.test/simple/
deploy --no-deps --reconcile-gpu-runtime
check "the pip mirror applies to the download" "called 'pip download -i http://mirror.test/simple/ --no-deps'"
check "the pip mirror does not turn the directory install into a network one" "grep -q -- '--no-index --find-links=' '$CALLS'"

new_box amd FAKE_DOWNLOAD_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "download failure exits 0" "[[ $rc -eq 0 ]]"
check "download failure: no uninstall" "! called 'pip uninstall'"
check "download failure: no install from the directory" "! called '--find-links'"
"$VENV/bin/python" -c 'import onnxruntime' && ok "download failure: import onnxruntime still works" || bad "download failure: import onnxruntime still works"
[[ "$(state ort_ver)" == 1.24.1 ]] && ok "download failure: old ONNX Runtime untouched" || bad "download failure: old ONNX Runtime untouched"
check "download failure stops there: no wheel" "! called curl"
check "download failure warns" "warned"
check "download failure warning names all three wheels it asked for" \
    "grep -- 'could not download' \"\$BOX/out\" | grep -qF 'onnxruntime-openvino==1.24.1'"
check "download failure: service restarted" "stopped_then_started"
check "download failure: scratch cleaned" "scratch_empty"

new_box amd FAKE_INSTALL_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "install failure exits 0" "[[ $rc -eq 0 ]]"
dl_dir="$(dl_dir_of)"
check "install failure restores the onnxruntime-openvino pin from the download directory" "restored_from '$dl_dir'"
check "install failure: restore comes after the failed install" \
    "in_order 'pip install --no-deps --no-index' 'pip install --force-reinstall --no-deps --no-index'"
[[ "$(state ort_ver)" == 1.24.1 && "$(state ort)" == ov ]] && ok "install failure: old ONNX Runtime is back" || bad "install failure: old ONNX Runtime is back"
check "install failure warns" "warned"
check "install failure: service restarted" "stopped_then_started"
check "install failure: scratch cleaned" "scratch_empty"

# The reason this restore is offline: the old runtime is already uninstalled, so if
# it needed the index and the network had gone, the machine would have no ONNX Runtime.
new_box amd FAKE_INSTALL_FAIL=1 FAKE_OFFLINE=1
deploy --no-deps --reconcile-gpu-runtime
check "network lost after the download: exits 0" "[[ $rc -eq 0 ]]"
[[ "$(state ort)" == ov && "$(state ort_ver)" == 1.24.1 ]] \
    && ok "network lost after the download: old ONNX Runtime is back" || bad "network lost after the download: old ONNX Runtime is back"
"$VENV/bin/python" -c 'import onnxruntime' && ok "network lost after the download: import onnxruntime works" || bad "network lost after the download: import onnxruntime works"
check "network lost after the download: scratch cleaned after the restore" "scratch_empty"

new_box amd FAKE_DOWNLOAD_FAIL_OV=1
deploy --no-deps --reconcile-gpu-runtime
check "restore wheel unavailable: exits 0" "[[ $rc -eq 0 ]]"
check "restore wheel unavailable: no uninstall" "! called 'pip uninstall'"
[[ "$(state ort_ver)" == 1.24.1 ]] && ok "restore wheel unavailable: old ONNX Runtime untouched" || bad "restore wheel unavailable: old ONNX Runtime untouched"
check "restore wheel unavailable: warns" "warned"
check "restore wheel unavailable: stops there" "! called curl"

new_box amd FAKE_INSTALL_FAIL=1 FAKE_RESTORE_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "install and restore both failing still exits 0" "[[ $rc -eq 0 ]]"
check "install and restore both failing warns" "warned"
check "install and restore both failing: service restarted" "stopped_then_started"

new_box amd FAKE_UNINSTALL_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "uninstall failure exits 0" "[[ $rc -eq 0 ]]"
check "uninstall failure: no install on top of a half-removed runtime" "! called 'pip install --no-deps --no-index'"
dl_dir="$(dl_dir_of)"
check "uninstall failure restores the pin from the download directory" "restored_from '$dl_dir'"
check "uninstall failure: scratch cleaned" "scratch_empty"

new_box amd FAKE_BAD_WHEEL=1
deploy --no-deps --reconcile-gpu-runtime
check "checksum mismatch exits 0" "[[ $rc -eq 0 ]]"
check "checksum mismatch: wheel not installed" "! grep -q 'llama_cpp_python.*whl\$' <(grep '^pip ' '$CALLS')"
[[ "$(state llama)" == cpu ]] && ok "checksum mismatch: CPU wheel stays" || bad "checksum mismatch: CPU wheel stays"
check "checksum mismatch warns" "warned"
check "checksum mismatch: scratch cleaned" "scratch_empty"
[[ "$(state ort_ver)" == 1.27.0 ]] && ok "checksum mismatch: ONNX Runtime swap is kept" || bad "checksum mismatch: ONNX Runtime swap is kept"

new_box amd FAKE_CURL_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "wheel download failure exits 0" "[[ $rc -eq 0 ]]"
[[ "$(state llama)" == cpu ]] && ok "wheel download failure: CPU wheel stays" || bad "wheel download failure: CPU wheel stays"
check "wheel download failure warns" "warned"

new_box amd FAKE_WHEEL_INSTALL_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "wheel install failure exits 0" "[[ $rc -eq 0 ]]"
[[ "$(state llama)" == cpu ]] && ok "wheel install failure: CPU wheel stays" || bad "wheel install failure: CPU wheel stays"
check "wheel install failure warns" "warned"

missing_lib() {   # missing_lib <name> <env assignments...>
    local name="$1"; shift
    new_box amd "$@"
    deploy --no-deps --reconcile-gpu-runtime
    check "$name: exits 0" "[[ $rc -eq 0 ]]"
    check "$name: wheel not downloaded" "! called curl"
    check "$name: wheel not installed" "! called 'llama_cpp_python'"
    [[ "$(state llama)" == cpu ]] && ok "$name: CPU wheel stays" || bad "$name: CPU wheel stays"
    check "$name: warns" "warned"
    [[ "$(state ort_ver)" == 1.27.0 ]] && ok "$name: ONNX Runtime swap is unaffected" || bad "$name: ONNX Runtime swap is unaffected"
}
missing_lib "no libvulkan.so.1"           "FAKE_LIBS=libgomp.so.1"
missing_lib "no libgomp.so.1"             "FAKE_LIBS=libvulkan.so.1"
missing_lib "neither library"             "FAKE_LIBS="
missing_lib "only 32-bit libvulkan.so.1"  "FAKE_LIBS=libgomp.so.1" "FAKE_LIBS32=libvulkan.so.1"
missing_lib "ldconfig fails"              "FAKE_LDCONFIG_FAIL=1"
missing_lib "glibc older than the wheel"  "FAKE_GLIBC=2.36"

new_box amd FAKE_APT_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "apt failure exits 0" "[[ $rc -eq 0 ]]"
check "apt failure warns" "warned"
check "apt failure does not block the ONNX Runtime step" "called 'pip download'"

# libvulkan1 without Mesa: the wheel loads and runs on CPU; offload stays false.
new_box amd FAKE_NO_MESA=1
deploy --no-deps --reconcile-gpu-runtime
check "no Mesa ICD exits 0" "[[ $rc -eq 0 ]]"
check "no Mesa ICD warns that offload is off" "grep -q 'no Mesa' '$BOX/out'"
check "no Mesa ICD does not claim an import failure" "! grep -q 'does not import' '$BOX/out'"

# The wheel installed but cannot load: not the same thing as CPU-only, and the
# message must not send anyone looking for Mesa.
new_box amd FAKE_LLAMA_BROKEN=1
deploy --no-deps --reconcile-gpu-runtime
check "wheel fails to import: exits 0" "[[ $rc -eq 0 ]]"
check "wheel fails to import: says so" "grep -q 'does not import' '$BOX/out'"
check "wheel fails to import: does not blame Mesa" "! grep -q 'no Mesa' '$BOX/out'"
check "wheel fails to import: service restarted" "stopped_then_started"

# Host packages. A plain deploy must not move Mesa: a new version changes the
# self-test fingerprint and sends every model through self-test again.
new_box amd "FAKE_DPKG=$ALL_DPKG_II"
deploy --no-deps --reconcile-gpu-runtime
check "all three packages installed: no apt call at all" "! called apt-get"
check "all three packages installed: no warning about them" "! grep -q 'libgomp1' '$BOX/out'"

for missing in "mesa-vulkan-drivers:rc libvulkan1:ii libgomp1:ii" "libvulkan1:ii libgomp1:ii" "mesa-vulkan-drivers:ii libvulkan1:ii"; do
    new_box amd "FAKE_DPKG=$missing"
    deploy --no-deps --reconcile-gpu-runtime
    check "[$missing] → apt installs, without upgrading" "called 'apt-get install -y --no-upgrade $HOST_PKGS'"
    check "[$missing] → apt never installs without --no-upgrade" "! grep -E '^apt-get install' '$CALLS' | grep -qv -- '--no-upgrade'"
done

new_box amd FAKE_APT_FAIL=1
deploy --no-deps --reconcile-gpu-runtime
check "apt retried after a list update, still without upgrading" \
    "[[ \$(grep -c '^apt-get install -y --no-upgrade ' '$CALLS') -eq 2 ]] && called 'apt-get update'"

# Pins are enforced on every branch, and only when they differ.
for branch in intel amd cpu; do
    new_box "$branch"
    echo 2026.3.0 > "$STATE/openvino"
    echo 2026.3.0.0 > "$STATE/openvino-genai"
    deploy --no-deps --reconcile-gpu-runtime
    check "$branch: wrong OpenVINO pins are corrected, without dependencies" \
        "called 'pip install --no-deps openvino==2026.4.0 openvino-genai==2026.4.0.0'"
    check "$branch: a pin already right is left alone" "! called 'openvino-tokenizers=='"
    [[ "$(state openvino)" == 2026.4.0 ]] && ok "$branch: OpenVINO ends at the pin" || bad "$branch: OpenVINO ends at the pin"
done
new_box intel FAKE_PIN_FAIL=1
echo 2026.3.0 > "$STATE/openvino"
deploy --no-deps --reconcile-gpu-runtime
check "pin install failure exits 0" "[[ $rc -eq 0 ]]"
check "pin install failure warns" "warned"

###############################################################################
echo ""
echo "deploy-parser.sh, amd with a Parser that pins no exact versions"
###############################################################################
cp "$PARSER/requirements.txt" "$BOX/requirements.exact"
OLD_SWAP="pip install --force-reinstall --no-deps onnxruntime-openvino>=1.24"
old_requirements() {   # old_requirements <onnxruntime line>
    printf '%s\n' "uvicorn>=0.30" "$1" "openvino>=2026.0" "openvino-genai>=2026.0" > "$PARSER/requirements.txt"
}
amd_runtime_untouched() {   # amd_runtime_untouched <label>
    check "$1: exits 0" "[[ $rc -eq 0 ]]"
    check "$1: no download" "! called 'pip download'"
    check "$1: no uninstall" "! called 'pip uninstall'"
    check "$1: no wheel" "! called curl"
    check "$1: no Mesa" "! called apt-get"
    [[ "$(state ort)" == ov && "$(state ort_ver)" == 1.24.1 && "$(state llama)" == cpu ]] \
        && ok "$1: venv stays on onnxruntime-openvino and the CPU wheel" \
        || bad "$1: venv stays on onnxruntime-openvino and the CPU wheel"
    check "$1: says why, once" "[[ \$(grep -c 'pins no exact' '$BOX/out') -eq 1 ]]"
    check "$1: service restarted" "stopped_then_started"
}

old_requirements "onnxruntime-openvino>=1.24"
new_box amd
deploy --no-deps --reconcile-gpu-runtime
amd_runtime_untouched "range requirement"
check "range requirement: OV probe ran, as on intel and cpu" "called 'python ov-ep-probe'"
check "range requirement: a working venv needs no pip call" "[[ $(pip_calls) -eq 0 ]]"

new_box amd
deploy --reconcile-gpu-runtime
amd_runtime_untouched "range requirement, full deploy"
check "range requirement, full deploy: installs requirements" "called '$BULK'"

new_box amd FAKE_BULK_PLAIN=1
deploy --reconcile-gpu-runtime
check "range requirement, plain wheel stomp: runs the swap with that requirement" "called '$OLD_SWAP'"
check "range requirement, plain wheel stomp: no wheel" "! called curl"

old_requirements "onnxruntime-openvino"
new_box amd
deploy --no-deps --reconcile-gpu-runtime
amd_runtime_untouched "bare requirement"

old_requirements "# no onnxruntime here"
new_box amd
deploy --no-deps --reconcile-gpu-runtime
amd_runtime_untouched "absent requirement"

# The same machine on a Parser with the exact pins gets the AMD stack.
cp "$BOX/requirements.exact" "$PARSER/requirements.txt"
new_box amd
deploy --no-deps --reconcile-gpu-runtime
[[ "$(state ort_ver)" == 1.27.0 && "$(state llama)" == vulkan ]] \
    && ok "exact requirement: replaces ONNX Runtime and the wheel" || bad "exact requirement: replaces ONNX Runtime and the wheel"
check "exact requirement: no such log line" "! grep -q 'pins no exact' '$BOX/out'"

# Intel and CPU are not affected by the check.
old_requirements "onnxruntime-openvino>=1.24"
new_box intel
deploy --no-deps --reconcile-gpu-runtime
check "range requirement on intel: no such log line" "! grep -q 'pins no exact' '$BOX/out'"
cp "$BOX/requirements.exact" "$PARSER/requirements.txt"

echo ""
echo "deploy-parser.sh from a Build worktree"
###############################################################################
# T20/T21 run DEV-NimoOS-Build-b22/scripts/deploy-parser.sh with DEPLOY_SRC_DIR:
# no sibling NimoOS-Build next to it, and the Parser source is a worktree.
WT="$BOX/repo2/DEV-NimoOS-Build-wt"
WT_PARSER="$BOX/repo2/DEV-NimoOS-Parser-wt"
mkdir -p "$WT/release/lib" "$WT_PARSER/parser" "$WT_PARSER/build/sysroot/usr/lib/systemd/system"
cp "$BUILD/release/versions.conf" "$WT/release/"
cp "$BUILD/release/lib/version_inject.sh" "$WT/release/lib/"
cp "$PARSER/requirements.txt" "$WT_PARSER/"
cp "$PARSER/build/sysroot/usr/lib/systemd/system/nimoos-parser.service" "$WT_PARSER/build/sysroot/usr/lib/systemd/system/"
echo marker > "$WT_PARSER/parser/from-worktree.py"
install_box_scripts "$DEPLOY_SRC" "$WT"
new_box amd
NIMO_DRM_ROOT="$DRM" TMPDIR="$SCRATCH" DEPLOY_SRC_DIR="$WT_PARSER" bash "$WT/scripts/deploy-parser.sh" --no-deps --reconcile-gpu-runtime > "$BOX/out" 2>&1
rc=$?
check "worktree deploy exits 0" "[[ $rc -eq 0 ]]"
check "worktree deploy syncs from DEPLOY_SRC_DIR" "[[ -f '$INSTALL/parser/from-worktree.py' ]]"
check "worktree deploy finds its own lib" "called 'pip download'"

###############################################################################
echo ""
echo "deploy-parser.sh managed recovery routing"
###############################################################################
cat > "$BUILD/scripts/install-parser.sh" <<'SHIM'
#!/usr/bin/env bash
printf 'component installer %s source=%s code-only=%s\n' "$*" "$DEPLOY_SRC_DIR" "$NIMO_PARSER_CODE_ONLY" >> "$CALLS"
SHIM
new_box intel
touch "$PARSER/parser/component-manifest.json"
chmod -x "$VENV/bin/python"
deploy --no-deps
check "managed deploy reaches recovery with an unavailable live venv" "called 'component installer --start source=$PARSER code-only=1'"
check "managed deploy delegates service lifecycle to the installer" "! called systemctl"
chmod +x "$VENV/bin/python"
rm -- "$PARSER/parser/component-manifest.json"

new_box intel
touch "$BOX/slot-component-manifest.json" "$BOX/slot-prepare.service"
deploy --no-deps
check "slot-managed deployment rejects a legacy payload" "[[ $rc -ne 0 ]] && grep -q 'image/OTA update route' '$BOX/out'"
check "slot-managed deployment leaves the service untouched" "[[ ! -s '$CALLS' ]]"
redirect_slot_markers "$HERE/install-parser.sh" > "$BUILD/scripts/install-parser.sh"
cat > "$BUILD/scripts/lib/stack-fetch.sh" <<'SHIM'
STACK_VERSION=fixture
stack_resolve() { printf 'attempted payload acquisition\n' >> "$CALLS"; return 51; }
SHIM
NIMO_PARSER_SCRATCH_ROOT="$BOX/install-scratch" bash "$BUILD/scripts/install-parser.sh" > "$BOX/out" 2>&1
rc=$?
check "slot-managed installer rejects before selecting a legacy or managed payload" "[[ $rc -ne 0 ]] && grep -q 'image/OTA update route' '$BOX/out' && [[ ! -s '$CALLS' ]]"
rm -- "$BOX/slot-component-manifest.json" "$BOX/slot-prepare.service"

###############################################################################
echo ""
echo "legacy writers and the component engine's lock"
###############################################################################
# The engine serialises on the live path's sibling .<name>.update.lock. Both
# legacy writers (deploy-parser.sh, install-parser.sh without a manifest) must
# take it before their managed check, so a migration that finishes while they
# wait is seen and refused instead of being written through the new links.
LOCK="$(dirname "$INSTALL")/.$(basename "$INSTALL").update.lock"
# migrate_under_lock <hold secs>: hold the lock like the engine does, then turn
# $INSTALL into the anchored layout (parser -> .current/parser) and release.
migrate_under_lock() {
    flock -x "$LOCK" bash -c '
        sleep "$1"
        mv "$2/parser" "$3/legacy-parser"
        mkdir -p "$3/managed/parser"; echo new > "$3/managed/parser/new.py"
        ln -s "$3/managed" "$2/.current"; ln -s .current/parser "$2/parser"' _ "$1" "$INSTALL" "$BOX" &
    holder=$!
    for _ in $(seq 1 50); do flock -n "$LOCK" true || break; sleep 0.1; done   # until the holder has it
}
unmigrate() {   # only after migrate_under_lock: an unpaired call would rm the real parser/ dir
    [[ -L "$INSTALL/.current" && -d "$BOX/legacy-parser" ]] || { bad "unmigrate called without a migration to undo"; return; }
    rm -f -- "$INSTALL/.current" "$INSTALL/parser"; rm -rf -- "$BOX/managed"
    mv "$BOX/legacy-parser" "$INSTALL/parser"
}
install_box_scripts "$DEPLOY_SRC" "$BUILD"

new_box intel
ln -s "$BOX/nowhere" "$INSTALL/.current"
deploy --no-deps
check "deploy-parser: a managed live path refuses a legacy payload" "[[ $rc -ne 0 ]] && grep -q 'managed Parser requires a payload with component-manifest.json' '$BOX/out'"
check "deploy-parser: the refusal touches neither unit nor service" "! called systemctl"
rm -- "$INSTALL/.current"

new_box intel
migrate_under_lock 2
deploy --no-deps
wait "$holder"
check "deploy-parser: waits for the engine's lock" "grep -q 'waiting for another Parser update to finish' '$BOX/out'"
check "deploy-parser: refuses the migration that landed while it waited" "[[ $rc -ne 0 ]] && grep -q 'managed Parser requires' '$BOX/out'"
check "deploy-parser: the managed release keeps its files" "[[ -f '$BOX/managed/parser/new.py' ]] && [[ ! -e '$BOX/managed/parser/from-worktree.py' ]]"
check "deploy-parser: the service was never stopped" "! called 'systemctl stop'"
unmigrate

# install-parser.sh, legacy payload. The sandbox copy drops the non-root
# re-exec through sudo (this test is not root, and EUID cannot be faked); the
# rewrite is checked before anything runs. A stack-fetch stub resolves a
# complete legacy payload.
mkdir -p "$BOX/payload/parser" "$BOX/payload/build/sysroot/usr/lib/systemd/system" "$BOX/payload/build/sysroot/etc/nimoos"
echo x > "$BOX/payload/requirements.txt"
echo '[Service]' > "$BOX/payload/build/sysroot/usr/lib/systemd/system/nimoos-parser.service"
echo '' > "$BOX/payload/build/sysroot/etc/nimoos/parser.conf"
redirect_slot_markers "$HERE/install-parser.sh" | sed -e 's/^if (( EUID != 0 )); then$/if false; then  # sandbox: no sudo re-exec/' > "$BUILD/scripts/install-parser.sh"
grep -q '^if false; then  # sandbox: no sudo re-exec' "$BUILD/scripts/install-parser.sh" \
    || { echo "  FAIL — could not drop the sudo re-exec in the sandbox install-parser.sh; refusing to run"; exit 1; }
cat > "$BUILD/scripts/lib/stack-fetch.sh" <<SHIM
STACK_VERSION=fixture
stack_resolve() { echo "$BOX/payload"; return 0; }
SHIM
run_installer() {   # run_installer <timeout secs>
    NIMO_PARSER_INSTALL_DIR="$INSTALL" NIMO_PARSER_SCRATCH_ROOT="$BOX/install-scratch" \
        timeout "$1" bash "$BUILD/scripts/install-parser.sh" > "$BOX/out" 2>&1
    rc=$?
}

new_box intel
flock -x "$LOCK" sleep 6 & holder=$!
for _ in $(seq 1 50); do flock -n "$LOCK" true || break; sleep 0.1; done
run_installer 3
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "install-parser: a legacy install waits for the engine's lock" "[[ $rc -eq 124 ]] && grep -q 'waiting for another Parser update to finish' '$BOX/out'"
check "install-parser: nothing past the managed check ran while waiting" "! grep -q 'preparing a Python 3.11 runtime' '$BOX/out'"

new_box intel
migrate_under_lock 2
run_installer 20
wait "$holder"
check "install-parser: refuses the migration that landed while it waited" "[[ $rc -ne 0 && $rc -ne 124 ]] && grep -q 'this Parser uses component updates' '$BOX/out'"
check "install-parser: the managed release keeps its files" "[[ -f '$BOX/managed/parser/new.py' ]]"
unmigrate

# A custom install location whose parent does not exist yet: the lock lives next
# to INSTALL_DIR, so the parent has to be created before it is opened (the engine
# does the same). The real function, from the installer sourced as a library.
CUSTOM="$BOX/custom-root/not-yet/parser"
out="$(NIMO_PARSER_LIBRARY_ONLY=1 NIMO_PARSER_INSTALL_DIR="$CUSTOM" \
       bash -c 'f="$1"; shift; source "$f"; acquire_live_update_lock && echo LOCKED' _ "$HERE/install-parser.sh" 2>&1)"
check "install-parser: locks a custom install dir whose parent did not exist" "grep -q LOCKED <<<'$out' && [[ -f '$BOX/custom-root/not-yet/.parser.update.lock' ]]"
check "install-parser: no 'No such file' on the lock" "! grep -q 'No such file' <<<'$out'"
install_box_scripts "$DEPLOY_SRC" "$BUILD"

###############################################################################
echo ""
echo "deploy-parser.sh --amd-npu-package"
###############################################################################
# ensure_amd_npu_package itself is covered by install-parser.npu-amd.test.sh;
# this checks the option's wiring: off by default, a no-op without the NPU, and
# with it the download runs before the service is stopped (it must not lengthen
# the outage), is bounded in time, and never fails the deploy.
PCI="$BOX/pci"
npu_pci() {   # npu_pci <vendor:device>...
    rm -rf "$PCI"; mkdir -p "$PCI"
    local n=0 pair
    for pair in "$@"; do
        mkdir -p "$PCI/dev$n"; echo "0x${pair%%:*}" > "$PCI/dev$n/vendor"; echo "0x${pair#*:}" > "$PCI/dev$n/device"
        n=$((n+1))
    done
}
export NIMO_PCI_ROOT="$PCI" NIMO_DL_TMPDIR="$SCRATCH"
new_box amd FAKE_LIBS="libcurl.so.4 libedit.so.2 libgomp.so.1" FAKE_CURL_FAIL=1
npu_pci 1022:17f0
deploy --no-deps
check "without the option: no AMD NPU step" "[[ $rc -eq 0 ]] && ! grep -q 'AMD NPU' '$BOX/out' && ! called 'nimoos-parser-npu-amd'"

new_box amd FAKE_LIBS="libcurl.so.4 libedit.so.2 libgomp.so.1" FAKE_CURL_FAIL=1
npu_pci 1002:150e 1022:1502
deploy --no-deps --amd-npu-package
check "no 1022:17f0: exits 0" "[[ $rc -eq 0 ]]"
check "no 1022:17f0: says it skipped" "grep -q 'skipping the AMD NPU package' '$BOX/out'"
check "no 1022:17f0: no download" "! called 'nimoos-parser-npu-amd'"

new_box amd FAKE_LIBS="libcurl.so.4 libedit.so.2 libgomp.so.1" FAKE_CURL_FAIL=1
npu_pci 1022:17f0
deploy --no-deps --amd-npu-package
check "1022:17f0, download fails: exits 0" "[[ $rc -eq 0 ]]"
check "1022:17f0: fetches the pinned package" "called 'parser/nimoos-parser-npu-amd-1.0.12-2.tar.zst'"
check "1022:17f0: the download runs before the service is stopped" \
    "in_order 'nimoos-parser-npu-amd' 'systemctl stop'"
check "1022:17f0: the download is bounded in time" "grep -q '^curl .*--max-time 1800 ' '$CALLS'"
check "1022:17f0, download fails: warns and starts the service" "grep -q 'could not fetch the AMD NPU package' '$BOX/out' && called 'systemctl start'"
check "1022:17f0, download fails: no pip call" "[[ \$(pip_calls) -eq 0 ]]"
check "1022:17f0, download fails: nothing under INSTALL_DIR/flm" "[[ ! -e '$INSTALL/flm' ]]"
unset NIMO_PCI_ROOT NIMO_DL_TMPDIR FAKE_LIBS FAKE_CURL_FAIL

###############################################################################
echo ""
echo "req_spec"
###############################################################################
spec() { bash -c 'source "$1"; INSTALL_DIR="$2"; req_spec "$3"' _ "$LIB_SRC" "$INSTALL" "$1" 2>/dev/null; }
cp "$PARSER/requirements.txt" "$INSTALL/requirements.txt"
[[ "$(spec onnxruntime-openvino)" == "onnxruntime-openvino==1.24.1" ]] && ok "exact pin" || bad "exact pin (got '$(spec onnxruntime-openvino)')"
[[ "$(spec openvino)" == "openvino==2026.4.0" ]] && ok "anchored name, trailing comment dropped" || bad "anchored name, trailing comment dropped (got '$(spec openvino)')"
[[ "$(spec openvino-telemetry)" == "openvino-telemetry" ]] && ok "unpinned line → bare name" || bad "unpinned line → bare name"
[[ "$(spec not-listed)" == "not-listed" ]] && ok "absent → bare name" || bad "absent → bare name"

###############################################################################
echo ""
echo "probe code on a real interpreter"
###############################################################################
# The stubs above match on the probe text. These run that text for real, against
# fake modules, in case the Python itself is wrong.
if command -v python3 >/dev/null 2>&1; then
    REAL="$TMP/real"
    mkdir -p "$REAL/venv/bin" "$REAL/mods"
    cat > "$REAL/venv/bin/python" <<SHIM
#!/usr/bin/env bash
exec env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$REAL/mods" python3 "\$@"
SHIM
    cat > "$REAL/venv/bin/pip" <<SHIM
#!/usr/bin/env bash
echo "pip \$*" >> "$REAL/pip.log"
exit 1
SHIM
    chmod +x "$REAL/venv/bin/"*
    cp "$PARSER/requirements.txt" "$REAL/requirements.txt"
    probe_run() {   # probe_run <function>: runs it from the lib against the fake modules
        : > "$REAL/pip.log"; : > "$CALLS"
        bash -c '
            source "$1"; sudo_cmd=""; VENV_DIR="$2/venv"; INSTALL_DIR="$2"
            log_info() { :; }; log_ok() { :; }; log_warn() { :; }
            "$3"
        ' _ "$LIB_SRC" "$REAL" "$1" >/dev/null 2>&1
    }
    fake_mods() {   # fake_mods <ort version|none> <ep 0|1> <offload True|False|none>
        rm -rf "$REAL/mods"; mkdir -p "$REAL/mods"
        [[ "$1" != none ]] && mkdir "$REAL/mods/onnxruntime" && echo "__version__ = '$1'" > "$REAL/mods/onnxruntime/__init__.py"
        [[ "$2" == 1 ]] && touch "$REAL/mods/onnxruntime_ep_webgpu.py"
        [[ "$3" != none ]] && printf 'def llama_supports_gpu_offload():\n    return %s\n' "$3" > "$REAL/mods/llama_cpp.py"
        for pin in openvino:2026.4.0 openvino_genai:2026.4.0.0 openvino_tokenizers:2026.4.0.0; do
            local name="${pin%%:*}" ver="${pin#*:}"
            mkdir -p "$REAL/mods/$name-$ver.dist-info"
            printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "${name//_/-}" "$ver" > "$REAL/mods/$name-$ver.dist-info/METADATA"
        done
    }
    fake_mods 1.27.0 1 True
    probe_run ensure_amd_runtime
    [[ ! -s "$REAL/pip.log" ]] && ok "ORT 1.27.0 + plugin + offload → nothing to do" || bad "ORT 1.27.0 + plugin + offload → nothing to do"
    fake_mods 1.24.1 1 True
    probe_run ensure_amd_runtime
    grep -q '^pip download' "$REAL/pip.log" && ok "wrong ORT version → swap starts" || bad "wrong ORT version → swap starts"
    fake_mods 1.27.0 0 True
    probe_run ensure_amd_runtime
    grep -q '^pip download' "$REAL/pip.log" && ok "plugin missing → swap starts" || bad "plugin missing → swap starts"
    fake_mods none 0 True
    probe_run ensure_amd_runtime
    grep -q '^pip download' "$REAL/pip.log" && ok "ORT not importable → swap starts" || bad "ORT not importable → swap starts"
    fake_mods 1.27.0 1 False
    probe_run ensure_amd_runtime
    called "curl " && ok "offload false → wheel fetched" || bad "offload false → wheel fetched"
    fake_mods 1.27.0 1 none
    probe_run ensure_amd_runtime
    called "curl " && ok "llama_cpp not importable → wheel fetched" || bad "llama_cpp not importable → wheel fetched"
    fake_mods 1.27.0 1 True
    probe_run ensure_openvino_pins
    [[ ! -s "$REAL/pip.log" ]] && ok "installed pins read from real metadata → no install" || bad "installed pins read from real metadata → no install"
    rm -rf "$REAL/mods/openvino_genai-"*
    probe_run ensure_openvino_pins
    grep -q 'openvino-genai==2026.4.0.0' "$REAL/pip.log" && ok "distribution not installed → pin installed" || bad "distribution not installed → pin installed"
else
    echo "  skip — python3 not installed"
fi

###############################################################################
echo ""
echo "no apt"
###############################################################################
unset FAKE_DPKG
no_apt_out="$(bash -c '
    source "$1"; sudo_cmd=""
    log_info() { :; }; log_ok() { :; }; log_warn() { echo "WARN: $*"; }
    command() { [[ "${2:-}" == apt-get ]] && return 1; builtin command "$@"; }
    ensure_amd_host_vulkan
    echo "rc=$?"
' _ "$LIB_SRC" 2>&1)"
[[ "$no_apt_out" == *WARN* && "$no_apt_out" == *"rc=0"* ]] && ok "no apt-get → warns, rc 0" || bad "no apt-get → warns, rc 0 ($no_apt_out)"
export FAKE_DPKG="$ALL_DPKG_II"
no_apt_out="$(bash -c '
    source "$1"; sudo_cmd=""
    log_info() { :; }; log_ok() { :; }; log_warn() { echo "WARN: $*"; }
    command() { [[ "${2:-}" == apt-get ]] && return 1; builtin command "$@"; }
    ensure_amd_host_vulkan
    echo "rc=$?"
' _ "$LIB_SRC" 2>&1)"
unset FAKE_DPKG
[[ "$no_apt_out" != *WARN* && "$no_apt_out" == *"rc=0"* ]] && ok "no apt-get but packages present → no warning" || bad "no apt-get but packages present → no warning ($no_apt_out)"

echo ""; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
