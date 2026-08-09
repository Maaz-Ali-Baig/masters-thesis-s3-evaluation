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
