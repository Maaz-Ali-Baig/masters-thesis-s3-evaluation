#!/usr/bin/env bash
#
# Security checks for ONE system, as described in security_method.md. Run as root on ceph0 while the system
# under test runs on all three VMs.
#
#   bash sec.sh <system> <check>
#
#   system   rustfs | seaweedfs | garage | ceph
#   check    sec1   listening ports on every node and what answers without credentials (GET of a list of paths,
#                   anonymous PUT and DELETE on the S3 port)
#            sec2   anonymous write through the non S3 ports that answered (SeaweedFS: master assign, volume server)
#            sec3   authentication: wrong secret, wrong access key, no signature
#            sec4   scoped key: needs SCOPED_AK, SCOPED_SK and SCOPED_BUCKET in the environment (key made beforehand
#                   with the admin tool of the system, the creation commands are recorded by hand); optional SCOPED_OTHER = a
#                   second existing bucket without permission for the scoped key (Garage: the admin key needs read and write on both buckets)
#            sec5   transport: is the object content visible on the wire (tcpdump, one upload to another node)
#            sec6   encryption at rest: marker objects (plain, SSE-S3, SSE-C), marker search in the data directories
#            sec8   visibility of the failed attempts of sec3 in the container logs
#            all    sec1, sec2, sec3, sec5, sec6, sec8 (sec4 only when the SCOPED_* variables are set)
#
# Keys are read from the key file and never printed. A fake access key is used for the failed attempts (so that
# sec8 can search for it). The state changes (objects, markers) are removed at the end of each check.
# Output: /root/sec-<system>-<time>/ with one text file per check, summary.txt, SHA256SUMS and the .tar.gz.
# Test only variables: SEC_HOSTS, SEC_NODES (node list, local only when it holds ceph0 alone), SEC_KEYFILE.

set -eu

SYSTEM="${1:-}"
CHECK="${2:-}"
die() { echo "sec: $*" >&2; exit 1; }

case "$SYSTEM" in
    rustfs)    KEYFILE=/root/rustfs-config/s3_credentials.txt;    AKL="Access key"; SKL="Secret key"; PORT=9000; REGION=us-east-1; DATA=rustfs;    CONT='^rustfs$' ;;
    seaweedfs) KEYFILE=/root/seaweedfs-config/s3_credentials.txt; AKL="Access key"; SKL="Secret key"; PORT=8333; REGION=us-east-1; DATA=seaweedfs; CONT='^seaweedfs$' ;;
    garage)    KEYFILE=/root/garage-key.txt;                      AKL="Key ID";     SKL="Secret key"; PORT=3900; REGION=garage;    DATA=garage;     CONT='^garage$' ;;
    ceph)      KEYFILE=/root/ceph-s3-credentials.txt;             AKL="Access key"; SKL="Secret key"; PORT=80;   REGION=us-east-1; DATA="";         CONT='rgw' ;;
    *) die "usage: $0 rustfs|seaweedfs|garage|ceph sec1|sec2|sec3|sec4|sec5|sec6|sec8|all" ;;
esac
KEYFILE="${SEC_KEYFILE:-$KEYFILE}"
PORT="${SEC_PORT:-$PORT}"
DIRS="${SEC_DATADIRS:-/srv/s3/disk1/$DATA /srv/s3/disk2/$DATA}"
NODES="${SEC_NODES-192.168.1.72 192.168.1.71 192.168.1.70}"
S3HOST="${SEC_HOSTS:-192.168.1.72:$PORT}"
OTHER="${SEC_OTHER:-192.168.1.71:$PORT}"
SELF=192.168.1.72
B=ftbucket
OUT="/root/sec-$SYSTEM-$(date +%Y%m%d-%H%M%S)"
SSHOPT="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

[ "$(id -u)" = 0 ] || die "run as root"
export PATH=/opt/aws-cli-new/bin:$PATH
command -v aws >/dev/null || die "aws cli not found"
[ -s "$KEYFILE" ] || die "$KEYFILE missing"
AK="$(awk -F': *' -v k="$AKL" '$1==k{print $2}' "$KEYFILE")"
SK="$(awk -F': *' -v k="$SKL" '$1==k{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || die "cannot parse $KEYFILE"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required AWS_MAX_ATTEMPTS=1
mkdir -p "$OUT"

rx() { local ip="$1"; shift; if [ "$ip" = "$SELF" ] || [ -n "${SEC_LOCAL:-}" ]; then bash -c "$*"; else ssh $SSHOPT "root@$ip" "$*"; fi; }
aws_as() { # ak sk host args...
    local ak="$1" sk="$2" host="$3"; shift 3
    AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_DEFAULT_REGION="$REGION" \
        aws --endpoint-url "http://$host" --cli-connect-timeout 4 --cli-read-timeout 20 "$@" 2>&1
}
code() { curl -s -m "${3:-6}" -X "$1" -o /dev/null -w '%{http_code} %{size_download}' ${4:+--data-binary "$4"} "$2" 2>/dev/null || echo "000 0"; }
cut150() { tr '\t\n' '  ' | cut -c1-150; }
log() { echo "$*" | tee -a "$OUT/$CUR.txt"; }

header() {
    log "host: $(hostname)  system: $SYSTEM  check: $CUR  time: $(date '+%F %T %z')"
    log "s3 endpoint used: $S3HOST  nodes: ${NODES:-none}"
}

# ------------------------------------------------------------------ sec1
PATHS="/ /health /metrics /status /v1/status /v1/health /cluster/status /dir/status /minio/health/live /minio/health/cluster /rustfs/console/index.html /dashboard /login /api/v1/login /$B"
sec1() {
    CUR=sec1; header
    local ip ports p path r c n
    : > "$OUT/sec1.tsv"
    for ip in $NODES; do
        ports="${SEC_PORTS:-$(rx "$ip" "ss -ltnH | awk '{print \$4}' | sed 's/.*://' | sort -un | tr '\n' ' '" 2>/dev/null || echo "ssh-failed")}"
        log "listening tcp ports on $ip: $ports"
        for p in $ports; do
            [ "$p" = 22 ] && continue
            r="$(code GET "http://$ip:$p/" 4)"
            if [ "${r%% *}" = 000 ]; then printf '%s\t%s\t%s\t%s\n' "$ip" "$p" "/" "no http answer" >> "$OUT/sec1.tsv"; continue; fi
            for path in $PATHS; do
                r="$(code GET "http://$ip:$p$path" 5)"
                printf '%s\t%s\t%s\t%s\n' "$ip" "$p" "$path" "$r" >> "$OUT/sec1.tsv"
            done
        done
    done
    log "== answers without credentials (node, port, path, http code, bytes): only code 200 with bytes, or 3xx"
    awk -F'\t' '{split($4,a," "); if((a[1]==200 && a[2]>0) || a[1] ~ /^3/) print}' "$OUT/sec1.tsv" | tee -a "$OUT/sec1.txt"
    log "== S3 port, anonymous PUT and DELETE of a bucket path (a refusal is the pass)"
    for ip in $NODES; do
        c="$(code PUT "http://$ip:$PORT/$B/secprobe-anon.txt" 6 x)"
        n="$(code DELETE "http://$ip:$PORT/$B/secprobe-anon.txt" 6)"
        log "$ip:$PORT PUT $c   DELETE $n"
    done
    log "full table: sec1.tsv ($(wc -l < "$OUT/sec1.tsv") rows)"
}

# ------------------------------------------------------------------ sec2
sec2() {
    CUR=sec2; header
    local ip p r put get del a fid url
    printf 'secprobe marker\n' > "$OUT/marker.tmp"
    log "== anonymous PUT of a marker file to every non S3 port that answered 200 or 3xx on / (PUT, read back, DELETE)"
    if [ ! -s "$OUT/sec1.tsv" ]; then log "sec1.tsv missing, run sec1 first (same run)"; fi
    awk -F'\t' -v s3="$PORT" '$3=="/" {split($4,a," "); if($2!=s3 && (a[1]==200 || a[1] ~ /^3/)) print $1 "\t" $2}' "$OUT/sec1.tsv" 2>/dev/null | sort -u | while IFS=$'\t' read -r ip p; do
        put="$(code PUT "http://$ip:$p/secprobe/marker.txt" 6 "secprobe marker")"
        get="$(code GET "http://$ip:$p/secprobe/marker.txt" 6)"
        del="$(code DELETE "http://$ip:$p/secprobe/marker.txt" 6)"
        echo "$ip:$p PUT $put   GET back $get   DELETE $del" | tee -a "$OUT/sec2.txt"
    done
    if [ "$SYSTEM" = seaweedfs ]; then
        log "== SeaweedFS: anonymous assign on the master, upload and read at the volume server, delete"
        a="$(curl -s -m 6 "http://$SELF:9333/dir/assign" 2>/dev/null || true)"
        fid="$(echo "$a" | sed -n 's/.*"fid":"\([^"]*\)".*/\1/p')"; url="$(echo "$a" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"
        if [ -z "$fid" ]; then log "assign refused or no answer: $(echo "$a" | cut150)"; else
            log "assign gave a file id on $url"
            put="$(curl -s -m 8 -o /dev/null -w '%{http_code}' -F "file=@$OUT/marker.tmp" "http://$url/$fid" 2>/dev/null || echo 000)"
            get="$(code GET "http://$url/$fid" 6)"
            del="$(code DELETE "http://$url/$fid" 6)"
            log "volume server upload $put, anonymous read back $get, delete $del"
        fi
        log "== SeaweedFS: anonymous READ of an existing object through the filer port 8888 (http code and bytes; a 200 with the object size means the S3 login is bypassed for reads) and anonymous listing of /buckets"
        for ip in $NODES; do
            log "filer read of $B/fixed/head.bin on $ip:8888: $(curl -s -m 10 -o /dev/null -w '%{http_code} %{size_download}' "http://$ip:8888/buckets/$B/fixed/head.bin" 2>/dev/null || echo 000)"
        done
        log "filer listing of /buckets as json on $SELF:8888: $(curl -s -m 10 -H 'Accept: application/json' "http://$SELF:8888/buckets/?limit=100" 2>/dev/null | grep -o '"FullPath":"[^"]*"' | wc -l) entries"
    fi
    rm -f "$OUT/marker.tmp"
}

# ------------------------------------------------------------------ sec3
FAKE="SECPROBE$(date +%s)FAKE"
sec3() {
    CUR=sec3; header
    local r
    echo "$FAKE" > "$OUT/fakekey.txt"
    log "fake access key used for the failed attempts (not a real key): $FAKE"
    r="$(aws_as "$AK" "WRONGSECRETWRONGSECRETWRONGSECRET0000" "$S3HOST" s3 ls "s3://$B/" | cut150)"; log "right access key, wrong secret: $r"
    r="$(aws_as "$FAKE" "WRONGSECRETWRONGSECRETWRONGSECRET0000" "$S3HOST" s3 ls "s3://$B/" | cut150)"; log "fake access key, wrong secret: $r"
    r="$(aws_as "$FAKE" "WRONGSECRETWRONGSECRETWRONGSECRET0000" "$S3HOST" s3api list-buckets | cut150)"; log "fake key, list buckets: $r"
    log "no signature: GET bucket $(code GET "http://$S3HOST/$B" 6), GET object $(code GET "http://$S3HOST/$B/fixed/head.bin" 6), PUT object $(code PUT "http://$S3HOST/$B/secprobe-nosig.txt" 6 x)"
    log "(pass: every line is a refusal, such as 403, SignatureDoesNotMatch, InvalidAccessKeyId)"
}

# ------------------------------------------------------------------ sec4
sec4() {
    CUR=sec4; header
    [ -n "${SCOPED_AK:-}" ] && [ -n "${SCOPED_SK:-}" ] && [ -n "${SCOPED_BUCKET:-}" ] || die "set SCOPED_AK, SCOPED_SK and SCOPED_BUCKET (key limited to read of that bucket)"
    local r other="${SCOPED_OTHER:-secother$(date +%s)}"
    printf 'scoped key test\n' > "$OUT/scoped.tmp"
    # SCOPED_OTHER (optional): name of an existing second bucket that the scoped key has no permission on; needed for Garage, where a bucket made through the
    # S3 API only gets a local alias of the creating key and the scoped key cannot resolve its name (a 404 instead of the refusal that is meant to be tested)
    [ -n "${SCOPED_OTHER:-}" ] || aws_as "$AK" "$SK" "$S3HOST" s3 mb "s3://$other" >/dev/null || true
    r="$(aws_as "$AK" "$SK" "$S3HOST" s3 cp "$OUT/scoped.tmp" "s3://$other/obj.txt" --only-show-errors | cut150)"; log "setup, admin key uploads obj.txt to the other bucket $other: ${r:-ok}"
    r="$(aws_as "$AK" "$SK" "$S3HOST" s3 cp "$OUT/scoped.tmp" "s3://$SCOPED_BUCKET/obj.txt" --only-show-errors | cut150)"; log "setup, admin key uploads obj.txt to the allowed bucket $SCOPED_BUCKET: ${r:-ok}"
    log "scoped key, allowed bucket $SCOPED_BUCKET (the key itself is not printed)"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3 ls "s3://$SCOPED_BUCKET/" | cut150)"; log "list allowed bucket (expect ok): $r"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3 cp "s3://$SCOPED_BUCKET/obj.txt" - | cut150)"; log "read allowed object (expect ok): $r"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3 cp "$OUT/scoped.tmp" "s3://$SCOPED_BUCKET/new.txt" --only-show-errors | cut150)"; log "write to allowed bucket (expect refused): ${r:-ALLOWED}"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3 rm "s3://$SCOPED_BUCKET/obj.txt" | cut150)"; log "delete in allowed bucket (expect refused): ${r:-ALLOWED}"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3 cp "s3://$other/obj.txt" - | cut150)"; log "read another bucket (expect refused): ${r:-ALLOWED}"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3api list-buckets | cut150)"; log "list all buckets (expect refused or only the allowed one): ${r:-EMPTY}"
    r="$(aws_as "$SCOPED_AK" "$SCOPED_SK" "$S3HOST" s3 mb "s3://secnew$(date +%s)" | cut150)"; log "create a bucket (expect refused): ${r:-ALLOWED}"
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$other" --recursive >/dev/null || true
    [ -n "${SCOPED_OTHER:-}" ] || aws_as "$AK" "$SK" "$S3HOST" s3 rb "s3://$other" >/dev/null || true
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$SCOPED_BUCKET/obj.txt" >/dev/null || true
    rm -f "$OUT/scoped.tmp"
    log "cleanup done (other bucket removed, test object removed)"
}

# ------------------------------------------------------------------ sec5
sec5() {
    CUR=sec5; header
    local marker="SECPROBE-WIRE-MARKER-$(date +%s)-ABCDEFGHIJKLMNOP" n pid host
    host="$OTHER"
    command -v tcpdump >/dev/null || { log "tcpdump MISSING on this node: NOT TESTED (decision to install is the user's)"; return 0; }
    for _ in $(seq 1 200); do echo "$marker"; done > "$OUT/wire.tmp"
    timeout 30 tcpdump -i any -nn -s0 -w "$OUT/wire.pcap" "host ${host%%:*} and port ${host##*:}" >/dev/null 2>&1 &
    pid=$!
    sleep 3
    aws_as "$AK" "$SK" "$host" s3 cp "$OUT/wire.tmp" "s3://$B/secprobe-wire.txt" --only-show-errors >/dev/null || log "upload failed"
    sleep 2; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    n="$(grep -c -a "$marker" "$OUT/wire.pcap" 2>/dev/null || true)"
    log "upload of a 200 line marker file to $host over plain http, packets captured on this node"
    log "marker lines found in the capture: ${n:-0}  (above 0 means the content crossed the network in clear)"
    aws_as "$AK" "$SK" "$host" s3 rm "s3://$B/secprobe-wire.txt" >/dev/null || true
    rm -f "$OUT/wire.tmp" "$OUT/wire.pcap"
    log "capture deleted (it holds the access key id in the Authorization header)"
}

# ------------------------------------------------------------------ sec6
# SEC_DISTINCT=1 (added 14 October 2026 for Garage): the three objects get different random content with one marker each, because Garage stores blocks by
# the hash of their content and three uploads of the same content share ONE block file (the search then cannot say which upload is stored in clear).
# Ceph (added 15 October 2026): BlueStore keeps objects on raw devices, so the marker search is a READ ONLY scan of every OSD block device of every node
# (the symlinks /var/lib/ceph/<fsid>/osd.N/block of cephadm, resolved to the logical volume). Each device is read once: zero bytes are turned into new lines
# (tr) so that grep does not have to hold a 32 GB "line", then grep -o prints every marker found and sort | uniq -c counts them. Nothing is written to a device.
# Per node a time box of 1500 s. One output line per device: its marker counts (no line = no marker found on that device).
ceph_scan() { # marker...
    local ip m args=""
    for m in "$@"; do args="$args -e $m"; done   # markers hold only A-Z, 0-9 and - : no quoting needed inside the remote bash -c '...'
    log "Ceph (BlueStore): read only scan of every OSD block device for the markers: $*"
    for ip in $NODES; do
        log "node $ip:"
        rx "$ip" "timeout 1500 bash -c 'for b in /var/lib/ceph/*/osd.*/block; do d=\$(readlink -f \$b); echo \"device \$d\"; tr \"\\\\0\" \"\\\\n\" < \$d | LC_ALL=C grep -a -o -F $args | sort | uniq -c; done'" 2>&1 | sed 's/^/   /' | tee -a "$OUT/sec6.txt" || log "   scan failed on $ip"
    done
    log "(PLAIN is the positive control and must be found on three devices, one per copy, if the object is stored in clear; a marker that is not found is not stored in clear or not stored)"
}
sec6_distinct() {
    CUR=sec6; header
    local base="SECPROBE-REST-MARKER-$(date +%s)-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" ip n k m sse_c_key ext="${SEC_EXT:-txt}"
    log "SEC_DISTINCT: three different random objects with one marker each (-PLAIN, -SSES, -SSEC), 16 KiB random bytes, 4 marker lines, 16 KiB random bytes; object names end in .$ext"
    for k in plain sse ssec; do
        case "$k" in plain) m="$base-PLAIN" ;; sse) m="$base-SSES" ;; ssec) m="$base-SSEC" ;; esac
        { head -c 16384 /dev/urandom; for _ in 1 2 3 4; do echo "$m"; done; head -c 16384 /dev/urandom; } > "$OUT/rest-$k.tmp"
    done
    sse_c_key="$(openssl rand -hex 16)"
    log "plain upload: $(aws_as "$AK" "$SK" "$S3HOST" s3 cp "$OUT/rest-plain.tmp" "s3://$B/secprobe-plain.$ext" --only-show-errors | cut150)"
    log "SSE-S3 upload: $(aws_as "$AK" "$SK" "$S3HOST" s3 cp "$OUT/rest-sse.tmp" "s3://$B/secprobe-sse.$ext" --sse AES256 --only-show-errors | cut150)"
    log "SSE-C upload: $(aws_as "$AK" "$SK" "$S3HOST" s3api put-object --bucket "$B" --key secprobe-ssec.$ext --body "$OUT/rest-ssec.tmp" --sse-customer-algorithm AES256 --sse-customer-key "$sse_c_key" | cut150)"
    log "(an empty text after an upload line means the upload was accepted; an error text means it was refused)"
    sleep 3
    if [ -z "$DATA" ]; then
        ceph_scan "$base-PLAIN" "$base-SSES" "$base-SSEC"
    else
        for k in PLAIN SSES SSEC; do
            for ip in $NODES; do
                n="$(rx "$ip" "grep -rlF '$base-$k' $DIRS 2>/dev/null | wc -l" 2>/dev/null || echo ssh-failed)"
                log "files containing the marker of the $k object on $ip: $n"
                rx "$ip" "grep -rlF '$base-$k' $DIRS 2>/dev/null | head -3 | sed 's/^/   /'" 2>/dev/null | tee -a "$OUT/sec6.txt" || true
            done
        done
        log "(PLAIN is the positive control and must be found; a marker that is found on a node is stored in clear there, a marker that is not found is not stored in clear or not stored)"
    fi
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$B/secprobe-plain.$ext" >/dev/null || true
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$B/secprobe-sse.$ext" >/dev/null || true
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$B/secprobe-ssec.$ext" >/dev/null || true
    rm -f "$OUT/rest-plain.tmp" "$OUT/rest-sse.tmp" "$OUT/rest-ssec.tmp"
    echo "$base" > "$OUT/sec6-marker.txt"
}
sec6() {
    [ -n "${SEC_DISTINCT:-}" ] && { sec6_distinct; return; }
    CUR=sec6; header
    local marker="SECPROBE-REST-MARKER-$(date +%s)-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" ip hits sse_c_key ext="${SEC_EXT:-txt}"
    log "object names end in .$ext (SEC_EXT; SeaweedFS compresses objects with a text name, so a control with SEC_EXT=bin is needed there)"
    if [ "${SEC_PAD:-}" = random ]; then
        # control for stores that compress repetitive data (SeaweedFS): 16 KiB random bytes, 4 marker lines, 16 KiB random bytes (about 33 KB, not compressible)
        { head -c 16384 /dev/urandom; for _ in 1 2 3 4; do echo "$marker"; done; head -c 16384 /dev/urandom; } > "$OUT/rest.tmp"
        log "object content: random padding with 4 marker lines (SEC_PAD=random)"
    else
        for _ in $(seq 1 400); do echo "$marker"; done > "$OUT/rest.tmp"
    fi
    sse_c_key="$(openssl rand -hex 16)"
    aws_as "$AK" "$SK" "$S3HOST" s3 cp "$OUT/rest.tmp" "s3://$B/secprobe-plain.$ext" --only-show-errors | cut150 | sed 's/^/plain upload: /' | tee -a "$OUT/sec6.txt" || true
    log "SSE-S3 upload: $(aws_as "$AK" "$SK" "$S3HOST" s3 cp "$OUT/rest.tmp" "s3://$B/secprobe-sse.$ext" --sse AES256 --only-show-errors | cut150)"
    log "SSE-C upload: $(aws_as "$AK" "$SK" "$S3HOST" s3api put-object --bucket "$B" --key secprobe-ssec.$ext --body "$OUT/rest.tmp" --sse-customer-algorithm AES256 --sse-customer-key "$sse_c_key" | cut150)"
    log "(an empty text after an upload line means the upload was accepted; an error text means it was refused)"
    sleep 3
    if [ -z "$DATA" ]; then
        ceph_scan "$marker"
    else
        for ip in $NODES; do
            hits="$(rx "$ip" "grep -rlF '$marker' $DIRS 2>/dev/null | wc -l" 2>/dev/null || echo ssh-failed)"
            log "files containing the marker on $ip (plain + SSE-S3 + SSE-C objects together): $hits"
            rx "$ip" "grep -rlF '$marker' $DIRS 2>/dev/null | head -8 | sed 's/^/   /'" 2>/dev/null | tee -a "$OUT/sec6.txt" || true
        done
        log "(each uploaded object that is NOT encrypted at rest leaves at least one file with the marker on some node; compare the number of files with the number of objects that were stored in clear)"
    fi
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$B/secprobe-plain.$ext" >/dev/null || true
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$B/secprobe-sse.$ext" >/dev/null || true
    aws_as "$AK" "$SK" "$S3HOST" s3 rm "s3://$B/secprobe-ssec.$ext" >/dev/null || true
    rm -f "$OUT/rest.tmp"
    echo "$marker" > "$OUT/sec6-marker.txt"
}

# ------------------------------------------------------------------ sec8
sec8() {
    CUR=sec8; header
    local ip n key
    key="${FAKE}"; [ -s "$OUT/fakekey.txt" ] && key="$(cat "$OUT/fakekey.txt")"
    [ -s "$OUT/fakekey.txt" ] || log "no fakekey.txt in this run: sec3 must run first in the same output folder (SEC_OUT=...); searching for $key"
    for ip in $NODES; do
        n="$(rx "$ip" "for c in \$(podman ps --format '{{.Names}}' | grep -E '$CONT'); do podman logs \$c 2>&1 | grep -c '$key'; done | paste -sd' '" 2>/dev/null || echo ssh-failed)"
        log "log lines containing the fake access key on $ip (one number per matching container): ${n:-none}"
    done
    log "(0 on every node would mean: the failed attempt is not visible in the container log at the default log level; a number above 0 is the count of log lines with the fake key. Only the node that served the request (the S3 endpoint used) is expected to show it. The log time stamps are UTC, the VM clock is UTC+2)"
}

case "$CHECK" in
    sec1) sec1 ;; sec2) sec2 ;; sec3) sec3 ;; sec4) sec4 ;; sec5) sec5 ;; sec6) sec6 ;; sec8) sec8 ;;
    all) sec1; sec2; sec3; sec5; sec6; sec8; [ -n "${SCOPED_AK:-}" ] && sec4 || true ;;
    *) die "unknown check '$CHECK'" ;;
esac

{
    echo "== end of run, output folder $OUT"
    echo "secret key found in output files (must be 0): $(grep -rlF "$SK" "$OUT" 2>/dev/null | wc -l)"
    echo "access key found in output files (must be 0): $(grep -rlF "$AK" "$OUT" 2>/dev/null | wc -l)"
} | tee "$OUT/summary.txt"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "archive: $OUT.tar.gz $(stat -c %s "$OUT.tar.gz") bytes"; sha256sum "$OUT.tar.gz"
