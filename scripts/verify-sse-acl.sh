#!/usr/bin/env bash
#
# Cross-check of probe tests C18 (SSE-S3 header) and C19 (canned ACL) with a second client.
#
#   ./scripts/verify-sse-acl.sh sw     # SeaweedFS (rf and ga also work, as controls)
#
# Both tests returned InternalError through the AWS CLI. The server log for C19 showed it
# looking up "acl.txt" for a key sent as "c19/acl.txt", so the hypothesis is that the ACL
# call fails for keys that have a path prefix. This script tests that directly: the same
# call on a key with no slash and on a key with one. It also prints the raw reply body for
# the encryption header, which the AWS CLI reduces to a generic message.
#
# Only facts are printed. Credentials come from ~/.thesis-s3-env for this one run.

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

OUTFILE="$ROOT/results/verify-sse-acl-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-verify-$(date +%m%d%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'sentinel for sse and acl check\n' > "$TMP/obj.txt"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
FILEHASH="$(sha256sum "$TMP/obj.txt" | cut -d' ' -f1)"

# req <label> <payload sha256> <curl args...>: one signed request, prints the status and body.
req() {
    local label="$1" ph="$2" code
    shift 2
    code="$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 30 \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$KEY:$SECRET" \
        -H "x-amz-content-sha256: $ph" "$@")"
    printf '%-38s HTTP %s   %s\n' "$label" "$code" "$(head -c 700 "$TMP/body" | tr '\r\n' '  ')"
}

{
    echo "verify-sse-acl  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket: $B"
    echo
    req "1  create bucket"                   "$EMPTY"    -X PUT "$ENDPOINT/$B"
    req "2  put flat.txt (no slash)"         "$FILEHASH" -X PUT -T "$TMP/obj.txt" "$ENDPOINT/$B/flat.txt"
    req "3  put dir/nested.txt (with slash)" "$FILEHASH" -X PUT -T "$TMP/obj.txt" "$ENDPOINT/$B/dir/nested.txt"
    echo
    echo "-- ACL: same call, key without and with a path prefix --"
    req "4  acl public-read on flat.txt"        "$EMPTY" -X PUT -H "x-amz-acl: public-read" "$ENDPOINT/$B/flat.txt?acl"
    req "5  acl public-read on dir/nested.txt"  "$EMPTY" -X PUT -H "x-amz-acl: public-read" "$ENDPOINT/$B/dir/nested.txt?acl"
    req "6  read acl of flat.txt"               "$EMPTY" "$ENDPOINT/$B/flat.txt?acl"
    echo
    echo "-- SSE-S3 header: same call, key without and with a path prefix --"
    req "7  put sse flat-sse.txt"            "$FILEHASH" -X PUT -T "$TMP/obj.txt" -H "x-amz-server-side-encryption: AES256" "$ENDPOINT/$B/flat-sse.txt"
    req "8  put sse dir/nested-sse.txt"      "$FILEHASH" -X PUT -T "$TMP/obj.txt" -H "x-amz-server-side-encryption: AES256" "$ENDPOINT/$B/dir/nested-sse.txt"
    req "9  head flat-sse.txt"                "$EMPTY"   -I "$ENDPOINT/$B/flat-sse.txt"
    echo
    for k in flat.txt dir/nested.txt flat-sse.txt dir/nested-sse.txt; do req "cleanup delete $k" "$EMPTY" -X DELETE "$ENDPOINT/$B/$k"; done
    req "cleanup delete bucket"              "$EMPTY"    -X DELETE "$ENDPOINT/$B"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
