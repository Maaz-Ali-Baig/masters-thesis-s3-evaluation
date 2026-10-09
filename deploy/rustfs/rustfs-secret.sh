#!/usr/bin/env bash
#
# Creates the shared RustFS config on THIS VM, or prints the fingerprints of an existing one.
#
#   bash rustfs-secret.sh create       makes /root/rustfs-config/ (run on ONE VM only)
#   bash rustfs-secret.sh sse          adds sse.env, the SSE-S3 master key (run on ONE VM only, after create)
#   bash rustfs-secret.sh fingerprint  prints mode, size and sha256 of every file in the directory
#
# The directory holds these files, all mode 600, none of them is ever printed:
#   rustfs.env            RUSTFS_ACCESS_KEY and RUSTFS_SECRET_KEY, handed to the container with --env-file
#   s3_credentials.txt    the same keys as two labelled lines, for the test scripts
#   sse.env               RUSTFS_SSE_S3_MASTER_KEY, a base64 encoded 32 byte key (added by "sse"). Without KMS
#                         RustFS 1.0.1 refuses SSE-S3 requests without it (compat test C18, 9 October 2026).
#                         rustfs-node.sh passes the file to the container when it exists.
#
# RustFS needs the same root key on all nodes. The directory has to be copied to the other two VMs by a
# route that does not show the content (scp typed by the user), and the fingerprints must then be
# identical on all three.

set -eu
D="/root/rustfs-config"

case "${1:-}" in
    create)
        [ ! -e "$D" ] || { echo "rustfs-secret: $D exists, not overwriting" >&2; exit 1; }
        umask 077
        mkdir -p "$D"
        AK="$(openssl rand -hex 10)"; SK="$(openssl rand -hex 20)"
        printf 'RUSTFS_ACCESS_KEY=%s\nRUSTFS_SECRET_KEY=%s\n' "$AK" "$SK" > "$D/rustfs.env"
        printf 'Access key: %s\nSecret key: %s\n' "$AK" "$SK" > "$D/s3_credentials.txt"
        chmod 700 "$D"; chmod 600 "$D"/*
        echo "created $D"
        stat -c '%a %s %n' "$D"/*
        sha256sum "$D"/*
        ;;
    sse)
        [ -d "$D" ] || { echo "rustfs-secret: $D missing, run create first" >&2; exit 1; }
        [ ! -e "$D/sse.env" ] || { echo "rustfs-secret: $D/sse.env exists, not overwriting" >&2; exit 1; }
        umask 077
        printf 'RUSTFS_SSE_S3_MASTER_KEY=%s\n' "$(openssl rand -base64 32)" > "$D/sse.env"
        chmod 600 "$D/sse.env"
        echo "created $D/sse.env"
        stat -c '%a %s %n' "$D/sse.env"
        sha256sum "$D/sse.env"
        ;;
    fingerprint)
        [ -d "$D" ] || { echo "rustfs-secret: $D missing" >&2; exit 1; }
        hostname
        stat -c '%a %s %n' "$D" "$D"/*
        sha256sum "$D"/*
        ;;
    *)
        echo "usage: $0 create|sse|fingerprint" >&2
        exit 64
        ;;
esac
