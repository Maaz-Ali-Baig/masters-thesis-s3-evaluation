#!/usr/bin/env bash
#
# Runs the S3 compatibility probe, or the ACL read check, against the Ceph RGW. Run as root on
# ceph0 ONLY, with the cluster running.
#
#   bash ceph-tests.sh compat   the 22 test S3 compatibility probe (scripts/s3-compat.sh)
#   bash ceph-tests.sh acl      ACL read of an object with ?acl and ?acl= (curl 7.88.1) and with the AWS CLI
#
# Same pattern as deploy/garage/garage-tests.sh: the probe is fetched from the public repository at
# a pinned commit and must have the expected sha256 (the file of the VM runs of the other three
# systems). Keys are read from /root/ceph-s3-credentials.txt, handed to the test inline and never
# printed. Endpoint: the RGW on ceph0 itself (localhost:80), region us-east-1, AWS CLI 2.36.8 in
# /opt/aws-cli-new. Before the run it prints the cluster health (read only).
#
# Output stays on ceph0 under /root/<mode>-ceph-vm-<time>/ and /root/<...>.tar.gz.

set -eu

COMMIT="c798c4d0ec8d7bb5288463802399572a6ff8a178"
RAW="https://raw.githubusercontent.com/Maaz-Ali-Baig/masters-thesis-s3-evaluation/$COMMIT/scripts"
SHA_COMPAT="6dabde8fbb8b9c166563595fa50ec29c98c7159d27b632d42552c45daf3e762d"
KEYFILE=/root/ceph-s3-credentials.txt
TS="$(date +%Y%m%d-%H%M%S)"
DIR=/root/ceph-deploy/tests

die() { echo "ceph-tests: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ "$(hostname -I | awk '{print $1}')" = "192.168.1.72" ] || die "run this on ceph0 (192.168.1.72)"
[ -s "$KEYFILE" ] || die "$KEYFILE missing"
[ -x /opt/aws-cli-new/bin/aws ] || die "/opt/aws-cli-new/bin/aws missing"
MODE="${1:-}"
case "$MODE" in compat|acl) ;; *) die "usage: $0 compat|acl" ;; esac

AK="$(awk -F': *' '/^Access key:/{print $2}' "$KEYFILE")"
SK="$(awk -F': *' '/^Secret key:/{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || die "cannot parse $KEYFILE"
export PATH=/opt/aws-cli-new/bin:$PATH
OUT="/root/$MODE-ceph-vm-$TS"
mkdir -p "$OUT" "$DIR"
cd "$OUT"

{
    echo "host: $(hostname) $(hostname -I | awk '{print $1}')  time: $(date -u +%FT%TZ) UTC"
    echo "aws: $(aws --version 2>&1 | head -1)   curl: $(curl --version | head -1)"
    echo "== ceph health detail"
    cephadm shell -- ceph health detail 2>&1 | head -40
    echo "== ceph versions"
    cephadm shell -- ceph versions 2>&1 | head -30
    echo "== ceph orch ps (non running daemons)"
    cephadm shell -- ceph orch ps 2>&1 | awk 'NR==1 || $0 !~ /running/' | head -20
} 2>&1 | tee "$OUT/cluster-state.txt"

set +e
if [ "$MODE" = compat ]; then
    curl -fsSL -o "$DIR/s3-compat.sh" "$RAW/s3-compat.sh" || die "download failed"
    GOT="$(sha256sum "$DIR/s3-compat.sh" | awk '{print $1}')"
    echo "script: s3-compat.sh  commit: $COMMIT  sha256 $GOT"
    [ "$GOT" = "$SHA_COMPAT" ] || die "sha256 differs from the expected $SHA_COMPAT"
    echo "script hash equals the expected one"
    export S3C_NAME="ceph-vm" S3C_ENDPOINT="http://localhost:80" S3C_KEY="$AK" S3C_SECRET="$SK"
    export S3C_REGION="us-east-1" S3C_OUTDIR="$OUT/run" S3C_NOTE="Ceph 20.2.4, 3 nodes, 6 OSDs, replicated 3, VMs, endpoint ceph0"
    bash "$DIR/s3-compat.sh" 2>&1 | tee "$OUT/console.txt"
    unset S3C_KEY S3C_SECRET
    if [ -f "$OUT/run/summary.tsv" ]; then
        echo "== summary.tsv"
        cat "$OUT/run/summary.tsv"
        sha256sum "$OUT/run/summary.tsv"
    fi
else
    EP="http://localhost:80"
    B="aclprobe$$"
    EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    aws --endpoint-url "$EP" --region us-east-1 s3api create-bucket --bucket "$B" >/dev/null 2>"$OUT/create.err"; echo "create bucket rc=$?"
    echo hi > "$OUT/k.txt"
    aws --endpoint-url "$EP" --region us-east-1 s3api put-object --bucket "$B" --key k.txt --body "$OUT/k.txt" >/dev/null 2>"$OUT/put.err"; echo "put object rc=$?"
    sig() {  # $1 = path with optional query; prints HTTP status and the first 100 characters of the error code line
        curl -s -o "$OUT/body.tmp" -w "HTTP %{http_code}" --aws-sigv4 "aws:amz:us-east-1:s3" -u "$AK:$SK" \
            -H "x-amz-content-sha256: $EMPTY" "$EP/$1"
        echo "  $(grep -o '<Code>[^<]*</Code>\|<AccessControlPolicy' "$OUT/body.tmp" | head -1)"
    }
    echo "curl GET key, no query    : $(sig "$B/k.txt")"
    echo "curl GET key?acl          : $(sig "$B/k.txt?acl")"
    echo "curl GET key?acl=         : $(sig "$B/k.txt?acl=")"
    echo "aws s3api get-object-acl  : grants $(aws --endpoint-url "$EP" --region us-east-1 s3api get-object-acl --bucket "$B" --key k.txt --query 'length(Grants)' --output text 2>&1 | head -c 100)"
    aws --endpoint-url "$EP" --region us-east-1 s3api delete-object --bucket "$B" --key k.txt >/dev/null 2>&1; echo "delete object rc=$?"
    aws --endpoint-url "$EP" --region us-east-1 s3api delete-bucket --bucket "$B" >/dev/null 2>&1; echo "delete bucket rc=$?"
    rm -f "$OUT/body.tmp" "$OUT/k.txt"
fi
set -e

echo "== end of run"
echo "output folder: $OUT"
echo "files containing the secret key (must be 0): $(grep -rlF "$SK" "$OUT" 2>/dev/null | wc -l)"
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "archive: $OUT.tar.gz $(stat -c %s "$OUT.tar.gz") bytes"
sha256sum "$OUT.tar.gz"
