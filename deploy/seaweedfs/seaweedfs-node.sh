#!/usr/bin/env bash
#
# SeaweedFS 3 node deployment, step 1 of 2. Run as root on EACH VM (ceph0, ceph1, ceph2).
#
#   bash seaweedfs-node.sh
#
# Prerequisites on the VM:
#   - /srv/s3/disk1 and /srv/s3/disk2 are mounted (XFS, 32 GB each)
#   - /root/seaweedfs-config exists and is IDENTICAL on all three VMs (seaweedfs-secret.sh)
#   - Ceph, Garage and RustFS are stopped (one system at a time on the VMs)
#
# What it does: starts one SeaweedFS 4.25 container with podman on the host network. Every node runs
# a master, a volume server, a filer and an S3 gateway (`weed server -filer -s3`). The three masters
# find each other through -master.peers, so the quorum is 3 of 3 masters (2 are needed). Replication
# is 002: two more copies on other volume servers in the same rack, so three copies on three nodes.
#
# Flags tested on the laptop (6 October 2026 setup, 8 October 2026 test, three containers on one
# Docker network with the same image digest): the cluster forms, an object written through the S3
# endpoint of one node is readable through the other two, and a bucket made on one node is listed on
# another (so the embedded filer stores do share metadata, the hypothesis of the design is settled
# for the laptop, not yet for the VMs). Differences from the laptop test: host network instead of a
# Docker network, and -ip is the node address.
#
# Deliberate setting: -master.volumeSizeLimitMB=1024. The default is 30000 (30 GB), which does not fit
# the 32 GB disks. The laptop single node run used the default.

set -eu

IMAGE="docker.io/chrislusf/seaweedfs@sha256:c42a5268ca13fcb65e0fae925886b107f4bf294d8db15e1be5509d55104eb509"
CFG="/root/seaweedfs-config"
D1="/srv/s3/disk1/seaweedfs"
D2="/srv/s3/disk2/seaweedfs"
PEERS="192.168.1.70:9333,192.168.1.71:9333,192.168.1.72:9333"

die() { echo "seaweedfs-node: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
command -v podman >/dev/null || die "podman not found"
mountpoint -q /srv/s3/disk1 || die "/srv/s3/disk1 is not mounted"
mountpoint -q /srv/s3/disk2 || die "/srv/s3/disk2 is not mounted"
[ -s "$CFG/security.toml" ] && [ -s "$CFG/s3_config.json" ] || die "$CFG is incomplete, create it with seaweedfs-secret.sh"

HOST="$(hostname)"
IP="$(hostname -I | awk '{print $1}')"
case "$IP" in
    192.168.1.70|192.168.1.71|192.168.1.72) ;;
    *) die "unexpected address '$IP', this script is for the three thesis VMs" ;;
esac

if systemctl is-active --quiet ceph-377124a6-acb5-11f1-b854-bc2411d95a65.target; then
    die "Ceph is still running on this node, stop it first"
fi
for other in garage rustfs; do
    if [ -n "$(podman ps -q --filter name=^${other}\$)" ]; then
        die "container '$other' is running on this node, stop it first (one system at a time)"
    fi
done

echo "== node: $HOST $IP"
echo "== image: $IMAGE"

mkdir -p "$D1" "$D2"
podman rm -f seaweedfs >/dev/null 2>&1 || true
podman run -d --name seaweedfs --network host --restart no \
    -v "$CFG":/etc/seaweedfs:ro \
    -v "$D1":"$D1" \
    -v "$D2":"$D2" \
    "$IMAGE" server -ip="$IP" -master.peers="$PEERS" \
    -dir="$D1,$D2" -volume.max=0,0 -master.volumeSizeLimitMB=1024 \
    -master.defaultReplication=002 -dataCenter=dc1 -rack=rack1 \
    -filer -s3 -s3.config=/etc/seaweedfs/s3_config.json >/dev/null

ok=0
for i in $(seq 1 30); do
    if curl -fsS "http://$IP:9333/cluster/status" >/tmp/seaweedfs-status.json 2>/dev/null; then ok=1; break; fi
    sleep 2
done

echo "== container"
podman ps --all --filter name=seaweedfs --format '{{.Names}} {{.Status}}'
echo "== master status (answered: $ok)"
cat /tmp/seaweedfs-status.json 2>/dev/null; echo
echo "== version"
podman exec seaweedfs weed version 2>&1 | head -3
echo "== log tail"
podman logs --tail 6 seaweedfs 2>&1
