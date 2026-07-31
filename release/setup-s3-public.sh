#!/usr/bin/env bash
###############################################################################
# setup-s3-public.sh — provision the public download bucket
#
# This is the INTERIM distribution path, used while CloudFront is unavailable.
# Anonymous readers hit S3 directly:
#
#     https://<bucket>.s3.<region>.amazonaws.com/get/nimoos-install.sh
#
# Why a separate bucket rather than opening prefixes on the existing one: the
# original bucket is shared with an unrelated OTA system whose database backups
# and per-device upgrade logs live alongside our artifacts. Granting public read
# there means turning off BlockPublicPolicy at the BUCKET level, which is a
# standing invitation for the next policy edit to expose that data. A dedicated
# bucket that contains nothing private cannot leak what it does not hold.
#
# Only these prefixes are readable, and each is content we intend to publish:
#   get/     install and update scripts
#   deps/    third-party dependency mirror (qdrant, ollama, parser wheels)
#   ttyd/    the terminal binary
#   <S3_PREFIX>/  release artifacts
#
# ACLs stay blocked. The bucket policy is the only grant, so no future upload can
# make an object public by setting an ACL on it.
#
# MIGRATING TO CLOUDFRONT LATER
#   setup-s3-cdn.sh takes this same bucket private again and puts CloudFront in
#   front of it via Origin Access Control. Running it WILL break direct anonymous
#   reads — that is the point — so update DOWNLOAD_DOMAIN to the CloudFront domain
#   in the same change, and re-run sync-install-script.sh.
#
# Usage:
#   ./setup-s3-public.sh --dry-run    # print every AWS call without running it
#   ./setup-s3-public.sh              # create or reconcile
#   ./setup-s3-public.sh --show       # report current state
#
# Credentials come from the standard AWS chain. Creating a bucket and setting a
# bucket policy need administrative rights, so run this under an admin profile,
# not the least-privilege uploader.
###############################################################################
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.conf
source "${SELF_DIR}/versions.conf"

DRY_RUN=0
SHOW_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --show)    SHOW_ONLY=1 ;;
        -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

C_B='\033[34m'; C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_0='\033[0m'
info() { echo -e "${C_B}==>${C_0} $*"; }
ok()   { echo -e "${C_G}[ OK ]${C_0} $*"; }
warn() { echo -e "${C_Y}[WARN]${C_0} $*" >&2; }
die()  { echo -e "${C_R}[FAIL]${C_0} $*" >&2; exit 1; }

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo -e "${C_Y}[dry-run]${C_0} aws $*"
        return 0
    fi
    aws "$@"
}

[ -n "${S3_BUCKET:-}" ] && [ -n "${AWS_REGION:-}" ] \
    || die "S3_BUCKET and AWS_REGION must be set in versions.conf"

# Prefixes served anonymously. Adding one here publishes it to the world.
PUBLIC_PREFIXES=( "get" "deps" "ttyd" "${S3_PREFIX}" )

if [ "${DRY_RUN}" -eq 0 ]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI not found — install it first"
    aws sts get-caller-identity >/dev/null 2>&1 \
        || die "AWS credentials are not usable — run 'aws configure'"
fi

# ---------------------------------------------------------------------------
# --show
# ---------------------------------------------------------------------------
if [ "${SHOW_ONLY}" -eq 1 ]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI not found"
    echo "bucket        : ${S3_BUCKET} (${AWS_REGION})"
    echo "prefix        : ${S3_PREFIX}"
    echo "configured DL : ${DOWNLOAD_DOMAIN}"
    if aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
        echo "bucket exists : yes"
        echo "public access : $(aws s3api get-public-access-block --bucket "${S3_BUCKET}" \
            --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null | tr -d ' \n' || echo unknown)"
        echo "policy        : $(aws s3api get-bucket-policy --bucket "${S3_BUCKET}" \
            --query 'Policy' --output text 2>/dev/null | head -c 120 || echo none)"
    else
        echo "bucket exists : NO"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 1) Bucket
# ---------------------------------------------------------------------------
info "step 1/3: bucket ${S3_BUCKET}"
if aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
    ok "bucket already exists"
else
    # us-east-1 rejects LocationConstraint; every other region requires it.
    if [ "${AWS_REGION}" = "us-east-1" ]; then
        run s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}"
    else
        run s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" \
            --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
    fi
    ok "bucket created"
fi

# ---------------------------------------------------------------------------
# 2) Public access block — ACLs blocked, bucket policy permitted
# ---------------------------------------------------------------------------
info "step 2/3: public access block"
# BlockPublicAcls / IgnorePublicAcls stay ON so an object ACL can never publish
# anything; the bucket policy in step 3 is the single, reviewable grant.
# BlockPublicPolicy / RestrictPublicBuckets must be OFF for that policy to apply.
run s3api put-public-access-block --bucket "${S3_BUCKET}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"
ok "object ACLs blocked; the bucket policy is the only path to public read"

# ---------------------------------------------------------------------------
# 3) Bucket policy — anonymous read, restricted to the published prefixes
# ---------------------------------------------------------------------------
info "step 3/3: bucket policy"
POL="$(mktemp)"
{
    printf '{\n  "Version": "2012-10-17",\n  "Statement": [{\n'
    printf '    "Sid": "PublicReadPublishedPrefixes",\n'
    printf '    "Effect": "Allow",\n'
    printf '    "Principal": "*",\n'
    printf '    "Action": "s3:GetObject",\n'
    printf '    "Resource": [\n'
    for i in "${!PUBLIC_PREFIXES[@]}"; do
        sep=","; [ "$((i + 1))" -eq "${#PUBLIC_PREFIXES[@]}" ] && sep=""
        printf '      "arn:aws:s3:::%s/%s/*"%s\n' "${S3_BUCKET}" "${PUBLIC_PREFIXES[$i]}" "${sep}"
    done
    printf '    ]\n  }]\n}\n'
} > "${POL}"

if [ "${DRY_RUN}" -eq 1 ]; then
    echo -e "${C_Y}[dry-run]${C_0} aws s3api put-bucket-policy with:"
    sed 's/^/          /' "${POL}"
else
    aws s3api put-bucket-policy --bucket "${S3_BUCKET}" --policy "file://${POL}" \
        --region "${AWS_REGION}"
    ok "public read granted on: ${PUBLIC_PREFIXES[*]}"
fi
rm -f "${POL}"

echo
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "dry-run finished, nothing was created"
    exit 0
fi
ok "public bucket ready: https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/"
echo
echo "Verify anonymously — these must return 200, not 403:"
echo "  curl -fsSLI https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/ttyd/${TTYD_VERSION}/ttyd.x86_64"
echo "  curl -fsSLI https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/get/nimoos-install.sh"
