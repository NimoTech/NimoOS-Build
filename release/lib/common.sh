#!/usr/bin/env bash
###############################################################################
# NimoOS release scripts — shared library
#
# Provides: config loading, the component registry, logging, architecture
# mapping and the AWS CLI wrapper.
# Sourced by release.sh and sync-install-script.sh.
###############################################################################

# ---------------------------------------------------------------------------
# Path resolution (independent of the caller's working directory)
# ---------------------------------------------------------------------------
# RELEASE_DIR    = this directory (NimoOS-Build/release)
# DOCS_DIR       = repository root (NimoOS-Build)
# WORKSPACE_ROOT = workspace root (where the NimoOS-* checkouts live)
RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$(cd "${RELEASE_DIR}/.." && pwd)"
# The workspace root can be overridden; layouts differ across build machines.
WORKSPACE_ROOT="${NIMO_WORKSPACE_ROOT:-$(cd "${DOCS_DIR}/.." && pwd)}"

VERSIONS_FILE="${RELEASE_DIR}/versions.conf"
INSTALL_SCRIPT="${DOCS_DIR}/nimoos-install.sh"

# ---------------------------------------------------------------------------
# Colours and logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'
    C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

log_info()  { echo -e "${C_BLUE}==>${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_err()   { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
log_step()  { echo -e "\n${C_CYAN}========== $* ==========${C_RESET}"; }
die()       { log_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Config loading and validation
# ---------------------------------------------------------------------------
load_versions() {
    [ -f "${VERSIONS_FILE}" ] || die "version file not found: ${VERSIONS_FILE}"

    # NIMOOS_VERSION_OVERRIDE lets a caller (the CI tag build) pin a version
    # without editing versions.conf. Re-sourcing through a process substitution
    # recomputes the derived VERSION_* values; VERSION_APPSTORE,
    # VERSION_INSTALLER and TTYD_VERSION are independent and keep their values.
    # versions.conf lives in a public repo, so the private CI must not write it.
    if [ -n "${NIMOOS_VERSION_OVERRIDE:-}" ]; then
        # shellcheck source=/dev/null
        source <(sed 's/^NIMOOS_VERSION=.*/NIMOOS_VERSION="'"${NIMOOS_VERSION_OVERRIDE}"'"/' "${VERSIONS_FILE}")
        [ "${NIMOOS_VERSION}" = "${NIMOOS_VERSION_OVERRIDE}" ] \
            || die "version override failed: expected ${NIMOOS_VERSION_OVERRIDE}, got ${NIMOOS_VERSION}"
    else
        # shellcheck source=/dev/null
        source "${VERSIONS_FILE}"
    fi

    local required=(S3_BUCKET AWS_REGION S3_PREFIX DOWNLOAD_DOMAIN)
    local key
    for key in "${required[@]}"; do
        [ -n "${!key}" ] || die "versions.conf is missing a required key: ${key}"
    done
}

# Warn when the download domain and the upload target look inconsistent.
# A mismatch means artifacts get uploaded to one place and installed from
# another, which fails only at install time on someone else's machine.
assert_same_region() {
    local s3_host="${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
    case "${DOWNLOAD_DOMAIN}" in
        *"${s3_host}"*)
            ;;                                  # direct S3 endpoint, matches
        *cloudfront.net*|*nimotech.ai*)
            ;;                                  # CDN in front of the bucket
        *)
            log_warn "DOWNLOAD_DOMAIN=${DOWNLOAD_DOMAIN} is neither ${s3_host}"
            log_warn "nor a known CDN domain — check versions.conf"
            ;;
    esac
}

component_registry() {
    cat <<'EOF'
gateway|NimoOS-Gateway|NimoOS-Gateway|go|arch|nimoos-gateway|nimoos-gateway|VERSION_GATEWAY|1
messagebus|NimoOS-MessageBus|NimoOS-MessageBus|go|arch|nimoos-message-bus|nimoos-message-bus|VERSION_MESSAGEBUS|1
userservice|NimoOS-UserService|NimoOS-UserService|go|arch|nimoos-user-service|nimoos-user-service|VERSION_USERSERVICE|1
localstorage|NimoOS-LocalStorage|NimoOS-LocalStorage|go|arch|nimoos-local-storage|nimoos-local-storage|VERSION_LOCALSTORAGE|1
appmanagement|NimoOS-AppManagement|NimoOS-AppManagement|go|arch|nimoos-app-management|nimoos-app-management|VERSION_APPMANAGEMENT|1
cli|NimoOS-CLI|NimoOS-CLI|go|arch|nimoos-cli|nimoos-cli|VERSION_CLI|0
ai|NimoOS-AI|NimoOS-AI|go|arch|nimoos-ai|nimoos-ai|VERSION_AI|0
wiki|NimoOS-Wiki|NimoOS-Wiki|go|arch|nimoos-wiki|nimoos-wiki|VERSION_WIKI|0
search|NimoOS-Search|NimoOS-Search|go|arch|nimoos-search|nimoos-search|VERSION_SEARCH|0
photos|NimoOS-Photos|NimoOS-Photos|go|arch|nimoos-photos|nimoos-photos|VERSION_PHOTOS|0
terminal|NimoOS-Terminal|NimoOS-Terminal|go|arch|nimoos-terminal|nimoos-terminal|VERSION_TERMINAL|0
parser|NimoOS-Parser|NimoOS-Parser|python|all|-|nimoos-parser|VERSION_PARSER|0
aiagent|NimoOS-AI|NimoOS-AI|dockeragent|all|-|nimoos-agent|VERSION_AIAGENT|0
ui|NimoOS-UI|NimoOS-UI|static|all|-|nimoos|VERSION_UI|0
appstore|NimoOS-AppStore|NimoOS-AppStore|script|all|package_appstore.sh|appstore|VERSION_APPSTORE|0
core|NimoOS|NimoOS|go|arch|nimoos|nimoos|VERSION_CORE|1
EOF
}

# Look up one registry line by key (non-zero exit when absent)
registry_line() {
    local want="$1"
    component_registry | awk -F'|' -v k="$want" '$1==k {print; found=1} END{exit !found}'
}

# Every component key
all_component_keys() {
    component_registry | awk -F'|' '{print $1}'
}

# ---------------------------------------------------------------------------
# Architecture mapping: target arch -> GOARCH / GOARM / cross compiler CC
# Kept consistent with each project's .goreleaser.yaml
# ---------------------------------------------------------------------------
arch_to_goarch() {
    case "$1" in
        amd64)   echo "amd64" ;;
        arm64)   echo "arm64" ;;
        arm-7)   echo "arm" ;;
        riscv64) echo "riscv64" ;;
        *) return 1 ;;
    esac
}
arch_to_goarm() { [ "$1" = "arm-7" ] && echo "7" || echo ""; }
arch_to_cc() {
    case "$1" in
        amd64)   echo "x86_64-linux-gnu-gcc" ;;
        arm64)   echo "aarch64-linux-gnu-gcc" ;;
        arm-7)   echo "arm-linux-gnueabihf-gcc" ;;
        riscv64) echo "riscv64-linux-gnu-gcc" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# AWS CLI location and S3 key construction
# ---------------------------------------------------------------------------
resolve_aws() {
    if [ -n "${AWS_CLI_BIN:-}" ] && [ -x "${AWS_CLI_BIN:-}" ]; then
        echo "${AWS_CLI_BIN}"; return 0
    fi
    if command -v aws >/dev/null 2>&1; then
        command -v aws; return 0
    fi
    return 1
}

# s3:// upload target for one artifact.
# Layout: s3://<bucket>/<prefix>/<project>/releases/download/<version>/<file>
# The inner releases/download segment mirrors GitHub's release URL shape, which
# keeps the generated install URLs recognisable.
s3_target_url() {
    local project="$1" version="$2" file="$3"
    echo "s3://${S3_BUCKET}/${S3_PREFIX}/${project}/releases/download/${version}/${file}"
}

