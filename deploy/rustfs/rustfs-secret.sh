#!/usr/bin/env bash
#
# Creates the shared RustFS config on THIS VM, or prints the fingerprints of an existing one.
#
#   bash rustfs-secret.sh create       makes /root/rustfs-config/ (run on ONE VM only)
#   bash rustfs-secret.sh fingerprint  prints mode, size and sha256 of the two files
#
# The directory holds two files, both mode 600, neither is ever printed:
#   rustfs.env            RUSTFS_ACCESS_KEY and RUSTFS_SECRET_KEY, handed to the container with --env-file
#   s3_credentials.txt    the same keys as two labelled lines, for the test scripts
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
    fingerprint)
        [ -d "$D" ] || { echo "rustfs-secret: $D missing" >&2; exit 1; }
        hostname
        stat -c '%a %s %n' "$D" "$D"/*
        sha256sum "$D"/*
        ;;
    *)
        echo "usage: $0 create|fingerprint" >&2
        exit 64
        ;;
esac
