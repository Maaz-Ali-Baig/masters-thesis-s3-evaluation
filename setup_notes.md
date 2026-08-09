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

Root cause: under Docker Desktop on Windows, the WSL2 distribution and the container runtime live in two
separate VMs, so bind mounts must be bridged between them. Directory bind mounts are bridged as a live
path mapping and remain valid indefinitely. **Single-file bind mounts are instead staged into an
ephemeral location inside the Docker Desktop VM** (`/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/`)
under a content hash. That staging area is discarded when Docker Desktop restarts, while the container
retains its now-dangling reference to the hashed path — so `runc` fails during container init and the
container cannot start. The source files in WSL are never touched or lost; only the mapping breaks.

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
authorisation must be granted explicitly per key per bucket (`bucket allow`). SeaweedFS and RustFS both
treat valid credentials as access to everything. Garage is deny-by-default, which is the stronger
security posture and should be credited as such in the Security chapter.

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
