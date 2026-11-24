#!/usr/bin/env bash
# Tests for install-parser.sh's install_unit() and its GPU vendor branch. Run:
#   bash scripts/install-parser.unit.test.sh
#
# install_unit copies the unit template, daemon-reloads, enables it, and then
# checks what systemd actually reports: a finite MemoryMax always, and
# Delegate=yes only when the template itself delegates (dynamic allocation
# phase 2). Holding an older template to Delegate=yes would make a rollback or
# an older Parser release uninstallable with this installer.
#
# Same sandbox trick as install-parser.models.test.sh: install_unit is lifted
# out of the installer with sed, `systemctl` is a shim on PATH that records its
# calls and answers MemoryMax/Delegate from FAKE_MEMMAX/FAKE_DELEGATE, unit
# files live under mktemp and sudo is emptied. Nothing real is touched.
#
# The GPU branch (last section) is the inline copy of lib/parser-gpu-branch.sh:
# every function must match the lib character for character, and setup_venv must
# only reach the onnxruntime-openvino swap on intel and cpu. deploy-parser.test.sh
# covers the behaviour in depth; this checks the installer's own wiring, under
# the `set -e` the installer really runs with.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-parser.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_CALLS}"
if [[ "$1" == "show" ]]; then
  case "$*" in
    *"-p MemoryMax"*) echo "${FAKE_MEMMAX-12884901888}" ;;
    *"-p Delegate"*)  echo "${FAKE_DELEGATE-yes}" ;;
  esac
fi
exit 0
SHIM
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"
export FAKE_CALLS="$TMP/calls"

echo "install-parser.sh install_unit"

LIB="$TMP/lib.sh"
for f in unit_template_delegates install_unit; do
    sed -n "/^$f() {/,/^}/p" "$SCRIPT" >> "$LIB"
    grep -q "^$f() {" "$LIB" && ok "installer defines $f()" || bad "installer defines $f()"
done
# a `curl | bash` stack install fetches only a fixed list of sub-scripts, so
# the installer must not depend on lib/parser-unit.sh
grep -qE '^[[:space:]]*(source|\.)[[:space:]].*lib/parser-unit\.sh' "$SCRIPT" \
    && bad "installer does not source lib/parser-unit.sh" || ok "installer does not source lib/parser-unit.sh"

# the inline copy and lib/parser-unit.sh must agree on every template shape
mkdir -p "$TMP/shapes"
printf '[Service]\nMemoryMax=12G\n'                         > "$TMP/shapes/plain"
printf '[Service]\nDelegate=yes\nDelegateSubgroup=serve\n'  > "$TMP/shapes/yes"
printf '[Service]\nDelegate = true \n'                      > "$TMP/shapes/true-spaced"
printf '[Service]\nDelegate=memory pids\n'                  > "$TMP/shapes/list"
printf '[Service]\nDelegate=yes\nDelegate=no\n'             > "$TMP/shapes/reset"
printf '[Service]\nDelegate=yes\nDelegate=\n'               > "$TMP/shapes/reset-empty"
printf '[Service]\n# Delegate=yes\n; Delegate=yes\n'        > "$TMP/shapes/commented"
printf '[Service]\nDelegate=off\n'                          > "$TMP/shapes/off"
for shape in "$TMP"/shapes/* "$TMP/shapes/missing"; do
    a="$(bash -c 'source "$1"; parser_unit_template_delegates "$2" && echo y || echo n' _ "$HERE/lib/parser-unit.sh" "$shape")"
    b="$(bash -c 'source "$1"; unit_template_delegates "$2" && echo y || echo n' _ "$LIB" "$shape")"
    [[ "$a" == "$b" ]] && ok "lib and installer agree on $(basename "$shape") ($a)" \
        || bad "lib and installer agree on $(basename "$shape") (lib $a, installer $b)"
done

SRC_PLAIN="$TMP/plain.service"
SRC_DELEGATE="$TMP/delegate.service"
printf '[Service]\nMemoryMax=12G\n' > "$SRC_PLAIN"
printf '[Service]\nMemoryMax=12G\nDelegate=yes\nDelegateSubgroup=serve\n' > "$SRC_DELEGATE"

# run_install <template>: install_unit in a subshell (log_fail exits); prints rc
run_install() {
    : > "$FAKE_CALLS"
    (
        # shellcheck source=/dev/null
        source "$LIB"
        log_info() { :; }
        log_ok()   { :; }
        log_fail() { echo "FAILED: $*" >&2; exit 1; }
        sudo_cmd=""
        SERVICE_FILE="nimoos-parser.service"
        UNIT_SRC="$1"
        UNIT_DST="$TMP/installed/nimoos-parser.service"
        mkdir -p "$TMP/installed"
        install_unit
    ) >/dev/null 2>"$TMP/stderr"
    echo $?
}

unset FAKE_MEMMAX FAKE_DELEGATE
export FAKE_DELEGATE=yes
rc="$(run_install "$SRC_DELEGATE")"
[[ "$rc" -eq 0 ]] && ok "template Delegate=yes, systemd yes → installs" || bad "template Delegate=yes, systemd yes → installs (rc $rc)"

export FAKE_DELEGATE=no
rc="$(run_install "$SRC_DELEGATE")"
[[ "$rc" -ne 0 ]] && ok "template Delegate=yes, systemd no → log_fail" || bad "template Delegate=yes, systemd no → log_fail (rc $rc)"
grep -q 'systemd does not (Delegate=no)' "$TMP/stderr" \
    && ok "template Delegate=yes, systemd no → says why" || bad "template Delegate=yes, systemd no → says why"

export FAKE_DELEGATE=""
rc="$(run_install "$SRC_DELEGATE")"
[[ "$rc" -ne 0 ]] && ok "template Delegate=yes, systemd empty → log_fail" || bad "template Delegate=yes, systemd empty → log_fail (rc $rc)"

export FAKE_DELEGATE=no
rc="$(run_install "$SRC_PLAIN")"
[[ "$rc" -eq 0 ]] && ok "template without Delegate, systemd no → installs" || bad "template without Delegate, systemd no → installs (rc $rc)"
grep -q -- '-p Delegate' "$FAKE_CALLS" \
    && bad "template without Delegate → Delegate not queried" || ok "template without Delegate → Delegate not queried"

export FAKE_MEMMAX=infinity FAKE_DELEGATE=yes
rc="$(run_install "$SRC_PLAIN")"
[[ "$rc" -ne 0 ]] && ok "MemoryMax=infinity → log_fail (unchanged)" || bad "MemoryMax=infinity → log_fail (unchanged) (rc $rc)"
unset FAKE_MEMMAX

###############################################################################
echo ""
echo "install-parser.sh GPU branch"
###############################################################################
GPU_LIB="$HERE/lib/parser-gpu-branch.sh"
# Enumerated from the lib, so a function added there cannot be forgotten here.
GPU_FNS="$(sed -n 's/^\([a-zA-Z_][a-zA-Z_0-9]*\)() {$/\1/p' "$GPU_LIB" 2>/dev/null)"
for f in detect_parser_gpu_branch ensure_amd_runtime ensure_openvino_pins reconcile_parser_gpu_runtime; do
    [[ $'\n'"$GPU_FNS"$'\n' == *$'\n'"$f"$'\n'* ]] && ok "enumeration finds $f()" || bad "enumeration finds $f()"
done

# a `curl | bash` stack install fetches only a fixed list of sub-scripts, so the
# installer must not depend on the lib; the two copies must agree instead
grep -qE '^[[:space:]]*(source|\.)[[:space:]].*parser-gpu-branch\.sh' "$SCRIPT" \
    && bad "installer does not source lib/parser-gpu-branch.sh" || ok "installer does not source lib/parser-gpu-branch.sh"
for f in $GPU_FNS; do
    a="$(sed -n "/^$f() {/,/^}/p" "$GPU_LIB" 2>/dev/null)"
    b="$(sed -n "/^$f() {/,/^}/p" "$SCRIPT")"
    if [[ -n "$a" && "$a" == "$b" ]]; then ok "lib and installer agree on $f()"; else bad "lib and installer agree on $f()"; fi
done
for v in DEP_LLAMA_VULKAN_WHEEL DEP_LLAMA_VULKAN_SHA256; do
    a="$(sed -n "s/^$v=//p" "$GPU_LIB" 2>/dev/null)"
    b="$(sed -n "s/^readonly $v=//p" "$SCRIPT")"
    if [[ -n "$a" && "$a" == "$b" ]]; then ok "lib and installer agree on $v"; else bad "lib and installer agree on $v"; fi
done
# deploy-parser.sh does not load stack-fetch.sh, so the lib repeats its defaults
deps_base() {   # deps_base <file> [domain]
    env -u NIMO_DEPS_BASE -u NIMO_DOWNLOAD_DOMAIN ${2:+NIMO_DOWNLOAD_DOMAIN="$2"} \
        bash -c 'source "$1" >/dev/null 2>&1; echo "$NIMO_DEPS_BASE"' _ "$1"
}
a="$(deps_base "$GPU_LIB")"; b="$(deps_base "$HERE/lib/stack-fetch.sh")"
if [[ -n "$a" && "$a" == "$b" ]]; then ok "lib and stack-fetch.sh agree on the default NIMO_DEPS_BASE ($a)"; else bad "lib and stack-fetch.sh agree on the default NIMO_DEPS_BASE (lib '$a', stack-fetch '$b')"; fi
a="$(deps_base "$GPU_LIB" http://mirror.test/)"; b="$(deps_base "$HERE/lib/stack-fetch.sh" http://mirror.test/)"
if [[ "$a" == "http://mirror.test/deps" && "$a" == "$b" ]]; then ok "lib and stack-fetch.sh derive NIMO_DEPS_BASE from the domain alike"; else bad "lib and stack-fetch.sh derive NIMO_DEPS_BASE from the domain alike (lib '$a', stack-fetch '$b')"; fi

# the same table, run through both copies
for shape in "intel:0x8086" "intel:0x1002,0x8086" "amd:0x1002" "amd:0x1002,0x1002" "cpu:0x10de" "cpu:"; do
    want="${shape%%:*}"; ids="${shape#*:}"; root="$TMP/drm-$RANDOM"; n=0
    mkdir -p "$root"
    for id in ${ids//,/ }; do mkdir -p "$root/card$n/device"; echo "$id" > "$root/card$n/device/vendor"; n=$((n+1)); done
    a="$(bash -c 'source "$1" && detect_parser_gpu_branch "$2"' _ "$GPU_LIB" "$root" 2>/dev/null)"
    b="$(bash -c "$(sed -n '/^detect_parser_gpu_branch() {/,/^}/p' "$SCRIPT")"$'\n''detect_parser_gpu_branch "$1"' _ "$root" 2>/dev/null)"
    if [[ "$a" == "$want" && "$b" == "$want" ]]; then ok "both copies say $want for [$ids]"; else bad "both copies say $want for [$ids] (lib '$a', installer '$b')"; fi
done

# setup_venv wiring. The checksum is the real pin, which the fixture wheel never
# matches: that is the "sha mismatch" case, and a pass-through would be a bug.
GPU="$TMP/gpu"
mkdir -p "$GPU/venv/bin" "$GPU/models"
SETUP_LIB="$TMP/setup-lib.sh"
: > "$SETUP_LIB"
for f in $GPU_FNS use_prebuilt vlm_ir_present text_ov_present ensure_openvino_runtime setup_venv; do
    sed -n "/^$f() {/,/^}/p" "$SCRIPT" >> "$SETUP_LIB"
done
cat > "$GPU/requirements.txt" <<'REQ'
uvicorn>=0.30
onnxruntime-openvino==1.24.1
openvino==2026.4.0
openvino-genai==2026.4.0.0
openvino-tokenizers==2026.4.0.0
REQ
cat > "$GPU/venv/bin/pip" <<'SHIM'
#!/usr/bin/env bash
echo "pip $*" >> "${FAKE_CALLS}"
[[ -n "${FAKE_PIP_FAIL:-}" && "$*" == *"${FAKE_PIP_FAIL}"* ]] && exit 1
exit 0
SHIM
cat > "$GPU/venv/bin/python" <<'SHIM'
#!/usr/bin/env bash
code=""
while [[ $# -gt 0 ]]; do case "$1" in -c) code="$2"; shift 2;; *) shift;; esac; done
case "$code" in
  *onnxruntime_ep_webgpu*)     exit 1 ;;
  *llama_supports_gpu_offload*) exit 1 ;;
  *OpenVINOExecutionProvider*) exit 1 ;;
  *"'openvino-genai'"*)        echo 2026.4.0.0 ;;
  *"'openvino-tokenizers'"*)   echo 2026.4.0.0 ;;
  *"'openvino'"*)              echo 2026.4.0 ;;
esac
exit 0
SHIM
cat > "$TMP/bin/apt-get" <<'SHIM'
#!/usr/bin/env bash
echo "apt-get $*" >> "${FAKE_CALLS}"
exit 0
SHIM
cat > "$TMP/bin/dpkg-query" <<'SHIM'
#!/usr/bin/env bash
[[ "${FAKE_DPKG_ALL:-}" == 1 ]] || exit 1
echo -n "ii "
SHIM
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "${FAKE_CALLS}"
out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
echo "not the pinned wheel" > "$out"
SHIM
cat > "$TMP/bin/ldconfig" <<'SHIM'
#!/usr/bin/env bash
for lib in ${FAKE_LIBS-libgomp.so.1 libvulkan.so.1}; do
    printf '\t%s (libc6,x86-64) => /lib/x86_64-linux-gnu/%s\n' "$lib" "$lib"
done
SHIM
cat > "$TMP/bin/getconf" <<'SHIM'
#!/usr/bin/env bash
echo "glibc 2.41"
SHIM
chmod +x "$GPU/venv/bin/"* "$TMP/bin/"*

# run_setup <vendor id or empty>: setup_venv under set -e, as the installer runs
# it; prints rc. The prebuilt path is taken, so the only pip calls are the branch's.
run_setup() {
    : > "$FAKE_CALLS"
    local root="$TMP/drm-setup"
    rm -rf "$root"; mkdir -p "$root"
    if [[ -n "$1" ]]; then mkdir -p "$root/card0/device"; echo "$1" > "$root/card0/device/vendor"; fi
    (
        set -e
        # shellcheck source=/dev/null
        source "$SETUP_LIB"
        log_info() { :; }; log_ok() { :; }
        log_warn() { echo "WARN: $*" >> "$TMP/gpu-warn"; }
        fetch_prebuilt_venv() { :; }
        sudo_cmd=""
        INSTALL_DIR="$GPU"; VENV_DIR="$GPU/venv"; VLM_MODELS_DIR="$GPU/models"
        PARSER_PY="/nonexistent/python3.11"
        NIMO_DEPS_BASE="http://mirror.test/deps"
        DEP_LLAMA_VULKAN_WHEEL="parser/llama-cpp-python-0.3.34-vulkan/llama_cpp_python-0.3.34-py3-none-linux_x86_64.whl"
        DEP_LLAMA_VULKAN_SHA256="541d1688d58e6047a3154fa140829a72c238e054b3c3812b44ef16f9a07b7fbb"
        NIMO_DRM_ROOT="$root"
        TMPDIR="$TMP"
        setup_venv
    ) >/dev/null 2>&1
    echo $?
}
gpu_called() { grep -qF -- "$1" "$FAKE_CALLS"; }
SWAP="install --force-reinstall --no-deps onnxruntime-openvino==1.24.1"
RESTORE="install --force-reinstall --no-deps --no-index --find-links="

for branch in "intel:0x8086" "cpu:"; do
    name="${branch%%:*}"; id="${branch#*:}"
    rc="$(run_setup "$id")"
    [[ "$rc" -eq 0 ]] && ok "$name: setup_venv succeeds" || bad "$name: setup_venv succeeds (rc $rc)"
    gpu_called "$SWAP" && ok "$name: runs the onnxruntime-openvino swap with the exact pin" || bad "$name: runs the onnxruntime-openvino swap with the exact pin"
    gpu_called "pip download" && bad "$name: no download" || ok "$name: no download"
    gpu_called "pip uninstall" && bad "$name: no uninstall" || ok "$name: no uninstall"
    gpu_called "apt-get" && bad "$name: no Mesa" || ok "$name: no Mesa"
    gpu_called "curl" && bad "$name: no Vulkan wheel" || ok "$name: no Vulkan wheel"
done

rc="$(run_setup 0x1002)"
[[ "$rc" -eq 0 ]] && ok "amd: setup_venv succeeds" || bad "amd: setup_venv succeeds (rc $rc)"
gpu_called "$SWAP" && bad "amd: no onnxruntime-openvino swap" || ok "amd: no onnxruntime-openvino swap"
gpu_called "$RESTORE" && bad "amd: nothing to restore" || ok "amd: nothing to restore"
gpu_called "apt-get install -y --no-upgrade mesa-vulkan-drivers libvulkan1 libgomp1" && ok "amd: installs Mesa, upgrading nothing" || bad "amd: installs Mesa, upgrading nothing"
dl="$(grep -n '^pip download' "$FAKE_CALLS" | cut -d: -f1)"
un="$(grep -n '^pip uninstall -y onnxruntime-openvino onnxruntime$' "$FAKE_CALLS" | cut -d: -f1)"
in="$(grep -n -- '--no-index --find-links=.* onnxruntime==1.27.0 onnxruntime-ep-webgpu==0.5.0$' "$FAKE_CALLS" | cut -d: -f1)"
[[ -n "$dl" && -n "$un" && -n "$in" && "$dl" -lt "$un" && "$un" -lt "$in" ]] \
    && ok "amd: download, then uninstall both, then install from the directory" \
    || bad "amd: download, then uninstall both, then install from the directory ($dl/$un/$in)"
gpu_called "curl" && ok "amd: fetches the Vulkan wheel" || bad "amd: fetches the Vulkan wheel"
grep -q '^pip .*llama_cpp_python' "$FAKE_CALLS" \
    && bad "amd: a wheel that fails its checksum is not installed" || ok "amd: a wheel that fails its checksum is not installed"

export FAKE_DPKG_ALL=1
rc="$(run_setup 0x1002)"
unset FAKE_DPKG_ALL
[[ "$rc" -eq 0 ]] && ok "amd: packages present → setup_venv succeeds" || bad "amd: packages present → setup_venv succeeds (rc $rc)"
gpu_called "apt-get" && bad "amd: packages present → no apt call" || ok "amd: packages present → no apt call"

export FAKE_PIP_FAIL="download"
rc="$(run_setup 0x1002)"
unset FAKE_PIP_FAIL
[[ "$rc" -eq 0 ]] && ok "amd: download failure does not fail the install" || bad "amd: download failure does not fail the install (rc $rc)"
gpu_called "pip uninstall" && bad "amd: download failure touches nothing" || ok "amd: download failure touches nothing"
grep -- 'could not download' "$TMP/gpu-warn" | grep -qF 'onnxruntime-openvino==1.24.1' \
    && ok "amd: download failure warning names the restore pin too" || bad "amd: download failure warning names the restore pin too"

export FAKE_PIP_FAIL="install --no-deps --no-index"
rc="$(run_setup 0x1002)"
unset FAKE_PIP_FAIL
[[ "$rc" -eq 0 ]] && ok "amd: install failure does not fail the install" || bad "amd: install failure does not fail the install (rc $rc)"
grep -qF -- "$RESTORE" "$FAKE_CALLS" && grep -q "$RESTORE.* onnxruntime-openvino==1.24.1\$" "$FAKE_CALLS" \
    && ok "amd: install failure restores the pin from the download directory" || bad "amd: install failure restores the pin from the download directory"

export FAKE_LIBS="libgomp.so.1"
rc="$(run_setup 0x1002)"
unset FAKE_LIBS
[[ "$rc" -eq 0 ]] && ok "amd: missing libvulkan does not fail the install" || bad "amd: missing libvulkan does not fail the install (rc $rc)"
gpu_called "curl" && bad "amd: missing libvulkan keeps the CPU wheel" || ok "amd: missing libvulkan keeps the CPU wheel"

export FAKE_PIP_FAIL="onnxruntime-openvino"
rc="$(run_setup 0x8086)"
unset FAKE_PIP_FAIL
[[ "$rc" -eq 0 ]] && ok "intel: swap failure does not fail the install" || bad "intel: swap failure does not fail the install (rc $rc)"

# An older Parser pins no exact versions and has no GGML_DISABLE_VULKAN, so on AMD
# it stays on the runtime it was written for.
cp "$GPU/requirements.txt" "$TMP/requirements.exact"
for shape in "ranges:onnxruntime-openvino>=1.24" "absent:uvicorn>=0.30"; do
    name="${shape%%:*}"
    printf '%s\n' "uvicorn>=0.30" "${shape#*:}" "openvino>=2026.0" > "$GPU/requirements.txt"
    rc="$(run_setup 0x1002)"
    [[ "$rc" -eq 0 ]] && ok "amd, old requirements ($name): setup_venv succeeds" || bad "amd, old requirements ($name): setup_venv succeeds (rc $rc)"
    gpu_called "pip download" && bad "amd, old requirements ($name): ONNX Runtime not replaced" || ok "amd, old requirements ($name): ONNX Runtime not replaced"
    gpu_called "pip uninstall" && bad "amd, old requirements ($name): nothing uninstalled" || ok "amd, old requirements ($name): nothing uninstalled"
    gpu_called "curl" && bad "amd, old requirements ($name): wheel not replaced" || ok "amd, old requirements ($name): wheel not replaced"
    gpu_called "apt-get" && bad "amd, old requirements ($name): no Mesa" || ok "amd, old requirements ($name): no Mesa"
    grep -qE '^pip install --force-reinstall --no-deps onnxruntime-openvino' "$FAKE_CALLS" \
        && ok "amd, old requirements ($name): takes the intel and cpu path" || bad "amd, old requirements ($name): takes the intel and cpu path"
done
cp "$TMP/requirements.exact" "$GPU/requirements.txt"
rc="$(run_setup 0x1002)"
[[ "$rc" -eq 0 ]] && grep -q '^pip download' "$FAKE_CALLS" && gpu_called "curl" \
    && ok "amd, exact requirements: replaces ONNX Runtime and the wheel" || bad "amd, exact requirements: replaces ONNX Runtime and the wheel"

echo ""; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
