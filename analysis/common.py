"""Shared helpers for the analysis scripts. Standard library only."""
import csv
import hashlib
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
OUT = ROOT / "analysis" / "out"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_tsv(path):
    """Tab separated file with a header line, as a list of dicts. Handles LF and CRLF."""
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_text(path, text):
    """Write with LF line endings, so the sha256 of an output does not depend on the machine."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        f.write(text)


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)


def verify_inputs(expected):
    """expected: {file name in results/: sha256 printed by the VM and written in the record}.
    Stops if a file differs: the analysis must run on the exact files the records cite."""
    bad = []
    for name, want in expected.items():
        p = RESULTS / name
        if not p.exists():
            bad.append(f"missing  {name}")
            continue
        got = sha256(p)
        if got != want:
            bad.append(f"differs  {name}\n           expected {want}\n           found    {got}")
    if bad:
        sys.exit("INPUT CHECK FAILED (a file in results/ is not the file the record cites; "
                 "if the file was converted to CRLF line endings, check out with LF):\n  "
                 + "\n  ".join(bad))
    print(f"input check: {len(expected)} files equal the sha256 written in the records")


def git_state():
    def run(*args):
        return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True,
                              timeout=20).stdout.strip()
    try:
        commit = run("rev-parse", "HEAD")
        dirty = run("status", "--porcelain", "--", "analysis", "results")
        return commit, ("clean" if not dirty else "UNCOMMITTED CHANGES in analysis/ or results/")
    except Exception as exc:  # git missing or slow: say so, do not guess
        return "unknown", f"git not readable ({exc.__class__.__name__})"


def environment_lines():
    lines = [f"python {platform.python_version()}"]
    try:
        import matplotlib
        lines.append(f"matplotlib {matplotlib.__version__}")
    except ImportError:
        lines.append("matplotlib not installed (no figures made)")
    return lines


def write_manifest(path, title, inputs, outputs):
    """inputs/outputs: lists of Path. One line each with sha256."""
    commit, state = git_state()
    out = [title, "=" * len(title), "",
           f"repository commit: {commit}", f"working tree (analysis, results): {state}"]
    out += environment_lines()
    out += ["", "INPUT FILES (results/)"]
    out += [f"{sha256(p)}  {p.relative_to(ROOT).as_posix()}" for p in inputs]
    out += ["", "OUTPUT FILES"]
    out += [f"{sha256(p)}  {p.relative_to(ROOT).as_posix()}" for p in outputs]
    write_text(path, "\n".join(out) + "\n")
