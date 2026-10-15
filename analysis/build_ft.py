#!/usr/bin/env python3
"""Fault tolerance runs S1 and S2 of the four systems on the VMs: tables and figures.

Run from anywhere:   python3 analysis/build_ft.py
Reads only the run archives results/ft-*.tar.gz (made by scripts/ft.sh on ceph0) and writes to analysis/out/ft/.

Definitions (all computed from the raw files of the archives, none typed from the records)
  t0            the moment ft.sh saw every target silent (line "all targets silent at" in console.txt).
  ack type      "ETag" if the ledger rows of acknowledged writes carry an ETag (aws s3api put-object, Ceph runs),
                "cp exit code" otherwise (aws s3 cp, exit code 0, all runs of Garage, RustFS and SeaweedFS).
                An acknowledgement of "aws s3 cp" after a stall of about 25 s can be false (results/garage-vm-fault-tolerance-S1-2026-10-14.txt),
                so for these runs "acknowledged" counts and gaps are not comparable with the ETag runs: a gap is a lower bound.
  round         one pass of the probe loop of ft.sh (index in the ledger). A round tries the endpoints in rotation until one acknowledges.
                hard failed round = no attempt of the round was acknowledged. masked failure = a failed attempt whose round was acknowledged
                by the next endpoint.
  ledger time   the time at which an attempt ENDED (ft.sh writes the row after the aws call). probe time: the time at which the probe ended.
  gap           time between two successful operations (ledger ACK rows, or probe READ_OK rows of one endpoint). The client read time out is 25 s,
                so a request that hangs is seen as failed 25 s later: a gap of about 25 s means "hung until the time out".
  tail          a run can end without a further acknowledgement; the interval from the last ACK to the last ledger row is then reported too.
Cross checks: the numbers of summary.txt (acknowledged, failed, longest gap) must equal the recomputed ones, or the script stops.
"""
import csv
import io
import re
import sys
import tarfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, RESULTS, ROOT, verify_inputs, write_csv, write_manifest, write_text  # noqa: E402

OUTDIR = OUT / "ft"
INVENTORY = RESULTS / "vm-archives-ceph0-SHA256SUMS.txt"
READ_TIMEOUT = 25.0          # --cli-read-timeout of ft.sh
GAP_MIN = 8.0                # probe rows come about every 2 s; a longer silence between two OK rows is a gap
SYSTEM_NAME = {"ceph": "Ceph", "seaweedfs": "SeaweedFS", "rustfs": "RustFS", "garage": "Garage"}
SYSTEM_ORDER = ["ceph", "seaweedfs", "rustfs", "garage"]
NODE = {"192.168.1.72": "ceph0", "192.168.1.71": "ceph1", "192.168.1.70": "ceph2"}

# Facts about single runs that cannot be derived from the archive. Each one is taken from the record named in the last field
# (read on 15 October 2026); runs without an entry have nothing recorded.
RUN_NOTES = {
    "ft-ceph-S1-20261015-141623": ("run A", "results/ceph-vm-fault-tolerance-S1-2026-10-15.txt"),
    "ft-ceph-S1-20261015-144339": ("run B; ft-ackcheck.sh (three clients) wrote in parallel for 600 s from the stop signal", "results/ceph-vm-fault-tolerance-S1-2026-10-15.txt"),
    "ft-ceph-S2-20261015-154345": ("stop 5 min after the signal; outage 9 to 10 min instead of 6 (read back blocked the power on prompt); user powered on by hand", "results/ceph-vm-fault-tolerance-S2-2026-10-15.txt"),
    "ft-garage-S1-20261014-083928": ("run 1; long outage, recovery watch aborted", "results/garage-vm-fault-tolerance-S1-2026-10-14.txt"),
    "ft-garage-S1-20261014-104306": ("run 2; ft-diag.sh (80 curl writes, 5 s apart) in parallel", "results/garage-vm-fault-tolerance-S1-2026-10-14.txt"),
    "ft-garage-S1-20261014-184630": ("run 3; ft-ackcheck.sh (three clients) wrote in parallel for 600 s", "results/garage-vm-fault-tolerance-S1-2026-10-14.txt"),
    "ft-garage-S2-20261014-121535": ("outage about 29 min instead of 6; recovery by hand; ft-diag.sh in parallel (6 and 4 writes)", "results/garage-vm-fault-tolerance-S2-2026-10-14.txt"),
    "ft-rustfs-S1-20261011-145627": ("probe keys restart at 1 in every run (no key prefix): read back valid, repair evidence not", "results/rustfs-vm-fault-tolerance-S1-2026-10-11.txt"),
    "ft-rustfs-S1-20261012-204542": ("repeat with a key prefix of its own and repair watch", "results/rustfs-vm-fault-tolerance-S1-repeat-2026-10-12.txt"),
    "ft-rustfs-S2-20261011-161345": ("probe keys restart at 1 in every run (older ft.sh)", "results/rustfs-vm-fault-tolerance-S2-2026-10-11.txt"),
    "ft-seaweedfs-S1-20261013-093344": ("user stopped the VM 1107 s after the signal; baseline and outage are counted from the silence", "results/seaweedfs-vm-fault-tolerance-S1-2026-10-13.txt"),
    "ft-seaweedfs-S1-20261013-133927": ("ft-diag.sh (curl writes through ceph0 and ceph2) in parallel from 13:46:21", "results/seaweedfs-vm-fault-tolerance-S1-repeat-2026-10-13.txt"),
    "ft-seaweedfs-S2-20261013-113256": ("outage about 13 min instead of 6", "results/seaweedfs-vm-fault-tolerance-S2-2026-10-13.txt"),
}

MEMBERS = ["ledger.tsv", "probe.tsv", "console.txt", "summary.txt", "verify.tsv", "verify-during-outage.tsv"]


# ------------------------------------------------------------------ reading
def read_archive(path):
    out = {}
    with tarfile.open(path, "r:gz") as tf:
        for m in tf.getmembers():
            base = m.name.split("/", 1)[-1]
            if m.isfile() and base in MEMBERS:
                out[base] = tf.extractfile(m).read().decode("utf-8", errors="replace")
    missing = [m for m in MEMBERS if m not in out]
    if missing:
        sys.exit(f"{path.name}: members missing {missing}")
    return out


def tsv(text, header=True, names=None):
    rows = list(csv.reader(io.StringIO(text), delimiter="\t"))
    if header:
        names = rows[0]
        rows = rows[1:]
    return [dict(zip(names, r)) for r in rows if r]


class Clock:
    """Converts HH:MM:SS of console.txt (VM clock, written with its UTC offset in the header) to epoch seconds."""

    def __init__(self, date_s, time_s, off):
        sign = 1 if off[0] == "+" else -1
        self.tz = timezone(sign * timedelta(hours=int(off[1:3]), minutes=int(off[3:5])))
        self.last = datetime.strptime(f"{date_s} {time_s}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=self.tz)

    def at(self, hhmmss):
        t = datetime.strptime(f"{self.last.date()} {hhmmss}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=self.tz)
        if t < self.last - timedelta(minutes=5):  # midnight passed
            t += timedelta(days=1)
        self.last = max(self.last, t)
        return t.timestamp()


def parse_console(text):
    h = re.search(r"host: (\S+)\s+system: (\S+)\s+scenario: (\S+)\s+time: (\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) ([+-]\d{4})", text)
    p = re.search(r"targets: ([\d. ]+?)\s+baseline: (\d+) s\s+outage: (\d+) s", text)
    clock = Clock(h.group(4), h.group(5), h.group(6))
    ev = {"ssh": {}, "start": {}}
    for line in text.splitlines():
        m = re.match(r"== ACTION NOW: hard stop .*\[(\d\d:\d\d:\d\d)\]", line)
        if m:
            ev["stop_signal"] = clock.at(m.group(1))
        m = re.match(r"== all targets silent at (\d\d:\d\d:\d\d) \(waited (\d+) s", line)
        if m:
            ev["silent"] = clock.at(m.group(1))
            ev["waited"] = int(m.group(2))
        m = re.match(r"== ACTION NOW: power on .*\[(\d\d:\d\d:\d\d)\]", line)
        if m:
            ev["power_signal"] = clock.at(m.group(1))
        m = re.match(r"== ssh answers on (\S+) at (\d\d:\d\d:\d\d)", line)
        if m:
            ev["ssh"][m.group(1)] = clock.at(m.group(2))
        m = re.match(r"== start command finished on (\S+) at (\d\d:\d\d:\d\d)", line)
        if m:
            ev["start"][m.group(1)] = clock.at(m.group(2))
    if "silent" not in ev:
        sys.exit("console.txt without 'all targets silent'")
    return dict(system=h.group(2), scenario=h.group(3), targets=p.group(1).split(),
                baseline=int(p.group(2)), planned_outage=int(p.group(3)), ev=ev)


def parse_summary(text):
    a = re.search(r"acknowledged writes (\d+), failed attempts (\d+)", text)
    g = re.search(r"longest gap between acknowledged writes ([\d.]+) s", text)
    return int(a.group(1)), int(a.group(2)), float(g.group(1))


# ------------------------------------------------------------------ analysis of one run
def analyse(name, parts):
    con = parse_console(parts["console.txt"])
    ev = con["ev"]
    t0 = ev["silent"]
    led = tsv(parts["ledger.tsv"])
    for r in led:
        r["t"] = float(r["epoch"])
        r["i"] = int(r["index"])
    probe = tsv(parts["probe.tsv"])
    for r in probe:
        r["t"] = float(r["epoch"])

    ack_type = "ETag" if any(r["result"] == "ACK" and r["error"].startswith("etag:") for r in led) else "cp exit code"

    # --- writes
    rounds = {}
    for r in led:
        rounds.setdefault(r["i"], []).append(r)
    hard = sorted(i for i, rs in rounds.items() if not any(x["result"] == "ACK" for x in rs))
    masked = sum(1 for i, rs in rounds.items() if any(x["result"] == "ACK" for x in rs) and any(x["result"] == "FAIL" for x in rs))
    acks = [r["t"] for r in led if r["result"] == "ACK"]
    n_ack = len(acks)
    n_fail = sum(1 for r in led if r["result"] == "FAIL")
    gaps = [(b - a, a) for a, b in zip(acks, acks[1:])]
    gap, gap_at = max(gaps)
    s_ack, s_fail, s_gap = parse_summary(parts["summary.txt"])
    if (n_ack, n_fail) != (s_ack, s_fail) or abs(gap - s_gap) > 0.06:
        sys.exit(f"{name}: recomputed ({n_ack}, {n_fail}, {gap:.1f}) differs from summary.txt ({s_ack}, {s_fail}, {s_gap})")
    tail = led[-1]["t"] - acks[-1]
    interval = max(gap, tail)
    interval_at = gap_at if gap >= tail else acks[-1]
    hard_t = [rounds[i][-1]["t"] for i in hard]

    # --- probe (reads of the fixed object), per endpoint
    by_ep = {}
    for r in probe:
        by_ep.setdefault(r["endpoint"], []).append(r)
    targets = {e for e in by_ep if e.split(":")[0] in con["targets"]}
    ep_info = {}
    for ep, rows in by_ep.items():
        rows.sort(key=lambda r: r["t"])
        oks = [r["t"] for r in rows if r["head_object"] == "READ_OK"]
        g = [(b - a, a, b) for a, b in zip(oks, oks[1:]) if b - a > GAP_MIN]
        if oks and rows[-1]["t"] - oks[-1] > GAP_MIN:  # no OK row until the end of the probe: the endpoint did not come back in the run
            g.append((rows[-1]["t"] - oks[-1], oks[-1], None))
        big = max(g, key=lambda x: x[0]) if g else (0.0, None, None)
        silent = [r["t"] for r in rows if r["live_code"] == "000"]
        fails = sum(1 for r in rows if r["head_object"] == "READ_FAIL")
        ep_info[ep] = dict(gap=big[0], gap_start=big[1], gap_end=big[2], fails=fails,
                           silent_first=min(silent) if silent else None)
    surv = {e: v for e, v in ep_info.items() if e not in targets}
    targ = {e: v for e, v in ep_info.items() if e in targets}
    s_ep = max(surv, key=lambda e: surv[e]["gap"])
    ends = [v["gap_end"] for v in targ.values()]
    t_back = None if (not ends or any(e is None for e in ends)) else max(ends)
    first_ssh = min(ev["ssh"].values()) if ev["ssh"] else None
    last_ssh = max(ev["ssh"].values()) if ev["ssh"] else None

    rel = lambda t: None if t is None else round(t - t0, 1)  # noqa: E731

    # --- read back
    is_seed = lambda k: k.startswith("seed/") or k.startswith("fixed/")  # noqa: E731
    ver = tsv(parts["verify.tsv"], header=False, names=["endpoint", "key", "expected", "got", "status"])
    per_ep = {}
    bad_keys = {}
    for r in ver:
        per_ep.setdefault(r["endpoint"], []).append(r["status"])
        if r["status"] != "OK":
            bad_keys.setdefault(r["key"], set()).add(r["endpoint"])
    n_obj = len({r["key"] for r in ver})
    by_key = {}
    for r in ver:
        by_key.setdefault(r["key"], []).append(r["status"])
    ok_idx = {int(k.rsplit("/", 1)[1]) for k, st in by_key.items() if not is_seed(k) and all(x == "OK" for x in st)}
    conf = sorted(r["t"] for r in led if r["result"] == "ACK" and r["i"] in ok_idx)
    unconf = sorted(r["t"] for r in led if r["result"] == "ACK" and r["i"] not in ok_idx)
    cgaps = [(b - a, a) for a, b in zip(conf, conf[1:])]
    cgap, cgap_at = max(cgaps)
    ctail = led[-1]["t"] - conf[-1]
    do = tsv(parts["verify-during-outage.tsv"], header=False, names=["endpoint", "key", "expected", "got", "status"])
    do_bad = [r for r in do if r["status"] != "OK"]

    return dict(
        run=name, system=con["system"], scenario=con["scenario"], ack_type=ack_type,
        note=RUN_NOTES.get(name, ("", ""))[0],
        planned_outage_s=con["planned_outage"], signal_to_silence_s=ev.get("waited"),
        ssh_first_rel=rel(first_ssh), ssh_last_rel=rel(last_ssh),
        targets_back_rel=rel(t_back),
        target_gap_s=round(max(v["gap"] for v in targ.values()), 1),
        survivor_read_gap_s=round(surv[s_ep]["gap"], 1), survivor_read_gap_censored=surv[s_ep]["gap_end"] is None,
        survivor_gap_node=NODE.get(s_ep.split(":")[0], s_ep),
        survivor_gap_start_rel=rel(surv[s_ep]["gap_start"]),
        rounds=len(rounds), acked=n_ack, failed_attempts=n_fail, hard_failed_rounds=len(hard), masked_failures=masked,
        hard_first_rel=rel(hard_t[0]) if hard_t else None, hard_last_rel=rel(hard_t[-1]) if hard_t else None,
        longest_ack_gap_s=round(gap, 1), ack_gap_start_rel=rel(gap_at),
        no_ack_interval_incl_tail_s=round(interval, 1), no_ack_start_rel=rel(interval_at), ends_without_ack=bool(tail > gap),
        confirmed_acks=len(conf), unconfirmed_acks=n_ack - len(conf),
        confirmed_interval_s=round(max(cgap, ctail), 1), confirmed_interval_start_rel=rel(cgap_at if cgap >= ctail else conf[-1]),
        confirmed_interval_censored=bool(ctail > cgap),
        read_back_objects=n_obj, read_back_ok_per_endpoint="/".join(str(sum(1 for s in v if s == "OK")) for _, v in sorted(per_ep.items())),
        not_readable_any_endpoint=len(bad_keys),
        not_readable_acked=sum(1 for k in bad_keys if not is_seed(k)), not_readable_seed=sum(1 for k in bad_keys if is_seed(k)),
        outage_read_objects=len(do), outage_read_not_ok=len(do_bad),
        outage_read_not_ok_seed=sum(1 for r in do_bad if is_seed(r["key"])),
        _unconf=unconf, _led=led, _probe=probe, _t0=t0, _ev=ev, _targets=targets, _rounds=rounds, _hard=hard,
    )


# ------------------------------------------------------------------ outputs
def build():
    inv = {}
    for line in INVENTORY.read_text().splitlines():
        h, f = line.split()
        inv[f] = h
    wanted = {f: h for f, h in inv.items() if f.startswith("ft-")}
    verify_inputs(wanted)
    runs = []
    for f in sorted(wanted):
        name = f[: -len(".tar.gz")]
        r = analyse(name, read_archive(RESULTS / f))
        runs.append(r)
        print(f"{name}: ack type {r['ack_type']}, acked {r['acked']}, failed {r['failed_attempts']} "
              f"(hard failed rounds {r['hard_failed_rounds']}), summary.txt equal")
    order = lambda r: (SYSTEM_ORDER.index(r["system"]), r["scenario"], r["run"])  # noqa: E731
    runs.sort(key=order)

    outputs = []
    pub = [k for k in runs[0] if not k.startswith("_")]
    p = OUTDIR / "ft_runs.csv"
    write_csv(p, pub, [[r[k] for k in pub] for r in runs])
    outputs.append(p)

    def num(x, censored=False):
        if x is None or x == "":
            return "n/a"
        return ("$\\geq$" if censored else "") + f"{x:.0f}"

    for sc, fname in (("S1", "ft_s1.tex"), ("S2", "ft_s2.tex")):
        extra = " & Outage reads not OK" if sc == "S2" else ""
        lines = ["\\begin{tabular}{llrrrrrr" + ("r" if sc == "S2" else "") + "}", "\\toprule",
                 "System & Ack & Outage (s) & Read gap (s) & Write gap (s) & Hard failed rounds & Acked, not readable & Back (s)" + extra + " \\\\", "\\midrule"]
        prev = None
        for r in [x for x in runs if x["scenario"] == sc]:
            if prev and prev != r["system"]:
                lines.append("\\midrule")
            prev = r["system"]
            ack = "ETag" if r["ack_type"] == "ETag" else "cp$^{*}$"
            back_missing = r["targets_back_rel"] is None
            tail = f" & {r['outage_read_not_ok']}/{r['outage_read_objects']}" if sc == "S2" else ""
            lines.append(f"{SYSTEM_NAME[r['system']]} {r['run'][-6:]} & {ack} & {num(r['target_gap_s'], back_missing)} & "
                         f"{num(r['survivor_read_gap_s'], r['survivor_read_gap_censored'])} & {num(r['confirmed_interval_s'], r['confirmed_interval_censored'])}"
                         f" & {r['hard_failed_rounds']} & {r['unconfirmed_acks']} & {num(r['targets_back_rel'])}{tail} \\\\")
        lines += ["\\bottomrule", "\\end{tabular}"]
        p2 = OUTDIR / fname
        write_text(p2, "\n".join(lines) + "\n")
        outputs.append(p2)

    outputs += figures(runs)
    inputs = [RESULTS / f for f in sorted(wanted)] + [INVENTORY]
    write_manifest(OUTDIR / "MANIFEST.txt", "Fault tolerance runs: inputs and outputs", inputs, outputs)
    print(f"\nwrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")
    print("cp* in the tables: acknowledgement = exit code of aws s3 cp (can be false after a stall of about 25 s). Write gap counts only acknowledged writes that are readable after the recovery.")


COL = {"ack": "#009E73", "fail": "#D55E00", "ok": "#999999", "silent": "#000000", "unconf": "#CC79A7"}


def figures(runs):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib is not installed: tables written, figures skipped (sudo apt install python3-matplotlib)")
        return []
    plt.rcParams.update({"font.size": 8, "axes.spines.top": False, "axes.spines.right": False, "pdf.fonttype": 42})
    outs = []
    for system in SYSTEM_ORDER:
        rs = [r for r in runs if r["system"] == system]
        fig, axes = plt.subplots(len(rs), 1, figsize=(7.2, 1.9 * len(rs) + 0.5), squeeze=False)
        for ax, r in zip(axes[:, 0], rs):
            t0 = r["_t0"]
            led, probe = r["_led"], r["_probe"]
            unc = set(r["_unconf"])
            conf_x = [x["t"] - t0 for x in led if x["result"] == "ACK" and x["t"] not in unc]
            ax.scatter(conf_x, [4] * len(conf_x), marker="|", s=14, c=COL["ack"], linewidths=0.6)
            ax.scatter([t - t0 for t in r["_unconf"]], [4] * len(r["_unconf"]), marker="|", s=55, c=COL["unconf"], linewidths=1.2)
            ax.scatter([x["t"] - t0 for x in led if x["result"] == "FAIL"], [4] * sum(1 for x in led if x["result"] == "FAIL"),
                       marker="|", s=40, c=COL["fail"], linewidths=0.9)
            eps = sorted({x["endpoint"] for x in probe})
            for k, ep in enumerate(eps):
                rows = [x for x in probe if x["endpoint"] == ep]
                y = 3 - k
                for status, sel, col in (("ok", lambda x: x["head_object"] == "READ_OK", COL["ok"]),
                                         ("fail", lambda x: x["head_object"] == "READ_FAIL" and x["live_code"] != "000", COL["fail"]),
                                         ("silent", lambda x: x["head_object"] == "READ_FAIL" and x["live_code"] == "000", COL["silent"])):
                    xs = [x["t"] - t0 for x in rows if sel(x)]
                    ax.scatter(xs, [y] * len(xs), marker="|", s=14, c=col, linewidths=0.6)
            ax.set_yticks([4, 3, 2, 1])
            ax.set_yticklabels(["writes"] + [NODE.get(e.split(":")[0], e) for e in eps])
            ax.axvline(0, color="k", lw=0.6, ls="--")
            for t in r["_ev"]["ssh"].values():
                ax.axvline(t - t0, color="#0072B2", lw=0.6, ls=":")
            hi = max((r["targets_back_rel"] or 0), (r["ssh_last_rel"] or 0)) or (led[-1]["t"] - t0)  # node never seen back: show the whole run
            ax.set_xlim(-150, min(hi + 240, led[-1]["t"] - t0 + 20))
            ax.set_ylim(0.4, 4.6)
            ax.grid(axis="x", alpha=0.2)
            ax.set_title(f"{SYSTEM_NAME[system]} {r['scenario']} {r['run'].split('-')[-2]} {r['run'].split('-')[-1]}   (acknowledgement: {r['ack_type']})",
                         fontsize=8, loc="left")
        axes[-1, 0].set_xlabel("seconds from the moment ft.sh saw the stopped node(s) silent (dashed); dotted: ssh answers after power on")
        fig.text(0.01, 0.022, "writes row: green = acknowledged and readable after the recovery, purple = acknowledged but NOT readable afterwards, red = failed attempt.", fontsize=6.3)
        fig.text(0.01, 0.004, "read rows (fixed object, per endpoint): grey = read ok, red = failed read, black = no HTTP answer.", fontsize=6.3)
        fig.tight_layout(rect=(0, 0.04, 1, 1))
        outs += save(fig, f"ft_timeline_{system}", plt)

    # gap figure: longest interval without a CONFIRMED write (acknowledged and readable after recovery)
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.1))
    for ax, sc in ((axes[0], "S1"), (axes[1], "S2")):
        x = 0
        ticks, labels = [], []
        for system in SYSTEM_ORDER:
            for r in [q for q in runs if q["system"] == system and q["scenario"] == sc]:
                etag = r["ack_type"] == "ETag"
                ax.bar(x, r["confirmed_interval_s"], color="#0072B2" if etag else "white", edgecolor="#0072B2", hatch=None if etag else "///")
                if r["confirmed_interval_censored"]:
                    ax.plot([x], [r["confirmed_interval_s"]], marker="^", color="#D55E00", ms=5)
                ref = r["survivor_read_gap_s"] if sc == "S1" else r["target_gap_s"]
                ax.plot([x], [ref], marker="_", color="k", ms=9, mew=1.4)
                ticks.append(x)
                labels.append(f"{SYSTEM_NAME[system]}\n{r['run'].split('-')[-1][:4]}")
                x += 1
            x += 0.6
        ax.set_xticks(ticks)
        ax.set_xticklabels(labels, fontsize=5.5, rotation=90)
        ax.set_title(f"{sc}: longest interval without a confirmed write", fontsize=7.5)
        ax.set_ylabel("seconds")
        if sc == "S1":
            ax.axhline(READ_TIMEOUT, color="#D55E00", lw=0.8, ls="--")
            ax.text(0.99, READ_TIMEOUT + 12, "client read time out 25 s", fontsize=6, color="#D55E00", ha="right", transform=ax.get_yaxis_transform())
    fig.text(0.01, 0.045, "confirmed write = acknowledged and readable on all three endpoints after the recovery. filled bar: ETag acknowledgement; hatched: aws s3 cp exit code.", fontsize=5.8)
    fig.text(0.01, 0.026, "black tick: S1 longest read gap of the fixed object at a surviving endpoint; S2 observed outage of the stopped endpoint.", fontsize=5.8)
    fig.text(0.01, 0.007, "red triangle: no later confirmed write before the end of the run, so the value is a lower bound.", fontsize=5.8)
    fig.tight_layout(rect=(0, 0.1, 1, 1))
    outs += save(fig, "ft_gaps", plt)
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
