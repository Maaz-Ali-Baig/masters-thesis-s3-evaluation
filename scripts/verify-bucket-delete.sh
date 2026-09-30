#!/usr/bin/env bash
#
# Independent cross-check of the "delete a non-empty bucket" behaviour (probe test C22).
#
#   ./scripts/verify-bucket-delete.sh sw     # SeaweedFS
#   ./scripts/verify-bucket-delete.sh rf     # RustFS
#   ./scripts/verify-bucket-delete.sh ga     # Garage
#
# Why this exists: the probe drives everything through the AWS CLI, which hides the raw
# HTTP status and could in principle be misleading (it already was once, over KeyCount).
# This script repeats the same sequence with curl signing its own requests, so a different
# client confirms or contradicts the result, and every HTTP status code is printed.
#
# Sequence: create a bucket, put one object, list it, DELETE the bucket, HEAD the bucket,
# create it again, list it again. AWS S3 answers the DELETE with 409 BucketNotEmpty and
# the object stays. Only facts are printed here, the reading of them is done separately.
#
# Credentials come from ~/.thesis-s3-env and are used for this one run only.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENVFILE="${THESIS_S3_ENV:-$HOME/.thesis-s3-env}"
[ $# -ge 1 ] || { echo "usage: $0 <sw|rf|ga>" >&2; exit 64; }
[ -f "$ENVFILE" ] || { echo "verify: $ENVFILE not found" >&2; exit 66; }
# shellcheck disable=SC1090
. "$ENVFILE"

case "$1" in
    sw) NAME=seaweedfs; KEY="$SW_KEY"; SECRET="$SW_SECRET"; REGION="$SW_REGION"; ENDPOINT="$SW_ENDPOINT" ;;
    rf) NAME=rustfs;    KEY="$RF_KEY"; SECRET="$RF_SECRET"; REGION="$RF_REGION"; ENDPOINT="$RF_ENDPOINT" ;;
    ga) NAME=garage;    KEY="$GA_KEY"; SECRET="$GA_SECRET"; REGION="$GA_REGION"; ENDPOINT="$GA_ENDPOINT" ;;
    *) echo "unknown system '$1'" >&2; exit 64 ;;
esac

OUTFILE="$ROOT/results/verify-bucket-delete-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-verify-$(date +%m%d%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'sentinel for bucket delete check\n' > "$TMP/sentinel.txt"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
FILEHASH="$(sha256sum "$TMP/sentinel.txt" | cut -d' ' -f1)"

# req <label> <payload sha256> <curl args...>: one signed request, prints the HTTP status
# and the start of the reply body.
req() {
    local label="$1" ph="$2" code
    shift 2
    code="$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 30 \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$KEY:$SECRET" \
        -H "x-amz-content-sha256: $ph" "$@")"
    printf '%-30s HTTP %s   %s\n' "$label" "$code" "$(head -c 240 "$TMP/body" | tr '\r\n' '  ')"
    if grep -q '<Key>' "$TMP/body" 2>/dev/null; then
        printf '%-30s        keys in reply: %s\n' "" "$(grep -o '<Key>[^<]*</Key>' "$TMP/body" | tr '\r\n' '  ')"
    fi
}

{
    echo "verify-bucket-delete  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "curl:   $(curl --version | head -1)"
    echo "bucket: $B"
    echo
    req "1 create bucket"          "$EMPTY"    -X PUT "$ENDPOINT/$B"
    req "2 put one object"         "$FILEHASH" -X PUT -T "$TMP/sentinel.txt" "$ENDPOINT/$B/sentinel.txt"
    req "3 list (object present)"  "$EMPTY"    "$ENDPOINT/$B?list-type=2"
    req "4 DELETE the bucket"      "$EMPTY"    -X DELETE "$ENDPOINT/$B"
    req "5 HEAD the bucket"        "$EMPTY"    -I "$ENDPOINT/$B"
    req "6 create bucket again"    "$EMPTY"    -X PUT "$ENDPOINT/$B"
    req "7 list (object survived?)" "$EMPTY"   "$ENDPOINT/$B?list-type=2"
    echo
    req "cleanup delete object"    "$EMPTY"    -X DELETE "$ENDPOINT/$B/sentinel.txt"
    req "cleanup delete bucket"    "$EMPTY"    -X DELETE "$ENDPOINT/$B"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
