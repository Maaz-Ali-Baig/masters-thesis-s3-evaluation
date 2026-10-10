#!/usr/bin/env bash
#
# Fault tolerance tooling for ONE system, as described in fault_tolerance_method.md. Run as root on ceph0
# (the node that is never stopped) while the system under test runs on all three VMs.
#
#   bash ft.sh <system> seed             write the seed set once (40 x 1 MiB, 3 x 6 MiB, 1 x 100 MiB) with sha256
#   bash ft.sh <system> preflight        endpoints, ssh to ceph1 and ceph2, node scripts, status commands (no failure)
#   bash ft.sh <system> scenario S1|S2   S1: ceph1 hard stopped, S2: ceph1 and ceph2 hard stopped
#   bash ft.sh <system> probe <dir>      (used by scenario) probe loop until <dir>/stop exists
#   bash ft.sh <system> verify <dir>     read every acknowledged object and the seed set through every endpoint
#   bash ft.sh <system> summary <dir>    times and counts from the ledger and the probe log
#
#   system   rustfs | seaweedfs | garage | ceph
#
# The VM hard stop and power on are done by the user in Proxmox. The script prints "ACTION NOW" lines and waits
# (it detects the stop by the endpoint going silent and the boot by ssh answering). After the boot it starts the
# system on the returned node with the node script of the system (ceph starts by itself). The failure time is
# bracketed by the probe (last answer to first silence), not taken from the clicks.
#
# Needs: key based ssh from ceph0 to ceph1 and ceph2 (BatchMode), the key file of the system on ceph0, the AWS CLI.
# Keys are read from the key file and never printed. Output: /root/ft-<system>-<scenario>-<time>/ and a .tar.gz.
# Test only variables: FT_HOSTS (list of host:port), FT_KEYFILE, FT_BASE, FT_OUTAGE.

set -eu

SYSTEM="${1:-}"
MODE="${2:-}"
die() { echo "ft: $*" >&2; exit 1; }

case "$SYSTEM" in
    rustfs)    KEYFILE=/root/rustfs-config/s3_credentials.txt;    AKL="Access key"; SKL="Secret key"; PORT=9000; REGION=us-east-1
               START="bash /root/rustfs-deploy/rustfs-node.sh";       DATA="rustfs" ;;
    seaweedfs) KEYFILE=/root/seaweedfs-config/s3_credentials.txt; AKL="Access key"; SKL="Secret key"; PORT=8333; REGION=us-east-1
               START="bash /root/seaweedfs-deploy/seaweedfs-node.sh"; DATA="seaweedfs" ;;
    garage)    KEYFILE=/root/garage-key.txt;                      AKL="Key ID";     SKL="Secret key"; PORT=3900; REGION=garage
               START="bash /root/garage-deploy/garage-node.sh";       DATA="garage" ;;
    ceph)      KEYFILE=/root/ceph-s3-credentials.txt;             AKL="Access key"; SKL="Secret key"; PORT=80;   REGION=us-east-1
               START="";                                              DATA="" ;;
    *) die "usage: $0 rustfs|seaweedfs|garage|ceph seed|preflight|scenario S1|S2|probe dir|verify dir|summary dir" ;;
esac
KEYFILE="${FT_KEYFILE:-$KEYFILE}"
HOSTLIST="${FT_HOSTS:-192.168.1.72:$PORT 192.168.1.71:$PORT 192.168.1.70:$PORT}"
FIRST="${HOSTLIST%% *}"
SELF=192.168.1.72
B=ftbucket
SEED="/root/ft-$SYSTEM-seed"
TS="$(date +%Y%m%d-%H%M%S)"
SSHOPT="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

case "$SYSTEM" in
    rustfs)    STATUS_CMD="curl -s -m 5 -o /dev/null -w 'health %{http_code}' http://localhost:9000/health" ;;
    seaweedfs) STATUS_CMD="curl -s -m 5 http://localhost:9333/cluster/status | head -c 300" ;;
    garage)    STATUS_CMD="podman exec garage /garage -c /etc/garage.toml status 2>&1 | head -12" ;;
    ceph)      STATUS_CMD="cephadm shell -- ceph -s 2>&1 | grep -E 'health|pgs|osd:|mon:'" ;;
esac
STATUS_CMD="${FT_STATUS_CMD:-$STATUS_CMD}"

[ "$(id -u)" = 0 ] || die "run as root"
command -v aws >/dev/null || [ -x /opt/aws-cli-new/bin/aws ] || die "aws cli not found"
export PATH=/opt/aws-cli-new/bin:$PATH
[ -s "$KEYFILE" ] || die "$KEYFILE missing"
AK="$(awk -F': *' -v k="$AKL" '$1==k{print $2}' "$KEYFILE")"
SK="$(awk -F': *' -v k="$SKL" '$1==k{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || die "cannot parse $KEYFILE"
export AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION="$REGION"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
export AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard
export B HOSTLIST

s3ep() { local ep="$1"; shift; aws --endpoint-url "http://$ep" --cli-connect-timeout 3 --cli-read-timeout 25 "$@"; }
clean1() { tr '\t\n' '  ' | cut -c1-150; }
now() { date +%s.%N | cut -c1-14; }
rx() { local ip="$1"; shift; if [ "$ip" = "$SELF" ]; then bash -c "$*"; else ssh $SSHOPT "root@$ip" "$*"; fi; }
live() { local c; c="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$1/" 2>/dev/null || true)"; echo "${c:-000}"; }
export -f s3ep clean1 now

ensure_bucket() {
    s3ep "$FIRST" s3api head-bucket --bucket "$B" >/dev/null 2>&1 || s3ep "$FIRST" s3 mb "s3://$B" >/dev/null 2>&1 || die "bucket $B cannot be made (garage: create it with the garage CLI and allow the key)"
}

# ---------------------------------------------------------------- seed
seed() {
    local n key size sha
    mkdir -p "$SEED"
    if [ -s "$SEED/seed.tsv" ]; then echo "seed set exists: $SEED/seed.tsv ($(wc -l < "$SEED/seed.tsv") objects)"; return 0; fi
    ensure_bucket
    : > "$SEED/seed.tsv.part"
    put_seed() { # key size
        head -c "$2" /dev/urandom > "$SEED/tmp.bin"
        sha="$(sha256sum "$SEED/tmp.bin" | cut -d' ' -f1)"
        s3ep "$FIRST" s3 cp "$SEED/tmp.bin" "s3://$B/$1" --only-show-errors >/dev/null || die "upload of $1 failed"
        printf '%s\t%s\t%s\n' "$1" "$2" "$sha" >> "$SEED/seed.tsv.part"
    }
    put_seed fixed/head.bin 1024
    for n in $(seq 1 40); do put_seed "seed/1MiB-$n" 1048576; done
    for n in 1 2 3; do put_seed "seed/6MiB-$n" 6291456; done
    put_seed seed/100MiB-1 104857600
    rm -f "$SEED/tmp.bin"
    mv "$SEED/seed.tsv.part" "$SEED/seed.tsv"
    echo "seed set written: $(wc -l < "$SEED/seed.tsv") objects, $SEED/seed.tsv sha256 $(sha256sum "$SEED/seed.tsv" | cut -d' ' -f1)"
}

# ---------------------------------------------------------------- probe
probe() {
    local d="$1" i=0 n ep idx k rc sha err c0 ep_list acked
    set -- $HOSTLIST; n=$#
    mkdir -p "$d"
    printf 'epoch\tendpoint\tlive_code\thead_object\n' > "$d/probe.tsv"
    printf 'epoch\tindex\tendpoint\tresult\tsha256\terror\n' > "$d/ledger.tsv"
    while [ ! -e "$d/stop" ]; do
        i=$((i+1)); c0="$(date +%s)"
        for ep in $HOSTLIST; do
            (
                c="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$ep/" 2>/dev/null || true)"; c="${c:-000}"
                if s3ep "$ep" s3api head-object --bucket "$B" --key fixed/head.bin >/dev/null 2>&1; then h=READ_OK; else h=READ_FAIL; fi
                printf '%s\t%s\t%s\t%s\n' "$(now)" "$ep" "$c" "$h" >> "$d/probe.tsv"
            ) &
        done
        wait
        head -c 1048576 /dev/urandom > "$d/obj.tmp"
        sha="$(sha256sum "$d/obj.tmp" | cut -d' ' -f1)"
        acked=0
        for k in $(seq 0 $((n-1))); do
            idx=$(( ((i-1) + k) % n + 1 ))
            ep="$(echo $HOSTLIST | cut -d' ' -f$idx)"
            if err="$(s3ep "$ep" s3 cp "$d/obj.tmp" "s3://$B/probe/$i" --only-show-errors 2>&1)"; then rc=0; else rc=1; fi
            if [ "$rc" = 0 ]; then
                printf '%s\t%s\t%s\tACK\t%s\t\n' "$(now)" "$i" "$ep" "$sha" >> "$d/ledger.tsv"; acked=1; break
            fi
            printf '%s\t%s\t%s\tFAIL\t%s\t%s\n' "$(now)" "$i" "$ep" "$sha" "$(echo "$err" | clean1)" >> "$d/ledger.tsv"
        done
        k=$(( 2 - ($(date +%s) - c0) )); [ "$k" -gt 0 ] && sleep "$k"
    done
    rm -f "$d/obj.tmp"
}

# ---------------------------------------------------------------- verify
verify_one() { # endpoint key expected-sha
    local got st
    got="$(s3ep "$1" s3 cp "s3://$B/$2" - 2>/dev/null | sha256sum | cut -d' ' -f1)"
    if [ "$got" = "$3" ]; then st=OK
    elif [ "$got" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then st=ERROR_OR_EMPTY
    else st=MISMATCH; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$got" "$st"
}
export -f verify_one

verify() {
    local d="$1" ep list="$1/verify-keys.tsv" eps="${2:-$HOSTLIST}"
    [ -s "$SEED/seed.tsv" ] || die "no seed set, run seed first"
    { cut -f1,3 "$SEED/seed.tsv"; awk -F'\t' '$4=="ACK"{print "probe/" $2 "\t" $5}' "$d/ledger.tsv" 2>/dev/null; } > "$list"
    : > "$d/verify.tsv"
    for ep in $eps; do
        echo "verify through $ep: $(wc -l < "$list") objects"
        xargs -a "$list" -P 6 -L1 bash -c 'verify_one "$0" "$1" "$2"' "$ep" 2>/dev/null >> "$d/verify.tsv" || true
    done
    echo "== verify result per endpoint (status, count)"
    awk -F'\t' '{c[$1 " " $5]++} END{for(k in c) print k, c[k]}' "$d/verify.tsv" | sort
}

# ---------------------------------------------------------------- summary
hhmmss() { if [ -n "${1:-}" ] && [ "$1" != 0 ]; then date -d "@${1%.*}" +%T; else echo "none"; fi; }
summary() {
    local d="$1" a f ff lf mg at e t
    {
        echo "== ledger"
        read -r a f ff lf mg at <<< "$(awk -F'\t' 'NR>1{ if($4=="ACK"){a++; if(la>0 && $1-la>mg){mg=$1-la; at=la} la=$1} else {f++; if(!ff) ff=$1; lf=$1} }
            END{printf "%d %d %s %s %.1f %s\n", a, f, (ff?ff:0), (lf?lf:0), mg, (at?at:0)}' "$d/ledger.tsv")"
        echo "acknowledged writes $a, failed attempts $f"
        echo "first failed attempt $(hhmmss "$ff"), last failed attempt $(hhmmss "$lf")"
        echo "longest gap between acknowledged writes $mg s (after $(hhmmss "$at"))"
        echo "== endpoint state changes (live code 000 = no answer, head_object READ_FAIL = cannot read the fixed object)"
        awk -F'\t' 'NR>1{ s=($3=="000")?"SILENT":"ANSWERS"; if(s!=ls[$2]){ if(ls[$2]!="") printf "%s\t%s live: %s\n", $1, $2, s; ls[$2]=s }
                       r=$4; if(r!=lr[$2]){ if(lr[$2]!="") printf "%s\t%s head_object: %s\n", $1, $2, r; lr[$2]=r } }' "$d/probe.tsv" \
        | sort -n | while IFS=$'\t' read -r e t; do echo "$(hhmmss "$e") $t"; done
    } | tee "$d/summary.txt"
}

# ---------------------------------------------------------------- scenario
watch_once() { # file; one sample of bytes and status
    local ip bytes
    for ip in 192.168.1.72 192.168.1.71 192.168.1.70; do
        if [ -n "$DATA" ]; then
            bytes="$(rx "$ip" "du -sb /srv/s3/disk1/$DATA /srv/s3/disk2/$DATA 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null || echo na)"
        else bytes=na; fi
        printf '%s\t%s\tbytes\t%s\n' "$(now)" "$ip" "${bytes:-na}" >> "$1"
    done
    printf '%s\t%s\tstatus\t%s\n' "$(now)" "$SELF" "$(bash -c "$STATUS_CMD" 2>&1 | tr '\t\n' '  ' | cut -c1-260)" >> "$1"
}

scenario() {
    local sc="${1:-}" D TARGETS OUTAGE BASE ip t0 tdown tup w stable_n last cur pid
    case "$sc" in
        S1) TARGETS="192.168.1.71"; OUTAGE="${FT_OUTAGE:-720}" ;;
        S2) TARGETS="192.168.1.71 192.168.1.70"; OUTAGE="${FT_OUTAGE:-360}" ;;
        *) die "scenario S1 or S2" ;;
    esac
    BASE="${FT_BASE:-300}"
    D="/root/ft-$SYSTEM-$sc-$TS"; mkdir -p "$D"
    exec > >(tee -a "$D/console.txt") 2>&1
    trap 'touch "$D/stop"' EXIT
    echo "host: $(hostname)  system: $SYSTEM  scenario: $sc  time: $(date '+%F %T %z')  output: $D"
    echo "targets: $TARGETS  baseline: $BASE s  outage: $OUTAGE s  hosts: $HOSTLIST"
    echo "aws: $(aws --version 2>&1 | head -1)  checksum setting: when_required, retries off"
    [ -s "$SEED/seed.tsv" ] || die "no seed set, run: bash ft.sh $SYSTEM seed"
    for ip in $TARGETS; do rx "$ip" true >/dev/null 2>&1 || die "ssh to $ip does not work (BatchMode)"; done
    for ip in $HOSTLIST; do [ "$(live "$ip")" != 000 ] || die "endpoint $ip does not answer before the test"; done
    ensure_bucket
    echo "== state before"; watch_once "$D/watch.tsv"; cat "$D/watch.tsv" | cut -c1-200
    probe "$D" &
    pid=$!
    echo "== baseline running ($BASE s), probe pid $pid"; sleep "$BASE"
    echo "== ACTION NOW: hard stop (power off, not shutdown) in Proxmox: $TARGETS   [$(date +%T)]"
    t0="$(date +%s)"
    while :; do
        w=0; for ip in $TARGETS; do [ "$(live "$ip:$PORT")" = 000 ] && w=$((w+1)); done
        [ "$w" -eq $(echo $TARGETS | wc -w) ] && break
        [ $(( $(date +%s) - t0 )) -gt 1200 ] && { touch "$D/stop"; die "no stop seen after 20 minutes"; }
        sleep 3
    done
    tdown="$(date +%s)"; echo "== all targets silent at $(date -d @$tdown +%T) (waited $((tdown - t0)) s for the user)"
    sleep 60
    echo "== during the outage: seed set read through the surviving endpoint"
    verify "$D" "$FIRST" | tail -4
    cp "$D/verify.tsv" "$D/verify-during-outage.tsv"
    w=$(( tdown + OUTAGE - $(date +%s) )); [ "$w" -gt 0 ] && sleep "$w"
    echo "== ACTION NOW: power on in Proxmox: $TARGETS   [$(date +%T)]"
    t0="$(date +%s)"
    for ip in $TARGETS; do
        until rx "$ip" true >/dev/null 2>&1; do
            [ $(( $(date +%s) - t0 )) -gt 900 ] && { touch "$D/stop"; die "$ip does not answer ssh after 15 minutes"; }
            sleep 5
        done
        echo "== ssh answers on $ip at $(date +%T)"
        if [ -n "$START" ]; then
            rx "$ip" "$START" > "$D/start-$ip.log" 2>&1 || echo "start command on $ip returned an error, see start-$ip.log"
            echo "== start command finished on $ip at $(date +%T)"
        else
            echo "== $SYSTEM starts by itself (systemd), nothing to run on $ip"
        fi
    done
    echo "== recovery watch every 20 s (until bytes are stable for 180 s, or 30 minutes)"
    stable_n=0; last=""; t0="$(date +%s)"
    while [ $(( $(date +%s) - t0 )) -lt 1800 ]; do
        watch_once "$D/watch.tsv"
        cur="$(grep -P '\tbytes\t' "$D/watch.tsv" | tail -3 | cut -f2,4 | tr '\n' ' ')"
        if [ -n "$DATA" ]; then
            if [ "$cur" = "$last" ]; then stable_n=$((stable_n+1)); else stable_n=0; fi
            last="$cur"
            [ "$stable_n" -ge 9 ] && { echo "== bytes stable for 180 s at $(date +%T)"; break; }
        else
            tail -1 "$D/watch.tsv" | grep -q HEALTH_OK && { echo "== HEALTH_OK at $(date +%T)"; break; }
        fi
        sleep 20
    done
    touch "$D/stop"; wait "$pid" 2>/dev/null || true
    echo "== full verification through all endpoints"
    verify "$D"
    summary "$D"
    ( cd "$D" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
    echo "secret key found in output files (must be 0): $(grep -rlF "$SK" "$D" 2>/dev/null | wc -l)"
    tar czf "$D.tar.gz" -C "$(dirname "$D")" "$(basename "$D")"
    echo "archive: $D.tar.gz $(stat -c %s "$D.tar.gz") bytes"; sha256sum "$D.tar.gz"
}

preflight() {
    local ip
    echo "host: $(hostname)  system: $SYSTEM  hosts: $HOSTLIST  time: $(date '+%F %T')"
    for ip in $HOSTLIST; do echo "endpoint $ip -> $(live "$ip")"; done
    for ip in 192.168.1.71 192.168.1.70; do
        if rx "$ip" "hostname" >/dev/null 2>&1; then echo "ssh to $ip: ok ($(rx "$ip" hostname))"; else echo "ssh to $ip: FAILED"; fi
        [ -n "$START" ] && { rx "$ip" "test -f ${START#bash }" 2>/dev/null && echo "node script present on $ip" || echo "node script MISSING on $ip: ${START#bash }"; }
    done
    echo "== status command on this node: $STATUS_CMD"
    bash -c "$STATUS_CMD" 2>&1 | cut -c1-200 | head -14
    ensure_bucket && echo "bucket $B ok"
    echo "seed set: $([ -s "$SEED/seed.tsv" ] && echo present || echo absent)"
}

case "$MODE" in
    seed)      seed ;;
    preflight) preflight ;;
    scenario)  scenario "${3:-}" ;;
    probe)     [ -n "${3:-}" ] || die "probe <dir>"; probe "$3" ;;
    verify)    [ -n "${3:-}" ] || die "verify <dir>"; verify "$3" ;;
    summary)   [ -n "${3:-}" ] || die "summary <dir>"; summary "$3" ;;
    *) die "unknown mode '$MODE'" ;;
esac
