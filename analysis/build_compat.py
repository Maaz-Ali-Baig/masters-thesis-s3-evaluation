#!/usr/bin/env python3
"""S3 compatibility table of the four systems (22 probe tests C01 to C22), tables only, no figures.

Run from anywhere:   python3 analysis/build_compat.py
Reads the summary.tsv of the five probe runs named in analysis/cells/compat_cells.py (four systems, RustFS twice: with and without the SSE-S3 master key) and the
old matrix results/compat-matrix-four-systems-2026-10-02.tsv. Writes to analysis/out/compat/.

What it does
1. Checks the sha256 of every summary.tsv against the value written in the records (for the three systems whose VM run has the same file, the record states that
   the VM summary.tsv has this sha256). Ceph: the pinned sha256 of the text copy of the run (results/compat-ceph-20261002-072634-evidence.txt).
2. Splits the sub-check column of every test into its sub-checks and recomputes the verdict with the rule of the record: UNSUPPORTED if a sub-check answered
   NotImplemented, else FAIL if a sub-check failed, else PASS. It stops if this differs from the verdict the probe wrote.
3. Compares the verdicts with the old matrix (Ceph, SeaweedFS, Garage must be equal; RustFS must differ exactly where the record says it differs, because the old
   column is RustFS 1.0.0-beta.8) and the totals with the totals written in the records.
4. Requires a typed reading (analysis/cells/compat_cells.py) for every cell that is not PASS, and checks that the sub-check named in the reading is in the
   summary line of that cell. The cause in the reading is the claim of the record; the script does not re-check it against the raw replies.
5. Writes compat_cells.csv, compat_summary.tex (22 rows by 4 systems), compat_details_<system>.tex and MANIFEST.txt.
A FAIL means "differs from documented AWS S3 behaviour", not "defective". UNSUPPORTED = the server answered NotImplemented.
"""
import hashlib
import re
import sys
import tarfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "cells"))
from common import OUT, RESULTS, ROOT, read_tsv, sha256, write_csv, write_manifest, write_text  # noqa: E402
import compat_cells as cc  # noqa: E402

OUTDIR = OUT / "compat"
OLD_MATRIX = RESULTS / "compat-matrix-four-systems-2026-10-02.tsv"
SYSTEMS = [("ceph", "Ceph"), ("seaweedfs", "SeaweedFS"), ("rustfs", "RustFS"), ("garage", "Garage")]
SHORT = {"PASS": "PASS", "FAIL": "FAIL", "UNSUPPORTED": "unsupported"}
# C18 depends on a setting of the deployment in three systems (key or key service); marked in the summary table
CONFIG_DEPENDENT = {("ceph", "C18"), ("seaweedfs", "C18"), ("rustfs", "C18")}


def tex(s):
    m = {"\\": "\\textbackslash{}", "&": "\\&", "%": "\\%", "$": "\\$", "#": "\\#", "_": "\\_", "{": "\\{", "}": "\\}", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}"}
    return "".join(m.get(ch, ch) for ch in s)


def summary_bytes(src):
    """Exact bytes of the summary.tsv of a source, and the sha256 that is checked."""
    if src["kind"] == "tar":
        with tarfile.open(RESULTS / src["file"], "r:gz") as tf:
            names = [m.name for m in tf.getmembers() if m.isfile() and m.name.endswith("/" + src["member"])]
            if len(names) != 1:
                sys.exit(f"{src['file']}: expected one {src['member']}, found {names}")
            data = tf.extractfile(names[0]).read()
        if "sha_archive" in src and sha256(RESULTS / src["file"]) != src["sha_archive"]:
            sys.exit(f"{src['file']} differs from the pinned archive sha256 {src['sha_archive']}")
        return data, hashlib.sha256(data).hexdigest(), src["sha_summary"]
    got_file = sha256(RESULTS / src["file"])
    if got_file != src["sha_file"]:
        sys.exit(f"{src['file']} differs from the pinned sha256\n  expected {src['sha_file']}\n  found    {got_file}")
    text = (RESULTS / src["file"]).read_text(encoding="utf-8").split("\n")
    start = text.index("### " + src["member"]) + 1
    end = next(i for i in range(start, len(text)) if text[i].startswith("### "))
    data = ("\n".join(text[start:end]) + "\n").encode("utf-8")
    return data, got_file, src["sha_file"]


def evidence_text_summary(c):
    """sha256 of the summary.tsv section of the text copy of the Ceph run of 2 October, after the pinned sha256 of the file."""
    got_file = sha256(RESULTS / c["file"])
    if got_file != c["sha_file"]:
        sys.exit(f"{c['file']} differs from the pinned sha256\n  expected {c['sha_file']}\n  found    {got_file}")
    text = (RESULTS / c["file"]).read_text(encoding="utf-8").split("\n")
    start = text.index("### " + c["member"]) + 1
    end = next(i for i in range(start, len(text)) if text[i].startswith("### "))
    return hashlib.sha256(("\n".join(text[start:end]) + "\n").encode("utf-8")).hexdigest()


def subchecks(detail):
    """'name:ok name:FAIL(text with spaces) ...' -> [(name, status)]. Rejoining must give the original text."""
    parts = re.split(r"\s(?=[A-Za-z0-9_]+:(?:ok\b|FAIL\())", detail.strip())
    res = []
    for p in parts:
        name, status = p.split(":", 1)
        res.append((name, status))
    if " ".join(f"{n}:{s}" for n, s in res) != detail.strip():
        sys.exit(f"sub-check split does not reproduce the text: {detail[:120]}")
    return res


def verdict_of(subs):
    if any(s.startswith("FAIL") and "NotImplemented" in s for _, s in subs):
        return "UNSUPPORTED"
    if any(s.startswith("FAIL") for _, s in subs):
        return "FAIL"
    return "PASS"


def build():
    cells = {}   # (system, test) -> dict
    what = {}
    inputs = []
    for key, src in cc.SOURCES.items():
        data, got, want = summary_bytes(src)
        if got != want:
            sys.exit(f"{src['file']} summary.tsv: sha256 {got} differs from the record ({want})")
        inputs.append(RESULTS / src["file"])
        rows = [ln.split("\t") for ln in data.decode("utf-8").splitlines() if ln.strip()]
        if [r[0] for r in rows] != [f"C{i:02d}" for i in range(1, 23)]:
            sys.exit(f"{key}: tests are not C01 to C22 in order")
        for r in rows:
            test, written, title, detail = r[0], r[1], r[2], r[3]
            subs = subchecks(detail)
            calc = verdict_of(subs)
            if calc != written:
                sys.exit(f"{key} {test}: the probe wrote {written}, the rule gives {calc}")
            what.setdefault(test, title)
            cells[(key, test)] = dict(verdict=calc, subs=subs, detail=detail, title=title)
    old2 = evidence_text_summary(cc.CROSS_CHECK)
    if old2 != cc.SOURCES["ceph"]["sha_summary"]:
        sys.exit(f"summary.tsv of the Ceph run of 2 October ({old2}) differs from the repeat of 16 October")
    inputs.append(RESULTS / cc.CROSS_CHECK["file"])
    print("Ceph: summary.tsv of the repeat of 16 October equals the summary.tsv of the run of 2 October")
    print(f"summary check: {len(cc.SOURCES)} runs, every sha256 equals the record, every verdict follows from its sub-checks")

    for key, want in cc.TOTALS_RECORD.items():
        got = tuple(sum(1 for t in what if cells[(key, t)]["verdict"] == v) for v in ("PASS", "FAIL", "UNSUPPORTED"))
        if got != want:
            sys.exit(f"{key}: totals {got} differ from the record {want}")
    print("totals equal the records:", ", ".join(f"{k} {v[0]}/{v[1]}/{v[2]}" for k, v in cc.TOTALS_RECORD.items()))

    old = {r["test"]: r for r in read_tsv(OLD_MATRIX)}
    for key, col in cc.OLD_MATRIX_SAME.items():
        bad = [t for t in what if old[t][col] != cells[(key, t)]["verdict"]]
        if bad:
            sys.exit(f"{key}: verdict differs from the old matrix in {bad}")
    for key, expect in cc.RUSTFS_DIFF_TO_OLD.items():
        diff = {t for t in what if old[t]["rustfs"] != cells[(key, t)]["verdict"]}
        if diff != expect:
            sys.exit(f"{key}: differences to the old RustFS column are {sorted(diff)}, the record says {sorted(expect)}")
    print("old matrix: Ceph, SeaweedFS, Garage equal; RustFS differs from the beta.8 column exactly where the record says")
    inputs.append(OLD_MATRIX)

    # readings
    bad = []
    for (key, test), c in cells.items():
        rd = cc.READINGS.get((key, test))
        if c["verdict"] == "PASS":
            if rd:
                bad.append(f"{key} {test}: reading for a PASS cell")
            continue
        if not rd:
            bad.append(f"{key} {test}: {c['verdict']} without a reading")
        elif not re.search(rd["pat"], c["detail"]):
            bad.append(f"{key} {test}: pattern {rd['pat']!r} not in the summary line")
    unused = [k for k in cc.READINGS if k not in cells]
    if bad or unused:
        sys.exit("READING CHECK FAILED:\n  " + "\n  ".join(bad + [f"unused reading {u}" for u in unused]))
    print(f"readings: {len(cc.READINGS)} cells that are not PASS, each names a sub-check that failed in its summary line")

    outputs = []
    p = OUTDIR / "compat_cells.csv"
    rows = []
    for t in sorted(what):
        for key, src in cc.SOURCES.items():
            c = cells[(key, t)]
            rd = cc.READINGS.get((key, t))
            failed = "; ".join(n for n, s in c["subs"] if s != "ok")
            rows.append([t, what[t], key, c["verdict"], len(c["subs"]), failed, "yes" if (key, t) in CONFIG_DEPENDENT or (key == "rustfs_default" and t == "C18") else "",
                         rd["text"] if rd else "", rd["src"] if rd else "", src["record"]])
    write_csv(p, ["test", "what", "deployment", "verdict", "sub_checks", "failed_sub_checks", "depends_on_setting", "reading_from_record", "reading_source", "record"], rows)
    outputs.append(p)

    lines = ["\\begin{tabular}{@{}llllll@{}}", "\\toprule", "Test & What & " + " & ".join(n for _, n in SYSTEMS) + " \\\\", "\\midrule"]
    for t in sorted(what):
        mark = lambda k: SHORT[cells[(k, t)]["verdict"]] + ("\\textsuperscript{a}" if (k, t) in CONFIG_DEPENDENT else "")
        lines.append(f"{t} & {tex(what[t])} & " + " & ".join(mark(k) for k, _ in SYSTEMS) + " \\\\")
    lines.append("\\midrule")
    for i, vname in enumerate(("PASS", "FAIL", "unsupported")):
        vv = ("PASS", "FAIL", "UNSUPPORTED")[i]
        lines.append(f" & {vname} (of 22) & " + " & ".join(str(sum(1 for t in what if cells[(k, t)]["verdict"] == vv)) for k, _ in SYSTEMS) + " \\\\")
    lines += ["\\bottomrule", "\\end{tabular}"]
    p = OUTDIR / "compat_summary.tex"
    write_text(p, "\n".join(lines) + "\n")
    outputs.append(p)

    for key, name in SYSTEMS:
        keys = [key] + (["rustfs_default"] if key == "rustfs" else [])
        lines = ["\\begin{tabular}{@{}lp{2.0cm}p{3.6cm}p{7.0cm}@{}}", "\\toprule", f"{name}: test & Verdict & Failed sub-checks & Reading (record) \\\\", "\\midrule"]
        for t in sorted(what):
            for k in keys:
                c = cells[(k, t)]
                rd = cc.READINGS.get((k, t))
                if rd is None:
                    continue
                if k == "rustfs_default" and rd["text"].startswith("Same as"):
                    continue
                lab = f"{t} ({cc.SOURCES[k]['label']})" if k == "rustfs_default" else t
                failed = ", ".join(n for n, s in c["subs"] if s != "ok")
                lines.append(f"{lab} & {SHORT[c['verdict']]} & {tex(failed)} & {tex(rd['text'])} \\\\")
        lines += ["\\bottomrule", "\\end{tabular}"]
        p = OUTDIR / f"compat_details_{key}.tex"
        write_text(p, "\n".join(lines) + "\n")
        outputs.append(p)

    inputs.append(Path(cc.__file__))
    write_manifest(OUTDIR / "MANIFEST.txt", "S3 compatibility table: inputs and outputs", inputs, outputs)
    print(f"wrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")


if __name__ == "__main__":
    build()
