# shellcheck shell=bash
# Shared version/build resolution for deploy.sh & release.sh.
# Requires NIMOOS_VERSION in scope (source versions.conf first).

# _build_number_floor: the highest build number that appears in builds.log, used
# as a lower bound. If the counter file is lost, emptied or corrupted — moving to
# a new machine, say — this keeps build numbers monotonic and stops them from
# repeating a number already used. Both historical line formats are accepted:
# "build=<n>" and "version=<ver>+<n>".
# $1 = path to the counter file; builds.log sits beside it. Prints 0 if unreadable.
_build_number_floor() {
  local log; log="$(dirname "$1")/builds.log"
  [ -r "$log" ] || { printf '0'; return 0; }
  awk '{
    for (i=1;i<=NF;i++) {
      if ($i ~ /^build=[0-9]+$/)            { n=substr($i,7)+0; if(n>m)m=n }
      else if ($i ~ /^version=.*\+[0-9]/)   { k=$i; sub(/^.*\+/,"",k); n=k+0; if(n>m)m=n }
    }
  } END { printf "%d", m+0 }' "$log" 2>/dev/null || printf '0'
}

# _next_build_number: atomically allocate the next build number. The counter is
# machine-wide, only ever increases, and is shared by dev deploys and releases.
# The counter file defaults to ~/.nimoos-ci/build-number and can be overridden
# with NIMOOS_BUILD_COUNTER. flock serialises the read-modify-write so deploy.sh
# and the packaging timer cannot hand out the same number.
# The starting point is max(current counter, highest number in builds.log), so a
# missing or corrupted file never resets to 1 or reuses a historical number. Any
# failure — an unwritable directory, for instance — degrades to 0 rather than
# aborting a caller running under set -e.
_next_build_number() {
  local f="${NIMOOS_BUILD_COUNTER:-$HOME/.nimoos-ci/build-number}"
  mkdir -p "$(dirname "$f")" 2>/dev/null || { printf '0'; return 0; }
  (
    flock 200 2>/dev/null || true
    cur="$(cat "$f" 2>/dev/null)"
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac       # missing or non-numeric -> 0
    floor="$(_build_number_floor "$f")"             # historical high-water mark, survives a reset
    [ "$floor" -gt "$cur" ] && cur="$floor"         # never go backwards
    c=$(( cur + 1 ))
    printf '%s\n' "$c" > "$f" 2>/dev/null || true
    printf '%s' "$c"
  ) 200>"${f}.lock" 2>/dev/null || printf '0'
}

# resolve_full_version: prints "$NIMOOS_VERSION+$build".
#   NIMOOS_BUILD set (passed in by release or CI) -> <ver>+<NIMOOS_BUILD>
#                                                     e.g. 1.9.3-alpha1+15
#   unset (a dev build via deploy.sh)             -> <ver>+<N>.g<sha>[-dirty]
#                                                     e.g. 1.9.3-alpha1+16.g730794d
#     N = the machine-wide monotonic build number, one allocated per call from the
#         same counter releases use
#     g<sha> records the commit and makes a dev build recognisable at a glance —
#         release artifacts have no .g<sha> suffix
# Note that the dev branch HAS A SIDE EFFECT: every call allocates (increments) a
# new build number, so a caller must invoke it exactly once per build. deploy.sh,
# deploy-ui.sh and deploy-parser.sh all do.
resolve_full_version() {
  local build="${NIMOOS_BUILD:-}"
  if [ -z "$build" ]; then
    local n sha
    n="$(_next_build_number)"
    sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [ -n "$(git status --porcelain 2>/dev/null)" ] && sha="${sha}-dirty"
    build="${n}.g${sha}"
  fi
  printf '%s+%s' "${NIMOOS_VERSION}" "${build}"
}

# GO_VERSION_SYM: deploy.sh service key -> ldflags -X target (pkg.Var)
declare -gA GO_VERSION_SYM=(
  [nimoos]="github.com/NimoTech/NimoOS/common.VERSION"
  [gateway]="github.com/NimoTech/NimoOS-Gateway/common.Version"
  [message-bus]="github.com/NimoTech/NimoOS-MessageBus/common.MessageBusVersion"
  [user-service]="github.com/NimoTech/NimoOS-UserService/common.Version"
  [local-storage]="github.com/NimoTech/NimoOS-LocalStorage/common.Version"
  [app-management]="github.com/NimoTech/NimoOS-AppManagement/common.AppManagementVersion"
  [ai]="github.com/NimoTech/NimoOS-AI/common.AIVersion"
  [wiki]="github.com/NimoTech/NimoOS-Wiki/common.WikiVersion"
  [search]="github.com/NimoTech/NimoOS-Search/common.Version"
  [photos]="github.com/NimoTech/NimoOS-Photos/common.PhotosVersion"
  [terminal]="github.com/NimoTech/NimoOS-Terminal/config.Version"
)
