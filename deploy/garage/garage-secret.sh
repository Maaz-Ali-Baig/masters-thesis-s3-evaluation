#!/usr/bin/env bash
#
# Creates the shared Garage RPC secret on THIS VM, or prints the fingerprint of an existing one.
#
#   bash garage-secret.sh create       generates /root/garage-rpc-secret (mode 600), run on ONE VM only
#   bash garage-secret.sh fingerprint  prints the sha256 of the file, to compare the three VMs
#
# The secret is never printed. Garage needs the same rpc_secret on every node, so the file made on
# one VM has to be copied to the other two by a route that does not show it in a chat or a log, and
# the fingerprints must then match on all three.

set -eu
F="/root/garage-rpc-secret"

case "${1:-}" in
    create)
        [ ! -e "$F" ] || { echo "garage-secret: $F exists, not overwriting" >&2; exit 1; }
        umask 077
        openssl rand -hex 32 > "$F"
        chmod 600 "$F"
        echo "created $F ($(wc -c < "$F") bytes incl. newline)"
        sha256sum "$F"
        ;;
    fingerprint)
        [ -s "$F" ] || { echo "garage-secret: $F missing" >&2; exit 1; }
        hostname
        stat -c '%a %s %n' "$F"
        sha256sum "$F"
        ;;
    *)
        echo "usage: $0 create|fingerprint" >&2
        exit 64
        ;;
esac
