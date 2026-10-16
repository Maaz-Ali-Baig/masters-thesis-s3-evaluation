# Scoring matrix method (frozen before any score is computed)

Status: revision 1 of 16 October 2026 (first version committed as 83936b2, revised after review by a second reader, before any score was computed; see section 9). This file is committed BEFORE `analysis/build_scoring.py` exists. After this commit, a rule may change only by an entry in section 9 (what changed, why, and whether scores had been seen).

## 1. Purpose and limits of the claim

1. The matrix is a decision aid. It turns the measured results of the four dimensions into scores under explicit assumptions (gates, formulas, thresholds, weights). A score is a derived result, not independent evidence that a system is better.
2. The raw measurements (cross system records, `analysis/out/`) are always shown next to the scores.
3. The conclusion drawn from the matrix is bounded to technical suitability under the tested conditions: three VMs, one cluster per system, default deployments, one client (AWS CLI 2.36.8, Warp 1.8.0). Operating effort, cost, TLS impact and maturity are not measured and are not scored.
4. The systems are compared as deployments, not as isolated software: the redundancy differs (Ceph, SeaweedFS and Garage keep three copies, RustFS uses erasure coding 3+3) and the load node ceph2 also runs a storage node.
5. A winner is named only under the rule of section 6.5. The wording is "robust within the tested assumptions".

## 2. Inputs (nothing else is used)

1. Performance: `analysis/out/perf/perf_long.csv` (median of three runs, client limited flag).
2. Compatibility: `analysis/out/compat/compat_cells.csv` (verdict and failed sub-checks per test). RustFS means 1.0.1 with the SSE-S3 master key, which is the state of every VM series; the variant without the key is used in section 6.
3. Security: `analysis/out/security/security_cells.csv`.
4. Fault tolerance: `analysis/out/ft/ft_runs.csv` (confirmed write gap, read gap, outage).
5. Definitions: `analysis/README.md`, the four cross system records in `results/`.

## 3. Stage 0: requirement gate and feature table

A gate is a requirement that a profile needs. A system that fails the gate of a profile gets no score in that profile (it is listed as "does not meet the requirement"). The gate is defined on sub-checks of the compatibility probe, not on the verdict word, because a FAIL can be one failed sub-check.

1. Gate G1, basic object workflow (used by profile P1 only): all sub-checks of C01 to C07 are ok, and the sub-checks `initiate`, `upload_parts`, `complete`, `assembled_bytes_identical` and `abort` of C08, and `fetch_ok` of C13 are ok. Passing G1 does not establish that an application will work: P1 applies to applications whose required features are satisfied (see the feature table).
2. No other gate is applied. Optional features (tagging C09, versioning C10, bucket policy C14, CORS C15, lifecycle C16, object lock C17, SSE-S3 C18, ACLs C19) are reported in a feature table (system by feature) with four values: supported (all sub-checks of the test ok), partial (at least one sub-check ok and at least one failed; the failed sub-check names are listed), unsupported (the server answered NotImplemented), untested. A reader who needs a feature reads off which systems qualify. A feature is never a hidden gate.
3. Scores of gated systems are computed with the same reference values as for ungated systems (the best value is taken over all four systems).

## 4. Stage 1: scores per criterion (0 to 1, higher is better)

### 4.1 Performance (two families, so that the number of configurations does not decide the weight)

1. Only configurations in which NO system is client limited are used (ceph2 mean CPU above 80 percent flags a system in a configuration). The configurations excluded for all systems are listed in the output (expected: PUT 16 MiB, PUT 100 MiB, PUT 1 MiB with 16 and 64 users, GET 50 KiB, mixed). Large object PUT and the mixed workload are therefore not scored. This is stated as a limit.
2. Per included configuration: score = median of the system divided by the highest median of the four systems.
3. Family PUT = mean over its included configurations; family GET = mean over its included configurations (every configuration in a family has equal weight). Performance = w_PUT x PUT + w_GET x GET, with w_PUT = w_GET = 0.5 except in profile P2 (0.2 and 0.8).
4. The three run ranges are reported next to the score. They are not used to create ties.
5. Limit to state: most GET data came from memory (resource records), so GET scores say little about the drives.

### 4.2 Compatibility

1. Score = number of tests with the verdict PASS divided by 22 (UNSUPPORTED and FAIL count as 0). RustFS is scored with the SSE-S3 key (C18 PASS); SeaweedFS and Ceph as deployed.
2. This is a count of tests, not a statement about compatibility with S3 in general. The feature table of section 3 is the readable form for a specific requirement.
3. A share of sub-checks is NOT used as an alternative: the probe lists different sub-checks when a test fails than when it passes (for example SeaweedFS C19 lists 6 sub-checks, Ceph 9; RustFS C21 lists `component_256` where Ceph lists `all_keys_roundtrip`), so per sub-check shares are not comparable across systems.

### 4.3 Security (default deployments, plain http): common checks only

1. Only checks that have the outcome PASS or FAIL for all four systems are scored (PASS = 1, FAIL = 0): rows 1, 2, 3, 7, 8, 9 and 12 of the security table. Score = PASS divided by the number of scored rows.
2. Rows with the outcome info, refused, not in clear or not tested are not scored: they have no pass condition or were not tested for every system. Absence of a finding is not counted as a pass.
3. KNOWN WEAKNESS: six of the seven scored rows have the same outcome in all four systems (only row 12, the failed login in the log, differs). This score separates the systems only through row 12. It does not contain the most serious finding (SeaweedFS filer port serves object data without credentials, row 6), because the equivalent check was not made as a pass or fail test on the other systems.
4. Therefore the security result is always reported with the list of FAIL and critical findings per system next to the score, the security score is described as "common security checks", and no numerical profile for security is computed (see section 5).

### 4.4 Fault tolerance (scenario S1, one node hard stopped)

1. FT1 write interruption: 32 s divided by the larger of 32 s and the median over the S1 runs of the longest gap between confirmed writes. There is no separate zero rule: a long gap gives a score near 0 by the formula itself (for example 800 s gives 0.04).
2. FT2 read interruption at a surviving endpoint: 32 s divided by the larger of 32 s and the median over the S1 runs of the longest gap between successful reads of the fixed object.
3. The value 32 s is an ASSUMED practical equivalence threshold, not a measured resolution. Reason: the probe uses a client read time out of 25 s, and a request in flight at the stop hangs until that time out; the largest gap attributed to this effect in Ceph and RustFS (writes and reads) is 32 s (one time out plus one probe round). Whether the systems would resume faster with another client is not tested (Q6 of the fault tolerance record). The threshold is varied in section 6.
4. Fault tolerance = mean of FT1 and FT2.
5. Reported next to the score, not scored: the number of confirmed writes between 60 s after time zero and the end of the outage (directly observed, per run, computed from the ledger and the read back in the run archives; if the archives cannot give it for a run, the cell is empty and this is stated), recovery after the return (units differ per system), scenario S2 (no system confirmed a write while two nodes were down, and the outage lengths differ), reads during the S2 outage (timing artefact in Ceph).
6. The write measure uses client observed success confirmed by a later read of the object on all endpoints. The acknowledgement mechanisms differ (put-object with ETag for Ceph, aws s3 cp exit code for the others), which limits comparability; the measure does not establish durability.
7. Limit to state: two to three runs per system, hard stop only, outage length differs in S2.

## 5. Stage 2: weights and aggregation

1. Dimension score = the score of section 4 (performance, compatibility, common security checks, fault tolerance). Overall score of a profile = sum of weight x dimension score, weights sum to 1.
2. Profiles (the weights are ASSUMPTIONS without an empirical basis; they are decisions of the author and are changed only by section 9):

| Profile | Gate | Performance | Compatibility | Security (common checks) | Fault tolerance |
|---|---|---|---|---|---|
| P0 equal weights | none | 0.25 | 0.25 | 0.25 | 0.25 |
| P1 S3 compatibility priority | G1 | 0.15 | 0.50 | 0.15 | 0.20 |
| P2 read heavy throughput | none | 0.55 (GET 0.8, PUT 0.2) | 0.15 | 0.10 | 0.20 |
| P3 availability on a small cluster | none | 0.15 | 0.15 | 0.10 | 0.60 |

3. A security conscious profile is NOT computed: the common security checks do not separate the systems enough (4.3). The security chapter reports the findings table instead, and the Discussion states the security findings per system without a score.
4. A score difference below 0.05 is not interpreted (convention, not derived from the data; varied in section 6).

## 6. Sensitivity rules (frozen)

For every profile P0 to P3 the base result is computed, then the variants below. All variants are reported, by category.

1. Weights: every combination of multiplying each of the four weights by 0.8 or 1.2 (16 variants), then renormalising to sum 1. Every scoring variant of point 2 is run with all 16 weight combinations (and with the unchanged weights).
2. Scoring variants (each replaces one rule, the others stay): (a) rank points instead of the ratio formulas in performance and fault tolerance, normalised as s_rank = (points minus 1) / 3 with points 4 for the best and 1 for the worst system and the mean rank for equal values; gates unchanged; (b) compatibility without C18; (c) RustFS without the SSE-S3 key (C18 FAIL); (d) fault tolerance plateau 25 s and 45 s instead of 32 s; (e) tie margin 0.03 and 0.10 instead of 0.05.
3. Dependency diagnostics (reported separately, NOT required for a robust winner): leave out each dimension in turn (renormalise the other weights), and leave out each compatibility test group (C01 to C08, C09 to C10 and C14 to C17, C11 to C13, C18 to C20, C21 to C22).
4. Eligible systems = systems that meet the gate of the profile. If no system is eligible, the profile has no result. If exactly one system is eligible, it is reported as "the only qualifying system", not as superior.
5. Robust winner of a profile: the eligible system with the highest overall score in the base result and in every variant of points 1 and 2 exceeds the runner up by at least the tie margin (0.05; 0.03 and 0.10 in variant (e)). Otherwise the result is "no robust winner" and the table lists in which variants the first place changes.
6. The count of variants in which a system is first is descriptive, not a probability: it depends on how many variants each category contains. It is reported per category.
7. The script writes one table per profile (base scores, raw values, variants won per category) and a list of every variant in which the first place changes.

## 7. What the thesis text may say

1. A score and its profile, with the assumptions of this file and the raw values next to it.
2. "System X has the highest score in profile P, robust within the tested assumptions", only under the rule of 6.5.
3. Never: a statement that a system is the best replacement for MinIO in general, a ranking that mixes dimensions without naming the profile and the weights, an interpretation of a score difference below the tie margin, or a numerical statement about security as a profile.

## 8. Known limits of the method

1. Aggregation can change the answer: weights, thresholds and the inclusion of related checks. Section 6 tests this, but it does not remove it, and it does not cover measurement uncertainty.
2. Fault tolerance has two to three runs per system and one failure type. The 25 s read time out of the probe hides differences of a few seconds.
3. The compatibility and security counts weight tests equally; they are not equal in impact.
4. Performance uses the unflagged configurations only. The GET results come mostly from memory.

## 9. Change log after the freeze

1. Revision 1 (16 October 2026, after the first commit 83936b2, before any score or build_scoring.py existed; reviewed by a second reader). Changes: (a) security: row 6 removed from the score (absence of a finding is not a pass), score renamed "common security checks", profile P4 (security conscious) not computed; (b) fault tolerance: the zero rule at 50 percent of the outage removed, 32 s labelled an assumed threshold and varied, directly observed confirmed writes during the outage added as a reported column, wording on the acknowledgement type changed; (c) profile P1 renamed "S3 compatibility priority", feature table with four values; (d) rank points normalised to 0 to 1, weight variants crossed with scoring variants, leave one out moved to diagnostics, thresholds varied, winner rule defined with eligible systems, descriptive counts per category; (e) the sub-check share variant for compatibility removed (the probe lists different sub-checks for failing and passing tests); (f) fixed reference values when a system is gated.
