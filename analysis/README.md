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
