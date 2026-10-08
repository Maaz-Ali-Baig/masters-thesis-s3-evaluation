#!/usr/bin/env bash
#
# SeaweedFS 3 node deployment, step 2 of 2. Run as root on ceph0, after seaweedfs-node.sh ran on all
# three VMs and the masters have elected a leader.
#
#   bash seaweedfs-roundtrip.sh
#
# Proves that the three S3 endpoints serve the same data: objects written through one node are read
# back through the other two and compared by sha256, in both directions, with two sizes. It also
# prints the cluster topology (volume servers) and the leader. Uses the key in
# /root/seaweedfs-config/s3_credentials.txt (never printed) and the AWS CLI in /opt/aws-cli-new (the
# same pinned 2.36.8 as for the Ceph runs). Output goes to stdout and to
# /root/seaweedfs-roundtrip-<time>.txt.

set -u

AWS=/opt/aws-cli-new/bin/aws
KEYFILE=/root/seaweedfs-config/s3_credentials.txt
B="rtbucket-$RANDOM$RANDOM"
EP0=http://192.168.1.72:8333
EP1=http://192.168.1.71:8333
EP2=http://192.168.1.70:8333
OUT="/root/seaweedfs-roundtrip-$(date +%Y%m%d-%H%M%S).txt"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

[ -x "$AWS" ] || { echo "seaweedfs-roundtrip: $AWS missing" >&2; exit 1; }
[ -s "$KEYFILE" ] || { echo "seaweedfs-roundtrip: $KEYFILE missing" >&2; exit 1; }
AK="$(awk -F': *' '/^Access key:/{print $2}' "$KEYFILE")"
SK="$(awk -F': *' '/^Secret key:/{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || { echo "seaweedfs-roundtrip: cannot parse $KEYFILE" >&2; exit 1; }

a() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION=us-east-1 "$AWS" "$@"; }

{
echo "seaweedfs-roundtrip  host=$(hostname)  date=$(date -u +%FT%TZ)"
echo "endpoints: $EP0 $EP1 $EP2   bucket: $B"
echo "leader: $(curl -fsS http://192.168.1.72:9333/cluster/status 2>&1 | grep -oE '"Leader":"[^"]*"')"
echo "volume servers: $(curl -fsS http://192.168.1.72:9333/dir/status 2>&1 | grep -oE '"Url":"[^"]*"' | tr '\n' ' ')"
head -c 1024 /dev/urandom > "$T/small.bin"
head -c 1048576 /dev/urandom > "$T/mib.bin"
fail=0
if ! a --endpoint-url "$EP0" s3api create-bucket --bucket "$B" >/dev/null 2>"$T/err"; then
    echo "FAIL create bucket: $(head -c 200 "$T/err")"; fail=1
fi
sleep 2
check() { # label, endpoint written, endpoint read, file
    local lbl="$1" w="$2" r="$3" f="$4" k
    k="rt-$(basename "$f")-$$-$RANDOM"
    if ! a --endpoint-url "$w" s3api put-object --bucket "$B" --key "$k" --body "$f" >/dev/null 2>"$T/err"; then
        echo "FAIL $lbl put: $(head -c 200 "$T/err")"; fail=1; return
    fi
    if ! a --endpoint-url "$r" s3api get-object --bucket "$B" --key "$k" "$T/back" >/dev/null 2>"$T/err"; then
        echo "FAIL $lbl get: $(head -c 200 "$T/err")"; fail=1; return
    fi
    if [ "$(sha256sum < "$f")" = "$(sha256sum < "$T/back")" ]; then
        echo "PASS $lbl  $(basename "$f")  sha256 $(sha256sum < "$f" | cut -c1-16)"
    else
        echo "FAIL $lbl  $(basename "$f")  content differs"; fail=1
    fi
    a --endpoint-url "$w" s3api delete-object --bucket "$B" --key "$k" >/dev/null 2>&1
}
for f in "$T/small.bin" "$T/mib.bin"; do
    check "write ceph0 read ceph1" "$EP0" "$EP1" "$f"
    check "write ceph0 read ceph2" "$EP0" "$EP2" "$f"
    check "write ceph1 read ceph0" "$EP1" "$EP0" "$f"
    check "write ceph1 read ceph2" "$EP1" "$EP2" "$f"
    check "write ceph2 read ceph0" "$EP2" "$EP0" "$f"
    check "write ceph2 read ceph1" "$EP2" "$EP1" "$f"
done
for e in "$EP0" "$EP1" "$EP2"; do
    printf 'list %s ' "$e"
    if a --endpoint-url "$e" s3api list-objects-v2 --bucket "$B" --query 'length(Contents || `[]`)' --output text 2>"$T/err"; then :; else echo "FAIL $(head -c 200 "$T/err")"; fail=1; fi
done
a --endpoint-url "$EP0" s3api delete-bucket --bucket "$B" >/dev/null 2>&1 || echo "note: bucket $B not deleted"
if [ "$fail" = 0 ]; then echo "RESULT all passed"; else echo "RESULT failures, see FAIL lines"; fi
} 2>&1 | tee "$OUT"
echo "saved: $OUT"
sha256sum "$OUT"
