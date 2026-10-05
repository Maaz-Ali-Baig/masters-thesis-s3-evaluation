#!/usr/bin/env bash
#
# Security test: does a presigned PUT URL accept, and act on, headers that its signature
# does not cover?
#
#   ./scripts/security-presign-unsigned-header.sh sw | rf | ga     credentials from ~/.thesis-s3-env
#   S3C_NAME=ceph S3C_ENDPOINT=http://localhost:80 S3C_KEY=... S3C_SECRET=... \
#     S3C_REGION=us-east-1 bash security-presign-unsigned-header.sh   any endpoint
#
# A presigned URL for PUT is built here with openssl, because the AWS CLI can only presign GET.
# The signature covers the method, the path and the host header only (SignedHeaders=host). The
# request is then sent with extra x-amz-* headers that the signature does not cover. AWS SigV4
# says such a request must be rejected. Ceph patched exactly this class of problem in
# CVE-2026-54330. "Accepted" and "acted upon" are different things, so after each accepted
# upload the object is read back with a second, independently signed curl request: its metadata
# headers, an anonymous GET, and the ACL grants.
#
# Cases (the object key is the case id):
#   g0  control, a presigned GET of an existing object, proves the signing code is right
#   p0  control, presigned PUT, nothing extra
#   p1  unsigned Content-Type
#   p2  unsigned x-amz-meta-injected
#   p3  unsigned x-amz-acl: public-read
#   p4  unsigned x-amz-tagging
#   p5  unsigned x-amz-storage-class: STANDARD_IA
#   p6  unsigned x-amz-website-redirect-location
#   p7  unsigned x-amz-copy-source pointing at g0, sent with an empty body. If the server acts on it,
#       the stored object has the content of g0 (19 bytes) and not 0 bytes.
#   p8  like p7, but the source is secret.txt in a second bucket (25 bytes, not the 19 of g0)
#   s2  control, x-amz-meta-injected is part of the signature (SignedHeaders)
#   s3  control, x-amz-acl is part of the signature
# For every upload the Content-Type header curl would add on its own is removed, so each case
# changes one thing only. The reading of the output is done separately, never in the script.
#
# Output goes to stdout and to $S3C_OUTDIR (default: the current directory).

set -u

if [ -n "${S3C_ENDPOINT:-}" ]; then
    NAME="${S3C_NAME:-custom}"; KEY="${S3C_KEY:?S3C_KEY}"; SECRET="${S3C_SECRET:?S3C_SECRET}"
    REGION="${S3C_REGION:-us-east-1}"; ENDPOINT="$S3C_ENDPOINT"
else
    ENVFILE="${THESIS_S3_ENV:-$HOME/.thesis-s3-env}"
    [ $# -ge 1 ] || { echo "usage: $0 <sw|rf|ga>  or set S3C_ENDPOINT, S3C_KEY, S3C_SECRET" >&2; exit 64; }
    [ -f "$ENVFILE" ] || { echo "security: $ENVFILE not found" >&2; exit 66; }
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
OUTFILE="$OUTDIR/security-presign-unsigned-header-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-sec-ps-$(date +%m%d%H%M%S)"
B2="$B-src"
HOSTPORT="${ENDPOINT#*://}"; HOSTPORT="${HOSTPORT%%/*}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'presigned put body\n' > "$TMP/body.txt"
: > "$TMP/empty.txt"
printf 'cross bucket source body\n' > "$TMP/secret.txt"
SECRETHASH="$(sha256sum "$TMP/secret.txt" | cut -d' ' -f1)"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
BODYHASH="$(sha256sum "$TMP/body.txt" | cut -d' ' -f1)"

hmac_hex() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -hex | awk '{print $NF}'; }

# presign <method> <path> <expires seconds> [name:value ...]
# Prints the presigned URL. The extra name:value pairs, given in sorted order, become signed headers.
presign() {
    local method="$1" path="$2" exp="$3" now d scope cred signed ch q creq sts k kd kr ks kk sig pair
    shift 3
    now="$(date -u +%Y%m%dT%H%M%SZ)"; d="${now:0:8}"
    scope="$d/$REGION/s3/aws4_request"
    cred="${KEY}%2F${d}%2F${REGION}%2Fs3%2Faws4_request"
    signed="host"; ch="host:$HOSTPORT"$'\n'
    for pair in "$@"; do signed="$signed;${pair%%:*}"; ch="$ch${pair%%:*}:${pair#*:}"$'\n'; done
    q="X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=$cred&X-Amz-Date=$now&X-Amz-Expires=$exp&X-Amz-SignedHeaders=${signed//;/%3B}"
    creq="$method"$'\n'"$path"$'\n'"$q"$'\n'"$ch"$'\n'"$signed"$'\n'"UNSIGNED-PAYLOAD"
    sts="AWS4-HMAC-SHA256"$'\n'"$now"$'\n'"$scope"$'\n'"$(printf '%s' "$creq" | sha256sum | cut -d' ' -f1)"
    k="$(printf '%s' "AWS4$SECRET" | od -An -tx1 | tr -d ' \n')"
    kd="$(hmac_hex "$k" "$d")"; kr="$(hmac_hex "$kd" "$REGION")"; ks="$(hmac_hex "$kr" "s3")"; kk="$(hmac_hex "$ks" "aws4_request")"
    sig="$(hmac_hex "$kk" "$sts")"
    printf '%s%s?%s&X-Amz-Signature=%s' "$ENDPOINT" "$path" "$q" "$sig"
}

# sreq <label> <payload sha256> <curl args...>: one request signed by curl itself (header signing).
sreq() {
    local label="$1" ph="$2" code show
    shift 2
    code="$(curl -s -D "$TMP/hdr" -o "$TMP/body" -w '%{http_code}' --max-time 30 \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$KEY:$SECRET" -H "x-amz-content-sha256: $ph" "$@")"
    show="$(head -c 120 "$TMP/body" | tr '\r\n' '  ')"
    printf '    %-34s HTTP %s  %s\n' "$label" "$code" "$show"
}

# after_put <key>: read an uploaded object back with an independent request.
after_put() {
    local k="$1" anon acl meta
    sreq "head, own credentials" "$EMPTY" -I "$ENDPOINT/$B/$k"
    meta="$(tr -d '\r' < "$TMP/hdr" | grep -iE '^(x-amz-meta-[^:]*|content-type|content-length|x-amz-tagging-count|x-amz-storage-class|x-amz-website-redirect-location):' | tr '\n' ' ')"
    printf '    %-34s %s\n' "headers kept" "${meta:-none}"
    anon="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ENDPOINT/$B/$k")"
    printf '    %-34s HTTP %s\n' "anonymous GET" "$anon"
    sreq "acl, own credentials" "$EMPTY" "$ENDPOINT/$B/$k?acl"
    acl="$(grep -c 'AllUsers' "$TMP/body")"
    printf '    %-34s %s\n' "AllUsers grants in ACL" "$acl"
    sreq "content stored, own credentials" "$EMPTY" "$ENDPOINT/$B/$k"
}

# put_case <key> <label> <presign extra name:value pairs, comma separated or empty> -- <curl header args...>
put_case() {
    local k="$1" label="$2" signed="$3" url code show
    shift 4
    # shellcheck disable=SC2086
    if [ -n "$signed" ]; then url="$(presign PUT "/$B/$k" 300 $signed)"; else url="$(presign PUT "/$B/$k" 300)"; fi
    code="$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 30 -X PUT -H "Host: $HOSTPORT" -H "Content-Type:" \
        "$@" --data-binary "@${BODYFILE:-$TMP/body.txt}" "$url")"
    show="$(head -c 150 "$TMP/body" | tr '\r\n' '  ')"
    printf '%s  %s\n    %-34s HTTP %s  %s\n' "$k" "$label" "presigned PUT" "$code" "$show"
    case "$code" in 2*) after_put "$k" ;; esac
}

{
    echo "security-presign-unsigned-header  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket: $B"
    echo
    sreq "create bucket" "$EMPTY" -X PUT "$ENDPOINT/$B"
    sreq "put object for the GET control" "$BODYHASH" -X PUT -H "Content-Type: text/plain" --data-binary "@$TMP/body.txt" "$ENDPOINT/$B/g0"
    sreq "create second bucket" "$EMPTY" -X PUT "$ENDPOINT/$B2"
    sreq "put secret.txt in second bucket" "$SECRETHASH" -X PUT -H "Content-Type: text/plain" --data-binary "@$TMP/secret.txt" "$ENDPOINT/$B2/secret.txt"
    echo
    url="$(presign GET "/$B/g0" 300)"
    code="$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 30 -H "Host: $HOSTPORT" "$url")"
    echo "g0  control, presigned GET"
    printf '    %-34s HTTP %s  %s\n' "presigned GET" "$code" "$(head -c 60 "$TMP/body" | tr '\r\n' '  ')"
    echo
    put_case p0 "control, nothing extra" "" --
    echo
    put_case p1 "unsigned Content-Type: application/octet-stream" "" -- -H "Content-Type: application/octet-stream"
    echo
    put_case p2 "unsigned x-amz-meta-injected: yes" "" -- -H "x-amz-meta-injected: yes"
    echo
    put_case p3 "unsigned x-amz-acl: public-read" "" -- -H "x-amz-acl: public-read"
    echo
    put_case p4 "unsigned x-amz-tagging: unsignedtag=1" "" -- -H "x-amz-tagging: unsignedtag=1"
    echo
    put_case p5 "unsigned x-amz-storage-class: STANDARD_IA" "" -- -H "x-amz-storage-class: STANDARD_IA"
    echo
    put_case p6 "unsigned x-amz-website-redirect-location" "" -- -H "x-amz-website-redirect-location: https://example.org/"
    echo
    BODYFILE="$TMP/empty.txt" put_case p7 "unsigned x-amz-copy-source: /$B/g0, empty body" "" -- -H "x-amz-copy-source: /$B/g0"
    echo
    BODYFILE="$TMP/empty.txt" put_case p8 "unsigned x-amz-copy-source from ANOTHER bucket: /$B2/secret.txt, empty body" "" -- -H "x-amz-copy-source: /$B2/secret.txt"
    echo
    put_case s2 "control, signed x-amz-meta-injected: yes" "x-amz-meta-injected:yes" -- -H "x-amz-meta-injected: yes"
    echo
    put_case s3 "control, signed x-amz-acl: public-read" "x-amz-acl:public-read" -- -H "x-amz-acl: public-read"
    echo
    echo "--- cleanup"
    for k in g0 p0 p1 p2 p3 p4 p5 p6 p7 p8 s2 s3; do sreq "delete $k" "$EMPTY" -X DELETE "$ENDPOINT/$B/$k"; done
    sreq "delete bucket" "$EMPTY" -X DELETE "$ENDPOINT/$B"
    sreq "delete secret.txt" "$EMPTY" -X DELETE "$ENDPOINT/$B2/secret.txt"
    sreq "delete second bucket" "$EMPTY" -X DELETE "$ENDPOINT/$B2"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
