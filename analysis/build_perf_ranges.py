#!/usr/bin/env python3
"""Range table for the performance chapter (new script, reads analysis/out/perf/perf_long.csv).

perf_long.csv holds, per system and configuration, the median, the minimum and the maximum of the three
recorded runs (written by build_perf.py). This script checks perf_long.csv against the sha256 in
analysis/out/perf/MANIFEST.txt and writes one table with the lowest and the highest run per cell to
analysis/out/perf_ranges/. It does not change any other script, table or record.
"""
import csv
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERF = os.path.join(ROOT, "analysis", "out", "perf")
OUT = os.path.join(ROOT, "analysis", "out", "perf_ranges")
SYSTEMS = ["Ceph", "SeaweedFS", "RustFS", "Garage"]

CONFIGS = [
    ("put_50KiB_c8", "PUT 50 KiB, 8"), ("put_1MiB_c8", "PUT 1 MiB, 8"),
    ("put_16MiB_c8", "PUT 16 MiB, 8"), ("put_100MiB_c8", "PUT 100 MiB, 8"),
    ("put_1MiB_c1", "PUT 1 MiB, 1"), ("put_1MiB_c4", "PUT 1 MiB, 4"),
    ("put_1MiB_c16", "PUT 1 MiB, 16"), ("put_1MiB_c64", "PUT 1 MiB, 64"),
    ("get_50KiB_c8", "GET 50 KiB, 8"), ("get_1MiB_c8", "GET 1 MiB, 8"),
    ("get_16MiB_c8", "GET 16 MiB, 8"), ("get_100MiB_c8", "GET 100 MiB, 8"),
    ("get_1MiB_c1", "GET 1 MiB, 1"), ("get_1MiB_c4", "GET 1 MiB, 4"),
    ("get_1MiB_c16", "GET 1 MiB, 16"), ("get_1MiB_c64", "GET 1 MiB, 64"),
    ("mixed_1MiB_c16", "Mixed 1 MiB, 16"),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    long_csv = os.path.join(PERF, "perf_long.csv")
    recorded = None
    with open(os.path.join(PERF, "MANIFEST.txt"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([0-9a-f]{64})\s+analysis/out/perf/perf_long\.csv$", line.strip())
            if m:
                recorded = m.group(1)
    if recorded != sha256(long_csv):
        sys.exit("perf_long.csv differs from the manifest of build_perf.py, stop")

    cells = {}
    with open(long_csv, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            cells[(row["system"], row["configuration"])] = row

    os.makedirs(OUT, exist_ok=True)
    lines = [r"\begin{tabular}{lllll}", r"\toprule",
             r"Configuration & Ceph & SeaweedFS & RustFS & Garage \\", r"\midrule"]
    for i, (config, label) in enumerate(CONFIGS):
        if i in (4, 8, 12, 16):
            lines.append(r"\midrule")
        parts = []
        for system in SYSTEMS:
            row = cells[(system, config)]
            cell = "%s to %s" % (row["min_MiB_s"], row["max_MiB_s"])
            if row["client_limited"] == "yes":
                cell += r"$^{\dagger}$"
            parts.append(cell)
        lines.append("%s & %s \\\\" % (label, " & ".join(parts)))
    lines += [r"\bottomrule", r"\end{tabular}"]
    with open(os.path.join(OUT, "perf_ranges.tex"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    try:
        commit = subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        commit = "unknown"
    with open(os.path.join(OUT, "MANIFEST.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("Range table of the performance series: inputs and outputs\n")
        f.write("==========================================================\n\n")
        f.write("repository commit: %s\npython %s\n\n" % (commit, sys.version.split()[0]))
        f.write("%s  analysis/out/perf/perf_long.csv\n" % sha256(long_csv))
        f.write("%s  analysis/out/perf_ranges/perf_ranges.tex\n" % sha256(os.path.join(OUT, "perf_ranges.tex")))
    print("written to", OUT)


if __name__ == "__main__":
    main()
