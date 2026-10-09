# RustFS on the three VMs

Three node RustFS 1.0.1 on ceph0, ceph1 and ceph2 (192.168.1.72, .71, .70), one system at a time with
Ceph, Garage and SeaweedFS stopped. The design is in `setup_notes.md` (section "Three node layouts"). The image
is pinned by digest (`sha256:1803faef5762...`, tag 1.0.1). The laptop image 1.0.0-beta.8 does not run on the VM CPU
(no AVX2, crash with exit 132), so the laptop RustFS results are labelled beta.8 and have to be repeated on 1.0.1 (not done yet).

Order (all run as root on the VM named in the first column):

| VM | Script | What it does |
|---|---|---|
| ceph0 | `rustfs-secret.sh create` | makes `/root/rustfs-config/` (root key as env file), never printed |
| ceph0 | `rustfs-secret.sh sse` (optional) | adds `sse.env` with the SSE-S3 master key, needed for SSE-S3 without KMS, copy it to the other VMs like the rest |
| ceph0 | copy the directory to ceph1 and ceph2 | `scp -r` typed by the user, then `rustfs-secret.sh fingerprint` must give the same sha256 on all three |
| all | `rustfs-node.sh` | starts one container per node, run on the three VMs within a minute |
| ceph0 | `rustfs-roundtrip.sh` | writes through each node, reads through the other two, sha256 compared |
| ceph0 | `rustfs-tests.sh compat` or `presign` | runs the 22 test compatibility probe or the presigned PUT test from the pinned repository commit, script hashes checked |
| all | `rustfs-stop.sh` | stops and removes the container, data is kept |

The volume list names all six drives (`http://192.168.1.{70...72}:9000/srv/s3/disk{1...2}/rustfs`). The vendor
documentation says distributed mode needs at least 4 servers, so the first start is itself a test: if RustFS
refuses with 3 nodes, that is the result and it goes to Prof. Baun.

The container runs as uid 10001 (user `rustfs`), so the script gives that uid the two data directories.
