#!/usr/bin/env bash
#
# Per-system S3 client helpers for the thesis testbed.
#
# Usage:
#   source scripts/s3-helpers.sh
#   s3sw s3 ls                            # SeaweedFS
#   s3rf s3 ls                            # RustFS
#   s3ga s3 ls s3://thesis-test-bucket/   # Garage
#   s3check                               # reachability of all three endpoints
#   s3info                                # show configured endpoints (no secrets)
#
# Why per-command credentials rather than `export`:
# each system needs different credentials AND a different region. Exporting
# AWS_ACCESS_KEY_ID in a long-lived terminal leaks the last-used system's
# credentials into the next command, which fails in confusing ways (an
# authentication error against the wrong backend looks like a broken system).
# These functions scope credentials to a single invocation, so nothing
# persists in the shell and there is nothing to unset.
#
# Credentials are read from ~/.thesis-s3-env, which is deliberately OUTSIDE
# the repository so secrets are never committed. See configs/README.md.

_THESIS_S3_ENV="${THESIS_S3_ENV:-$HOME/.thesis-s3-env}"

if [ -f "$_THESIS_S3_ENV" ]; then
    # shellcheck disable=SC1090
    . "$_THESIS_S3_ENV"
else
    echo "s3-helpers: $_THESIS_S3_ENV not found." >&2
    echo "  Create it with the per-system keys (see configs/README.md)." >&2
    echo "  Garage secret: docker exec garage /garage key info thesis-key --show-secret" >&2
fi

# SeaweedFS - port 8333
s3sw() {
    AWS_ACCESS_KEY_ID="$SW_KEY" \
    AWS_SECRET_ACCESS_KEY="$SW_SECRET" \
    AWS_DEFAULT_REGION="$SW_REGION" \
    aws --endpoint-url "$SW_ENDPOINT" "$@"
}

# RustFS - port 9000
s3rf() {
    AWS_ACCESS_KEY_ID="$RF_KEY" \
    AWS_SECRET_ACCESS_KEY="$RF_SECRET" \
    AWS_DEFAULT_REGION="$RF_REGION" \
    aws --endpoint-url "$RF_ENDPOINT" "$@"
}

# Garage - port 3900. Region must match s3_region in garage.toml, otherwise
# SigV4 signing fails with AuthorizationHeaderMalformed.
s3ga() {
    AWS_ACCESS_KEY_ID="$GA_KEY" \
    AWS_SECRET_ACCESS_KEY="$GA_SECRET" \
    AWS_DEFAULT_REGION="$GA_REGION" \
    aws --endpoint-url "$GA_ENDPOINT" "$@"
}

# Reachability check for all three endpoints. HTTP 403 is a healthy answer:
# the server is alive and speaking S3, it just wants authentication.
# No response means the container may be up while its API is unreachable,
# which is the failure signature of setup_notes.md Issues 1 and 4.
s3check() {
    local name endpoint
    for pair in "SeaweedFS:$SW_ENDPOINT" "RustFS:$RF_ENDPOINT" "Garage:$GA_ENDPOINT"; do
        name="${pair%%:*}"
        endpoint="${pair#*:}"
        printf '%-11s %-24s ' "$name" "$endpoint"
        curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 "$endpoint/" \
            || echo 'NO RESPONSE'
    done
}

# Show what is configured, without printing any secret.
s3info() {
    printf '%-11s %-24s %-12s %s\n' SYSTEM ENDPOINT REGION 'ACCESS KEY'
    printf '%-11s %-24s %-12s %s\n' SeaweedFS "$SW_ENDPOINT" "$SW_REGION" "$SW_KEY"
    printf '%-11s %-24s %-12s %s\n' RustFS    "$RF_ENDPOINT" "$RF_REGION" "$RF_KEY"
    printf '%-11s %-24s %-12s %s\n' Garage    "$GA_ENDPOINT" "$GA_REGION" "$GA_KEY"
}
