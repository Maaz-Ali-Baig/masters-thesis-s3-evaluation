#!/usr/bin/env python3
"""Security comparison table of the four systems on the VMs (tables only, no figures).

Run from anywhere:   python3 analysis/build_security.py
Reads analysis/cells/security_cells.py (cells filled by hand from the security records) and the raw outputs in results/sec-*.tar.gz, results/presign-*.tar.gz
(and one plain file for the Ceph presigned test). Writes to analysis/out/security/.

What it does
1. Checks the sha256 of every archive it uses against results/vm-archives-ceph0-SHA256SUMS.txt.
2. For every cell, searches each evidence pattern in the raw output (the pattern must be found at least the stated number of times; "ABSENT" means the member must
   not exist, i.e. the check was not run). If one pattern is not found the script stops: a cell that the raw output does not support cannot be published.
3. Writes security_cells.csv (all 52 cells with the result of the evidence check), security_summary.tex (13 rows by 4 systems, outcome words only),
   security_details_<system>.tex (row, outcome, text, record) and MANIFEST.txt.
Outcome words: PASS and FAIL follow the pass conditions of security_method.md (a FAIL is a finding about the default deployment, not a judgement of the product),
REFUSED = the server refused the request meant to enable the feature, NOT IN CLEAR = SSE accepted and the marker not found on the drives (strength not shown),
INFO = a fact without a pass condition, NOT TESTED = the check was not run or found nothing to test.
"""
import re
import sys
import tarfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "cells"))
from common import OUT, RESULTS, ROOT, verify_inputs, write_csv, write_manifest, write_text  # noqa: E402
import security_cells as sc  # noqa: E402

OUTDIR = OUT / "security"
INVENTORY = RESULTS / "vm-archives-ceph0-SHA256SUMS.txt"
SYSTEMS = [("ceph", "Ceph"), ("seaweedfs", "SeaweedFS"), ("rustfs", "RustFS"), ("garage", "Garage")]
SHORT = {"PASS": "PASS", "FAIL": "FAIL", "REFUSED": "refused", "NOT IN CLEAR": "not in clear", "INFO": "info", "NOT TESTED": "n.t."}
_cache = {}


def tex(s):
    out = []
    for ch in s:
        out.append({"\\": "\\textbackslash{}", "&": "\\&", "%": "\\%", "$": "\\$", "#": "\\#", "_": "\\_", "{": "\\{", "}": "\\}", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}"}.get(ch, ch))
    return "".join(out)


def load(archive):
    """Text of all members of an archive (name -> text), or of a plain file ("file:results/...") under the key ""."""
    if archive in _cache:
        return _cache[archive]
    if archive.startswith("file:"):
        p = ROOT / archive[5:]
        res = {"": p.read_text(encoding="utf-8", errors="replace")}
    else:
        res = {}
        with tarfile.open(RESULTS / f"{archive}.tar.gz", "r:gz") as tf:
            for m in tf.getmembers():
                if m.isfile():
                    res[m.name.split("/", 1)[-1]] = tf.extractfile(m).read().decode("utf-8", errors="replace")
    _cache[archive] = res
    return res


def check(ev):
    """Returns (ok, note) for a list of evidence items."""
    notes = []
    for item in ev:
        archive, member, pattern = item[0], item[1], item[2]
        need = item[3] if len(item) > 3 else 1
        files = load(archive)
        if pattern == "ABSENT":
            if member in files:
                return False, f"{archive}:{member} exists but the cell says the check was not run"
            notes.append(f"{member} absent")
            continue
        if member not in files:
            return False, f"{archive}:{member} not found"
        n = len(re.findall(pattern, files[member], flags=re.M))
        if n < need:
            return False, f"{archive}:{member}: pattern {pattern!r} found {n} times, needed {need}"
        notes.append(f"{n}x")
    return True, " ".join(notes)


def build():
    inv = {}
    for line in INVENTORY.read_text().splitlines():
        h, f = line.split()
        inv[f] = h
    used = sorted({e[0] for c in sc.CELLS.values() for e in c["ev"] if not e[0].startswith("file:")})
    verify_inputs({f"{a}.tar.gz": inv[f"{a}.tar.gz"] for a in used})
    plain_files = sorted({e[0][5:] for c in sc.CELLS.values() for e in c["ev"] if e[0].startswith("file:")})

    rows = []
    bad = []
    for key, c in sc.CELLS.items():
        ok, note = check(c["ev"])
        if not ok:
            bad.append((key, note))
        rows.append((key[0], key[1], c["out"], c["text"], c["src"], ok, note))
    if bad:
        sys.exit("EVIDENCE CHECK FAILED:\n  " + "\n  ".join(f"{k}: {n}" for k, n in bad))
    print(f"evidence check: {len(rows)} cells, every pattern found in the raw output of the archives")
    if len(rows) != len(sc.ROWS) * len(SYSTEMS):
        sys.exit(f"expected {len(sc.ROWS) * len(SYSTEMS)} cells, found {len(rows)}")

    outputs = []
    order = {s: i for i, (s, _) in enumerate(SYSTEMS)}
    rowid = {r[0]: i for i, r in enumerate(sc.ROWS)}
    rows.sort(key=lambda r: (rowid[r[1]], order[r[0]]))
    label = {r[0]: (r[1], r[2]) for r in sc.ROWS}
    p = OUTDIR / "security_cells.csv"
    write_csv(p, ["row", "check", "what", "system", "outcome", "text", "record", "evidence_found"],
              [[r[1], label[r[1]][0], label[r[1]][1], r[0], r[2], r[3], r[4], r[6]] for r in rows])
    outputs.append(p)

    cell = {(r[0], r[1]): r for r in rows}
    lines = ["\\begin{tabular}{@{}llllll@{}}", "\\toprule", "Check & What & " + " & ".join(n for _, n in SYSTEMS) + " \\\\", "\\midrule"]
    for rid, chk, what in sc.ROWS:
        lines.append(f"{chk} & {tex(what)} & " + " & ".join(SHORT[cell[(s, rid)][2]] for s, _ in SYSTEMS) + " \\\\")
    lines += ["\\bottomrule", "\\end{tabular}"]
    p = OUTDIR / "security_summary.tex"
    write_text(p, "\n".join(lines) + "\n")
    outputs.append(p)

    for s, name in SYSTEMS:
        lines = ["\\begin{tabular}{@{}p{3.6cm}lp{7.4cm}p{3.6cm}@{}}", "\\toprule", f"{name}: what & Outcome & Evidence & Record \\\\", "\\midrule"]
        for rid, chk, what in sc.ROWS:
            r = cell[(s, rid)]
            lines.append(f"{chk} {tex(what)} & {SHORT[r[2]]} & {tex(r[3])} & {tex(r[4])} \\\\")
        lines += ["\\bottomrule", "\\end{tabular}"]
        p = OUTDIR / f"security_details_{s}.tex"
        write_text(p, "\n".join(lines) + "\n")
        outputs.append(p)

    inputs = [RESULTS / f"{a}.tar.gz" for a in used] + [ROOT / f for f in plain_files] + [INVENTORY, Path(sc.__file__)]
    write_manifest(OUTDIR / "MANIFEST.txt", "Security comparison table: inputs and outputs", inputs, outputs)
    print(f"wrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")
    counts = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
    print("outcomes:", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))


if __name__ == "__main__":
    build()
