#!/usr/bin/env bash
# Tests for install-parser.sh's staged site-packages swap (swap_in_site_packages)
# and the prebuilt venv path built on it. Run: bash scripts/install-parser.venv.test.sh
#
# BUG-0163 (121, 2026-11-17): fetch_prebuilt_venv removed the live
# site-packages of a running Parser and unpacked the new one in its place. The
# 7.5G filesystem under /opt filled up part-way, the pip fallback could not
# finish either, and Parser kept running on a tree with files missing: every
# job failed with ENOENT. Rules under test:
#   - the new tree is unpacked next to the current one and only renamed into
#     place after the venv's interpreter imports the key modules from it;
#   - not enough free space next to the current tree → rc 2, nothing touched,
#     and setup_venv stops instead of falling back to pip;
#   - a failed import check, a truncated archive or a failed rename → rc 1, the
#     current tree is unchanged, setup_venv falls back to pip on it;
#   - SIGTERM in the middle of the unpack leaves the current tree in place and
#     no staging directory behind;
#   - leftovers of an interrupted run are cleaned up, and an "old" copy whose
#     live directory is gone is put back before anything else happens;
#   - site_packages_need_kb rounds every entry up to 4K blocks.
#
# Same sandbox trick as the other installer tests: functions are lifted out of
# the installer with sed and sourced with INSTALL_DIR under mktemp, `curl` is a
# shim serving fixture tarballs, and sudo is emptied. Nothing real is touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-parser.sh"
TMP="$(mktemp -d)"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP"' EXIT

command -v zstd >/dev/null    || { echo "  skip — zstd not installed"; exit 0; }
command -v python3 >/dev/null || { echo "  skip — python3 not installed"; exit 0; }

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

extract() { sed -n "/^$1() {/,/^}/p" "$SCRIPT"; }
LIB="$TMP/lib.sh"
: > "$LIB"
for f in ensure_zstd avail_kb_of kb_human dl_tmp site_packages_need_kb sp_swap_rollback \
         swap_in_site_packages fetch_prebuilt_venv use_prebuilt setup_venv; do
    extract "$f" >> "$LIB"
    grep -q "^$f() {" "$LIB" && ok "installer defines $f()" || bad "installer defines $f()"
done
grep -q 'rm -rf "${sp}" && ${sudo_cmd} mkdir -p "${sp}"' "$SCRIPT" \
    && bad "no in-place rm -rf + unpack of site-packages is left" \
    || ok "no in-place rm -rf + unpack of site-packages is left"

# ---- fixtures ------------------------------------------------------------------
mk_sp() {   # mk_sp <dir> <module...>: a site-packages with stub packages
    local d="$1" m; shift; mkdir -p "$d"
    for m in "$@"; do mkdir -p "$d/$m"; echo "OK = 1" > "$d/$m/__init__.py"; done
}
GOOD=(torch onnxruntime uvicorn ctranslate2 scenedetect)
mk_sp "$TMP/fx/good" "${GOOD[@]}"
# a .pth file pointing at a subdirectory: the staged import check must run it
mkdir -p "$TMP/fx/good/extra/pthmod"; touch "$TMP/fx/good/extra/pthmod/__init__.py"
echo extra > "$TMP/fx/good/extra.pth"
tar --zstd -cf "$TMP/fx/good.tar.zst" -C "$TMP/fx/good" .
mk_sp "$TMP/fx/stale" torch onnxruntime uvicorn scenedetect   # no ctranslate2
tar --zstd -cf "$TMP/fx/stale.tar.zst" -C "$TMP/fx/stale" .
head -c 300 "$TMP/fx/good.tar.zst" > "$TMP/fx/truncated.tar.zst"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) out="\$2"; shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
case "\$url" in
  *parser-venv-*) cp "\${FAKE_VENV_TARBALL:-$TMP/fx/good.tar.zst}" "\$out";;
  *) exit 22;;
esac
SHIM
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# Every scenario gets a real venv: the import check runs its interpreter. The
# installer hardcodes lib/python3.11, so only on a 3.11 host is that the
# venv's own site-packages, which the "current tree is never imported from"
# check needs; elsewhere that one check is skipped.
python3 -m venv --without-pip "$TMP/probe" || { echo "  skip — python3 -m venv failed"; exit 0; }
PY311=0; [[ "$("$TMP/probe/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')" == 3.11 ]] && PY311=1

# ---- sandbox ---------------------------------------------------------------------
log_info() { echo "INFO: $*"; }; log_ok() { echo "OK: $*"; }
log_warn() { echo "WARN: $*" | tee -a "$TMP/warn.log"; }
log_fail() { echo "FAIL: $*"; exit 1; }
sudo_cmd=""
NIMO_DEPS_BASE="http://deps.test"
DEP_VENV="parser/parser-venv-1.0-cp311-linux-x86_64.tar.zst"
DL_SIZE_ESTIMATE_PREBUILT_VENV=$((1024 * 1024))
# shellcheck disable=SC1090
source "$LIB"
export NIMO_DL_TMPDIR="$TMP/dl"; mkdir -p "$NIMO_DL_TMPDIR"
eval "real_avail_kb_of() $(declare -f avail_kb_of | tail -n +2)"
# The venv's filesystem can be made "full" on its own; download scratch keeps
# the real free space so dl_tmp still succeeds.
avail_kb_of() {
    if [[ -n "${FAKE_VENV_AVAIL_KB:-}" && "$1" == "$INSTALL_DIR"* ]]; then echo "$FAKE_VENV_AVAIL_KB"; else real_avail_kb_of "$1"; fi
}
# mv can be made to fail when it moves the staged tree into place
mv() {
    if [[ -n "${FAKE_MV_FAIL_STAGE:-}" && "$*" == *.new.* ]]; then return 1; fi
    command mv "$@"
}
PIP_LOG="$TMP/pip.log"
pip_install() { echo "pip $*" >> "$PIP_LOG"; }
ensure_openvino_runtime() { :; }
reconcile_parser_gpu_runtime() { :; }
uname() { [[ "${1:-}" == "-m" ]] && echo x86_64 || command uname "$@"; }

scenario() {   # scenario <name> [old]: a venv, optionally with a current site-packages
    INSTALL_DIR="$TMP/inst-$1"
    VENV_DIR="$INSTALL_DIR/venv"
    SP="$VENV_DIR/lib/python3.11/site-packages"
    python3 -m venv --without-pip "$VENV_DIR"
    mkdir -p "$VENV_DIR/lib/python3.11"
    rm -rf "$SP"
    if [[ "${2:-}" == old ]]; then mkdir -p "$SP"; echo current > "$SP/OLD"; fi
    unset FAKE_VENV_TARBALL FAKE_VENV_AVAIL_KB FAKE_MV_FAIL_STAGE
    : > "$TMP/warn.log"; : > "$PIP_LOG"
}
old_intact()   { [[ -f "$SP/OLD" && ! -e "$SP/torch" ]]; }
new_in_place() { [[ -f "$SP/torch/__init__.py" && ! -e "$SP/OLD" ]]; }
no_leftovers() { ! compgen -G "$SP.new.*" >/dev/null && ! compgen -G "$SP.old.*" >/dev/null; }
no_download()  { [[ -z "$(ls -A "$NIMO_DL_TMPDIR")" ]]; }
rc_of() { local rc=0; "$@" >>"$TMP/out.log" 2>&1 || rc=$?; echo "$rc"; }

echo "install-parser.sh site_packages_need_kb"
mkdir -p "$TMP/fx/sz"; head -c 10000 /dev/zero > "$TMP/fx/sz/a"; : > "$TMP/fx/sz/b"
tar --zstd -cf "$TMP/fx/sz.tar.zst" -C "$TMP/fx/sz" .
check "3 entries (dir, 10000 B, 0 B) → 4+(4+12)+4 = 24 KB" '[[ "$(site_packages_need_kb "$TMP/fx/sz.tar.zst")" == 24 ]]'
check "truncated archive → fails" '! site_packages_need_kb "$TMP/fx/truncated.tar.zst" >/dev/null'
check "missing archive → fails" '! site_packages_need_kb "$TMP/fx/nope.tar.zst" >/dev/null'

echo ""
echo "install-parser.sh fetch_prebuilt_venv (staged swap)"

scenario ok old
rc="$(rc_of fetch_prebuilt_venv)"
check "upgrade → rc 0" '[[ "$rc" == 0 ]]'
check "upgrade → new tree in place, old one gone" new_in_place
check "upgrade → .pth files of the new tree are kept" '[[ -f "$SP/extra.pth" ]]'
check "upgrade → no staging or old copy left" no_leftovers
check "upgrade → download removed" no_download

scenario fresh
rc="$(rc_of fetch_prebuilt_venv)"
check "fresh venv → rc 0 and the tree in place" '[[ "$rc" == 0 && -f "$SP/torch/__init__.py" ]]'
check "fresh venv → no leftovers" no_leftovers

scenario nospace old
FAKE_VENV_AVAIL_KB=1
rc="$(rc_of fetch_prebuilt_venv)"
check "not enough room → rc 2" '[[ "$rc" == 2 ]]'
check "not enough room → current tree untouched" old_intact
check "not enough room → no leftovers, download removed" 'no_leftovers && no_download'
check "not enough room → says how much is needed" 'grep -q "not enough free space next to" "$TMP/warn.log"'

scenario room_just_short old
need="$(site_packages_need_kb "$TMP/fx/good.tar.zst")"
FAKE_VENV_AVAIL_KB=$(( need ))      # enough for the tree, not for the 10% margin
rc="$(rc_of fetch_prebuilt_venv)"
check "free space below need+10% → rc 2" '[[ "$rc" == 2 ]] && old_intact'

scenario stale old
export FAKE_VENV_TARBALL="$TMP/fx/stale.tar.zst"
rc="$(rc_of fetch_prebuilt_venv)"
check "import check fails (no ctranslate2) → rc 1" '[[ "$rc" == 1 ]]'
check "import check fails → current tree untouched" old_intact
check "import check fails → no leftovers" no_leftovers
check "import check fails → warns about the import check" 'grep -q "import check" "$TMP/warn.log"'

scenario old_tree_not_used old
# The current tree has every module; the staged one lacks ctranslate2. The
# check must not pass by importing from the current tree.
mk_sp "$SP" "${GOOD[@]}"; rm -rf "$SP/torch"; mk_sp "$SP" torch; echo current > "$SP/OLD"
export FAKE_VENV_TARBALL="$TMP/fx/stale.tar.zst"
if [[ "$PY311" == 1 ]]; then
    "$VENV_DIR/bin/python" -c 'import torch, onnxruntime, uvicorn, ctranslate2, scenedetect' \
        && ok "(precondition) the venv imports every module from its current tree" \
        || bad "(precondition) the venv imports every module from its current tree"
    rc="$(rc_of fetch_prebuilt_venv)"
    check "import check reads only the staged tree (current one has every module) → rc 1" '[[ "$rc" == 1 && -f "$SP/OLD" ]]'
else
    echo "  skip — host python is not 3.11: the current-tree import check needs it"
fi

scenario truncated old
export FAKE_VENV_TARBALL="$TMP/fx/truncated.tar.zst"
rc="$(rc_of fetch_prebuilt_venv)"
check "truncated download → rc 1, current tree untouched, no leftovers" '[[ "$rc" == 1 ]] && old_intact && no_leftovers'

scenario mv_in_fails old
FAKE_MV_FAIL_STAGE=1
rc="$(rc_of fetch_prebuilt_venv)"
unset FAKE_MV_FAIL_STAGE
check "rename into place fails → rc 1 and the previous tree is back" '[[ "$rc" == 1 ]] && old_intact && no_leftovers'

scenario sigterm old
cat > "$TMP/bin/tar" <<'SHIM'
#!/usr/bin/env bash
# pass listings through; on extract, write one file then TERM the installer
for a in "$@"; do [[ "$a" == -x* || "$a" == -*x* && "$a" != --* ]] && x=1; done
if [[ "${x:-}" == 1 ]]; then
    while [[ $# -gt 0 ]]; do [[ "$1" == -C ]] && { : > "$2/partial"; break; }; shift; done
    kill -TERM "$INSTALLER_PID"; sleep 2; exit 1
fi
exec /usr/bin/tar "$@"
SHIM
chmod +x "$TMP/bin/tar"; hash -r
( export INSTALLER_PID=$BASHPID; fetch_prebuilt_venv ) >/dev/null 2>&1; rc=$?
rm -f "$TMP/bin/tar"; hash -r
check "SIGTERM during the unpack → exits 130" '[[ "$rc" == 130 ]]'
check "SIGTERM during the unpack → current tree untouched, no staging left" 'old_intact && no_leftovers'

scenario restore_leftover
mkdir -p "$SP.old.4242"; echo current > "$SP.old.4242/OLD"; mkdir -p "$SP.new.4242/junk"
FAKE_VENV_AVAIL_KB=1
rc="$(rc_of fetch_prebuilt_venv)"
check "interrupted earlier swap → old copy put back even when this run has no room" '[[ "$rc" == 2 ]] && old_intact && no_leftovers'
check "interrupted earlier swap → says so" 'grep -q "interrupted earlier run" "$TMP/warn.log"'

scenario stale_leftovers old
mkdir -p "$SP.old.4242" "$SP.new.4243"
rc="$(rc_of fetch_prebuilt_venv)"
check "leftovers next to a live tree → removed, swap proceeds" '[[ "$rc" == 0 ]] && new_in_place && no_leftovers'

echo ""
echo "install-parser.sh setup_venv"

scenario sv_ok old
out="$( setup_venv 2>&1 )"; rc=$?
check "prebuilt ok → no pip install" '[[ "$rc" == 0 && ! -s "$PIP_LOG" ]] && new_in_place'

scenario sv_nospace old
FAKE_VENV_AVAIL_KB=1
out="$( setup_venv 2>&1 )"; rc=$?
check "no room → setup_venv fails the install" '[[ "$rc" != 0 ]] && grep -q "free up space" <<<"$out"'
check "no room → pip is not attempted" '[[ ! -s "$PIP_LOG" ]]'
check "no room → current venv untouched" old_intact

scenario sv_stale old
export FAKE_VENV_TARBALL="$TMP/fx/stale.tar.zst"
out="$( setup_venv 2>&1 )"; rc=$?
check "stale prebuilt → falls back to pip on the untouched venv" '[[ "$rc" == 0 ]] && grep -q "requirements.txt" "$PIP_LOG" && old_intact'

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
