#!/usr/bin/env bash
#
# Second-client check of the "server returned success where AWS returns an error" results.
#
#   ./scripts/verify-raw-http.sh sw | rf | ga
#
# Each line is one raw HTTP request made with curl signing its own requests, with the status
# code AWS S3 documents in the label. Nothing is interpreted here, only statuses and headers
# are printed, so the same script can be run on all three systems and the outputs compared.
#
# Checks: conditional GET and PUT, multipart listing and minimum part size, SSE-S3 header
# echo, object lock headers, bad Content-MD5, invalid bucket name, CORS preflight (with and
# without a configuration), and what is returned for CORS and lifecycle after deletion.
#
# Credentials come from ~/.thesis-s3-env for this one run.

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

OUTFILE="$ROOT/results/verify-raw-http-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-verify-$(date +%m%d%H%M%S)"
B2="s3c-verify-nocors-$(date +%m%d%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
head -c 1048576 /dev/urandom > "$TMP/mb.bin"
printf 'raw http check body\n' > "$TMP/small.txt"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
SMALLHASH="$(sha256sum "$TMP/small.txt" | cut -d' ' -f1)"
MBHASH="$(sha256sum "$TMP/mb.bin" | cut -d' ' -f1)"

# req <label> <payload sha256> <curl args...>: one signed request. Leaves the body in
# $TMP/body and the response headers in $TMP/hdr.
req() {
    local label="$1" ph="$2" code show
    shift 2
    code="$(curl -s -D "$TMP/hdr" -o "$TMP/body" -w '%{http_code}' --max-time 30 \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$KEY:$SECRET" \
        -H "x-amz-content-sha256: $ph" "$@")"
    show="$(head -c 150 "$TMP/body" | tr '\r\n' '  ')"
    printf '%-58s HTTP %s   %s\n' "$label" "$code" "$show"
}
# hv <header name>: value of a response header from the last request, empty when absent.
hv() { tr -d '\r' < "$TMP/hdr" | grep -i "^$1:" | head -1 | cut -d' ' -f2-; }
note() { printf '%-58s %s\n' "$1" "$2"; }
urlpath() { printf '%s' "$ENDPOINT/$1"; }

{
    echo "verify-raw-http  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket: $B"
    echo
    req "create bucket" "$EMPTY" -X PUT "$(urlpath "$B")"
    req "put obj.txt" "$SMALLHASH" -X PUT --data-binary "@$TMP/small.txt" "$(urlpath "$B/obj.txt")"
    req "head obj.txt" "$EMPTY" -I "$(urlpath "$B/obj.txt")"
    ETAG="$(hv etag)"
    note "  etag seen" "$ETAG"
    echo
    echo "-- conditional requests (AWS: 304, 412, 412, 412) --"
    req "GET If-None-Match: <etag>            (AWS 304)" "$EMPTY" -H "If-None-Match: $ETAG" "$(urlpath "$B/obj.txt")"
    req "GET If-Match: wrong etag             (AWS 412)" "$EMPTY" -H 'If-Match: "00000000000000000000000000000000"' "$(urlpath "$B/obj.txt")"
    req "GET If-Unmodified-Since: year 2000   (AWS 412)" "$EMPTY" -H "If-Unmodified-Since: Sat, 01 Jan 2000 00:00:00 GMT" "$(urlpath "$B/obj.txt")"
    req "PUT If-None-Match: * on existing key (AWS 412)" "$SMALLHASH" -X PUT -H "If-None-Match: *" --data-binary "@$TMP/small.txt" "$(urlpath "$B/obj.txt")"
    echo
    echo "-- SSE-S3 header, and is it echoed back (AWS: 200 and x-amz-server-side-encryption: AES256) --"
    req "PUT with x-amz-server-side-encryption: AES256" "$SMALLHASH" -X PUT -H "x-amz-server-side-encryption: AES256" --data-binary "@$TMP/small.txt" "$(urlpath "$B/sse.txt")"
    note "  PUT reply header x-amz-server-side-encryption" "[$(hv x-amz-server-side-encryption)]"
    req "HEAD that object" "$EMPTY" -I "$(urlpath "$B/sse.txt")"
    note "  HEAD reply header x-amz-server-side-encryption" "[$(hv x-amz-server-side-encryption)]"
    echo
    echo "-- object lock headers on a normal bucket (AWS: 400 InvalidRequest, lock needs a lock enabled bucket) --"
    req "PUT with x-amz-object-lock-mode GOVERNANCE" "$SMALLHASH" -X PUT -H "x-amz-object-lock-mode: GOVERNANCE" -H "x-amz-object-lock-retain-until-date: 2030-01-01T00:00:00Z" --data-binary "@$TMP/small.txt" "$(urlpath "$B/lock.txt")"
    req "HEAD that object" "$EMPTY" -I "$(urlpath "$B/lock.txt")"
    note "  HEAD reply header x-amz-object-lock-mode" "[$(hv x-amz-object-lock-mode)]"
    echo
    echo "-- integrity and naming (AWS: 400 BadDigest, 400 InvalidBucketName) --"
    req "PUT with wrong Content-MD5" "$MBHASH" -X PUT -H "Content-MD5: $(head -c 16 /dev/zero | base64)" --data-binary "@$TMP/mb.bin" "$(urlpath "$B/badmd5.bin")"
    req "create bucket named Bad_Name_x" "$EMPTY" -X PUT "$(urlpath "Bad_Name_x")"
    echo
    echo "-- multipart (AWS: upload listed, then EntityTooSmall for two 1 MiB parts) --"
    req "POST ?uploads (initiate)" "$EMPTY" -X POST "$(urlpath "$B/mp.bin?uploads")"
    UPID="$(sed -n 's#.*<UploadId>\([^<]*\)</UploadId>.*#\1#p' "$TMP/body" | head -1)"
    note "  upload id" "$UPID"
    req "GET ?uploads (is it listed)" "$EMPTY" "$(urlpath "$B?uploads")"
    note "  upload id occurrences in the listing" "$(grep -c "$UPID" "$TMP/body")  (0 means the upload is missing)"
    req "PUT part 1 (1 MiB)" "$MBHASH" -X PUT --data-binary "@$TMP/mb.bin" "$(urlpath "$B/mp.bin?partNumber=1&uploadId=$UPID")"
    E1="$(hv etag)"
    req "PUT part 2 (1 MiB)" "$MBHASH" -X PUT --data-binary "@$TMP/mb.bin" "$(urlpath "$B/mp.bin?partNumber=2&uploadId=$UPID")"
    E2="$(hv etag)"
    printf '<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>%s</ETag></Part><Part><PartNumber>2</PartNumber><ETag>%s</ETag></Part></CompleteMultipartUpload>' "$E1" "$E2" > "$TMP/complete.xml"
    req "POST complete, two 1 MiB parts (AWS 400 EntityTooSmall)" "$(sha256sum "$TMP/complete.xml" | cut -d' ' -f1)" -X POST --data-binary "@$TMP/complete.xml" "$(urlpath "$B/mp.bin?uploadId=$UPID")"
    req "DELETE ?uploadId (abort, cleanup)" "$EMPTY" -X DELETE "$(urlpath "$B/mp.bin?uploadId=$UPID")"
    echo
    echo "-- CORS: a bucket with NO configuration, then one with a rule for https://example.org only --"
    req "create bucket without CORS" "$EMPTY" -X PUT "$(urlpath "$B2")"
    req "OPTIONS preflight, no CORS configured" "$EMPTY" -X OPTIONS -H "Origin: https://example.org" -H "Access-Control-Request-Method: GET" "$(urlpath "$B2/x")"
    note "  allow-origin header returned" "[$(hv access-control-allow-origin)]"
    printf '<CORSConfiguration><CORSRule><AllowedOrigin>https://example.org</AllowedOrigin><AllowedMethod>GET</AllowedMethod><AllowedHeader>*</AllowedHeader></CORSRule></CORSConfiguration>' > "$TMP/cors.xml"
    CMD5="$(openssl dgst -md5 -binary "$TMP/cors.xml" | base64)"
    req "PUT ?cors (rule for example.org)" "$(sha256sum "$TMP/cors.xml" | cut -d' ' -f1)" -X PUT -H "Content-MD5: $CMD5" --data-binary "@$TMP/cors.xml" "$(urlpath "$B?cors")"
    req "OPTIONS preflight, origin example.org (allowed)" "$EMPTY" -X OPTIONS -H "Origin: https://example.org" -H "Access-Control-Request-Method: GET" "$(urlpath "$B/obj.txt")"
    note "  allow-origin header returned" "[$(hv access-control-allow-origin)]"
    req "OPTIONS preflight, origin evil.example (not listed)" "$EMPTY" -X OPTIONS -H "Origin: https://evil.example" -H "Access-Control-Request-Method: GET" "$(urlpath "$B/obj.txt")"
    note "  allow-origin header returned" "[$(hv access-control-allow-origin)]"
    req "GET object with Origin: https://example.org" "$EMPTY" -H "Origin: https://example.org" "$(urlpath "$B/obj.txt")"
    note "  allow-origin header on the real GET" "[$(hv access-control-allow-origin)]"
    req "GET object with Origin: https://evil.example (not listed)" "$EMPTY" -H "Origin: https://evil.example" "$(urlpath "$B/obj.txt")"
    note "  allow-origin header on that real GET" "[$(hv access-control-allow-origin)]"
    req "DELETE ?cors" "$EMPTY" -X DELETE "$(urlpath "$B?cors")"
    req "GET ?cors after delete (AWS 404 NoSuchCORSConfiguration)" "$EMPTY" "$(urlpath "$B?cors")"
    echo
    echo "-- lifecycle after delete (AWS 404 NoSuchLifecycleConfiguration) --"
    printf '<LifecycleConfiguration><Rule><ID>r</ID><Filter><Prefix>x/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>' > "$TMP/lc.xml"
    LMD5="$(openssl dgst -md5 -binary "$TMP/lc.xml" | base64)"
    req "PUT ?lifecycle" "$(sha256sum "$TMP/lc.xml" | cut -d' ' -f1)" -X PUT -H "Content-MD5: $LMD5" --data-binary "@$TMP/lc.xml" "$(urlpath "$B?lifecycle")"
    req "DELETE ?lifecycle" "$EMPTY" -X DELETE "$(urlpath "$B?lifecycle")"
    req "GET ?lifecycle after delete" "$EMPTY" "$(urlpath "$B?lifecycle")"
    echo
    for k in obj.txt sse.txt lock.txt badmd5.bin mp.bin; do req "cleanup delete $k" "$EMPTY" -X DELETE "$(urlpath "$B/$k")" >/dev/null; done
    req "cleanup delete bucket" "$EMPTY" -X DELETE "$(urlpath "$B")"
    req "cleanup delete bucket (no cors)" "$EMPTY" -X DELETE "$(urlpath "$B2")"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
