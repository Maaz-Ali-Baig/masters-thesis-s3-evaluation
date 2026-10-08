#!/usr/bin/env bash
#
# Creates the shared SeaweedFS config on THIS VM, or prints the fingerprints of an existing one.
#
#   bash seaweedfs-secret.sh create       makes /root/seaweedfs-config/ (run on ONE VM only)
#   bash seaweedfs-secret.sh fingerprint  prints mode, size and sha256 of the three files
#
# The directory holds three files, all mode 600, none of them is ever printed:
#   security.toml         JWT signing keys (master, volume servers and filers must share them)
#   s3_config.json        the S3 identity every S3 gateway uses (same identity on all nodes)
#   s3_credentials.txt    the same access key and secret key as two labelled lines, for the test scripts
#
# The directory has to be copied to the other two VMs by a route that does not show the content
# (scp typed by the user), and the fingerprints must then be identical on all three.

set -eu
D="/root/seaweedfs-config"

case "${1:-}" in
    create)
        [ ! -e "$D" ] || { echo "seaweedfs-secret: $D exists, not overwriting" >&2; exit 1; }
        umask 077
        mkdir -p "$D"
        K1="$(openssl rand -hex 32)"; K2="$(openssl rand -hex 32)"; K3="$(openssl rand -hex 32)"
        AK="$(openssl rand -hex 10)"; SK="$(openssl rand -hex 20)"
        cat > "$D/security.toml" <<EOF
[jwt.signing]
key = "$K1"
expires_after_seconds = 10

[access]
ui = false

[filer.expose_directory_metadata]
enabled = true

[jwt.signing.read]
key = "$K2"
expires_after_seconds = 10

# Required: without this key the S3 gateway IAM subsystem fails to start (setup_notes.md, Issue 2)
[jwt.filer_signing]
key = "$K3"
expires_after_seconds = 10
EOF
        cat > "$D/s3_config.json" <<EOF
{
  "identities": [
    {
      "name": "thesis-test-user",
      "credentials": [ { "accessKey": "$AK", "secretKey": "$SK" } ],
      "actions": [ "Admin", "Read", "Write" ]
    }
  ]
}
EOF
        printf 'Access key: %s\nSecret key: %s\n' "$AK" "$SK" > "$D/s3_credentials.txt"
        chmod 700 "$D"; chmod 600 "$D"/*
        echo "created $D"
        stat -c '%a %s %n' "$D"/*
        sha256sum "$D"/*
        ;;
    fingerprint)
        [ -d "$D" ] || { echo "seaweedfs-secret: $D missing" >&2; exit 1; }
        hostname
        stat -c '%a %s %n' "$D" "$D"/*
        sha256sum "$D"/*
        ;;
    *)
        echo "usage: $0 create|fingerprint" >&2
        exit 64
        ;;
esac
