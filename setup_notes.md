# S3 Testbed Setup Notes

## AWS CLI (S3 client used for manual testing)
- Version: aws-cli/2.36.8, confirmed via `aws --version`
- Install method: official Linux x86_64 installer — download `awscliv2.zip`, `unzip`, run `sudo ./aws/install`. Confirmed by the presence of those exact filenames during install; this is AWS's one documented method for Linux, no ambiguity.
- Installed to `/usr/local/aws-cli/v2/dist/aws`, self-contained, symlinked at `/usr/local/bin/aws`. Confirmed (via `readlink -f $(which aws)`) that it does not depend on the original download/extraction folder — so the leftover `awscliv2.zip` and `aws/` extraction folder were safe to delete from the repo afterward and have been removed.
- Credentials: dummy `test`/`test` access key/secret in the default profile (`~/.aws/credentials`), region `us-east-1`. These are not real AWS credentials — only there to satisfy the CLI's auth requirement when talking to local S3-compatible endpoints via `--endpoint-url`.

## Warp (primary benchmarking tool)
- Version: v1.5.0, confirmed via `warp --version`, installed at `/usr/local/bin/warp`
- Distribution note: Warp is no longer published as a GitHub release tar.gz. It's now a raw Linux binary hosted under MinIO's "aistor" branding at `dl.min.io/aistor/warp/release/linux-amd64/archive/warp`. Worth a mention in Methodology/Appendix C since older Warp install guides online describe the GitHub-release method, which no longer applies.
- **Status: installed and version-confirmed only — no benchmark has been run against any system yet.** First Warp run (against SeaweedFS) is the next planned step, not yet completed.

## SeaweedFS
- Ports: 9333 (master), 8080 (volume), 8888 (filer/dashboard), 8333 (S3 API)
- Dashboard: http://localhost:9333
- Current working command (see issues below for why it evolved from the original):

```
docker run -d --name seaweedfs \
  -p 9333:9333 -p 8080:8080 -p 8888:8888 -p 8333:8333 \
  -v ~/seaweedfs-data:/data \
  -v ~/seaweedfs-security.toml:/etc/seaweedfs/security.toml \
  -v ~/seaweedfs-s3-config.json:/etc/seaweedfs/s3_config.json \
  chrislusf/seaweedfs server -s3 -s3.config=/etc/seaweedfs/s3_config.json
```

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
