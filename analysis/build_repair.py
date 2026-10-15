#!/usr/bin/env python3
"""Recovery evidence of the fault tolerance runs: what the repair watch recorded after the stopped node(s) came back.

Run from anywhere:   python3 analysis/build_repair.py
Reads the run archives results/ft-*.tar.gz (member repairwatch.tsv, plus the files used by build_ft.py) and writes to analysis/out/repair/.

Two kinds of evidence, which are NOT the same quantity and are never put in one column
  Garage, RustFS, SeaweedFS   ft-repairwatch.sh counts files on every drive of every node every 20 s (Garage: the whole data directories,
                              RustFS: the files of the run's key prefix, SeaweedFS: the files of the volumes of the bucket). A file count is not
                              a proof of integrity or of repair; it shows whether the returned node ends with as many files as the nodes that stayed up.
  Ceph                        ceph status every 20 s: health, OSDs up and in, PGs active+clean, degraded and misplaced objects.
Definitions
  lag            files on the returned node minus the mean of the files on the nodes that stayed up, in the same sample, summed over the drives
                 of the node. The mean of the samples before the stop is the baseline (earlier runs on the same cluster left differences, see the records),
                 and the lag is reported relative to this baseline.
  closed         from the first sample after the return from which every later sample has |lag| <= TOL files. TOL = 3 files, because the probe kept
                 writing (about one object every 2 s) during the watch, so counts differ by up to 2 files at any moment (RustFS, before and after the stop).
  return         the first successful read of the fixed object at the returned endpoint (build_ft.py, targets_back_rel), the same for all systems.
Runs without a repair watch after the return (Garage run 1, Garage S2 and the RustFS runs of 11 October) are listed as such and not used.
"""
import csv
import io
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, RESULTS, verify_inputs, write_csv, write_manifest, write_text  # noqa: E402
import build_ft  # noqa: E402

OUTDIR = OUT / "repair"
TOL = 3.0
ALL_NODES = ["192.168.1.72", "192.168.1.71", "192.168.1.70"]
NODE = build_ft.NODE


def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


def files_lag(r, text):
    """Lag samples per returned node for a run with the file count format. Returns {node: [(t_rel, lag_rel)]}, baseline, or None."""
    rows = list(csv.DictReader(io.StringIO(text), delimiter="\t"))
    if not rows or "files" not in rows[0]:
        return None
    t0 = r["_t0"]
    targets = [t for t in ALL_NODES if any(e.startswith(t + ":") for e in r["_targets"])]
    ref = [n for n in ALL_NODES if n not in targets]
    uniq = {}
    for x in rows:  # the last sample is written twice with the same time stamp: one row per (time, node, drive)
        uniq[(int(x["epoch"]), x["node"], x["data_dir"])] = num(x["files"])
    by = {}
    for (t, node, _), v in uniq.items():
        by.setdefault(t, {}).setdefault(node, []).append(v)
    out = {}
    base = {}
    for tg in targets:
        s = []
        for t, nd in sorted(by.items()):
            tot = {n: (None if any(v is None for v in vs) else sum(vs)) for n, vs in nd.items()}
            if tot.get(tg) is None or any(tot.get(n) is None for n in ref):
                continue
            s.append((t - t0, tot[tg] - sum(tot[n] for n in ref) / len(ref)))
        pre = [v for t, v in s if t < 0]
        if not pre:
            return None
        base[tg] = sum(pre) / len(pre)
        out[tg] = [(t, v - base[tg]) for t, v in s]
    return out, base


def analyse_files(r, lag):
    res = []
    back = r["targets_back_rel"]
    for tg, s in lag[0].items():
        if back is None or not s or s[-1][0] < back:
            res.append(dict(node=tg, usable=False))
            continue
        low = min(s, key=lambda x: x[1])
        after = [(t, v) for t, v in s if t >= back]
        closed_at = None
        for i in range(len(after)):
            if all(abs(v) <= TOL for _, v in after[i:]):
                closed_at = after[i][0] - back
                break
        res.append(dict(node=tg, usable=True, base=lag[1][tg], lowest=low[1], lowest_at=low[0], end=after[-1][1], end_after_return=after[-1][0] - back,
                        closed_after=closed_at, last10=max(abs(v) for t, v in after if t >= after[-1][0] - 600)))
    return res


def analyse_ceph(r, text):
    rows = list(csv.DictReader(io.StringIO(text), delimiter="\t"))
    t0, back = r["_t0"], r["targets_back_rel"]
    g = []
    for x in rows:
        g.append(dict(t=int(x["epoch"]) - t0, health=x["health"], up=num(x["osds_up"]), inn=num(x["osds_in"]), clean=num(x["pgs_active_clean"]),
                      pgs=num(x["pgs_total"]), deg=num(x["degraded_objects"]), mis=num(x["misplaced_objects"])))
    after = [x for x in g if back is not None and x["t"] >= back]
    ok = next((x for x in after if x["health"] == "HEALTH_OK"), None)
    clean = next((x for x in after if x["pgs"] and x["clean"] == x["pgs"] and x["deg"] == 0), None)
    degs = [(x["deg"], x["t"]) for x in g if x["deg"] is not None]
    peak = max(degs) if degs else (None, None)
    return dict(g=g, noquorum_rows=sum(1 for x in g if "QUORUM" in x["health"].upper()), peak_degraded=peak[0], peak_degraded_at=peak[1],
                min_osds_in=None if any("QUORUM" in x["health"].upper() for x in g) else min((x["inn"] for x in g if x["inn"] is not None), default=None),  # without quorum the OSD count is not measured
                health_ok_after_return=None if ok is None or back is None else round(ok["t"] - back, 1),
                pgs_clean_after_return=None if clean is None or back is None else round(clean["t"] - back, 1))


def build():
    inv = {}
    for line in build_ft.INVENTORY.read_text().splitlines():
        h, f = line.split()
        inv[f] = h
    wanted = {f: h for f, h in inv.items() if f.startswith("ft-")}
    verify_inputs(wanted)
    files_rows, ceph_rows, unused = [], [], []
    plots_files, plots_ceph = [], []
    for f in sorted(wanted):
        name = f[: -len(".tar.gz")]
        parts = build_ft.read_archive(RESULTS / f)
        r = build_ft.analyse(name, parts)
        text = parts.get("repairwatch.tsv")
        if text is None:
            unused.append((name, "no repairwatch.tsv in the archive"))
            continue
        label = f"{build_ft.SYSTEM_NAME[r['system']]} {r['scenario']} {name.split('-')[-1]}"
        if r["system"] == "ceph":
            c = analyse_ceph(r, text)
            ceph_rows.append((r, label, c))
            plots_ceph.append((r, label, c))
            continue
        lag = files_lag(r, text)
        if lag is None:
            unused.append((name, "repair watch format or baseline missing"))
            continue
        res = analyse_files(r, lag)
        if not any(x["usable"] for x in res):
            unused.append((name, "the repair watch ends before the node answered again"))
            continue
        for x in res:
            files_rows.append((r, label, x))
        plots_files.append((r, label, lag))

    for name, why in unused:
        print(f"not used: {name} ({why})")
    outputs = []
    p = OUTDIR / "repair_files.csv"
    write_csv(p, ["run", "node", "baseline_lag_files", "lowest_lag_files", "lowest_at_s_from_silence", "end_lag_files", "end_s_after_return",
                  "closed_after_s", "max_abs_lag_last_10min", "tol_files"],
              [[r["run"], NODE[x["node"]], f"{x['base']:.1f}", f"{x['lowest']:.0f}", f"{x['lowest_at']:.0f}", f"{x['end']:.1f}", f"{x['end_after_return']:.0f}",
                "" if x["closed_after"] is None else f"{x['closed_after']:.0f}", f"{x['last10']:.1f}", TOL] for r, _, x in files_rows if x["usable"]])
    outputs.append(p)
    p = OUTDIR / "repair_ceph.csv"
    write_csv(p, ["run", "peak_degraded_objects", "peak_at_s_from_silence", "min_osds_in", "noquorum_rows", "pgs_clean_after_return_s", "health_ok_after_return_s"],
              [[r["run"], c["peak_degraded"], c["peak_degraded_at"], c["min_osds_in"], c["noquorum_rows"], c["pgs_clean_after_return"], c["health_ok_after_return"]]
               for r, _, c in ceph_rows])
    outputs.append(p)

    lines = ["\\begin{tabular}{llrrrr}", "\\toprule", "Run & Node & Lowest lag & End lag & End (s after return) & Closed after (s) \\\\", "\\midrule"]
    prev = None
    for r, label, x in files_rows:
        if not x["usable"]:
            continue
        if prev and prev != r["system"]:
            lines.append("\\midrule")
        prev = r["system"]
        closed = "not closed" if x["closed_after"] is None else f"{x['closed_after']:.0f}"
        lines.append(f"{label} & {NODE[x['node']]} & {int(round(x['lowest']))} & {int(round(x['end']))} & {x['end_after_return']:.0f} & {closed} \\\\")
    lines += ["\\bottomrule", "\\end{tabular}"]
    p = OUTDIR / "repair_files.tex"
    write_text(p, "\n".join(lines) + "\n")
    outputs.append(p)

    lines = ["\\begin{tabular}{lrrrr}", "\\toprule", "Run & Peak degraded objects & Lowest OSDs in & PGs clean after return (s) & HEALTH\\_OK after return (s) \\\\", "\\midrule"]
    f1 = lambda v: "n/a" if v is None else f"{v:.0f}"  # noqa: E731
    for r, label, c in ceph_rows:
        lines.append(f"{label} & {f1(c['peak_degraded'])} & {f1(c['min_osds_in'])} & {f1(c['pgs_clean_after_return'])} & {f1(c['health_ok_after_return'])} \\\\")
    lines += ["\\bottomrule", "\\end{tabular}"]
    p = OUTDIR / "repair_ceph.tex"
    write_text(p, "\n".join(lines) + "\n")
    outputs.append(p)

    outputs += figures(plots_files, plots_ceph)
    inputs = [RESULTS / f for f in sorted(wanted)] + [build_ft.INVENTORY]
    write_manifest(OUTDIR / "MANIFEST.txt", "Recovery evidence of the fault tolerance runs: inputs and outputs", inputs, outputs)
    print(f"\nwrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")
    for r, label, x in files_rows:
        if x["usable"]:
            print(f"{label} {NODE[x['node']]}: lowest {x['lowest']:.0f}, end {x['end']:.1f} files at {x['end_after_return']:.0f} s after return, "
                  f"closed after {'never' if x['closed_after'] is None else str(round(x['closed_after'])) + ' s'}")
    for r, label, c in ceph_rows:
        print(f"{label}: peak degraded {c['peak_degraded']}, PGs clean {c['pgs_clean_after_return']} s, HEALTH_OK {c['health_ok_after_return']} s after return")


def figures(plots_files, plots_ceph):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib is not installed: tables written, figures skipped")
        return []
    plt.rcParams.update({"font.size": 8, "axes.spines.top": False, "axes.spines.right": False, "pdf.fonttype": 42})
    outs = []
    col = ["#0072B2", "#D55E00"]
    fig, axes = plt.subplots(len(plots_files), 1, figsize=(7.2, 1.9 * len(plots_files) + 0.4), squeeze=False)
    for ax, (r, label, lag) in zip(axes[:, 0], plots_files):
        for k, (tg, s) in enumerate(lag[0].items()):
            ax.plot([t for t, _ in s], [v for _, v in s], color=col[k % 2], lw=1, label=f"{NODE[tg]} (baseline lag {lag[1][tg]:.0f})")
        ax.axhspan(-TOL, TOL, color="#999999", alpha=0.2, lw=0)
        ax.axvline(0, color="k", lw=0.6, ls="--")
        if r["targets_back_rel"] is not None:
            ax.axvline(r["targets_back_rel"], color="#0072B2", lw=0.6, ls=":")
        ax.set_title(f"{label} (lag in files)", fontsize=7, loc="left")
        ax.set_ylabel("files")
        ax.legend(fontsize=6, frameon=False, loc="lower left")
    axes[-1, 0].set_xlabel("seconds from silence (dashed); dotted: endpoint back; grey band: +-3 files")
    fig.tight_layout()
    outs += save(fig, "repair_files", plt)

    fig, axes = plt.subplots(len(plots_ceph), 1, figsize=(7.2, 1.9 * len(plots_ceph) + 0.4), squeeze=False)
    for ax, (r, label, c) in zip(axes[:, 0], plots_ceph):
        def gapped(rows, key):  # a break in the line where no status was read for more than 90 s (no monitor quorum)
            xs, ys, last = [], [], None
            for x in rows:
                if x[key] is None:
                    continue
                if last is not None and x["t"] - last > 90:
                    xs.append(float("nan"))
                    ys.append(float("nan"))
                xs.append(x["t"])
                ys.append(x[key])
                last = x["t"]
            return xs, ys
        ax.plot(*gapped(c["g"], "deg"), color="#D55E00", lw=1, label="degraded objects")
        ax.plot(*gapped(c["g"], "mis"), color="#0072B2", lw=1, label="misplaced objects")
        ax2 = ax.twinx()
        ax2.step(*gapped(c["g"], "inn"), color="#009E73", lw=0.8, where="post")
        ax2.set_ylim(0, 7)
        ax2.set_ylabel("OSDs in", color="#009E73")
        for t in [x["t"] for x in c["g"] if "QUORUM" in x["health"].upper()][:1]:
            ax.axvline(t, color="k", lw=0.6)
        ax.axvline(0, color="k", lw=0.6, ls="--")
        if r["targets_back_rel"] is not None:
            ax.axvline(r["targets_back_rel"], color="#0072B2", lw=0.6, ls=":")
        ax.set_title(label, fontsize=7.5, loc="left")
        ax.set_ylabel("objects")
        ax.legend(fontsize=6, frameon=False, loc="upper left")
    axes[-1, 0].set_xlabel("seconds from silence (dashed); dotted: endpoint back; solid black: first row without monitor quorum")
    fig.tight_layout()
    outs += save(fig, "repair_ceph", plt)
    return outs


def save(fig, name, plt):
    OUTDIR.mkdir(parents=True, exist_ok=True)
    paths = []
    for ext in ("pdf", "png"):
        p = OUTDIR / f"{name}.{ext}"
        kw = {"metadata": {"CreationDate": None}} if ext == "pdf" else {"dpi": 200}
        fig.savefig(p, **kw)
        paths.append(p)
    plt.close(fig)
    return paths


if __name__ == "__main__":
    build()
