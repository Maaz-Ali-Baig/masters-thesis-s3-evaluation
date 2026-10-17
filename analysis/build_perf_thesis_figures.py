#!/usr/bin/env python3
"""Thesis versions of the performance figures and tables (new script, build_perf.py stays unchanged).

It imports build_perf.py as a module, checks the same input files against the same sha256 values,
recomputes the same medians and flags, and draws the same figures. Differences to build_perf.py:
  1. Figure titles and axis labels say "concurrency" instead of "users".
  2. In the two tables, the highest median of a row is printed in bold only if no system in that row
     is flagged (client limited). Flagged values keep their dagger.
Writes to analysis/out/perf_thesis/. It does not write to analysis/out/perf/.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_perf as bp  # noqa: E402
from common import OUT, RESULTS, verify_inputs, write_manifest, write_text  # noqa: E402

OUTDIR = OUT / "perf_thesis"


def load():
    verify_inputs(bp.EXPECTED_SHA256)
    data = {}
    for s in bp.SYSTEMS:
        stats, errors = bp.load_system(s)
        cpu = bp.load_cpu(s)
        if set(cpu) != set(stats):
            sys.exit(f"{s['name']}: sar configurations differ from the performance configurations")
        flagged = {c for c, v in cpu.items() if v > bp.CLIENT_LIMIT_CPU}
        data[s["key"]] = dict(sys=s, stats=stats, cpu=cpu, flagged=flagged, errors=errors)
    return data


def tables(data):
    outs = []

    def row_flagged(c):
        return any(c in data[s["key"]]["flagged"] for s in bp.SYSTEMS)

    def cell(key, c, best_key):
        txt = bp.fmt(data[key]["stats"][c]["median"])
        if best_key == key and not row_flagged(c):
            txt = r"\textbf{" + txt + "}"
        if c in data[key]["flagged"]:
            txt += r"$^{\dagger}$"
        return txt

    def best_of(c):
        return max(bp.SYSTEMS, key=lambda s: data[s["key"]]["stats"][c]["median"])["key"]

    def tex_row(label, c):
        b = best_of(c)
        return label + " & " + " & ".join(cell(s["key"], c, b) for s in bp.SYSTEMS) + r" \\"

    head = ["\\begin{tabular}{lrrrr}", "\\toprule",
            "Configuration & " + " & ".join(s["name"] for s in bp.SYSTEMS) + r" \\", "\\midrule"]
    tail = ["\\bottomrule", "\\end{tabular}"]

    lines = list(head)
    for i, op in enumerate(bp.OPS):
        if i:
            lines.append("\\midrule")
        for (o, size, conc) in [r for r in bp.SIZE_ROWS if r[0] == op]:
            lines.append(tex_row(f"{op.upper()} {bp.SIZE_LABEL[size]}", bp.cfg_name(o, size, conc)))
    lines += tail
    p = OUTDIR / "perf_size.tex"
    write_text(p, "\n".join(lines) + "\n")
    outs.append(p)

    lines = list(head)
    for i, op in enumerate(bp.OPS):
        if i:
            lines.append("\\midrule")
        for (o, size, conc) in [r for r in bp.CONC_ROWS if r[0] == op]:
            lines.append(tex_row(f"{op.upper()}, concurrency {conc}", bp.cfg_name(o, size, conc)))
    lines.append("\\midrule")
    lines.append(tex_row("Mixed, concurrency 16", bp.MIXED))
    lines += tail
    p = OUTDIR / "perf_concurrency.tex"
    write_text(p, "\n".join(lines) + "\n")
    outs.append(p)
    return outs


def figures(data):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D

    plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
                         "pdf.fonttype": 42, "axes.grid": True, "grid.alpha": 0.25,
                         "grid.linewidth": 0.5})
    outs = []

    def point(ax, x, key, c, **kw):
        st = data[key]["stats"][c]
        flagged = c in data[key]["flagged"]
        col = bp.COLOURS[key]
        ax.errorbar([x], [st["median"]], yerr=[[st["median"] - st["min"]], [st["max"] - st["median"]]],
                    fmt=bp.MARKERS[key], color=col, mfc="white" if flagged else col, ms=6,
                    capsize=2, elinewidth=1, **kw)

    def legend_handles():
        h = [Line2D([], [], marker=bp.MARKERS[s["key"]], color=bp.COLOURS[s["key"]], ls="", label=s["name"])
             for s in bp.SYSTEMS]
        h.append(Line2D([], [], marker="o", color="grey", mfc="white", ls="",
                        label=f"hollow: {bp.LOAD_NODE} CPU above {bp.CLIENT_LIMIT_CPU:.0f} %"))
        return h

    def save(fig, name):
        OUTDIR.mkdir(parents=True, exist_ok=True)
        paths = []
        for ext in ("pdf", "png"):
            p = OUTDIR / f"{name}.{ext}"
            kw = {"metadata": {"CreationDate": None}} if ext == "pdf" else {"dpi": 200}
            fig.savefig(p, **kw)
            paths.append(p)
        plt.close(fig)
        return paths

    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=True)
    for ax, op in zip(axes, bp.OPS):
        for i, size in enumerate(bp.SIZES):
            for j, s in enumerate(bp.SYSTEMS):
                point(ax, i + (j - 1.5) * 0.18, s["key"], bp.cfg_name(op, size, 8))
        ax.set_yscale("log")
        ax.set_xticks(range(len(bp.SIZES)))
        ax.set_xticklabels([bp.SIZE_LABEL[x] for x in bp.SIZES])
        ax.set_title(op.upper() + ", concurrency: 8")
        ax.set_xlabel("object size")
    axes[0].set_ylabel("throughput (MiB/s, log scale)")
    fig.legend(handles=legend_handles(), loc="lower center", ncol=5, frameon=False, fontsize=8)
    fig.tight_layout(rect=(0, 0.1, 1, 1))
    outs += save(fig, "perf_size")

    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=False)
    for ax, op in zip(axes, bp.OPS):
        for s in bp.SYSTEMS:
            key = s["key"]
            xs = bp.CONCS
            ys = [data[key]["stats"][bp.cfg_name(op, "1MiB", c)]["median"] for c in xs]
            ax.plot(xs, ys, color=bp.COLOURS[key], lw=1, alpha=0.6)
            for c in xs:
                point(ax, c, key, bp.cfg_name(op, "1MiB", c))
        ax.set_xscale("log", base=2)
        ax.set_xticks(bp.CONCS)
        ax.set_xticklabels([str(c) for c in bp.CONCS])
        ax.set_title(op.upper() + ", 1 MiB objects")
        ax.set_xlabel("concurrency")
    for ax in axes:
        ax.set_ylabel("throughput (MiB/s)")
    fig.legend(handles=legend_handles(), loc="lower center", ncol=5, frameon=False, fontsize=8)
    fig.tight_layout(rect=(0, 0.1, 1, 1))
    outs += save(fig, "perf_concurrency")

    fig, ax = plt.subplots(figsize=(3.6, 3.0))
    for j, s in enumerate(bp.SYSTEMS):
        key = s["key"]
        st = data[key]["stats"][bp.MIXED]
        flagged = bp.MIXED in data[key]["flagged"]
        ax.bar(j, st["median"], color="white" if flagged else bp.COLOURS[key], edgecolor=bp.COLOURS[key],
               hatch="///" if flagged else None, width=0.6)
        ax.errorbar([j], [st["median"]], yerr=[[st["median"] - st["min"]], [st["max"] - st["median"]]],
                    color="black", capsize=3, elinewidth=1)
    ax.set_xticks(range(len(bp.SYSTEMS)))
    ax.set_xticklabels([s["name"] for s in bp.SYSTEMS])
    ax.set_ylabel("throughput (MiB/s)")
    ax.set_title("Mixed workload, 1 MiB, concurrency: 16")
    ax.grid(axis="x", visible=False)
    fig.text(0.01, 0.01, f"hatched: {bp.LOAD_NODE} CPU above {bp.CLIENT_LIMIT_CPU:.0f} %", fontsize=7)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    outs += save(fig, "perf_mixed")
    return outs


def main():
    data = load()
    outputs = tables(data) + figures(data)
    inputs = [RESULTS / n for n in bp.EXPECTED_SHA256]
    write_manifest(OUTDIR / "MANIFEST.txt", "Thesis versions of the performance figures and tables",
                   inputs, outputs)
    print(f"wrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")


if __name__ == "__main__":
    main()
