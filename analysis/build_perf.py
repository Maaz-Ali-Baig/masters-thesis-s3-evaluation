#!/usr/bin/env python3
"""Performance comparison of the four systems on the VMs: tables and figures.

Run from anywhere:   python3 analysis/build_perf.py
Reads only files in results/ (the tables the performance records cite), writes to analysis/out/perf/.

What it does
1. Checks every input file against the sha256 written in the records (stops on a difference).
2. Recomputes median, minimum and maximum of the three recorded runs per configuration from the
   per run tables and compares them with the config tables made on the VMs (stops on a difference).
3. Marks a configuration of a system as client limited when the mean CPU of the load node ceph2 is
   above 80 percent in that configuration (rule of performance_method.md, section 3). The CPU
   comes from the sar tables of the same series.
4. Writes long and wide tables (CSV and LaTeX), a ranking table, and figures (PDF and PNG).
5. Writes MANIFEST.txt with the commit, the library versions and the sha256 of all inputs and outputs.

Nothing in this file is typed from the records except the sha256 values of the input files and the
list of client limited configurations that the records state (used only as a cross check).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, RESULTS, read_tsv, verify_inputs, write_csv, write_manifest, write_text  # noqa: E402

OUTDIR = OUT / "perf"
LOAD_NODE = "ceph2"
CLIENT_LIMIT_CPU = 80.0

# Order of the systems as in the thesis (Ceph, SeaweedFS, RustFS, Garage).
SYSTEMS = [
    dict(key="ceph", name="Ceph",
         runs="perf-ceph-vm-3node-20261015-table-runs.tsv",
         configs="perf-ceph-vm-3node-20261015-table-configs.tsv",
         sar="perf-ceph-vm-3node-20261015-sar-runs-ceph2.tsv", sar_kind="runs",
         record_flags=None),
    dict(key="seaweedfs", name="SeaweedFS",
         runs="perf-seaweedfs-vm-3node-20261012-table-runs.tsv",
         configs="perf-seaweedfs-vm-3node-20261012-table-configs.tsv",
         sar="perf-seaweedfs-vm-3node-20261012-sar-configs.tsv", sar_kind="configs",
         record_flags={"put_100MiB_c8", "put_16MiB_c8", "mixed_1MiB_c16"}),
    dict(key="rustfs", name="RustFS",
         runs="perf-rustfs-vm-3node-20261010-table-runs.tsv",
         configs="perf-rustfs-vm-3node-20261010-table-configs.tsv",
         sar="perf-rustfs-vm-3node-20261010-sar-configs.tsv", sar_kind="configs",
         record_flags={"put_100MiB_c8", "put_16MiB_c8", "get_50KiB_c8"}),
    dict(key="garage", name="Garage",
         runs="perf-garage-vm-3node-20261013-table-runs.tsv",
         configs="perf-garage-vm-3node-20261013-table-configs.tsv",
         sar="perf-garage-vm-3node-20261013-sar-runs-ceph2.tsv", sar_kind="runs",
         record_flags=set()),
]

# sha256 of the input files as printed by the VMs and written in the records
# (results/<system>-vm-performance-*.txt and the sar records).
EXPECTED_SHA256 = {
    "perf-ceph-vm-3node-20261015-table-runs.tsv": "8622184a04d1c8fc0ab689e57549b303616e0633665bcebb959d6cd4358cd88d",
    "perf-ceph-vm-3node-20261015-table-configs.tsv": "a21360dd0f2fd4a4f8e658969ac4727878636b25ac7b90fd58fad06cb29afaf4",
    "perf-ceph-vm-3node-20261015-sar-runs-ceph2.tsv": "5647b198b0241b35c8820c6679ffb22e3e01e40277213e73a3870a815d6dff40",
    "perf-seaweedfs-vm-3node-20261012-table-runs.tsv": "321c283abb182adef897391b372464e09bd4a4dff16bae9e5c11177a4014b579",
    "perf-seaweedfs-vm-3node-20261012-table-configs.tsv": "7bef6987cd224be33eb395477d26cb19c14ed78b1e3c169c3dbddd03f12588b3",
    "perf-seaweedfs-vm-3node-20261012-sar-configs.tsv": "dc349388afcbd759f3f1a3157fed58ed3d0147876c75b6f7751872ef3ee286de",
    "perf-rustfs-vm-3node-20261010-table-runs.tsv": "79efdebc85fb0924d2125dc6bc0317f8b59397517126aba363bc936469acdcc0",
    "perf-rustfs-vm-3node-20261010-table-configs.tsv": "6d428ab2e30e01250156c13d182cdc0adeca146e6fd61fae6bfd10d3ed532736",
    "perf-rustfs-vm-3node-20261010-sar-configs.tsv": "10cb92cf95f2c6d6af999ee7f151b5747c26190067024b9f2f3eff792b8ef7c3",
    "perf-garage-vm-3node-20261013-table-runs.tsv": "61b6394ca320c00eb56ed694e6f3ce7bac80a0784a3f111e0bf0954f97158a22",
    "perf-garage-vm-3node-20261013-table-configs.tsv": "9f061d427d5ac625c800f5dc8c9d5172c320ce6d44e3766c4280c2b04d2f969e",
    "perf-garage-vm-3node-20261013-sar-runs-ceph2.tsv": "41951fa5d596509907bcb9c6fcd495cb36483a004d468568dadf72db1ef6632b",
}

SIZES = ["50KiB", "1MiB", "16MiB", "100MiB"]
SIZE_LABEL = {"50KiB": "50 KiB", "1MiB": "1 MiB", "16MiB": "16 MiB", "100MiB": "100 MiB"}
CONCS = [1, 4, 8, 16, 64]
OPS = ["put", "get"]


def cfg_name(op, size, conc):
    return f"{op}_{size}_c{conc}"


SIZE_ROWS = [(op, s, 8) for op in OPS for s in SIZES]
CONC_ROWS = [(op, "1MiB", c) for op in OPS for c in CONCS]
MIXED = "mixed_1MiB_c16"


def median3(values):
    v = sorted(values)
    if len(v) != 3:
        sys.exit(f"expected 3 recorded runs, found {len(v)}")
    return v[1]


def load_system(s):
    """Per configuration: median, min, max, list of run values, from the per run table."""
    by = {}
    errors = 0
    for r in read_tsv(RESULTS / s["runs"]):
        cfg, _, rep = r["run"].rpartition("_r")
        thr = r["throughput"].split()
        if len(thr) != 2 or thr[1] != "MiB/s":
            sys.exit(f"{s['runs']}: unexpected throughput text {r['throughput']!r}")
        by.setdefault(cfg, []).append(float(thr[0]))
        errors += int(r["error_lines"])
    stats = {c: dict(median=median3(v), min=min(v), max=max(v), n=len(v)) for c, v in by.items()}
    # cross check with the config table made on the VM
    mism = []
    ref = read_tsv(RESULTS / s["configs"])
    if {r["configuration"] for r in ref} != set(stats):
        sys.exit(f"{s['name']}: configurations of the run table and the config table differ")
    for r in ref:
        c = r["configuration"]
        for key, col in (("median", "median_MiB_s"), ("min", "min_MiB_s"), ("max", "max_MiB_s")):
            if abs(stats[c][key] - float(r[col])) > 0.0051:
                mism.append(f"{c} {key}: recomputed {stats[c][key]} table {r[col]}")
    if mism:
        sys.exit(f"{s['name']}: recomputed values differ from the config table:\n  " + "\n  ".join(mism))
    return stats, errors


def load_cpu(s):
    """Mean CPU (percent busy) of the load node per configuration."""
    rows = read_tsv(RESULTS / s["sar"])
    cpu = {}
    if s["sar_kind"] == "runs":
        acc = {}
        for r in rows:
            cfg, _, _ = r["run"].rpartition("_r")
            acc.setdefault(cfg, []).append(float(r["cpu_busy"]))
        cpu = {c: sum(v) / len(v) for c, v in acc.items()}
    else:
        for r in rows:
            if r["node"] == LOAD_NODE:
                cpu[r["configuration"]] = float(r["cpu_busy"])
    return cpu


def fmt(x):
    return f"{x:.2f}"


def build():
    verify_inputs(EXPECTED_SHA256)
    data = {}
    for s in SYSTEMS:
        stats, errors = load_system(s)
        cpu = load_cpu(s)
        if set(cpu) != set(stats):
            sys.exit(f"{s['name']}: sar configurations differ from the performance configurations")
        flagged = {c for c, v in cpu.items() if v > CLIENT_LIMIT_CPU}
        data[s["key"]] = dict(sys=s, stats=stats, cpu=cpu, flagged=flagged, errors=errors)
        runs = sum(v["n"] for v in stats.values())
        print(f"{s['name']:10s} {len(stats)} configurations, {runs} recorded runs, error_lines total {errors}, "
              f"recomputed medians equal the config table")
        if s["record_flags"] is not None:
            same = flagged == s["record_flags"]
            print(f"{'':10s} client limited (load node CPU above {CLIENT_LIMIT_CPU:.0f} %): "
                  f"{sorted(flagged) or 'none'}; record states {sorted(s['record_flags']) or 'none'}: "
                  f"{'EQUAL' if same else 'DIFFERENT, check'}")
        else:
            print(f"{'':10s} client limited (load node CPU above {CLIENT_LIMIT_CPU:.0f} %): "
                  f"{sorted(flagged) or 'none'} (the Ceph record does not list them; computed here)")

    outputs = []

    # long table
    long_rows = []
    all_cfgs = [cfg_name(*r) for r in SIZE_ROWS] + [cfg_name(*r) for r in CONC_ROWS if r[2] != 8] + [MIXED]
    for s in SYSTEMS:
        d = data[s["key"]]
        for c in sorted(d["stats"]):
            st = d["stats"][c]
            long_rows.append([s["name"], c, fmt(st["median"]), fmt(st["min"]), fmt(st["max"]), st["n"],
                              f"{d['cpu'][c]:.1f}", "yes" if c in d["flagged"] else "no"])
    p = OUTDIR / "perf_long.csv"
    write_csv(p, ["system", "configuration", "median_MiB_s", "min_MiB_s", "max_MiB_s", "runs",
                  "load_node_cpu_mean_percent", "client_limited"], long_rows)
    outputs.append(p)

    # ranking
    rank_rows = []
    for c in all_cfgs:
        vals = [(data[s["key"]]["stats"][c]["median"], s["name"], s["key"]) for s in SYSTEMS]
        vals.sort(key=lambda t: -t[0])
        best, second = vals[0], vals[1]
        gap = (best[0] / second[0] - 1) * 100
        best_min = data[best[2]]["stats"][c]["min"]
        second_max = data[second[2]]["stats"][c]["max"]
        flagged = [s["name"] for s in SYSTEMS if c in data[s["key"]]["flagged"]]
        rank_rows.append([c, " > ".join(v[1] for v in vals), f"{gap:.1f}",
                          "yes" if best_min > second_max else "no", ", ".join(flagged) or "none"])
    p = OUTDIR / "perf_ranking.csv"
    write_csv(p, ["configuration", "order_by_median", "best_over_second_percent",
                  "ranges_separate", "client_limited_systems"], rank_rows)
    outputs.append(p)

    # wide tables
    def cell(key, c, best_c):
        st = data[key]["stats"][c]
        txt = fmt(st["median"])
        if best_c == key:
            txt = r"\textbf{" + txt + "}"
        if c in data[key]["flagged"]:
            txt += r"$^{\dagger}$"
        return txt

    def best_of(c):
        return max(SYSTEMS, key=lambda s: data[s["key"]]["stats"][c]["median"])["key"]

    def tex_row(label, c):
        b = best_of(c)
        return label + " & " + " & ".join(cell(s["key"], c, b) for s in SYSTEMS) + r" \\"

    head = ["\\begin{tabular}{lrrrr}", "\\toprule",
            "Configuration & " + " & ".join(s["name"] for s in SYSTEMS) + r" \\", "\\midrule"]
    tail = ["\\bottomrule", "\\end{tabular}"]

    lines = list(head)
    for i, op in enumerate(OPS):
        if i:
            lines.append("\\midrule")
        for (o, size, conc) in [r for r in SIZE_ROWS if r[0] == op]:
            lines.append(tex_row(f"{op.upper()} {SIZE_LABEL[size]}", cfg_name(o, size, conc)))
    lines += tail
    p = OUTDIR / "perf_size.tex"
    write_text(p, "\n".join(lines) + "\n")
    outputs.append(p)

    lines = list(head)
    for i, op in enumerate(OPS):
        if i:
            lines.append("\\midrule")
        for (o, size, conc) in [r for r in CONC_ROWS if r[0] == op]:
            lab = f"{op.upper()}, {conc} user" + ("" if conc == 1 else "s")
            lines.append(tex_row(lab, cfg_name(o, size, conc)))
    lines.append("\\midrule")
    lines.append(tex_row("Mixed, 16 users", MIXED))
    lines += tail
    p = OUTDIR / "perf_concurrency.tex"
    write_text(p, "\n".join(lines) + "\n")
    outputs.append(p)

    # load node CPU table (CSV) for the footnote and the limits section
    cpu_rows = []
    for c in all_cfgs:
        cpu_rows.append([c] + [f"{data[s['key']]['cpu'][c]:.1f}" for s in SYSTEMS])
    p = OUTDIR / "perf_load_node_cpu.csv"
    write_csv(p, ["configuration"] + [s["name"] for s in SYSTEMS], cpu_rows)
    outputs.append(p)

    outputs += figures(data)

    inputs = [RESULTS / n for n in EXPECTED_SHA256]
    write_manifest(OUTDIR / "MANIFEST.txt", "Performance comparison: inputs and outputs", inputs, outputs)
    print(f"\nwrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")
    print("legend: bold = highest median in the row; dagger = client limited "
          f"(mean CPU of {LOAD_NODE} above {CLIENT_LIMIT_CPU:.0f} percent in that configuration)")


# ---------------------------------------------------------------- figures
COLOURS = {"ceph": "#0072B2", "seaweedfs": "#E69F00", "rustfs": "#009E73", "garage": "#CC79A7"}
MARKERS = {"ceph": "o", "seaweedfs": "s", "rustfs": "^", "garage": "D"}


def figures(data):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.lines import Line2D
    except ImportError:
        print("matplotlib is not installed: tables written, figures skipped "
              "(install with: sudo apt install python3-matplotlib)")
        return []
    plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
                         "pdf.fonttype": 42, "axes.grid": True, "grid.alpha": 0.25,
                         "grid.linewidth": 0.5})
    outs = []

    def point(ax, x, key, c, **kw):
        st = data[key]["stats"][c]
        flagged = c in data[key]["flagged"]
        col = COLOURS[key]
        ax.errorbar([x], [st["median"]], yerr=[[st["median"] - st["min"]], [st["max"] - st["median"]]],
                    fmt=MARKERS[key], color=col, mfc="white" if flagged else col, ms=6,
                    capsize=2, elinewidth=1, **kw)

    def legend_handles():
        h = [Line2D([], [], marker=MARKERS[s["key"]], color=COLOURS[s["key"]], ls="", label=s["name"])
             for s in SYSTEMS]
        h.append(Line2D([], [], marker="o", color="grey", mfc="white", ls="",
                        label=f"hollow: {LOAD_NODE} CPU above {CLIENT_LIMIT_CPU:.0f} %"))
        return h

    # figure 1: object size, concurrency 8
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=True)
    for ax, op in zip(axes, OPS):
        for i, size in enumerate(SIZES):
            for j, s in enumerate(SYSTEMS):
                point(ax, i + (j - 1.5) * 0.18, s["key"], cfg_name(op, size, 8))
        ax.set_yscale("log")
        ax.set_xticks(range(len(SIZES)))
        ax.set_xticklabels([SIZE_LABEL[x] for x in SIZES])
        ax.set_title(op.upper() + ", 8 users")
        ax.set_xlabel("object size")
    axes[0].set_ylabel("throughput (MiB/s, log scale)")
    fig.legend(handles=legend_handles(), loc="lower center", ncol=5, frameon=False, fontsize=8)
    fig.tight_layout(rect=(0, 0.1, 1, 1))
    outs += save(fig, "perf_size", plt)

    # figure 2: concurrency, 1 MiB
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=False)
    for ax, op in zip(axes, OPS):
        for s in SYSTEMS:
            key = s["key"]
            xs = CONCS
            ys = [data[key]["stats"][cfg_name(op, "1MiB", c)]["median"] for c in xs]
            ax.plot(xs, ys, color=COLOURS[key], lw=1, alpha=0.6)
            for c in xs:
                point(ax, c, key, cfg_name(op, "1MiB", c))
        ax.set_xscale("log", base=2)
        ax.set_xticks(CONCS)
        ax.set_xticklabels([str(c) for c in CONCS])
        ax.set_title(op.upper() + ", 1 MiB objects")
        ax.set_xlabel("concurrent users")
    for ax in axes:
        ax.set_ylabel("throughput (MiB/s)")
    fig.legend(handles=legend_handles(), loc="lower center", ncol=5, frameon=False, fontsize=8)
    fig.tight_layout(rect=(0, 0.1, 1, 1))
    outs += save(fig, "perf_concurrency", plt)

    # figure 3: mixed workload
    fig, ax = plt.subplots(figsize=(3.6, 3.0))
    for j, s in enumerate(SYSTEMS):
        key = s["key"]
        st = data[key]["stats"][MIXED]
        flagged = MIXED in data[key]["flagged"]
        ax.bar(j, st["median"], color="white" if flagged else COLOURS[key], edgecolor=COLOURS[key],
               hatch="///" if flagged else None, width=0.6)
        ax.errorbar([j], [st["median"]], yerr=[[st["median"] - st["min"]], [st["max"] - st["median"]]],
                    color="black", capsize=3, elinewidth=1)
    ax.set_xticks(range(len(SYSTEMS)))
    ax.set_xticklabels([s["name"] for s in SYSTEMS])
    ax.set_ylabel("throughput (MiB/s)")
    ax.set_title("Mixed workload, 1 MiB, 16 users")
    ax.grid(axis="x", visible=False)
    fig.text(0.01, 0.01, f"hatched: {LOAD_NODE} CPU above {CLIENT_LIMIT_CPU:.0f} %", fontsize=7)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    outs += save(fig, "perf_mixed", plt)
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
