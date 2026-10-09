#!/usr/bin/env bash
#
# RustFS 3 node deployment, step 1 of 2. Run as root on EACH VM (ceph0, ceph1, ceph2), the three runs
# within a minute of each other (the nodes wait for each other when they start).
#
#   bash rustfs-node.sh
#
# Prerequisites on the VM:
#   - /srv/s3/disk1 and /srv/s3/disk2 are mounted (XFS, 32 GB each)
#   - /root/rustfs-config exists and is IDENTICAL on all three VMs (rustfs-secret.sh)
#   - Ceph, Garage and SeaweedFS are stopped (one system at a time on the VMs)
#
# Image: RustFS 1.0.1 (tag 1.0.1 = latest on 8 October 2026). The laptop image 1.0.0-beta.8 (sha256
# fa19210ac469...) crashed on all VMs with "trap invalid opcode" (exit 132): its erasure coding crate
# reed-solomon-erasure uses the AVX2 instruction vbroadcasti128 in reedsolomon_gal_mul, and the VM CPU
# (QEMU Virtual CPU 2.5+) has no AVX2. 1.0.1 is the redo, see setup_notes.md.
#
# What it does: starts one RustFS container with podman on the host network. The volume list
# names all six drives of the cluster (three nodes, two drives each), so RustFS forms one erasure coded
# set over the six drives. The vendor documentation gives EC:3 (3 data and 3 parity shards) as the default
# for 6 drives, two shards per node, and says that distributed mode needs at least 4 servers. We have 3 and
# the thesis needs the same number of nodes for every system, so this is a test of what RustFS does with
# 3 nodes. If it refuses to start, that is the result, and it is reported to Prof. Baun, not worked around.
#
# The container process runs as the user rustfs (uid 10001, no su-exec step in the entrypoint), so the
# script gives uid 10001 the two data directories. The keys are read from the env file, never printed.

set -eu

IMAGE="docker.io/rustfs/rustfs@sha256:1803faef57627e2d9c2e7d89d655d712ddded5389040054987163043fecb6a3c"
CFG="/root/rustfs-config"
D1="/srv/s3/disk1/rustfs"
D2="/srv/s3/disk2/rustfs"
VOLUMES="http://192.168.1.{70...72}:9000/srv/s3/disk{1...2}/rustfs"

die() { echo "rustfs-node: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
command -v podman >/dev/null || die "podman not found"
mountpoint -q /srv/s3/disk1 || die "/srv/s3/disk1 is not mounted"
mountpoint -q /srv/s3/disk2 || die "/srv/s3/disk2 is not mounted"
[ -s "$CFG/rustfs.env" ] && [ -s "$CFG/s3_credentials.txt" ] || die "$CFG is incomplete, create it with rustfs-secret.sh"

HOST="$(hostname)"
IP="$(hostname -I | awk '{print $1}')"
case "$IP" in
    192.168.1.70|192.168.1.71|192.168.1.72) ;;
    *) die "unexpected address '$IP', this script is for the three thesis VMs" ;;
esac

if systemctl is-active --quiet ceph-377124a6-acb5-11f1-b854-bc2411d95a65.target; then
    die "Ceph is still running on this node, stop it first"
fi
for other in garage seaweedfs; do
    if [ -n "$(podman ps -q --filter name=^${other}\$)" ]; then
        die "container '$other' is running on this node, stop it first (one system at a time)"
    fi
done

echo "== node: $HOST $IP"
echo "== image: $IMAGE"
# Optional SSE-S3 master key (rustfs-secret.sh sse), the same file on all three nodes. Not printed.
SSE_ARGS=()
if [ -s "$CFG/sse.env" ]; then
    SSE_ARGS=(--env-file "$CFG/sse.env")
    echo "== sse.env: present, passed to the container"
else
    echo "== sse.env: absent"
fi

mkdir -p "$D1" "$D2"
chown 10001:10001 "$D1" "$D2"
podman rm -f rustfs >/dev/null 2>&1 || true
podman run -d --name rustfs --network host --restart no \
    --env-file "$CFG/rustfs.env" \
    "${SSE_ARGS[@]}" \
    -e RUSTFS_VOLUMES="$VOLUMES" \
    -e RUSTFS_ADDRESS=":9000" \
    -e RUSTFS_CONSOLE_ENABLE=true \
    -e RUSTFS_CONSOLE_ADDRESS=":9001" \
    -v "$D1":"$D1" \
    -v "$D2":"$D2" \
    "$IMAGE" >/dev/null

ok=0
code=000
for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:9000/" 2>/dev/null || true)"
    if [ "$code" != "000" ]; then ok=1; break; fi
    if [ -z "$(podman ps -q --filter name=^rustfs\$)" ]; then break; fi
    sleep 2
done

echo "== container"
podman ps --all --filter name=rustfs --format '{{.Names}} {{.Status}}'
echo "== port 9000 answered: $ok (http code $code)"
echo "== version"
podman exec rustfs /usr/bin/rustfs --version 2>&1 | head -2 || true
echo "== log tail (200 characters per line)"
podman logs --tail 15 rustfs 2>&1 | cut -c1-200
