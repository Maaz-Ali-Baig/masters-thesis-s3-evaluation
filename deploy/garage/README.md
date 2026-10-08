# Garage on the three VMs

Three node Garage v1.0.0 on ceph0, ceph1 and ceph2 (192.168.1.72, .71, .70), one system at a time with
Ceph stopped. The design and the reasons for each setting are in `setup_notes.md` (section "Three node
layouts"). The image is pinned by digest, the same digest as the laptop image.

Order (all run as root on the VM named in the first column):

| VM | Script | What it does |
|---|---|---|
| ceph0 | `garage-secret.sh create` | creates `/root/garage-rpc-secret` (never printed) |
| all | copy the secret file to ceph1 and ceph2 | by a route that does not show it, then `garage-secret.sh fingerprint` must give the same sha256 on all three |
| all | `garage-node.sh` | config, container, prints the node id (`id@ip:3901`) |
| ceph0 | `garage-cluster.sh <id@ip ceph1> <id@ip ceph2>` | connect, layout (one zone per node, replication factor 3), key `thesis-key`, bucket `thesis-test-bucket` |
| ceph0 | `garage-roundtrip.sh` | writes through each node, reads through the other two, sha256 compared |
| all | `garage-stop.sh` | stops and removes the container, data is kept |

Facts found by testing the pinned image on the laptop (6 October 2026):

- The multi directory `data_dir = [{ path, capacity }, ...]` is accepted by v1.0.0.
- In `garage layout assign` the node id must come before the flags, because `-t` takes several values and
  swallows the id otherwise.
- A key cannot be created before a layout is applied (`Could not reach quorum`).
- `garage key allow` prints the secret key in clear, so the cluster script masks the output of every key
  command and keeps the secret only in `/root/garage-key.txt` (mode 600).
