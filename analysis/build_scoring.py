#!/usr/bin/env python3
"""Scoring matrix of the four systems, implemented exactly as written in scoring_method.md (revision 2).

Run from anywhere:   python3 analysis/build_scoring.py
Reads only generated outputs of the other scripts (analysis/out/perf, compat, security, ft) and scoring_method.md. Writes to analysis/out/scoring/.

Order of work (nothing is scored before the first three steps are printed):
1. check inputs and print the configurations excluded as client limited (4.1) and the gate result per system (3);
2. dimension scores (section 4), profile scores (section 5);
3. variants (section 6): weights, scoring variants crossed with weights, tie margins; leave one out as diagnostics;
4. robust winner rule (6.5) per profile.
Every rule is in scoring_method.md; a rule is not changed here without an entry in section 9 of that file.
"""
import csv
import itertools
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, ROOT, write_csv, write_manifest, write_text  # noqa: E402

OUTDIR = OUT / "scoring"
SYS = ["ceph", "seaweedfs", "rustfs", "garage"]
NAME = {"ceph": "Ceph", "seaweedfs": "SeaweedFS", "rustfs": "RustFS", "garage": "Garage"}
PLATEAU = 32.0
MARGIN = 0.05
DIMS = ["performance", "compatibility", "security", "fault tolerance"]

# profile: gate, weights (performance, compatibility, security, fault tolerance), weight of GET inside performance
PROFILES = {
    "P0 equal weights": dict(gate=False, w=(0.25, 0.25, 0.25, 0.25), wget=0.5),
    "P1 S3 compatibility priority": dict(gate=True, w=(0.15, 0.50, 0.15, 0.20), wget=0.5),
    "P2 read heavy throughput": dict(gate=False, w=(0.55, 0.15, 0.10, 0.20), wget=0.8),
    "P3 availability on a small cluster": dict(gate=False, w=(0.15, 0.15, 0.10, 0.60), wget=0.5),
}
FEATURES = ["C09", "C10", "C14", "C15", "C16", "C17", "C18", "C19"]
GROUPS = {"C01 to C08": [f"C{i:02d}" for i in range(1, 9)], "C09, C10, C14 to C17": ["C09", "C10", "C14", "C15", "C16", "C17"],
          "C11 to C13": ["C11", "C12", "C13"], "C18 to C20": ["C18", "C19", "C20"], "C21, C22": ["C21", "C22"]}
GATE_SUBCHECKS = {"C08": ["initiate", "upload_parts", "complete", "assembled_bytes_identical", "abort"], "C13": ["fetch_ok"]}
SEC_ROWS_EXPECTED = ["r1", "r2", "r3", "r7", "r8", "r9", "r12"]

# scoring variants of 6.2: name -> overrides of the base rules
VARIANTS = {
    "a rank points": dict(rank=True),
    "b compatibility without C18": dict(no_c18=True),
    "c RustFS without SSE-S3 key": dict(rf_default=True),
    "d plateau 25 s": dict(plateau=25.0),
    "d plateau 45 s": dict(plateau=45.0),
    "e margin 0.03": dict(margin=0.03),
    "e margin 0.10": dict(margin=0.10),
}


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def tex(s):
    m = {"\\": "\\textbackslash{}", "&": "\\&", "%": "\\%", "$": "\\$", "#": "\\#", "_": "\\_", "{": "\\{", "}": "\\}"}
    return "".join(m.get(ch, ch) for ch in s)


def rank_points(values, higher_is_better):
    """4 points for the best of four, 1 for the worst, mean points for equal values (scoring_method.md 6.2a). Returns {key: s_rank in 0..1}."""
    keys = sorted(values, key=lambda k: values[k], reverse=higher_is_better)
    pos = {}
    i = 0
    while i < len(keys):
        j = i
        while j + 1 < len(keys) and values[keys[j + 1]] == values[keys[i]]:
            j += 1
        mean_pos = (i + j) / 2
        for k in keys[i:j + 1]:
            pos[k] = mean_pos
        i = j + 1
    return {k: ((4 - pos[k]) - 1) / 3 for k in values}


# ------------------------------------------------------------------ inputs
perf = read_csv(OUT / "perf" / "perf_long.csv")
compat = read_csv(OUT / "compat" / "compat_cells.csv")
sec = read_csv(OUT / "security" / "security_cells.csv")
ft = read_csv(OUT / "ft" / "ft_runs.csv")
METHOD = ROOT / "scoring_method.md"
INPUTS = [OUT / "perf" / "perf_long.csv", OUT / "compat" / "compat_cells.csv", OUT / "security" / "security_cells.csv", OUT / "ft" / "ft_runs.csv", METHOD]
for p in INPUTS:
    if not p.exists():
        sys.exit(f"missing input {p}")
if "confirmed_in_outage_after_60s" not in ft[0] or "ok_sub_checks" not in compat[0]:
    sys.exit("ft_runs.csv or compat_cells.csv is from an older version of its script: rerun build_ft.py and build_compat.py")

# performance: configurations and exclusion (4.1.1)
mp = {(r["system"].lower(), r["configuration"]): float(r["median_MiB_s"]) for r in perf}
cl = {(r["system"].lower(), r["configuration"]): r["client_limited"] for r in perf}
CFGS = sorted({c for _, c in mp})
if any(len([s for s in SYS if (s, c) in mp]) != 4 for c in CFGS):
    sys.exit("performance table incomplete")
EXCLUDED = [c for c in CFGS if any(cl[(s, c)] == "yes" for s in SYS)]
INCLUDED = [c for c in CFGS if c not in EXCLUDED]
for c in INCLUDED:
    if not (c.startswith("put_") or c.startswith("get_")):
        sys.exit(f"included configuration {c} is neither PUT nor GET: scoring_method.md has no family for it")
FAM = {c: ("PUT" if c.startswith("put_") else "GET") for c in INCLUDED}

# compatibility
verdict = {(r["deployment"], r["test"]): r["verdict"] for r in compat}
failed = {(r["deployment"], r["test"]): [x for x in r["failed_sub_checks"].split("; ") if x] for r in compat}
okn = {(r["deployment"], r["test"]): [x for x in r["ok_sub_checks"].split("; ") if x] for r in compat}
nsub = {(r["deployment"], r["test"]): int(r["sub_checks"]) for r in compat}
TESTS = sorted({t for _, t in verdict})
WHAT = {r["test"]: r["what"] for r in compat}

# security
secc = {(r["system"], r["row"]): r["outcome"] for r in sec}
ROWS = sorted({r for _, r in secc}, key=lambda x: int(x[1:]))
SEC_ROWS = [r for r in ROWS if all(secc[(s, r)] in ("PASS", "FAIL") for s in SYS)]
if SEC_ROWS != SEC_ROWS_EXPECTED:
    sys.exit(f"scored security rows {SEC_ROWS} differ from scoring_method.md 4.3 ({SEC_ROWS_EXPECTED})")

# fault tolerance S1
S1 = {s: [r for r in ft if r["system"] == s and r["scenario"] == "S1"] for s in SYS}
if any(not v for v in S1.values()):
    sys.exit("no S1 runs for a system")


# ------------------------------------------------------------------ step 1: print exclusions and gate
def gate(s):
    """G1 (3.1): all sub-checks of C01 to C07 ok, the named sub-checks of C08 and C13 ok."""
    why = []
    for t in [f"C0{i}" for i in range(1, 8)]:
        if verdict[(s, t)] != "PASS":
            why.append(f"{t} {verdict[(s, t)]}")
    for t, names in GATE_SUBCHECKS.items():
        for n in names:
            if n not in okn[(s, t)]:
                why.append(f"{t}:{n} not ok")
    return not why, why


GATE = {s: gate(s) for s in SYS}
print("client limited exclusion (4.1.1): configurations excluded for all systems:")
for c in EXCLUDED:
    print("   ", c, "flagged:", ", ".join(NAME[s] for s in SYS if cl[(s, c)] == "yes"))
print(f"included: {len(INCLUDED)} configurations (PUT {sum(1 for c in INCLUDED if FAM[c] == 'PUT')}, GET {sum(1 for c in INCLUDED if FAM[c] == 'GET')})")
print("gate G1 (basic object workflow):")
for s in SYS:
    print("   ", NAME[s], "meets" if GATE[s][0] else "DOES NOT MEET: " + "; ".join(GATE[s][1]))
print("security rows scored (all four PASS or FAIL):", ", ".join(SEC_ROWS))


# ------------------------------------------------------------------ step 2: dimension scores
def perf_scores(rank, wget):
    cell = {}
    for c in INCLUDED:
        vals = {s: mp[(s, c)] for s in SYS}
        if rank:
            cell[c] = rank_points(vals, True)
        else:
            best = max(vals.values())
            cell[c] = {s: vals[s] / best for s in SYS}
    out = {}
    for s in SYS:
        put = statistics.mean(cell[c][s] for c in INCLUDED if FAM[c] == "PUT")
        get = statistics.mean(cell[c][s] for c in INCLUDED if FAM[c] == "GET")
        out[s] = (1 - wget) * put + wget * get
    return out, cell


def compat_scores(no_c18, rf_default, drop=None):
    skip = set(GROUPS[drop]) if drop else set()
    if no_c18:
        skip.add("C18")
    tests = [t for t in TESTS if t not in skip]
    out = {}
    for s in SYS:
        key = "rustfs_default" if (s == "rustfs" and rf_default) else s
        out[s] = sum(1 for t in tests if verdict[(key, t)] == "PASS") / len(tests)
    return out


def sec_scores():
    return {s: sum(1 for r in SEC_ROWS if secc[(s, r)] == "PASS") / len(SEC_ROWS) for s in SYS}


def ft_gaps():
    res = {}
    for s in SYS:
        w = statistics.median(float(r["confirmed_interval_s"]) for r in S1[s])
        rd = statistics.median(float(r["survivor_read_gap_s"]) for r in S1[s])
        cens = any(r["confirmed_interval_censored"] == "True" or r["survivor_read_gap_censored"] == "True" for r in S1[s])
        res[s] = (w, rd, cens)
    return res


def ft_scores(plateau, rank):
    g = ft_gaps()
    eff_w = {s: max(plateau, g[s][0]) for s in SYS}
    eff_r = {s: max(plateau, g[s][1]) for s in SYS}
    if rank:
        f1, f2 = rank_points(eff_w, False), rank_points(eff_r, False)
    else:
        f1 = {s: plateau / eff_w[s] for s in SYS}
        f2 = {s: plateau / eff_r[s] for s in SYS}
    return {s: (f1[s] + f2[s]) / 2 for s in SYS}, f1, f2, eff_w, eff_r


def dims(var, wget, drop_group=None):
    rank = var.get("rank", False)
    p, _ = perf_scores(rank, wget)
    c = compat_scores(var.get("no_c18", False), var.get("rf_default", False), drop_group)
    sc = sec_scores()
    f, *_ = ft_scores(var.get("plateau", PLATEAU), rank)
    return {s: (p[s], c[s], sc[s], f[s]) for s in SYS}


def eligible(prof):
    return [s for s in SYS if (not PROFILES[prof]["gate"]) or GATE[s][0]]


def overall(d, w):
    tot = sum(w)
    return {s: sum(wi * di for wi, di in zip(w, d[s])) / tot for s in SYS}


def first_place(scores, elig, margin):
    ranked = sorted(elig, key=lambda s: scores[s], reverse=True)
    if not ranked:
        return None, None, None, False
    if len(ranked) == 1:
        return ranked[0], None, None, True
    diff = scores[ranked[0]] - scores[ranked[1]]
    return ranked[0], ranked[1], diff, diff >= margin - 1e-12


# ------------------------------------------------------------------ step 3: variants
WEIGHT_MULT = [None] + list(itertools.product((0.8, 1.2), repeat=4))


def weights_of(prof, mult):
    w = PROFILES[prof]["w"]
    return tuple(a * b for a, b in zip(w, mult)) if mult else tuple(w)


variant_rows = []
base_dims = {}
results = {}
for prof, spec in PROFILES.items():
    elig = eligible(prof)
    wget = spec["wget"]
    rows = []
    # base
    d0 = dims({}, wget)
    base_dims[prof] = d0
    sc0 = overall(d0, spec["w"])
    top0, _, _, _ = first_place(sc0, elig, MARGIN)
    rows.append(("base", "base", None, MARGIN, sc0))
    for m in WEIGHT_MULT[1:]:
        rows.append(("weights", "weights x" + "/".join(f"{x:g}" for x in m), m, MARGIN, overall(d0, weights_of(prof, m))))
    for vname, ov in VARIANTS.items():
        d = dims(ov, wget)
        margin = ov.get("margin", MARGIN)
        for m in WEIGHT_MULT:
            lab = vname + ("" if m is None else " | weights x" + "/".join(f"{x:g}" for x in m))
            rows.append(("scoring " + vname, lab, m, margin, overall(d, weights_of(prof, m))))
    cat_first = {}
    changes = []
    for cat, lab, m, margin, sc in rows:
        top, second, diff, ok = first_place(sc, elig, margin)
        cat_first.setdefault(cat, {})
        key = NAME[top] if (top and ok) else ("no clear first" if top else "none")
        cat_first[cat][key] = cat_first[cat].get(key, 0) + 1
        differs = (top != top0) or (not ok)
        if differs:
            changes.append(lab)
        variant_rows.append([prof, cat, lab, "" if m is None else "/".join(f"{x:g}" for x in m), margin] +
                            [f"{sc[s]:.4f}" for s in SYS] + [NAME[top] if top else "", NAME[second] if second else "",
                                                             "" if diff is None else f"{diff:.4f}", "yes" if ok else "no", "yes" if differs else "no"])
    # robust winner (6.5)
    if not elig:
        verdict_txt = "no eligible system"
    elif len(elig) == 1:
        verdict_txt = f"the only qualifying system: {NAME[elig[0]]}"
    elif not changes and top0:
        verdict_txt = f"robust winner within the tested assumptions: {NAME[top0]}"
    else:
        verdict_txt = "no robust winner"
    results[prof] = dict(elig=elig, base=sc0, top0=top0, verdict=verdict_txt, cat_first=cat_first, n_changes=len(changes), n_variants=len(rows))

# diagnostics (6.3): not part of the robust rule
diag_rows = []
for prof, spec in PROFILES.items():
    elig = eligible(prof)
    d0 = base_dims[prof]
    for i, dn in enumerate(DIMS):
        w = list(spec["w"])
        w[i] = 0.0
        sc = overall(d0, tuple(w))
        top, second, diff, ok = first_place(sc, elig, MARGIN)
        diag_rows.append([prof, "leave out " + dn] + [f"{sc[s]:.4f}" for s in SYS] + [NAME[top] if top else "", "" if diff is None else f"{diff:.4f}", "yes" if ok else "no"])
    for g in GROUPS:
        d = dims({}, spec["wget"], drop_group=g)
        sc = overall(d, spec["w"])
        top, second, diff, ok = first_place(sc, elig, MARGIN)
        diag_rows.append([prof, "leave out compatibility group " + g] + [f"{sc[s]:.4f}" for s in SYS] + [NAME[top] if top else "", "" if diff is None else f"{diff:.4f}", "yes" if ok else "no"])

# ------------------------------------------------------------------ outputs
outputs = []


def out_csv(name, header, rows):
    p = OUTDIR / name
    write_csv(p, header, rows)
    outputs.append(p)


def out_tex(name, text):
    p = OUTDIR / name
    write_text(p, text)
    outputs.append(p)


# performance cells
_, cell_ratio = perf_scores(False, 0.5)
_, cell_rank = perf_scores(True, 0.5)
rows = []
for c in CFGS:
    for s in SYS:
        inc = c in INCLUDED
        rows.append([c, NAME[s], mp[(s, c)], cl[(s, c)], "yes" if inc else "no (a system is client limited)",
                     f"{cell_ratio[c][s]:.4f}" if inc else "", f"{cell_rank[c][s]:.4f}" if inc else ""])
out_csv("scoring_perf_cells.csv", ["configuration", "system", "median_MiB_s", "client_limited", "included", "score_ratio", "score_rank"], rows)

# fault tolerance
g = ft_gaps()
fscore, f1, f2, effw, effr = ft_scores(PLATEAU, False)
rows = [[NAME[s], len(S1[s]), f"{g[s][0]:.1f}", f"{g[s][1]:.1f}", "yes" if g[s][2] else "no", f"{effw[s]:.1f}", f"{effr[s]:.1f}", f"{f1[s]:.4f}", f"{f2[s]:.4f}", f"{fscore[s]:.4f}"] for s in SYS]
out_csv("scoring_ft.csv", ["system", "S1_runs", "median_write_gap_s", "median_read_gap_s", "any_censored", "effective_write_gap_s", "effective_read_gap_s", "FT1", "FT2", "FT"], rows)
rows = [[r["run"], NAME[r["system"]], r["scenario"], r["confirmed_interval_s"], r["target_gap_s"], r["confirmed_in_outage_after_60s"]] for r in ft]
out_csv("scoring_ft_observed.csv", ["run", "system", "scenario", "confirmed_write_gap_s", "observed_outage_s", "confirmed_writes_from_60s_to_outage_end"], rows)

# security
rows = []
for s in SYS:
    for r in ROWS:
        if secc[(s, r)] == "FAIL" or (s == "seaweedfs" and r == "r6"):
            rows.append([NAME[s], r, secc[(s, r)], "scored" if r in SEC_ROWS else "listed only (not scored)"])
out_csv("scoring_security_findings.csv", ["system", "row", "outcome", "role"], rows)

# feature table
def feature(s, t):
    v = verdict[(s, t)]
    if v == "UNSUPPORTED":
        return "unsupported"
    if v == "PASS":
        return "supported"
    nf = len(failed[(s, t)])
    return "failed" if nf == nsub[(s, t)] else "partial"


rows = [[t, WHAT[t]] + [feature(s, t) for s in SYS] for t in FEATURES]
out_csv("scoring_features.csv", ["test", "what"] + [NAME[s] for s in SYS], rows)
out_tex("scoring_features.tex", "\n".join(["\\begin{tabular}{@{}llllll@{}}", "\\toprule", "Test & Feature & " + " & ".join(NAME[s] for s in SYS) + " \\\\", "\\midrule"] +
        [f"{t} & {tex(WHAT[t])} & " + " & ".join(feature(s, t) for s in SYS) + " \\\\" for t in FEATURES] + ["\\bottomrule", "\\end{tabular}"]) + "\n")

# profiles and base scores
out_csv("scoring_profiles.csv", ["profile", "gate", "w_performance", "w_compatibility", "w_security", "w_fault_tolerance", "w_GET_in_performance"],
        [[p, "G1" if v["gate"] else "none", *v["w"], v["wget"]] for p, v in PROFILES.items()])
rows = []
for prof in PROFILES:
    for s in SYS:
        d = base_dims[prof][s]
        ok = s in results[prof]["elig"]
        rows.append([prof, NAME[s], "yes" if ok else "no (gate)"] + [f"{x:.4f}" for x in d] + [f"{results[prof]['base'][s]:.4f}" if ok else ""])
out_csv("scoring_base.csv", ["profile", "system", "eligible", "performance", "compatibility", "security_common_checks", "fault_tolerance", "overall"], rows)
lines = ["\\begin{tabular}{@{}llrrrrrrrr@{}}", "\\toprule", "System & Gate & Perf. & Compat. & Security & Fault tol. & " + " & ".join(p.split(" ")[0] for p in PROFILES) + " \\\\", "\\midrule"]
d_eq = base_dims["P0 equal weights"]
for s in SYS:
    cells = []
    for prof in PROFILES:
        cells.append(f"{results[prof]['base'][s]:.2f}" if s in results[prof]["elig"] else "n.e.")
    lines.append(f"{NAME[s]} & {'met' if GATE[s][0] else 'not met'} & " + " & ".join(f"{x:.2f}" for x in d_eq[s]) + " & " + " & ".join(cells) + " \\\\")
lines += ["\\bottomrule", "\\end{tabular}"]
out_tex("scoring_base.tex", "\n".join(lines) + "\n")

hdr = ["profile", "category", "variant", "weight_multipliers", "tie_margin"] + [f"score_{s}" for s in SYS] + ["first", "second", "difference", "margin_met", "differs_from_base"]
out_csv("scoring_variants.csv", hdr, variant_rows)
out_csv("scoring_diagnostics_leave_one_out.csv", ["profile", "left_out"] + [f"score_{s}" for s in SYS] + ["first", "difference", "margin_met"], diag_rows)
rows = []
for prof, r in results.items():
    for cat, cnt in r["cat_first"].items():
        rows.append([prof, cat, "; ".join(f"{k} {v}" for k, v in sorted(cnt.items()))])
out_csv("scoring_first_place_counts.csv", ["profile", "category", "first place count (descriptive, not a probability)"], rows)
out_csv("scoring_result.csv", ["profile", "eligible", "base_first", "variants", "variants_where_first_place_changes", "result"],
        [[p, ", ".join(NAME[s] for s in r["elig"]), NAME[r["top0"]] if r["top0"] else "", r["n_variants"], r["n_changes"], r["verdict"]] for p, r in results.items()])

write_manifest(OUTDIR / "MANIFEST.txt", "Scoring matrix (scoring_method.md revision 2): inputs and outputs", INPUTS + [Path(__file__)], outputs)

print()
print("RESULT per profile (scoring_method.md 6.5):")
for prof, r in results.items():
    print(f"  {prof}: {r['verdict']}  (first place changes in {r['n_changes']} of {r['n_variants']} variants)")
print(f"wrote {len(outputs)} files and MANIFEST.txt to {OUTDIR}")
