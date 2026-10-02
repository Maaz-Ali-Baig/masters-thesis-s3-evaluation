# Test Scripts

Scripts used to run benchmarks and compatibility/security/replication tests against each system
(maps to Appendix C — "Test Scripts" — in the thesis).

## s3-helpers.sh

Per-system AWS CLI wrappers, so each system is addressed with the correct endpoint, credentials
and region without any of them leaking into the shell environment.

```bash
source scripts/s3-helpers.sh

s3sw s3 ls                             # SeaweedFS  :8333
s3rf s3 ls                             # RustFS     :9000
s3ga s3 ls s3://thesis-test-bucket/    # Garage     :3900

s3check                                # reachability of all three endpoints
s3info                                 # show endpoints/regions/keys (no secrets)
```

**Why wrappers instead of `export`.** The three systems need different credentials *and* different
regions. Exporting `AWS_ACCESS_KEY_ID` in a long-lived terminal leaves the previous system's
credentials in place for the next command, and the resulting failure looks like a broken storage
system rather than a stale variable. These functions scope credentials to a single invocation, so
nothing persists and there is nothing to unset.

**Region matters, not just credentials.** Garage enforces the region configured as `s3_region` in
`garage.toml` as part of the SigV4 signature scope. Addressing it with the AWS default
`us-east-1` fails with `AuthorizationHeaderMalformed`. SeaweedFS and RustFS accept `us-east-1`.
See `setup_notes.md` for the full write-up.

**Interpreting `s3check`.** `HTTP 403` is a healthy result — the server is running and speaking S3,
and is refusing an unauthenticated request. No response means the container may be up while its API
is unreachable, which is the failure signature of Issues 1 and 4 in `setup_notes.md`.

### Credentials

Secrets are **not** stored in this repository. `s3-helpers.sh` reads them from `~/.thesis-s3-env`
(mode 600, outside the repo). Override the location with `THESIS_S3_ENV=/path/to/file`.

The file defines, per system, a key/secret/region/endpoint quadruple:

```sh
SW_KEY=...   SW_SECRET=...   SW_REGION=us-east-1   SW_ENDPOINT=http://localhost:8333
RF_KEY=...   RF_SECRET=...   RF_REGION=us-east-1   RF_ENDPOINT=http://localhost:9000
GA_KEY=...   GA_SECRET=...   GA_REGION=garage      GA_ENDPOINT=http://localhost:3900
```

The Garage secret can be re-read at any time from the running container:

```bash
docker exec garage /garage key info thesis-key --show-secret
```

SeaweedFS and RustFS credentials are not secret in any meaningful sense — `test`/`test` and the
inherited MinIO default `minioadmin`/`minioadmin` respectively — but are kept in the same file so
there is one place to look.

## s3-compat.sh and s3-compat-run.sh

S3 API compatibility probe (Chapter 6, Appendix C). One file, run unchanged against every
system, so each compatibility matrix cell comes from identical requests. It runs 22 tests
(C01 to C22): bucket and object basics, range reads, copy, listing and pagination, deletes,
multipart upload, tagging, versioning, conditional requests, presigned URLs, bucket policy,
CORS, lifecycle, object lock, SSE-S3, ACLs, integrity checksums, awkward key names, and
error code fidelity.

**Local systems (SeaweedFS, RustFS, Garage).** Run from WSL, from the repository root:

```bash
./scripts/s3-compat-run.sh sw
./scripts/s3-compat-run.sh rf
./scripts/s3-compat-run.sh ga
```

The runner reads `~/.thesis-s3-env` and passes credentials to the probe inline for that one
run. Nothing is exported, so there is nothing to unset. Output lands in
`results/compat-<system>-<timestamp>/`.

**Ceph (on ceph0).** The probe is fetched from the public repository, then run with the
credentials given inline:

```bash
curl -fsSL -o /root/s3-compat.sh https://raw.githubusercontent.com/Maaz-Ali-Baig/masters-thesis-s3-evaluation/main/scripts/s3-compat.sh
S3C_NAME=ceph S3C_ENDPOINT=http://localhost:80 S3C_KEY=<key> S3C_SECRET=<secret> \
  S3C_NOTE="Ceph 20.2.4 Tentacle, RGW" bash /root/s3-compat.sh
```

Use the same AWS CLI version as the laptop runs (2.36.8). The Debian 12 package is 2.9.19, which
predates default checksums and conditional upload flags, so its results are not comparable. The
official installer for a pinned version goes into its own folder and leaves the system CLI alone:

```bash
curl -fsSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.36.8.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp/awscli-new
mkdir -p /opt/aws-cli-new/bin && /tmp/awscli-new/aws/install -i /opt/aws-cli-new/files -b /opt/aws-cli-new/bin
PATH=/opt/aws-cli-new/bin:$PATH   # put in front of the probe run
```

**Options and variables.** `--only C01,C08` runs selected tests, `--keep` skips bucket cleanup,
`--list` prints the test ids. `S3C_REGION` defaults to `us-east-1` (Garage needs `garage`).
`S3C_CHECKSUM=when_required` stops the AWS CLI adding default integrity checksums, which
separates "the server rejects the default client" from "the server lacks the feature".
`S3C_KEEP_BIN=1` keeps the test payloads that are normally deleted after the run.

**Verdicts.** PASS means every sub-check behaved as AWS S3 documents. UNSUPPORTED means a
sub-check failed and the server answered NotImplemented. FAIL is anything else. SKIP means a
prerequisite failed or the installed AWS CLI lacks the flag. PASS and FAIL are decided
mechanically against documented AWS behaviour; whether a FAIL is a defect or a legitimate
design difference is a judgement made afterwards from the saved evidence.

**Evidence.** Every request is saved under `evidence/<test>/` as `.cmd`, `.out` and `.err`
(command, stdout, stderr), so any matrix cell traces back to the raw server reply.
`summary.tsv` has one row per test. `env.txt` records the AWS CLI version, the server's
response headers, and checksums of the payloads used. Credentials are never written out.

**AWS CLI crash on Ceph error replies.** Ceph RGW sends error replies with an empty
`<Message>`. AWS CLI 2.36.8 then crashes with `argument of type 'NoneType' is not a container or
iterable` (in `awscli/customizations/s3errormsg.py`) before it prints the error code, so every
check that expects a specific error looked like a failure with no code. The probe now repeats
such a failed request once with `--debug` and keeps only the status line and reply body in
`<test>-NN.reply` (never the request headers, which hold the signature). The code read from
that reply is appended to the `.err` file. It only acts when the crash text is present: the
SeaweedFS, RustFS and Garage runs give identical verdicts with and without it.

**What the probe does not prove.** SSE-S3 (C18) tests that the API accepts and echoes the
header, not that data is encrypted on disk. Lifecycle (C16) tests that the configuration is
stored and returned, not that objects actually expire. Presigned PUT and unsigned-header
handling belong to the security phase and need a client that can presign uploads.

## verify-*.sh, second client cross checks

The probe drives everything through the AWS CLI, which hides the raw HTTP status and can mislead (it already
did once, over `KeyCount`). These scripts repeat the surprising results with `curl` signing its own requests, so
a different client confirms or contradicts them. Each takes `sw`, `rf` or `ga` and saves its output under
`results/`. They use the same `~/.thesis-s3-env` credentials inline and create and remove their own buckets
(named `s3c-verify-*`), emptying them first.

```bash
./scripts/verify-bucket-delete.sh sw      # delete a bucket that still holds an object, then look at what is left
./scripts/verify-acl-enforcement.sh sw    # object ACL, bucket ACL and bucket policy against anonymous requests
./scripts/verify-key-limits.sh sw         # trailing slash key, path component length, exact total key length
./scripts/verify-sse-acl.sh sw            # SSE-S3 header and canned ACL on flat and prefixed keys
./scripts/verify-raw-http.sh sw           # conditional requests, multipart, SSE and lock headers, CORS, lifecycle
```

Run the same script on all three systems and compare, because the other two act as controls that show the test
can detect the behaviour AWS documents. Only statuses, headers and short body excerpts are printed. The reading
of them is done separately, never inside the script.

Two traps found while writing them. `curl -T file URL/` appends the file name when the URL ends in a slash, so
uploads to a key ending in `/` must use `--data-binary`. The AWS CLI drops `KeyCount` from listings it paginates
automatically, so count the listed keys or use `--no-paginate`.
