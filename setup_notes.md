# S3 Testbed Setup Notes

## AWS CLI (S3 client used for manual testing)
- Version: aws-cli/2.36.8, confirmed via `aws --version`
- Install method: official Linux x86_64 installer — download `awscliv2.zip`, `unzip`, run `sudo ./aws/install`. Confirmed by the presence of those exact filenames during install; this is AWS's one documented method for Linux, no ambiguity.
- Installed to `/usr/local/aws-cli/v2/dist/aws`, self-contained, symlinked at `/usr/local/bin/aws`. Confirmed (via `readlink -f $(which aws)`) that it does not depend on the original download/extraction folder — so the leftover `awscliv2.zip` and `aws/` extraction folder were safe to delete from the repo afterward and have been removed.
- Credentials: dummy `test`/`test` access key/secret in the default profile (`~/.aws/credentials`), region `us-east-1`. These are not real AWS credentials — only there to satisfy the CLI's auth requirement when talking to local S3-compatible endpoints via `--endpoint-url`.

## Warp (primary benchmarking tool)
- Version: v1.5.0, confirmed via `warp --version`, installed at `/usr/local/bin/warp`
- Distribution note: Warp is no longer published as a GitHub release tar.gz. It's now a raw Linux binary hosted under MinIO's "aistor" branding at `dl.min.io/aistor/warp/release/linux-amd64/archive/warp`. Worth a mention in Methodology/Appendix C since older Warp install guides online describe the GitHub-release method, which no longer applies.
- **Status: pipeline validated against all three lightweight systems (SeaweedFS 3 Aug, RustFS and Garage 9 Aug 2026). No measurement-grade data collected yet.**
- Use `--benchdata results/warp-raw/<name>` on every run. Without it Warp writes its benchmark data file
  into the current working directory, which is how `warp-put-…json.zst` ended up in the repository root
  after the first run. The benchdata file is not a by-product — `warp analyze` can regenerate reports,
  re-slice by time window and export CSV from it without re-running the benchmark, so for real
  measurement runs these files *are* the raw data behind Appendix B.
- Garage additionally requires `--region garage`; without it Warp signs with `us-east-1` and fails with
  `AuthorizationHeaderMalformed` (Issue 6). Pass credentials via shell variables sourced from
  `~/.thesis-s3-env` rather than typing them on the command line, to keep the secret out of shell history
  and out of the process list.

### First Warp run — pipeline validation, not data (3 August 2026)
Purpose: confirm that Warp can connect, authenticate, drive load and report against a local
S3-compatible endpoint. Deliberately small and short; the resulting numbers are **not** usable as results.

```bash
warp put --host localhost:8333 --access-key test --secret-key test \
  --bucket warp-benchmark-bucket --obj.size 1MiB --duration 20s --concurrent 4
```

Note: `--bucket` is destructive — Warp wipes the target bucket before and after every run. A dedicated
`warp-benchmark-bucket` is used so that `thesis-test-bucket` (holding the manual verification object) is
never touched.

Outcome — **1732 requests, 0 errors**. Pipeline confirmed working end to end.

| Metric | Value |
|---|---|
| Throughput | 94.52 MiB/s (94.52 obj/s) |
| Data written | 1732 MiB over a 16 s measured window |
| Latency | avg 46.2 ms, p50 39.3 ms, p90 58.5 ms, p99 197.2 ms, max 768.6 ms, stddev 42.3 ms |
| TTFB | avg 35 ms, median 29 ms, p99 175 ms, max 752 ms |
| Per-second throughput | fastest 168.6 MiB/s, median 89.3 MiB/s, slowest 48.9 MiB/s |

Two observations worth carrying into the methodology:

1. **Warp reports a shorter measured window than the requested duration** (`Ran: 16s` for `--duration 20s`)
   because it trims ramp-up and ramp-down from its analysis. Durations quoted in the thesis must be the
   measured window, not the requested one.

2. **Throughput varied by a factor of 3.4 between the fastest and slowest second of a single run**
   (48.9 to 168.6 MiB/s), and the latency standard deviation (42.3 ms) is close to the mean (46.2 ms).
   Probable causes are environmental rather than properties of SeaweedFS: the Docker Desktop
   virtualisation layer, the Windows host filesystem beneath it, on-demand volume allocation inside
   SeaweedFS during the run, and the absence of any warm-up period. This is direct empirical support for
   the decision to repeat every measurement at least five times and report means — a single run of this
   workload could plausibly have reported anything between roughly 49 and 169 MiB/s.

Raw output saved to `results/2026-08-03_warp_pipeline_validation_seaweedfs.txt`.

Open questions for the professor before measurement runs begin (protocol changes, not to be decided
unilaterally): whether to add an explicit warm-up phase that is discarded, and whether to lengthen runs
(e.g. 60 s x 5 repetitions) rather than relying on short runs alone.

### Warp validation across all three lightweight systems (9 August 2026)
Same parameters for each (`--obj.size 1MiB --duration 20s --concurrent 4`), differing only in endpoint,
credentials and — for Garage — region. **Zero errors on all three**, so the measurement chain is validated
for every lightweight system in the study. Full write-up and raw output in
`results/2026-08-09_warp_pipeline_validation_all_three.txt`.

|                     | SeaweedFS | RustFS | Garage |
|---|---|---|---|
| Throughput          | 94.52 MiB/s | 91.63 MiB/s | 40.61 MiB/s |
| Requests in ~17 s   | 1732 | 1825 | 768 |
| Latency p50         | 39.3 ms | 34.8 ms | 85.8 ms |
| Latency p99         | 197.2 ms | 117.5 ms | 706.2 ms |
| TTFB median         | 29 ms | 25 ms | 78 ms |
| Slowest 1 s window  | 48.9 MiB/s | 28.0 MiB/s | 2.2 MiB/s |
| Intra-run spread    | 3.4x | 5.0x | 23.1x |

**These are not results.** Single unrepeated runs, no warm-up, uncontrolled host, and — importantly — the
three systems are not equivalently configured, since Garage runs at `replication_factor = 1` while the
others are plain single-node defaults. They are not comparable as deployed.

Three observations worth carrying forward as hypotheses to test, not as findings:

1. **SeaweedFS and RustFS are indistinguishable here.** 94.52 against 91.63 MiB/s is well inside the noise
   of runs this unstable, and no claim of one being faster is supportable on this evidence.

2. **Garage differs on every axis, and TTFB says where.** A median time-to-first-byte of 78 ms against
   25-29 ms means the delay occurs *before* data transfer begins, which points at per-request overhead
   rather than bandwidth. At 1 MiB this is a metadata-heavy workload, and Garage's LMDB metadata store,
   256 partitions and quorum machinery (present even at replication factor 1) plausibly cost more per
   object. The test that would settle it is an object-size sweep: if the cause is per-request overhead,
   the gap should narrow substantially at 100 MiB and 1 GiB.

3. **Garage's variance is the most striking number and has a methodological consequence.** Its slowest
   one-second window managed 2.2 MiB/s against a 45.9 MiB/s median — a 23x intra-run spread, against 3.4x
   and 5.0x for the others. That is a stall rather than ordinary noise, and a periodic metadata flush or
   fsync would be consistent with a system built to prioritise durability on unreliable nodes (unverified).
   The consequence: **if a system stalls periodically, run length matters as much as repetition count.**
   A 17-second window may miss a stall entirely or land squarely on one, and neither is representative.
   This is concrete support for lengthening individual runs rather than only repeating short ones.

## ossperf (baseline benchmarking tool, cross-check against Warp)
- Source: github.com/christianbaun/ossperf, vendored into this repo at `ossperf/` on 16 August 2026.
- Install note: the tool was first obtained via `git clone`, but the checkout (on the Windows/OneDrive
  filesystem) picked up CRLF line endings, which broke every script with `$'\r': command not found` and
  a syntax error. Downloading a plain zip from GitHub instead avoided this entirely — a zip preserves the
  original Unix line endings, whereas `git checkout` on Windows can convert them. The working copy in
  `ossperf/` was obtained this way and confirmed to run cleanly (`file ossperf.sh` shows no CRLF markers).
  One stray file, `DEADJOE` (a `joe`-editor crash-recovery dump unrelated to the tool, present in the
  upstream repo by accident), was removed before committing.
- Dependencies: `bash`, `bc`, `md5sum` (present by default); `parallel` (installed via
  `sudo apt-get install -y parallel` — pulled in `sysstat` as a side effect, which is useful later for the
  CPU/memory/I/O investigation Baun asked for, since it provides `sar`/`iostat`/`mpstat`).
- `s3cmd` is listed as a *required* dependency in ossperf's own README even though this project uses the
  `-w` (AWS CLI) mode instead. The check at line 201 of `ossperf.sh` is unconditional — it runs regardless
  of which backend flag is passed, unlike the AWS CLI check further down, which is correctly gated on
  `-w`. `s3cmd` therefore only needs to be *installed* (`sudo apt-get install -y s3cmd`), never configured,
  since `-w` means it's never actually invoked.
- When using `-w`, ossperf requires `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as real environment
  variables — it does not read the AWS CLI's own credentials file or profile. No region variable is
  required; the AWS CLI's own default profile region is used.

### First successful run (16 August 2026)
```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
./ossperf.sh -n 5 -s 1048576 -w -d http://localhost:8333 -b ossperf-testbucket
```
Five 1 MiB files, matching ossperf's own documented example, against SeaweedFS. All six phases (create
bucket, upload, list, download, erase objects, erase bucket) completed with `[OK]`, and
`[OK] Checksums have been validated and match the files` confirmed byte-for-byte integrity — the same
guarantee as `scripts/verify-roundtrip.sh`, and the same method used in Wernicke (2017).

### Reporting standard: Mbps
ossperf reports bandwidth natively in Mbps (megabits/second, decimal). Warp reports natively in MiB/s
(mebibytes/second). Adopted Mbps as the standard unit across the thesis, since it is ossperf's native
output and the conventional network-bandwidth unit. Conversion used throughout:
```
1 MiB/s = 1,048,576 bytes/s x 8 bits/byte = 8,388,608 bits/s = 8.3886 Mbps
```
Any figure originally measured in MiB/s and converted for comparison is marked as such; it is not a
fresh measurement and carries the rounding of the conversion.

### Sequential vs. parallel upload/download (16 and 22 August 2026)
First comparison (16 August, `n=3` sequential then `n=3` parallel, run order tracked only by memory of
execution sequence since ossperf's CSV output has no column recording which mode produced a row) showed
sequential outperforming parallel on download with no overlap across the six runs, but overlapping,
inconclusive results on upload. Raw data preserved for reference at
`results/ossperf-seaweedfs-mode-unconfirmed-2026-08-16.csv` — kept for the record, but not relied upon,
since the mode of each row could only be inferred, not confirmed.

This exposed a real data-hygiene gap: relying on memory of run order across a working session is fragile.
Fixed going forward by moving `results.csv` to a mode-labelled filename in `results/` immediately after
each batch, before starting the next, so a mixed-mode file can no longer occur.

Repeated cleanly on 22 August 2026, three runs per mode, each batch archived immediately:
`results/ossperf-seaweedfs-sequential-2026-08-22.csv`,
`results/ossperf-seaweedfs-parallel-2026-08-22.csv`.

| | Upload (Mbps) | Download (Mbps) |
|---|---|---|
| Sequential | 12.3, 20.1, 18.4 | 28.6, 29.4, 31.5 |
| Parallel | 10.3, 8.9, 10.9 | 9.8, 9.2, 11.9 |

No overlap on either metric this time — sequential's lowest value clears parallel's highest on both
upload and download. At this specific test shape (5 files, 1 MiB each, against SeaweedFS), sequential
execution outperforms `-p` (GNU-parallel-driven concurrent `aws` invocations) by roughly 2-3x.

**Scope of this finding, stated explicitly so it is not over-generalised:** tested on one system
(SeaweedFS), one object size (1 MiB), one file count (5). Plausible explanation is that GNU parallel's own
coordination overhead, plus five separate `aws` CLI process spawns (fresh Python interpreter and TLS
handshake each), is not amortised at this small scale — `nproc` confirmed 8 cores available, ruling out
simple core starvation as the cause. This does **not** establish that `-p` is generally worse; it may
behave differently at larger file counts or object sizes, which would need to be tested before any such
claim is made.

### Recurring bucket-creation stall — three instances across two systems, not yet explained
`TIME_CREATE_BUCKET` spiked to an anomalous ~10 seconds twice, against a normal range of roughly 1-6
seconds for the same operation: 9.572 s (16 August, mode-unconfirmed batch) and 10.094 s (22 August,
first parallel run). Bucket creation is normally a near-instant metadata operation on all three systems
tested so far.

This is the same *shape* of problem already seen on Garage via Warp — a 23x intra-run throughput spread
with a slowest-second measurement of 2.2 MiB/s against a 45.9 MiB/s median (see the Warp section above).
Three occurrences now, across two different systems (SeaweedFS twice, Garage once), all presenting as an
intermittent multi-second stall rather than a steady slowdown. Worth investigating as a possible shared
cause (e.g. Docker Desktop/WSL2 virtualisation layer, or filesystem sync behaviour under OneDrive) rather
than three unrelated system-specific quirks. This is the concrete material for the CPU/memory/I/O
investigation Baun asked for in response to the Warp variance question — `sysstat` (installed as a side
effect of installing `parallel`, see above) provides `sar`, `iostat` and `mpstat` for exactly this.

## SeaweedFS
- Ports: 9333 (master), 8080 (volume), 8888 (filer/dashboard), 8333 (S3 API)
- Dashboard: http://localhost:9333
- Current working command (see issues below for why it evolved from the original):

```
docker run -d --name seaweedfs \
  -p 9333:9333 -p 8080:8080 -p 8888:8888 -p 8333:8333 \
  -v ~/seaweedfs-data:/data \
  -v ~/seaweedfs-config:/etc/seaweedfs \
  chrislusf/seaweedfs server -s3 -s3.config=/etc/seaweedfs/s3_config.json
```

Config files live in `~/seaweedfs-config/` (`security.toml` and `s3_config.json`) and are mounted as a
**directory**, not as individual files. This is deliberate and required — see Issue 4.

### Issue 1 — S3 API port not exposed (found 26 July 2026)
Original command only mapped 9333/8080/8888. Port 8333 (SeaweedFS's default S3 API port) was never
published to the host, so AWS CLI/Warp could not reach it at all (connection refused).
Diagnosed via `docker port seaweedfs` / `docker inspect`. Fixed by adding `-p 8333:8333` and recreating
the container.

### Issue 2 — ListBuckets silently returns empty despite bucket existing (found 26 July 2026)
After fixing the port, `aws s3 mb s3://test-bucket` reported success (and a second attempt correctly said
`BucketAlreadyExists`), but `aws s3 ls` always returned an empty list. Checked the filer's `/buckets/`
directory directly (`curl http://localhost:8888/buckets/`) and confirmed the bucket folder genuinely
existed on disk — so the S3 gateway's bucket listing was out of sync with the filer, not a real absence
of data.

Root cause found in `docker logs seaweedfs`:
```
E... s3api_server.go:307 Failed to load IAM configuration: no signing key found for STS service;
please provide 'signingKey' in IAM config, configure 'jwt.filer_signing.key' in security.toml,
or ensure SSE-S3 is initialized
```
The S3 gateway's IAM/STS subsystem failed to initialize because no JWT signing key was configured,
which left bucket-listing in a broken state even though basic writes still went through.

Fix: generated a `security.toml` (via `weed scaffold -config=security` as a template) with a random
signing key under `[jwt.filer_signing]`, mounted at `/etc/seaweedfs/security.toml`.

### Issue 3 — Fixing the signing key switched on strict IAM, which then rejected all credentials
Once the signing key was set, the S3 gateway logged `Starting S3 API Server with standard IAM` and started
enforcing real identity checks — the dummy `test`/`test` AWS CLI credentials were then rejected with
`InvalidAccessKeyId`, since no identity had ever been registered for them.

Fix: created `~/seaweedfs-s3-config.json` defining an explicit identity (`thesis-test-user`) with
access key `test` / secret `test` and `Admin`/`Read`/`Write` actions, mounted it into the container, and
passed `-s3.config=/etc/seaweedfs/s3_config.json` on the `weed server` command. Flag name confirmed via
`docker exec seaweedfs weed server --help | grep s3.`.

Also added a `-v ~/seaweedfs-data:/data` volume at the same time — previously all SeaweedFS data lived
only in the container's writable layer, so every `docker rm`/recreate (needed for each of the fixes above)
silently wiped test buckets. Data now persists across container recreation.

### Verification (26 July 2026)
Full round trip confirmed against `http://localhost:8333` with the fixed setup:
`s3 mb` → `s3 ls` (bucket shows up) → `s3 cp` upload → `s3 ls` on bucket (object shows up) → `s3 cp`
download → `diff` on the two files matched. Pipeline confirmed working end to end.

### Issue 4 — Container fails to restart after Docker Desktop restarts: single-file bind mounts do not survive (found 2 August 2026)
The container ran fine for several days, then stopped cleanly when Docker Desktop shut down
(`filer.go:465 Gracefully stopping gRPC server` — an orderly shutdown, not a crash). It then refused to
start again: `docker start` failed, and the Docker Desktop UI reported only a generic `400` error.
`docker ps -a` showed `Exited (127)`, which normally means "command not found" and is misleading here —
the container never reached the point of executing any command.

The real error was only visible via `docker inspect seaweedfs --format '{{.State.Error}}'`:
```
error mounting "/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/Ubuntu/2d6d2672de38..."
to rootfs at "/etc/seaweedfs/s3_config.json": not a directory:
Are you trying to mount a directory onto a file (or vice-versa)?
```

**Observed behaviour (proven by the table below and reproduced by the fix):** single-file bind mounts did
not survive a Docker Desktop restart, directory bind mounts did, and the container's stored reference
pointed at a hashed path under `/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/` that no longer
resolved.

**Proposed mechanism (inference, not verified here, and no source recorded):** under Docker Desktop on
Windows the WSL2 distribution and the container runtime live in separate VMs, so bind mounts must be
bridged between them; directory mounts appear to be bridged as a live path mapping while single files
appear to be staged into the hashed location above, which is then discarded on restart, leaving the
container holding a dangling reference. This explanation is consistent with every observation made, but it
was not independently confirmed against Docker documentation or source, and it should be cited or
re-verified before appearing in the thesis as a cause rather than as a hypothesis. What is certain either
way is the observable rule and the fix. The source files in WSL were never touched or lost; only the
mapping broke.

The failure mode was directly observable in this setup, since the same container used both mount types:

| Mount | Type | Survived Docker Desktop restart |
|---|---|---|
| `~/seaweedfs-data` → `/data` | directory | Yes — test bucket and object intact after 6 days |
| `~/seaweedfs-security.toml` → `/etc/seaweedfs/security.toml` | single file | No |
| `~/seaweedfs-s3-config.json` → `/etc/seaweedfs/s3_config.json` | single file | No |

Fix: consolidated both config files into a single directory and mounted the directory instead:
```bash
mkdir -p ~/seaweedfs-config
mv ~/seaweedfs-security.toml  ~/seaweedfs-config/security.toml
mv ~/seaweedfs-s3-config.json ~/seaweedfs-config/s3_config.json
```
then recreated the container with `-v ~/seaweedfs-config:/etc/seaweedfs` in place of the two single-file
`-v` flags. `/etc/seaweedfs/` is one of the three locations SeaweedFS searches for `security.toml` by
default, so both files still resolve at the paths the server expects, and `-s3.config=` is unchanged.

### Verification (2 August 2026)
After the directory-mount fix: container `Up`, `docker inspect` confirms only two mounts, both of type
directory (`~/seaweedfs-data → /data`, `~/seaweedfs-config → /etc/seaweedfs`). Logs show
`Starting S3 API Server with standard IAM` followed by
`Start Seaweed S3 API Server ... at http port 8333`, with no IAM error. `aws s3 ls` returns
`thesis-test-bucket`, and `aws s3 ls s3://thesis-test-bucket/` still lists `test-object.txt` (26 bytes) —
so the persistent data volume carried the earlier test data through both the outage and the container
recreation.

**Relevance to the thesis:** this belongs in section 4.4 (Reproducibility and Fairness Considerations).
It is a case where the containerisation layer — not the storage system under test — silently invalidated
a test environment between sessions, and where the surfaced error messages (`400`, exit code `127`) both
pointed away from the actual cause. Any benchmark environment rebuilt from single-file bind mounts under
Docker Desktop is therefore not reliably reproducible across restarts; directory mounts should be
preferred for all four systems.

## RustFS
- Ports: 9000 (S3 API), 9001 (dashboard)
- Command: docker run -d --name rustfs -p 9000:9000 -p 9001:9001 -e RUSTFS_ROOT_USER=minioadmin -e RUSTFS_ROOT_PASSWORD=minioadmin rustfs/rustfs server /data
- Dashboard: http://localhost:9001
- Login: minioadmin / minioadmin

### Verification (9 August 2026) — no issues encountered
Full S3 round trip on the first attempt, with no configuration of any kind: `s3 mb` → `s3 ls` →
`s3 cp` upload → `s3 ls` on the bucket → `s3 cp` download → `diff` matched. Region `us-east-1` accepted.

This is worth recording precisely because nothing went wrong. SeaweedFS required three separate fixes
(unpublished port, missing JWT signing key, unregistered identity) and Garage required cluster layout
assignment plus explicit key/bucket authorisation before either would serve a single object. RustFS
served correctly straight from `docker run` with no config files and no flags. That difference in
operational complexity is a finding in its own right and supports the project's "drop-in MinIO
replacement" positioning.

**Security observation:** the round trip succeeded using `minioadmin`/`minioadmin`, the MinIO default
credentials, unchanged. RustFS does not appear to force a credential change on first start. Contrast with
Garage, which ships no default credentials at all — a key must be explicitly created. To be confirmed and
written up in the Security chapter.

### Multi-node support — confirmed via documentation, not yet built (22 August 2026)
Open question since Baun's reply (9 August): does RustFS support clustering at all, since only Ceph was
originally planned as multi-node. Checked directly rather than assumed, per RustFS's own GitHub repo,
docs, and a community discussion asking the same question (rustfs/rustfs#2248).

**Answer: yes, RustFS has a distributed mode, with three caveats that matter for planning.**

1. Feature status is listed as "Under Testing," not stable/production. Worth stating as a limitation
   when RustFS's multi-node results are eventually reported.
2. The current single-node deployment **cannot be upgraded in place**. Single-node mode uses no erasure
   coding, and its on-disk data layout is incompatible with distributed mode. A multi-node cluster has to
   be a fresh deployment, with all nodes defined from the start — not an extension of the running
   container documented above.
3. Requires `--network host` rather than the default Docker bridge networking currently used for all
   three lightweight systems, since bridge networking does not support the node-to-node communication
   distributed mode needs.

Configuration shape (from RustFS's own docs, not yet tested locally): all nodes are listed together in a
single `RUSTFS_VOLUMES` environment variable, e.g.
`RUSTFS_VOLUMES="http://node1:9000/data http://node2:9000/data http://node3:9000/data"`, rather than each
node being configured independently and joined afterward (contrast with Garage's `layout assign` /
`layout apply` model, or Ceph's per-daemon bootstrap).

**Consequence for the replication chapter's scope decision:** RustFS can now be included in the
single-node-and-multi-node comparison Baun asked for. Actual deployment (fresh containers, host
networking, node count — proposed as three, to match the Ceph VM count, pending Baun's confirmation) is
scheduled together with the SeaweedFS and Garage multi-node builds, not done in isolation, so all three
lightweight systems' clusters are stood up under comparable conditions.

## Garage
- Ports: 3900 (S3 API), 3901 (RPC), 3902 (admin)
- Data dir `~/garage-data`, config dir `~/garage-config` (see mount note below)
- RPC secret must be exactly 64 hex characters generated via: openssl rand -hex 32
- Dashboard: No web UI — managed via CLI or admin API at http://localhost:3902
- Current working command:

```
docker run -d --name garage \
  -p 3900:3900 -p 3901:3901 -p 3902:3902 \
  -v ~/garage-data:/var/lib/garage \
  -v ~/garage-config:/etc/garage \
  dxflrs/garage:v1.0.0 \
  /garage -c /etc/garage/garage.toml server
```

### Issue 5 — Garage will not serve S3 until a cluster layout is assigned (9 August 2026)
Unlike SeaweedFS and RustFS, starting the Garage container is not sufficient. `garage status` reported
`NO ROLE ASSIGNED`: the node was running but belonged to no cluster and therefore had nowhere to place
data. The S3 port answered (HTTP 403), which makes this easy to mistake for a working deployment.

This is a design difference rather than a defect — Garage is cluster-first where the others are
single-node-first — and belongs in the Background chapter, not only in setup notes.

Sequence required to make a single node usable:
```bash
docker exec garage /garage -c /etc/garage/garage.toml status          # obtain node ID
docker exec garage /garage -c /etc/garage/garage.toml layout assign -z dc1 -c 10G <node-id>
docker exec garage /garage -c /etc/garage/garage.toml layout show     # staged, not yet applied
docker exec garage /garage -c /etc/garage/garage.toml layout apply --version 1
docker exec garage /garage -c /etc/garage/garage.toml key create thesis-key
docker exec garage /garage -c /etc/garage/garage.toml bucket create thesis-test-bucket
docker exec garage /garage -c /etc/garage/garage.toml bucket allow --read --write --owner thesis-test-bucket --key thesis-key
```
Garage deliberately separates staging (`layout assign`) from committing (`layout apply --version N`), so
a topology change can be reviewed before it takes effect. `--version` must be stated explicitly, which
guards against two administrators applying conflicting layouts.

Note the applied layout reported "Partitions are replicated 1 times on at least 1 distinct zones" —
i.e. `replication_factor = 1`, no redundancy. Adequate for throughput benchmarking, but this must be
raised and a multi-node cluster built before the Replication and Fault Tolerance chapter.

**Permission model.** Keys and buckets are independent objects and neither implies access to the other;
authorisation must be granted explicitly per key per bucket (`bucket allow`). Garage is deny-by-default,
which is the stronger posture *as configured by default* and should be credited as such in the Security
chapter.

**Correction (22 September 2026) — an earlier version of this paragraph claimed "SeaweedFS and RustFS both
treat valid credentials as access to everything." That claim is not supported by anything tested here and
has been withdrawn.** The SeaweedFS identity in use (`configs/seaweedfs/s3_config.json`) was deliberately
created with `Admin`, `Read` and `Write` granted globally, and RustFS was addressed with its root
administrator credentials. Under both configurations full access is the expected outcome, so the
observation shows what was granted, not what the system is capable of restricting. The setup as built
could not have distinguished "no scoping available" from "scoping available, not used".

*Open question, with the test that settles it*: create a deliberately scoped, non-admin identity on each of
SeaweedFS and RustFS, granting access to exactly one bucket, then attempt an operation against a second
bucket with that identity and record the result. Only that establishes a genuine three-way comparison of
authorisation granularity. Until it is run, the Security chapter may state Garage's deny-by-default model
as observed, but must not characterise SeaweedFS's or RustFS's model at all.

`garage key info` also reports `Can create buckets: false` for a newly created key, meaning the key
cannot create buckets through the S3 API (`aws s3 mb`) unless separately granted with
`garage key allow --create-bucket`. Tooling that expects to create its own bucket on first run will fail
against a default Garage key. Worth testing explicitly, before and after granting the permission, so the
compatibility matrix records evidence rather than an assertion.

### Issue 6 — Garage enforces its configured S3 region in the SigV4 signature (9 August 2026)
`aws s3 ls` against Garage failed with:
```
An error occurred (AuthorizationHeaderMalformed) when calling the ListBuckets operation:
Authorization header malformed, unexpected scope: 20260809/us-east-1/s3/aws4_request
```
Cause: AWS Signature V4 includes the region in the signing scope. `garage.toml` sets
`s3_region = "garage"`, while the AWS CLI was configured with the near-universal default `us-east-1`, so
client and server computed different signatures. Fixed by addressing Garage with `AWS_DEFAULT_REGION=garage`.

Two aspects make this significant rather than a mere configuration slip:

1. **The failure was partial, and therefore misleading.** `ListBuckets` (account-scoped) failed, while
   `PutObject` and `ListObjects` (bucket-scoped) succeeded — S3 clients can discover the correct region
   from a bucket-scoped response and silently retry. A casual check that only uploaded a file would have
   concluded Garage was working. This is the same class of trap as Issue 2: verify the complete round
   trip, never a single successful operation.

2. **It is a genuine migration friction point.** SeaweedFS and RustFS both accepted `us-east-1`. Most S3
   implementations ignore the region or default to it precisely because so many clients hardcode it.
   Existing tooling pointed at MinIO with default settings will fail against Garage until every client is
   reconfigured, and the error text does not indicate that the region is the problem. Belongs in the S3
   API Compatibility chapter.

### Issue 7 — converting Garage to a directory bind mount also changes the CLI invocation (9 August 2026)
Garage originally mounted `~/garage.toml` as a *single file*, the pattern that made SeaweedFS unstartable
in Issue 4. Converted pre-emptively, before benchmarking, rather than waiting for it to fail:
```bash
mkdir -p ~/garage-config && mv ~/garage.toml ~/garage-config/garage.toml
```
and the container recreated with `-v ~/garage-config:/etc/garage` in place of the single-file mount.

Because Garage looks for `/etc/garage.toml` by default, the config path must now be passed explicitly:
`/garage -c /etc/garage/garage.toml server`. The non-obvious consequence is that **every CLI invocation
needs the flag as well**, since `docker exec garage /garage status` is a separate process that also reads
the config to locate the running node's RPC socket. Without it:
```
Error: Unable to read configuration file /etc/garage.toml
```
The server was running correctly at the time; only the CLI was misconfigured. Easy to misread as a failed
container.

**Verification after conversion:** both mounts confirmed as type `directory`
(`~/garage-data → /var/lib/garage`, `~/garage-config → /etc/garage`); cluster layout intact (zone `dc1`,
capacity 10.0 GB, not `NO ROLE ASSIGNED`); `bucket info` reported `Objects: 1, Size: 51 B`; and the S3
round trip matched on `diff`. Layout, access key, bucket and object all survived container recreation, as
expected given that all state lives in the directory-mounted `~/garage-data`.

**One unexplained observation, recorded for honesty.** Immediately after the recreation,
`aws s3 ls s3://thesis-test-bucket/` returned an empty listing with exit code 0, while `ListBuckets`
returned correctly — suggesting the object table was not yet loaded although the S3 API was already
accepting requests. Garage's own `bucket info` reported `Objects: 1` at the same time, so no data was
lost, and a retry moments later listed the object correctly. **Two deliberate reproduction attempts (a
`docker restart` and a full `docker rm` + `docker run`, each polled from t=0) failed to reproduce it —
listings were correct immediately in both cases.** It is therefore recorded as observed once and not
reproduced, most plausibly a startup race, rather than claimed as a confirmed defect. The practical
mitigation is the same either way and is already required by Issues 1 and 4: verify from the client side
that listings are correct before starting a measurement run, and never treat an empty listing immediately
after startup as authoritative.

## Ceph

- Platform: 3 VMs on university Proxmox VE 9.2.10, one per physical host (pveproj0/1/2), Debian 12.15
  (Bookworm). Hostnames set to `ceph0` (192.168.1.72, bootstrap/admin node, reports internally as
  `debian` — see the hostname note below), `ceph1` (192.168.1.71), `ceph2` (192.168.1.70).
- Access constraint: the university VPN (FortiClient) reaches the Proxmox management console only, not
  the VM subnet itself (192.168.1.0/24). Confirmed via parallel ping tests from both WSL and native
  PowerShell (both 100% packet loss to the VM IPs, while the VMs ping each other with 0% loss), which
  rules out a WSL-specific routing bug and points at the VPN's own routing scope. The university cluster
  admin (Mr Petrozziello) confirmed this is a permanent limitation of the current network design, not
  something that can be opened on request. **Consequence: all Ceph work happens by pasting commands into
  the Proxmox browser console, one node at a time — there is no SSH path from the laptop into this
  network.** This also means Warp and ossperf, which run from the WSL laptop against `localhost`-mapped
  ports for the other three systems, cannot reach Ceph's S3 endpoint the same way; benchmarking Ceph will
  need the tools installed and run from inside the VM network itself, a genuine methodology difference
  worth stating explicitly rather than glossing over.
- Install method: `cephadm`, the official Ceph-recommended orchestrator for multi-node clusters.

### Issue 8 — documented cephadm download method (raw script from a release branch on GitHub) is dead (7 September 2026)
Ceph's own docs and many install guides describe downloading the standalone `cephadm` script directly
from a release branch of the GitHub repo, e.g.
`https://raw.githubusercontent.com/ceph/ceph/reef/src/cephadm/cephadm`. This returned a 14-byte file
whose entire content was the literal text `404: Not Found` — not a curl error, a genuine HTTP 404 with a
plausible-looking filename, easy to mistake for a truncated but real download until the file size and
content are actually checked. Tried three branches in sequence (`reef`, `squid`, `main`) — all three
404'd identically. Confirmed with `curl -v` that this was a real TLS connection to
`raw.githubusercontent.com` (valid certificate, real handshake) returning a genuine 404, not a proxy or
network intercept substituting content.

Root cause, per the current Ceph installation documentation
([docs.ceph.com/en/latest/cephadm/install/](https://docs.ceph.com/en/latest/cephadm/install/), which
documents the `download.ceph.com` method and no longer the GitHub raw-file one): recent Ceph releases
distribute `cephadm` as a build artifact rather than a plain script sitting in the git tree at that path.
*Precision note*: what is directly evidenced here is that the GitHub path 404s on all three branches tried
and that the documented method is now the `download.ceph.com` one. The statement about **why** the file
moved is read from the documentation's current shape, not from a changelog entry naming the change, so it
should be cited as "the documented method is X" rather than asserted as a packaging history. The
documented current method downloads a release-specific build from `download.ceph.com`:
```bash
CEPH_RELEASE=20.2.4   # latest active release at the time (Tentacle, EOL 2027-06-01)
curl --silent --remote-name --location https://download.ceph.com/rpm-${CEPH_RELEASE}/el9/noarch/cephadm
chmod +x cephadm
```
This worked immediately — a real ~1 MB executable, versus the earlier 14-byte 404 pages. Note the path
says `el9` (Enterprise Linux 9) but the script itself is distro-agnostic; it ran correctly on Debian 12.
Worth recording as a live example of how fast infrastructure tooling documentation drifts — several
install guides found via search still describe the GitHub method as current.

Also needed `curl` itself installed first (`apt install -y curl`), since the minimal Debian template used
for these VM clones does not include it by default.

### Ceph bootstrap and cluster build (7-17 September 2026)
Sequence, run entirely through the Proxmox console on each node in turn:

1. **cephadm install** (on `ceph0` only): `./cephadm add-repo --release tentacle` then `./cephadm install`
   — adds Ceph's apt repo for Debian and installs the `cephadm` command properly. Confirmed with
   `cephadm version` → `20.2.4 ... tentacle (stable)`.
2. **Bootstrap the first node**: `cephadm bootstrap --mon-ip 192.168.1.72`. Creates the first monitor and
   manager daemon, pulls container images (Ceph runs its daemons in Podman containers, not natively on
   the host), and prints a generated dashboard URL/password and the cluster's SSH public key
   (`/etc/ceph/ceph.pub`) used to add further nodes. `ceph -s` immediately afterward showed `HEALTH_WARN`
   with `OSD count 0 < osd_pool_default_size 3` — expected and correct at this point, since no storage has
   been added yet.

### Issue 9 — hostname collision across cloned VMs (7 September 2026)
All three VMs were cloned from the same Proxmox template and therefore all reported `hostname` as
`debian`. Ceph identifies cluster hosts by hostname, so adding a second and third node under an identical
name would conflict. Fixed by renaming only the two not-yet-joined nodes
(`hostnamectl set-hostname ceph1` / `ceph2`, plus updating the `127.0.1.1` line in `/etc/hosts` to match)
and leaving the already-bootstrapped node's hostname (`debian`) untouched, since it was already registered
in the cluster under that name and renaming it risked disrupting the running monitor. The cluster does not
require any particular naming scheme, only uniqueness — so `debian`, `ceph1`, `ceph2` is a valid, if
slightly inconsistent-looking, permanent set of hostnames for this cluster.

### Issue 10 — adding hosts requires SSH key distribution, which requires password auth Debian disables by default for root (7 September 2026)
`ceph orch host add` requires the bootstrap node to SSH into each new host as root using the cluster's
generated key (`ssh-copy-id -f -i /etc/ceph/ceph.pub root@<new-host-ip>`), which itself requires a
one-time password login to seed that key. This failed repeatedly with `Permission denied`, even
immediately after resetting the root password via `passwd` on the target VM's own console (ruling out a
wrong/forgotten password). Checked `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/` on the target
host for an explicit `PermitRootLogin` setting — neither had one, meaning OpenSSH's current default
applied: `PermitRootLogin prohibit-password`, which accepts root logins by SSH key only and silently
rejects password attempts regardless of whether the password is correct.

Fix, applied on `ceph1` and `ceph2` before the key copy: appended `PermitRootLogin yes` to
`/etc/ssh/sshd_config` and `systemctl restart ssh`, to allow one password-based login long enough to
install the cluster's SSH key. After the key is installed, root login no longer needs a password at all,
so this is a narrow, temporary widening of access rather than a standing weakening — worth a one-line
mention in the Security chapter as a real hardening default encountered during setup, not something to
gloss over.

### Issue 11 — `ceph orch host add` fails a preflight check for a missing package (7 September 2026)
Adding `ceph1` failed with `Error EINVAL: check-host failed: ... ERROR: lvcreate binary does not appear
to be installed`, even though Podman, systemd and the hostname all passed their checks. Ceph's orchestrator
runs a preflight host-check before accepting a new node, and requires LVM tooling to be present up front —
even though no OSDs (which are the actual LVM users) exist yet at that point. Fixed with
`apt install -y lvm2` on `ceph1` and `ceph2`, after which both hosts were added cleanly:
```bash
cephadm shell -- ceph orch host add ceph1 192.168.1.71
cephadm shell -- ceph orch host add ceph2 192.168.1.70
```
`ceph orch host ls` then listed all three hosts, and `ceph -s` showed 3 mon daemons in quorum
(`debian`, `ceph1`, `ceph2`) with a standby manager on `ceph1` — still `HEALTH_WARN` for the same reason
as before (no OSDs yet).

### OSD provisioning
Each of the three Proxmox VMs was given a second virtual disk (32 GB each, added via the Proxmox web UI,
Hardware → Add → Hard Disk on each VM — this step happens in Proxmox itself, not inside the VM console)
in addition to the existing OS disk, since Ceph requires a dedicated raw, unpartitioned, unmounted disk
per OSD and will not use free space on the OS disk. `ceph orch device ls` did not list the new disks
until a manual refresh (`ceph orch device ls --refresh`) was run — Ceph's device inventory scans
periodically rather than instantly picking up newly attached hardware.

Once visible, all three were claimed in one command:
```bash
cephadm shell -- ceph orch apply osd --all-available-devices
```
`ceph -s` afterward showed **`HEALTH_OK`**, 3 mons in quorum, 3 OSDs up and in, 96 GiB total usable
capacity (3 × 32 GB). This is the first fully healthy state of the cluster.

### RGW (S3 gateway) deployment and verification (17 September 2026)
```bash
cephadm shell -- ceph orch apply rgw s3test --placement="3 debian ceph1 ceph2"
```
Deployed one RGW (RADOS Gateway, Ceph's S3-compatible API service) daemon on each of the three nodes,
matching the multi-node placement already used for mons/OSDs. `ceph orch ps --daemon-type rgw` confirmed
all three running on port 80.

Created a test S3 identity via `radosgw-admin` (Ceph's own admin CLI, separate from the `ceph` command):
```bash
cephadm shell -- radosgw-admin user create --uid=thesis --display-name="Thesis Test User" \
  --access-key=thesiskey --secret-key=<CEPH_TEST_SECRET_KEY>
```

S3 round trip verified directly from `ceph0`'s console (the only reachable point — see the access
constraint note above), using AWS CLI installed on the VM itself rather than the laptop:
```bash
aws --endpoint-url http://localhost:80 s3 mb s3://thesis-test
head -c 1M /dev/urandom > testfile.bin
md5sum testfile.bin                                                   # b7e8ee47e21259c8a71f5c8b02b5a900
aws --endpoint-url http://localhost:80 s3 cp testfile.bin s3://thesis-test/
aws --endpoint-url http://localhost:80 s3 cp s3://thesis-test/testfile.bin testfile-downloaded.bin
md5sum testfile-downloaded.bin                                        # b7e8ee47e21259c8a71f5c8b02b5a900
```
Hashes matched. Bucket create, list, upload, download and integrity all confirmed working — Ceph's S3
pipeline is verified end to end, using the same MD5 round-trip method as `scripts/verify-roundtrip.sh`
applied to the other three systems.

**Status at this point: 3-node cluster healthy, RGW live on all three nodes, S3 basic operations
verified. Not yet benchmarked with Warp or ossperf — pending a decision on how to run those tools against
a network the laptop cannot reach directly (most likely: install them on `ceph0` itself and run from
there, pulling results back via the console or a shared location). Not yet load-tested, and fault-tolerance
testing (node failure simulation) not yet attempted.**

### Benchmarking Ceph — tools installed and run on `ceph0` itself (17 September 2026)
Confirmed the network constraint noted above in practice: with `warp`/`ossperf` on the WSL laptop, there
is no route to any of the three VMs, only to the Proxmox console. Resolution adopted: install both
benchmarking tools directly on `ceph0` and run them from there, pasting results out through the console —
a real, stated methodology difference from the other three systems, which are measured from the laptop.

- **Warp**: installed v1.7.0 (`dl.min.io/aistor/warp/release/linux-amd64/archive/warp`) — note this is a
  newer version than the v1.5.0 used against SeaweedFS/RustFS/Garage in August, since Warp has moved on
  since then. Worth a one-line mention alongside any cross-system Warp comparison.
- **ossperf**: installed via `git clone` directly on the Linux VM (not the zip-download workaround used on
  Windows/OneDrive) — confirmed via `file ossperf.sh` to carry no CRLF line endings, so the corruption
  problem that forced the zip method on the laptop does not apply here, as expected since it was a
  Windows/OneDrive-specific issue, not a property of `ossperf` itself.

### Issue 12 — Warp's default chunked/streaming upload signing is rejected by this Ceph RGW build (17 September 2026)
`warp put` against Ceph's RGW failed every upload with a bare `Access Denied`, while bucket creation,
listing and other calls all succeeded normally:
```
warp: <ERROR> upload error:  Access Denied.
```
Isolated the cause methodically rather than guessing:

1. Ruled out credentials/permissions — an `aws s3 cp` of the same file, by the same user, into the same
   bucket Warp had just created, succeeded without issue.
2. Ruled out clock skew — `timedatectl` showed `System clock synchronized: yes`, NTP active, correct
   timezone.
3. Used `warp put --debug` to capture the actual HTTP exchange. The failing request:
   ```
   PUT /warp-debug2-bucket/gAolg32M/2.ynpDvqQwCasoRyQ0.rnd HTTP/1.1
   Content-Encoding: aws-chunked
   X-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD
   X-Amz-Decoded-Content-Length: 1048576
   ...
   HTTP/1.1 403 Forbidden
   <Error><Code>AccessDenied</Code>...
   ```
   Every successful call in the same session (`aws s3 cp`, and Warp's own bucket-creation/listing calls)
   used a normally signed request body; only the object-upload calls, which Warp's underlying client
   (`minio-go v7.3.0`) sends using AWS's chunked, streaming-signed transfer encoding
   (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD` + `Content-Encoding: aws-chunked`), were rejected.

Searched for known Ceph RGW issues with this signing mode — several exist
([PR #9484](https://github.com/ceph/ceph/pull/9484),
[PR #10167](https://github.com/ceph/ceph/pull/10167),
[PR #15965](https://github.com/ceph/ceph/pull/15965),
[tracker #16146](https://tracker.ceph.com/issues/16146),
[tracker #19754](https://tracker.ceph.com/issues/19754),
[tracker #20665](https://tracker.ceph.com/issues/20665)) — but all found so far predate this Ceph release
(Tentacle 20.2.4) by several years and describe different symptoms (hangs, zero-byte upload failures,
LDAP-specific auth), not a clean `AccessDenied` on a normal-sized object.

**The working hypothesis recorded at this point — that Ceph's RGW does not support the chunked/streaming
transfer mode — later turned out to be wrong, and is left here deliberately rather than edited away, since
the correction is itself part of the methodology.** Streaming uploads are supported; the actual fault lay in
*which headers that mode includes in the signature*. Root cause was established on 22 September 2026 via
RGW-side debug logging — see "Issue 12 resolved" below.

**This is treated as a genuine S3 API compatibility finding, not merely a local obstacle**: a real,
current-generation Ceph RGW deployment rejects a standard AWS SDK upload mode that a mainstream benchmarking
tool (Warp, built on `minio-go`, the same client library many production applications use) sends by
default. Belongs in the S3 API Compatibility chapter regardless of whether a workaround is eventually
found, since the practical consequence — "this popular tool's default upload mode does not work against
Ceph out of the box" — is itself the finding.

**Practical resolution adopted for now**: benchmark Ceph with ossperf instead of Warp, since ossperf's `-w`
mode uses the AWS CLI as its backend, already confirmed working against Ceph (see the manual round trip
and `aws s3 cp` test above). Warp is not abandoned — the exact cause is worth establishing before the
thesis is written up, and is scheduled as a dedicated follow-up investigation. *(That investigation was
carried out on 22 September 2026 and succeeded; Warp is now usable against Ceph. See below.)*

### Issue 12 resolved — root cause found, and it is a security-versus-compatibility finding (22 September 2026)

Dedicated follow-up session, as planned. The decisive move was to stop inspecting the request from the
client side and instead ask the server *why* it refused.

**Step 1 — raise RGW's own log verbosity.** `ceph tell` does not accept RGW targets (`Bad target type
'client'`, since RGW is a client-type daemon, not mon/osd/mgr/mds), so the level was set through the
cluster config database instead, which running daemons pick up live without a restart:
```bash
cephadm shell -- ceph orch ps --daemon-type rgw        # identify the local daemon
cephadm shell -- ceph config set client.rgw.s3test.debian.ghnhoi debug_rgw 20/20
```
The daemon serving `localhost:80` on `ceph0` is `rgw.s3test.debian.ghnhoi`.

**Step 2 — reproduce with a single worker** so the debug log stays readable, then capture it:
```bash
warp put --duration=5s --concurrent=1 --obj.size=1MiB --host=localhost:80 \
  --access-key=thesiskey --secret-key=<CEPH_TEST_SECRET_KEY> --bucket=warp-debug3
cephadm logs --name rgw.s3test.debian.ghnhoi -- -n 3000 > /root/rgwdebug.log
grep -m1 -B 50 "err_no=-1" /root/rgwdebug.log
```
(Note: `cephadm logs` passes extra arguments to `journalctl` only after a `--` separator; `--tail` is not
a cephadm flag.)

**Step 3 — the decisive log line.** RGW states the reason explicitly:
```
req ... v4 credential format = thesiskey/20260921/us-east-1/s3/aws4_request
req ... access key id = thesiskey
Signature rejected: 'content-type' supplied but not in CanonicalHeaders.
req ... s3:put_obj rgw::auth::s3::LocalEngine denied with reason=-1
req ... s3:put_obj rgw::auth::s3::AWSAuthStrategy denied with reason=-1
req ... s3:put_obj Failed the auth strategy, reason=-1
failed to authorize request
req ... op->ERRORHANDLER: err_no=-1 new_err_no=-1
```
`err_no=-1` is `EPERM`, which RGW surfaces to the client as a bare `AccessDenied` with no message body —
which is precisely why this was so hard to diagnose from the client side.

**Step 4 — confirm the same fault from the client side.** Captured the full request with `warp put --debug`
and isolated the failing object PUT:
```
PUT /warp-debug5/%29F%29B%28mvH/1.7hJLdmRlY06%28X17k.rnd HTTP/1.1
Host: localhost
User-Agent: MinIO (linux; amd64) minio-go/v7.3.0 warp/v1.7.0
Authorization: AWS4-HMAC-SHA256 Credential=thesiskey/20260921/default/s3/aws4_request,
  SignedHeaders=content-encoding;host;x-amz-content-sha256;x-amz-date;x-amz-decoded-content-length,
  Signature=**REDACTED**
Content-Encoding: aws-chunked
Content-Type: application/octet-stream
X-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD
X-Amz-Date: 20260921T191924Z
X-Amz-Decoded-Content-Length: 1048576

HTTP/1.1 403 Forbidden
```
`Content-Type: application/octet-stream` is on the wire, but `content-type` does not appear in
`SignedHeaders`. Server-side complaint and client-side evidence match exactly.

**Step 5 — locate the fault in the client library.** Warp v1.7.0 embeds `minio-go v7.3.0`. That version's
streaming signer excludes Content-Type from the signature unconditionally
([`pkg/signer/request-signature-streaming.go`](https://github.com/minio/minio-go/blob/v7.3.0/pkg/signer/request-signature-streaming.go)):
```go
var ignoredStreamingHeaders = map[string]bool{
	"Authorization": true,
	"User-Agent":    true,
	"Content-Type":  true,   // present in v7.3.0, removed upstream since
}
```
The non-streaming signer signs Content-Type correctly, which is exactly why bucket creation, listing and
`aws s3 cp` all succeeded while only object uploads failed. On current `master` the `"Content-Type"` entry
is gone.

**The full causal chain, and why this is a genuine finding rather than a local obstacle:**

1. Ceph patched [CVE-2026-54330](https://docs.ceph.com/en/latest/security/CVE-2026-54330/) (CVSS 8.1,
   rated Important by Red Hat) in **Tentacle 20.2.4 and Squid 19.2.6** — the exact release deployed on this
   cluster. The flaw: RGW's SigV4 verifier validated only the headers listed in `X-Amz-SignedHeaders` and
   silently accepted additional unsigned ones, so any holder of a presigned PUT URL could attach arbitrary
   unsigned `x-amz-*` headers and escalate privileges beyond what the URL's signer authorised.
2. The patch hardened SigV4 verification so that headers present on the wire but absent from the signature
   cause the request to be rejected.
3. `minio-go v7.3.0`'s streaming signer sends `Content-Type` while deliberately omitting it from
   `SignedHeaders` — legal against AWS S3, which tolerates unsigned non-`x-amz-` headers, but rejected by
   the newly hardened RGW.
4. Warp v1.7.0 therefore fails **every object upload** against a patched Ceph with an unexplained
   `AccessDenied`, while every other operation works.

This was reported upstream independently as
[minio-go issue #2300](https://github.com/minio/minio-go/issues/2300) —
*"Streaming/chunked signer excludes Content-Type from SignedHeaders, causing rejections on hardened
S3-compatible servers (Ceph RGW)"* — filed against this same Ceph version and explicitly attributing it to
the post-CVE hardening. Fixed in commit `c4168e0c` on 9 September 2026 (*"signer: fix streaming signer to
include Content-Type in SignedHeaders"*).

**Resolution — upgrade the client, not the server.** Warp **v1.8.0** (released 19 September 2026) pins
`minio-go v7.3.1-0.20260909183557-78bfa91607c2`, i.e. the commit containing the fix:
```bash
wget https://dl.min.io/aistor/warp/release/linux-amd64/archive/warp_1.8.0_amd64.deb \
  -O /root/warp_1.8.0_amd64.deb
dpkg -i /root/warp_1.8.0_amd64.deb
warp --version        # v1.8.0
```

**Verification** — the identical command that previously failed on every single upload:
```
Report: PUT. Concurrency: 1. Ran: 7s
 * Average: 28.41 MiB/s, 28.41 obj/s
 * Reqs: Avg: 35.0ms, 50%: 36.1ms, 90%: 40.0ms, 99%: 43.5ms, Fastest: 28.7ms, Slowest: 53.3ms
 * Reqs: 261, Errs: 0, Objs: 261, Bytes: 261.0MiB
```
261 objects, **zero errors**. *These numbers are not a measurement* — `debug_rgw` was still at `20/20`
during this run, which is enormously expensive logging. Debug level was reset immediately afterwards:
```bash
cephadm shell -- ceph config rm client.rgw.s3test.debian.ghnhoi debug_rgw
```

**Consequences for the thesis:**

- **Methodological**: Warp now works against Ceph, so Ceph can be benchmarked with *the same tool* as
  SeaweedFS, RustFS and Garage rather than only with ossperf. This removes a real threat to comparability
  that had been accepted as unavoidable. ossperf results already collected remain valid and are kept.
- **S3 API Compatibility chapter**: the finding is sharper than first recorded. It is not "Ceph does not
  support chunked uploads" (false); it is *"Ceph RGW enforces AWS SigV4 more strictly than AWS S3 itself
  does, and that strictness breaks a mainstream client library's default upload path."* Both halves are
  citable and reproducible.
- **Security chapter**: this is the clearest security-versus-compatibility trade-off encountered in the
  project so far. Ceph closed a genuine privilege-escalation vulnerability, and the correct, specification-
  conformant fix immediately broke a widely used client whose behaviour AWS had always tolerated. The same
  class of breakage hit other clients simultaneously: Bun's S3 client
  ([issue #43029](https://github.com/oven-sh/bun/issues/43029), fixed in
  [PR #43045](https://github.com/oven-sh/bun/pull/43045)) and `aws-sdk-php` as surfaced through Nextcloud
  ([issue #63489](https://github.com/nextcloud/server/issues/63489)).
- **Diagnostic lesson worth recording as method**: a bare `AccessDenied` with an empty message from an
  S3-compatible server is close to undiagnosable from the client side. Server-side debug logging turned a
  multi-day unknown into a single explicit sentence. Worth applying to the other three systems whenever an
  opaque 403 appears.

**Follow-up carried out the same day**: whether SeaweedFS, RustFS and Garage enforce the same SigV4
strictness. See the next section.

### SigV4 header strictness compared across all four systems (22 September 2026)

The Ceph failure above provided an unusually clean probe. A pre-fix Warp build sends a `Content-Type`
header that its own signature does not cover, so pointing it at each system answers one precise question:
**does this implementation reject a request carrying a header absent from `SignedHeaders`, as the AWS SigV4
specification requires, or does it accept it as AWS S3 itself does?** This is a direct compatibility and
security comparison across all four systems, obtained at essentially no cost, and it was run deliberately
before the pre-fix Warp binary was discarded.

**Method.** Identical `warp put` invocation against each system, single worker, 1 MiB objects, credentials
passed as flags rather than exported so nothing leaked between systems (see `scripts/s3-helpers.sh` for why
that matters here). The three lightweight systems were driven from the laptop's WSL environment where they
run in Docker; Ceph was driven from `ceph0` itself, since the laptop has no network route to the VM subnet.

```bash
# SeaweedFS
warp put --duration=10s --concurrent=1 --obj.size=1MiB --host=127.0.0.1:8333 \
  --access-key=test --secret-key=test --bucket=warp-sigv4-seaweedfs
# RustFS
warp put --duration=10s --concurrent=1 --obj.size=1MiB --host=127.0.0.1:9000 \
  --access-key=minioadmin --secret-key=minioadmin --bucket=warp-sigv4-rustfs
# Garage (own region required; existing bucket reused because a default Garage key
# cannot create buckets over S3, and --noclear protects the existing test data)
source ~/.thesis-s3-env && warp put --duration=10s --concurrent=1 --obj.size=1MiB \
  --host=127.0.0.1:3900 --access-key="$GA_KEY" --secret-key="$GA_SECRET" \
  --region=garage --bucket=thesis-test-bucket --noclear
```

**Results.**

| System | Version under test | Unsigned `Content-Type` | Outcome |
|---|---|---|---|
| Ceph RGW | Tentacle **20.2.4**, 3-node VM cluster | **Rejected** | `403 AccessDenied`, every object upload failed |
| SeaweedFS | **4.25** (`7acba59a5`), Docker, single node | Accepted | 180 objects, 0 errors, 18.94 MiB/s |
| RustFS | **1.0.0-beta.8** (`64c0ede`), Docker, single node | Accepted | 212 objects, 0 errors, 21.12 MiB/s |
| Garage | **v1.0.0**, Docker, single node | Accepted | 115 objects, 0 errors, 11.68 MiB/s |

Exact builds recorded at test time, since a claim of the form "system X accepts unsigned headers" is only
citable if the build it was observed on is identified:

```
chrislusf/seaweedfs  latest    sha256:c42a5268ca13fcb65e0fae925886b107f4bf294d8db15e1be5509d55104eb509
  weed version 30GB 4.25 7acba59a5 linux amd64
rustfs/rustfs        latest    sha256:fa19210ac4697c79d7ccca1ec9b0eb91aebacc6691991ffb14014bb3c67e6cc3
  rustfs 1.0.0-beta.8, git 64c0ede0261eeb7ccd415221d6f102aa70829b6a, built 2026-06-10, rustc 1.96.0
dxflrs/garage        v1.0.0    sha256:0c7ed80d22c0b0f902fbd0ec74fc68073f72a46ea15d54e3c4c484184a8c7516
```
SeaweedFS and RustFS were pulled as `latest` rather than pinned tags, so the image digests above are the
authoritative identifiers for reproducibility, not the tag.

**Incidental but relevant to the maturity discussion**: RustFS reports itself as `1.0.0-beta.8`. A system
still publishing beta builds is being compared against Ceph 20.2.4 and Garage v1.0.0, both stable releases.
That asymmetry is worth stating explicitly wherever RustFS results are presented, in either direction: it
tempers criticism of rough edges, and it tempers claims of production readiness.

**Ceph is the only one of the four that rejected this request.** The three lightweight systems all accept
a request whose signature does not cover a header that was sent.

*Scope of the claim, stated so it is not over-generalised*: one header (`Content-Type`), sent in one mode
(streaming/chunked PUT), by one client library. This does **not** establish that the three lightweight
systems are lax about SigV4 in general, nor that Ceph is strict about every unsigned header. It
establishes exactly one divergence, reproducibly. Broader wording such as "Ceph enforces the
specification and the others do not" would require testing additional headers and additional request
shapes.

**The client-side premise was verified rather than assumed.** The three lightweight systems were driven
with Warp v1.5.0 (`minio-go v7.0.98`) while Ceph was driven with v1.7.0 (`minio-go v7.3.0`). Since the
whole comparison rests on both builds sending the same unsigned header, this was confirmed on the wire
rather than inferred from version dates:
```
PUT /warp-sigv4-seaweedfs/NSC4XV7y/1.%28iqEKm0LmYR7pv9J.rnd HTTP/1.1
User-Agent: MinIO (linux; amd64) minio-go/v7.0.98 warp/v1.5.0
Authorization: AWS4-HMAC-SHA256 Credential=test/20260921/us-east-1/s3/aws4_request,
  SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-decoded-content-length,
  Signature=**REDACTED**
Content-Type: application/octet-stream
X-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD
```
`Content-Type` present, `content-type` absent from `SignedHeaders`. Identical fault shape to the Ceph
capture. One incidental version difference: v7.0.98 does not send `Content-Encoding: aws-chunked` at all,
whereas v7.3.0 does (added upstream in August 2026). This does not affect the property under test.

**Threats to validity, stated plainly rather than glossed over:**

- *Different vantage points.* Ceph was exercised from inside the VM network, the other three from the
  laptop. This is the same network constraint already flagged for the performance chapter. It does not
  affect this particular result, because SigV4 verification is decided from the request's own contents
  before any network characteristic becomes relevant, but the asymmetry is real and is stated rather than
  hidden.
- *Different client versions.* v1.5.0 against three systems, v1.7.0 against Ceph. Mitigated by the wire
  capture above, which shows the tested property is identical in both.
- *The throughput figures in the table are incidental, not measurements.* They are a by-product of a
  functional test with `--concurrent=1` and are not comparable across systems; the performance chapter's
  numbers come from the dedicated batches, not from here.

**What this does and does not establish.** It establishes that three of four systems accept a header not
covered by the signature. It does **not** establish that they honour unsigned `x-amz-*` headers, which is
the specific vector behind CVE-2026-54330 and the part with genuine security consequences: a server may
accept an unsigned header while ignoring its value. Distinguishing "accepted" from "acted upon" requires a
separate test, and the distinction must not be blurred in the write-up.

**Next test, designed but not yet run**: generate a presigned PUT URL against each system, attach an
unsigned `x-amz-*` header (for example `x-amz-acl` or a metadata header) to the request, and check whether
the server acts on it. If SeaweedFS, RustFS or Garage honour it, they carry the same weakness Ceph patched
in CVE-2026-54330, which would be the strongest security finding in the project. This belongs in the
Security chapter and should be run deliberately, with the pre-fix Warp binary and the presigned URLs
preserved as evidence.

### First ossperf run against Ceph (17 September 2026)
```bash
export AWS_ACCESS_KEY_ID=thesiskey
export AWS_SECRET_ACCESS_KEY=<CEPH_TEST_SECRET_KEY>
./ossperf.sh -n 5 -s 1048576 -w -d http://localhost:80 -b ossperf-ceph-testbucket
```
Five 1 MiB files, same shape as the first SeaweedFS run in August, run directly on `ceph0`. All six phases
`[OK]`, checksums matched.

| Metric | Value |
|---|---|
| Bucket create | 0.621 s |
| Upload | 0.764 s |
| List | 0.543 s |
| Download | 0.599 s |
| Erase objects | 0.584 s |
| Erase bucket | 0.605 s |
| **Upload bandwidth** | **54.899 Mbps** |
| **Download bandwidth** | **70.021 Mbps** |

**Not a result, same caveats as every first run in this project**: single unrepeated pass, no warm-up, and
critically **not directly comparable to the three lightweight systems' numbers**, since those run in Docker
Desktop on the laptop while this runs natively on dedicated university VM hardware — different environments
entirely, not just different systems. Exists to confirm the pipeline works end to end on Ceph, which it
does.

### Warm-up and repeated-measurement session (17 September 2026)
Followed the same discipline established for the other three systems: unrecorded warm-up passes first,
then a repeated real batch, with `sar` (installed via `apt install -y sysstat`) running in the background
throughout to capture CPU, memory and disk activity per Baun's instruction on the earlier variance
question.

Two unrecorded warm-up runs (`ossperf-warmup1`, `ossperf-warmup2`) landed at 63.5/73.5 Mbps and
59.9/68.4 Mbps upload/download respectively — close to the very first run above (54.9/70.0), suggesting
the environment was already close to steady state rather than needing a long warm-up.

**Data-hygiene note, same category of mistake as the mode-unconfirmed CSV back in August**: the first real
5-run batch was executed without ossperf's `-o` flag, which is what actually writes `results.csv` — the
runs themselves succeeded and were read directly from terminal output, but no file was produced to archive
(`find / -name results.csv` afterward found nothing). Confirmed the cause by checking the script itself
(`ossperf.sh` line 368, `OUTPUT_FILENAME=results.csv`, only written when `-o` is passed — line 72
documents this). Re-ran the batch with `-o` included and archived immediately, per the established
convention, to `results/ossperf-ceph-batch1-2026-09-17.csv`:

```bash
sar -u -r -d 1 60 > sar-ceph-batch1.txt &
for i in 1 2 3 4 5; do ./ossperf.sh -n 5 -s 1048576 -w -o -d http://localhost:80 -b ossperf-ceph-run$i; done
cp results.csv results/ossperf-ceph-batch1-2026-09-17.csv
```

| Run | Upload (Mbps) | Download (Mbps) | Total time (s) | Bucket create (s) |
|---|---|---|---|---|
| 1 | 59.325 | 68.985 | 4.178 | 1.155 |
| 2 | 62.415 | 76.959 | 3.377 | 0.542 |
| 3 | 64.231 | 70.256 | 3.742 | 0.532 |
| 4 | 61.954 | 67.324 | 3.541 | 0.534 |
| 5 | 58.416 | 76.398 | 3.547 | 0.609 |

**No stall observed in this batch.** Bucket creation stayed at 0.53-0.61 s for runs 2-5 (only run 1 ran
slightly higher at 1.155 s, plausibly ordinary first-request cost rather than the ~10 s anomaly seen
earlier), a useful negative data point for the recurring-stall investigation: it did not reproduce here,
in this environment, at this batch size. Upload ranged 58.4-64.2 Mbps, download 67.3-77.0 Mbps — a
narrower spread than the SeaweedFS sequential/parallel comparison from August, consistent with dedicated
VM hardware rather than a shared Docker Desktop host, though this remains a hypothesis pending an
object-size sweep and more batches.

`sar` results for this batch: CPU averaged 27.13% (%user) with one momentary spike to 87% coinciding with
an operation, %iowait averaged only 1.19%, memory held steady around 37% used throughout, and disk write
throughput on `sda` (the OSD's backing device) briefly burst to ~5.3 MB/s before settling to an average of
577.64 kB/s. Nothing here points at resource saturation as a bottleneck for this workload size — worth
revisiting at larger object sizes or higher concurrency, where a genuine bottleneck would be more likely
to surface.

**As with every other repeated-measurement result in this project: not directly comparable across
environments.** This is real repeated data for Ceph specifically (5 runs, archived, with resource
monitoring), but still cannot be placed on the same chart as the SeaweedFS/RustFS/Garage numbers without
stating the environment difference explicitly, since those run in Docker Desktop on the laptop and this
runs on dedicated university VM hardware.

### Fault tolerance test — node failure and recovery (18-21 September 2026)
First genuine multi-node fault-tolerance test in the project, made possible by Ceph being the only system
with a real multi-node deployment so far. Procedure follows the node-failure-simulation flow already
planned in the notebook's Replication section: baseline → write known data → kill a node → verify
continued service and data integrity → restart the node → verify recovery.

**Baseline (18 September).** `ceph -s` confirmed `HEALTH_OK`, 3 mons in quorum, 3 OSDs up/in, 162 PGs
`active+clean`, one OSD per host (`ceph osd tree`). Wrote a known 1 MiB object
(`faulttest.bin`, MD5 `c2c69c415819f434626b05e0686565a2`) to `s3://thesis-test/` as a fixed reference
point before inducing any failure.

**Failure induced.** `ceph1` chosen over `ceph0`/`debian`, since all commands run from `ceph0`'s own
console — killing it would have cut off the only reachable point. Stopped (not gracefully shut down, to
simulate a real crash rather than an orderly departure) via the Proxmox web UI.

**Immediate reaction (within ~25 seconds).**
```
health: HEALTH_WARN
        1/3 mons down, quorum debian,ceph2
        1 osds down
        1 host (1 osds) down
        Degraded data redundancy: 323/969 objects degraded (33.333%), 90 pgs degraded
osd: 3 osds: 2 up (since 15s), 3 in (since 8d)
pgs: 90 active+undersized+degraded, 72 active+undersized
```
Quorum survived on the remaining two mons (Ceph requires a strict majority — losing 1 of 3 does not lose
quorum, losing 2 of 3 would). All PGs stayed `active`, meaning still serving reads and writes despite
being undersized. Confirmed directly rather than assumed: read back `faulttest.bin` (MD5 matched exactly)
and wrote a fresh object, `faulttest2.bin`, both while the cluster was in this degraded state — both
operations succeeded normally through `ceph0`'s RGW endpoint.

**Extended outage behaviour (re-checked after ~2 days, node left down deliberately to observe longer-term
handling, not just an instantaneous blip).**
```
health: HEALTH_WARN
        1 hosts fail cephadm check
        1/3 mons down, quorum debian,ceph2
        Degraded data redundancy: 324/972 objects degraded (33.333%), 90 pgs degraded, 162 pgs undersized
osd: 3 osds: 2 up (since 2d), 2 in (since 2d)
rgw: 2 daemons active (2 hosts, 1 zones)
usage: 1.9 GiB used, 62 GiB / 64 GiB avail
```
Ceph automatically marked the down OSD **out** (not just down) after its default timeout
(`mon_osd_down_out_interval`, 600 s), removing it from capacity accounting entirely — usable capacity
dropped from 96 to 64 GiB accordingly. This is expected self-healing behaviour (the cluster stops counting
on a host it no longer expects back soon), not a fault. RGW dropped to 2 active gateways, consistent with
losing `ceph1`'s instance. PGs were `active` (undersized and degraded, but active) at every point the
cluster was observed. **No S3 operation was issued at the 2-day mark**, so continued serving across the
outage is inferred from cluster state rather than demonstrated by a client request. Stated as an inference,
not a measurement.

**Recovery.** Restarted `ceph1`'s VM via Proxmox. `ceph -s` immediately after showed the previous (stale,
2-day-old) `HEALTH_WARN` state — a reminder that `ceph -s` reflects the state at query time, not a live
push, so it must be re-run rather than trusted from a prior paste. A clean re-run once the VM had booted
showed:
```
health: HEALTH_OK
mon: 3 daemons, quorum debian,ceph1,ceph2 (age 12m)
osd: 3 osds: 3 up (since 11m), 3 in (since 11m)
rgw: 3 daemons active (3 hosts, 1 zones)
pgs: 162 active+clean
usage: 2.1 GiB used, 94 GiB / 96 GiB avail
```
Full recovery to `HEALTH_OK`: mon rejoined quorum, OSD came back up and in, all 162 PGs returned to
`active+clean`, full 96 GiB capacity restored automatically, with no manual intervention beyond starting
the VM.

**Timing claim, stated precisely rather than generously.** Recovery *duration* was not measured. No
timestamp was taken at the moment the VM was started, and `ceph -s` was run only once after booting. The
counters above (`quorum ... age 12m`, `3 up (since 11m)`) record when each daemon came up relative to the
query, not how long recovery took from node start. What the evidence supports is therefore: *recovery had
fully completed by the time the cluster was checked, with the OSD having been back up for 11 minutes and
quorum re-formed 12 minutes earlier.* The actual recovery window is bounded above by roughly 12 minutes
and is otherwise unknown — it may have been considerably shorter, with the remainder idle.
**To quote a recovery time in the thesis, the test must be repeated with `date` recorded at VM start and
`ceph -s` polled at intervals until `active+clean`.** Cheap to do and worth doing, since recovery time is
one of the few directly comparable numbers the Replication chapter can offer once the other systems are
multi-node.

**Final integrity check.** Both test objects read back from the bucket after full recovery and compared
against their original checksums:
- `faulttest.bin` (written before the failure): `c2c69c415819f434626b05e0686565a2`, matched.
- `faulttest2.bin` (written *during* the degraded window): local source hash `793b910d6b0ff133757b79c9a47bd5e7`,
  and a fresh download from the bucket after full recovery matched exactly.

**Result, stated at exactly the strength the evidence supports:**

- **Zero data loss.** Proven. Both objects verified by MD5 after recovery, including the one written while
  degraded.
- **S3 reads and writes worked while degraded.** Proven, but at one point in time: immediately after the
  node was killed. A read and a write were each performed once and both succeeded.
- **S3 remained available across the full two-day outage.** *Not proven.* No client operation was issued
  between the immediate-reaction check and the recovery check. What is known for the intervening period is
  only that the pool never left `active` at the points it was observed, which is an indicator of
  availability, not a measurement of it. The earlier phrasing of this as "continuous availability
  throughout" claimed more than was tested and has been corrected here.
- **Full automatic recovery with no manual intervention.** Proven, with the timing caveat above.

**Both gaps were closed by a repeat run the same night — see "Fault tolerance rerun" below, which measured
recovery time and logged 268 availability probes with zero failures.** This is the strongest evidence in
the project so far for
Ceph's core value proposition —
durability and availability under node failure — and is exactly the kind of result the other three systems
cannot yet be compared against, since none of them has a multi-node deployment yet. Directly reusable for
the Replication and Fault Tolerance chapter, including as the worked example for the node-failure-simulation
flowchart already sketched in the notebook.

### Fault tolerance rerun — recovery time and availability measured (21-22 September 2026)
The 18-21 September test above proved zero data loss but only *inferred* continued availability, and its
recovery time was read indirectly off `ceph -s` counters rather than measured. Both claims were withdrawn
during the evidence audit. This rerun closes both gaps. Full record, including the exact scripts and the
complete timeline, in `results/ceph-faulttolerance-rerun-2026-09-22.txt`.

**Method.** Two instruments, both started before the failure was induced:

1. An **availability probe** on `ceph0`, writing and reading a small object through the local RGW every
   ~5 s and logging the outcome of each with a timestamp (`/root/availlog.sh`, run under `nohup`). This is
   what converts "the cluster looked healthy whenever I checked" into an actual availability record.
2. Explicit **event markers** (`echo "CEPH1_STOP $(date +%H:%M:%S)"`) written before each Proxmox action,
   so node stop and node start are timestamped rather than remembered, plus a polling loop recording
   `ceph health` every ~20 s until `HEALTH_OK`.

`ceph1` was again hard-stopped (not gracefully shut down), and deliberately left down past the 600 s
`mon_osd_down_out_interval` so that the OSD was marked `out` and recovery involved a genuine backfill —
matching the conditions of the original test rather than producing an easier, non-comparable one.
Confirmed before restarting: `ceph osd stat` → `3 osds: 2 up (since 11m), 2 in (since 104s)`.

**Measured results.**

| Measurement | Value | Basis |
|---|---|---|
| Outage duration (node down) | **13 min 45 s** | 23:01:55 → 23:15:40, both timestamped |
| Time to data redundancy restored | **under 4 min 22 s** | 23:15:40 → already clear at 23:20:02 |
| Time to full `HEALTH_OK` | **10 min 24 s** | 23:15:40 → 23:26:04, both timestamped |
| Availability probes | **268 samples**, ~5 s apart | 23:00:07 → 23:27:14 |
| Probe failures | **0** | `grep -c FAIL /root/avail.log` → `0` |

**Every write and every read succeeded, without exception, across the entire test** — before the failure,
throughout the 13 min 45 s outage, during recovery, and after. Availability is now measured rather than
inferred.

**The two recovery times are different things, and the distinction matters.** The polling loop waits for
`HEALTH_OK`, but that state was gated by `1 hosts fail cephadm check` — the *orchestrator's* management-layer
check reconnecting to the returned host. The degraded-data warning had already cleared by the first poll.
So the cluster's **data** was fully redundant again in under 4 min 22 s, while the **orchestrator** took
10 min 24 s to declare the cluster healthy. Quoting only the 10 min 24 s figure would overstate how long the
cluster actually ran at reduced redundancy by a factor of roughly 2.5.

This also retrospectively explains the ~11-12 minute figure from the first run, which the audit flagged as
unmeasured: it was the same orchestrator check clearing, read off `ceph -s` counters. The original number
was not wrong so much as measuring something other than what it appeared to measure — a good illustration
of why "recovery time" needs defining before it is reported.

**Limitation of this run, recorded rather than smoothed over.** The exact moment data redundancy was
restored was not captured. A mangled paste of the polling loop into the Proxmox browser console (pipe
characters did not survive the paste, leaving the shell on a continuation prompt) cost the first ~4.5
minutes after restart, so the first successful poll at 23:20:02 already showed recovery complete. The
figure is therefore a genuine **upper bound**, not a point measurement. To capture it exactly, the poll must
record PG state (`ceph pg stat`, or the `pgs:` line of `ceph -s`) rather than only `ceph health`, and must
be started *before* the node is restarted. Worth doing on the next run, since data-recovery time is one of
the few directly comparable numbers the Replication chapter can offer once the other three systems are
multi-node.

**Combined result across both runs, stated at the strength the evidence now supports:**

- **Zero data loss** under single-node failure. Proven, by MD5 on objects written both before and during
  the failure (18-21 September run).
- **Continuous S3 availability** through a node failure and its recovery. Proven, by 268 consecutive
  write-and-read probes with zero failures (this run).
- **Automatic recovery with no manual intervention** beyond restarting the VM. Proven in both runs.
- **Data redundancy restored in under 4 min 22 s**; orchestrator reported `HEALTH_OK` after 10 min 24 s.
  Measured, with the upper-bound caveat above.
- **Survival of a multi-day outage** (~2 days) without data loss. Proven in the first run.

### Warp benchmarking on Ceph, and a load-generator placement finding (23 September 2026)
First real Warp measurements on Ceph, now that v1.8.0 works against it (Issue 12 resolved). Protocol
follows the discipline used for ossperf: discarded warm-up runs, then five recorded 60 s runs, `sar`
logging CPU/memory/disk on the measured node throughout, and Warp's `--benchdata` kept for every run so
`warp analyze` can re-slice the raw data later. Full record in
`results/warp-ceph-coresidency-2026-09-23.txt`.

**What was not planned, and turned out to be the more important result.** The first batch was run on
`ceph0` itself against `localhost:80`, the same arrangement used for every other measurement in this
project. The `sar` data showed `%user` at 64.14% with the disk only 25% utilised, and the obvious
objection was that Warp's own CPU cost was inseparable from Ceph's. Unlike on the laptop, this was
testable: Warp was installed on `ceph2` and the identical batch re-run against `ceph0`'s gateway over the
network.

| | Client on `ceph0` (co-resident) | Client on `ceph2` (separate host) |
|---|---|---|
| Throughput, 5 runs | 45.45 - 47.31 MiB/s, mean **46.49** | 73.03 - 78.02 MiB/s, mean **74.86** |
| In Mbps | ~390 | ~628 |
| Latency, average | 88.0 ms | 53.2 ms |
| Latency, p99 | 183.7 ms | 115.2 ms |
| Intra-run spread | 1.8x | 2.0x |
| Errors | 0 | 0 |

**Moving the load generator off the measured node raised measured throughput by 61%, despite adding a
network hop that was not previously there.** The two ranges do not overlap at any point across five runs
each, so this is not a noise artefact.

`sar` on `ceph0` explains it and provides an independent check:

| | Batch A (client here) | Batch B (client elsewhere) |
|---|---|---|
| `%user` | 64.14 | 48.11 |
| `%system` | 11.08 | 18.19 |
| `%iowait` | 2.49 | 7.96 |
| `%idle` | 22.26 | 25.69 |
| `sdb` writes | 34832 kB/s | 56258 kB/s |
| `sdb` utilisation | 25.22% | 35.90% |

`%user` fell by 16 percentage points, which is the benchmark tool's own CPU cost leaving the host. Disk
write throughput rose 61%, matching the throughput rise almost exactly — a useful internal consistency
check that the extra throughput genuinely reached storage rather than being a measurement artefact.

**Explicitly not claimed: that Ceph is CPU-bound.** In Batch B `%idle` is still 25.69% and disk
utilisation only 35.90%, so nothing is saturated. At concurrency 4 the binding constraint is more
plausibly the request concurrency than a hardware ceiling. A concurrency sweep is the designed follow-up.
Note also that `ceph0` is the busiest node by construction here, serving the RGW gateway for every request
while also running a mon, the active mgr and an OSD; `sar` describes that node, not a cluster average.

**Why this matters well beyond Ceph.** *Every* measurement in this project so far has placed the load
generator on the same host as the storage system: the three lightweight systems run in Docker on the
laptop with Warp and ossperf also on the laptop, and Ceph was measured from `ceph0` until now. So the bias
is present throughout, and it is **not neutral between systems**: a system consuming more CPU per request
loses more to a co-resident client than a lightweight one does. The bias therefore runs against precisely
the systems that do the most work per request, which is the comparison this thesis exists to make.

This is a threat to validity for the Performance chapter's central comparison, and it is now demonstrated
rather than argued — 61% on the one system where it could be tested directly. It belongs in the
methodology question already put to Baun, and it materially strengthens the case for moving all four
systems onto the university VMs with a dedicated load-generating node rather than benchmarking each
system from its own host.

**Consequence for existing data**: the ossperf Ceph batch
(`results/ossperf-ceph-batch1-2026-09-17.csv`) and the Warp verification run were all produced with the
client on `ceph0`. They remain valid records of what was run, but they understate Ceph and must not be
placed alongside any future off-host measurement.

**Separate observation, on tool choice.** ossperf measured Ceph at 58-64 Mbps upload for 1 MiB objects;
Warp measures the same system and object size at roughly 390 Mbps co-resident and 628 Mbps off-host.
Neither is wrong. ossperf spawns a separate AWS CLI process per file, so a large share of its elapsed time
is process startup, Python interpreter initialisation and connection setup, while Warp holds a persistent
client at a fixed concurrency. They measure genuinely different things, and the ~6-10x gap is the size of
that difference. **ossperf and Warp figures can therefore never share a chart**, and the Methodology
chapter should state which question each tool answers rather than presenting them as two estimates of one
quantity.

### Concurrency sweep on Ceph, and the discovery that the VMs have one vCPU (23 September 2026)
Follow-up to the co-residency finding above, which left one question open: with neither CPU nor disk
saturated at concurrency 4, what actually limits throughput? Object size held at 1 MiB, client on `ceph2`,
only concurrency varied. Full record in `results/warp-ceph-concurrency-sweep-2026-09-23.txt`.

**The curve** (exploratory pass, single run per level, shape-finding only):

| Concurrency | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|
| Throughput (MiB/s) | 34.18 | 59.95 | 79.29 | 83.77 | 84.45 | 91.24 | 86.61 |
| Latency avg (ms) | 29.4 | 33.3 | 50.2 | 95.3 | 186.8 | 339.3 | 711.9 |

Zero errors at every level including 64. Repeated three times each around the knee:

| Concurrency | Runs (MiB/s) | Mean | Latency avg |
|---|---|---|---|
| 4 | 78.79, 81.14, 78.28 | **79.40** | 50.4 ms |
| 8 | 89.27, 86.09, 79.71 | **85.02** | 97.1 ms |
| 16 | 89.38, 85.43, 88.78 | **87.86** | 179.8 ms |

Going 4 to 8 buys 7.1% throughput for 93% more latency; 8 to 16 buys 3.3% for another 85%. **Saturation
is effectively reached by concurrency 8**, and the plateau is roughly 85-88 MiB/s (about 715-740 Mbps).
Past the knee, added concurrency buys queue time rather than throughput.

*Limit on that claim*: the distributions overlap (c8 spans 79.71-89.27 while c4 reaches 81.14), so with
three runs the levels are not cleanly separated at the extremes even though the means differ.

**Internal validity check.** Little's Law (throughput x latency = concurrency) holds within 3% at every
level measured, from c1 through c64. The instrument is measuring what it claims to.

**Bottleneck investigation.** `sar` at concurrency 16 showed `%idle` still 19.49 and disk utilisation only
34.39% with sub-2 ms waits, so nothing looked saturated. Three candidates were formed and tested by cost:

1. *The network* — **eliminated**. `sar -n DEV` during a run showed `ens18` at 90529 kB/s in, 45344 kB/s
   out. (Outbound is *half* of inbound, not double as predicted before measuring; the prediction that
   `ceph0` fans out both replicas for every object was wrong. Probable reason, unverified: only about a
   third of PGs have their primary OSD on `ceph0`.) `%ifutil` reads 0.00 because virtio reports no link
   speed (`/sys/class/net/ens18/speed` = -1), so the path was measured directly with `iperf3` while Ceph
   was idle: **8.64 Gbit/s in both directions**. Ceph was using about 8% of it. Incidentally 8609 TCP
   retransmits in 10 s at full rate, recorded but far too little to explain a plateau at 8% utilisation.
2. *A serialisation point inside one daemon* — tested with `sar -P ALL`, expecting one pinned core beside
   idle ones. The output listed only `all` and `0`.
3. *Another node being the real ceiling* — **not tested**, only `ceph0` has ever been monitored. Open.

**The discovery.** The per-core test did not find a pinned core; it found there is only one core to pin.

```
ceph0:  nproc = 1,  processors in /proc/cpuinfo = 1,  RAM 7 GB usable
ceph1:  nproc = 1
ceph2:  nproc = 1
```

**Every Ceph measurement in this project was taken on single-core nodes**, each running a mon, an OSD and
an RGW gateway, with the active mgr on `ceph0` as well, all sharing one core.

Consequences:

- **The plateau now has a plausible mechanism.** A single server at ~76% utilisation already shows sharply
  rising queue times, which matches the measured shape exactly: throughput flat past concurrency 8,
  latency rising linearly. **Strongly indicated, not proven** — the settling test is to add vCPUs and
  repeat the sweep. If the plateau moves, the core count was the constraint.
- **The co-residency result is now explained rather than merely observed.** Running Warp on `ceph0` put
  the load generator and the entire storage stack on one core. A 61% throughput loss is the expected
  outcome, not a surprise.
- **Provisioning does not match what was agreed.** The specification put to Baun and to Mr Petrozziello
  was approximately 4 cores, 8-16 GB RAM and 50-100 GB disk per VM. RAM matches at 8 GB; core count does
  not (1 against ~4).
- **Every Ceph performance figure recorded so far must carry the annotation "single-vCPU nodes".** They
  are not wrong, but they characterise a severely under-provisioned deployment rather than Ceph as such,
  and Ceph's own sizing guidance is well above one core per node.

**Actions**: ask Mr Petrozziello to raise the vCPU count to the agreed spec; tell Baun, since it affects
every Ceph number already reported to him; repeat the sweep afterwards and keep the existing curve as the
low-core reference point, since same software, same disks, same network, different core count is itself a
result worth reporting; and monitor `ceph1`/`ceph2` during a run to close candidate 3.

**Data-hygiene note**: the `sar` log for the exploratory sweep was lost. The intended per-level command
was not the one executed — an earlier command was re-run from shell history — and its 600-sample window
closed at about 22:54 while the pinned runs began at 22:58:39, so the two never overlapped. Throughput and
latency are unaffected, as those come from the Warp output files, but resource data for the sweep and for
the pinned runs at concurrency 4 and 8 does not exist. Same class of slip as the missing `-o` flag in
August: the command that ran was not the command intended, and it was only caught afterwards.

### Raising the VMs to 4 vCPUs, and the 1-core versus 4-core comparison (23 September 2026)
The section above proposed, explicitly as a hypothesis, that the single vCPU explained the throughput
plateau, and named the settling test: add cores, repeat the sweep, see whether the plateau moves. This is
that test. Full record in `results/warp-ceph-4core-sweep-2026-09-23.txt`.

**Nothing else changed.** Same Ceph version, same disks, same network, same client node, same tool, same
object size, same run length, same command. Cores raised 1 to 4 per VM in the Proxmox UI (Hardware,
Processors, sockets left at 1), which requires the VM powered off. Done one node at a time with a graceful
Shutdown rather than Stop, confirming `HEALTH_OK` from `ceph0` between each, and `ceph0` last since every
cluster command is issued from it and health cannot be checked while it is down. This brings the cores to
the specification already agreed with Baun and Mr Petrozziello (~4 cores, 8-16 GB RAM); RAM was already at
8 GB. Afterwards: `HEALTH_OK`, 3 mons in quorum, 3 OSDs up and in, 162 pgs `active+clean`, 3 RGWs, with the
active mgr failed over to `ceph1` as expected.

**Result.**

| Concurrency | 1 core | 4 cores | Gain | Latency, 1c to 4c |
|---|---|---|---|---|
| 1 | 34.18 MiB/s | 37.76 | 1.10x | 29.4 to 26.4 ms |
| 2 | 59.95 | 73.62 | 1.23x | 33.3 to 27.3 ms |
| 4 | 79.29 | 121.94 | 1.54x | 50.2 to 32.9 ms |
| 8 | 83.77 | 175.99 | 2.10x | 95.3 to 45.4 ms |
| 16 | 84.45 | 218.33 | 2.59x | 186.8 to 72.2 ms |
| 32 | 91.24 | 263.97 | 2.89x | 339.3 to 119.7 ms |
| 64 | 86.61 | **284.68** | **3.29x** | 711.9 to 222.6 ms |

Zero errors at every level in both sweeps. **The hypothesis is confirmed: the single vCPU was the
constraint.** 284.68 MiB/s is about 2388 Mbps against roughly 727 Mbps before.

Three things the *shape* shows, which a single headline number would hide:

1. **The gain grows with concurrency** — 1.10x at concurrency 1 rising to 3.29x at 64. That is the
   signature of a queueing bottleneck being relieved: at concurrency 1 there is nothing to queue behind, so
   core count barely matters, and the more requests contend the more the extra cores are worth. The whole
   curve belongs in the thesis, not one point from it.
2. **Latency improved most where it was worst**, 187 ms to 72 ms at concurrency 16, 712 ms to 223 ms at 64.
3. **Four times the cores gave at most 3.29x throughput.** Sublinear, as expected, and the deficit is
   itself informative.

Little's Law holds within 2% at all seven levels of the 4-core sweep, as it did at all seven of the
1-core sweep.

**Where the limit sits now.** Per-level slicing was possible this time because each level was timestamped
on the client while `sar` ran continuously on `ceph0`. (`sar` writes timestamps in 12-hour format with a
separate AM/PM field, which any slicing script must account for.)

| Conc. | CPU busy | idle | disk write | disk util | await | queue |
|---|---|---|---|---|---|---|
| 1 | 18% | 81.62 | 36.5 MB/s | 29% | 0.96 ms | 0.30 |
| 4 | 52% | 47.65 | 111.0 | 59% | 1.16 | 1.16 |
| 16 | 73% | 26.83 | 190.4 | 73% | 2.04 | 2.14 |
| 32 | 80% | 20.15 | 217.3 | 77% | 2.40 | 2.54 |
| 64 | 83% | 17.42 | 226.0 | 77% | 2.64 | 2.75 |

CPU cost per unit throughput *improves* with concurrency, from 0.49 percentage points of CPU per MiB/s at
concurrency 1 to 0.29 at 64, so batching pays. At concurrency 64 CPU is 83% busy and the disk 77% utilised,
queue depth 2.75, service waits up from 0.96 to 2.64 ms, and disk throughput flattens between 32 and 64
(+4%) while client throughput still rises (+7.8%).

**Conclusion, at the strength the evidence supports: the 4-core plateau is not a single bottleneck.** CPU
and disk approach saturation together, which is why gains taper rather than stop. Neither is individually
decisive and naming one would be wrong. The network remains irrelevant, 284 MiB/s against a measured
8.64 Gbit/s path.

**Caveats, recorded rather than smoothed over:**

- Single run per level. Exploratory, establishing shape, exactly as the 1-core sweep was. Citable figures
  need repetition at the levels of interest.
- Each level's `sar` window includes Warp's setup and cleanup either side of the measured 60 s, so the
  resource averages **understate** the true peak during the measured period.
- Only `ceph0` was monitored. `ceph1` and `ceph2` carry OSD work and have never been observed during a run.
- The knee has moved to around concurrency 32 and throughput was **still rising at 64**, so this curve may
  not have reached its plateau at all. Extending to 128 would settle it.

**Consequence for every earlier Ceph number.** All of them were taken on single-vCPU nodes and understate
the system by up to 3.3x at high concurrency. They are not discarded — they become the low-core reference
point, and the pair of curves is a result in its own right. But no earlier Ceph figure may be presented as
characterising Ceph without that annotation.

### Object-size sweep, the cost model, and where the ceiling actually is (23 September 2026)
With every hardware explanation for the plateau eliminated (network, gateway, node CPU and disk, and the
shared storage backend), the remaining question was whether Ceph's cost is charged per operation or per
byte. Concurrency held at 8, object size varied. Full record in
`results/warp-ceph-objectsize-2026-09-23.txt`.

| Size | Conc. | Throughput | Ops/s | Latency | Per connection |
|---|---|---|---|---|---|
| 50 KiB | 8 | 23.72 MiB/s | 485.87 | 16.4 ms | 2.97 MiB/s |
| 1 MiB | 8 | 171.13 | 171.13 | 46.5 ms | 21.39 |
| 16 MiB | 8 | 262.02 | 16.38 | 516.7 ms | 32.75 |
| 100 MiB | 8 | 271.00 | 2.71 | 2951.7 ms | 33.88 |
| 1 GiB | **2** | 254.64 | 0.25 | 8031.7 ms | 127.32 |

**The cost model.** Fitting latency against object size across the concurrency-8 points gives

> request latency = **15.2 ms fixed + about 31 ms per MiB** (at concurrency 8)

Checked against every point rather than asserted: 50 KiB predicted 16.7 ms against 16.4 measured;
100 MiB predicted 3145 ms against 2952 measured; throughput at 1 MiB predicted 172.0 MiB/s against 171.13
measured; at 50 KiB predicted 23.8 against 23.72. **The model holds across a 2000-fold range of object
size.** Refitting on the 100 MiB point gives 29.4 ms/MiB, so the slope declines slightly at large sizes
while the fixed term stays at about 15 ms.

**What it means.** There is a fixed cost of roughly 15 ms per PUT independent of size: HTTP handling,
SigV4 verification, a bucket index update, and waiting for three replica acknowledgements. Its share of
each request is ~93% at 50 KiB, ~33% at 1 MiB, ~3% at 16 MiB and ~0.5% at 100 MiB.

**The ceiling, and what concurrency is actually for.** The aggregate ceiling is roughly 270-290 MiB/s and
object size does not move it. What size changes is *how much concurrency is needed to reach it*:

- 1 GiB objects reach 254.64 MiB/s with **2** connections
- 100 MiB objects reach 271.00 MiB/s with **8**
- 1 MiB objects need **64** to reach 284.71
- 50 KiB objects cannot reach it at any concurrency tested

Per-connection bandwidth says the same thing from the other direction: 127 MiB/s per connection at
concurrency 2, but 34 MiB/s at concurrency 8. The connections share one aggregate ceiling rather than each
getting their own.

**Relation to existing literature.** The TU Munich PVLDB 2023 paper already in the source log reports small
objects as latency-bound and large objects becoming bandwidth-bound in the 8-32 MB region. This sweep
reproduces that independently, on a different system, with a fitted constant rather than a qualitative
claim — the transition here sits between 1 MiB (33% overhead) and 16 MiB (3%), consistent with that range.
For Related Work this is corroboration rather than citation.

**Capacity — the first 1 GiB attempt failed.** At concurrency 8 it produced 709 errors reading
"insufficient capacity". Eight concurrent 1 GiB uploads is 8 GiB in flight, 24 GiB after replication, on
top of data already written and the parts of failed uploads. A 96 GiB cluster cannot sustain that shape.
**This is a limitation of the test environment, not a Ceph defect** — Ceph refused the writes, said why,
stayed `HEALTH_OK` and recovered without intervention. Re-run at concurrency 2, which fits. The
concurrency difference is stated wherever the 1 GiB figure appears, and the sample is small (about 15
objects) though variance was low at 2%.

**Three operational findings worth keeping:**

1. **Deleted capacity does not return immediately.** RGW garbage collection reclaims asynchronously, by
   default hourly. 37 GiB showed as used after runs whose objects had already been deleted;
   `radosgw-admin gc process --include-all` reclaimed 35 GiB of it at once.
2. **Removing a bucket does not clean up aborted multipart uploads.** After
   `radosgw-admin bucket rm --purge-objects --bypass-gc` succeeded and the bucket left `bucket list`, the
   data pool still held 4,110 objects and 16 GiB stored (48 GiB raw). A second GC pass *after* the removal
   cleared them. Order matters: GC before the purge does not catch them.
3. **Multipart upload is exercised and works.** `minio-go` switches to multipart above 16 MiB, so the
   100 MiB and 1 GiB runs demonstrate it against Ceph RGW — a row in the compatibility matrix obtained as
   a by-product.

**Open after this:** resource data per object size is not yet analysed (the `sar` log for the first three
sizes exists and is sliceable; the 100 MiB and 1 GiB runs had no monitoring); whether 8 vCPUs beats 4 is
untested and is the last hardware variable not yet moved; and disk capacity is 32 GB per VM against an
agreed specification of 50-100 GB, which should be expanded only after the current curve is complete so
the sweep describes one unchanged cluster.

### Small-object write amplification in Ceph, traced to a measured cause (24 September 2026)

Full record in `results/ceph-smallobject-writeamplification-2026-09-24.txt`.

This began as housekeeping and turned into the strongest mechanistic finding in the Performance chapter so
far. It is recorded in the order it actually happened, including the hypothesis that was falsified on the
way, because the falsification is part of the evidence.

**Bucket cleanup, and the GC behaviour reproduced.** Eight leftover Warp buckets were removed with
`radosgw-admin bucket rm --purge-objects`, followed by `radosgw-admin gc process --include-all` *after* the
removal. The cluster went from 51 GiB raw used (45 GiB free, `default.rgw.buckets.data` holding 4.10k
objects and 16 GiB stored) to 3.4 GiB used (93 GiB free, 4 objects, 3.0 MiB stored). 48 GiB reclaimed.

This is the **second** occurrence of the behaviour first recorded on 23 September, which promotes it from a
one-off observation to a repeatable one. The previous cleanup ended at 3.1 GiB and this one began at 51 GiB,
so the debris accumulated from runs performed after that cleanup; which specific run produced it is not
established and is not claimed here.

**Per-object-size resource data.** The `sar` log left open on 23 September was sliced using the level markers
recorded on ceph2 (note again that `sar` writes 12-hour timestamps with a separate AM/PM field, so the
19:03:54 marker is matched as `07:03:54 PM`):

| Object size | user | sys | iowait | idle | busy | disk write | util | await | queue |
|---|---|---|---|---|---|---|---|---|---|
| 50 KiB | 32.73 | 20.89 | 7.84 | 38.52 | 61% | 41.1 MiB/s | 62% | 0.65 ms | 1.01 |
| 1 MiB | 36.75 | 25.32 | 6.60 | 31.30 | 69% | 147.8 | 67% | 1.57 | 1.69 |
| 16 MiB | 39.10 | 25.66 | 5.01 | 30.20 | 70% | 243.1 | 65% | 4.83 | 2.96 |

Client-side throughput for the same three runs was 23.72, 171.13 and 262.02 MiB/s.

Two things stand out. First, **CPU is nearly flat while throughput moves eleven-fold**: the CPU cost per
MiB/s delivered is 2.57 percentage points at 50 KiB, 0.40 at 1 MiB and 0.27 at 16 MiB, a ten-fold efficiency
difference. This corroborates the latency-fitted cost model of 23 September from an independent direction —
the fixed per-request cost is CPU work, and small objects pay it per tiny object.

Second, **disk writes do not track delivered bytes at 50 KiB**. Comparing ceph0's disk write rate against
client throughput gives 1.73x at 50 KiB, 0.86x at 1 MiB and 0.93x at 16 MiB. Under 3x replication across
three OSDs each OSD should write roughly 1x the client rate; the two figures slightly under 1.0 are
explained by each `sar` window including Warp's setup and teardown, which dilutes the average. 50 KiB at
1.73x is the outlier and is a real effect.

Neither CPU nor disk was saturated at any size, so at concurrency 8 ceph0 is not the constraint. Disk
utilisation was flat at 62-67% across all three sizes while `await` rose from 0.65 ms to 4.83 ms and queue
depth from 1.01 to 2.96 — the same time busy, servicing much larger requests.

**A hypothesis, and its falsification.** The first explanation offered for the 1.73x was BlueStore minimum
allocation size padding. `ceph config get osd bluestore_min_alloc_size_hdd` returned **4096**. A 50 KiB
object rounds up to 52 KiB on a 4 KiB allocation unit, which is 4% padding and nowhere near 1.73x. **The
hypothesis is falsified**, and it is left here rather than deleted. Worth keeping separately: older Ceph
defaulted this to 64 KiB, which would have been punishing for small objects; Tentacle ships 4 KiB, so Ceph
is already well tuned at the allocation layer.

**The actual mechanism.** `ceph config get osd bluestore_prefer_deferred_size_hdd` returned **65536**.
Writes below 64 KiB take BlueStore's deferred path — data goes into the write-ahead log first and is written
to the device again afterwards — while writes above it go straight to the device once. 50 KiB is below the
threshold; 1 MiB and 16 MiB are above it, and RGW stripes large objects at 4 MiB so every stripe is above it
too.

That fits all three measurements, but fitting is not proof. It was therefore tested directly.

**The controlled test.** Two uploads of equal total size and different object size, with BlueStore's
deferred-write counters read either side. 200 files of 51,200 bytes (9.77 MiB total) against 10 files of
1,048,576 bytes (10.00 MiB total), random content so compression cannot interfere, counters read via
`ceph tell osd.0 perf dump bluestore`:

| Point | `issued_deferred_writes` | `issued_deferred_write_bytes` |
|---|---|---|
| baseline | 64,693 | 1,580,662,784 |
| after 200 x 50 KiB | 65,093 (**+400**) | 1,591,312,384 (**+10,649,600**, 10.16 MiB) |
| after 10 x 1 MiB | 65,093 (**+0**) | 1,591,312,384 (**+0**) |

Identical payload volume. The small-object batch put 10.16 MiB through the write-ahead log, slightly more
than its own 9.77 MiB payload; the large-object batch put nothing through it at all. The +400 for 200
objects is two deferred writes per object, and the 409,600-byte excess over payload is exactly 2,048 bytes
per object — the deferred metadata write accompanying each data write.

The counters come from `osd.0`, which lives on **ceph1**, while the `sar` amplification data came from
**ceph0**'s disk. Two different nodes showing the same behaviour, which strengthens the result.

**Why the HDD profile applies at all.** `cat /sys/block/sdb/queue/rotational` returns **1**, and
`ceph osd tree` shows all three OSDs as `CLASS hdd`. The guest kernel reports the virtual disk as rotational,
Ceph classes it as `hdd`, and the `hdd` tuning profile selects the 64 KiB deferred threshold. The SSD default
for this setting is 0, meaning no deferred writes at all.

The complete chain, with every link measured rather than assumed:

```
/sys/block/sdb/queue/rotational = 1
  -> Ceph device class = hdd
    -> bluestore_prefer_deferred_size_hdd = 65536
      -> objects under 64 KiB written twice
        -> 1.73x disk write amplification at 50 KiB
```

**What it means.** The small-object penalty in Ceph is not only latency. For the same delivered bytes,
sub-64-KiB objects cost twice the physical writes, which halves effective write bandwidth and doubles device
wear on a small-object workload. This is a tunable and a deliberate trade, not a defect: deferred writes
exist to make small writes fast on rotational media by batching them into the log, and the cost is paid in
write volume. For a self-hosted private cloud deployment, the practical point is that device class detection
silently selects a tuning profile, and on virtualised storage that detection may not reflect the physical
media.

**Open, stated rather than glossed.** Whether the storage physically under the Proxmox host is rotational is
**unknown** — virtio disks commonly report `rotational=1` regardless of the backing media, and this Proxmox
account has VM-level rights only with no node-level view, so it cannot be said that Ceph is *misclassifying*
the device, only that the classification follows what the guest kernel reports. Whether setting
`bluestore_prefer_deferred_size_hdd` to 0 removes the amplification, and what that does to small-object
latency, is untested; that is the experiment that would turn this observation into a recommendation. And the
100 MiB and 1 GiB runs had no `sar` monitoring, so the resource table covers three of the five sizes only.

### Disk expansion turned into an OSD count and placement group scaling test (25 September 2026)

Full record in `results/ceph-osd-and-pg-scaling-2026-09-25.txt`.

**Why this happened.** Disk expansion to the agreed 50-100 GB per VM spec was already due. A second
32 GB disk was added to each node in Proxmox (matching bus/storage/iothread on the existing OSD disk,
no SSD emulation, so `rotational` stays 1 and the device class stays `hdd`), intending to compare a
3-OSD and 6-OSD cluster at concurrency 64, 1 MiB objects, three runs per point.

**It did not go as planned, and that turned out to matter.** The cluster's OSD spec
(`osdspec_affinity: all-available-devices`) claimed the new disks and built OSDs automatically before
any deliberate step was taken - confirmed via `ceph-volume lvm list`, which showed the same cluster
fsid on the new devices. That same check surfaced something unexamined until now: the data pool
`default.rgw.buckets.data` had been running with **`pg_num=1`** for every Ceph benchmark ever run on
this cluster. A placement group is Ceph's unit of write parallelism, and a single PG serialising every
write through one primary OSD was a plausible dominant explanation for the ~280 MiB/s ceiling found on
23 September. A two-point test became a three-point test isolating OSD count from PG count.

**Results, three runs per point:**

| Condition | Mean throughput | vs baseline |
|---|---|---|
| 3 OSD, 1 PG (baseline, confirmed before any change) | 279.79 MiB/s | - |
| 6 OSD, 1 PG (PG forced back down, isolates OSD count) | 270.24 MiB/s | -3.4% |
| 6 OSD, 256 PG (autoscaler default after disks added) | 304.71 MiB/s | +8.9% |

**Doubling OSD count gave nothing** - if anything a small loss, no overlap between the 3-OSD and
6-OSD/1-PG sets. Consistent with the 23 September finding that the shared storage backend sustains far
more throughput (~3.7 GB/s measured) than the cluster ever uses, so extra OSD daemons add coordination
cost without adding usable bandwidth - plausible given that prior measurement, but not separately
proven here.

**PG count did matter**: +12.8% between the two 6-OSD conditions, with nothing else changing. **This
corrects the hypothesis that motivated the test.** A single-PG bottleneck as a *dominant* explanation is
not supported; the effect is real but modest, not the order-of-magnitude change true serialisation would
produce. The 23 September conclusion - CPU and disk approaching saturation together, with neither
individually decisive - stands, with pg_num=1 added as a confirmed secondary factor rather than a
replacement cause.

**Resource data (ceph0 only, measurements 2 and 3 only - the 3-OSD baseline's `sar` was started on the
wrong host and is lost, the same class of slip as the missing per-level `sar` in the first sweep).** CPU
cost per MiB/s delivered was nearly identical at both PG counts (0.197 vs 0.206), and disk write bytes
as a fraction of client throughput was the same ratio both times (0.511 vs 0.510). Neither run
approached saturation (39% and 32% disk util). So on ceph0 specifically, the PG-driven gain is not
explained by this node working harder; it most likely reflects better write parallelism spread across
all 6 OSDs cluster-wide, which single-node data cannot directly show, since ceph1 and ceph2 were never
monitored in this test.

**State left afterward**: `default.rgw.buckets.data` restored to `pg_num=256` with autoscaling back on
(this is what the cluster would have converged to anyway). Cluster: 6 OSDs, HEALTH_OK, 192 GiB total raw
capacity, meeting the agreed 50-100 GB per VM specification.

### S3 compatibility probe on SeaweedFS, RustFS and Garage, with cross verification (30 September 2026)

Full record in `results/s3-compat-three-systems-2026-09-30.txt`, matrix in `results/compat-matrix-2026-09-30.tsv`.
Canonical runs: `compat-seaweedfs-20260930-205945`, `compat-rustfs-20260930-210446`, `compat-garage-20260930-210449`,
stored as `results/<run>.tar.gz` (about 500 small evidence files each, extract with `tar -xzf results/<run>.tar.gz -C results`).

**What was built.** `scripts/s3-compat.sh` runs 22 tests (C01 to C22) against one endpoint and saves the
command, stdout and stderr of every request, so each matrix cell traces to a raw server reply.
`scripts/s3-compat-run.sh` runs it for SeaweedFS, RustFS or Garage with credentials passed inline from
`~/.thesis-s3-env`, so nothing is exported and nothing needs unsetting. Verdicts are PASS, FAIL (differs from
documented AWS S3 behaviour), UNSUPPORTED (the server answered NotImplemented) and SKIP. A FAIL means "differs
from AWS", not "defective". AWS itself has disabled ACLs on new buckets by default since 2023, so the ACL
tests measure legacy behaviour.

**Targets.** Three single node Docker containers on the laptop. SeaweedFS `chrislusf/seaweedfs`
`sha256:c42a5268ca13...` (Server header "SeaweedFS 30GB 4.25"), RustFS `rustfs/rustfs` `sha256:fa19210ac469...`,
Garage `dxflrs/garage:v1.0.0` `sha256:0c7ed80d22c0...`. Clients: AWS CLI 2.36.8 and curl 8.5.0. Ceph has not been
run through the probe yet.

| Result | SeaweedFS | RustFS | Garage |
|---|---|---|---|
| PASS | 18 | 18 | 7 |
| FAIL | 4 | 4 | 9 |
| UNSUPPORTED | 0 | 0 | 6 |

**How a FAIL was verified.** Five steps in order: read the raw saved reply, repeat with curl (which also
shows the HTTP status the AWS CLI hides), read the server log for the exact moment and the source of the exact
version if the log is silent, explain the cause with two scratch containers from the same image that differ in
exactly one setting, and run the same check on the other systems as a control. The scripts are
`verify-bucket-delete.sh`, `verify-sse-acl.sh`, `verify-acl-enforcement.sh`, `verify-key-limits.sh` and
`verify-raw-http.sh`.

**Two probe faults were caught this way, and one cross check was itself wrong.**
1. The probe first reported a missing `KeyCount` for SeaweedFS. I described it as a server difference, which was
   wrong. The AWS CLI drops `KeyCount` when it paginates automatically, and `--no-paginate` returns `KeyCount 0`.
   That claim is withdrawn.
2. The ACL test used one prefixed key, which hid that SeaweedFS handles flat keys. It now tests both.
3. The first curl test of the trailing slash key was invalid: `curl -T file URL/` appends the file name when the URL
   ends in a slash, so it uploaded to a different key. RustFS and Garage returned 404, which contradicted the CLI,
   and that contradiction exposed it. Redone with `--data-binary`.

**SeaweedFS, proven.**
1. Deleting a non empty bucket succeeds and the data is destroyed. AWS CLI and curl agree (HTTP 204), and the
   server log shows the volume files removed at that moment (a 112 byte `.dat` and 16 byte `.idx`, against 8 and 0
   for the empty volumes). RustFS and Garage refuse with 409 `BucketNotEmpty` using the same script. The cause is the
   option `-s3.allowDeleteBucketNotEmpty`, which the build's own help gives as "allow recursive deleting all entries
   along with bucket (default true)". Two containers from the same image differing only in that flag: the default
   deletes everything, `false` answers 409 `BucketNotEmpty` and the object survives.
2. The SSE-S3 header returns a bare HTTP 500 and stores nothing. The same image with and without
   `WEED_S3_SSE_KEY`, identical otherwise, gives 500 without and 200 with. With a key set, a plaintext marker was
   found once in the volume files (the plain object) and not for the SSE object, which read back correctly. That
   covers the volume files only, not the filer metadata store. The 4.25 source contains the message "SSE-S3
   encryption is not configured", but I did not trace the call site and the log at `-v=4` showed nothing, so the
   two container result is the proof.
3. A canned ACL fails on keys with a path prefix (HTTP 500) and works on flat keys. Source cause in 4.25: for a
   non versioned object the handler sets `updateDirectory` to the bucket directory, not the object's folder, which
   matches the log line "not found /buckets/.../acl.txt" for the key `c19/acl.txt`.
4. Public read is decided per bucket. An object ACL `public-read` is accepted and listed but anonymous GET stays
   403. A bucket ACL `public-read` makes anonymous GET and LIST return 200, yet `get-bucket-acl` does not list the
   `AllUsers` grant. A bucket policy works. In the source, anonymous requests are allowed by `isBucketPublicRead(bucket)`
   or by the bucket policy and no object ACL is consulted. A bucket can be public without the ACL read back showing it.
5. One path component is limited to 255 bytes (255 accepted, 256 refused with `KeyTooLongError`), while total key
   length up to 1024 bytes is accepted and 1025 refused, equal to the AWS limit. RustFS shows the same two limits.
6. A key ending in `/` accepts a body and reads back as 0 bytes (curl PUT 200, GET 0 bytes; RustFS and Garage
   return all bytes).

**RustFS, proven (two clients).** `list-multipart-uploads` does not list an active upload. A wrong Content-MD5
returns HTTP 500 `InternalError` (AWS 400 `BadDigest`). ACL calls succeed and change nothing, so public read is
never granted and the server fails closed. The 255 byte component limit and the 1024 total limit apply. The SSE-S3
header is accepted and echoed back, but data at rest was not tested.

**Garage, proven.** `NotImplemented` for tagging, versioning, bucket policy, bucket encryption, ACLs and the object
lock configuration, which matches the Garage documentation page on S3 compatibility. Accepted and ignored, confirmed
with curl: `If-Match` with a wrong etag, `If-Unmodified-Since` in the past, `If-None-Match: *` on PUT, two 1 MiB
multipart parts, the SSE-S3 header (not echoed) and object lock headers on a normal bucket. The CORS preflight
answers `*` for every origin including with no CORS configuration, while real requests follow the rules. Reading
CORS or lifecycle configuration after deleting it returns 204 instead of 404. Total keys of 479 bytes are accepted and
480 bytes fail with HTTP 503, with the server's own message "LMDB: MDB_BAD_VALSIZE", where AWS answers 400
`KeyTooLongError` and a 503 is retried by clients.

**Hypotheses.** Garage's limit being the LMDB 511 byte key limit minus a 32 byte prefix (the edge is measured, the
prefix is my reading). Garage storing SSE-S3 data unencrypted (supported by its documentation and the missing echo,
not tested on disk).

**Open.** Ceph was probed afterwards, see the next section. Garage's expired presigned URL returning 400 and its CRC64NVME handling rest on
the AWS CLI run only. RustFS and Garage data at rest were not checked. Everything is single node Docker on one
laptop and describes these builds only.

**Housekeeping.** The verification scripts left test buckets on Garage (four) and RustFS (three) when a system
refused to delete a non empty bucket. They were removed and the scripts now empty the bucket first. The thesis
buckets and containers were never touched, and all `sw-scratch-*` containers were removed.

### S3 compatibility probe on Ceph, an AWS CLI crash, and two real differences (30 September and 2 October 2026)

Full record in `results/s3-compat-ceph-2026-10-02.txt`, matrix in `results/compat-matrix-four-systems-2026-10-02.tsv`.
Evidence files: `results/aws-cli-crash-on-ceph-error-replies-2026-10-02.txt`,
`results/ceph-sse-s3-vault-check-2026-10-02.txt`, `results/verify-checksum-header-*-2026100*.txt`.

**Setup.** The probe was fetched on `ceph0` from the public repository (commit `29e3f00`, 960 lines) and run against
the RGW at `localhost:80` with the same AWS CLI version as the laptop runs. The Debian package on the VM is 2.9.19,
so 2.36.8 was installed with the official installer into `/opt/aws-cli-new` and the system CLI was left alone. The
commands reached the VM through a Claude Code session running on `ceph0` and controlled from the laptop, with the
instruction to print the raw output only. Only that raw output was used as evidence.

**The first Ceph run was invalid.** It ended 11 pass, 11 fail, and nine of the failures were not Ceph. Ceph error
replies carry an empty `<Message></Message>`, and AWS CLI 2.36.8 then crashes with `argument of type 'NoneType' is
not a container or iterable` in `awscli/customizations/s3errormsg.py` (line 55, `_is_sigv4_error_message`) before it
prints the error code, so the probe saw no code. Proven three ways: the raw reply read with `--debug` (HTTP 404,
`NoSuchBucket`, empty `Message`), the line of source at tag 2.36.8, and two local throwaway servers that differ only
in the `<Message>` text (empty: crash, exit 255; with text: correct error, exit 254). The probe now repeats a failed
request once with `--debug` when it sees that crash text, keeps only the status line and reply body, and appends the
code it read to the `.err` file. The three laptop systems give the same verdict on all 22 tests with the patched
probe, and the recovery never triggered there.

**Result on the patched probe: Ceph 20 pass, 2 fail (C18, C20).** C08, C11, C12, C15, C16, C19, C21 and C22, which at
least one other system fails, pass on Ceph.

**C20, proven with two clients and three controls.** Ceph accepts an upload whose `x-amz-checksum-sha256` or
`x-amz-checksum-sha1` header is wrong. The AWS CLI upload with a SHA256 of 32 zero bytes returned success. A curl
script that signs its own requests got HTTP 200 for all four uploads (correct and wrong sha256 and sha1), the object
under the wrong checksum exists with its body intact, and a HEAD with checksum mode returned no checksum header even
for the correct values. SeaweedFS, RustFS and Garage run through the same script refuse the wrong values with HTTP
400 (`BadDigest`, `InvalidDigest` on Garage) and store nothing.

**The curl check first got 403 on Ceph, one change fixed it.** Without an explicit `Content-Type`, all four uploads
got `403 AccessDenied`, including the correct ones. Adding `-H "Content-Type: application/octet-stream"` and nothing
else gave 200. So RGW 20.2.4 refuses an upload that carries an unsigned `Content-Type`, which is the same behaviour
as the Warp finding earlier in this file. The three laptop systems accepted the unsigned header.

**C18, proven cause.** Ceph answers the SSE-S3 header (`--server-side-encryption AES256`) with HTTP 400
`InvalidArgument`, where AWS accepts it. `rgw_crypt_sse_s3_backend` is `vault` on this cluster, no Vault token file is
configured, and the RGW log at the two request times reads `ERROR: Vault token file not set in
rgw_crypt_vault_token_file`, which the v20.2.4 source raises in `load_token_from_file` (`rgw_kms.cc` line 213). SSE-S3
is therefore unavailable here and the header is refused, not silently ignored as Garage does. My first guess, that the
backend setting was not `vault`, was wrong: the cluster says it is, and the log gave the real reason.

**Hypothesis.** Ceph 20.2.4 does not process the `x-amz-checksum-*` request headers at all. Not separated: HEAD against
GET, and the Ceph source was not read for this.

**Open.** Whether a wrong checksum in the trailer form of an aws-chunked upload is detected. SSE-S3 with a configured
Vault and the data on disk. The evidence archive of the canonical run (`ceph-20261002-072634`, 21210 bytes, 584
entries, sha256 `33066ead1076d35061187c8eb4a72b6c9e64b1f0d2c1d83aefca3939fbdaad50`) is on `ceph0`; its 559 files are in the
repository as text (`results/compat-ceph-20261002-072634-evidence.txt`), verified by sha256 block by block. Only the
gateway on `ceph0` was probed, from `ceph0` itself.

---

## Security: presigned PUT with unsigned headers, three systems on the laptop (2 October 2026, written 5 October)

Full record in `results/security-presign-unsigned-header-three-systems-2026-10-02.txt`, raw runs in `results/security-presign-unsigned-header-{seaweedfs,rustfs,garage}-20261002-*.txt`, script `scripts/security-presign-unsigned-header.sh` (sha256 `f1678fc1e4f2559eb33d1c59d3b2e520b97882aa488f27ec4e5aa943a4d0ab92`).

**Why.** The four way SigV4 test of 22 September showed that three systems accept an unsigned `Content-Type`, which AWS also tolerates. It did not show whether they act on unsigned `x-amz-` headers, which is the CVE-2026-54330 vector. This is the test designed at the end of that section.

**Method.** A presigned PUT URL (`SignedHeaders=host`) is built by hand with openssl, because the AWS CLI can only presign GET. One header is added per case without being signed, curl's own `Content-Type` is removed so only that header differs, and an accepted object is read back by a second signed request (HEAD, ACL, content) and by an anonymous GET. Controls: g0 (presigned GET), p0 (nothing extra), s2 and s3 (the metadata and ACL headers inside the signature).

**Result.**

| Unsigned header | SeaweedFS 4.25 | RustFS 1.0.0-beta.8 | Garage v1.0.0 |
|---|---|---|---|
| `x-amz-meta-*` | 403 | 200, applied | 400 |
| `x-amz-acl` | 403 | 200, not applied | 400 |
| `x-amz-tagging` | 403 | 200, applied | 400 |
| `x-amz-storage-class` | 403 | 200, applied | 400 |
| `x-amz-website-redirect-location` | 403 | 200, applied | 400 |
| `x-amz-copy-source`, same bucket | 403 | 200, applied | 400 |
| `x-amz-copy-source`, other bucket | 403 | 200, applied | 400 |

SeaweedFS answers `403 SignatureDoesNotMatch`. Garage answers `400 InvalidRequest`, "Header `x-amz-meta-injected` should be signed". RustFS accepts every case. Read back: `x-amz-meta-injected: yes`, `x-amz-tagging-count: 1`, `x-amz-storage-class: STANDARD_IA` and the redirect header are present, and with an empty body plus an unsigned `x-amz-copy-source` the object holds the source content (19 bytes of g0, and in the second bucket case 25 bytes, "cross bucket source body"). The ACL header has no effect on RustFS even when signed (0 AllUsers grants, anonymous GET 403).

**Limits.** The signer was the admin identity, so the cross bucket copy shows that the header is acted on, not that a permission was bypassed (O1). Whether RustFS applies an unsigned `Content-Type` is not separable, because both p0 and p1 store `application/octet-stream`. Ceph is not run yet (needs the VM). Cause in the RustFS source is not read.

**Hypotheses.** H1: RustFS checks only the headers listed in `SignedHeaders`. H2: Ceph 20.2.4 rejects all these cases after the CVE fix.

**Next.** (1) Scoped identity without read access to the second bucket signs the URL, to settle O1. (2) Run the script on ceph0. (3) Repeat all four on the VMs, as Prof. Baun requires (see below).

### Supervisor ruling on the platform (reply of 22 September 2026, found 4 October)

Prof. Baun replied on 22 September: the software solutions must run on the same platform and be tested with the same parameters, so all of them are to be deployed on the university VMs and tested one after the other. His reply was missed because the university moved the internal mail to Outlook. A follow up mail was sent on 4 October. Consequences: SeaweedFS, RustFS and Garage are deployed on the Proxmox VMs with the same nodes and resources as Ceph, and performance figures come from the VMs. The laptop results stay in the thesis and are labelled as laptop runs next to the VM runs. The compatibility and security scripts are repeated on the VMs.

### Presigned PUT test on Ceph (5 October 2026)

Record `results/security-presign-unsigned-header-ceph-2026-10-05.txt` (it also holds the four system table), raw file `results/security-presign-unsigned-header-ceph-20261005-230914.txt` (79 lines, sha256 `0c9d51ba3593b9e46661341d6643bd8d78de5d0017069c75947995eced776476`, trailing spaces stripped, copy checked by hash against ceph0). The script was fetched on ceph0 from the repository at commit `6917bc3` and its sha256 equals the one recorded above (`f1678fc1...0ab92`).

**Result.** Ceph 20.2.4 rejects all eight unsigned cases (unsigned `Content-Type`, metadata, ACL, tagging, storage class, website redirect, copy source in the same and in another bucket) with `403 AccessDenied`. The controls pass: the presigned GET and a plain PUT give 200, the metadata header inside the signature is accepted and applied, and the ACL header inside the signature is accepted and applied (anonymous GET 200, while p0 and s2 stay private with 403). So the rejection is caused by the header not being signed, and the test can detect an applied header on Ceph.

| | SeaweedFS 4.25 | RustFS 1.0.0-beta.8 | Garage v1.0.0 | Ceph 20.2.4 |
|---|---|---|---|---|
| Unsigned `x-amz-*` headers (all cases) | 403 | 200, five applied | 400 | 403 |
| Unsigned `Content-Type` | accepted | accepted | accepted | 403 |

**Limits.** The ACL read with the owner's credentials returns `403 SignatureDoesNotMatch` on Ceph, so the "AllUsers grants 0" line is not valid for Ceph (cause not investigated, open O6). One run on one gateway, from ceph0 itself. The test shows the behaviour of the patched release, not that an older release accepted the headers, so it does not by itself prove the content of CVE-2026-54330. The RGW source was not read for the reason behind the status code.

## VM disks for the other three systems, and a Ceph orchestrator surprise (5 October 2026)

Baun's ruling (all systems on the same platform, the university VMs) means SeaweedFS, RustFS and Garage are deployed on ceph0, ceph1 and ceph2. Every VM has 4 vCPU, 7.7 GiB RAM, 975 MiB swap and three 32 GB disks (OS disk, two Ceph OSD disks). The free space on the OS disk is only 15 to 20 GB, so two more 32 GB disks were added to each VM in Proxmox (serials `drive-scsi3` and `drive-scsi4`) to give the other systems the same capacity as Ceph's two OSDs per node. Ceph is stopped during the other systems' runs.

**Disk names are not stable.** After the reboot of ceph0 the OS disk was `sda`, the OSDs `sdb` and `sdd`, the new disks `sdc` and `sde`, while before the reboot the OS disk had been `sdc`. All disk work uses `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN` and a check that the disk is empty (`wipefs -n` prints nothing, `blkid` returns 2).

**What went wrong.** The cluster has an OSD service `osd.all-available-devices` (`host_pattern: '*'`, `all: true`, not unmanaged). cephadm turns every blank disk into an OSD. On ceph0 the new disks were formatted as XFS within minutes, before cephadm reached them. On ceph1 and ceph2 the blank disks were claimed as osd.6, osd.7, osd.8 and osd.9 (the cluster went from 6 to 10 OSDs, still `HEALTH_OK`, 449 PGs `active+clean`) between the blank check and the format command. The format command has a guard that checks the disk is empty before `mkfs`, and it aborted on ceph1, so nothing was formatted and no existing OSD disk was written. My mistake: I did not look at the orchestrator spec before the disks were added.

**Fix.** `ceph orch apply osd --all-available-devices --unmanaged=true` (the spec now shows `unmanaged: true`, existing OSDs unchanged), then `ceph orch osd rm 6 7 8 9 --zap`. Ceph drained the four OSDs (few data, 5.3 MiB in 295 objects), purged and zapped them. Afterwards: 6 OSDs up, `HEALTH_OK`, 449 PGs `active+clean`, 192 GiB capacity again, and the four disks listed as available with no reject reason.

**Result.** On all three VMs the two new disks are XFS (labels `s3disk1` and `s3disk2`), mounted at `/srv/s3/disk1` and `/srv/s3/disk2` by UUID with `nofail`, `xfsprogs` installed. Ceph's own disks (`drive-scsi1` and `drive-scsi2`) were not written by anything I ran.

**Permanent change to the Ceph cluster configuration:** the OSD service is unmanaged, so a blank disk added later is not claimed automatically. Say so wherever the Ceph setup is described.

**A tool note.** The Claude Code sessions on the VMs have their own safety classifier. It blocked disk formatting twice, once because its last `lsblk` still showed OSDs on the disks (stale, they had just been removed). A fresh read only `lsblk` and `wipefs` plus the changed facts in the prompt cleared that. Nothing was run in pieces to get around a block.

### Images for SeaweedFS, RustFS and Garage on the VMs (6 October 2026)

podman 4.3.1 is the container runtime on ceph0, ceph1 and ceph2 (docker is not installed). Docker Hub is reachable from the VMs (`HTTP/2 401` on an unauthenticated `/v2/` request). Each VM pulled the same three images by registry digest, which is the digest recorded for the laptop images, so the builds are identical and not "latest" of a later day:

| Image | Digest (same on laptop and all three VMs) | Version printed by the binary on each VM |
|---|---|---|
| `docker.io/chrislusf/seaweedfs` | `sha256:c42a5268ca13fcb65e0fae925886b107f4bf294d8db15e1be5509d55104eb509` | `version 30GB 4.25 7acba59a5 linux amd64` |
| `docker.io/rustfs/rustfs` | `sha256:fa19210ac4697c79d7ccca1ec9b0eb91aebacc6691991ffb14014bb3c67e6cc3` | `rustfs 1.0.0-beta.8`, git commit `64c0ede0261eeb7ccd415221d6f102aa70829b6a`, built 2026-06-10, rustc 1.96.0 |
| `docker.io/dxflrs/garage` | `sha256:0c7ed80d22c0b0f902fbd0ec74fc68073f72a46ea15d54e3c4c484184a8c7516` | `garage v1.0.0` |

Proof on each VM: `podman images --digests` prints the digests above, and the binaries print the version strings above (the SeaweedFS and RustFS strings equal the ones captured from the laptop images on 22 September). Note for readers of the raw output: podman's image id (`7a6dd717...`, `df6c9c72...`, `3754b851...`, the same on all three VMs) differs from the laptop id because Docker on the laptop reports the registry digest as the id and podman reports the content id, and the sizes differ because Docker shows compressed and podman unpacked sizes. The digest and the version strings are the comparison that counts. `podman manifest inspect docker://...` is not supported in podman 4.3.1, so images were pulled directly by digest. Free space on the OS disk after the pull: 15 GB (ceph0), 18 GB (ceph1), 19 GB (ceph2).

## Three node layouts for SeaweedFS, RustFS and Garage on the VMs (design, 6 October 2026)

Status: **design only, nothing deployed yet.** Every statement taken from the vendor documentation is marked (doc) and is untested until a deployment step proves it.

**Common rules.** Nodes: ceph0 (hostname `debian`, 192.168.1.72), ceph1 (192.168.1.71), ceph2 (192.168.1.70). One system runs at a time and Ceph is stopped (`noout` set first). Containers run with podman 4.3.1, `--network host`, the images by digest from the section above. Data goes to `/srv/s3/disk1/<system>` and `/srv/s3/disk2/<system>` (two XFS disks of 32 GB per node, the same capacity as Ceph's two OSDs). No resource limits (the VMs are identical: 4 vCPU, 7.7 GiB RAM). Test credentials are generated per system, kept in a mode 600 file on the VM and never printed. After each deployment: an S3 round trip through every node (write on one, read on the other two), the cluster status commands, and the versions recorded.

**Redundancy is not identical across the four systems, and the thesis must say so.** Ceph: replicated pools, size 3 across 3 hosts (default `osd_pool_default_size` 3, to be confirmed with `ceph osd pool ls detail` when Ceph is restarted). Garage: `replication_factor = 3`, three zones, so every node holds every object. SeaweedFS: replication `002`, three copies on three different volume servers. RustFS: erasure coding over 6 drives, and the docs give EC:3 as the default for 6 to 7 drives per set (doc), so 3 data plus 3 parity shards, two shards per node, 2x raw overhead against 3x for the others. One failed node costs RustFS 2 of 6 shards (still readable), two failed nodes cost 4 of 6 (not readable). The fault tolerance chapter compares what each system survives, not an equal storage overhead.

**Garage v1.0.0 (3 nodes).**
- `garage.toml` per node: `replication_factor = 3`, `db_engine = "lmdb"` and `s3_region = "garage"` as on the laptop, `rpc_bind_addr = "[::]:3901"`, `rpc_public_addr = "<node ip>:3901"`, the same `rpc_secret` on all nodes, `metadata_dir = /srv/s3/disk1/garage/meta`, `data_dir` as a list of two directories with a capacity each (list syntax exists since v0.9.0, doc): `[{ path = "/srv/s3/disk1/garage/data", capacity = "30G" }, { path = "/srv/s3/disk2/garage/data", capacity = "30G" }]`.
- Connect: `garage node connect <id>@<ip>:3901` from two nodes to the third (doc: one direction per pair is enough). Layout: `layout assign <id> -z z1|z2|z3 -c <capacity>` and `layout apply`, then `key create` and bucket create.
- Open: what `-c` means with two data directories (sum of both?). Settled by `garage layout show` after the assign.

**SeaweedFS 4.25 (3 nodes).**
- The laptop ran the all in one `weed server -s3 -s3.config=...`. On the VMs the same command runs on each node with `-master.peers=<three ip>:9333`, `-dir=/srv/s3/disk1/seaweedfs,/srv/s3/disk2/seaweedfs`, `-volume.max=0`, `-master.defaultReplication=002`, the same data center and rack on all nodes (so `002` means two more copies on other servers in that rack), and `-filer -s3` with the same `s3_config.json` and `security.toml` (the JWT signing keys, see Issue 4 above) mounted at `/etc/seaweedfs`. Three masters is the odd number a quorum needs (doc).
- Filers: each node runs a filer with the embedded store. The wiki says that filers find each other through the master and aggregate each other's metadata, and warns that mixing embedded and shared stores is not fine (doc). So an object written through one node's S3 endpoint should be visible through the others. This is a hypothesis until proven. Fallback if it fails: one filer and one S3 gateway on ceph0 only, which would be a single point of failure and has to be reported as a limit.

**RustFS 1.0.0-beta.8 (3 nodes).**
- `RUSTFS_VOLUMES="http://192.168.1.{70...72}:9000/srv/s3/disk{1...2}/rustfs"` (brace expansion with three dots, doc) on every node, plus `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `RUSTFS_ADDRESS=":9000"`, `RUSTFS_CONSOLE_ENABLE`, `RUSTFS_CONSOLE_ADDRESS=":9001"`. Host networking is required for the node to node traffic (noted on 22 August).
- **Real risk:** the docs state that a minimum of 4 servers is required for distributed mode (doc). We have 3, and Baun requires the same number of nodes for every system. Whether RustFS starts, refuses or runs degraded with 3 nodes and 6 drives is unknown and is the first thing the deployment shows. If it refuses, that is a result to report (RustFS cannot run in the required topology), and the choice of a different RustFS topology goes to Prof. Baun. It is not decided silently.

**Order of deployment:** Garage (cluster first by design, a good test of the process), then SeaweedFS, then RustFS (riskiest).

### Ceph stopped on all three VMs (6 October 2026)

Before the stop (ceph0, `ceph osd pool ls detail`): all 8 pools are `replicated size 3 min_size 2` (this confirms the redundancy statement above). Flags `noout` and `norebalance` were set with `ceph osd set`, then the cluster target `ceph-377124a6-acb5-11f1-b854-bc2411d95a65.target` was stopped on ceph1, ceph2 and last on ceph0 (`systemctl stop`). Verified on each host (hostname in the output): target `inactive`, 0 podman containers, RAM available 6.0 GiB (ceph1), 5.5 GiB (ceph2), 6.1 GiB (ceph0), and on ceph0 `/srv/s3/disk1` and `/srv/s3/disk2` still mounted. Nothing was deleted.

**To start Ceph again:** `systemctl start ceph-377124a6-acb5-11f1-b854-bc2411d95a65.target` on ceph0, ceph1 and ceph2, wait for the monitors, then `ceph osd unset noout` and `ceph osd unset norebalance`, and check `ceph -s` for `HEALTH_OK`. The OSD service stays `unmanaged`.

**Tool note:** the stop was blocked in the sessions on ceph0 (twice by the Claude there and once by the harness' own check, which treated resending as a bypass of the earlier refusal) and passed on ceph1 and ceph2. It was finished by running the command in the Proxmox console of ceph0. The `!` prefix does not run in the web view of a Remote Control session.

## Garage v1.0.0 on the three VMs (8 October 2026)

First system deployed on the university VMs under Prof. Baun's ruling (same platform for all systems). Scripts: `deploy/garage/` at commit `adf5690` (five scripts fetched from the pinned commit, sha256 of all five equal to the local files on ceph0, ceph1 and ceph2).

**Steps and evidence** (hostname printed in every output):
1. The RPC secret was made on ceph0 (`garage-secret.sh create`, 65 bytes incl. newline, mode 600, never printed) and copied to ceph1 and ceph2 by `scp` typed by the user (ssh from ceph0 to the others had no key, both refused with `Permission denied (publickey,password)`). First attempt failed because the wrong password was typed (ceph1 `sshd -T`: `permitrootlogin yes`, `passwordauthentication yes`). Fingerprint (sha256 of the file) is identical on the three VMs, mode 600, 65 bytes.
2. `garage-node.sh` on each VM: container `garage Up`, the pinned image digest `sha256:0c7ed80d...`, node ids `f3ef27cd...` (ceph0, `debian`), `f8b9d17e...` (ceph1), `b33b45c3...` (ceph2). The ids of ceph1 and ceph2 given to the cluster script were checked by the sha256 of the id string on the VM against the sha256 of the transcription (both equal).
3. `garage-cluster.sh` on ceph0: connect, layout with one zone per node (`z1` ceph0, `z2` ceph1, `z3` ceph2), `-c 60GB` per node, `layout apply --version 1`, key `thesis-key` (secret masked in the output, file mode 600), bucket `thesis-test-bucket`.
4. Strict re-check on ceph0 (`garage status`, `garage layout show`, output sha256 `c8d1a44f...315e`, equal to the hash of my transcription): layout version 1, three healthy nodes, zones z1, z2, z3, 60.0 GB each.
5. `garage-roundtrip.sh` on ceph0 (11:48:38Z): 12 of 12 PASS (1 KiB and 1 MiB objects, written through each node and read through the other two, sha256 equal), list on all three endpoints returns 0 objects after cleanup, `RESULT all passed`. Raw record: `results/garage-roundtrip-vm-3node-20261008-134838.txt` (sha256 `97cfe2bb3875ac68a0cda03dd35b847e09dd9bde0cbf9c3acd35df514fae4e67`, equal to the file hash printed on ceph0).

**What is proven:** a three node Garage cluster with replication factor 3 and one zone per node runs on the VMs, and objects are readable through every S3 endpoint after being written through any other.

**What is not proven yet:** that every object really has three copies (the roundtrip does not count copies), behaviour under load, the failure behaviour. The 60.0 GB capacity is the value I assigned with `-c 60GB`, it is not measured from the two data directories (open question on `-c` with two data directories stays open).

**Tool note:** the Claude session on ceph0 retyped the first status table instead of copying it and mislabelled the ceph1 row (`[ceph2] z3`), then added a correction itself. Because of this, VM output that matters is now taken from compact commands that print a sha256 of their own output, and compared with the sha256 of my transcription. The table on the first run is not used as evidence.

**State now:** Garage is running on all three VMs (containers `garage`), Ceph stopped. The Garage data stays on `/srv/s3/disk1/garage` and `/srv/s3/disk2/garage`.

## SeaweedFS three node scripts and laptop test (8 October 2026)

Scripts for the VMs are in `deploy/seaweedfs/` (secret and config creation, node start, roundtrip, stop). First run on the VMs: see the section "SeaweedFS on the three VMs" at the end.

**Laptop test of the planned flags** (pinned image digest `c42a5268...`, three containers `sw0`, `sw1`, `sw2` on one Docker network, embedded filer stores, flags as planned: `-master.peers`, `-dir` with two directories, `-volume.max=0,0`, `-master.volumeSizeLimitMB=1024`, `-master.defaultReplication=002`, same data center and rack, `-filer -s3`):
- The three masters formed one cluster (`IsLeader` true on sw0 with two peers), three volume servers appeared in the topology, 1904 volume slots each.
- Written through sw0, the 1 MiB object was identical when read through sw0, sw1 and sw2 (`cmp`). Written through sw2, identical when read through sw1. The bucket made on sw0 was listed on sw1. So the filers share metadata in this setup. This settles the hypothesis from the layout design for the laptop. It is not yet proven on the VMs (different network mode).
- After the writes each node directory held three `.dat` files. That is a count and fits replication 002, it is not a proof of three copies per volume.
- First run: one of the three containers (sw2) was not running 30 seconds after the start. The log was not captured, so the cause is unknown. The second run started all three. Open: whether a start race exists. The VM script prints the container state and can be rerun.
- My own test mistakes in the first run: the bucket name `rt` is shorter than the three characters S3 needs.

**Deliberate difference from the laptop single node run:** `-master.volumeSizeLimitMB=1024`, because the default of 30000 MB does not fit the 32 GB disks (the laptop topology reported `30GB 4.25 7acba59a5`). This must be named in the thesis when SeaweedFS figures from the laptop and from the VMs are compared.

### Garage on the VMs: compatibility probe and presigned PUT (8 October 2026)

Run on ceph0 by `deploy/garage/garage-tests.sh` (commit `ef0da01`), which fetches the two test scripts at commit `c798c4d` and stops if their sha256 differs. Record: `results/garage-vm-compat-and-presign-2026-10-08.txt`.
- **Compatibility probe, 22 tests:** 7 PASS, 9 FAIL, 6 UNSUPPORTED. The `summary.tsv` has sha256 `bef96583...960fb` on ceph0, the same as the laptop single node file of 30 September. So all verdicts and sub-check details are identical, the three node cluster changed nothing here.
- **Presigned PUT:** p2 to p8 (every unsigned x-amz header case) answer 400 InvalidRequest, the controls answer 200, same as the laptop. One difference: the ACL read of the control objects answers 403 AccessDenied (Invalid signature) on the VMs and 501 NotImplemented on the laptop. Normalized comparison: changing the four 501 lines to 403 reproduces the VM hash exactly, so nothing else differs.
- **H3 settled on ceph0 the same day:** curl 7.88.1 signs the valueless `?acl` query wrongly. Garage answered 403 Invalid signature to `?acl`, 501 NotImplemented to `?acl=`, and NotImplemented to the AWS CLI `get-object-acl`. So the cluster is not the cause. Not proven: curl 8.5.0 on the laptop (not retested). Ceph O6 shows the same pattern but stays open until Ceph runs again (test: `?acl=`). The scripts send `?acl`, so ACL reads through curl on ceph0 are unreliable until a decision is made to change the scripts to `?acl=`.
- Evidence archives stay on ceph0 (sha256 in the record), the key never appeared in them (0 files).

### Garage on the VMs: four further checks (8 October 2026)

Record: `results/garage-vm-extra-checks-2026-10-08.txt`.
- **G1 three copies, proven:** a 3 MiB object written through ceph0 added the same three block files (1 MiB plus 37 bytes each) on all three VMs, and the sha256 of the sorted file names is identical on all three. Not proven: byte identity of the blocks, and the spread over the two data directories (all three blocks went to disk1).
- **G2 multipart, proven with a condition:** a 100 MiB object (13 parts) written through ceph0 and read through ceph2 is identical, after the CLI was told `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`. **Finding F1:** with the default settings of AWS CLI 2.36.8 the multipart upload to Garage v1.0.0 fails with `InvalidRequest: invalid checksum algorithm`. Every load tool in the performance phase must use the same checksum setting on all four systems.
- **G3 restart persistence, proven:** containers removed and recreated on all three nodes. Same node ids, same layout and status hash (`c8d1a44f...315e`), the G1 object and the G2 object read back identical through ceph1. Not tested: unclean stop, a node down longer than the others (fault tolerance phase).
- **G4 admin API:** no admin token and no metrics token set. `/health` and `/metrics` answer 200 without credentials from the LAN, `/v1/status`, `/v1/bucket`, `/v1/key` answer 403. Belongs to the security phase.

## SeaweedFS on the three VMs (8 October 2026)

Second system on the VMs. Garage was stopped first on ceph2, ceph1, ceph0 (`garage-stop.sh`, `containers left: 0` on each, data kept). Scripts: `deploy/seaweedfs/`, four scripts fetched at commit `c798c4d` and checked with `sha256sum -c` on all three VMs (all OK), later `seaweedfs-node.sh` again at commit `4325e39` (sha256 `0f132333...75ac`).

**Steps and evidence** (hostname printed in every output):
1. `seaweedfs-secret.sh create` on ceph0 made `/root/seaweedfs-config` (three files, mode 600, directory 700, never printed). The directory was copied to ceph1 and ceph2 with `scp -rp` typed by the user. The fingerprint (modes, sizes, sha256 of the three files) gives the same output hash `bf7227df...d4a4` on all three VMs.
2. The pinned image digest `sha256:c42a5268...eb509` was pulled on all three (image id `7a6dd7173f8015fb178a`, same digest shown).
3. **First start failed on all three VMs:** container `seaweedfs Exited (255)`. Log on ceph0: `master.go:234 please verify /srv/s3/disk1/seaweedfs is writable ... mkdir /srv/s3/disk1/seaweedfs/m9333: permission denied`. Cause found by tests on ceph0: the image entrypoint `/entrypoint.sh` drops to the user `seaweed` (uid 1000, `su-exec seaweed`) and only fixes the ownership of `/data`, while our data directories (root, 755) and the config (root, 600) belong to root. A throwaway container run as root with `--entrypoint sh` could create the directory (`mkdir-ok`), so the cause is the user switch. This is a difference from the laptop test, which did not hit it.
4. **Fix:** `seaweedfs-node.sh` now runs `chown 1000:1000` on the two data directories and `chown -R 1000:1000` on the config directory before starting the container (commit `4325e39`). Rerun on all three: `seaweedfs Up`, `version 30GB 4.25 7acba59a5 linux amd64`, `master status (answered: 1)`.
5. `seaweedfs-roundtrip.sh` on ceph0 (17:27:40Z, endpoints on port 8333, region us-east-1): 12 of 12 PASS (1 KiB and 1 MiB objects written through each node and read through the other two, sha256 equal), list on all three endpoints returns 0 objects after cleanup, `RESULT all passed`. Leader `192.168.1.70:9333` (ceph2), three volume servers `192.168.1.70:8080`, `.71:8080`, `.72:8080`. Raw record: `results/seaweedfs-roundtrip-vm-3node-20261008-192740.txt` (sha256 `087048cf84e96e9e9364ce4da899381c8b9ee85461086105687b64c205c8ff4f`, equal to the file hash printed on ceph0 after one byte, a trailing space on line 4, was restored in my copy).

**What is proven:** a three node SeaweedFS cluster (three masters, three volume servers, three filers with S3) runs on the VMs under the pinned image, and objects written through any S3 endpoint read back identical through the other two. The embedded filer metadata is shared across the nodes on the VMs as well (a bucket created through ceph0 was usable through the other endpoints).

**What is not proven yet:** that every volume really has three copies (replication 002 is configured, the roundtrip does not count copies), behaviour under load, failure behaviour, the compatibility probe and presigned PUT results on SeaweedFS on the VMs. The run as the non root user `seaweed` is a property of the image and is part of the setup.

**Tool note:** the Claude session on ceph0 added a "correction" comment of its own to one copied output (about a comment line in the entrypoint) although told not to. The reading of the entrypoint (`su-exec seaweed`, `chown -R seaweed:seaweed /data`, uid 1000) is from its direct lines and fits the observed error.

**State now:** SeaweedFS is running on all three VMs (container `seaweedfs`), Garage and Ceph stopped.

### SeaweedFS on the VMs: compatibility probe and presigned PUT (8 October 2026)

Run on ceph0 by `deploy/seaweedfs/seaweedfs-tests.sh` (commit `080a8c7`), which fetches the two test scripts at commit `c798c4d` and stops if their sha256 differs. Record: `results/seaweedfs-vm-compat-and-presign-2026-10-08.txt`.
- **Compatibility probe, 22 tests:** 18 PASS, 4 FAIL (C18, C19, C21, C22), 0 UNSUPPORTED. The `summary.tsv` has sha256 `ab8f1522...eb61`, the same as the laptop canonical single node run `compat-seaweedfs-20260930-205945` (ceph0 confirmed it with `sha256sum -c` against the laptop value). So all verdicts and sub-check details are identical, the three node cluster changed nothing here.
- **Presigned PUT:** p2 to p8 (every unsigned x-amz header case) answer 403, the controls answer 200, the anonymous GET answers 403, same as the laptop. One difference, found with per line fingerprints of the normalized view: the four ACL reads of the control objects answer 403 SignatureDoesNotMatch on the VMs and 200 on the laptop. Replacing that one value in the laptop list reproduces the VM list hash, so nothing else differs. In this run the line "AllUsers grants in ACL 0" carries no information (it counts an error reply).
- **H3 settled on ceph0 the same day (second system):** curl 7.88.1 answers 403 SignatureDoesNotMatch to `?acl` and 200 to `?acl=`, and the AWS CLI `get-object-acl` returns the Owner and the Grants. So SeaweedFS is not the cause, the valueless query sent by curl 7.88.1 is. Same pattern as Garage. Not proven: curl 8.5.0 on the laptop (not retested). Ceph O6 still open (Ceph stopped). Decision open (P4): change the scripts to send `?acl=`.
- Evidence archives stay on ceph0 (sha256 in the record), the key never appeared in them (0 files).
- **Tool note:** the Claude session on ceph0 dropped one line when copying the 82 line view and said so itself, so the view was compared by per line fingerprints and hashes instead of by copying.

### SeaweedFS on the VMs: four further checks (8 October 2026)

Record: `results/seaweedfs-vm-extra-checks-2026-10-08.txt`.
- **S1 three copies, proven:** a 3 MiB object written through ceph0 sits in volume 32 (file id `32,4c3ad04a91`). The master lists three locations for volume 32 (all three VMs). The volume file `s1bucket7958_32.dat` exists on all three VMs with 3145784 bytes, and the 3145728 data bytes equal the original on all three. The whole files are NOT byte identical: ceph1 and ceph2 differ from ceph0 only inside the last 28 bytes (the first 3145756 bytes have the same hash on all three). The differing 8 bytes decode as nanosecond timestamps of the write (18:19:15Z, a few ms apart). Consistent with a per node append timestamp, not proven (format not read). So for SeaweedFS a byte identical copy is not the right test, the data bytes are.
- **S2 multipart, proven, no condition:** a 100 MiB object (13 parts) written through ceph0 with the default AWS CLI 2.36.8 settings and read through ceph2 is identical. Unlike Garage (F1), SeaweedFS accepts the default checksum behaviour. The load tool setting for the performance phase stays open (Garage needs `when_required`).
- **S3 restart persistence, proven:** containers recreated on all three nodes, both objects read back identical through ceph1, same three locations for volume 32, leader changed from ceph2 to ceph0. The stop was a kill: `podman rm -f` printed "StopSignal SIGTERM failed to stop container seaweedfs in 10 seconds, resorting to SIGKILL" on all three (cause not examined). Not tested: power loss, a node away longer, writes while a node is away.
- **S4 endpoints without credentials:** master (9333), volume server (8080) and filer (8888) answer GET requests from the LAN without any credentials, and the filer returns the stored object (3145728 bytes) while the S3 endpoint answers 403 for the same object. `security.toml` has `[access] ui = false` and a read JWT key, they did not prevent this. Not tested: writes through the filer port, a volume server read by file id. Belongs to the security phase (P3), same question for the other systems.

## RustFS on the three VMs: first attempt with 1.0.0-beta.8 crashed (8 October 2026)

SeaweedFS was stopped on ceph2, ceph1, ceph0 (podman rm -f, data kept, SIGTERM ignored for 10 s again, then killed). The RustFS scripts are in `deploy/rustfs/` (commit 514124b, sha256 of the four scripts checked on all three VMs with sha256sum -c). The shared key was made on ceph0 and copied by scp, the two files had the same sha256 on all three VMs (checked on the VMs). The image was the laptop image 1.0.0-beta.8 (`sha256:fa19210ac469...`), volume list `http://192.168.1.{70...72}:9000/srv/s3/disk{1...2}/rustfs`, started on the three VMs within a minute.

**Observed (PROVEN, from the VM output):**
- ceph2: container `Exited (132)`, 6 seconds after the start (started 23:23:56, ended 23:24:02 local). Kernel log: `traps: rustfs-worker[2235657] trap invalid opcode ip:7fb8d6660f67 sp:7fb8cade87e8 error:0 in rustfs[7fb8cca17000+acb0000]`, OOMKilled false, 3.0 GiB free.
- ceph0: same, trap at 23:24:56, `ip:7f021a516f67 ... in rustfs[7f02108cd000+acb0000]`, exit 132.
- ceph1: container still `Up` three minutes later, no trap logged. Its state was not examined further (two of three nodes were dead, so it could not serve).
- ip minus the module base is 0x9C49F67 on ceph2 and on ceph0 (computed by me from the two lines above), so both faulted at the same place of the binary.
- All three VMs: CPU model "QEMU Virtual CPU version 2.5+", 45 flag words, identical md5 of the flag line (09e078a45dc71cf9f73f1e5ccb26e074), no avx, avx2, bmi1, bmi2, pclmulqdq. Present: sse4_1, sse4_2, popcnt, aes.

**Instruction (PROVEN on the laptop, same image digest):** the binary was copied out of the image (sha256 2204d757ea08c2318bb1fb027d79a4b3d4f08f093915070b8ebd63dddeb5d4e5). The executable segment starts at virtual address 0x891000, so the faulting address is 0x9C49F67 + 0x891000 = 0xA4DAF67. `objdump -d` shows there `vbroadcasti128 ymm4, XMMWORD PTR [rdi]`, the first vector instruction of the symbol `reedsolomon_gal_mul` (address 0xA4DAF60), which comes with the crate `reed-solomon-erasure` 6.0.0 (strings in the binary list that crate and `reed-solomon-simd` 3.1.0). `vbroadcasti128` is an AVX2 instruction. The address is exactly on an instruction boundary.
CONSISTENT WITH, NOT PROVEN: the crash is this AVX2 instruction running on a CPU without AVX2 (the CPU flags and the trap type agree, but the exact trap was not traced by a debugger). Not examined: why the C code is not guarded by a CPU check.

**Research (web, 8 October 2026):**
- rustfs/rustfs issue #1838 "x86_64 Docker image crashes with SIGILL (exit 132) on CPUs without AVX" (closed 21 Feb 2026): reporter on a Synology with a Celeron J4125, image 1.0.0-alpha.83, cause named by the reporter: the build workflow used `-C target-cpu=native`.
- PR #1895 (merged 21 Feb 2026) replaced `native` with `-C target-cpu=x86-64-v2` for the x86_64 Linux builds. The beta.8 image (built 10 June 2026) still crashed, so this change did not remove the instruction found here (the Rust flags are one thing, the C code of reed-solomon-erasure is another, this link is a hypothesis).
- The crate documentation of reed-solomon-erasure says its `simd-accel` feature is tuned for Haswell and later and that a native architecture setting stops the build running on older CPUs. It does not mention a runtime check.
- Docker Hub: tag `1.0.1` (and `latest`) is `sha256:1803faef57627e2d9c2e7d89d655d712ddded5389040054987163043fecb6a3c`, pushed 3 October 2026, amd64 and arm64. The beta.8 image was therefore four months old.
- 1.0.1 binary (laptop, `rustfs 1.0.1`, build time 2026-10-03 02:33:36 UTC, stripped, sha256 a5ac41209ca8eca6c591c1584cc108b308850e1b74955afd4af9fe1b0379f2eb): the strings list only `reed-solomon-simd-3.1.0`, not `reed-solomon-erasure`. That crate documents a runtime choice of the instruction set with a plain Rust fallback. NOT PROVEN that 1.0.1 runs on the VM CPU: the strings are an indication, only a run on the VMs settles it.

**A failed test of mine:** a single node run with four directories on one disk (control beta.8 and 1.0.1) exited with code 1 for both. The log of 1.0.1 says `[FATAL] Server runtime failed: local erasure endpoints must use distinct physical disks; detected shared devices [8:32 => ...]`. So 1.0.1 checks that the drives of a node are on distinct devices. This did not test the AVX2 question (the control did not crash either), and the test folder was removed.

**Decision (Maaz, 8 October 2026):** redo RustFS before reporting anything, with the 1.0.1 image (pinned by digest in `rustfs-node.sh`, commit 760cdd0). The small `.rustfs.sys` folders (4 KB each) of the failed start were removed on all three VMs (looked at first, size under 16 KB). Consequence: the laptop RustFS runs (compat probe, presign, SigV4 test) used beta.8 and have to be repeated on 1.0.1 and labelled by version.
Still open: whether 1.0.1 starts and stays up on the 3 nodes (first test), whether RustFS accepts 3 nodes (the docs say 4 servers), whether the two drives of a node count as distinct physical disks (disk1 and disk2 are different devices on the VMs, the device numbers were not printed).
