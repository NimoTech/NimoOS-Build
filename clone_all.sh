#!/bin/bash
# Clone every NimoOS repository, laid out the way a build expects.
#
# Each Go service has a `replace` directive pointing at ../NimoOS-Common, so the
# repositories must be siblings of one another. By default they are cloned next
# to this checkout of NimoOS-Build, which produces exactly that layout; pass a
# different directory to override.
#
# A failed clone does not stop the run — failures are summarised at the end, and
# directories that already exist are skipped, so the script is safe to re-run.
#
# Usage: ./clone_all.sh [target-directory]
#
# Cloning over HTTPS by default means no SSH key is needed. Set NIMO_GIT_SSH=1
# to use git@github.com instead, which is what you want when pushing.

# Default to the parent of this checkout, so the repositories end up as siblings.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEST_DIR="${1:-$(dirname "${SELF_DIR}")}"
mkdir -p "$DEST_DIR"
cd "$DEST_DIR" || { echo "cannot enter $DEST_DIR"; exit 1; }

if [ "${NIMO_GIT_SSH:-0}" = "1" ]; then
    GIT_BASE="git@github.com:NimoTech"
else
    GIT_BASE="https://github.com/NimoTech"
fi

echo "cloning into: $DEST_DIR"
echo "remote base:  $GIT_BASE"
echo ""

# Repositories under the NimoTech organisation. Order does not matter.
# Each line is: <repository> [target-directory]
NIMOTECH_REPOS=(
    "NimoOS"                # core: file management, system monitoring, Samba, cloud storage mounts
    "NimoOS-Gateway"        # API gateway, the only externally reachable entry point
    "NimoOS-MessageBus"     # inter-service pub/sub plus WebSocket
    "NimoOS-UserService"    # users, JWT, JWKS
    "NimoOS-LocalStorage"   # disks, MergerFS, USB
    "NimoOS-AppManagement"  # Docker Compose apps and the AppStore
    "NimoOS-AI"             # LLM routing, the Python agent, the outward-facing MCP server
    "NimoOS-Search"         # RAG retrieval API
    "NimoOS-Wiki"           # visible long-term memory (.wiki.md)
    "NimoOS-Photos"         # albums: EXIF, thumbnails, local vectors
    "NimoOS-Parser"         # Python indexing service (docling plus embeddings into Qdrant)
    "NimoOS-AppStore"       # AppStore manifests and cache (a data repository)
    "NimoOS-Terminal"       # the built-in web terminal (ttyd, tmux, a thin Go service)
    "NimoOS-Common"         # shared library: JWT, zap, HTTP, inter-service SDK
    "NimoOS-CLI"            # Cobra CLI for administration and diagnostics
    "NimoOS-UI"             # Vue 2 SPA
    "NimoOS-KVM"            # optional add-on: libvirt VM management; not part of the core install
)

# Not cloned: NimoOS's internal documentation repository, and the retired
# v0.4.x-era installer repository whose scripts this one replaced. Both are
# private, and nothing here depends on either — a build needs only the
# repositories above.

success=0
failed=0
skipped=0
failed_list=()

clone_repo() {
    local url="$1" dir="$2"
    if [ -d "$dir/.git" ]; then
        echo "skipping (already present): $dir"
        skipped=$((skipped + 1))
        return
    fi
    echo ">>> cloning $dir"
    if git clone "$url" "$dir"; then
        success=$((success + 1))
    else
        echo "[ERROR] clone failed: $url"
        failed=$((failed + 1))
        failed_list+=("$dir")
    fi
    echo ""
}

for entry in "${NIMOTECH_REPOS[@]}"; do
    repo="${entry%% *}"                       # first field: repository name
    dir="${entry#* }"; [ "$dir" = "$entry" ] && dir="$repo"   # second field: target directory, defaulting to the repository name
    clone_repo "${GIT_BASE}/${repo}.git" "$dir"
done

echo ""
echo "Done. $success cloned, $skipped skipped, $failed failed."
[ "$failed" -gt 0 ] && echo "failed: ${failed_list[*]}"
echo ""
echo "Layout:"
ls -1 "$DEST_DIR"
