# shellcheck shell=bash
# Deploy provenance stamps — "whose tree is live right now?"
#
# The live box has ONE binary per service and ONE agent container, while a
# developer (or an agent session) can hold several worktrees of the same repo.
# deploy.sh and deploy-agent.sh both overwrite from "the current tree", so
# whoever ran last wins — silently. That has cost us twice:
#
#   * a deploy from a tree without the scheduled-task routes replaced the
#     agent's main.py, and POST /agent/tasks started 404-ing while the
#     container still reported healthy;
#   * the reverse, one tree's Go binary gating /agent/web-settings while the
#     container's Python had no such route.
#
# Neither was a judgement error. Both times nobody could SEE what they were
# about to overwrite. These functions record it and refuse a deploy that would
# drop commits, which is the one case worth stopping.
#
# Why hard failure and not a warning: the usual invocation is
# `bash deploy-agent.sh 2>&1 | tail -8`, which swallows anything printed before
# the last few lines. A non-zero exit is the only signal that survives a pipe.
# `NIMO_DEPLOY_FORCE=1` is the escape hatch; it must be typed, so overwriting
# someone else's tree stops being something you can do without noticing.

STAMP_DIR="${NIMO_DEPLOY_STAMP_DIR:-/var/lib/nimoos/.deploy-stamps}"

# sudo only when the stamp dir actually needs it. The default lives under
# /var/lib/nimoos and does; a dir the caller redirected to (tests) usually does
# not, and using sudo there would leave root-owned files the caller then cannot
# rewrite — which silently turns a later stamp_write into a no-op.
_stamp_sudo() {
  [[ $EUID -eq 0 ]] && return 0
  local probe="$STAMP_DIR"
  while [[ -n "$probe" && ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || echo sudo
}

# stamp_artifact_hash <spec> — sha256 of what was actually installed.
#
# spec is either a host path (hashed here) or `hash:<hex>` for an artifact the
# caller had to reach some other way (inside the agent container, say).
# Prints nothing when it cannot be determined; callers treat that as "unknown",
# never as "matches".
stamp_artifact_hash() {
  local spec="${1:-}"
  [[ -z "$spec" ]] && return 0
  if [[ "$spec" == hash:* ]]; then
    echo "${spec#hash:}"
    return 0
  fi
  [[ -r "$spec" ]] || { $(_stamp_sudo) test -r "$spec" 2>/dev/null || return 0; }
  $(_stamp_sudo) sha256sum "$spec" 2>/dev/null | cut -d' ' -f1
}

# stamp_write <name> <git-dir> [artifact-spec] [source]
#
# The artifact hash is the part that makes a stamp checkable. Recording only
# git metadata means the file is an ASSERTION about the live system, and an
# assertion can be wrong — one was: these stamps were first seeded by hand from
# a belief about what was live, the `ai` layer was misidentified, and the stamp
# then told a reader the wrong tree was serving. Anything that can disagree with
# reality must carry something reality can be compared against.
stamp_write() {
  local name="$1" repo="$2" artifact="${3:-}" source="${4:-deploy}" sudo_cmd
  sudo_cmd="$(_stamp_sudo)"
  local artifact_sha
  artifact_sha="$(stamp_artifact_hash "$artifact")"
  local head branch dirty
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
  # A detached HEAD is normal here: restoring someone else's deploy is done by
  # checking out their ref directly, and that has to record their commit.
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  dirty=0
  [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && dirty=1
  $sudo_cmd mkdir -p "$STAMP_DIR"
  printf 'head=%s\nbranch=%s\nrepo_root=%s\ndirty=%s\nat=%s\nsource=%s\nartifact=%s\nartifact_sha=%s\n' \
    "$head" "$branch" "$repo" "$dirty" "$(date -Is)" "$source" \
    "${artifact#hash:}" "${artifact_sha:-}" \
    | $sudo_cmd tee "$STAMP_DIR/$name" >/dev/null
}

_stamp_field() {   # _stamp_field <file> <key>
  [[ -r "$1" ]] || return 1
  sed -n "s/^$2=//p" "$1" | head -1
}

# stamp_verify <name> <git-dir> <human label>
#
# 0 = go ahead (no stamp yet, same lineage, or forced). 1 = refuse.
# The question is deliberately NOT "is it the same commit" (advancing your own
# branch changes that every time) nor "the same branch name" (two worktrees
# happily share `integrate/*`). It is: does the live code exist in MY history?
# If it does, this deploy moves forward. If it does not, the live box holds
# commits this tree never had, and overwriting drops them.
stamp_verify() {
  local name="$1" repo="$2" label="$3" artifact="${4:-}"
  local file="$STAMP_DIR/$name"
  local rec_head rec_branch rec_root rec_dirty reason=""
  local rec_sha now_sha

  rec_head="$(_stamp_field "$file" head || true)"
  [[ -z "$rec_head" || "$rec_head" == unknown ]] && return 0   # nothing to compare
  rec_branch="$(_stamp_field "$file" branch || true)"
  rec_root="$(_stamp_field "$file" repo_root || true)"
  rec_dirty="$(_stamp_field "$file" dirty || true)"

  # Cross-check the stamp against the thing it describes, BEFORE reasoning from
  # it. Ancestry logic is only as good as the claim it starts from, and a stamp
  # that disagrees with the artifact on disk means something replaced that
  # artifact outside these scripts — which happened twice in one night and went
  # unexplained both times. Refuse rather than reason from a claim known to be
  # false; a wrong "you may deploy" is exactly the outcome this file exists to
  # prevent.
  rec_sha="$(_stamp_field "$file" artifact_sha || true)"
  now_sha="$(stamp_artifact_hash "$artifact")"
  if [[ -n "$rec_sha" && -n "$now_sha" && "$rec_sha" != "$now_sha" ]]; then
    reason="the live $label does not match its own deploy record (recorded sha ${rec_sha:0:12}, on disk ${now_sha:0:12}) — something replaced it outside the deploy scripts, so the record cannot be trusted"
  elif [[ -z "$rec_sha" ]]; then
    # Not fatal (old stamps, and hand-written ones, have no hash) but never
    # silent: a reader who trusts an unverifiable stamp is the failure mode.
    echo "  [note] the $label deploy record carries no artifact hash, so it could not be cross-checked" >&2
  fi

  if [[ -n "$reason" ]]; then
    :   # already decided above
  elif ! git -C "$repo" cat-file -e "${rec_head}^{commit}" 2>/dev/null; then
    # Not a lookup failure to shrug at: the commit that is LIVE does not exist
    # in this tree, so it cannot possibly be an ancestor. `--is-ancestor` exits
    # 128 here rather than 1, which a bare `if !` would blur into the same
    # message; say the true thing instead.
    reason="the live $label was built from commit ${rec_head:0:8}, which does not exist in this tree (never fetched, or a different repo)"
  elif ! git -C "$repo" merge-base --is-ancestor "$rec_head" HEAD 2>/dev/null; then
    reason="the live $label has commits this tree does not contain (live ${rec_head:0:8} is not an ancestor of $(git -C "$repo" rev-parse --short HEAD))"
  elif [[ "$rec_dirty" == "1" && "$rec_root" != "$repo" ]]; then
    # Same lineage, but the last deploy came from ANOTHER tree with uncommitted
    # changes, so its commit does not describe what is actually live and
    # ancestry proves nothing about the files.
    reason="the live $label was deployed from $rec_root with uncommitted changes, so what is live cannot be identified from git"
  else
    return 0
  fi

  if [[ "${NIMO_DEPLOY_FORCE:-}" == "1" ]]; then
    echo "  [FORCED] $reason" >&2
    echo "  [FORCED] overwriting anyway because NIMO_DEPLOY_FORCE=1" >&2
    return 0
  fi

  {
    echo ""
    echo "REFUSING TO DEPLOY: $reason"
    echo ""
    echo "  live:  ${rec_head:0:8} on ${rec_branch:-?} from ${rec_root:-?}"
    echo "  yours: $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?') on $(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') from $repo"
    echo ""
    echo "Deploying now would replace the live $label with a tree that never had"
    echo "those commits. Options:"
    echo "  * merge or rebase the live commit into this tree, then deploy;"
    echo "  * deploy from the tree that owns it (see 'from' above);"
    echo "  * NIMO_DEPLOY_FORCE=1 <your command>   # deliberately overwrite it"
  } >&2
  return 1
}
