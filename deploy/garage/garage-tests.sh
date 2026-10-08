#!/usr/bin/env bash
#
# Runs one of the two thesis test scripts against the three node Garage cluster. Run as root on
# ceph0 ONLY, after garage-cluster.sh.
#
#   bash garage-tests.sh compat     the 22 test S3 compatibility probe (scripts/s3-compat.sh)
#   bash garage-tests.sh presign    the presigned PUT unsigned header test
#
# The test scripts are fetched from the public repository at a pinned commit and must have the
# expected sha256, so the VM runs exactly the file that ran on the laptop and on Ceph. The key is
# read from /root/garage-key.txt and handed to the test inline, it is never printed. The endpoint
# is the Garage node on ceph0 itself (as the Ceph runs used the gateway on localhost), region
# "garage". The AWS CLI is the pinned 2.36.8 in /opt/aws-cli-new.
#
# Output stays on ceph0 under /root/<mode>-garage-vm-<time>/ and /root/<...>.tar.gz.

set -eu

COMMIT="c798c4d0ec8d7bb5288463802399572a6ff8a178"
RAW="https://raw.githubusercontent.com/Maaz-Ali-Baig/masters-thesis-s3-evaluation/$COMMIT/scripts"
SHA_COMPAT="6dabde8fbb8b9c166563595fa50ec29c98c7159d27b632d42552c45daf3e762d"
SHA_PRESIGN="f1678fc1e4f2559eb33d1c59d3b2e520b97882aa488f27ec4e5aa943a4d0ab92"
KEYFILE=/root/garage-key.txt
TS="$(date +%Y%m%d-%H%M%S)"
DIR=/root/garage-deploy/tests

die() { echo "garage-tests: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ "$(hostname -I | awk '{print $1}')" = "192.168.1.72" ] || die "run this on ceph0 (192.168.1.72)"
[ -s "$KEYFILE" ] || die "$KEYFILE missing"
[ -x /opt/aws-cli-new/bin/aws ] || die "/opt/aws-cli-new/bin/aws missing"
MODE="${1:-}"
case "$MODE" in
    compat)  FILE=s3-compat.sh;                      WANT="$SHA_COMPAT" ;;
    presign) FILE=security-presign-unsigned-header.sh; WANT="$SHA_PRESIGN" ;;
    *) die "usage: $0 compat|presign" ;;
esac

mkdir -p "$DIR"
curl -fsSL -o "$DIR/$FILE" "$RAW/$FILE"
GOT="$(sha256sum "$DIR/$FILE" | awk '{print $1}')"
echo "host: $(hostname)  script: $FILE  commit: $COMMIT"
echo "sha256 $GOT"
[ "$GOT" = "$WANT" ] || die "sha256 differs from the expected $WANT"
echo "script hash equals the expected one"

AK="$(awk -F': *' '/^Key ID:/{print $2}' "$KEYFILE")"
SK="$(awk -F': *' '/^Secret key:/{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || die "cannot parse $KEYFILE"
export PATH=/opt/aws-cli-new/bin:$PATH
echo "aws: $(aws --version 2>&1 | head -1)"

OUT="/root/$MODE-garage-vm-$TS"
mkdir -p "$OUT"
export S3C_NAME="garage-vm" S3C_ENDPOINT="http://localhost:3900" S3C_KEY="$AK" S3C_SECRET="$SK"
export S3C_REGION="garage" S3C_OUTDIR="$OUT/run" S3C_NOTE="Garage v1.0.0, 3 nodes, replication factor 3, VMs, endpoint ceph0"
cd "$OUT"
set +e
if [ "$MODE" = compat ]; then
    bash "$DIR/$FILE" 2>&1 | tee "$OUT/console.txt"
else
    mkdir -p "$OUT/run"
    bash "$DIR/$FILE" 2>&1 | tee "$OUT/console.txt"
fi
set -e
unset S3C_KEY S3C_SECRET

echo "== end of run"
echo "output folder: $OUT"
echo "files containing the secret key (must be 0): $(grep -rlF "$SK" "$OUT" 2>/dev/null | wc -l)"
if [ "$MODE" = compat ] && [ -f "$OUT/run/summary.tsv" ]; then
    echo "== summary.tsv"
    cat "$OUT/run/summary.tsv"
    sha256sum "$OUT/run/summary.tsv"
fi
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "archive: $OUT.tar.gz $(stat -c %s "$OUT.tar.gz") bytes"
sha256sum "$OUT.tar.gz"
