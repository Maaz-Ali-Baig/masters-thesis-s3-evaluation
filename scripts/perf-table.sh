#!/usr/bin/env bash
#
# Tables from one output folder of perf-warp.sh (run it on the VM that holds the folder).
#
#   bash perf-table.sh /root/perf-rustfs-20261010-163409
#
# Table 1: every recorded run (r1 to r3, the warm up runs are left out): label, throughput, objects per second,
#          average latency, p99 latency, number of error lines.
# Table 2: per configuration the median, the minimum and the maximum of the three throughput values (MiB/s).
# Both are plain text, tab separated, and are printed with their sha256 so that a copy can be checked.
# For the mixed workload the throughput is the Total report of Warp (latencies are per operation type and are
# not taken here, see the console files).

set -eu
D="${1:?usage: bash perf-table.sh <output folder of perf-warp.sh>}"
[ -d "$D/console" ] || { echo "perf-table: $D/console missing" >&2; exit 1; }
T1="$(mktemp)"; T2="$(mktemp)"
for f in "$D"/console/*_r[123].txt; do
    n="$(basename "$f" .txt)"
    awk -v n="$n" '
        /^Report: Total/ { t=1 }
        /Average:/ && !a && (n !~ /^mixed/ || t) { s=$0; sub(/.*Average: /,"",s); split(s,x,", "); thr=x[1]; objs=x[2]; a=1 }
        /\* Reqs:/ && !r && n !~ /^mixed/ { s=$0; sub(/.*Reqs: Avg: /,"",s); split(s,y,", "); avg=y[1]; p99=y[4]; sub(/^99%: /,"",p99); r=1 }
        /Errors:/ { e++ }
        END { printf "%s\t%s\t%s\t%s\t%s\t%d\n", n, thr, objs, avg, p99, e }' "$f"
done > "$T1"
{
    printf 'run\tthroughput\tobjects_per_s\tavg_latency\tp99_latency\terror_lines\n'
    cat "$T1"
} > "$T2"
cp "$T2" "$D/table-runs.tsv"
awk -F'\t' '{
        n=$1; sub(/_r[123]$/,"",n); v=$2; sub(/ MiB\/s.*/,"",v); v=v+0
        c[n]++; val[n, c[n]]=v
    }
    END {
        for (n in c) {
            if (c[n] < 3) { printf "%s\t%d\tn/a\tn/a\tn/a\n", n, c[n]; continue }
            a=val[n,1]; b=val[n,2]; d=val[n,3]
            lo=a; if (b<lo) lo=b; if (d<lo) lo=d
            hi=a; if (b>hi) hi=b; if (d>hi) hi=d
            med=a+b+d-lo-hi
            printf "%s\t%d\t%.2f\t%.2f\t%.2f\n", n, c[n], med, lo, hi
        }
    }' "$T1" | sort > "$T1.cfg"
{
    printf 'configuration\truns\tmedian_MiB_s\tmin_MiB_s\tmax_MiB_s\n'
    cat "$T1.cfg"
} > "$D/table-configs.tsv"
rm -f "$T1" "$T2" "$T1.cfg"
echo "== table 1: every recorded run ($D/table-runs.tsv)"
cat "$D/table-runs.tsv"
sha256sum "$D/table-runs.tsv"
echo "== table 2: median, minimum and maximum of three runs ($D/table-configs.tsv)"
cat "$D/table-configs.tsv"
sha256sum "$D/table-configs.tsv"
