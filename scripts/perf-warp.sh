#!/usr/bin/env bash
#
# Performance series with Warp for ONE system, as described in performance_method.md. Run as root on ceph2
# (the load node) while the system under test runs on all three VMs.
#
#   bash perf-warp.sh <system> <mode> [op size concurrency]
#
#   system   rustfs | seaweedfs | garage | ceph
#   mode     preflight   tools, key file, endpoints, Warp flags, bucket, a short smoke test (not a measurement)
#            controls    dd on every data disk and iperf3 from ceph2 to the other nodes (before and after a system)
#            size        series 1: object size 50 KiB, 1 MiB, 16 MiB, 100 MiB, concurrency 8, PUT and GET
#            conc        series 2: concurrency 1, 4, 16, 64 at 1 MiB, PUT and GET (PERF_EXTRA128=1 adds 128)
#            mixed       series 3: Warp mixed workload, 1 MiB, concurrency 16
#            all         size, conc and mixed, one after the other
#            one         a single run, for example: bash perf-warp.sh rustfs one put 1MiB 4
#
# Every configuration: one warm up run (PERF_WARMUP seconds, default 30, discarded) and three recorded runs
# (PERF_DURATION seconds, default 60). GET: the warm up run prepares the dataset, the recorded runs read it
# with the list existing flag. Page cache is emptied on the storage nodes before every GET run when ssh to them works.
#
# Storage node actions (df check, cache drop, sar) use key based ssh from ceph2 to ceph0 and ceph1 (a key made
# for this test and removed at the end of the VM work). Without it the script runs, but only ceph2 is monitored
# and the record says so. The key file of the system must be on ceph2 (rustfs and seaweedfs: copied with
# the config; garage: /root/garage-key.txt; ceph: /root/ceph-s3-credentials.txt, to be made in phase 4).
# Keys are read from the file, passed to Warp in the environment and never printed.
#
# Output: /root/perf-<system>-<time>/ with console/ (one text per run), raw/ (Warp benchdata), runs.tsv (label, kind,
# op, size, concurrency, start and end epoch, exit code), summary.txt, header.txt, SHA256SUMS and the .tar.gz next to it.
# Test only variables: PERF_TEST=1 (no ceph2 check, no version check), PERF_HOSTS, PERF_KEYFILE, PERF_NODES, PERF_AWS.

set -eu

SYSTEM="${1:-}"
MODE="${2:-}"
die() { echo "perf-warp: $*" >&2; exit 1; }

case "$SYSTEM" in
    rustfs)    KEYFILE=/root/rustfs-config/s3_credentials.txt;    AKL="Access key"; SKL="Secret key"; PORT=9000; REGION=us-east-1 ;;
    seaweedfs) KEYFILE=/root/seaweedfs-config/s3_credentials.txt; AKL="Access key"; SKL="Secret key"; PORT=8333; REGION=us-east-1 ;;
    garage)    KEYFILE=/root/garage-key.txt;                      AKL="Key ID";     SKL="Secret key"; PORT=3900; REGION=garage ;;
    ceph)      KEYFILE=/root/ceph-s3-credentials.txt;             AKL="Access key"; SKL="Secret key"; PORT=80;   REGION=us-east-1 ;;
    *) die "usage: $0 rustfs|seaweedfs|garage|ceph preflight|controls|size|conc|mixed|all|one [op size concurrency]" ;;
esac
KEYFILE="${PERF_KEYFILE:-$KEYFILE}"
HOSTS="${PERF_HOSTS:-192.168.1.72:$PORT,192.168.1.71:$PORT,192.168.1.70:$PORT}"
FIRST="${HOSTS%%,*}"
SELF=192.168.1.70
NODES="${PERF_NODES-192.168.1.72 192.168.1.71 192.168.1.70}"
AWSBIN="${PERF_AWS:-/opt/aws-cli-new/bin/aws}"
BUCKET=perfbench
DUR="${PERF_DURATION:-60}"
WARM="${PERF_WARMUP:-30}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="/root/perf-$SYSTEM-$TS"

[ "$(id -u)" = 0 ] || die "run as root"
if [ -z "${PERF_TEST:-}" ]; then
    [ "$(hostname -I | awk '{print $1}')" = "$SELF" ] || die "run this on ceph2 ($SELF), the load node"
fi
command -v warp >/dev/null || die "warp not found"
[ -x "$AWSBIN" ] || command -v aws >/dev/null || die "aws cli not found ($AWSBIN)"
[ -x "$AWSBIN" ] || AWSBIN="$(command -v aws)"
[ -s "$KEYFILE" ] || die "$KEYFILE missing"
AK="$(awk -F': *' -v k="$AKL" '$1==k{print $2}' "$KEYFILE")"
SK="$(awk -F': *' -v k="$SKL" '$1==k{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || die "cannot parse $KEYFILE"
export WARP_ACCESS_KEY="$AK" WARP_SECRET_KEY="$SK"
export AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION="$REGION"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
s3() { "$AWSBIN" --endpoint-url "http://$FIRST" "$@"; }
# the flag for reading existing objects is spelled differently in some Warp versions
if warp get --help 2>&1 | grep -q -- '--list-existing'; then LISTEX=--list-existing; else LISTEX=--list.existing; fi

# ---- storage node helpers (ssh from ceph2, ceph2 itself is local)
SSHOPT="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
node_sh() { if [ "$1" = "$SELF" ]; then bash -s; else ssh $SSHOPT "root@$1" bash -s; fi; }
on_nodes() { local ip; for ip in $NODES; do echo "== node $ip"; printf '%s\n' "$1" | node_sh "$ip" || echo "node $ip: command failed"; done; }
SSH_OK=1
for ip in $NODES; do
    [ "$ip" = "$SELF" ] && continue
    ssh $SSHOPT "root@$ip" true >/dev/null 2>&1 || SSH_OK=0
done
if [ "$SSH_OK" = 0 ] && [ -n "${PERF_TEST:-}" ]; then NODES=""; fi
if [ "$SSH_OK" = 0 ] && [ -z "${PERF_TEST:-}" ]; then NODES="$SELF"; fi

mkdir -p "$OUT/console" "$OUT/raw"
RUNS="$OUT/runs.tsv"
printf 'label\tkind\top\tsize\tconcurrency\tstart_epoch\tend_epoch\texit\n' > "$RUNS"

header() {
    echo "host: $(hostname)  system: $SYSTEM  mode: $MODE  time: $(date '+%F %T %z')  output: $OUT"
    echo "warp: $(warp --version 2>&1 | head -1)"
    echo "aws:  $("$AWSBIN" --version 2>&1 | head -1)"
    echo "kernel: $(uname -sr)  load node cpu: $(nproc) cores"
    echo "hosts: $HOSTS  region: $REGION  bucket: $BUCKET"
    echo "duration: $DUR s  warm up: $WARM s  ssh to storage nodes: $SSH_OK  nodes handled: ${NODES:-none}"
    echo "checksum setting for the aws cli: when_required (finding F1)"
}
header | tee "$OUT/header.txt"

# ---- space and cache control
used_pct() {
    local ip
    for ip in $NODES; do
        printf 'df --output=pcent /srv/s3/disk1 /srv/s3/disk2 | tail -n +2 | tr -d " %%"\n' | node_sh "$ip" 2>/dev/null || true
    done | sort -n | tail -1
}
wait_space() {
    local limit=50 i=0 u
    [ -n "$NODES" ] || return 0
    while :; do
        u="$(used_pct)"; u="${u:-0}"
        [ "$u" -le "$limit" ] && return 0
        i=$((i+1)); [ "$i" -gt 20 ] && die "data disks still ${u} percent used after 10 minutes, stopping"
        echo "space: ${u} percent used, waiting 30 s for reclaim ($i/20)"; sleep 30
    done
}
drop_caches() { [ -n "$NODES" ] || return 0; on_nodes 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1 || true; }
reclaim() {
    if [ "$SYSTEM" = ceph ] && [ "$SSH_OK" = 1 ]; then
        printf 'cephadm shell -- radosgw-admin gc process --include-all >/dev/null 2>&1; echo gc done\n' | node_sh 192.168.1.72 || true
    fi
}
clean_bucket() {
    s3 s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
    local n; n="$(s3 s3 ls "s3://$BUCKET" 2>/dev/null | wc -l)"
    echo "bucket $BUCKET objects left after cleaning: $n"
    reclaim
}
monitor_start() {
    [ -n "$NODES" ] || return 0
    on_nodes "mkdir -p $OUT; S_TIME_FORMAT=ISO nohup sar -u -r -d -n DEV 1 > $OUT/sar-\$(hostname).txt 2>&1 < /dev/null & echo \$! > $OUT/sar.pid; echo sar started" || true
}
monitor_stop() {
    [ -n "$NODES" ] || return 0
    on_nodes "kill \$(cat $OUT/sar.pid) 2>/dev/null; echo sar stopped; ls -l $OUT/sar-*.txt" || true
}

# ---- one Warp run
run_warp() { # label kind op size conc seconds [extra warp flags]
    local label="$1" kind="$2" op="$3" size="$4" conc="$5" secs="$6" s e rc
    shift 6
    [ "$op" = get ] && drop_caches
    wait_space
    echo "=== $label  ($kind, $op, $size, concurrency $conc, ${secs}s)  $(date '+%T')"
    s="$(date +%s)"
    set +e
    warp "$op" --host="$HOSTS" --region="$REGION" --bucket="$BUCKET" --obj.size="$size" \
        --concurrent="$conc" --duration="${secs}s" --benchdata="$OUT/raw/$label" --no-color "$@" \
        > "$OUT/console/$label.raw" 2>&1
    rc=$?
    set -e
    e="$(date +%s)"
    # Warp draws a progress bar; keep the text without the bar and the progress lines
    tr '\r' '\n' < "$OUT/console/$label.raw" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
        | grep -v -E '█|^[[:space:]]*$|^Reqs: [0-9]+, Errs|^ - +[A-Z]+ Average' > "$OUT/console/$label.txt" || true
    rm -f "$OUT/console/$label.raw"
    if grep -q '^Report:' "$OUT/console/$label.txt"; then
        sed -n '/^Report:/,$p' "$OUT/console/$label.txt" | cut -c1-200
    else
        tail -15 "$OUT/console/$label.txt" | cut -c1-200
    fi
    echo "exit code $rc"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$kind" "$op" "$size" "$conc" "$s" "$e" "$rc" >> "$RUNS"
}

config() { # op size conc objects
    local op="$1" size="$2" conc="$3" objs="$4" tag r
    tag="${op}_${size}_c${conc}"
    echo "##### configuration $tag"
    if [ "$op" = get ]; then
        clean_bucket
        run_warp "${tag}_warm" warm get "$size" "$conc" "$WARM" --objects="$objs" --noclear
        for r in 1 2 3; do
            run_warp "${tag}_r$r" run get "$size" "$conc" "$DUR" $LISTEX --noclear
        done
    else
        run_warp "${tag}_warm" warm "$op" "$size" "$conc" "$WARM"
        for r in 1 2 3; do run_warp "${tag}_r$r" run "$op" "$size" "$conc" "$DUR"; done
    fi
    clean_bucket
}

series_size() {
    local spec size objs
    for spec in 50KiB:50000 1MiB:8192 16MiB:512 100MiB:80; do
        size="${spec%%:*}"; objs="${spec##*:}"
        config put "$size" 8 "$objs"
        config get "$size" 8 "$objs"
    done
}
series_conc() {
    local c list="1 4 16 64"
    [ -n "${PERF_EXTRA128:-}" ] && list="$list 128"
    for c in $list; do
        config put 1MiB "$c" 8192
        config get 1MiB "$c" 8192
    done
}
series_mixed() {
    local r
    echo "##### configuration mixed_1MiB_c16"
    run_warp mixed_1MiB_c16_warm warm mixed 1MiB 16 "$WARM" --objects=2000
    for r in 1 2 3; do run_warp "mixed_1MiB_c16_r$r" run mixed 1MiB 16 "$DUR" --objects=2000; done
    clean_bucket
}

summarize() {
    {
        echo "run summary (Report and Average lines and any error line of each run; the full text is in console/)"
        local f
        for f in "$OUT"/console/*.txt; do
            echo "-- $(basename "$f" .txt)"
            grep -m12 -E "^Report:|Average:|Errors:|rror" "$f" || echo "   no summary line found"
        done
    } > "$OUT/summary.txt"
    cat "$OUT/summary.txt"
}

finish() {
    monitor_stop
    echo "== end of run"
    echo "secret key found in output files (must be 0): $(grep -rlF "$SK" "$OUT" 2>/dev/null | wc -l)"
    echo "access key found in output files (must be 0): $(grep -rlF "$AK" "$OUT" 2>/dev/null | wc -l)"
    ( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
    tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
    echo "archive: $OUT.tar.gz $(stat -c %s "$OUT.tar.gz") bytes"
    sha256sum "$OUT.tar.gz"
}

preflight() {
    local flag opcmd missing=0 ip code
    echo "== tools"
    warp --version 2>&1 | head -1
    if [ -z "${PERF_TEST:-}" ]; then
        warp --version 2>&1 | grep -q "1\.8\.0" || echo "WARNING: warp is not 1.8.0, the method names 1.8.0"
    fi
    "$AWSBIN" --version 2>&1 | head -1
    command -v sar >/dev/null && echo "sar present on this node" || echo "sar MISSING on this node"
    command -v iperf3 >/dev/null && echo "iperf3 present on this node" || echo "iperf3 MISSING on this node"
    echo "== warp flags used by this script (from warp --help, not from memory)"
    for opcmd in put get mixed; do
        for flag in --host --region --bucket --obj.size --concurrent --duration --benchdata --no-color; do
            warp "$opcmd" --help 2>&1 | grep -q -- "$flag" || { echo "MISSING in warp $opcmd: $flag"; missing=1; }
        done
    done
    for flag in --objects --noclear "$LISTEX"; do
        warp get --help 2>&1 | grep -q -- "$flag" || { echo "MISSING in warp get: $flag"; missing=1; }
    done
    warp mixed --help 2>&1 | grep -q -- "--objects" || { echo "MISSING in warp mixed: --objects"; missing=1; }
    [ "$missing" = 0 ] && echo "all flags present"
    echo "== endpoints (unsigned GET /, any answer except 000 means the port is open)"
    for ip in ${HOSTS//,/ }; do
        code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$ip/" || true)"
        echo "$ip -> $code"
    done
    echo "== ssh to the other storage nodes: $SSH_OK (1 = works)"
    echo "== bucket $BUCKET"
    if ! s3 s3 ls "s3://$BUCKET" >/dev/null 2>&1; then
        s3 s3 mb "s3://$BUCKET" 2>&1 | tail -2 || true
    fi
    s3 s3 ls "s3://$BUCKET" >/dev/null 2>&1 && echo "bucket reachable" || echo "bucket NOT reachable (garage: create it with the garage CLI and allow the key)"
    echo "== smoke tests (20 s, 1 MiB, concurrency 4; not measurements)"
    run_warp smoke_put smoke put 1MiB 4 20
    clean_bucket
    run_warp smoke_get_prepare smoke get 1MiB 4 10 --objects=300 --noclear
    run_warp smoke_get_listed smoke get 1MiB 4 10 $LISTEX --noclear
    clean_bucket
    echo "== smoke test, one 100 MiB object path (multipart): 15 s, concurrency 2"
    run_warp smoke_put_100MiB smoke put 100MiB 2 15
    clean_bucket
    summarize
    echo "== runs.tsv (exit column must be 0 everywhere)"
    cat "$RUNS"
}

controls() {
    local ip
    echo "== disk reference: 2 GiB dd with oflag=direct and conv=fsync on a scratch file on /srv/s3/disk1 of each node"
    on_nodes 'hostname; dd if=/dev/zero of=/srv/s3/disk1/perf-ref.bin bs=1M count=2048 oflag=direct conv=fsync 2>&1 | tail -1; rm -f /srv/s3/disk1/perf-ref.bin; ls /srv/s3/disk1/perf-ref.bin 2>&1 | head -1'
    echo "== network: iperf3 10 s from this node to the other storage nodes"
    command -v iperf3 >/dev/null || { echo "iperf3 missing"; return 0; }
    for ip in $NODES; do
        [ "$ip" = "$SELF" ] && continue
        printf 'iperf3 -s -1 -D\n' | node_sh "$ip" >/dev/null 2>&1 || { echo "$ip: could not start iperf3 server"; continue; }
        sleep 2
        echo "-- to $ip"
        iperf3 -c "$ip" -t 10 2>&1 | tail -4
    done
}

case "$MODE" in
    preflight) monitor_start; preflight; finish ;;
    controls)  controls 2>&1 | tee "$OUT/controls.txt"; finish ;;
    size)      monitor_start; series_size; summarize; finish ;;
    conc)      monitor_start; series_conc; summarize; finish ;;
    mixed)     monitor_start; series_mixed; summarize; finish ;;
    all)       monitor_start; series_size; series_conc; series_mixed; summarize; finish ;;
    one)
        [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] || die "usage: $0 $SYSTEM one put|get|mixed 1MiB 4"
        monitor_start
        if [ "$3" = get ]; then
            run_warp "one_get_prepare" warm get "$4" "$5" "$WARM" --objects=300 --noclear
            run_warp "one_get" run get "$4" "$5" "$DUR" $LISTEX --noclear
            clean_bucket
        else
            run_warp "one_$3" run "$3" "$4" "$5" "$DUR"
        fi
        summarize; finish ;;
    *) die "unknown mode '$MODE'" ;;
esac
