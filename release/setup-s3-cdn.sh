#!/usr/bin/env bash
###############################################################################
# setup-s3-cdn.sh — provision the S3 + CloudFront distribution path for NimoOS
#
# Idempotent: safe to re-run. Each step checks for the resource first and only
# creates what is missing, so it doubles as a "make reality match this script"
# tool after someone clicks around in the console.
#
# What it builds:
#
#     S3 bucket (private, public access fully blocked)
#          ^  read allowed only via Origin Access Control
#     CloudFront distribution
#          ^
#     https://<id>.cloudfront.net   ->  later: get.nimotech.ai
#
# Why the bucket stays private: a public bucket makes every future upload public
# by default, which is the usual way object storage leaks. With OAC the only
# reader is CloudFront, and the policy names that distribution explicitly.
#
# Cache behaviour, driven by how long each kind of object lives. The TTL comes
# from the Cache-Control header set at upload time, not from the distribution:
#   get/*   install scripts, rewritten in place  -> max-age=300, invalidate
#   others  versioned artifacts, never rewritten -> max-age=31536000, immutable
# Both behaviours therefore use the managed CachingOptimized policy, which honours
# origin Cache-Control. get/* is split out as its own behaviour so invalidations
# and any future TTL change can target install scripts without touching artifacts.
# Because artifact keys contain the version, a new release is always a new key
# and needs no invalidation at all.
#
# Usage:
#   ./setup-s3-cdn.sh --dry-run     # print every AWS call without running it
#   ./setup-s3-cdn.sh               # create or reconcile
#   ./setup-s3-cdn.sh --show        # print current state and the CDN domain
#
# Credentials come from the standard AWS chain (~/.aws/credentials, environment,
# or an instance role). Never pass keys as arguments — they end up in ps output
# and shell history.
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
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
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

# The AWS CLI is only needed for real runs; --dry-run and --help must work
# before it is installed, since reviewing the plan comes first.
if [ "${DRY_RUN}" -eq 0 ]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI not found — install it first"
fi
[ -n "${S3_BUCKET:-}" ] && [ -n "${AWS_REGION:-}" ] \
    || die "S3_BUCKET and AWS_REGION must be set in versions.conf"

OAC_NAME="nimoos-${S3_BUCKET}-oac"
STATE_FILE="${SELF_DIR}/.cdn-state"     # records the distribution id, gitignored

if [ "${DRY_RUN}" -eq 0 ]; then
    aws sts get-caller-identity >/dev/null 2>&1 \
        || die "AWS credentials are not usable — run 'aws configure'"
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
else
    ACCOUNT_ID="<account-id>"
fi

# ---------------------------------------------------------------------------
# --show: report current state and exit
# ---------------------------------------------------------------------------
if [ "${SHOW_ONLY}" -eq 1 ]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI not found"
    echo "bucket        : ${S3_BUCKET} (${AWS_REGION})"
    echo "prefix        : ${S3_PREFIX}"
    echo "configured DL : ${DOWNLOAD_DOMAIN}"
    if aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
        echo "bucket exists : yes"
    else
        echo "bucket exists : NO"
    fi
    dist_id="$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Origins.Items[?contains(DomainName, '${S3_BUCKET}')]].Id | [0]" \
        --output text 2>/dev/null || echo None)"
    if [ "${dist_id}" != "None" ] && [ -n "${dist_id}" ]; then
        dom="$(aws cloudfront get-distribution --id "${dist_id}" \
            --query 'Distribution.DomainName' --output text)"
        sts="$(aws cloudfront get-distribution --id "${dist_id}" \
            --query 'Distribution.Status' --output text)"
        echo "distribution  : ${dist_id} (${sts})"
        echo "CDN domain    : https://${dom}/"
        echo
        echo "Put this in versions.conf when the status is Deployed:"
        echo "  DOWNLOAD_DOMAIN=\"https://${dom}/\""
        echo "And export this so install-script uploads invalidate the CDN:"
        echo "  export CLOUDFRONT_DISTRIBUTION_ID=${dist_id}"
    else
        echo "distribution  : none found"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 1) Bucket — created private, with public access blocked at the bucket level
# ---------------------------------------------------------------------------
info "step 1/5: bucket ${S3_BUCKET}"
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

# All four blocks stay on. The OAC grant in step 4 names a service principal
# (cloudfront.amazonaws.com) restricted by SourceArn, which S3 does not classify
# as public, so BlockPublicPolicy does not stand in its way. Leaving those two
# switches off would only make a later accidentally-public policy possible.
run s3api put-public-access-block --bucket "${S3_BUCKET}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
ok "public access fully blocked (OAC is the only read path)"

# ---------------------------------------------------------------------------
# 2) Origin Access Control — lets exactly one distribution read the bucket
# ---------------------------------------------------------------------------
info "step 2/5: origin access control"
OAC_ID=""
if [ "${DRY_RUN}" -eq 0 ]; then
    OAC_ID="$(aws cloudfront list-origin-access-controls \
        --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
        --output text 2>/dev/null || echo None)"
fi
if [ "${OAC_ID}" = "None" ] || [ -z "${OAC_ID}" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo -e "${C_Y}[dry-run]${C_0} aws cloudfront create-origin-access-control --name ${OAC_NAME}"
        OAC_ID="<oac-id>"
    else
        OAC_ID="$(aws cloudfront create-origin-access-control \
            --origin-access-control-config \
            "Name=${OAC_NAME},Description=NimoOS artifact distribution,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
            --query 'OriginAccessControl.Id' --output text)"
        ok "OAC created: ${OAC_ID}"
    fi
else
    ok "OAC already exists: ${OAC_ID}"
fi

# ---------------------------------------------------------------------------
# 3) Distribution — two cache behaviours, split by object lifetime
# ---------------------------------------------------------------------------
info "step 3/5: cloudfront distribution"
DIST_ID=""
if [ "${DRY_RUN}" -eq 0 ]; then
    DIST_ID="$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Origins.Items[?contains(DomainName, '${S3_BUCKET}')]].Id | [0]" \
        --output text 2>/dev/null || echo None)"
fi

if [ "${DIST_ID}" != "None" ] && [ -n "${DIST_ID}" ]; then
    ok "distribution already exists: ${DIST_ID}"
else
    ORIGIN_DOMAIN="${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
    CFG="$(mktemp)"
    # 658327ea-... is the AWS managed CachingOptimized policy. Using it rather
    # than hand-rolled TTLs keeps the distribution from drifting away from the
    # Cache-Control headers the upload scripts already set per object.
    cat > "${CFG}" <<JSON
{
  "CallerReference": "nimoos-${S3_BUCKET}-$(date -u +%Y%m%d%H%M%S 2>/dev/null || echo manual)",
  "Comment": "NimoOS artifact and install script distribution",
  "Enabled": true,
  "PriceClass": "PriceClass_All",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "s3-${S3_BUCKET}",
      "DomainName": "${ORIGIN_DOMAIN}",
      "OriginAccessControlId": "${OAC_ID}",
      "S3OriginConfig": { "OriginAccessIdentity": "" }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-${S3_BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  },
  "CacheBehaviors": {
    "Quantity": 1,
    "Items": [{
      "PathPattern": "/get/*",
      "TargetOriginId": "s3-${S3_BUCKET}",
      "ViewerProtocolPolicy": "redirect-to-https",
      "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] },
      "Compress": true,
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
    }]
  }
}
JSON
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo -e "${C_Y}[dry-run]${C_0} aws cloudfront create-distribution with:"
        sed 's/^/          /' "${CFG}"
        DIST_ID="<distribution-id>"
    else
        DIST_ID="$(aws cloudfront create-distribution \
            --distribution-config "file://${CFG}" \
            --query 'Distribution.Id' --output text)"
        ok "distribution created: ${DIST_ID}"
        warn "propagation takes 5-15 minutes; check with --show"
    fi
    rm -f "${CFG}"
fi

# ---------------------------------------------------------------------------
# 4) Bucket policy — grant read to that distribution only
# ---------------------------------------------------------------------------
info "step 4/5: bucket policy"
POL="$(mktemp)"
cat > "${POL}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipalReadOnly",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${S3_BUCKET}/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
      }
    }
  }]
}
JSON
if [ "${DRY_RUN}" -eq 1 ]; then
    echo -e "${C_Y}[dry-run]${C_0} aws s3api put-bucket-policy with:"
    sed 's/^/          /' "${POL}"
else
    aws s3api put-bucket-policy --bucket "${S3_BUCKET}" --policy "file://${POL}"
    ok "policy applied — only distribution ${DIST_ID} may read"
fi
rm -f "${POL}"

# ---------------------------------------------------------------------------
# 5) Report what to wire up
# ---------------------------------------------------------------------------
info "step 5/5: next steps"
if [ "${DRY_RUN}" -eq 0 ]; then
    CDN_DOMAIN="$(aws cloudfront get-distribution --id "${DIST_ID}" \
        --query 'Distribution.DomainName' --output text)"
    printf '%s\n' "CLOUDFRONT_DISTRIBUTION_ID=${DIST_ID}" > "${STATE_FILE}"
    echo
    ok "CDN domain: https://${CDN_DOMAIN}/"
    echo
    echo "1. Wait until 'Deployed':   ./setup-s3-cdn.sh --show"
    echo "2. Point downloads at it, in versions.conf:"
    echo "     DOWNLOAD_DOMAIN=\"https://${CDN_DOMAIN}/\""
    echo "3. Regenerate the install script URLs:"
    echo "     ../../nimo_os_docs/release/sync-install-script.sh"
    echo "4. Let install-script uploads invalidate the CDN:"
    echo "     export CLOUDFRONT_DISTRIBUTION_ID=${DIST_ID}"
    echo
    echo "Custom domain later: request an ACM certificate in us-east-1 (CloudFront"
    echo "only reads certificates from that region regardless of the bucket's),"
    echo "add the alias to the distribution, then CNAME get.nimotech.ai to it."
else
    echo "dry-run finished, nothing was created"
fi
