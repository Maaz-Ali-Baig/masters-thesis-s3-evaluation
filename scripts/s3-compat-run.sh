#!/usr/bin/env bash
#
# Run the S3 compatibility probe against one of the three local systems.
#
#   ./scripts/s3-compat-run.sh sw            # SeaweedFS
#   ./scripts/s3-compat-run.sh rf            # RustFS
#   ./scripts/s3-compat-run.sh ga            # Garage
#   ./scripts/s3-compat-run.sh sw --only C08 # one test only
#
# Credentials come from ~/.thesis-s3-env (the same file s3-helpers.sh uses) and
# are passed to the probe inline for this one invocation. Nothing is exported,
# so there is nothing to unset afterwards and no leakage into the next system.
# Output goes to results/compat-<system>-<timestamp>/ in the repository.
#
# For Ceph the probe is run on the VM instead, see scripts/README.md.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENVFILE="${THESIS_S3_ENV:-$HOME/.thesis-s3-env}"

if [ $# -lt 1 ]; then
    echo "usage: $0 <sw|rf|ga> [s3-compat.sh options]" >&2
    exit 64
fi
if [ ! -f "$ENVFILE" ]; then
    echo "s3-compat-run: $ENVFILE not found (see scripts/README.md)" >&2
    exit 66
fi
# shellcheck disable=SC1090
. "$ENVFILE"

sys="$1"
shift
case "$sys" in
    sw) name=seaweedfs; key="$SW_KEY"; secret="$SW_SECRET"; region="$SW_REGION"; endpoint="$SW_ENDPOINT" ;;
    rf) name=rustfs;    key="$RF_KEY"; secret="$RF_SECRET"; region="$RF_REGION"; endpoint="$RF_ENDPOINT" ;;
    ga) name=garage;    key="$GA_KEY"; secret="$GA_SECRET"; region="$GA_REGION"; endpoint="$GA_ENDPOINT" ;;
    *) echo "unknown system '$sys', use sw, rf or ga" >&2; exit 64 ;;
esac

S3C_NAME="$name" S3C_ENDPOINT="$endpoint" S3C_KEY="$key" S3C_SECRET="$secret" S3C_REGION="$region" \
S3C_OUTDIR="$ROOT/results/compat-$name-$(date +%Y%m%d-%H%M%S)" \
    bash "$HERE/s3-compat.sh" "$@"
