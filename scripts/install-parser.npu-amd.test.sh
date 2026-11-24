#!/usr/bin/env bash
# Tests for install-parser.sh's AMD NPU package (ensure_amd_npu_package) and its
# copy in lib/parser-npu-amd.sh. Run:
#   bash scripts/install-parser.npu-amd.test.sh
#
# The AMD NPU package (FastFlowLM 1.0.12 + Whisper-V3-Turbo-NPU2 + a private
# XRT, see package-parser-npu-amd.sh) goes to /opt/nimoos-parser/flm only on
# machines with the AMD NPU 1022:17f0. Rules under test:
#   - skipped when NIMO_PARSER_NPU_AMD=0, on a non-x86_64 host, or when no PCI
#     device is 1022:17f0; skipped when the marker already reads the pin;
#   - the host needs libcurl.so.4, libedit.so.2, libgomp.so.1 and glibc >= 2.39;
#     a missing library is installed with apt-get --no-upgrade (only those three
#     packages), and a host that still lacks them, or has an older glibc, is
#     skipped with a warning;
#   - the download is checked for size and sha256, unpacked into a staging
#     directory, checked file by file against nimoos-flm.json (files, links,
#     nothing unlisted) and model-root/SHA256SUMS, chowned root:root, dirs 0755,
#     files 0644, runtime/bin/flm 0755, then swapped in with two renames; the
#     marker is written last;
#   - every failure only warns and returns 0, leaves the installed tree as it
#     was, and leaves no staging directory or download behind;
#   - nothing is written outside INSTALL_DIR (no /opt/xilinx, no apt FLM);
#   - the inline copy in install-parser.sh and lib/parser-npu-amd.sh agree
#     character for character, and the installer calls it between
#     fetch_asr_venv and install_conf.
#
# Sandbox: the functions run with INSTALL_DIR under mktemp, sudo emptied, the
# package served by the real curl from a file:// URL (through a logging shim),
# and uname, ldconfig, getconf, apt-get and chown replaced by shims. The PCI
# tree is a fake directory (NIMO_PCI_ROOT). Nothing real is touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-parser.sh"
NPU_LIB="$HERE/lib/parser-npu-amd.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for t in zstd python3 curl sha256sum; do
    command -v "$t" >/dev/null || { echo "  skip — $t not installed"; exit 0; }
done
REAL_CURL="$(command -v curl)"

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

###############################################################################
echo "install-parser.sh pins and wiring"
###############################################################################
check "lib exists" "[[ -f '$NPU_LIB' ]]"
check "PARSER_NPU_AMD_VERSION is 1.0.12-2" "grep -qx 'readonly PARSER_NPU_AMD_VERSION=\"1.0.12-2\"' '$SCRIPT'"
check "PARSER_NPU_AMD_SHA256 is a sha256" "grep -qE '^readonly PARSER_NPU_AMD_SHA256=\"[0-9a-f]{64}\"\$' '$SCRIPT'"
check "PARSER_NPU_AMD_SIZE_BYTES is pinned" "grep -qE '^readonly PARSER_NPU_AMD_SIZE_BYTES=\"[0-9]+\"\$' '$SCRIPT'"
check "PARSER_NPU_AMD_UNPACKED_BYTES is pinned" "grep -qE '^readonly PARSER_NPU_AMD_UNPACKED_BYTES=\"[0-9]+\"\$' '$SCRIPT'"
check "the pins say the version moves with core's AMD spec" "grep -q 'core.s AMD NPU spec (its RuntimeVersion and acceptance record)' '$SCRIPT' && grep -q 'core.s AMD NPU spec (its RuntimeVersion and acceptance record)' '$NPU_LIB'"
check "DEP_NPU_AMD_BUNDLE names the package" \
    "grep -qx 'readonly DEP_NPU_AMD_BUNDLE=\"parser/nimoos-parser-npu-amd-\${PARSER_NPU_AMD_VERSION}.tar.zst\"' '$SCRIPT'"
check "NPU_AMD_DIR is INSTALL_DIR/flm" "grep -qx 'readonly NPU_AMD_DIR=\"\${INSTALL_DIR}/flm\"' '$SCRIPT'"
asr="$(grep -n '^fetch_asr_venv$' "$SCRIPT" | cut -d: -f1)"
npu="$(grep -n '^ensure_amd_npu_package || true$' "$SCRIPT" | cut -d: -f1)"
conf="$(grep -n '^install_conf$' "$SCRIPT" | cut -d: -f1)"
check "main flow runs ensure_amd_npu_package || true between fetch_asr_venv and install_conf" \
    "[[ -n '$asr' && -n '$npu' && -n '$conf' && $asr -lt ${npu:-0} && ${npu:-0} -lt $conf ]]"
check "installer does not source lib/parser-npu-amd.sh" \
    "! grep -qE '^[[:space:]]*(source|\\.)[[:space:]].*parser-npu-amd\\.sh' '$SCRIPT'"

# Enumerated from the lib, so a function added there cannot be forgotten here.
NPU_FNS="$(sed -n 's/^\([a-zA-Z_][a-zA-Z_0-9]*\)() {$/\1/p' "$NPU_LIB" 2>/dev/null)"
for f in dl_tmp ensure_amd_npu_package; do
    [[ $'\n'"$NPU_FNS"$'\n' == *$'\n'"$f"$'\n'* ]] && ok "enumeration finds $f()" || bad "enumeration finds $f()"
done
for f in $NPU_FNS; do
    a="$(sed -n "/^$f() {/,/^}/p" "$NPU_LIB")"
    b="$(sed -n "/^$f() {/,/^}/p" "$SCRIPT")"
    if [[ -n "$a" && "$a" == "$b" ]]; then ok "lib and installer agree on $f()"; else bad "lib and installer agree on $f()"; fi
done
for v in PARSER_NPU_AMD_VERSION PARSER_NPU_AMD_SHA256 PARSER_NPU_AMD_SIZE_BYTES PARSER_NPU_AMD_UNPACKED_BYTES DEP_NPU_AMD_BUNDLE NPU_AMD_DIR; do
    a="$(sed -n "s/^$v=//p" "$NPU_LIB" 2>/dev/null)"
    b="$(sed -n "s/^readonly $v=//p" "$SCRIPT")"
    if [[ -n "$a" && "$a" == "$b" ]]; then ok "lib and installer agree on $v"; else bad "lib and installer agree on $v"; fi
done
deps_base() {   # deps_base <file> [domain]
    env -u NIMO_DEPS_BASE -u NIMO_DOWNLOAD_DOMAIN ${2:+NIMO_DOWNLOAD_DOMAIN="$2"} INSTALL_DIR=/x \
        bash -c 'source "$1" >/dev/null 2>&1; echo "$NIMO_DEPS_BASE"' _ "$1"
}
a="$(deps_base "$NPU_LIB")"; b="$(deps_base "$HERE/lib/stack-fetch.sh")"
check "lib and stack-fetch.sh agree on the default NIMO_DEPS_BASE" "[[ -n '$a' && '$a' == '$b' ]]"
a="$(deps_base "$NPU_LIB" http://mirror.test/)"
check "lib derives NIMO_DEPS_BASE from the domain" "[[ '$a' == http://mirror.test/deps ]]"
body="$(sed -n '/^ensure_amd_npu_package() {/,/^}/p' "$SCRIPT"; for f in $NPU_FNS; do sed -n "/^$f() {/,/^}/p" "$NPU_LIB"; done)"
check "nothing goes to /opt/xilinx" "! grep -qi 'xilinx' <<< \"\$body\""
check "FLM itself is never installed with apt" "! grep -qiE 'apt-get[^|]*(fastflowlm|libxrt)' <<< \"\$body\""
apt_lines="$(grep 'apt-get install' <<< "$body")"
if grep -qF 'local -a pkgs=(libcurl4t64 libedit2 libgomp1)' <<< "$body" && [[ -n "$apt_lines" ]] \
    && ! grep -vqF -- 'apt-get install -y --no-upgrade "${pkgs[@]}"' <<< "$apt_lines"; then
    ok "apt only ever gets libcurl4t64 libedit2 libgomp1, upgrading nothing"
else
    bad "apt only ever gets libcurl4t64 libedit2 libgomp1, upgrading nothing"
fi

###############################################################################
# Sandbox
###############################################################################
OPT="$TMP/opt"
DEPS="$TMP/deps"
DL="$TMP/dl"
PCI="$TMP/pci"
STATE="$TMP/state"
export CALLS="$TMP/calls" STATE REAL_CURL
mkdir -p "$TMP/bin" "$DEPS/parser" "$DL" "$STATE"

cat > "$TMP/bin/uname" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == -m ]] && { echo "${FAKE_ARCH:-x86_64}"; exit 0; }
exec /usr/bin/uname "$@"
SHIM
cat > "$TMP/bin/ldconfig" <<'SHIM'
#!/usr/bin/env bash
echo "ldconfig $*" >> "$CALLS"
libs="${FAKE_LIBS-libcurl.so.4 libedit.so.2 libgomp.so.1}"
[[ -f "$STATE/apt-fixed" ]] && libs="libcurl.so.4 libedit.so.2 libgomp.so.1"
echo "$(wc -w <<< "$libs") libs found in cache"
for lib in $libs; do printf '\t%s (libc6,x86-64) => /lib/x86_64-linux-gnu/%s\n' "$lib" "$lib"; done
for lib in ${FAKE_LIBS32-}; do printf '\t%s (libc6) => /lib/i386-linux-gnu/%s\n' "$lib" "$lib"; done
SHIM
cat > "$TMP/bin/getconf" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == GNU_LIBC_VERSION ]] || exit 1
echo "glibc ${FAKE_GLIBC:-2.41}"
SHIM
cat > "$TMP/bin/apt-get" <<'SHIM'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CALLS"
[[ -n "${FAKE_APT_FAIL:-}" ]] && exit 100
[[ "$1" == install && -n "${FAKE_APT_FIXES:-}" ]] && touch "$STATE/apt-fixed"
exit 0
SHIM
# The installer runs as root and expects root-owned files; here they belong to
# the test user, so `find -user root` / `-group root` ask about that user.
cat > "$TMP/bin/find" <<'SHIM'
#!/usr/bin/env bash
args=() prev=""
for a in "$@"; do
    if [[ "$a" == root && "$prev" == -user ]]; then args+=("$(id -un)")
    elif [[ "$a" == root && "$prev" == -group ]]; then args+=("$(id -gn)")
    else args+=("$a"); fi
    prev="$a"
done
exec /usr/bin/find "${args[@]}"
SHIM
cat > "$TMP/bin/chown" <<'SHIM'
#!/usr/bin/env bash
echo "chown $*" >> "$CALLS"
exit 0
SHIM
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
[[ -n "${FAKE_CURL_FAIL:-}" ]] && exit 22
exec "$REAL_CURL" "$@"
SHIM
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

# pci <vendor:device>...: a fake /sys/bus/pci/devices
pci() {
    rm -rf "$PCI"; mkdir -p "$PCI"
    local n=0 pair
    for pair in "$@"; do
        mkdir -p "$PCI/0000:0$n:00.0"
        echo "0x${pair%%:*}" > "$PCI/0000:0$n:00.0/vendor"
        echo "0x${pair#*:}"  > "$PCI/0000:0$n:00.0/device"
        n=$((n+1))
    done
}

# make_pkg <name> [corruption]: a small package laid out like the real one,
# with a manifest and SHA256SUMS that describe it (unless corrupted).
make_pkg() {
    local name="$1" how="${2:-}" d="$TMP/pkgsrc-$1"
    rm -rf "$d"
    mkdir -p "$d/runtime/bin" "$d/runtime/lib" "$d/runtime/share/flm/xclbins/Whisper-V3-Turbo-NPU2" \
             "$d/xrt/lib" "$d/model-root/models/Whisper-V3-Turbo-NPU2"
    printf '#!/bin/sh\necho flm\n' > "$d/runtime/bin/flm"
    echo whisper > "$d/runtime/lib/libwhisper_npu.so"
    echo '{}' > "$d/runtime/share/flm/model_list.json"
    echo '{}' > "$d/runtime/share/flm/model_info.json"
    local x
    for x in decoder_mv encoder_attn encoder_dequant encoder_mm whisper_head; do
        echo "$x" > "$d/runtime/share/flm/xclbins/Whisper-V3-Turbo-NPU2/$x.xclbin"
    done
    for x in libxrt_coreutil.so.2.25.37 libxrt_core.so.2.25.37 libxrt_driver_xdna.so.2.25.260102.56.release libboost_program_options.so.1.83.0; do
        echo "$x" > "$d/xrt/lib/$x"
    done
    ln -s libxrt_core.so.2.25.37 "$d/xrt/lib/libxrt_core.so.2"
    ln -s libxrt_core.so.2 "$d/xrt/lib/libxrt_core.so"
    for x in config.json model.q4nx tokenizer.json tokenizer_config.json; do
        echo "$x" > "$d/model-root/models/Whisper-V3-Turbo-NPU2/$x"
    done
    # The old 1.0.12-1 layout: a licenses/ directory the installer no longer accepts.
    [[ "$how" == licenses ]] && { mkdir -p "$d/licenses"; echo "sources" > "$d/licenses/SOURCES.md"; }
    # Odd modes on purpose: the installer has to normalise them.
    chmod 0700 "$d/runtime/bin/flm"; chmod 0600 "$d/runtime/lib/libwhisper_npu.so"; chmod 0775 "$d/xrt"
    # flm as a link to a file outside the package: chmod must never follow it.
    [[ "$how" == flm-symlink ]] && { rm "$d/runtime/bin/flm"; ln -s "$OUTSIDE" "$d/runtime/bin/flm"; }
    python3 -I - "$d" "$how" <<'PY'
import hashlib, json, os, stat, sys
root, how = sys.argv[1], sys.argv[2]
files, links = {}, {}
for top in ("runtime", "xrt"):
    for dpath, _, names in os.walk(os.path.join(root, top)):
        for n in names:
            p = os.path.join(dpath, n)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                links[rel] = os.readlink(p)
            else:
                files[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
if how == "lying-manifest":
    files["runtime/lib/libwhisper_npu.so"] = "0" * 64
if how == "bad-link":
    links["xrt/lib/libxrt_core.so"] = "libxrt_core.so.9"
m = {"files": files, "links": links, "runtime_id": "amd-flm", "schema_version": 1, "version": "1.0.12"}
open(os.path.join(root, "nimoos-flm.json"), "w").write(json.dumps(m, sort_keys=True, separators=(",", ":")))
model = os.path.join(root, "model-root")
rows = []
for n in sorted(os.listdir(os.path.join(model, "models/Whisper-V3-Turbo-NPU2"))):
    rel = f"models/Whisper-V3-Turbo-NPU2/{n}"
    digest = hashlib.sha256(open(os.path.join(model, rel), "rb").read()).hexdigest()
    if how == "bad-sums" and n == "model.q4nx":
        digest = "f" * 64
    rows.append(f"{digest}  {rel}\n")
open(os.path.join(model, "SHA256SUMS"), "w").write("".join(rows))
if how == "unlisted":
    open(os.path.join(root, "runtime/lib/libsneaky.so"), "w").write("x")
PY
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --zstd -cf "$DEPS/parser/$name.tar.zst" \
        -C "$d" nimoos-flm.json model-root runtime xrt $([[ -d "$d/licenses" ]] && echo licenses)
}

PKG_VERSION="1.0.12-2"
BUNDLE="nimoos-parser-npu-amd-$PKG_VERSION"
make_pkg "$BUNDLE"
cp "$DEPS/parser/$BUNDLE.tar.zst" "$TMP/good.tar.zst"
GOOD_SHA="$(sha "$TMP/good.tar.zst")"; GOOD_SIZE="$(stat -c%s "$TMP/good.tar.zst")"
GOOD_UNPACKED="$(tar --zstd -tvf "$TMP/good.tar.zst" | awk '$1 ~ /^-/ { s += $3 } END { print s + 0 }')"
NEED_KB=$(( (GOOD_UNPACKED + 1023) / 1024 * 11 / 10 ))
SIZE_KB=$(( (GOOD_SIZE + 1023) / 1024 ))
OUTSIDE="$TMP/outside-file"
echo "not part of the package" > "$OUTSIDE"; chmod 0600 "$OUTSIDE"
for how in lying-manifest bad-sums unlisted bad-link flm-symlink licenses; do make_pkg "$how" "$how"; done

# The installer's copies of every lib function, as the installer runs them.
LIB="$TMP/lib.sh"
: > "$LIB"
for f in $NPU_FNS; do sed -n "/^$f() {/,/^}/p" "$SCRIPT" >> "$LIB"; done

# serve <tarball>: what the mirror hands out as the pinned package name
serve() { cp "$1" "$DEPS/parser/$BUNDLE.tar.zst"; }

# run_ensure <lib> [VAR=value...]: one call, as the installer makes it but
# under set -euo pipefail, so a stray failing command shows up as rc != 0.
run_ensure() {
    local lib="$1"; shift
    : > "$CALLS"; rm -f "$STATE/apt-fixed"
    (
        set -euo pipefail
        INSTALL_DIR="$OPT"
        # shellcheck source=/dev/null
        source "$lib"
        log_info() { echo "INFO: $*"; }; log_ok() { echo "OK: $*"; }
        log_warn() { echo "WARN: $*"; }
        sudo_cmd=""
        NPU_AMD_DIR="$OPT/flm"
        PARSER_NPU_AMD_VERSION="$PKG_VERSION"
        PARSER_NPU_AMD_SHA256="$GOOD_SHA"
        PARSER_NPU_AMD_SIZE_BYTES="$GOOD_SIZE"
        PARSER_NPU_AMD_UNPACKED_BYTES="$GOOD_UNPACKED"
        DEP_NPU_AMD_BUNDLE="parser/nimoos-parser-npu-amd-${PARSER_NPU_AMD_VERSION}.tar.zst"
        NIMO_DEPS_BASE="file://$DEPS"
        NIMO_DL_TMPDIR="$DL"
        NIMO_PCI_ROOT="$PCI"
        local kv; for kv in "$@"; do export "${kv?}"; done
        # FAKE_INSTALL_AVAIL_KB: free space reported for INSTALL_DIR only.
        if [[ -n "${FAKE_INSTALL_AVAIL_KB:-}" ]]; then
            eval "real_$(declare -f avail_kb_of)"
            avail_kb_of() { if [[ "$1" == "$INSTALL_DIR" ]]; then echo "$FAKE_INSTALL_AVAIL_KB"; else real_avail_kb_of "$1"; fi; }
        fi
        # FAKE_DIFFERENT_FS: the download directory and INSTALL_DIR are on
        # different filesystems (here they really share one).
        if [[ -n "${FAKE_DIFFERENT_FS:-}" ]]; then amd_npu_dev_of() { echo "fake:$1"; }; fi
        # FAKE_NO_PYTHON3: python3 is not installed.
        if [[ -n "${FAKE_NO_PYTHON3:-}" ]]; then
            command() { if [[ "$1" == -v && "$2" == python3 ]]; then return 1; fi; builtin command "$@"; }
        fi
        ensure_amd_npu_package
    ) > "$TMP/out" 2>&1
    rc=$?
}
called()   { grep -qF -- "$1" "$CALLS"; }
downloaded() { grep -q "^curl " "$CALLS"; }
warned()   { grep -q '^WARN' "$TMP/out"; }
leftovers() { find "$OPT" -maxdepth 1 \( -name '.flm-staging-*' -o -name '.flm-old-*' \) | grep -q .; }
dl_empty() { [[ -z "$(ls -A "$DL")" ]]; }
tree_sum() { (cd "$1" 2>/dev/null && find . -printf '%p %y %m %l\n' | sort && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum | cut -d' ' -f1; }
fresh() { rm -rf "$OPT" "$DL"; mkdir -p "$OPT" "$DL"; serve "$TMP/good.tar.zst"; pci "$@"; }
# old_tree: an installed older package, to prove a failure leaves it alone
old_tree() {
    mkdir -p "$OPT/flm/runtime/bin"
    echo old > "$OPT/flm/runtime/bin/flm"; echo old-only > "$OPT/flm/old-only"
    echo "1.0.11-1" > "$OPT/flm/.package-version"
}

AMD_NPU="1022:17f0"

###############################################################################
echo ""
echo "skips"
###############################################################################
fresh 8086:7d55 1022:1502 1002:150e
run_ensure "$LIB"
check "no 1022:17f0 → returns 0" "[[ $rc -eq 0 ]]"
check "no 1022:17f0 → no download" "! downloaded"
check "no 1022:17f0 → nothing installed" "[[ ! -e '$OPT/flm' ]]"
check "no 1022:17f0 → says so" "grep -q '17f0' '$TMP/out'"

fresh 1022:17f1 1023:17f0
run_ensure "$LIB"
check "vendor and device must match on one device → no download" "! downloaded"

fresh "$AMD_NPU"
run_ensure "$LIB" NIMO_PARSER_NPU_AMD=0
check "NIMO_PARSER_NPU_AMD=0 → returns 0" "[[ $rc -eq 0 ]]"
check "NIMO_PARSER_NPU_AMD=0 → no download" "! downloaded && [[ ! -e '$OPT/flm' ]]"

fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_ARCH=aarch64
check "not x86_64 → returns 0" "[[ $rc -eq 0 ]]"
check "not x86_64 → no download" "! downloaded && [[ ! -e '$OPT/flm' ]]"

###############################################################################
echo ""
echo "a fresh install"
###############################################################################
fresh 8086:7d55 "$AMD_NPU"
run_ensure "$LIB"
check "returns 0" "[[ $rc -eq 0 ]]"
[[ $rc -eq 0 ]] || sed 's/^/      /' "$TMP/out"
check "downloads the pinned name from NIMO_DEPS_BASE" "called 'file://$DEPS/parser/$BUNDLE.tar.zst'"
check "no warning" "! warned"
F="$OPT/flm"
check "lands in INSTALL_DIR/flm" "[[ -f '$F/nimoos-flm.json' && -f '$F/runtime/bin/flm' && -f '$F/model-root/models/Whisper-V3-Turbo-NPU2/model.q4nx' ]]"
check "keeps the XRT links" "[[ -L '$F/xrt/lib/libxrt_core.so' && \$(readlink '$F/xrt/lib/libxrt_core.so.2') == libxrt_core.so.2.25.37 ]]"
check "marker reads the pinned version" "[[ \$(cat '$F/.package-version') == '$PKG_VERSION' ]]"
check "marker is 0644" "[[ \$(stat -c %a '$F/.package-version') == 644 ]]"
check "chowns the staging tree to root:root before the swap" "grep -qE '^chown -R root:root $OPT/\\.flm-staging-[0-9]+\$' '$CALLS'"
check "every directory is 0755" "[[ -z \$(find '$F' -type d ! -perm 0755) ]]"
check "runtime/bin/flm is 0755" "[[ \$(stat -c %a '$F/runtime/bin/flm') == 755 ]]"
check "every other file is 0644" "[[ -z \$(find '$F' -type f ! -path '$F/runtime/bin/flm' ! -perm 0644) ]]"
check "no staging or old directory left" "! leftovers"
check "download removed" "dl_empty"
check "no apt call when the libraries are there" "! called apt-get"
check "the download is bounded in time" "grep -q '^curl .*--max-time 1800 ' '$CALLS'"
FLM_RUNTIME="${PARSER_FLM_RUNTIME:-$HERE/../../DEV-NimoOS-Parser/parser/flm_runtime.py}"
if [[ -f "$FLM_RUNTIME" ]] && grep -q '^def load_identity' "$FLM_RUNTIME"; then
    out="$(python3 -I - "$FLM_RUNTIME" "$F" <<'PY' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("flm_runtime", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.load_identity(sys.argv[2], trusted_uid=os.getuid()).version)
PY
)"
    check "Parser flm_runtime.load_identity accepts the installed tree" "[[ '$out' == 1.0.12 ]]"
    [[ "$out" == 1.0.12 ]] || echo "      $out"
else
    echo "  skip — no Parser flm_runtime.py (set PARSER_FLM_RUNTIME to run its validator too)"
fi

# ctimes <dir>: the full ctime of every entry, to prove nothing was touched
ctimes() { (cd "$1" && /usr/bin/find . -exec stat -c '%z %n' {} + | sort); }
: > "$CALLS"
ct_before="$(ctimes "$OPT/flm")"
run_ensure "$LIB"
check "marker at the pin → returns 0" "[[ $rc -eq 0 ]]"
check "marker at the pin → no download" "! downloaded"
check "marker at the pin → the installed tree was checked" "grep -q 'checking it' '$TMP/out' && ! grep -q 'check failed' '$TMP/out'"
check "marker at the pin, modes right → no chown or chmod, no ctime moves" \
    "! called chown && ! grep -q 'resetting the owner' '$TMP/out' && [[ \"\$(ctimes '$OPT/flm')\" == \"\$ct_before\" ]]"

cp "$OPT/flm/runtime/lib/libwhisper_npu.so" "$TMP/whisper.orig"
echo damaged >> "$OPT/flm/runtime/lib/libwhisper_npu.so"
run_ensure "$LIB"
check "marker at the pin, a file damaged → returns 0" "[[ $rc -eq 0 ]]"
check "marker at the pin, a file damaged → says so and installs again" \
    "grep -q 'does not match its manifest' '$TMP/out' && downloaded && cmp -s '$OPT/flm/runtime/lib/libwhisper_npu.so' '$TMP/whisper.orig' && [[ \$(cat '$OPT/flm/.package-version') == '$PKG_VERSION' ]] && ! leftovers"
run_ensure "$LIB"
check "after the repair the marker is trusted again → no download" "[[ $rc -eq 0 ]] && ! downloaded"

chmod g+w "$OPT/flm/runtime/bin/flm" "$OPT/flm/model-root/SHA256SUMS" "$OPT/flm/xrt/lib"
run_ensure "$LIB"
check "content intact, modes loosened → returns 0 without a download" "[[ $rc -eq 0 ]] && ! downloaded"
check "content intact, modes loosened → owner and modes are set again" \
    "called 'chown -R root:root $OPT/flm' && [[ \$(stat -c %a '$OPT/flm/runtime/bin/flm') == 755 && \$(stat -c %a '$OPT/flm/model-root/SHA256SUMS') == 644 && \$(stat -c %a '$OPT/flm/xrt/lib') == 755 ]]"
ct_before="$(ctimes "$OPT/flm")"
run_ensure "$LIB"
check "after the repair a rerun changes nothing (no chown, no ctime moves)" \
    "[[ $rc -eq 0 ]] && ! downloaded && ! called chown && [[ \"\$(ctimes '$OPT/flm')\" == \"\$ct_before\" ]]"
for drift in "flm-0700:chmod 0700 $OPT/flm/runtime/bin/flm" "setgid-dir:chmod g+s $OPT/flm/runtime/lib" "dir-0700:chmod 0700 $OPT/flm/model-root"; do
    eval "${drift#*:}"
    run_ensure "$LIB"
    check "drift (${drift%%:*}) → repaired without a download" \
        "[[ $rc -eq 0 ]] && ! downloaded && called 'chown -R root:root $OPT/flm' && [[ \$(stat -c %a '$OPT/flm/runtime/bin/flm') == 755 && \$(stat -c %a '$OPT/flm/runtime/lib') == 755 && \$(stat -c %a '$OPT/flm/model-root') == 755 ]]"
done

before="$(tree_sum "$OPT/flm")"
run_ensure "$LIB" FAKE_NO_PYTHON3=1
check "python3 missing with a marked tree → says python3, not a mismatch" \
    "[[ $rc -eq 0 ]] && grep -q 'python3 is unavailable' '$TMP/out' && ! grep -q 'does not match' '$TMP/out' && ! downloaded"
check "python3 missing with a marked tree → tree unchanged" "[[ \$(tree_sum '$OPT/flm') == '$before' ]]"

rm "$OPT/flm/nimoos-flm.json"
run_ensure "$LIB"
check "marker at the pin but no nimoos-flm.json → returns 0" "[[ $rc -eq 0 ]]"
check "marker at the pin but no nimoos-flm.json → installs again" \
    "downloaded && [[ -f '$OPT/flm/nimoos-flm.json' && \$(cat '$OPT/flm/.package-version') == '$PKG_VERSION' ]] && ! leftovers"

fresh "$AMD_NPU"
chmod g+s "$OPT"
run_ensure "$LIB"
check "setgid INSTALL_DIR → installs" "[[ $rc -eq 0 && -f '$OPT/flm/.package-version' ]]"
check "setgid INSTALL_DIR → no directory of the package keeps setgid" "[[ -z \$(find '$OPT/flm' -type d -perm -2000) ]]"

# The download directory ($DL) and INSTALL_DIR really share a filesystem here.
check "fixture: download directory and INSTALL_DIR share a filesystem" "[[ \$(stat -c %d '$DL') == \$(stat -c %d '$OPT') ]]"
fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_INSTALL_AVAIL_KB=$((NEED_KB + SIZE_KB - 1))
check "same filesystem, short of 1.1× unpacked + the archive → returns 0" "[[ $rc -eq 0 ]]"
check "same filesystem, short of 1.1× unpacked + the archive → warns, no download, nothing installed, scratch removed" \
    "warned && grep -q 'skipping it (video' '$TMP/out' && ! downloaded && [[ ! -e '$OPT/flm' ]] && dl_empty"
fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_INSTALL_AVAIL_KB=$((NEED_KB + SIZE_KB))
check "same filesystem, exactly 1.1× unpacked + the archive → installs" "[[ $rc -eq 0 && -f '$OPT/flm/.package-version' ]]"
fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_DIFFERENT_FS=1 FAKE_INSTALL_AVAIL_KB=$((NEED_KB - 1))
check "different filesystems, short of 1.1× unpacked → warns, no download, nothing installed" \
    "[[ $rc -eq 0 ]] && warned && ! downloaded && [[ ! -e '$OPT/flm' ]] && dl_empty"
fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_DIFFERENT_FS=1 FAKE_INSTALL_AVAIL_KB=$NEED_KB
check "different filesystems, exactly 1.1× unpacked (the archive does not count) → installs" "[[ $rc -eq 0 && -f '$OPT/flm/.package-version' ]]"
fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_INSTALL_AVAIL_KB=unknown
check "INSTALL_DIR free space unknown → warns, no download" "[[ $rc -eq 0 ]] && warned && ! downloaded"

fresh "$AMD_NPU"
run_ensure "$NPU_LIB"
check "the lib itself installs too (deploy-parser.sh path)" "[[ $rc -eq 0 && \$(cat '$OPT/flm/.package-version' 2>/dev/null) == '$PKG_VERSION' ]] && ! leftovers"

###############################################################################
echo ""
echo "an upgrade"
###############################################################################
fresh "$AMD_NPU"
old_tree
run_ensure "$LIB"
check "returns 0" "[[ $rc -eq 0 ]]"
check "replaces the old tree" "[[ ! -e '$OPT/flm/old-only' && \$(cat '$OPT/flm/.package-version') == '$PKG_VERSION' && -f '$OPT/flm/nimoos-flm.json' ]]"
check "no staging or old directory left" "! leftovers"

###############################################################################
echo ""
echo "failures warn, return 0 and change nothing"
###############################################################################
# fails <name> <tarball to serve> [VAR=value...]
fails() {
    local name="$1" tarball="$2" before; shift 2
    fresh "$AMD_NPU"
    serve "$tarball"
    old_tree
    before="$(tree_sum "$OPT/flm")"
    run_ensure "$LIB" "$@"
    check "$name → returns 0" "[[ $rc -eq 0 ]]"
    check "$name → warns" "warned"
    check "$name → installed tree unchanged" "[[ \$(tree_sum '$OPT/flm') == '$before' ]]"
    check "$name → no staging or old directory left" "! leftovers"
    check "$name → no download left" "dl_empty"
}
fails "sha256 differs from the pin" "$TMP/good.tar.zst" PARSER_NPU_AMD_SHA256="$(printf '0%.0s' {1..64})"
check "sha256 differs from the pin → says why" "grep -q 'failed its checksum' '$TMP/out'"
fails "size differs from the pin" "$TMP/good.tar.zst" PARSER_NPU_AMD_SIZE_BYTES="$((GOOD_SIZE + 1))"
check "size differs from the pin → says why" "grep -q 'not the pinned' '$TMP/out'"
fails "download fails" "$TMP/good.tar.zst" FAKE_CURL_FAIL=1
check "download fails → says why" "grep -q 'could not fetch' '$TMP/out'"
for how in lying-manifest bad-sums unlisted bad-link licenses; do
    fails "package whose tree fails its check ($how)" "$DEPS/parser/$how.tar.zst" \
        PARSER_NPU_AMD_SHA256="$(sha "$DEPS/parser/$how.tar.zst")" PARSER_NPU_AMD_SIZE_BYTES="$(stat -c%s "$DEPS/parser/$how.tar.zst")"
    check "package whose tree fails its check ($how) → says why" "grep -q 'does not match its own manifest' '$TMP/out' && grep -q 'check failed' '$TMP/out'"
done
fails "runtime/bin/flm is a link" "$DEPS/parser/flm-symlink.tar.zst" \
    PARSER_NPU_AMD_SHA256="$(sha "$DEPS/parser/flm-symlink.tar.zst")" PARSER_NPU_AMD_SIZE_BYTES="$(stat -c%s "$DEPS/parser/flm-symlink.tar.zst")"
check "runtime/bin/flm is a link → its target is not chmodded" "[[ \$(stat -c %a '$OUTSIDE') == 600 ]]"
check "runtime/bin/flm is a link → says why" "grep -q 'not a regular file' '$TMP/out'"
fails "not a zstd tarball" "$SCRIPT" PARSER_NPU_AMD_SHA256="$(sha "$SCRIPT")" PARSER_NPU_AMD_SIZE_BYTES="$(stat -c%s "$SCRIPT")"
check "not a zstd tarball → says why" "grep -q 'could not unpack' '$TMP/out'"

###############################################################################
echo ""
echo "host libraries"
###############################################################################
fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_LIBS="libgomp.so.1" FAKE_APT_FAIL=1
check "missing libcurl/libedit, apt fails → returns 0" "[[ $rc -eq 0 ]]"
check "missing libcurl/libedit, apt fails → apt asked for exactly the three packages, upgrading nothing" \
    "called 'apt-get install -y --no-upgrade libcurl4t64 libedit2 libgomp1' && [[ \$(grep -c '^apt-get install' '$CALLS') -ge 1 ]] && ! grep '^apt-get install' '$CALLS' | grep -qv -- '-y --no-upgrade libcurl4t64 libedit2 libgomp1\$'"
check "missing libcurl/libedit, apt fails → warns and skips" "warned && ! downloaded && [[ ! -e '$OPT/flm' ]]"

fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_LIBS="libgomp.so.1" FAKE_LIBS32="libcurl.so.4 libedit.so.2"
check "32-bit libraries do not count" "called 'apt-get install' && ! downloaded"

fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_LIBS="libcurl.so.4 libgomp.so.1" FAKE_APT_FIXES=1
check "missing libedit, apt installs it → installs the package" \
    "[[ $rc -eq 0 ]] && called 'apt-get install -y --no-upgrade libcurl4t64 libedit2 libgomp1' && [[ \$(cat '$OPT/flm/.package-version' 2>/dev/null) == '$PKG_VERSION' ]]"

fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_GLIBC=2.36
check "glibc 2.36 → returns 0" "[[ $rc -eq 0 ]]"
check "glibc 2.36 → warns, no apt, no download" "warned && ! called apt-get && ! downloaded && [[ ! -e '$OPT/flm' ]]"

fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_GLIBC=2.39
check "glibc 2.39 is enough" "[[ $rc -eq 0 && -f '$OPT/flm/.package-version' ]]"

fresh "$AMD_NPU"
run_ensure "$LIB" FAKE_GLIBC=3.0
check "glibc 3.0 is enough" "[[ $rc -eq 0 && -f '$OPT/flm/.package-version' ]]"

echo ""; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
