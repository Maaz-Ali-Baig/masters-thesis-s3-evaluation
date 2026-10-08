# SeaweedFS on the three VMs

Three node SeaweedFS 4.25 on ceph0, ceph1 and ceph2 (192.168.1.72, .71, .70), one system at a time with
Ceph, Garage and RustFS stopped. The design and the reasons for each setting are in `setup_notes.md`
(section "Three node layouts"). The image is pinned by digest, the same digest as the laptop image.

Order (all run as root on the VM named in the first column):

| VM | Script | What it does |
|---|---|---|
| ceph0 | `seaweedfs-secret.sh create` | makes `/root/seaweedfs-config/` (JWT keys, S3 identity), never printed |
| ceph0 | copy the directory to ceph1 and ceph2 | `scp -r` typed by the user, then `seaweedfs-secret.sh fingerprint` must give the same sha256 on all three |
| all | `seaweedfs-node.sh` | starts master, volume server, filer and S3 gateway in one container |
| ceph0 | `seaweedfs-roundtrip.sh` | writes through each node, reads through the other two, sha256 compared |
| all | `seaweedfs-stop.sh` | stops and removes the container, data is kept |

Settings that differ from the laptop single node run, on purpose:
`-master.volumeSizeLimitMB=1024` (default 30000 does not fit 32 GB disks), `-master.defaultReplication=002`,
`-master.peers` with the three addresses, two data directories per node, one data center and one rack for
all nodes (so replication 002 puts the copies on three different servers).

Facts found by the laptop test with the pinned image (8 October 2026, three containers on one Docker
network, not the host network):

- The three masters elect a leader, three volume servers join, `volume.max=0` gives about 1904 volumes
  per node on the laptop disk.
- An object written through the S3 endpoint of one node is readable through the other two, and a bucket
  made on one node is listed on another. So the embedded filer stores share metadata (hypothesis settled
  for the laptop, to be proven again on the VMs).
- After writes each node held three `.dat` files, consistent with replication 002 (a count, not proof of
  three copies per volume).
- In the first run one of the three containers had exited after the start (cause not captured, not seen
  in the second run). The node script prints the container state, and a rerun replaces the container.
- A bucket name needs at least three characters (my own test used `rt` and failed).
