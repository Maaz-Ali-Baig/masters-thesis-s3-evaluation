# Scoring matrix method (frozen before any score is computed)

Status: DRAFT of 16 October 2026. This file is committed BEFORE `analysis/build_scoring.py` exists. After the commit, a rule may change only by an entry in section 9 (what changed, why, and whether scores had been seen). Reviewed by: (pending) the author and a second reviewer.

## 1. Purpose and limits of the claim

1. The matrix is a decision aid. It turns the measured results of the four dimensions into scores under explicit assumptions (gates, formulas, weights). A score is a derived result, not independent evidence that a system is better.
2. The raw measurements (cross system records, `analysis/out/`) are always shown next to the scores.
3. The conclusion drawn from the matrix is bounded to technical suitability under the tested conditions: three VMs, one cluster per system, default deployments, one client (AWS CLI 2.36.8, Warp 1.8.0). Operating effort, cost, TLS impact and maturity are not measured and are not scored.
4. The systems are compared as deployments, not as isolated software: the redundancy differs (Ceph, SeaweedFS and Garage keep three copies, RustFS uses erasure coding 3+3) and the load node ceph2 also runs a storage node.
5. A winner is named only if it wins under every variant of section 6. The wording is "robust within the tested assumptions".

## 2. Inputs (nothing else is used)

1. Performance: `analysis/out/perf/perf_long.csv` (median of three runs, client limited flag).
2. Compatibility: `analysis/out/compat/compat_cells.csv` (verdict and failed sub-checks per test). RustFS means 1.0.1 with the SSE-S3 master key, which is the state of every VM series; the variant without the key is used in the sensitivity check of section 6.
3. Security: `analysis/out/security/security_cells.csv`.
4. Fault tolerance: `analysis/out/ft/ft_runs.csv` (confirmed write gap, read gap).
5. Definitions: `analysis/README.md`, the four cross system records in `results/`.

## 3. Stage 0: requirement gates

A gate is a requirement that a profile needs. A system that fails a gate of a profile gets no score in that profile (it is listed as "does not meet the requirement"). Gates are defined on sub-checks of the compatibility probe, not on the verdict word, because a FAIL can be one failed sub-check.

1. Gate G1, core object API (used by the profile "S3 drop-in" only): all sub-checks of C01 to C07 are ok, and the sub-checks `initiate`, `upload_parts`, `complete`, `assembled_bytes_identical` and `abort` of C08, and `fetch_ok` of C13 are ok.
2. No other gate is applied in any profile. Optional features (tagging C09, versioning C10, bucket policy C14, CORS C15, lifecycle C16, object lock C17, SSE-S3 C18, ACLs C19) are reported in a separate requirement table (system by feature, yes or no from the sub-checks). A reader who needs a feature reads off which systems qualify. A feature is never a hidden gate.

## 4. Stage 1: scores per criterion (0 to 1, higher is better)

### 4.1 Performance (two families, so that the number of configurations does not decide the weight)

1. Only configurations in which NO system is client limited are used (ceph2 mean CPU above 80 percent flags a system in a configuration). The configurations excluded for all systems are listed in the output (expected: PUT 16 MiB, PUT 100 MiB, PUT 1 MiB with 16 and 64 users, GET 50 KiB, mixed). Large object PUT and the mixed workload are therefore not scored. This is stated as a limit.
2. Per included configuration: score = median of the system divided by the highest median of the four systems.
3. Family PUT = mean over its included configurations; family GET = mean over its included configurations. Performance = w_PUT x PUT + w_GET x GET, with w_PUT = w_GET = 0.5 except in the profile "read heavy" (0.2 and 0.8).
4. The three run ranges are reported next to the score. They are not used to create ties.
5. Limit to state: most GET data came from memory (resource records), so GET scores say little about the drives.

### 4.2 Compatibility

1. Score = number of tests with the verdict PASS divided by 22 (UNSUPPORTED and FAIL count as 0). RustFS is scored with the SSE-S3 key (C18 PASS); SeaweedFS and Ceph as deployed.
2. This is a count of tests, not a statement about compatibility with S3 in general. The optional feature table of section 3 is the readable form for a specific requirement.

### 4.3 Security (default deployments, plain http)

1. Only checks that have the outcome PASS or FAIL for all four systems are scored (PASS = 1, FAIL = 0): rows 1, 2, 3, 7, 8, 9 and 12 of the security table. Score = PASS divided by the number of scored rows.
2. Rows with the outcome info, refused, not in clear or not tested are not scored, because they have no pass condition or were not tested for every system.
3. KNOWN WEAKNESS: six of the seven scored rows have the same outcome in all four systems (only row 12, the failed login in the log, differs), so this score separates the systems only a little and does not contain the most serious finding (SeaweedFS filer port, row 6, outcome info for the other systems). Therefore the security result is always shown with the list of FAIL findings per system, and the variant in section 6 scores row 6 (SeaweedFS FAIL, the others "no finding" = PASS) to show how much it changes the result.

### 4.4 Fault tolerance (scenario S1, one node hard stopped; two criteria)

1. FT1 write availability: 0 if writes were not sustained during the outage, defined as: the median over the S1 runs of the longest gap between confirmed writes is at least 50 percent of the median observed outage of the stopped endpoint (in the tested data this is expected for SeaweedFS only: gaps of 800 and 815 s against outages of 855 and 843 s; the script decides, not this sentence). Otherwise 32 s divided by the larger of 32 s and the median over the S1 runs of the longest gap between confirmed writes. The value 32 s is the largest gap that is attributed to the client read time out of 25 s plus one probe round (record FT, D4, Q6): gaps up to 32 s are not distinguished.
2. FT2 read availability at a surviving endpoint: 32 s divided by the larger of 32 s and the median over the S1 runs of the longest gap between successful reads of the fixed object.
3. Fault tolerance = mean of FT1 and FT2.
4. Not scored (reported only): recovery after the return (units differ per system), scenario S2 (no system confirmed a write while two nodes were down, and the outage lengths differ), reads during the S2 outage (timing artefact in Ceph).
5. Limit to state: two to three runs per system, hard stop only, outage length differs in S2, acknowledgement type differs (the confirmed write measure does not depend on it).

## 5. Stage 2: weights and aggregation

1. Dimension score = the score of section 4 (performance, compatibility, security, fault tolerance). Overall score of a profile = sum of weight x dimension score, weights sum to 1.
2. Profiles (the weights are ASSUMPTIONS without an empirical basis; they are decisions of the author and are changed only by section 9):

| Profile | Gate | Performance | Compatibility | Security | Fault tolerance |
|---|---|---|---|---|---|
| P0 equal weights | none | 0.25 | 0.25 | 0.25 | 0.25 |
| P1 S3 drop-in for existing applications | G1 | 0.15 | 0.50 | 0.15 | 0.20 |
| P2 read heavy throughput | none | 0.55 (GET 0.8) | 0.15 | 0.10 | 0.20 |
| P3 availability on a small cluster | none | 0.15 | 0.15 | 0.10 | 0.60 |
| P4 security conscious | none | 0.10 | 0.15 | 0.55 | 0.20 |

3. A score difference below 0.05 is not interpreted (convention, not derived from the data).

## 6. Sensitivity rules (frozen)

For every profile the base result is computed, then these variants. All variants are reported.

1. Weights, jointly: every combination of multiplying each of the four weights by 0.8 or 1.2 (16 variants), then renormalising to sum 1.
2. Scoring method: (a) rank points instead of the formulas (4 for the best system, 1 for the worst, equal values share the mean rank, no range based ties); (b) compatibility as the share of sub-checks that are ok instead of the share of tests; (c) compatibility without C18; (d) RustFS without the SSE-S3 key (C18 FAIL); (e) security with row 6 scored as in 4.3 point 3.
3. Criterion inclusion: leave out each dimension in turn (renormalise the other weights), and leave out each compatibility test group (C01 to C08, C09 to C10 and C14 to C17, C11 to C13, C18 to C20, C21 to C22).
4. A system is called the robust winner of a profile only if it has the highest overall score in the base result and in every variant (differences below 0.05 count as a shared first place and block a robust winner). Otherwise the result is "no robust winner", with the share of variants won by each system.
5. The script writes one table per profile (base scores, raw values, variants won) and a list of every variant in which the first place changes.

## 7. What the thesis text may say

1. A score and its profile, with the assumptions of this file and the raw values next to it.
2. "System X has the highest score in profile P, robust within the tested assumptions", only under the rule of 6.4.
3. Never: a statement that a system is the best replacement for MinIO in general, a ranking that mixes dimensions without naming the profile and the weights, or an interpretation of a score difference below 0.05.

## 8. Known limits of the method

1. Aggregation can change the answer: rank spacing, weights and the inclusion of related checks. Section 6 tests this, but it does not remove it.
2. Fault tolerance has two to three runs per system and one failure type. The 25 s read time out of the probe hides differences of a few seconds (Q6 of the fault tolerance record: whether 25 s is a property of the systems or of the client is not tested).
3. The compatibility and security counts weight tests equally; they are not equal in impact.
4. Performance uses the unflagged configurations only. The GET results come mostly from memory.

## 9. Change log after the freeze

(empty: no rule has been changed since the first commit of this file)
