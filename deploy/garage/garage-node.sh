#!/usr/bin/env bash
#
# Garage 3 node deployment, step 1 of 3. Run as root on EACH VM (ceph0, ceph1, ceph2).
#
#   bash garage-node.sh
#
# Prerequisites on the VM:
#   - /srv/s3/disk1 and /srv/s3/disk2 are mounted (XFS, 32 GB each)
#   - /root/garage-rpc-secret exists, mode 600, 64 hex characters, IDENTICAL on all three VMs
#     (create it with garage-secret.sh, never print it)
#   - Ceph is stopped (one system at a time on the VMs)
#
# What it does: writes /etc/garage/garage.toml, starts one Garage v1.0.0 container with podman
# on the host network, and prints this node's id. Data goes to /srv/s3/disk1/garage and
# /srv/s3/disk2/garage. The image is pinned by the digest recorded for the laptop image, so the
# build is identical on the laptop and on the VMs.
#
# Settings that mirror the laptop deployment: lmdb, s3_region "garage", root_domain, admin API on
# 3902. Settings that differ on purpose: replication_factor 3 (the laptop ran 1) and two data
# directories per node (the laptop had one).

set -eu

IMAGE="docker.io/dxflrs/garage@sha256:0c7ed80d22c0b0f902fbd0ec74fc68073f72a46ea15d54e3c4c484184a8c7516"
SECRET_FILE="/root/garage-rpc-secret"
D1="/srv/s3/disk1/garage"
D2="/srv/s3/disk2/garage"

die() { echo "garage-node: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
command -v podman >/dev/null || die "podman not found"
mountpoint -q /srv/s3/disk1 || die "/srv/s3/disk1 is not mounted"
mountpoint -q /srv/s3/disk2 || die "/srv/s3/disk2 is not mounted"
[ -s "$SECRET_FILE" ] || die "$SECRET_FILE missing, create it with garage-secret.sh"
[ "$(tr -d '\n' < "$SECRET_FILE" | wc -c)" = 64 ] || die "$SECRET_FILE is not 64 characters"

HOST="$(hostname)"
IP="$(hostname -I | awk '{print $1}')"
case "$IP" in
    192.168.1.70|192.168.1.71|192.168.1.72) ;;
    *) die "unexpected address '$IP', this script is for the three thesis VMs" ;;
esac

if systemctl is-active --quiet ceph-377124a6-acb5-11f1-b854-bc2411d95a65.target; then
    die "Ceph is still running on this node, stop it first"
fi

echo "== node: $HOST $IP"
echo "== image: $IMAGE"

mkdir -p /etc/garage "$D1/meta" "$D1/data" "$D2/data"
umask 077
cat > /etc/garage/garage.toml <<EOF
metadata_dir = "$D1/meta"
data_dir = [
    { path = "$D1/data", capacity = "30G" },
    { path = "$D2/data", capacity = "30G" },
]
db_engine = "lmdb"
replication_factor = 3
rpc_bind_addr = "[::]:3901"
rpc_public_addr = "$IP:3901"
rpc_secret = "$(tr -d '\n' < "$SECRET_FILE")"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "0.0.0.0:3902"
EOF
chmod 600 /etc/garage/garage.toml

podman rm -f garage >/dev/null 2>&1 || true
podman run -d --name garage --network host --restart no \
    -v /etc/garage/garage.toml:/etc/garage.toml:ro \
    -v "$D1":"$D1" \
    -v "$D2":"$D2" \
    "$IMAGE" /garage -c /etc/garage.toml server >/dev/null

for i in 1 2 3 4 5 6 7 8 9 10; do
    if podman exec garage /garage -c /etc/garage.toml node id >/tmp/garage-nodeid.txt 2>&1; then break; fi
    sleep 2
done

echo "== container"
podman ps --filter name=garage --format '{{.Names}} {{.Status}}'
echo "== node id (id@address, this is not a secret)"
grep -oE '[0-9a-f]{64}@[^ ]+' /tmp/garage-nodeid.txt || cat /tmp/garage-nodeid.txt
echo "== log tail"
podman logs --tail 6 garage 2>&1
echo "== config fingerprint (secret line removed)"
grep -v '^rpc_secret' /etc/garage/garage.toml | sha256sum
