#!/usr/bin/env python3
"""Thesis layout of the compatibility matrix (new script, build_compat.py stays unchanged).

Reads analysis/out/compat/compat_cells.csv (made by build_compat.py), checks it against the sha256 in
analysis/out/compat/MANIFEST.txt, and writes the matrix of the 22 tests with a wrapping text column, so that
it fits the page width. The verdicts are not recomputed: they are copied from compat_cells.csv.
Main comparison: RustFS 1.0.1 with the SSE-S3 master key (deployment "rustfs"). The variant without the key
("rustfs_default") is named in the caption only.
Writes to analysis/out/compat_thesis/.
"""
import csv
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPAT = ROOT / "analysis" / "out" / "compat"
OUTDIR = ROOT / "analysis" / "out" / "compat_thesis"
SYSTEMS = [("ceph", "Ceph"), ("seaweedfs", "SeaweedFS"), ("rustfs", "RustFS"), ("garage", "Garage")]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def tex_escape(text):
    return (text.replace("\\", r"\textbackslash{}").replace("&", r"\&").replace("%", r"\%")
            .replace("_", r"\_").replace("#", r"\#").replace("*", r"{*}"))


def main():
    cells_csv = COMPAT / "compat_cells.csv"
    recorded = None
    for line in (COMPAT / "MANIFEST.txt").read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([0-9a-f]{64})\s+analysis/out/compat/compat_cells\.csv$", line.strip())
        if m:
            recorded = m.group(1)
    if recorded != sha256(cells_csv):
        sys.exit("compat_cells.csv differs from the manifest of build_compat.py, stop")

    rows = list(csv.DictReader(open(cells_csv, encoding="utf-8")))
    tests = []
    for r in rows:
        if r["test"] not in tests:
            tests.append(r["test"])
    # feature names for the thesis table; the full descriptions stay in compat_cells.csv and in the
    # detail tables of the appendix
    what = {
        "C01": "Buckets", "C02": "Objects", "C03": "Headers and metadata", "C04": "Range reads",
        "C05": "Server-side copy", "C06": "Listing", "C07": "Deletion", "C08": "Multipart upload",
        "C09": "Tagging", "C10": "Versioning", "C11": "Conditional reads", "C12": "Conditional writes",
        "C13": "Presigned URLs", "C14": "Bucket policy", "C15": "CORS", "C16": "Lifecycle configuration",
        "C17": "Object lock", "C18": "SSE-S3 (API only)", "C19": "ACLs", "C20": "Integrity checksums",
        "C21": "Unusual object keys", "C22": "Error codes",
    }
    if set(what) != set(r["test"] for r in rows):
        sys.exit("feature names do not match the tests of compat_cells.csv")
    cell = {(r["test"], r["deployment"]): r for r in rows}
    if len(tests) != 22:
        sys.exit("expected 22 tests, found %d" % len(tests))

    def verdict(test, dep):
        r = cell[(test, dep)]
        word = {"PASS": "PASS", "FAIL": "FAIL", "UNSUPPORTED": "UNSUPPORTED"}[r["verdict"]]
        if r["depends_on_setting"]:
            word += r"\textsuperscript{a}"
        return word

    lines = [r"\begin{tabularx}{\textwidth}{@{}lXllll@{}}", r"\toprule",
             r"Test & Feature & Ceph & SeaweedFS & RustFS & Garage \\", r"\midrule"]
    for i, t in enumerate(tests):
        if i in (7,):
            lines.append(r"\midrule")
        lines.append("%s & %s & %s \\\\" % (t, tex_escape(what[t]),
                                            " & ".join(verdict(t, d) for d, _ in SYSTEMS)))
    lines.append(r"\midrule")
    for label, word in (("PASS", "PASS"), ("FAIL", "FAIL"), ("UNSUPPORTED", "UNSUPPORTED")):
        counts = [sum(1 for t in tests if cell[(t, d)]["verdict"] == word) for d, _ in SYSTEMS]
        lines.append(" & %s (of 22) & %s \\\\" % (label, " & ".join(str(c) for c in counts)))
    lines += [r"\bottomrule", r"\end{tabularx}"]

    OUTDIR.mkdir(parents=True, exist_ok=True)
    out = OUTDIR / "compat_matrix.tex"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")

    try:
        commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True,
                                text=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--", "analysis", "results",
                                ":(exclude)analysis/out"], capture_output=True, text=True).stdout.strip()
        state = "clean" if not dirty else "UNCOMMITTED CHANGES in analysis/ (outside out/) or results/"
    except Exception:
        commit, state = "unknown", "unknown"
    (OUTDIR / "MANIFEST.txt").write_text(
        "Thesis layout of the compatibility matrix: inputs and outputs\n"
        "=============================================================\n\n"
        "repository commit: %s\nworking tree (analysis, results): %s\npython %s\n\n"
        "%s  analysis/out/compat/compat_cells.csv\n%s  analysis/out/compat_thesis/compat_matrix.tex\n"
        % (commit, state, sys.version.split()[0], sha256(cells_csv), sha256(out)),
        encoding="utf-8", newline="\n")
    print("written to", OUTDIR)


if __name__ == "__main__":
    main()
