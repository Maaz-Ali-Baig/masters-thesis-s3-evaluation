#!/usr/bin/env python3
"""Latency tables for the performance chapter (new script, reads the same inputs as build_perf.py).

Reads the four per run tables of the VM series (results/perf-<system>-vm-3node-*-table-runs.tsv),
checks them against the sha256 values written in analysis/out/perf/MANIFEST.txt, and writes the median
over the three recorded runs of the average latency and of the 99th percentile latency per system and
configuration to analysis/out/perf_latency/. The mixed workload has no latency columns in the run tables
(perf-table.sh does not extract them for it), so it is not in the output.

It does not change any other script, table or record.
"""
import csv
import hashlib
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "results")
OUT = os.path.join(ROOT, "analysis", "out", "perf_latency")
PERF_MANIFEST = os.path.join(ROOT, "analysis", "out", "perf", "MANIFEST.txt")
PERF_LONG = os.path.join(ROOT, "analysis", "out", "perf", "perf_long.csv")

SYSTEMS = [
    ("Ceph", "perf-ceph-vm-3node-20261015-table-runs.tsv"),
    ("SeaweedFS", "perf-seaweedfs-vm-3node-20261012-table-runs.tsv"),
    ("RustFS", "perf-rustfs-vm-3node-20261010-table-runs.tsv"),
    ("Garage", "perf-garage-vm-3node-20261013-table-runs.tsv"),
]

# configuration order and labels of the table
CONFIGS = [
    ("put_50KiB_c8", "PUT 50 KiB, 8"), ("put_1MiB_c8", "PUT 1 MiB, 8"),
    ("put_16MiB_c8", "PUT 16 MiB, 8"), ("put_100MiB_c8", "PUT 100 MiB, 8"),
    ("put_1MiB_c1", "PUT 1 MiB, 1"), ("put_1MiB_c4", "PUT 1 MiB, 4"),
    ("put_1MiB_c16", "PUT 1 MiB, 16"), ("put_1MiB_c64", "PUT 1 MiB, 64"),
    ("get_50KiB_c8", "GET 50 KiB, 8"), ("get_1MiB_c8", "GET 1 MiB, 8"),
    ("get_16MiB_c8", "GET 16 MiB, 8"), ("get_100MiB_c8", "GET 100 MiB, 8"),
    ("get_1MiB_c1", "GET 1 MiB, 1"), ("get_1MiB_c4", "GET 1 MiB, 4"),
    ("get_1MiB_c16", "GET 1 MiB, 16"), ("get_1MiB_c64", "GET 1 MiB, 64"),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def recorded_hashes():
    """sha256 of the input files as written in the manifest of build_perf.py."""
    found = {}
    with open(PERF_MANIFEST, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([0-9a-f]{64})\s+(results/\S+)$", line.strip())
            if m:
                found[os.path.basename(m.group(2))] = m.group(1)
    return found


def to_ms(text):
    """Latency text such as '13.6ms' or '1.2s' to milliseconds."""
    m = re.match(r"^([0-9.]+)\s*(ms|s)$", text.strip())
    if not m:
        raise ValueError("cannot read latency value: %r" % text)
    value = float(m.group(1))
    return value * 1000.0 if m.group(2) == "s" else value


def client_limited():
    flags = {}
    with open(PERF_LONG, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            flags[(row["system"], row["configuration"])] = row["client_limited"] == "yes"
    return flags


def main():
    hashes = recorded_hashes()
    for _, name in SYSTEMS:
        path = os.path.join(RES, name)
        if hashes.get(name) != sha256(path):
            sys.exit("hash of %s differs from the manifest of build_perf.py, stop" % name)
    limited = client_limited()
    os.makedirs(OUT, exist_ok=True)

    data = {}  # (system, config) -> dict
    for system, name in SYSTEMS:
        runs = {}
        with open(os.path.join(RES, name), encoding="utf-8") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                label = row["run"]
                if label.startswith("mixed") or not row["avg_latency"].strip():
                    continue
                config = re.sub(r"_r[0-9]+$", "", label)
                runs.setdefault(config, []).append(
                    (to_ms(row["avg_latency"]), to_ms(row["p99_latency"])))
        for config, values in runs.items():
            if len(values) != 3:
                sys.exit("%s %s has %d runs, expected 3" % (system, config, len(values)))
            avg = [v[0] for v in values]
            p99 = [v[1] for v in values]
            data[(system, config)] = {
                "avg_median": statistics.median(avg), "avg_min": min(avg), "avg_max": max(avg),
                "p99_median": statistics.median(p99), "p99_min": min(p99), "p99_max": max(p99),
            }

    with open(os.path.join(OUT, "perf_latency.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["system", "configuration", "avg_median_ms", "avg_min_ms", "avg_max_ms",
                    "p99_median_ms", "p99_min_ms", "p99_max_ms", "client_limited"])
        for system, _ in SYSTEMS:
            for config, _label in CONFIGS:
                d = data[(system, config)]
                w.writerow([system, config,
                            "%.1f" % d["avg_median"], "%.1f" % d["avg_min"], "%.1f" % d["avg_max"],
                            "%.1f" % d["p99_median"], "%.1f" % d["p99_min"], "%.1f" % d["p99_max"],
                            "yes" if limited[(system, config)] else "no"])

    def fmt(x):
        return ("%.0f" % x) if x >= 100 else ("%.1f" % x)

    # one table per operation, with the object size and the concurrency in their own columns;
    # each cell is: median run average / median run 99th percentile (ms)
    def split_config(config):
        m = re.match(r"^(put|get)_(\w+)_c(\d+)$", config)
        return m.group(1), m.group(2).replace("KiB", " KiB").replace("MiB", " MiB"), m.group(3)

    for op in ("put", "get"):
        lines = [r"\begin{tabular}{llrrrr}", r"\toprule",
                 r"Object size & Concurrency & Ceph & SeaweedFS & RustFS & Garage \\", r"\midrule"]
        rows = [c for c, _ in CONFIGS if c.startswith(op + "_")]
        for i, config in enumerate(rows):
            if i == 4:
                lines.append(r"\midrule")
            _, size, conc = split_config(config)
            cells = []
            for system, _ in SYSTEMS:
                d = data[(system, config)]
                cell = "%s / %s" % (fmt(d["avg_median"]), fmt(d["p99_median"]))
                if limited[(system, config)]:
                    cell += r"$^{\dagger}$"
                cells.append(cell)
            lines.append("%s & %s & %s \\\\" % (size, conc, " & ".join(cells)))
        lines += [r"\bottomrule", r"\end{tabular}"]
        with open(os.path.join(OUT, "perf_latency_%s.tex" % op), "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")

    try:
        commit = subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip()
        state = subprocess.check_output(["git", "-C", ROOT, "status", "--porcelain", "analysis", "results"],
                                        text=True).strip()
        state = "clean" if not state else "UNCOMMITTED CHANGES in analysis/ or results/"
    except Exception:
        commit, state = "unknown", "unknown"
    with open(os.path.join(OUT, "MANIFEST.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("Latency tables of the performance series: inputs and outputs\n")
        f.write("=============================================================\n\n")
        f.write("repository commit: %s\nworking tree (analysis, results): %s\npython %s\n\n"
                % (commit, state, sys.version.split()[0]))
        f.write("INPUT FILES (results/), checked against analysis/out/perf/MANIFEST.txt\n")
        for _, name in SYSTEMS:
            f.write("%s  results/%s\n" % (sha256(os.path.join(RES, name)), name))
        f.write("%s  analysis/out/perf/perf_long.csv\n\n" % sha256(PERF_LONG))
        f.write("OUTPUT FILES\n")
        for name in ("perf_latency.csv", "perf_latency_put.tex", "perf_latency_get.tex"):
            f.write("%s  analysis/out/perf_latency/%s\n" % (sha256(os.path.join(OUT, name)), name))
    print("written to", OUT)


if __name__ == "__main__":
    main()
