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

# --- the artifact anchor -----------------------------------------------------
# Added after the git-only stamp told a reader the wrong tree was live: these
# stamps were first seeded BY HAND from a belief, the belief was wrong for one
# layer, and nothing in the file could contradict it. A stamp that cannot be
# checked against reality is worse than no stamp, because it gets trusted.

ART="$TMP/artifact.bin"
echo "v1" > "$ART"
stamp_write art "$A" "$ART"
[[ "$(sed -n 's/^artifact_sha=//p' "$NIMO_DEPLOY_STAMP_DIR/art")" == "$(sha256sum "$ART" | cut -d' ' -f1)" ]] \
  && ok "the artifact hash is recorded" || bad "the artifact hash is recorded"
check 0 "artifact unchanged -> allowed" stamp_verify art "$A" "thing" "$ART"

# Someone replaced the live artifact outside the deploy scripts: git says the
# same lineage, but the record no longer describes what is installed.
echo "v2-replaced-behind-our-back" > "$ART"
check 1 "artifact replaced outside the scripts -> refused" stamp_verify art "$A" "thing" "$ART"

# A caller that computes the hash elsewhere (inside a container) passes hash:.
stamp_write art2 "$A" "hash:abc123"
[[ "$(sed -n 's/^artifact_sha=//p' "$NIMO_DEPLOY_STAMP_DIR/art2")" == "abc123" ]] \
  && ok "hash: form is stored verbatim" || bad "hash: form is stored verbatim"
# The spec keeps its `hash:` prefix in the file. Bare hex reads exactly like a
# path field, so a reader could not tell a container hash from a host path
# without opening the library — which defeats the point of a readable record.
[[ "$(sed -n 's/^artifact=//p' "$NIMO_DEPLOY_STAMP_DIR/art2")" == "hash:abc123" ]] \
  && ok "a container hash is distinguishable from a path in the file" \
  || bad "a container hash is distinguishable from a path in the file"
check 1 "hash: mismatch -> refused" stamp_verify art2 "$A" "thing" "hash:def456"
check 0 "hash: match -> allowed" stamp_verify art2 "$A" "thing" "hash:abc123"

# An unreachable artifact (container down, file gone) must not be read as a
# mismatch — that would block every deploy on a stopped container.
check 0 "artifact hash unavailable -> not treated as a mismatch" \
  stamp_verify art2 "$A" "thing" "hash:"

# A stamp with no hash at all (hand-written, or predating this field) still
# reasons from git, but says out loud that it could not be cross-checked.
printf 'head=%s\nbranch=x\nrepo_root=%s\ndirty=0\nat=now\n' \
  "$(git -C "$A" rev-parse HEAD)" "$A" > "$NIMO_DEPLOY_STAMP_DIR/art3"
if stamp_verify art3 "$A" "thing" "$ART" 2>&1 | grep -q "could not be cross-checked"; then
  ok "an unverifiable stamp is called out, not trusted silently"
else
  bad "an unverifiable stamp is called out, not trusted silently"
fi

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
