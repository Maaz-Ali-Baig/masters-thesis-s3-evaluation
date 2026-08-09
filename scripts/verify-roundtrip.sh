#!/usr/bin/env bash
#
# S3 round-trip integrity verification for all three lightweight systems.
#
#   ./scripts/verify-roundtrip.sh            # 1 MiB test object (default)
#   ./scripts/verify-roundtrip.sh 50K        # smaller
#   ./scripts/verify-roundtrip.sh 100M       # larger, exercises multipart
#
# For each system it writes a file of random bytes, records its MD5, uploads it,
# lists it, downloads it to a fresh path, recomputes the MD5, and compares.
#
# Why MD5 rather than diff: a checksum is a fixed-size fingerprint that can be
# recorded once and compared later without retaining the original file, which is
# what the replication and failure testing needs. It also follows Wernicke (2017),
# the Baun/Gabel-supervised precursor thesis, which used MD5 checksums for the
# same purpose - giving methodological continuity worth citing.
#
# Random content is used deliberately: a file of repeated identical bytes could
# be silently deduplicated or compressed by a storage system and still return a
# matching checksum, which would not prove the full path worked.

set -uo pipefail

SIZE="${1:-1M}"
BUCKET="thesis-test-bucket"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-helpers.sh"

printf '%-11s %-10s %-34s %-34s %s\n' SYSTEM SIZE 'MD5 UPLOADED' 'MD5 RETRIEVED' RESULT
printf '%.0s-' {1..110}; echo

overall=0

verify() {
    local name="$1" fn="$2"
    local src="$WORKDIR/${name}-src.bin"
    local dst="$WORKDIR/${name}-dst.bin"
    local key="verify-${name}-${STAMP}.bin"

    # random content, so a deduplicating or compressing backend cannot fake a match
    head -c "$(numfmt --from=iec "$SIZE")" /dev/urandom > "$src" 2>/dev/null

    local md5_src md5_dst result
    md5_src="$(md5sum "$src" | cut -d' ' -f1)"

    if ! "$fn" s3 cp "$src" "s3://$BUCKET/$key" >/dev/null 2>&1; then
        printf '%-11s %-10s %-34s %-34s %s\n' "$name" "$SIZE" "$md5_src" '-' 'FAIL (upload)'
        overall=1; return
    fi

    if ! "$fn" s3 ls "s3://$BUCKET/$key" >/dev/null 2>&1; then
        printf '%-11s %-10s %-34s %-34s %s\n' "$name" "$SIZE" "$md5_src" '-' 'FAIL (not listed)'
        overall=1
        "$fn" s3 rm "s3://$BUCKET/$key" >/dev/null 2>&1
        return
    fi

    if ! "$fn" s3 cp "s3://$BUCKET/$key" "$dst" >/dev/null 2>&1; then
        printf '%-11s %-10s %-34s %-34s %s\n' "$name" "$SIZE" "$md5_src" '-' 'FAIL (download)'
        overall=1
        "$fn" s3 rm "s3://$BUCKET/$key" >/dev/null 2>&1
        return
    fi

    md5_dst="$(md5sum "$dst" | cut -d' ' -f1)"
    if [ "$md5_src" = "$md5_dst" ]; then
        result='PASS'
    else
        result='FAIL (checksum mismatch)'
        overall=1
    fi
    printf '%-11s %-10s %-34s %-34s %s\n' "$name" "$SIZE" "$md5_src" "$md5_dst" "$result"

    # leave the testbed as we found it
    "$fn" s3 rm "s3://$BUCKET/$key" >/dev/null 2>&1
}

verify SeaweedFS s3sw
verify RustFS    s3rf
verify Garage    s3ga

echo
if [ "$overall" -eq 0 ]; then
    echo "All systems verified: uploaded and retrieved objects are byte-identical."
else
    echo "One or more systems FAILED. Do not benchmark until this is resolved."
fi
exit "$overall"
