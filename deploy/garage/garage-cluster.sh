#!/usr/bin/env bash
#
# Garage 3 node deployment, step 2 of 3. Run as root on ceph0 ONLY, after garage-node.sh ran on
# all three VMs.
#
#   bash garage-cluster.sh <id@ip:3901 of ceph1> <id@ip:3901 of ceph2>
#
# The two arguments are the "id@address" strings that garage-node.sh printed on ceph1 and ceph2.
# This node's own id is read from the local container.
#
# What it does: connects the nodes, assigns one zone per node (so replication factor 3 puts one
# copy in each zone), applies the layout, creates the S3 key and the test bucket, and grants the
# key access. The key file /root/garage-key.txt contains the secret key (mode 600, never printed).
#
# Names mirror the laptop: key "thesis-key", bucket "thesis-test-bucket". The key also gets
# --create-bucket, because the compatibility probe creates its own buckets.

set -eu

[ "$(id -u)" = 0 ] || { echo "garage-cluster: run as root" >&2; exit 1; }
[ $# -eq 2 ] || { echo "usage: $0 <id@ip:3901 ceph1> <id@ip:3901 ceph2>" >&2; exit 64; }
PEER1="$1"; PEER2="$2"
for p in "$PEER1" "$PEER2"; do
    echo "$p" | grep -qE '^[0-9a-f]{64}@[0-9.]+:3901$' || { echo "garage-cluster: bad node string '$p'" >&2; exit 64; }
done
[ "$(hostname -I | awk '{print $1}')" = "192.168.1.72" ] || { echo "garage-cluster: run this on ceph0 (192.168.1.72)" >&2; exit 1; }

G() { podman exec garage /garage -c /etc/garage.toml "$@"; }

ID0="$(G node id 2>&1 | grep -oE '^[0-9a-f]{64}' | head -1)"
ID1="${PEER1%%@*}"
ID2="${PEER2%%@*}"
[ -n "$ID0" ] || { echo "garage-cluster: cannot read the local node id" >&2; exit 1; }

echo "== connect"
G node connect "$PEER1"
G node connect "$PEER2"
sleep 4
echo "== status before the layout"
G status

echo "== layout (one zone per node, capacity 60G = two data dirs of 30G)"
# the node id must come BEFORE the flags: -t takes several values and would swallow it (tested on v1.0.0)
G layout assign "$ID0" -z z1 -c 60GB -t ceph0
G layout assign "$ID1" -z z2 -c 60GB -t ceph1
G layout assign "$ID2" -z z3 -c 60GB -t ceph2
G layout show
G layout apply --version 1
sleep 3
G layout show

echo "== key and bucket"
umask 077
G key create thesis-key > /root/garage-key.txt
chmod 600 /root/garage-key.txt
G bucket create thesis-test-bucket
G bucket allow --read --write --owner thesis-test-bucket --key thesis-key | sed -E 's/^(Secret key: ).*/\1<hidden>/'
# "garage key allow" prints the secret key in clear (seen on v1.0.0), so every key command is masked
G key allow --create-bucket thesis-key | sed -E 's/^(Secret key: ).*/\1<hidden>/'
G key info thesis-key | sed -E 's/^(Secret key: ).*/\1<hidden>/'
echo "(secret key is only in /root/garage-key.txt)"

echo "== final status"
G status
