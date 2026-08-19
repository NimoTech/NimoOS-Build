#!/usr/bin/env bash
# Tests for lib/deploy-stamp.sh. Run: bash scripts/lib/deploy-stamp.test.sh
#
# Touches nothing real: a throwaway git repo under mktemp and a stamp dir
# redirected with NIMO_DEPLOY_STAMP_DIR, so it needs no root and cannot affect
# a live box.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export NIMO_DEPLOY_STAMP_DIR="$TMP/stamps"
# shellcheck source=deploy-stamp.sh
source "$HERE/deploy-stamp.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok   — $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL — $1"; }
check() {   # check <expected rc> <label> <command...>
  local want="$1" label="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [[ "$got" == "$want" ]] && ok "$label" || bad "$label (want rc=$want, got $got)"
}

git_quiet() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

A="$TMP/tree-a"; B="$TMP/tree-b"
mkdir -p "$A"; git_quiet "$A" init -q
echo base > "$A/f"; git_quiet "$A" add f; git_quiet "$A" commit -qm base
BASE="$(git -C "$A" rev-parse HEAD)"

echo "deploy-stamp.sh"

# 1. Nothing recorded yet: a first-ever deploy must not be blocked.
check 0 "no stamp yet -> allowed" stamp_verify svc "$A" "thing"

# 2. Same commit: the ordinary redeploy of an unchanged tree.
stamp_write svc "$A"
check 0 "same commit -> allowed" stamp_verify svc "$A" "thing"

# 3. Advancing your own branch. Equality would have failed here, which is
#    exactly why the check is ancestry.
echo more >> "$A/f"; git_quiet "$A" commit -qam second
check 0 "live commit is an ancestor -> allowed" stamp_verify svc "$A" "thing"

# 4. Divergence: the live code has a commit this tree never had. THE case both
#    real outages had.
git clone -q "$A" "$B"
git_quiet "$B" checkout -q -b other "$BASE"
echo theirs > "$B/g"; git_quiet "$B" add g; git_quiet "$B" commit -qm theirs
stamp_write svc "$B"                       # their tree is now live
check 1 "live has commits this tree lacks -> refused" stamp_verify svc "$A" "thing"

# 5. Same, but forced.
check 0 "NIMO_DEPLOY_FORCE=1 overrides the refusal" \
  env NIMO_DEPLOY_FORCE=1 bash -c \
  "NIMO_DEPLOY_STAMP_DIR='$NIMO_DEPLOY_STAMP_DIR'; source '$HERE/deploy-stamp.sh'; stamp_verify svc '$A' thing"

# 6. The live commit is not in this tree at all (never fetched). `--is-ancestor`
#    exits 128 here, not 1, so a naive check would report the wrong thing.
UNKNOWN="$(printf 'de%.0s' {1..20})"
printf 'head=%s\nbranch=x\nrepo_root=%s\ndirty=0\nat=now\n' \
  "$UNKNOWN" "$B" > "$NIMO_DEPLOY_STAMP_DIR/svc"
# Assert the fixture actually landed. Without this the test passed on the
# PREVIOUS stamp (also a refusal) when the write failed — a green that proved
# nothing, and how the sudo-ownership bug in stamp_write got found.
[[ "$(sed -n 's/^head=//p' "$NIMO_DEPLOY_STAMP_DIR/svc")" == "$UNKNOWN" ]] \
  && ok "fixture for the unknown-commit case was written" \
  || bad "fixture for the unknown-commit case was written"
check 1 "live commit unknown to this tree -> refused" stamp_verify svc "$A" "thing"

# 7. Same lineage, but deployed from ANOTHER tree with uncommitted changes:
#    ancestry says nothing about the files that actually went out.
echo scratch > "$B/dirty-file"; git_quiet "$B" add dirty-file
git_quiet "$B" checkout -q "$(git -C "$A" rev-parse HEAD)" 2>/dev/null || true
stamp_write svc "$B"
[[ "$(sed -n 's/^dirty=//p' "$NIMO_DEPLOY_STAMP_DIR/svc")" == "1" ]] \
  && ok "dirty state is recorded" || bad "dirty state is recorded"
check 1 "dirty deploy from another tree -> refused" stamp_verify svc "$A" "thing"

# 8. ...but a dirty deploy from THIS tree is just your own work in progress.
stamp_write svc2 "$A"
echo wip >> "$A/f"
stamp_write svc2 "$A"
check 0 "dirty deploy from the same tree -> allowed" stamp_verify svc2 "$A" "thing"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
