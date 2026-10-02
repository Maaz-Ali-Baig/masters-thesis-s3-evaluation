#!/usr/bin/env bash
#
# S3 API compatibility probe for the thesis testbed (Chapter 6, Appendix C).
#
# One file, one target system per run. The same file is used unchanged against
# Ceph RGW, SeaweedFS, RustFS and Garage, so every compatibility matrix cell
# comes from identical requests.
#
# Usage (credentials are passed inline so nothing persists in the shell):
#   S3C_NAME=ceph S3C_ENDPOINT=http://localhost:80 \
#   S3C_KEY=... S3C_SECRET=... S3C_REGION=us-east-1 \
#   ./s3-compat.sh [--only C01,C08] [--keep] [--list]
#
# Variables:
#   S3C_NAME       label used in the output directory name (required)
#   S3C_ENDPOINT   S3 endpoint URL (required)
#   S3C_KEY        access key (required)
#   S3C_SECRET     secret key (required)
#   S3C_REGION     signing region, default us-east-1 (Garage needs its own)
#   S3C_OUTDIR     output directory, default ./compat-out/<name>-<timestamp>
#   S3C_NOTE       free text stored in env.txt, e.g. the server version string
#   S3C_CHECKSUM   optional: "when_required" makes the AWS CLI stop adding
#                  default integrity checksums to requests. Leave unset to test
#                  the default client behaviour.
#
# Verdicts, per test:
#   PASS         every sub-check behaved as AWS S3 documents it
#   UNSUPPORTED  a sub-check failed and the server answered NotImplemented
#   FAIL         a sub-check failed for any other reason
#   SKIP         a prerequisite failed, or the installed AWS CLI lacks the flag
# PASS/FAIL is decided mechanically against documented AWS S3 behaviour. Whether
# a FAIL is a defect or a legitimate design difference is a judgement made later
# from the saved evidence, never here.
#
# Evidence: every request is saved as evidence/<test>/<test>-NN.{cmd,out,err}
# (command, stdout, stderr), so any matrix cell can be traced to the raw reply.
# Credentials are never written to the output directory.
#
# Cleanup: buckets created by the run are emptied and removed at the end. Object
# lock uses GOVERNANCE mode only, never COMPLIANCE, because COMPLIANCE cannot be
# undone by the owner and would leave undeletable data behind.

set -u

ONLY=""
KEEP=0
for a in "$@"; do
    case "$a" in
        --keep) KEEP=1 ;;
        --list) LISTONLY=1 ;;
        --only) ;;
        --only=*) ONLY="${a#--only=}" ;;
        C[0-9]*) ONLY="$a" ;;
        *) ;;
    esac
done
# "--only C01,C02" (two words) is handled here since the loop above sees them apart
prev=""
for a in "$@"; do
    [ "$prev" = "--only" ] && ONLY="$a"
    prev="$a"
done

TESTS="C01 C02 C03 C04 C05 C06 C07 C08 C09 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20 C21 C22"

if [ "${LISTONLY:-0}" = 1 ]; then
    echo "$TESTS"
    exit 0
fi

: "${S3C_NAME:?S3C_NAME is required}"
: "${S3C_ENDPOINT:?S3C_ENDPOINT is required}"
: "${S3C_KEY:?S3C_KEY is required}"
: "${S3C_SECRET:?S3C_SECRET is required}"
REGION="${S3C_REGION:-us-east-1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${S3C_OUTDIR:-./compat-out/${S3C_NAME}-${STAMP}}"
mkdir -p "$OUT/evidence" "$OUT/data"
OUT="$(cd "$OUT" && pwd)"
DATA="$OUT/data"
SUMMARY="$OUT/summary.tsv"
: > "$SUMMARY"

# Bucket names: lowercase letters, digits and hyphens only, so every system accepts them.
SAFE="$(printf '%s' "$S3C_NAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | cut -c1-12)"
RUN="s3c-${SAFE}-$(date +%m%d%H%M%S)"
B1="${RUN}-main"
BUCKETS=()

# A private AWS config file makes the run independent of ~/.aws and forces
# path-style addressing, which every self-hosted endpoint here expects.
{
    echo "[default]"
    echo "region = $REGION"
    echo "s3 ="
    echo "    addressing_style = path"
    if [ "${S3C_CHECKSUM:-}" = "when_required" ]; then
        echo "request_checksum_calculation = when_required"
        echo "response_checksum_validation = when_required"
    fi
} > "$OUT/aws-config"

aws_() {
    AWS_ACCESS_KEY_ID="$S3C_KEY" AWS_SECRET_ACCESS_KEY="$S3C_SECRET" \
    AWS_DEFAULT_REGION="$REGION" AWS_CONFIG_FILE="$OUT/aws-config" \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PAGER="" \
    aws --endpoint-url "$S3C_ENDPOINT" --cli-read-timeout 60 --cli-connect-timeout 10 "$@"
}

# ---------------------------------------------------------------------------
# Evidence and verdict plumbing
# ---------------------------------------------------------------------------

T_ID=""; T_DESC=""; T_DIR=""; STEP=0; SUBS=""; NBAD=0
LAST_OUT=""; LAST_ERR=""; LAST_RC=0

want() {
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

begin() {
    want "$1" || return 1
    T_ID="$1"; T_DESC="$2"; T_DIR="$OUT/evidence/$1"
    mkdir -p "$T_DIR"
    STEP=0; SUBS=""; NBAD=0
    return 0
}

# recover_reply <n> <aws args>: AWS CLI 2.36 crashes with "argument of type
# 'NoneType' is not a container or iterable" (s3errormsg.py) on an error reply
# whose <Message> is empty, which Ceph RGW sends. The crash hides the server's
# answer, so the failed request is repeated once with --debug and only the HTTP
# status line and the reply body are kept (never the request headers, which hold
# the signature). The error code read from the raw reply is appended to the .err
# file in the CLI's own wording, so errcode sees what the server really said.
recover_reply() {
    local n="$1" code status
    shift
    grep -q "is not a container or iterable" "$T_DIR/$n.err" || return 0
    aws_ "$@" --debug 2>&1 | awk '/HTTP\/1\.1" [0-9]+ /{print} /Response body:/{getline; print; exit}' > "$T_DIR/$n.reply"
    code="$(sed -n 's/.*<Code>\([^<]*\)<\/Code>.*/\1/p' "$T_DIR/$n.reply" | head -1)"
    status="$(sed -n 's/.*HTTP\/1\.1" \([0-9]*\) .*/\1/p' "$T_DIR/$n.reply" | head -1)"
    [ -n "$code" ] && printf 'An error occurred (%s) when calling the operation: read from the raw reply (HTTP %s), the AWS CLI crashed on it, see %s.reply\n' "$code" "$status" "$n" >> "$T_DIR/$n.err"
    return 0
}

# run <aws args>: execute the AWS CLI against the endpoint and keep the evidence.
run() {
    STEP=$((STEP + 1))
    local n
    n="$(printf '%s-%02d' "$T_ID" "$STEP")"
    printf '$ aws --endpoint-url %s %s\n' "$S3C_ENDPOINT" "$*" > "$T_DIR/$n.cmd"
    aws_ "$@" > "$T_DIR/$n.out" 2> "$T_DIR/$n.err"
    LAST_RC=$?
    [ "$LAST_RC" -ne 0 ] && recover_reply "$n" "$@"
    LAST_OUT="$T_DIR/$n.out"; LAST_ERR="$T_DIR/$n.err"
    return $LAST_RC
}

# runx <command...>: same, for non-AWS tools such as curl.
runx() {
    STEP=$((STEP + 1))
    local n
    n="$(printf '%s-%02d' "$T_ID" "$STEP")"
    printf '$ %s\n' "$*" > "$T_DIR/$n.cmd"
    "$@" > "$T_DIR/$n.out" 2> "$T_DIR/$n.err"
    LAST_RC=$?
    LAST_OUT="$T_DIR/$n.out"; LAST_ERR="$T_DIR/$n.err"
    return $LAST_RC
}

# errcode: the S3 error code from the last failed AWS CLI call, or the HTTP status.
errcode() {
    local c
    c="$(sed -n 's/.*An error occurred (\([^)]*\)).*/\1/p' "$LAST_ERR" | head -1)"
    [ -z "$c" ] && c="rc$LAST_RC"
    printf '%s' "$c"
}

# errmsg: short single-line error text, safe for the tab-separated summary.
errmsg() { head -c 200 "$LAST_ERR" | tr '\n\t' '  '; }

outv() { tr -d '\n' < "$LAST_OUT"; }

# sub <name> <0|1> [note]: record one sub-check. 1 means it failed.
sub() {
    if [ "$2" = 0 ]; then
        SUBS="$SUBS $1:ok"
    else
        SUBS="$SUBS $1:FAIL(${3:-})"
        NBAD=$((NBAD + 1))
    fi
}

finish() {
    printf '%s\t%s\t%s\t%s\n' "$T_ID" "$1" "$T_DESC" "${2# }" >> "$SUMMARY"
    printf '%-4s %-11s %s\n     %s\n' "$T_ID" "$1" "$T_DESC" "${2# }"
}

conclude() {
    if [ "$NBAD" -eq 0 ]; then
        finish PASS "$SUBS"
    elif printf '%s' "$SUBS" | grep -qi 'NotImplemented'; then
        finish UNSUPPORTED "$SUBS"
    else
        finish FAIL "$SUBS"
    fi
}

skip() { finish SKIP "$1"; }

mkbucket() {
    local b="$1"
    shift
    if run s3api create-bucket --bucket "$b" "$@"; then
        BUCKETS+=("$b"); return 0
    fi
    # AWS-style servers outside us-east-1 want the region spelled out.
    if grep -q 'IllegalLocationConstraint\|InvalidLocationConstraint' "$LAST_ERR"; then
        if run s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$REGION" "$@"; then
            BUCKETS+=("$b"); return 0
        fi
    fi
    return 1
}

putsmall() { run s3api put-object --bucket "$1" --key "$2" --body "$DATA/small.txt"; }

purge_bucket() {
    local b="$1" q k v u
    aws_ s3api list-multipart-uploads --bucket "$b" --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null |
    while IFS=$'\t' read -r k u; do
        [ -z "$k" ] && continue
        [ "$k" = None ] && continue
        aws_ s3api abort-multipart-upload --bucket "$b" --key "$k" --upload-id "$u" >/dev/null 2>&1
    done
    for q in Versions DeleteMarkers; do
        aws_ s3api list-object-versions --bucket "$b" --query "${q}[].[Key,VersionId]" --output text 2>/dev/null |
        while IFS=$'\t' read -r k v; do
            [ -z "$k" ] && continue
            [ "$k" = None ] && continue
            aws_ s3api delete-object --bucket "$b" --key "$k" --version-id "$v" >/dev/null 2>&1 ||
            aws_ s3api delete-object --bucket "$b" --key "$k" --version-id "$v" --bypass-governance-retention >/dev/null 2>&1
        done
    done
    aws_ s3 rm "s3://$b" --recursive >/dev/null 2>&1
    aws_ s3api delete-bucket --bucket "$b" >/dev/null 2>&1
}

cleanup() {
    local b
    if [ "$KEEP" = 1 ]; then
        echo "cleanup skipped (--keep). Buckets left: ${BUCKETS[*]-none}"
        return
    fi
    : > "$OUT/cleanup.txt"
    for b in ${BUCKETS[@]+"${BUCKETS[@]}"}; do
        purge_bucket "$b"
        if aws_ s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
            echo "LEFT BEHIND $b" >> "$OUT/cleanup.txt"
            echo "cleanup: bucket $b could NOT be removed, delete it by hand"
        else
            echo "removed $b" >> "$OUT/cleanup.txt"
        fi
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Environment record and test data
# ---------------------------------------------------------------------------

{
    echo "name:        $S3C_NAME"
    echo "endpoint:    $S3C_ENDPOINT"
    echo "region:      $REGION"
    echo "started:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "aws cli:     $(aws --version 2>&1)"
    echo "checksum:    ${S3C_CHECKSUM:-cli default}"
    echo "note:        ${S3C_NOTE:-}"
    echo "client host: $(uname -srm)"
    echo "run id:      $RUN"
    echo "--- server response headers, GET / (anonymous) ---"
    curl -s -I --max-time 10 "$S3C_ENDPOINT/" 2>&1
} > "$OUT/env.txt"

printf 'hello s3 compat\n' > "$DATA/small.txt"
head -c 1048576 /dev/urandom > "$DATA/rand1m.bin"
head -c 6291456 /dev/urandom > "$DATA/rand6m.bin"
head -c 5242880 "$DATA/rand6m.bin" > "$DATA/part1.bin"
tail -c +5242881 "$DATA/rand6m.bin" > "$DATA/part2.bin"
head -c 1048576 "$DATA/rand6m.bin" > "$DATA/tiny1.bin"

T_ID="SETUP"; T_DIR="$OUT/evidence/SETUP"; mkdir -p "$T_DIR"; STEP=0
echo "== $S3C_NAME  $S3C_ENDPOINT  ($RUN)"
if ! mkbucket "$B1"; then
    echo "SETUP FAILED: could not create the working bucket."
    echo "  $(errcode): $(errmsg)"
    echo "  Raw evidence: $T_DIR"
    exit 2
fi
url="$S3C_ENDPOINT/$B1"

# Shared fixture: tests that need an existing object read this one instead of
# depending on another test's output, so any test can be run alone with --only.
run s3api put-object --bucket "$B1" --key fixture/rand1m.bin --body "$DATA/rand1m.bin" >/dev/null ||
    echo "warning: fixture upload failed ($(errcode)); tests that read it will fail, see evidence/SETUP"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

t_c01() {
    begin C01 "Bucket create, head, list, delete" || return
    local b="${RUN}-c01"
    if mkbucket "$b"; then sub create 0; else sub create 1 "$(errcode)"; conclude; return; fi
    if run s3api head-bucket --bucket "$b"; then sub head 0; else sub head 1 "$(errcode)"; fi
    run s3api list-buckets --query 'Buckets[].Name' --output text
    if [ $LAST_RC = 0 ] && grep -qw "$b" "$LAST_OUT"; then sub list 0; else sub list 1 "not listed"; fi
    if run s3api delete-bucket --bucket "$b"; then sub delete 0; else sub delete 1 "$(errcode)"; fi
    run s3api head-bucket --bucket "$b"
    if [ $LAST_RC = 0 ]; then sub gone 1 "head still succeeds"; elif grep -qE '404|Not Found|NoSuchBucket' "$LAST_ERR"; then sub gone 0; else sub gone 1 "failed but not as not-found: $(errcode)"; fi
    conclude
}

t_c02() {
    begin C02 "PUT, HEAD, GET object with content integrity" || return
    local k="c02/rand1m.bin" etag md5
    if run s3api put-object --bucket "$B1" --key "$k" --body "$DATA/rand1m.bin" --query ETag --output text; then
        sub put 0; etag="$(outv | tr -d '"')"
    else
        sub put 1 "$(errcode)"; conclude; return
    fi
    if run s3api head-object --bucket "$B1" --key "$k" --query ContentLength --output text &&
       [ "$(outv)" = 1048576 ]; then sub head_length 0; else sub head_length 1 "$(errcode) $(outv)"; fi
    if run s3api get-object --bucket "$B1" --key "$k" "$T_DIR/get.bin" && cmp -s "$T_DIR/get.bin" "$DATA/rand1m.bin"; then
        sub get_bytes_identical 0
    else
        sub get_bytes_identical 1 "$(errcode)"
    fi
    md5="$(md5sum < "$DATA/rand1m.bin" | cut -d' ' -f1)"
    # Recorded as information: AWS returns the MD5 as the ETag for single-part uploads.
    if [ "$etag" = "$md5" ]; then sub etag_is_md5 0; else sub etag_is_md5 1 "etag=$etag"; fi
    conclude
}

t_c03() {
    begin C03 "Content-Type, user metadata and cache headers round trip" || return
    local k="c03/meta.txt" got
    if ! run s3api put-object --bucket "$B1" --key "$k" --body "$DATA/small.txt" \
            --content-type application/x-thesis --metadata k1=v1,k2=v2 \
            --cache-control max-age=60 --content-disposition attachment; then
        sub put 1 "$(errcode)"; conclude; return
    fi
    run s3api head-object --bucket "$B1" --key "$k" \
        --query '[ContentType,Metadata.k1,Metadata.k2,CacheControl,ContentDisposition]' --output text
    got="$(outv | tr '\t' '|')"
    if [ "$got" = "application/x-thesis|v1|v2|max-age=60|attachment" ]; then
        sub head_returns_all 0
    else
        sub head_returns_all 1 "got=$got"
    fi
    conclude
}

t_c04() {
    begin C04 "Range GET: bounded, suffix, open ended, unsatisfiable" || return
    local k="fixture/rand1m.bin"
    run s3api get-object --bucket "$B1" --key "$k" --range bytes=0-9 "$T_DIR/r1.bin"
    head -c 10 "$DATA/rand1m.bin" > "$T_DIR/e1.bin"
    if [ $LAST_RC = 0 ] && cmp -s "$T_DIR/r1.bin" "$T_DIR/e1.bin"; then sub bounded 0; else sub bounded 1 "$(errcode)"; fi
    run s3api get-object --bucket "$B1" --key "$k" --range bytes=-5 "$T_DIR/r2.bin"
    tail -c 5 "$DATA/rand1m.bin" > "$T_DIR/e2.bin"
    if [ $LAST_RC = 0 ] && cmp -s "$T_DIR/r2.bin" "$T_DIR/e2.bin"; then sub suffix 0; else sub suffix 1 "$(errcode)"; fi
    run s3api get-object --bucket "$B1" --key "$k" --range bytes=100- "$T_DIR/r3.bin"
    tail -c +101 "$DATA/rand1m.bin" > "$T_DIR/e3.bin"
    if [ $LAST_RC = 0 ] && cmp -s "$T_DIR/r3.bin" "$T_DIR/e3.bin"; then sub open_ended 0; else sub open_ended 1 "$(errcode)"; fi
    # AWS answers 416 InvalidRange when the start is past the end of the object.
    run s3api get-object --bucket "$B1" --key "$k" --range bytes=99999999- "$T_DIR/r4.bin"
    if [ $LAST_RC != 0 ] && grep -qi 'InvalidRange\|416' "$LAST_ERR"; then
        sub unsatisfiable_rejected 0
    else
        sub unsatisfiable_rejected 1 "rc=$LAST_RC $(errcode)"
    fi
    conclude
}

t_c05() {
    begin C05 "Server-side CopyObject with content integrity" || return
    local k="c05/copy.bin"
    if run s3api copy-object --bucket "$B1" --key "$k" --copy-source "$B1/fixture/rand1m.bin"; then
        sub copy 0
    else
        sub copy 1 "$(errcode)"; conclude; return
    fi
    if run s3api get-object --bucket "$B1" --key "$k" "$T_DIR/copy.bin" && cmp -s "$T_DIR/copy.bin" "$DATA/rand1m.bin"; then
        sub copy_bytes_identical 0
    else
        sub copy_bytes_identical 1 "$(errcode)"
    fi
    # Copy onto itself with REPLACE metadata is how clients rewrite metadata in place.
    if run s3api copy-object --bucket "$B1" --key "$k" --copy-source "$B1/$k" \
            --metadata-directive REPLACE --metadata z=1; then
        run s3api head-object --bucket "$B1" --key "$k" --query Metadata.z --output text
        if [ "$(outv)" = 1 ]; then sub metadata_replace 0; else sub metadata_replace 1 "got=$(outv)"; fi
    else
        sub metadata_replace 1 "$(errcode)"
    fi
    conclude
}

t_c06() {
    begin C06 "Listing: v2 prefix and delimiter, pagination, start-after, v1" || return
    local k tok n total=0 pages=0 trunc
    for k in c06/a/1.txt c06/a/2.txt c06/b/1.txt c06/root1.txt c06/root2.txt; do
        putsmall "$B1" "$k" || { sub seed 1 "$k $(errcode)"; conclude; return; }
    done
    run s3api list-objects-v2 --bucket "$B1" --prefix c06/ --delimiter / --query '[length(CommonPrefixes),length(Contents)]' --output text
    if [ "$(outv | tr '\t' ',')" = "2,2" ]; then sub prefix_delimiter 0; else sub prefix_delimiter 1 "got=$(outv | tr '\t' ',') $(errcode)"; fi
    tok=""
    while [ "$pages" -lt 10 ]; do
        pages=$((pages + 1))
        if [ -z "$tok" ]; then
            run s3api list-objects-v2 --bucket "$B1" --prefix c06/ --max-keys 2 --no-paginate --query '[IsTruncated,NextContinuationToken,KeyCount]' --output text
        else
            run s3api list-objects-v2 --bucket "$B1" --prefix c06/ --max-keys 2 --no-paginate --continuation-token "$tok" --query '[IsTruncated,NextContinuationToken,KeyCount]' --output text
        fi
        [ $LAST_RC = 0 ] || break
        trunc="$(cut -f1 "$LAST_OUT" | tr -d '\n')"
        tok="$(cut -f2 "$LAST_OUT" | tr -d '\n')"
        n="$(cut -f3 "$LAST_OUT" | tr -d '\n')"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
        [ "$trunc" = True ] || break
        [ "$tok" = None ] && break
    done
    # 5 keys at 2 per page must take 3 pages. One page means max-keys was ignored.
    if [ "$total" = 5 ] && [ "$pages" -ge 3 ]; then sub pagination 0; else sub pagination 1 "keys=$total pages=$pages"; fi
    run s3api list-objects-v2 --bucket "$B1" --prefix c06/ --start-after c06/a/2.txt --query 'length(Contents)' --output text
    if [ "$(outv)" = 3 ]; then sub start_after 0; else sub start_after 1 "got=$(outv) $(errcode)"; fi
    run s3api list-objects --bucket "$B1" --prefix c06/ --query 'length(Contents)' --output text
    if [ "$(outv)" = 5 ]; then sub list_v1 0; else sub list_v1 1 "got=$(outv) $(errcode)"; fi
    conclude
}

t_c07() {
    begin C07 "DeleteObject, DeleteObjects, delete of a missing key" || return
    putsmall "$B1" c07/a.txt; putsmall "$B1" c07/b.txt; putsmall "$B1" c07/c.txt
    if run s3api delete-object --bucket "$B1" --key c07/a.txt; then sub delete_one 0; else sub delete_one 1 "$(errcode)"; fi
    run s3api get-object --bucket "$B1" --key c07/a.txt "$T_DIR/gone.bin"
    if grep -q 'NoSuchKey' "$LAST_ERR"; then sub get_after_delete_nosuchkey 0; else sub get_after_delete_nosuchkey 1 "$(errcode)"; fi
    # AWS treats deleting a key that does not exist as success.
    if run s3api delete-object --bucket "$B1" --key c07/never-existed.txt; then sub delete_missing_ok 0; else sub delete_missing_ok 1 "$(errcode)"; fi
    if run s3api delete-objects --bucket "$B1" --delete '{"Objects":[{"Key":"c07/b.txt"},{"Key":"c07/c.txt"}],"Quiet":false}'; then
        sub delete_many 0
    else
        sub delete_many 1 "$(errcode)"; conclude; return
    fi
    # Not KeyCount here. A first run got no KeyCount from an auto-paginated listing, and the
    # likely cause is the AWS CLI merging pages (unconfirmed, keycount_zero_when_empty below
    # tests it with --no-paginate). Listing the keys does not depend on the answer.
    run s3api list-objects-v2 --bucket "$B1" --prefix c07/ --query 'Contents[].Key' --output text
    if [ $LAST_RC = 0 ] && { [ -z "$(outv)" ] || [ "$(outv)" = None ]; }; then sub all_gone 0; else sub all_gone 1 "remaining=$(outv)"; fi
    # AWS always reports KeyCount, including 0. --no-paginate returns the server's raw first page.
    run s3api list-objects-v2 --bucket "$B1" --prefix c07/ --no-paginate --query 'KeyCount' --output text
    if [ "$(outv)" = 0 ]; then sub keycount_zero_when_empty 0; else sub keycount_zero_when_empty 1 "got=$(outv)"; fi
    conclude
}

t_c08() {
    begin C08 "Multipart upload: complete, list, abort, minimum part size" || return
    local k="c08/mp.bin" uid e1 e2 q1 q2 body
    if run s3api create-multipart-upload --bucket "$B1" --key "$k" --query UploadId --output text; then
        uid="$(outv)"; sub initiate 0
    else
        sub initiate 1 "$(errcode)"; conclude; return
    fi
    run s3api upload-part --bucket "$B1" --key "$k" --upload-id "$uid" --part-number 1 --body "$DATA/part1.bin" --query ETag --output text
    e1="$(outv)"
    run s3api upload-part --bucket "$B1" --key "$k" --upload-id "$uid" --part-number 2 --body "$DATA/part2.bin" --query ETag --output text
    e2="$(outv)"
    if [ -n "$e1" ] && [ -n "$e2" ] && [ "$e1" != None ] && [ "$e2" != None ]; then sub upload_parts 0; else sub upload_parts 1 "$(errcode)"; fi
    run s3api list-parts --bucket "$B1" --key "$k" --upload-id "$uid" --query 'length(Parts)' --output text
    if [ "$(outv)" = 2 ]; then sub list_parts 0; else sub list_parts 1 "got=$(outv) $(errcode)"; fi
    run s3api list-multipart-uploads --bucket "$B1" --query 'Uploads[].UploadId' --output text
    if grep -qF "$uid" "$LAST_OUT"; then sub list_uploads 0; else sub list_uploads 1 "upload not listed"; fi
    q1="$(printf '%s' "$e1" | sed 's/"/\\"/g')"; q2="$(printf '%s' "$e2" | sed 's/"/\\"/g')"
    body="{\"Parts\":[{\"ETag\":\"$q1\",\"PartNumber\":1},{\"ETag\":\"$q2\",\"PartNumber\":2}]}"
    if run s3api complete-multipart-upload --bucket "$B1" --key "$k" --upload-id "$uid" --multipart-upload "$body"; then
        sub complete 0
    else
        sub complete 1 "$(errcode)"
    fi
    if run s3api get-object --bucket "$B1" --key "$k" "$T_DIR/mp.bin" && cmp -s "$T_DIR/mp.bin" "$DATA/rand6m.bin"; then
        sub assembled_bytes_identical 0
    else
        sub assembled_bytes_identical 1 "$(errcode)"
    fi
    run s3api head-object --bucket "$B1" --key "$k" --query ETag --output text
    if outv | grep -q -- '-2"*$'; then sub etag_has_part_count 0; else sub etag_has_part_count 1 "etag=$(outv)"; fi
    # Abort: the upload must disappear and later part uploads must be refused.
    if run s3api create-multipart-upload --bucket "$B1" --key c08/aborted.bin --query UploadId --output text; then
        uid="$(outv)"
        run s3api upload-part --bucket "$B1" --key c08/aborted.bin --upload-id "$uid" --part-number 1 --body "$DATA/part1.bin"
        if run s3api abort-multipart-upload --bucket "$B1" --key c08/aborted.bin --upload-id "$uid"; then sub abort 0; else sub abort 1 "$(errcode)"; fi
        run s3api upload-part --bucket "$B1" --key c08/aborted.bin --upload-id "$uid" --part-number 2 --body "$DATA/tiny1.bin"
        if [ $LAST_RC != 0 ] && grep -q 'NoSuchUpload' "$LAST_ERR"; then sub part_after_abort_refused 0; else sub part_after_abort_refused 1 "rc=$LAST_RC $(errcode)"; fi
    else
        sub abort 1 "initiate: $(errcode)"
    fi
    # AWS refuses to complete an upload whose non-final part is under 5 MiB.
    if run s3api create-multipart-upload --bucket "$B1" --key c08/small-parts.bin --query UploadId --output text; then
        uid="$(outv)"
        run s3api upload-part --bucket "$B1" --key c08/small-parts.bin --upload-id "$uid" --part-number 1 --body "$DATA/tiny1.bin" --query ETag --output text
        q1="$(outv | sed 's/"/\\"/g')"
        run s3api upload-part --bucket "$B1" --key c08/small-parts.bin --upload-id "$uid" --part-number 2 --body "$DATA/tiny1.bin" --query ETag --output text
        q2="$(outv | sed 's/"/\\"/g')"
        body="{\"Parts\":[{\"ETag\":\"$q1\",\"PartNumber\":1},{\"ETag\":\"$q2\",\"PartNumber\":2}]}"
        run s3api complete-multipart-upload --bucket "$B1" --key c08/small-parts.bin --upload-id "$uid" --multipart-upload "$body"
        if [ $LAST_RC != 0 ] && grep -q 'EntityTooSmall' "$LAST_ERR"; then
            sub min_part_size_enforced 0
        else
            sub min_part_size_enforced 1 "rc=$LAST_RC $(errcode)"
        fi
        run s3api abort-multipart-upload --bucket "$B1" --key c08/small-parts.bin --upload-id "$uid"
    fi
    conclude
}

t_c09() {
    begin C09 "Object tagging: put, get, header form, delete" || return
    local k="c09/tag.txt"
    putsmall "$B1" "$k"
    if run s3api put-object-tagging --bucket "$B1" --key "$k" --tagging '{"TagSet":[{"Key":"env","Value":"test"},{"Key":"k2","Value":"v2"}]}'; then
        sub put_tagging 0
    else
        sub put_tagging 1 "$(errcode)"; conclude; return
    fi
    run s3api get-object-tagging --bucket "$B1" --key "$k" --query 'length(TagSet)' --output text
    if [ "$(outv)" = 2 ]; then sub get_tagging 0; else sub get_tagging 1 "got=$(outv) $(errcode)"; fi
    if run s3api put-object --bucket "$B1" --key c09/tag2.txt --body "$DATA/small.txt" --tagging "a=b&c=d"; then
        run s3api get-object-tagging --bucket "$B1" --key c09/tag2.txt --query 'length(TagSet)' --output text
        if [ "$(outv)" = 2 ]; then sub tagging_on_put 0; else sub tagging_on_put 1 "got=$(outv)"; fi
    else
        sub tagging_on_put 1 "$(errcode)"
    fi
    run s3api delete-object-tagging --bucket "$B1" --key "$k"
    run s3api get-object-tagging --bucket "$B1" --key "$k" --query 'length(TagSet)' --output text
    if [ "$(outv)" = 0 ]; then sub delete_tagging 0; else sub delete_tagging 1 "got=$(outv) $(errcode)"; fi
    conclude
}

t_c10() {
    begin C10 "Versioning: versions, delete marker, restore" || return
    local b="${RUN}-ver" k="c10/v.txt" old marker
    if ! mkbucket "$b"; then sub create_bucket 1 "$(errcode)"; conclude; return; fi
    if run s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled; then
        sub enable 0
    else
        sub enable 1 "$(errcode)"; conclude; return
    fi
    run s3api get-bucket-versioning --bucket "$b" --query Status --output text
    if [ "$(outv)" = Enabled ]; then sub status_enabled 0; else sub status_enabled 1 "got=$(outv)"; fi
    printf 'one\n' > "$DATA/v1.txt"; printf 'two\n' > "$DATA/v2.txt"
    run s3api put-object --bucket "$b" --key "$k" --body "$DATA/v1.txt"
    run s3api put-object --bucket "$b" --key "$k" --body "$DATA/v2.txt"
    run s3api list-object-versions --bucket "$b" --prefix "$k" --query 'length(Versions)' --output text
    if [ "$(outv)" = 2 ]; then sub two_versions 0; else sub two_versions 1 "got=$(outv) $(errcode)"; fi
    run s3api list-object-versions --bucket "$b" --prefix "$k" --query 'Versions[?IsLatest==`false`].VersionId | [0]' --output text
    old="$(outv)"
    if run s3api get-object --bucket "$b" --key "$k" --version-id "$old" "$T_DIR/old.txt" && cmp -s "$T_DIR/old.txt" "$DATA/v1.txt"; then
        sub get_old_version 0
    else
        sub get_old_version 1 "$(errcode) old=$old"
    fi
    run s3api delete-object --bucket "$b" --key "$k" --query DeleteMarker --output text
    if [ "$(outv)" = True ]; then sub delete_creates_marker 0; else sub delete_creates_marker 1 "got=$(outv) $(errcode)"; fi
    run s3api get-object --bucket "$b" --key "$k" "$T_DIR/hidden.txt"
    if grep -q 'NoSuchKey' "$LAST_ERR"; then sub hidden_behind_marker 0; else sub hidden_behind_marker 1 "$(errcode)"; fi
    run s3api list-object-versions --bucket "$b" --prefix "$k" --query 'DeleteMarkers[0].VersionId' --output text
    marker="$(outv)"
    if run s3api delete-object --bucket "$b" --key "$k" --version-id "$marker" &&
       run s3api get-object --bucket "$b" --key "$k" "$T_DIR/back.txt" && cmp -s "$T_DIR/back.txt" "$DATA/v2.txt"; then
        sub remove_marker_restores 0
    else
        sub remove_marker_restores 1 "$(errcode) marker=$marker"
    fi
    conclude
}

t_c11() {
    begin C11 "Conditional GET: If-Match, If-None-Match, date conditions" || return
    local k="fixture/rand1m.bin" etag
    run s3api head-object --bucket "$B1" --key "$k" --query ETag --output text
    etag="$(outv)"
    if run s3api get-object --bucket "$B1" --key "$k" --if-match "$etag" "$T_DIR/m.bin"; then sub if_match_ok 0; else sub if_match_ok 1 "$(errcode)"; fi
    run s3api get-object --bucket "$B1" --key "$k" --if-none-match "$etag" "$T_DIR/n.bin"
    if [ $LAST_RC != 0 ] && grep -qi '304\|Not Modified' "$LAST_ERR"; then sub if_none_match_304 0; else sub if_none_match_304 1 "rc=$LAST_RC $(errcode)"; fi
    run s3api get-object --bucket "$B1" --key "$k" --if-match '"00000000000000000000000000000000"' "$T_DIR/p.bin"
    if [ $LAST_RC != 0 ] && grep -qi 'PreconditionFailed\|412' "$LAST_ERR"; then sub if_match_mismatch_412 0; else sub if_match_mismatch_412 1 "rc=$LAST_RC $(errcode)"; fi
    run s3api get-object --bucket "$B1" --key "$k" --if-modified-since 2099-01-01T00:00:00Z "$T_DIR/q.bin"
    if [ $LAST_RC != 0 ] && grep -qi '304\|Not Modified' "$LAST_ERR"; then sub if_modified_since_304 0; else sub if_modified_since_304 1 "rc=$LAST_RC $(errcode)"; fi
    run s3api get-object --bucket "$B1" --key "$k" --if-unmodified-since 2000-01-01T00:00:00Z "$T_DIR/r.bin"
    if [ $LAST_RC != 0 ] && grep -qi 'PreconditionFailed\|412' "$LAST_ERR"; then sub if_unmodified_since_412 0; else sub if_unmodified_since_412 1 "rc=$LAST_RC $(errcode)"; fi
    conclude
}

t_c12() {
    begin C12 "Conditional PUT with If-None-Match: * (create only if absent)" || return
    local k="c12/once.txt"
    if run s3api put-object --bucket "$B1" --key "$k" --body "$DATA/small.txt" --if-none-match '*'; then
        sub first_write_accepted 0
    else
        if grep -qi 'Unknown options\|Invalid choice\|unrecognized' "$LAST_ERR"; then
            skip "installed AWS CLI does not have --if-none-match on put-object"; return
        fi
        sub first_write_accepted 1 "$(errcode)"; conclude; return
    fi
    run s3api put-object --bucket "$B1" --key "$k" --body "$DATA/small.txt" --if-none-match '*'
    if [ $LAST_RC != 0 ] && grep -qi 'PreconditionFailed\|412' "$LAST_ERR"; then
        sub second_write_refused 0
    else
        sub second_write_refused 1 "rc=$LAST_RC $(errcode)"
    fi
    conclude
}

t_c13() {
    begin C13 "Presigned GET URL: works, expires, rejects a tampered signature" || return
    local u code sig
    putsmall "$B1" c13/p.txt
    if run s3 presign "s3://$B1/c13/p.txt" --expires-in 60; then
        u="$(outv)"
    else
        sub presign 1 "$(errcode)"; conclude; return
    fi
    runx curl -s -o "$T_DIR/p.out" -w '%{http_code}' --max-time 20 "$u"
    code="$(cat "$LAST_OUT")"
    if [ "$code" = 200 ] && cmp -s "$T_DIR/p.out" "$DATA/small.txt"; then sub fetch_ok 0; else sub fetch_ok 1 "http=$code"; fi
    sig="${u%?}"
    case "${u: -1}" in 0) sig="${sig}1" ;; *) sig="${sig}0" ;; esac
    runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$sig"
    code="$(cat "$LAST_OUT")"
    if [ "$code" = 403 ]; then sub tampered_rejected 0; else sub tampered_rejected 1 "http=$code"; fi
    if run s3 presign "s3://$B1/c13/p.txt" --expires-in 2; then
        u="$(outv)"; sleep 5
        runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$u"
        code="$(cat "$LAST_OUT")"
        if [ "$code" = 403 ]; then sub expired_rejected 0; else sub expired_rejected 1 "http=$code"; fi
    else
        sub expired_rejected 1 "presign: $(errcode)"
    fi
    conclude
}

t_c14() {
    begin C14 "Bucket policy: roundtrip and enforcement for anonymous reads" || return
    local code pol="$DATA/policy.json"
    putsmall "$B1" c14/pub.txt
    printf '{"Version":"2012-10-17","Statement":[{"Sid":"AnonRead","Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::%s/c14/*"]}]}' "$B1" > "$pol"
    runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/c14/pub.txt"
    code="$(cat "$LAST_OUT")"
    if [ "$code" = 403 ]; then sub anonymous_denied_by_default 0; else sub anonymous_denied_by_default 1 "http=$code"; fi
    if run s3api put-bucket-policy --bucket "$B1" --policy "file://$pol"; then
        sub put_policy 0
    else
        sub put_policy 1 "$(errcode) $(errmsg)"; conclude; return
    fi
    run s3api get-bucket-policy --bucket "$B1" --query Policy --output text
    if grep -q AnonRead "$LAST_OUT"; then sub get_policy 0; else sub get_policy 1 "sid not returned $(errcode)"; fi
    runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/c14/pub.txt"
    code="$(cat "$LAST_OUT")"
    if [ "$code" = 200 ]; then sub policy_allows_anonymous_read 0; else sub policy_allows_anonymous_read 1 "http=$code"; fi
    # The policy covers c14/ only, so a key outside it must stay closed.
    runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/fixture/rand1m.bin"
    code="$(cat "$LAST_OUT")"
    if [ "$code" = 403 ]; then sub policy_scoped_to_prefix 0; else sub policy_scoped_to_prefix 1 "http=$code"; fi
    run s3api delete-bucket-policy --bucket "$B1"
    runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/c14/pub.txt"
    code="$(cat "$LAST_OUT")"
    if [ "$code" = 403 ]; then sub delete_policy_revokes 0; else sub delete_policy_revokes 1 "http=$code"; fi
    conclude
}

t_c15() {
    begin C15 "CORS: configuration roundtrip and preflight behaviour" || return
    local cfg="$DATA/cors.json" hdr
    printf '{"CORSRules":[{"AllowedOrigins":["https://example.org"],"AllowedMethods":["GET","PUT"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}' > "$cfg"
    if run s3api put-bucket-cors --bucket "$B1" --cors-configuration "file://$cfg"; then
        sub put_cors 0
    else
        sub put_cors 1 "$(errcode)"; conclude; return
    fi
    run s3api get-bucket-cors --bucket "$B1" --query 'CORSRules[0].AllowedOrigins[0]' --output text
    if [ "$(outv)" = "https://example.org" ]; then sub get_cors 0; else sub get_cors 1 "got=$(outv) $(errcode)"; fi
    runx curl -s -D - -o /dev/null --max-time 20 -X OPTIONS -H "Origin: https://example.org" -H "Access-Control-Request-Method: GET" "$url/fixture/rand1m.bin"
    hdr="$(cat "$LAST_OUT")"
    if printf '%s' "$hdr" | grep -qi '^access-control-allow-origin: https://example.org'; then sub preflight_allowed_origin 0; else sub preflight_allowed_origin 1 "no allow-origin header"; fi
    runx curl -s -D - -o /dev/null --max-time 20 -X OPTIONS -H "Origin: https://evil.example" -H "Access-Control-Request-Method: GET" "$url/fixture/rand1m.bin"
    hdr="$(cat "$LAST_OUT")"
    if ! printf '%s' "$hdr" | grep -q '^HTTP/'; then
        sub preflight_other_origin_refused 1 "no HTTP response received"
    elif printf '%s' "$hdr" | grep -qi '^access-control-allow-origin'; then
        sub preflight_other_origin_refused 1 "allow-origin returned for unlisted origin"
    else
        sub preflight_other_origin_refused 0
    fi
    run s3api delete-bucket-cors --bucket "$B1"
    run s3api get-bucket-cors --bucket "$B1"
    if [ $LAST_RC != 0 ] && grep -q 'NoSuchCORSConfiguration' "$LAST_ERR"; then sub delete_cors 0; else sub delete_cors 1 "rc=$LAST_RC $(errcode)"; fi
    conclude
}

t_c16() {
    begin C16 "Lifecycle configuration roundtrip (enforcement not tested)" || return
    local cfg="$DATA/lifecycle.json"
    printf '{"Rules":[{"ID":"expire-c16","Status":"Enabled","Filter":{"Prefix":"c16/"},"Expiration":{"Days":1}}]}' > "$cfg"
    if run s3api put-bucket-lifecycle-configuration --bucket "$B1" --lifecycle-configuration "file://$cfg"; then
        sub put_lifecycle 0
    else
        sub put_lifecycle 1 "$(errcode) $(errmsg)"; conclude; return
    fi
    run s3api get-bucket-lifecycle-configuration --bucket "$B1" --query 'Rules[0].ID' --output text
    if [ "$(outv)" = expire-c16 ]; then sub get_lifecycle 0; else sub get_lifecycle 1 "got=$(outv) $(errcode)"; fi
    run s3api delete-bucket-lifecycle --bucket "$B1"
    run s3api get-bucket-lifecycle-configuration --bucket "$B1"
    if [ $LAST_RC != 0 ] && grep -q 'NoSuchLifecycleConfiguration' "$LAST_ERR"; then sub delete_lifecycle 0; else sub delete_lifecycle 1 "rc=$LAST_RC $(errcode)"; fi
    conclude
}

t_c17() {
    begin C17 "Object lock (GOVERNANCE): retention enforced, bypass works" || return
    local b="${RUN}-lock" k="c17/locked.txt" retain vid
    if ! mkbucket "$b" --object-lock-enabled-for-bucket; then sub create_lock_bucket 1 "$(errcode) $(errmsg)"; conclude; return; fi
    run s3api get-object-lock-configuration --bucket "$b" --query 'ObjectLockConfiguration.ObjectLockEnabled' --output text
    if [ "$(outv)" = Enabled ]; then sub lock_enabled 0; else sub lock_enabled 1 "got=$(outv) $(errcode)"; fi
    retain="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
    if run s3api put-object --bucket "$b" --key "$k" --body "$DATA/small.txt" \
            --object-lock-mode GOVERNANCE --object-lock-retain-until-date "$retain" --query VersionId --output text; then
        vid="$(outv)"; sub put_locked 0
    else
        sub put_locked 1 "$(errcode)"; conclude; return
    fi
    run s3api head-object --bucket "$b" --key "$k" --query ObjectLockMode --output text
    if [ "$(outv)" = GOVERNANCE ]; then sub mode_returned 0; else sub mode_returned 1 "got=$(outv)"; fi
    run s3api delete-object --bucket "$b" --key "$k" --version-id "$vid"
    if [ $LAST_RC != 0 ] && grep -qi 'AccessDenied' "$LAST_ERR"; then sub delete_blocked 0; else sub delete_blocked 1 "rc=$LAST_RC $(errcode)"; fi
    if run s3api delete-object --bucket "$b" --key "$k" --version-id "$vid" --bypass-governance-retention; then sub bypass_allowed 0; else sub bypass_allowed 1 "$(errcode)"; fi
    conclude
}

t_c18() {
    begin C18 "SSE-S3 header and bucket default encryption (API only, at-rest not verified)" || return
    local k="c18/sse.bin"
    if run s3api put-object --bucket "$B1" --key "$k" --body "$DATA/rand1m.bin" --server-side-encryption AES256; then
        sub put_sse 0
    else
        sub put_sse 1 "$(errcode) $(errmsg)"
    fi
    run s3api head-object --bucket "$B1" --key "$k" --query ServerSideEncryption --output text
    if [ "$(outv)" = AES256 ]; then sub sse_echoed 0; else sub sse_echoed 1 "got=$(outv)"; fi
    if run s3api get-object --bucket "$B1" --key "$k" "$T_DIR/sse.bin" && cmp -s "$T_DIR/sse.bin" "$DATA/rand1m.bin"; then sub sse_roundtrip 0; else sub sse_roundtrip 1 "$(errcode)"; fi
    if run s3api put-bucket-encryption --bucket "$B1" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'; then
        run s3api get-bucket-encryption --bucket "$B1" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text
        if [ "$(outv)" = AES256 ]; then sub bucket_default_roundtrip 0; else sub bucket_default_roundtrip 1 "got=$(outv)"; fi
        run s3api delete-bucket-encryption --bucket "$B1"
    else
        sub bucket_default_roundtrip 1 "$(errcode)"
    fi
    conclude
}

t_c19() {
    begin C19 "ACLs: read, canned public-read, enforcement, revert to private (flat and prefixed keys)" || return
    local k code which
    run s3api get-bucket-acl --bucket "$B1" --query 'length(Grants)' --output text
    if [ $LAST_RC = 0 ]; then sub get_bucket_acl 0; else sub get_bucket_acl 1 "$(errcode)"; fi
    # A key with no path prefix and one with a prefix are tested separately. An earlier run
    # showed the ACL call failing for a prefixed key while working for a flat one, so a single
    # key would hide which case a system handles.
    for which in flat prefixed; do
        if [ $which = flat ]; then k="c19-flat.txt"; else k="c19/acl.txt"; fi
        putsmall "$B1" "$k"
        if run s3api put-object-acl --bucket "$B1" --key "$k" --acl public-read; then
            sub "put_acl_$which" 0
        else
            sub "put_acl_$which" 1 "$(errcode)"; continue
        fi
        run s3api get-object-acl --bucket "$B1" --key "$k" --query 'Grants[].Grantee.URI' --output text
        if grep -q 'global/AllUsers' "$LAST_OUT"; then sub "allusers_grant_listed_$which" 0; else sub "allusers_grant_listed_$which" 1 "grant not shown"; fi
        runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/$k"
        code="$(cat "$LAST_OUT")"
        if [ "$code" = 200 ]; then sub "public_read_enforced_$which" 0; else sub "public_read_enforced_$which" 1 "http=$code"; fi
        run s3api put-object-acl --bucket "$B1" --key "$k" --acl private
        runx curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url/$k"
        code="$(cat "$LAST_OUT")"
        if [ "$code" = 403 ]; then sub "private_restores_denial_$which" 0; else sub "private_restores_denial_$which" 1 "http=$code"; fi
    done
    conclude
}

t_c20() {
    begin C20 "Integrity checksums: default CLI upload, algorithms, bad values refused" || return
    local alg f local_sum got zero
    if run s3 cp "$DATA/rand1m.bin" "s3://$B1/c20/cp.bin" && run s3 cp "s3://$B1/c20/cp.bin" "$T_DIR/cp.bin" && cmp -s "$T_DIR/cp.bin" "$DATA/rand1m.bin"; then
        sub default_cli_upload 0
    else
        sub default_cli_upload 1 "$(errcode) $(errmsg)"
    fi
    for alg in CRC32 CRC32C CRC64NVME SHA1 SHA256; do
        if run s3api put-object --bucket "$B1" --key "c20/$alg.bin" --body "$DATA/rand1m.bin" --checksum-algorithm "$alg"; then
            run s3api get-object --bucket "$B1" --key "c20/$alg.bin" --checksum-mode ENABLED --query "Checksum$alg" --output text "$T_DIR/$alg.bin"
            got="$(outv)"
            local_sum=""
            case "$alg" in
                SHA256) local_sum="$(openssl dgst -sha256 -binary "$DATA/rand1m.bin" | base64)" ;;
                SHA1) local_sum="$(openssl dgst -sha1 -binary "$DATA/rand1m.bin" | base64)" ;;
            esac
            if [ -z "$got" ] || [ "$got" = None ]; then
                sub "$alg" 1 "accepted but checksum not returned"
            elif [ -n "$local_sum" ] && [ "$got" != "$local_sum" ]; then
                sub "$alg" 1 "returned $got expected $local_sum"
            else
                sub "$alg" 0
            fi
        else
            if grep -qi 'Invalid choice\|Unknown options' "$LAST_ERR"; then
                SUBS="$SUBS $alg:n/a(installed CLI lacks this algorithm)"
            else
                sub "$alg" 1 "$(errcode)"
            fi
        fi
    done
    # A server that verifies integrity must refuse a body that does not match the digest sent with it.
    zero="$(head -c 32 /dev/zero | base64)"
    run s3api put-object --bucket "$B1" --key c20/badsha.bin --body "$DATA/rand1m.bin" --checksum-sha256 "$zero"
    if [ $LAST_RC != 0 ] && grep -qE 'BadDigest|InvalidDigest|InvalidRequest|BadRequest|XAmzContentSHA256Mismatch|400' "$LAST_ERR"; then
        sub wrong_sha256_refused 0
    else
        sub wrong_sha256_refused 1 "rc=$LAST_RC $(errcode)"
    fi
    run s3api put-object --bucket "$B1" --key c20/badmd5.bin --body "$DATA/rand1m.bin" --content-md5 "$(head -c 16 /dev/zero | base64)"
    if [ $LAST_RC != 0 ] && grep -q 'BadDigest\|InvalidDigest' "$LAST_ERR"; then sub wrong_md5_refused 0; else sub wrong_md5_refused 1 "rc=$LAST_RC $(errcode)"; fi
    conclude
}

t_c21() {
    begin C21 "Awkward object keys: symbols, depth, folder marker, component and total length" || return
    local i n bad=0 stored=0 cnt parts many
    local -a labels keys
    many="c21/"
    for parts in 1 2 3 4 5 6 7 8 9; do many="$many$(head -c 100 /dev/zero | tr '\0' 'b')/"; done
    many="${many}end"
    labels=(space unicode symbols percent deep_path trailing_slash component_255 component_256 total_917_in_10_parts)
    keys=("c21/sp ace.txt" "c21/üñí-ünï.txt" "c21/a+b=c&d.txt" "c21/pct%20x.txt" "c21/deep/a/b/c/d/e.txt" "c21/dir-marker/"
          "c21/$(head -c 255 /dev/zero | tr '\0' 'k')" "c21/$(head -c 256 /dev/zero | tr '\0' 'k')" "$many")
    n=0
    for i in "${!keys[@]}"; do
        n=$((n + 1))
        if run s3api put-object --bucket "$B1" --key "${keys[$i]}" --body "$DATA/small.txt"; then
            stored=$((stored + 1))
            if run s3api get-object --bucket "$B1" --key "${keys[$i]}" "$T_DIR/k$n.bin" && cmp -s "$T_DIR/k$n.bin" "$DATA/small.txt"; then
                :
            else
                bad=$((bad + 1)); sub "${labels[$i]}" 1 "get returned different bytes or failed: $(errcode)"
            fi
        else
            bad=$((bad + 1)); sub "${labels[$i]}" 1 "put: $(errcode)"
        fi
    done
    [ $bad = 0 ] && sub all_keys_roundtrip 0
    # Counted from the listed keys, not KeyCount, see the note in C07. The expectation is the
    # number of keys the server accepted, so a refused key is reported once above, not twice.
    run s3api list-objects-v2 --bucket "$B1" --prefix c21/ --query 'length(Contents)' --output text
    cnt="$(outv)"
    if [ "$cnt" = "$stored" ]; then sub listing_count 0; else sub listing_count 1 "listed=$cnt accepted=$stored"; fi
    conclude
}

t_c22() {
    begin C22 "Error code fidelity against documented AWS S3 codes" || return
    local b="${RUN}-c22"
    run s3api get-object --bucket "$B1" --key c22/does-not-exist "$T_DIR/x.bin"
    if grep -q 'NoSuchKey' "$LAST_ERR"; then sub missing_key_NoSuchKey 0; else sub missing_key_NoSuchKey 1 "$(errcode)"; fi
    run s3api get-object --bucket "${RUN}-no-such-bucket" --key x "$T_DIR/x.bin"
    if grep -q 'NoSuchBucket' "$LAST_ERR"; then sub missing_bucket_NoSuchBucket 0; else sub missing_bucket_NoSuchBucket 1 "$(errcode)"; fi
    run s3api head-object --bucket "$B1" --key c22/does-not-exist
    if grep -q '404\|Not Found' "$LAST_ERR"; then sub head_missing_404 0; else sub head_missing_404 1 "$(errcode)"; fi
    # Re-creating your own bucket: AWS us-east-1 returns success, others BucketAlreadyOwnedByYou.
    run s3api create-bucket --bucket "$B1"
    if [ $LAST_RC = 0 ] || grep -q 'BucketAlreadyOwnedByYou\|BucketAlreadyExists' "$LAST_ERR"; then sub recreate_own_bucket 0; else sub recreate_own_bucket 1 "$(errcode)"; fi
    # A bucket that still holds an object must refuse deletion with BucketNotEmpty. The bucket is
    # built here with one known object and listed just before the call, so the state at the moment
    # of deletion is part of the saved evidence and does not have to be assumed.
    if mkbucket "$b" && putsmall "$b" sentinel.txt; then
        run s3api list-objects-v2 --bucket "$b" --query 'Contents[].Key' --output text
        if [ "$(outv)" = sentinel.txt ]; then sub nonempty_precondition 0; else sub nonempty_precondition 1 "listing=$(outv)"; fi
        run s3api delete-bucket --bucket "$b"
        if [ $LAST_RC != 0 ] && grep -q 'BucketNotEmpty' "$LAST_ERR"; then
            sub delete_nonempty_BucketNotEmpty 0
            run s3api delete-object --bucket "$b" --key sentinel.txt
        else
            sub delete_nonempty_BucketNotEmpty 1 "rc=$LAST_RC $(errcode)"
            if [ $LAST_RC = 0 ]; then
                # The server reported success. Recreate the bucket and see whether the object survived.
                if mkbucket "$b"; then
                    run s3api list-objects-v2 --bucket "$b" --query 'Contents[].Key' --output text
                    if [ "$(outv)" = sentinel.txt ]; then sub data_survives_delete 0; else sub data_survives_delete 1 "after delete and recreate, listing=$(outv)"; fi
                else
                    sub data_survives_delete 1 "could not recreate bucket: $(errcode)"
                fi
            fi
        fi
        aws_ s3api delete-object --bucket "$b" --key sentinel.txt >/dev/null 2>&1
        aws_ s3api delete-bucket --bucket "$b" >/dev/null 2>&1
    else
        sub nonempty_setup 1 "$(errcode)"
    fi
    # Passes the client side name check but not the S3 naming rules, so the server has to refuse it.
    run s3api create-bucket --bucket "Bad_Name_${RUN}"
    if [ $LAST_RC != 0 ] && grep -q 'InvalidBucketName' "$LAST_ERR"; then
        sub invalid_bucket_name 0
    else
        sub invalid_bucket_name 1 "rc=$LAST_RC $(errcode)"
        aws_ s3api delete-bucket --bucket "Bad_Name_${RUN}" >/dev/null 2>&1
    fi
    run s3api delete-bucket --bucket "${RUN}-never-created"
    if [ $LAST_RC != 0 ] && grep -q 'NoSuchBucket' "$LAST_ERR"; then sub delete_missing_bucket 0; else sub delete_missing_bucket 1 "rc=$LAST_RC $(errcode)"; fi
    conclude
}

for id in $TESTS; do
    "t_$(printf '%s' "$id" | tr 'C' 'c')"
done

# The random test payloads and the copies read back from the server are several
# MB per run and add nothing once compared. Their checksums stay in env.txt; the
# commands and raw server replies stay in evidence/. S3C_KEEP_BIN=1 keeps them.
{
    echo "--- input data sha256 ---"
    (cd "$DATA" && sha256sum ./*.bin small.txt)
} >> "$OUT/env.txt"
if [ "${S3C_KEEP_BIN:-0}" != 1 ]; then
    rm -rf "$DATA"
    find "$OUT/evidence" -name '*.bin' -delete
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "== summary for $S3C_NAME"
for v in PASS FAIL UNSUPPORTED SKIP; do
    printf '%-12s %s\n' "$v" "$(cut -f2 "$SUMMARY" | grep -c "^$v\$")"
done
echo "results:  $SUMMARY"
echo "evidence: $OUT/evidence/"
echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/env.txt"
