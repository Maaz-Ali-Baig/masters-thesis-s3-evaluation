# After MinIO: An Empirical Evaluation of Open Source S3-Compatible Storage Systems

Master's thesis, Frankfurt University of Applied Sciences (High Integrity Systems, M.Sc.).

Author: Maaz Ali Baig, Supervisors: Prof. Dr. Christian Baun, Prof. Dr. Thomas Gabel

## About

The MinIO repository was archived by its owner in April 2026, and the community edition is now
distributed as source only, without binaries. This repository holds the deployment scripts, test
scripts, result records, analysis scripts and setup notes of a comparative evaluation of four open
source S3-compatible storage systems for self-hosted private clouds.

The systems were tested on the same three virtual machines under one protocol. Four dimensions were
evaluated: performance, S3 API compatibility, security and fault tolerance. A weighted scoring
matrix combines the results.

## Systems under evaluation

| System | Version | Language | S3 endpoint | Deployment |
|---|---|---|---|---|
| Ceph | 20.2.4 | C++ | RGW, port 80 | cephadm, containers |
| SeaweedFS | 4.25 | Go | port 8333 | Podman container |
| RustFS | 1.0.1 | Rust | port 9000 | Podman container |
| Garage | v1.0.0 | Rust | port 3900 | Podman container |

Test environment: three university virtual machines (ceph0, ceph1, ceph2) on Proxmox, Debian, with
two data disks each. One system ran at a time. The configuration of every system is in `configs/` and
`deploy/`, and the exact settings are listed in Appendix A of the thesis.

## Repository structure

```
configs/        Configuration files per system (keys and secrets replaced by placeholders)
deploy/         Deployment and test scripts per system, as run on the virtual machines
scripts/        Benchmark, compatibility, security and fault tolerance scripts
results/        Result records (.txt), machine made tables (.tsv) and run archives (.tar.gz)
analysis/       Scripts that build every table and figure of the thesis from results/
ossperf/        Reference copy of ossperf (upstream, unmodified)
setup_notes.md  Setup steps, problems encountered and how they were solved
*_method.md     Written method of each dimension (performance, security, fault tolerance, scoring)
```

Each folder has its own `README.md` where needed.

## Results and how they are checked

1. Every result record names the commit and the sha256 of the script it used, the raw output, the
   proven findings, the open points and the comparison with the predictions written before the run.
2. Every table and figure of the thesis is made by a script in `analysis/` from the files in
   `results/`. The scripts check the input files against the recorded sha256 values and stop if a
   file differs. Each output has a `MANIFEST.txt` with the commit and the library versions.
3. Scale of the data: 17 performance configurations (204 runs with Warp 1.8.0), 22 compatibility
   tests, 13 security checks and 13 fault tolerance runs, each for the systems that were tested.

To rebuild the tables (Python 3 with the standard library, matplotlib for figures):

```bash
python3 analysis/build_perf.py
```

See `analysis/README.md` for the other scripts.

## Method note

The commands on the virtual machines were run in terminal sessions with an AI coding assistant. Only
the raw command output was used as evidence, and scripts were checked by sha256 after transfer. The
result records state the details for each series.

## Usage of the helper scripts

Each system needs different credentials, and Garage needs a different region. The helper script
handles this per command:

```bash
source scripts/s3-helpers.sh

s3sw s3 ls      # SeaweedFS
s3rf s3 ls      # RustFS
s3ga s3 ls      # Garage
s3check         # check that all endpoints are reachable
```

Credentials are read from `~/.thesis-s3-env`, outside this repository. See `scripts/README.md`.

## Limitations

The study used one cluster, one version of each system and one to three fault tolerance runs per
scenario. The load generator ran on a storage node, so some performance results are flagged. Only
the hard stop of a virtual machine was tested as a failure. These limits and the open points are
stated in the thesis and in the result records.
