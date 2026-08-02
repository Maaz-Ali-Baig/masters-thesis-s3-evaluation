# S3 Testbed Setup Notes

## AWS CLI (S3 client used for manual testing)
- Version: aws-cli/2.36.8, confirmed via `aws --version`
- Install method: official Linux x86_64 installer — download `awscliv2.zip`, `unzip`, run `sudo ./aws/install`. Confirmed by the presence of those exact filenames during install; this is AWS's one documented method for Linux, no ambiguity.
- Installed to `/usr/local/aws-cli/v2/dist/aws`, self-contained, symlinked at `/usr/local/bin/aws`. Confirmed (via `readlink -f $(which aws)`) that it does not depend on the original download/extraction folder — so the leftover `awscliv2.zip` and `aws/` extraction folder were safe to delete from the repo afterward and have been removed.
- Credentials: dummy `test`/`test` access key/secret in the default profile (`~/.aws/credentials`), region `us-east-1`. These are not real AWS credentials — only there to satisfy the CLI's auth requirement when talking to local S3-compatible endpoints via `--endpoint-url`.

## Warp (primary benchmarking tool)
- Version: v1.5.0, confirmed via `warp --version`, installed at `/usr/local/bin/warp`
- Distribution note: Warp is no longer published as a GitHub release tar.gz. It's now a raw Linux binary hosted under MinIO's "aistor" branding at `dl.min.io/aistor/warp/release/linux-amd64/archive/warp`. Worth a mention in Methodology/Appendix C since older Warp install guides online describe the GitHub-release method, which no longer applies.
- **Status: pipeline validated against SeaweedFS on 3 August 2026 (see below). No measurement-grade data collected yet.**

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


## Garage
- Ports: 3900 (S3 API), 3901 (RPC), 3902 (admin)
- Requires config file at ~/garage.toml and data dirs at ~/garage-data
- RPC secret must be exactly 64 hex characters generated via: openssl rand -hex 32
- Command: docker run -d --name garage -p 3900:3900 -p 3901:3901 -p 3902:3902 -v ~/garage-data:/var/lib/garage -v ~/garage.toml:/etc/garage.toml dxflrs/garage:v1.0.0
- Dashboard: No web UI — managed via CLI or admin API at http://localhost:3902

**Known risk — not yet fixed:** the command above mounts `~/garage.toml` as a *single file*, the same
pattern that caused the SeaweedFS restart failure in Issue 4. Garage is expected to fail to restart in the
same way after some future Docker Desktop restart. The equivalent fix would be to move `garage.toml` into
a directory (e.g. `~/garage-config/garage.toml`), mount that directory, and point Garage at the config
inside it. To be applied before benchmarking begins, so the environment is stable across sessions.
