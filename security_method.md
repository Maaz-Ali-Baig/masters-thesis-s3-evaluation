# Security method for the four systems on the university VMs

Status: DRAFT of 10 October 2026, not yet approved. Nothing in this file has been run. The same checks are done on
Ceph, SeaweedFS, RustFS and Garage, as deployed (defaults, no hardening), one system at a time. "As deployed" is the
point: the question is what an operator gets without extra work, and then what is possible with a small change.

## 1. Question

How exposed is each system in its default three node deployment, how finely can access be limited, is the data protected
in transit and at rest, and can a failed attack be seen in the logs?

Already known (and kept, not repeated here): the presigned URL and unsigned header test (results/security-presign-*),
the 22 case compatibility probe with its encryption and ACL cases, and the unauthenticated port checks done on the VMs for
Garage (G4), SeaweedFS (S4) and RustFS (R4). No Ceph port check is recorded in setup_notes.md, the context file or the memory notes (searched on 10 October 2026 for
ports, dashboard, ss and the usual Ceph port numbers). What the notes do record: cephadm bootstrap on ceph0 printed a
dashboard URL and a generated password (setup_notes.md, bootstrap step 2), so the Ceph dashboard exists on the cluster, and
the RGW is placed on several nodes on port 80 (ceph orch ps --daemon-type rgw). Which other ports Ceph exposes (monitor,
manager, dashboard, metrics) is OPEN and is checked in Phase 4 with SEC1 and SEC7. The checks below put all four
into one table and add what is missing.

## 2. The checks (each has a pass condition written before the run)

SEC1 Open ports and anonymous reachability.
- Listening TCP ports on every node (ss -ltn). From another node, without credentials: GET of / and a fixed list of paths
  (/health, /metrics, /status, /v1/status, /cluster/status, /dir/status, the console and dashboard paths), codes and byte
  counts. Also an anonymous PUT and DELETE to a bucket path on the S3 port.
- Record: for each port, whether the answer without credentials is 200 with content. Pass for the S3 port: 403 for bucket,
  object, PUT and DELETE.

SEC2 Anonymous write through non S3 ports (only for ports that answered 200 in SEC1).
- One PUT of a marker file to the port (for SeaweedFS the filer port, and a read of a stored file from the volume server by
  file id), read back, then removed. Shows whether the data path can be reached around S3 authentication.
- Pass: no write without credentials.

SEC3 Authentication.
- Wrong secret key, wrong access key, empty signature: all must be refused. Expired presigned URL refused. (The presigned
  header cases already exist; rerun on RustFS 1.0.1 is done, the others are cited.)

SEC4 Least privilege (scoped key).
- A second key is created that may only read one bucket. With it: read of that bucket works; write, delete, read of another
  bucket, list of all buckets, creation of a bucket must be refused. The creation step is system specific (Ceph radosgw-admin
  user and policy, Garage key allow, SeaweedFS identity actions, RustFS IAM user with policy) and is recorded as typed.
- Pass: only the allowed action works. Where a system cannot limit a key to one bucket, that is the result.

SEC5 Transport.
- Level 1 (all systems, as deployed): is the S3 port plain HTTP, and is the object content visible on the wire? A capture
  on one node (tcpdump, if present) of an upload of a file containing a unique marker string, then a count of the marker in
  the capture. Credentials are never sent in clear by SigV4, so only content is looked at.
- Level 2 (time boxed to 45 minutes per system, only if Level 1 is done): enable TLS on one node with a self signed
  certificate and test with curl --cacert. If it does not work in the time box the record says "not tested, time box",
  and the documented support is cited as documentation, not as a result.

SEC6 Encryption at rest.
- Write three objects with a unique 200 byte marker: no encryption requested, SSE-S3 requested (where the compat probe shows
  support; RustFS needs its master key, already set on the cluster), and SSE-C if supported. Then search the data directories
  of all three nodes for the marker (grep -rlF) and report which files contain it.
- Pass for "encrypted": marker not found for the SSE objects. The unencrypted object shows the default.
- Ceph stores on a raw device (BlueStore): the search is a read only scan of the block device, time boxed. Never a write to
  /dev/sdb.

SEC7 Management and admin interfaces.
- For each admin or console interface (Garage admin API 3903, SeaweedFS master, volume, filer, RustFS console 9001, Ceph
  dashboard, mgr and prometheus ports): is it open, does it show configuration or topology without credentials, is there a
  login, what does the console expose after login with the root key (one screenshot or text, no secrets).

SEC8 Visibility of a failed attack.
- After the failed requests of SEC3 (made with a unique fake access key), search the logs of the system for the fake key and
  for the source address. Pass: the failed attempt can be found. Where there is no request log by default, that is the result.

## 3. Output

One table, four systems by eight checks, each cell: result, one line of evidence, and the name and hash of the record file.
Cells are PASS, FAIL, NOT TESTED (with reason) or OPEN. A FAIL is a finding about the default deployment, not a
judgement of the product (settings that could close it are named separately and not tested unless time remains).

## 4. Safety

1. Only the thesis cluster is tested, with test keys, by the user's own commands. Nothing leaves the VM network.
2. No credential value is printed or stored in a result file (scripts read key files; the access key and the test keys are
   searched for in the archives, as in the compat probe, and the count must be 0).
3. State changes (SEC2 marker, SEC4 key, SEC6 objects) are removed at the end and the removal is logged.
4. Hostname first in every command on the VM sessions, output copied character for character, hashes on the VM.

## 5. Threats to validity

1. Default deployments differ in what they enable (console, metrics, SSE master key). The table says which setting was on.
2. Different versions between laptop runs and VM runs for RustFS (beta.8 against 1.0.1): only VM results are in the table.
3. One test environment, one run. A PASS shows that one case did not fail, not that the system is secure.
4. TLS may not be tested in all systems (time box).
