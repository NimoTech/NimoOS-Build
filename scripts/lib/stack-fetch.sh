#!/usr/bin/env bash
# stack-fetch.sh — shared library giving install-*.sh a dual-mode payload lookup
#
#   development machine (source present) -> use the sibling NimoOS-* source tree
#   end user (no source)                 -> download the matching release tarball
#                                           and unpack it into a temp directory
#
# Pulled in by each install-*.sh via `source .../lib/stack-fetch.sh`.
# The download domain, key prefix and version can all be overridden by
# environment variables, which is how nimoos-stack-install.sh applies one
# version across every component.

# Downloads come from the same domain that release/versions.conf uploads to.
: "${NIMO_DOWNLOAD_DOMAIN:=https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/}"
# Key prefix under the download domain. NIMO_OSS_PREFIX is the former name and
# is still honoured so existing environments keep working.
: "${NIMO_KEY_PREFIX:=${NIMO_OSS_PREFIX:-NimoTech}}"
# Third-party dependencies (the official qdrant, ollama and similar binaries) are
# mirrored under deps/ so machines with no direct route to github.com or
# ollama.com can still install. Layout:
#   ${NIMO_DEPS_BASE}/qdrant/qdrant-<arch>.tar.gz
#   ${NIMO_DEPS_BASE}/ollama/ollama-linux-<arch>.tar.zst
: "${NIMO_DEPS_BASE:=https://nimoos-s3-bucket.s3.us-east-2.amazonaws.com/deps}"

# Default version for every component, overridable per component with e.g.
# STACK_VERSION_PARSER. release/versions.conf is the single source of truth, so
# read NIMOOS_VERSION from it when this library sits inside a checkout. Run
# standalone — bootstrapped into a temp directory by `curl | bash` — there is no
# versions.conf to read, and the literal below applies.
if [ -z "${STACK_VERSION:-}" ]; then
    _sf_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
    _sf_conf="${_sf_dir}/../../release/versions.conf"
    if [ -n "${_sf_dir}" ] && [ -f "${_sf_conf}" ]; then
        # Only NIMOOS_VERSION is wanted; grep it out rather than sourcing the file,
        # which would also pull in every VERSION_* and the S3 settings.
        _sf_ver="$(grep -m1 '^NIMOOS_VERSION=' "${_sf_conf}" | cut -d= -f2- | tr -d '"\r')"
        [ -n "${_sf_ver}" ] && STACK_VERSION="v${_sf_ver}"
    fi
    unset _sf_dir _sf_conf _sf_ver
fi
: "${STACK_VERSION:=v1.9.4-alpha1}"

# uname -m -> the architecture token used in release file names
stack_arch() {
    case "$(uname -m)" in
        x86_64)         echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l)         echo "arm-7" ;;
        riscv64)        echo "riscv64" ;;
        *)              echo "amd64" ;;
    esac
}

# stack_download <project> <version> <tarfile> <dest_dir>
#   Download the tarball and unpack it into dest_dir, which must already exist.
#   Returns non-zero on failure.
stack_download() {
    local project="$1" version="$2" tarfile="$3" dest="$4"
    local url="${NIMO_DOWNLOAD_DOMAIN}${NIMO_KEY_PREFIX}/${project}/releases/download/${version}/${tarfile}"
    local tmp
    tmp="$(mktemp)"
    echo "[fetch] ${url}" >&2
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"
        echo "[fetch] download failed: ${url}" >&2
        return 1
    fi
    if ! tar -xzf "${tmp}" -C "${dest}"; then
        rm -f "${tmp}"
        echo "[fetch] could not unpack: ${tarfile}" >&2
        return 1
    fi
    rm -f "${tmp}"
}

# stack_resolve <src_dir> <project> <version> <arch_mode> <token>
#   Work out the component's payload root and print it to stdout:
#     - src_dir exists -> echo src_dir; the caller builds or copies from source
#     - otherwise      -> download linux-<arch|all>-<token>-<version>.tar.gz,
#                         unpack it into a temp directory and echo that
#   The unpacked layout matches the source repository (both contain
#   build/sysroot/...), so callers do not need to tell the two apart.
#   Returns: 0 = source mode, 10 = downloaded, anything else = failure
stack_resolve() {
    local src_dir="$1" project="$2" version="$3" arch_mode="$4" token="$5"
    if [ -n "${src_dir}" ] && [ -d "${src_dir}" ]; then
        echo "${src_dir}"
        return 0
    fi
    local arch tarfile dest
    if [ "${arch_mode}" = "all" ]; then arch="all"; else arch="$(stack_arch)"; fi
    tarfile="linux-${arch}-${token}-${version}.tar.gz"
    dest="$(mktemp -d)"
    if ! stack_download "${project}" "${version}" "${tarfile}" "${dest}"; then
        rm -rf "${dest}"
        return 1
    fi
    echo "${dest}"
    return 10
}

# stack_fetch_dep <relpath> <dest_file>
#   Download a third-party dependency from deps/ into dest_file. relpath looks
#   like qdrant/qdrant-x86_64-... Returns 0 on success and non-zero on a network
#   error or 404, leaving it to the caller to fall back to the upstream source.
stack_fetch_dep() {
    local relpath="$1" dest="$2"
    local url="${NIMO_DEPS_BASE}/${relpath}"
    echo "[dep-fetch] ${url}" >&2
    curl -fSL --retry 3 --connect-timeout 10 -o "${dest}" "${url}"
}
