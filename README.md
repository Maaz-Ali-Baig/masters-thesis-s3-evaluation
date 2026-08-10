# After MinIO: An Empirical Evaluation of Open Source S3-Compatible Storage Systems

Master's thesis, Frankfurt University of Applied Sciences (High Integrity Systems, M.Sc.).

MinIO was archived and moved to a closed source model in early 2026. This repository holds the test
environments, scripts, results and setup documentation for a comparative evaluation of four open
source alternatives across performance, S3 API compatibility, security, and replication.

Author: Maaz Ali Baig
Supervisors: Prof. Dr. Christian Baun, Prof. Dr. Thomas Gabel
Submission: 3 November 2026

## Systems under evaluation

| System | Language | S3 port | Deployment |
|---|---|---|---|
| Ceph | C++ | via RGW | Proxmox VMs (Debian) |
| SeaweedFS | Go | 8333 | Docker |
| RustFS | Rust | 9000 | Docker |
| Garage | Rust | 3900 | Docker |

## Repository structure

```
configs/        Config files per system (secrets replaced with placeholders)
scripts/        Test and verification scripts
results/        Raw benchmark output
setup_notes.md  Setup steps, problems encountered, and how they were fixed
ossperf/        Reference copy of ossperf (upstream, unmodified)
```

`configs/`, `results/` and `scripts/` correspond to Appendices A, B and C of the thesis.

## Usage

Each system needs different credentials, and Garage needs a different region. The helper script
handles this per command:

```bash
source scripts/s3-helpers.sh

s3sw s3 ls      # SeaweedFS
s3rf s3 ls      # RustFS
s3ga s3 ls      # Garage
s3check         # check all three endpoints are reachable
```

Verify data integrity on all three systems:

```bash
./scripts/verify-roundtrip.sh
```

Uploads a file of random bytes, downloads it again, and compares the MD5 checksum.

Credentials are read from `~/.thesis-s3-env`, outside this repository. See `scripts/README.md`.

## Status

| | Deployed | S3 verified | Benchmarked |
|---|---|---|---|
| SeaweedFS | yes | yes | pipeline validation only |
| RustFS | yes | yes | pipeline validation only |
| Garage | yes | yes | pipeline validation only |
| Ceph | not yet | no | no |

No measurement-grade data has been collected yet. The runs in `results/` exist only to confirm the
tooling works end to end and are marked as not citable.

Setup was not uniform: SeaweedFS needed three fixes before its S3 interface worked, Garage does not
serve anything until a cluster layout is assigned and access is granted per key and per bucket, and
RustFS worked on the first attempt with no configuration. All of it is documented in
[`setup_notes.md`](setup_notes.md).
