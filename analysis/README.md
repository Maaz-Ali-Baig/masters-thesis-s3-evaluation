# Analysis: tables and figures for the thesis

Every table and figure in the results chapters is made by a script in this folder from files in
`results/`. Nothing is typed by hand into a table or a figure. The scripts run on the laptop (WSL),
not on the VMs, and use only the Python standard library plus matplotlib for figures.

## Run

```bash
cd "/mnt/c/Users/MAAZ ALI BAIG/OneDrive/Desktop/Masters Thesis/masters-thesis-s3-evaluation"
python3 analysis/build_perf.py
```

Setup once (WSL, Debian or Ubuntu): `sudo apt install -y python3-matplotlib`. Without matplotlib the
tables are still written and the figures are skipped with a message. The versions used are written
into the manifest of every run.

## What a script does

1. Checks every input file against the sha256 written in the result records. If a file differs, the
   script stops.
2. Recomputes the values (for the performance series: median, minimum and maximum of the three
   recorded runs) from the per run tables and compares them with the tables made on the VMs. If they
   differ, the script stops.
3. Applies the rule of the method that is computed from data (for performance: a configuration is
   client limited if the mean CPU of the load node ceph2 is above 80 percent, `performance_method.md`
   section 3).
4. Writes tables (CSV for checking, LaTeX `tabular` for the thesis) and figures (PDF for the thesis,
   PNG for a quick look) to `analysis/out/<topic>/`.
5. Writes `MANIFEST.txt`: commit, state of the working tree, library versions, sha256 of all input
   and output files.

For a clean manifest: commit the scripts first, run them, then commit `analysis/out/`.

## Scripts

| Script | Output folder | Content |
|---|---|---|
| `common.py` | none | helpers: hashes, file reading, manifest |
| `build_perf.py` | `out/perf/` | performance comparison of the four systems on the VMs |
| `build_ft.py` | `out/ft/` | fault tolerance runs S1 and S2 of the four systems, read from `results/ft-*.tar.gz` |
| `build_repair.py` | `out/repair/` | what the repair watch recorded after the stopped node(s) came back: file count lag (Garage, RustFS, SeaweedFS) and Ceph health |
| `build_security.py` | `out/security/` | security comparison table (13 rows by 4 systems, tables only), cells in `analysis/cells/security_cells.py` checked against the raw archives |
| `build_compat.py` | `out/compat/` | S3 compatibility table (22 probe tests by 4 systems), verdicts recomputed from the sub-checks of five `summary.tsv`, readings in `analysis/cells/compat_cells.py` |

Outputs of `build_perf.py`:

1. `perf_long.csv`: one row per system and configuration (median, minimum, maximum, runs, load node CPU, client limited).
2. `perf_ranking.csv`: order of the systems per configuration, gap between first and second, whether the ranges of the three runs are separate, which systems are client limited.
3. `perf_size.tex`, `perf_concurrency.tex`: the two comparison tables (`\input` in Overleaf; needs `booktabs`). Bold = highest median in the row, dagger = client limited.
4. `perf_load_node_cpu.csv`: mean CPU of ceph2 per system and configuration.
5. `perf_size`, `perf_concurrency`, `perf_mixed` as `.pdf` and `.png`. Hollow marker or hatched bar = client limited. Whiskers are minimum to maximum of the three runs and are often smaller than the marker. In `perf_concurrency` the PUT and GET panels have their own y axes.

## Rules for the text that uses these files

1. A number in the thesis comes from a generated file or from a record, never from memory.
2. The captions must say: median of three runs of 60 s, VM series, Warp 1.8.0 on ceph2, which is also a storage node.
3. The captions must say that redundancy differs: Ceph, SeaweedFS and Garage keep three copies, RustFS uses erasure coding 3+3.
4. A client limited cell (dagger) is not used for a ranking, as the method says. Whether a statement can still be made about such a cell is decided in the text, with the reason.
5. In most GET runs the drives delivered less than the client received (resource records), so part of the data came from memory; the cause for Ceph is OPEN. The exception is RustFS at 16 and 100 MiB, where the drives read about 1.8 times the client volume. The text must say so.
6. The write volume ratios of the resource records use different sar windows per system (Garage record, limit L6). They are not put side by side in one table.

## Fault tolerance (`build_ft.py`): definitions and limits

Input: the 13 run archives `results/ft-*.tar.gz` (hashes in `results/vm-archives-ceph0-SHA256SUMS.txt`). Output in `analysis/out/ft/`: `ft_runs.csv` (all metrics per run), `ft_s1.tex`, `ft_s2.tex`, `ft_timeline_<system>.pdf` (every run on a time axis), `ft_gaps.pdf`. The script stops if the recomputed numbers differ from the `summary.txt` of a run.

1. **Time zero** is the moment `ft.sh` saw every stopped node silent. In S2 the first node went down up to about 15 s earlier, so a gap can start slightly before zero.
2. **Acknowledgement type.** Ceph runs: `aws s3api put-object` with an ETag. Garage, RustFS, SeaweedFS runs: exit code 0 of `aws s3 cp`. A `cp` acknowledgement after a stall of about 25 s can be false (Garage record, 14 October). The two types are not compared by their counts.
3. **Confirmed write** = an acknowledged write whose object is readable on all three endpoints after the recovery. The main write measure ("write gap") is the longest interval between two confirmed writes. It does not depend on the acknowledgement type, because false acknowledgements are not readable afterwards. "Acked, not readable" is the count of acknowledgements that are not confirmed; for `cp` runs this is an upper bound of lost writes, not a finding.
4. **Round.** One pass of the probe loop. A hard failed round has no acknowledged attempt. A failed attempt that the next endpoint rescued is a masked failure.
5. **Read gap** = longest time between two successful reads of the fixed object (`head-object`) at one surviving endpoint. A gap of about 25 s means a request hung until the client read time out.
6. **Outage** = the longest gap of successful reads at a stopped endpoint, measured by the probe (VM down time plus boot and start). The `ssh answers` lines of `console.txt` are not used, because the read back during the outage can delay them (Ceph S2, deviation D2).
7. **Censored values** are written with a greater or equal sign. Garage S1 run 1 and Garage S2 end before the stopped node answered again inside the probe, so their outage and write gap are lower bounds.
8. **Run notes** (parallel writers, deviations) are typed in `RUN_NOTES` with the record they come from. They cannot be derived from the archive.
9. A cross system statement about "lost acknowledged writes" is not allowed from these data (see 2 and 3). Statements about gaps, hard failed rounds, outage and read gaps are.

## Recovery evidence (`build_repair.py`): definitions and limits

Input: `repairwatch.tsv` in the 13 run archives (11 have one; the two RustFS runs of 11 October have none). Output in `analysis/out/repair/`: `repair_files.csv/.tex`, `repair_ceph.csv/.tex`, `repair_files.pdf`, `repair_ceph.pdf`.

1. **File count lag** (Garage, RustFS, SeaweedFS): files on the returned node minus the mean of the nodes that stayed up, in the same 20 s sample, relative to the mean before the stop. The unit differs by system (Garage: all files of the data directories, RustFS: files of the run's key prefix, SeaweedFS: files of the bucket volumes), so only the shape (does the lag go back to zero?) is compared, not the number of files.
2. **Closed** = from the first sample after the return, every later sample has a lag of at most 3 files (RustFS shows noise of up to 2 files, because the probe keeps writing). "Not closed" means the lag was still there at the end of the 30 minute watch.
3. A closed lag is not a proof of repair or of integrity, and a lag that stays is not a proof of data loss: the objects of all runs were readable on all endpoints (`ft_runs.csv`).
4. The repair watch of Garage run 1 and Garage S2 ends before the node answered again; they are not used. The last sample of every watch is written twice with the same time stamp (handled).
5. **Ceph**: the status is not readable without monitor quorum, so no OSD count exists for S2 (n/a). The status rows before the first row with quorum are stale values of the monitors, not a measured state. HEALTH_OK can come later than all PGs clean (S1 run B: a cephadm host check warning, see the record).

## Security table (`build_security.py`): how the cells are made and checked

Tables only, no figures. The 52 cells (13 rows by 4 systems) are written by hand in `analysis/cells/security_cells.py` from the four security records (`results/<system>-vm-security-*.txt`). Each cell carries its outcome word, a short text, the record and point it comes from (for example `SW-P4`), and the regular expressions that must be found in the raw output of the run archives (`results/sec-*.tar.gz`, `results/presign-*.tar.gz`). `build_security.py` stops if one pattern is not found. This protects the table against typing errors: it already stopped once, because the Garage archive cuts a line before the SSE-C field that the record had quoted.

Outcome words: PASS and FAIL follow the pass conditions of `security_method.md` (a FAIL is a finding about the default deployment, not a judgement of the product); `refused` = the server refused the request that was meant to enable the feature; `not in clear` = SSE accepted and the marker was not found on the drives (the strength of the encryption is not shown); `info` = a fact without a pass condition; `n.t.` = not tested (the check was not run, or the script found nothing to test).

Limits to state with the table: default deployments, plain http, no TLS (transport was tested at level 1 only); one run per check; the paths and ports tested are fixed lists; SEC4 (scoped key) was run for all four systems, for SeaweedFS it protects the S3 port only; SEC7 (admin interfaces) is limited to the anonymous answers of SEC1; whether a marker that is not found means encryption is not shown. The presigned PUT test of Ceph is the run of 5 October on the same VMs (plain file in `results/`).

## S3 compatibility table (`build_compat.py`): how the table is made and checked

Tables only, no figures. Input: the `summary.tsv` of five probe runs (Ceph from the archive of the repeat of 16 October `compat-ceph-vm-20261016-095804.tar.gz` (its summary must equal the one of the run of 2 October in the text copy `compat-ceph-20261002-072634-evidence.txt`), SeaweedFS, Garage and RustFS from the `compat-*.tar.gz` in `results/`; RustFS twice, with and without the SSE-S3 master key). The script stops if

1. a `summary.tsv` does not have the sha256 written in the records (for SeaweedFS, RustFS and Garage the records state that the summary of the VM run has the same sha256, so the VM result equals the file here; the VM archives stay on ceph0),
2. a verdict does not follow from its sub-checks (rule of the records: a sub-check that answered NotImplemented = UNSUPPORTED, else a failed sub-check = FAIL, else PASS),
3. a column differs from the old matrix `compat-matrix-four-systems-2026-10-02.tsv` (Ceph, SeaweedFS, Garage must be equal; RustFS must differ exactly in C08 and C20, and in C18 without the key, because the old column is 1.0.0-beta.8), or the totals differ from the totals in the records,
4. a cell that is not PASS has no reading, or its reading names a sub-check that did not fail.

The readings are typed in `analysis/cells/compat_cells.py` with the record and point they come from. Only the sub-check they name is checked; the cause in the text is the claim of the record. State with the table: a FAIL means "differs from documented AWS S3 behaviour", not "defective"; the columns are deployments (C18 depends on a key or key service in Ceph, SeaweedFS and RustFS); the number of PASS cells weights all tests equally and is not a ranking; Ceph was probed on 2 October and not again; AWS CLI is the only client of the probe.
