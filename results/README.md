# Raw Benchmark Data

Raw output from Warp/ossperf runs — throughput, latency, concurrency, and compatibility results
per system (maps to Appendix B — "Raw Benchmark Data" — in the thesis). Kept as plain CSV/JSON
where possible so results are diffable and reviewable in git.

## How to read this folder

1. **Records** (`*.txt`) are the written result files. Each one names the commit and sha256 of the
   script it used, the raw output, a PROVEN section, an OPEN section and the comparison with the
   predictions written before the run. A statement in a record is either proven by the raw output
   shown in it, labelled HYPOTHESIS with the test that would confirm it, or listed as OPEN.
2. **Tables** (`*.tsv`) are the machine made tables that a record cites. The sha256 of each table
   was compared with the copy on the VM.
3. **The compared series** is the VM series: the same three university VMs, the same protocol, one
   system after another. Files of the VM series have `vm` in the name.
4. **Earlier runs** (laptop in Docker, September Ceph runs on the single vCPU cluster, August
   pipeline validation) stay in the thesis, labelled as earlier runs. They are not mixed into the
   VM comparison.
5. Scripts that produced the files are described in `scripts/README.md`.

## VM series (the compared runs)

| Dimension | Ceph 20.2.4 | SeaweedFS | RustFS 1.0.1 | Garage v1.0.0 |
|---|---|---|---|---|
| Performance | `ceph-vm-performance-2026-10-15.txt` | `seaweedfs-vm-performance-2026-10-12.txt` | `rustfs-vm-performance-2026-10-10.txt` | `garage-vm-performance-2026-10-13.txt` |
| Resource use (sar) | `ceph-vm-performance-sar-2026-10-15.txt` | `seaweedfs-vm-performance-sar-2026-10-12.txt` | `rustfs-vm-performance-sar-2026-10-10.txt` | `garage-vm-performance-sar-2026-10-13.txt` |
| Security | `ceph-vm-security-2026-10-15.txt` | `seaweedfs-vm-security-2026-10-13.txt` | `rustfs-vm-security-2026-10-11.txt` | `garage-vm-security-2026-10-14.txt` |
| Fault tolerance S1 | `ceph-vm-fault-tolerance-S1-2026-10-15.txt` | `seaweedfs-vm-fault-tolerance-S1-2026-10-13.txt`, repeat `seaweedfs-vm-fault-tolerance-S1-repeat-2026-10-13.txt` | `rustfs-vm-fault-tolerance-S1-2026-10-11.txt`, repeat `rustfs-vm-fault-tolerance-S1-repeat-2026-10-12.txt` | `garage-vm-fault-tolerance-S1-2026-10-14.txt` |
| Fault tolerance S2 | `ceph-vm-fault-tolerance-S2-2026-10-15.txt` | `seaweedfs-vm-fault-tolerance-S2-2026-10-13.txt` | `rustfs-vm-fault-tolerance-S2-2026-10-11.txt` | `garage-vm-fault-tolerance-S2-2026-10-14.txt` |
| Predictions written before the runs | `ceph-vm-predictions-2026-10-15.txt` | none in this folder | none in this folder | `garage-vm-predictions-2026-10-13.txt` |
| Compatibility probe and presigned PUT on the VMs | see "Compatibility" below | `seaweedfs-vm-compat-and-presign-2026-10-08.txt` | `rustfs-vm-compat-and-presign-2026-10-09.txt` | `garage-vm-compat-and-presign-2026-10-08.txt` |
| Further checks on the VMs | none | `seaweedfs-vm-extra-checks-2026-10-08.txt` | `rustfs-vm-extra-checks-2026-10-09.txt` | `garage-vm-extra-checks-2026-10-08.txt` |
| Round trip integrity on the VMs | none | `seaweedfs-roundtrip-vm-3node-20261008-192740.txt` | `rustfs-roundtrip-vm-3node-20261009-111145.txt` | `garage-roundtrip-vm-3node-20261008-134838.txt` |

Performance tables (one file per kind; Ceph and Garage also have the sar tables per node):

1. Ceph: `perf-ceph-vm-3node-20261015-table-runs.tsv`, `-table-configs.tsv`, `-sar-runs-ceph0.tsv`, `-sar-runs-ceph1.tsv`, `-sar-runs-ceph2.tsv`
2. Garage: `perf-garage-vm-3node-20261013-table-runs.tsv`, `-table-configs.tsv`, `-sar-runs-ceph0.tsv`, `-sar-runs-ceph1.tsv`, `-sar-runs-ceph2.tsv`
3. RustFS: `perf-rustfs-vm-3node-20261010-table-runs.tsv`, `-table-configs.tsv`, `-sar-configs.tsv`
4. SeaweedFS: `perf-seaweedfs-vm-3node-20261012-table-runs.tsv`, `-table-configs.tsv`, `-sar-configs.tsv`

Other VM series files: `ft-seaweedfs-vm-S1-20261013-093344-filecounts.txt`,
`ft-seaweedfs-vm-S1b-20261013-133927-filecounts.txt`, `ft-seaweedfs-vm-S2-20261013-113256-filecounts.txt`
(file counts per node during the SeaweedFS outages).

The run folders and `.tar.gz` archives of the VM series stay on the VMs (and are listed with their
sha256 in the records). Only records and tables are in the repository.

## Compatibility (S3 API)

1. `compat-matrix-four-systems-2026-10-02.tsv`: matrix of the 22 probe tests (C01 to C22) for the four systems. SeaweedFS, RustFS and Garage ran as single node Docker containers on the laptop (30 September), Ceph was probed on 30 September and 2 October (see its record for the cluster).
2. `s3-compat-three-systems-2026-09-30.txt`, `s3-compat-ceph-2026-10-02.txt`: written records with cross verification. `compat-matrix-2026-09-30.tsv`: first matrix, three systems.
3. Probe evidence folders (command, stdout and stderr of every request): `compat-seaweedfs-*`, `compat-rustfs-*`, `compat-garage-*`, `compat-rustfs101-laptop-*` (RustFS 1.0.1 on the laptop, 9 October), `compat-ceph-20261002-072634-evidence.txt`. `compat-rustfs101-laptop-ssekey-*` and `compat-rustfs101-laptop-ssekey-C18-20261009.tsv` hold the SSE-S3 follow up for RustFS 1.0.1.
4. Second client cross checks (`verify-*.txt`, made with `scripts/verify-*.sh`): bucket delete, ACL enforcement, key limits, raw HTTP, checksum header (`verify-checksum-header-*`, Ceph also with the unsigned Content-Type), SSE and ACL.
5. `aws-cli-crash-on-ceph-error-replies-2026-10-02.txt`: AWS CLI 2.36.8 crash on empty Ceph error messages.
6. `ceph-sse-s3-vault-check-2026-10-02.txt`: SSE-S3 on Ceph needs a key service.
7. Presigned PUT with headers outside the signature: `security-presign-unsigned-header-*` (three systems on the laptop, 2 October; Ceph, 5 October; RustFS 1.0.1 laptop, 9 October).

No VM run of the 22 test probe on Ceph is in this folder; the Ceph compatibility cells come from the 30 September and 2 October probe.

## Earlier runs (labelled in the thesis, not part of the VM comparison)

1. Ceph, September 2026, single vCPU era cluster and early four vCPU runs: `ceph-faulttolerance-rerun-2026-09-22.txt`, `ceph-osd-and-pg-scaling-2026-09-25.txt`, `ceph-smallobject-writeamplification-2026-09-24.txt`, `warp-ceph-concurrency-sweep-2026-09-23.txt`, `warp-ceph-4core-sweep-2026-09-23.txt`, `warp-ceph-coresidency-2026-09-23.txt`, `warp-ceph-objectsize-2026-09-23.txt`, `sar-ceph-batch1-2026-09-17.txt`, `ossperf-ceph-batch1-2026-09-17.csv`.
2. SeaweedFS ossperf runs, August 2026: `ossperf-seaweedfs-*.csv` (the name of `ossperf-seaweedfs-mode-unconfirmed-2026-08-16.csv` says its run mode is unconfirmed; check before citing).
3. Pipeline validation, August 2026: `2026-08-03_warp_pipeline_validation_seaweedfs.txt` and `2026-08-09_warp_pipeline_validation_all_three.txt`. Marked NOT MEASUREMENT DATA, DO NOT CITE.
4. `warp-raw/`: raw Warp output files (`.json.zst`) of the validation and September runs.
5. SeaweedFS investigation files from 30 September and 1 October: `seaweedfs-serverlog-c18-c19-window-20260930.txt`, `seaweedfs-scratch-verbose-sse-acl-serverlog-20260930.txt`, `seaweedfs-sse-at-rest-check-scratch-20261001-002744.txt`.

## Raw run archives of the VM series (in this folder)

The archives made by the scripts on the VMs (`ft.sh`, `sec.sh`, `security-presign-unsigned-header.sh`) are kept here as `.tar.gz`, 26 files, 3.5 MB in all, unchanged. They were copied from ceph0 on 15 October 2026. Their sha256 is in `vm-archives-ceph0-SHA256SUMS.txt` and in the records. `analysis/` reads them directly.

1. `ft-<system>-<scenario>-<date>-<time>.tar.gz` (13 files): one fault tolerance run. Inside: `ledger.tsv` (every write attempt), `probe.tsv` (probe of the fixed object), `repairwatch.tsv`, `verify*.tsv` (read back), `summary.txt`, `console.txt`.
2. `sec-<system>-<date>-<time>.tar.gz` (10 files): one security run (`sec.sh`, and `sec-ceph-replies` for Ceph).
3. `presign-<system>-vm-<date>-<time>.tar.gz` (3 files): the presigned PUT test with unsigned headers on the VMs.

Not in the repository (kept on the VMs and on the author's laptop): the performance series archives with the Warp raw data (1.7 to 2.6 MB each), the sar logs of the three nodes (8 to 20 MB each) and five `compat-*` archives, which are held back because a key value was found in them. The performance tables that the records cite are in this folder.
