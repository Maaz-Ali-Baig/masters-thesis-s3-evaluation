#!/usr/bin/env bash
#
# Cross-check of probe test C21 with a second client (curl signing its own requests).
#
#   ./scripts/verify-key-limits.sh sw     # rf and ga also work, as controls
#
# Two results from the probe are checked here:
#   1. A key ending in "/" accepted a body but read back as 0 bytes of type
#      httpd/unix-directory.
#   2. A 904 byte key was refused with KeyTooLongError. AWS allows 1024 bytes in total.
#
# For 2 the limit is measured, not guessed: keys made of one long path component of
# growing length, and keys made of many short components with a long total length.
# That separates "one component is limited" from "the whole key is limited".
#
# Note: the trailing slash upload uses --data-binary. With -T, curl appends the local file name
# to a URL that ends in a slash, which uploads to a different key and invalidates the test.
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

OUTFILE="$ROOT/results/verify-key-limits-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-verify-$(date +%m%d%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'sixteen bytes ok\n' > "$TMP/obj.txt"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
FILEHASH="$(sha256sum "$TMP/obj.txt" | cut -d' ' -f1)"
CREATED=()

# req <label> <payload sha256> <curl args...>: one signed request, prints status, bytes received
# and the start of the body.
req() {
    local label="$1" ph="$2" res
    shift 2
    res="$(curl -s -o "$TMP/body" -w '%{http_code} bytes=%{size_download} type=%{content_type}' --max-time 30 \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$KEY:$SECRET" \
        -H "x-amz-content-sha256: $ph" "$@")"
    printf '%-34s HTTP %s   %s\n' "$label" "$res" "$(head -c 130 "$TMP/body" | tr '\r\n' '  ')"
}

rep() { local c="$1" n="$2" s=""; s="$(head -c "$n" /dev/zero | tr '\0' "$c")"; printf '%s' "$s"; }

{
    echo "verify-key-limits  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket: $B"
    echo "object body: 17 bytes"
    echo
    req "create bucket" "$EMPTY" -X PUT "$ENDPOINT/$B"
    echo
    echo "-- 1. key ending in slash, with a 17 byte body --"
    req "PUT  dm/marker/ (with body)"  "$FILEHASH" -X PUT --data-binary "@$TMP/obj.txt" "$ENDPOINT/$B/dm/marker/"
    req "GET  dm/marker/"              "$EMPTY"    "$ENDPOINT/$B/dm/marker/"
    req "PUT  dm/plain (control)"      "$FILEHASH" -X PUT -T "$TMP/obj.txt" "$ENDPOINT/$B/dm/plain"
    req "GET  dm/plain (control)"      "$EMPTY"    "$ENDPOINT/$B/dm/plain"
    echo
    echo "-- 2a. ONE path component of growing length (key = that component) --"
    for n in 100 200 255 256 300 500 900 1000; do
        k="$(rep a "$n")"
        req "PUT  1 component, $n bytes" "$FILEHASH" -X PUT -T "$TMP/obj.txt" "$ENDPOINT/$B/$k"
    done
    echo
    echo "-- 2b. MANY short components, long total (each component 100 bytes) --"
    for parts in 5 9 10; do
        k=""; i=0
        while [ $i -lt $parts ]; do k="$k$(rep b 100)/"; i=$((i + 1)); done
        k="${k}end"
        req "PUT  $parts x 100 byte parts, total ${#k}" "$FILEHASH" -X PUT -T "$TMP/obj.txt" "$ENDPOINT/$B/$k"
    done
    echo
    echo "-- 2c. exact TOTAL key length (components of at most 99 bytes, so a per component limit cannot interfere) --"
    for total in 300 400 450 470 478 479 480 490 511 512 600 1000 1024 1025; do
        k=""; left=$total
        while [ "$left" -gt 0 ]; do
            take=$left; [ "$take" -gt 99 ] && take=99
            k="$k$(rep d "$take")"; left=$((left - take))
            if [ "$left" -gt 1 ]; then k="$k/"; left=$((left - 1)); fi
        done
        req "PUT  total key length ${#k}" "$FILEHASH" -X PUT -T "$TMP/obj.txt" "$ENDPOINT/$B/$k"
    done
    echo
    echo "-- cleanup: SeaweedFS removes a bucket with its contents, other systems may need objects removed first --"
    # Remove the objects first: systems that refuse to delete a non empty bucket would otherwise keep it.
    AWS_ACCESS_KEY_ID="$KEY" AWS_SECRET_ACCESS_KEY="$SECRET" AWS_DEFAULT_REGION="$REGION" AWS_PAGER="" aws --endpoint-url "$ENDPOINT" s3 rm "s3://$B" --recursive >/dev/null 2>&1
    req "delete bucket" "$EMPTY" -X DELETE "$ENDPOINT/$B"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
