#!/usr/bin/env bash
#
# Second-client check of the "wrong x-amz-checksum header accepted" result (probe test C20).
#
#   ./scripts/verify-checksum-header.sh sw | rf | ga      credentials from ~/.thesis-s3-env
#   S3C_NAME=ceph S3C_ENDPOINT=http://localhost:80 S3C_KEY=... S3C_SECRET=... \
#     S3C_REGION=us-east-1 bash verify-checksum-header.sh   any endpoint, inline credentials
#
# Each line is one raw PUT made with curl signing its own request, so the AWS CLI is not
# involved. The same small body is uploaded with a correct and with a wrong
# x-amz-checksum-sha256 and x-amz-checksum-sha1 header. AWS S3 answers the wrong ones with
# 400 BadDigest. A HEAD with x-amz-checksum-mode shows which checksum the server stored,
# and a GET shows whether the body arrived intact. Only statuses, headers and short body
# excerpts are printed, the reading of them is done separately.
#
# Content-Type is set explicitly on every PUT so that it is part of the signature. curl adds
# an unsigned one when it sends a body, and the first version of this check, without it, got
# 403 AccessDenied from Ceph RGW on every upload, even with a correct checksum.
#
# Output goes to stdout and to $S3C_OUTDIR (default: the current directory).

set -u

if [ -n "${S3C_ENDPOINT:-}" ]; then
    NAME="${S3C_NAME:-custom}"; KEY="${S3C_KEY:?S3C_KEY}"; SECRET="${S3C_SECRET:?S3C_SECRET}"
    REGION="${S3C_REGION:-us-east-1}"; ENDPOINT="$S3C_ENDPOINT"
else
    ENVFILE="${THESIS_S3_ENV:-$HOME/.thesis-s3-env}"
    [ $# -ge 1 ] || { echo "usage: $0 <sw|rf|ga>  or set S3C_ENDPOINT, S3C_KEY, S3C_SECRET" >&2; exit 64; }
    [ -f "$ENVFILE" ] || { echo "verify: $ENVFILE not found" >&2; exit 66; }
    # shellcheck disable=SC1090
    . "$ENVFILE"
    case "$1" in
        sw) NAME=seaweedfs; KEY="$SW_KEY"; SECRET="$SW_SECRET"; REGION="$SW_REGION"; ENDPOINT="$SW_ENDPOINT" ;;
        rf) NAME=rustfs;    KEY="$RF_KEY"; SECRET="$RF_SECRET"; REGION="$RF_REGION"; ENDPOINT="$RF_ENDPOINT" ;;
        ga) NAME=garage;    KEY="$GA_KEY"; SECRET="$GA_SECRET"; REGION="$GA_REGION"; ENDPOINT="$GA_ENDPOINT" ;;
        *) echo "unknown system '$1'" >&2; exit 64 ;;
    esac
fi

OUTDIR="${S3C_OUTDIR:-$(pwd)}"
mkdir -p "$OUTDIR"
OUTFILE="$OUTDIR/verify-checksum-header-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-verify-ck-$(date +%m%d%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'checksum header check body\n' > "$TMP/small.txt"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
BODYHASH="$(sha256sum "$TMP/small.txt" | cut -d' ' -f1)"
SHA256_OK="$(openssl dgst -sha256 -binary "$TMP/small.txt" | base64)"
SHA1_OK="$(openssl dgst -sha1 -binary "$TMP/small.txt" | base64)"
SHA256_BAD="$(head -c 32 /dev/zero | base64)"
SHA1_BAD="$(head -c 20 /dev/zero | base64)"

# req <label> <payload sha256> <curl args...>: one signed request. Leaves the body in
# $TMP/body and the response headers in $TMP/hdr, and prints the status, any
# x-amz-checksum response headers and a short body excerpt.
req() {
    local label="$1" ph="$2" code show ck
    shift 2
    code="$(curl -s -D "$TMP/hdr" -o "$TMP/body" -w '%{http_code}' --max-time 30 \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$KEY:$SECRET" \
        -H "x-amz-content-sha256: $ph" "$@")"
    show="$(head -c 150 "$TMP/body" | tr '\r\n' '  ')"
    ck="$(tr -d '\r' < "$TMP/hdr" | grep -i '^x-amz-checksum' | tr '\n' ' ')"
    printf '%-46s HTTP %s  %s %s\n' "$label" "$code" "$ck" "$show"
}
url() { printf '%s' "$ENDPOINT/$1"; }

{
    echo "verify-checksum-header  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket: $B"
    echo "body sha256 (base64) = $SHA256_OK"
    echo
    req "create bucket" "$EMPTY" -X PUT "$(url "$B")"
    echo "--- PUT with a checksum header (AWS: correct = 200, wrong = 400 BadDigest)"
    req "put, correct sha256" "$BODYHASH" -X PUT -H "Content-Type: application/octet-stream" --data-binary "@$TMP/small.txt" -H "x-amz-checksum-sha256: $SHA256_OK" "$(url "$B/ok256.txt")"
    req "put, WRONG sha256" "$BODYHASH" -X PUT -H "Content-Type: application/octet-stream" --data-binary "@$TMP/small.txt" -H "x-amz-checksum-sha256: $SHA256_BAD" "$(url "$B/bad256.txt")"
    req "put, correct sha1" "$BODYHASH" -X PUT -H "Content-Type: application/octet-stream" --data-binary "@$TMP/small.txt" -H "x-amz-checksum-sha1: $SHA1_OK" "$(url "$B/ok1.txt")"
    req "put, WRONG sha1" "$BODYHASH" -X PUT -H "Content-Type: application/octet-stream" --data-binary "@$TMP/small.txt" -H "x-amz-checksum-sha1: $SHA1_BAD" "$(url "$B/bad1.txt")"
    echo "--- what was stored (HEAD with x-amz-checksum-mode: ENABLED)"
    for k in ok256 bad256 ok1 bad1; do
        req "head $k.txt" "$EMPTY" -I -H "x-amz-checksum-mode: ENABLED" "$(url "$B/$k.txt")"
    done
    echo "--- is the body of the object stored under the wrong sha256 intact"
    req "get bad256.txt" "$EMPTY" "$(url "$B/bad256.txt")"
    cp "$TMP/body" "$TMP/got.txt"
    if cmp -s "$TMP/got.txt" "$TMP/small.txt"; then echo "body identical to what was sent: yes"; else echo "body identical to what was sent: no (or object missing)"; fi
    echo "--- cleanup"
    for k in ok256 bad256 ok1 bad1; do
        req "delete $k.txt" "$EMPTY" -X DELETE "$(url "$B/$k.txt")"
    done
    req "delete bucket" "$EMPTY" -X DELETE "$(url "$B")"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
