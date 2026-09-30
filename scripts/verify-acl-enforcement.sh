#!/usr/bin/env bash
#
# Cross-check of probe test C19: is a public-read ACL actually enforced for anonymous readers?
#
#   ./scripts/verify-acl-enforcement.sh sw     # rf and ga also work, as controls
#
# The probe found that a public-read ACL on a flat key was accepted and listed, yet an
# anonymous GET still returned 403. This checks that with a second client and separates
# three cases: an object ACL, a bucket ACL, and a bucket policy (which passed in C14).
# Anonymous requests are plain curl calls with no signature at all.
#
# Note for the write-up: AWS itself has disabled ACLs on new buckets by default since 2023,
# so "ACLs work" is a legacy AWS behaviour, not the current default.
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

OUTFILE="$ROOT/results/verify-acl-enforcement-$NAME-$(date +%Y%m%d-%H%M%S).txt"
B="s3c-verify-$(date +%m%d%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'acl enforcement sentinel\n' > "$TMP/obj.txt"

s3() {
    AWS_ACCESS_KEY_ID="$KEY" AWS_SECRET_ACCESS_KEY="$SECRET" AWS_DEFAULT_REGION="$REGION" AWS_PAGER="" \
    aws --endpoint-url "$ENDPOINT" "$@"
}
# anon <label> <url>: a request with NO credentials at all.
anon() {
    local code
    code="$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 20 "$2")"
    printf '%-52s anonymous HTTP %s   %s\n' "$1" "$code" "$(head -c 110 "$TMP/body" | tr '\r\n' '  ')"
}
# step <label> <aws args>: a signed call, prints success or the error.
step() {
    local label="$1"
    shift
    if s3 "$@" > "$TMP/out" 2> "$TMP/err"; then
        printf '%-52s ok   %s\n' "$label" "$(head -c 90 "$TMP/out" | tr '\r\n' '  ')"
    else
        printf '%-52s ERROR %s\n' "$label" "$(head -c 130 "$TMP/err" | tr '\r\n' '  ')"
    fi
}

{
    echo "verify-acl-enforcement  system=$NAME  endpoint=$ENDPOINT  region=$REGION"
    echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "bucket: $B"
    echo
    step "create bucket"                          s3api create-bucket --bucket "$B"
    step "put obj.txt"                            s3api put-object --bucket "$B" --key obj.txt --body "$TMP/obj.txt"
    anon "A0 anonymous GET, before any ACL"       "$ENDPOINT/$B/obj.txt"
    echo
    echo "-- case 1: object ACL public-read --"
    step "put-object-acl public-read"             s3api put-object-acl --bucket "$B" --key obj.txt --acl public-read
    step "get-object-acl grantee URIs"            s3api get-object-acl --bucket "$B" --key obj.txt --query 'Grants[].[Grantee.URI,Permission]' --output text
    anon "A1 anonymous GET after object ACL"      "$ENDPOINT/$B/obj.txt"
    echo
    echo "-- case 2: bucket ACL public-read --"
    step "put-bucket-acl public-read"             s3api put-bucket-acl --bucket "$B" --acl public-read
    step "get-bucket-acl grantee URIs"            s3api get-bucket-acl --bucket "$B" --query 'Grants[].[Grantee.URI,Permission]' --output text
    anon "A2 anonymous GET of object after bucket ACL"  "$ENDPOINT/$B/obj.txt"
    anon "A3 anonymous LIST after bucket ACL"     "$ENDPOINT/$B?list-type=2"
    echo
    echo "-- case 3: back to private, then a bucket policy (reference, passed in C14) --"
    step "put-bucket-acl private"                 s3api put-bucket-acl --bucket "$B" --acl private
    step "put-object-acl private"                 s3api put-object-acl --bucket "$B" --key obj.txt --acl private
    anon "A4 anonymous GET after both set private" "$ENDPOINT/$B/obj.txt"
    printf '{"Version":"2012-10-17","Statement":[{"Sid":"AnonRead","Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::%s/*"]}]}' "$B" > "$TMP/policy.json"
    step "put-bucket-policy (anonymous GetObject)" s3api put-bucket-policy --bucket "$B" --policy "file://$TMP/policy.json"
    anon "A5 anonymous GET after bucket policy"   "$ENDPOINT/$B/obj.txt"
    echo
    s3 s3 rm "s3://$B" --recursive >/dev/null 2>&1
    s3 s3api delete-bucket-policy --bucket "$B" >/dev/null 2>&1
    step "cleanup delete bucket"                  s3api delete-bucket --bucket "$B"
} 2>&1 | tee "$OUTFILE"
echo
echo "saved: $OUTFILE"
