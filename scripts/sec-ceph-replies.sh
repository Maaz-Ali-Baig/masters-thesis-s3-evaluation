#!/usr/bin/env bash
#
# Raw server replies for the Ceph security checks in which the AWS CLI 2.36.8 crashed with "argument of type 'NoneType' is not a container
# or iterable" (results/aws-cli-crash-on-ceph-error-replies-2026-10-02.txt): the crash text hides the HTTP status. Each call runs with --debug
# and only the HTTP status line and the <Code> of the reply are kept (the debug text with the Authorization header is never printed or stored).
# Also: (a) the scoped user gets max_buckets -1 (in RGW 0 means unlimited, -1 refuses bucket creation, rgw_op.cc check_owner_max_buckets v20.2.4),
# (b) stray test buckets of the scoped user are removed, (c) the search for the fake access key in the RGW container logs is repeated with a
# positive control (a string that must be in the log if requests are logged at all).
#
#   bash sec-ceph-replies.sh
#
# Run as root on ceph0. Needs /root/ceph-s3-credentials.txt and /root/secscoped.env (SCOPED_AK, SCOPED_SK). Keys are never printed.
# Output: /root/sec-ceph-replies-<time>/replies.txt, summary.txt, SHA256SUMS and the .tar.gz.

set -u
export PATH=/opt/aws-cli-new/bin:$PATH
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required AWS_MAX_ATTEMPTS=1
KEYFILE=/root/ceph-s3-credentials.txt
HOST=192.168.1.72:80
B=ftbucket
NODES="192.168.1.72 192.168.1.71 192.168.1.70"
SSHOPT="-o BatchMode=yes -o ConnectTimeout=5"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v aws >/dev/null || { echo "aws cli not found" >&2; exit 1; }
# shellcheck disable=SC1091
. /root/secscoped.env
AK="$(awk -F': *' '$1=="Access key"{print $2}' "$KEYFILE")"
SK="$(awk -F': *' '$1=="Secret key"{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] && [ -n "${SCOPED_AK:-}" ] && [ -n "${SCOPED_SK:-}" ] || { echo "keys missing" >&2; exit 1; }
OUT="/root/sec-ceph-replies-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/replies.txt"
FAKE="SECPROBE$(date +%s)FAKE"
log() { echo "$*" | tee -a "$LOG"; }

# reply <label> <access key> <secret key> <aws arguments...>: one line with the http status and the error code of the last reply
reply() {
    local label="$1" ak="$2" sk="$3" o st cd; shift 3
    o="$(AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_DEFAULT_REGION=us-east-1 \
        aws --endpoint-url "http://$HOST" --cli-connect-timeout 4 --cli-read-timeout 20 --debug "$@" 2>&1)"
    st="$(printf '%s\n' "$o" | grep -o 'HTTP/1\.1" [0-9][0-9][0-9]' | tail -1 | awk '{print $2}')"
    cd="$(printf '%s\n' "$o" | grep -o '<Code>[^<]*</Code>' | tail -1 | sed 's/<[^>]*>//g')"
    log "$label: http ${st:-none} code ${cd:-none}"
}

log "host: $(hostname)  time: $(date '+%F %T %z')  s3 endpoint: $HOST  bucket: $B  aws: $(aws --version 2>&1 | cut -c1-60)"
log "fake access key (not a real key): $FAKE"
printf 'reply test\n' > "$OUT/body.tmp"

log "== setup"
log "scoped user max_buckets before: $(cephadm shell -- radosgw-admin user info --uid=secscoped 2>/dev/null | grep -m1 '"max_buckets"' | tr -d ' ,')"
cephadm shell -- radosgw-admin user modify --uid=secscoped --max-buckets=-1 >/dev/null 2>&1 || log "user modify failed"
log "scoped user max_buckets after: $(cephadm shell -- radosgw-admin user info --uid=secscoped 2>/dev/null | grep -m1 '"max_buckets"' | tr -d ' ,')"
for b in $(cephadm shell -- radosgw-admin bucket list --uid=secscoped 2>/dev/null | grep -o '"secnew[0-9]*"' | tr -d '"'); do
    cephadm shell -- radosgw-admin bucket rm --bucket="$b" --purge-objects >/dev/null 2>&1 && log "removed stray test bucket $b" || log "could not remove $b"
done
reply "admin puts the delete target sec-reply-del.txt (control, expect 200)" "$AK" "$SK" s3api put-object --bucket "$B" --key sec-reply-del.txt --body "$OUT/body.tmp"

log "== authentication (sec3 repeated)"
reply "right access key, wrong secret, list objects" "$AK" "WRONGSECRETWRONGSECRETWRONGSECRET0000" s3api list-objects-v2 --bucket "$B" --max-keys 1
reply "fake access key, wrong secret, list objects" "$FAKE" "WRONGSECRETWRONGSECRETWRONGSECRET0000" s3api list-objects-v2 --bucket "$B" --max-keys 1
reply "fake access key, list buckets" "$FAKE" "WRONGSECRETWRONGSECRETWRONGSECRET0000" s3api list-buckets
reply "admin key, list objects (control, expect 200)" "$AK" "$SK" s3api list-objects-v2 --bucket "$B" --max-keys 1

log "== scoped key (sec4 repeated, read only bucket policy on $B)"
reply "scoped key, list objects (expect 200)" "$SCOPED_AK" "$SCOPED_SK" s3api list-objects-v2 --bucket "$B" --max-keys 1
reply "scoped key, get sec-reply-del.txt (expect 200)" "$SCOPED_AK" "$SCOPED_SK" s3api get-object --bucket "$B" --key sec-reply-del.txt "$OUT/get.tmp"
reply "scoped key, put object new.txt" "$SCOPED_AK" "$SCOPED_SK" s3api put-object --bucket "$B" --key new.txt --body "$OUT/body.tmp"
reply "scoped key, delete sec-reply-del.txt" "$SCOPED_AK" "$SCOPED_SK" s3api delete-object --bucket "$B" --key sec-reply-del.txt
log "object sec-reply-del.txt still there after the scoped delete: $(AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url "http://$HOST" s3api head-object --bucket "$B" --key sec-reply-del.txt --query ContentLength --output text 2>&1 | cut -c1-80)"
NEWB="secnew$(date +%s)"
reply "scoped key, create bucket $NEWB (max_buckets -1)" "$SCOPED_AK" "$SCOPED_SK" s3api create-bucket --bucket "$NEWB"
if cephadm shell -- radosgw-admin bucket list --uid=secscoped 2>/dev/null | grep -q "\"$NEWB\""; then
    log "bucket $NEWB EXISTS after the attempt"
    cephadm shell -- radosgw-admin bucket rm --bucket="$NEWB" --purge-objects >/dev/null 2>&1 && log "removed $NEWB"
else
    log "bucket $NEWB does not exist after the attempt"
fi

log "== encryption headers over plain http (sec6 repeated)"
reply "plain put (control, expect 200)" "$AK" "$SK" s3api put-object --bucket "$B" --key sec-reply-plain.txt --body "$OUT/body.tmp"
reply "SSE-S3 put (header AES256)" "$AK" "$SK" s3api put-object --bucket "$B" --key sec-reply-sses.txt --body "$OUT/body.tmp" --server-side-encryption AES256
reply "SSE-C put (customer key, http)" "$AK" "$SK" s3api put-object --bucket "$B" --key sec-reply-ssec.txt --body "$OUT/body.tmp" --sse-customer-algorithm AES256 --sse-customer-key "$(openssl rand -hex 16)"
for k in sec-reply-plain.txt sec-reply-sses.txt sec-reply-ssec.txt sec-reply-del.txt; do
    AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url "http://$HOST" s3api delete-object --bucket "$B" --key "$k" >/dev/null 2>&1
done

log "== container log search (sec8 repeated, with a positive control)"
for ip in $NODES; do
    r="$(ssh $SSHOPT "root@$ip" "for c in \$(podman ps --format '{{.Names}}' | grep rgw); do echo \"\$c fake:\$(podman logs \$c 2>&1 | grep -c '$FAKE') ftbucket:\$(podman logs \$c 2>&1 | grep -c ftbucket) lines:\$(podman logs \$c 2>&1 | wc -l)\"; done" 2>&1 | paste -sd';')"
    log "rgw containers on $ip (name, lines with the fake key, lines with the string $B, total lines): ${r:-none}"
done
rm -f "$OUT/body.tmp" "$OUT/get.tmp"

{
    echo "== end of run, output folder $OUT"
    echo "secret key found in output files (must be 0): $(grep -rlF "$SK" "$OUT" 2>/dev/null | wc -l)"
    echo "access key found in output files (must be 0): $(grep -rlF "$AK" "$OUT" 2>/dev/null | wc -l)"
    echo "scoped secret found in output files (must be 0): $(grep -rlF "$SCOPED_SK" "$OUT" 2>/dev/null | wc -l)"
} | tee "$OUT/summary.txt"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "archive: $OUT.tar.gz $(stat -c %s "$OUT.tar.gz") bytes"; sha256sum "$OUT.tar.gz"
