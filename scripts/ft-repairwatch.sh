#!/usr/bin/env bash
# ft-repairwatch.sh : per drive count of the probe objects of one fault tolerance run (repair after an outage)
#
# usage: bash ft-repairwatch.sh <run dir of ft.sh> [rustfs|seaweedfs|garage]   (start it while the scenario runs, it stops by itself)
#
# Mode garage: Garage splits objects into blocks named by their hash, so the blocks of one run cannot be found by the key
# prefix. The counts are therefore the whole data directories of Garage on every node (default
# /srv/s3/disk1/garage/data and /srv/s3/disk2/garage/data, override with RW_DIRS): per data dir the number of first level
# folders, the number of files and the bytes. The seed set and every earlier run are included, so only the differences
# between the nodes and over time matter (a node that was down stays behind until the Garage resync has copied the
# missing blocks). A node that does not answer ssh is written as DOWN. Nothing is written to the directories.
#
# Mode seaweedfs (second argument): SeaweedFS keeps data in volumes, not in one folder per object, so the counts come from
# the volume server status of every node (http://<node>:8080/status, read from ceph0, no ssh): per disk id the number of
# volumes, the sum of FileCount and the sum of Size of the volumes of the collection ftbucket (the bucket of the run; it
# holds the seed set and every earlier run, so only the differences between the nodes and over time matter). A node
# whose status does not answer is written as DOWN. Columns then mean: data dir = disk<id>, object folders = volumes.
# Settings: RW_PORT (default 8080), RW_COLLECTION (default ftbucket).
#
# Mode ceph (added 15 October 2026): Ceph repairs by itself and reports it, so no files are counted. Every RW_INTERVAL seconds ceph0 (RW_SELF) runs
# "timeout 20 cephadm shell -- ceph status -f json" (read only; without mon quorum the call times out and the row says NOQUORUM) and writes one row:
# epoch, time, health, osds up, osds in, osds total, pgs total, pgs active+clean, degraded objects, misplaced objects, objects, acked writes so far
# (output <run dir>/repairwatch.tsv, different columns from the other modes). The key prefix file is only checked for existence.
#
# Reads the key prefix of the run from <run dir>/prefix (written by scripts/ft.sh from commit f330983 on), and every
# RW_INTERVAL seconds (default 20) counts, on every node and every data directory, the object folders, the files and the
# bytes under <data dir>/<prefix>. A node that does not answer ssh is written as DOWN. The acknowledged writes of the
# ledger of the run are written in the last column, so that the counts can be compared with what was acknowledged.
# It stops when <run dir>/stop exists (ft.sh creates it at the end of its recovery watch) after one last sample.
# Output: <run dir>/repairwatch.tsv (epoch, time, node, data dir, object folders, files, bytes, acked so far).
# It only reads. Settings by environment: RW_NODES, RW_DIRS, RW_INTERVAL, RW_SELF, RW_LOCAL (run everything locally, for tests).

set -u
D="${1:-}"
[ -n "$D" ] && [ -d "$D" ] || { echo "usage: $0 <run dir of ft.sh>" >&2; exit 1; }
SYS="${2:-rustfs}"
case "$SYS" in rustfs|seaweedfs|garage|ceph) ;; *) echo "second argument: rustfs, seaweedfs, garage or ceph" >&2; exit 1 ;; esac
[ -s "$D/prefix" ] || { echo "no $D/prefix (run made with a script older than f330983?)" >&2; exit 1; }
P="$(cat "$D/prefix")"
PORT="${RW_PORT:-8080}"
COLL="${RW_COLLECTION:-ftbucket}"
PYSW='
import sys, json
d = json.load(sys.stdin)
a = {}
for v in d.get("Volumes", []):
    if v.get("Collection") == sys.argv[1]:
        t = a.setdefault(v.get("DiskId", 0), [0, 0, 0])
        t[0] += 1
        t[1] += v.get("FileCount", 0)
        t[2] += v.get("Size", 0)
if not a:
    print("none 0 0 0")
for k in sorted(a):
    print("disk%s %d %d %d" % (k, a[k][0], a[k][1], a[k][2]))
'
NODES="${RW_NODES:-192.168.1.72 192.168.1.71 192.168.1.70}"
if [ "$SYS" = garage ]; then
    DIRS="${RW_DIRS:-/srv/s3/disk1/garage/data /srv/s3/disk2/garage/data}"
    SUB=""
else
    DIRS="${RW_DIRS:-/srv/s3/disk1/rustfs/ftbucket /srv/s3/disk2/rustfs/ftbucket}"
    SUB="/$P"
fi
INTERVAL="${RW_INTERVAL:-20}"
SELF="${RW_SELF:-192.168.1.72}"
SSHOPT="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new"
OUT="$D/repairwatch.tsv"

# one remote command prints, per data dir: dir, object folders, files, bytes
REMOTE='for d in '"$DIRS"'; do
  p="$d'"$SUB"'"
  if [ -d "$p" ]; then
    echo "$d $(find "$p" -mindepth 1 -maxdepth 1 -type d | wc -l) $(find "$p" -type f | wc -l) $(du -sb "$p" | cut -f1)"
  else
    echo "$d 0 0 0"
  fi
done'

rx() { # node command
    if [ "$1" = "$SELF" ] || [ -n "${RW_LOCAL:-}" ]; then bash -c "$2"; else ssh $SSHOPT "root@$1" "$2"; fi
}

sample() {
    local n now t acked out line
    now="$(date +%s)"; t="$(date +%T)"
    acked="$(awk -F'\t' '$4=="ACK"' "$D/ledger.tsv" 2>/dev/null | wc -l)"
    for n in $NODES; do
        if [ "$SYS" = seaweedfs ]; then
            out="$(curl -s -m 5 "http://$n:$PORT/status" 2>/dev/null | python3 -c "$PYSW" "$COLL" 2>/dev/null)" || out=""
        else
            out="$(rx "$n" "$REMOTE" 2>/dev/null)" || out=""
        fi
        if [ -n "$out" ]; then
            while read -r line; do
                set -- $line
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$t" "$n" "$1" "$2" "$3" "$4" "$acked" >> "$OUT"
            done <<< "$out"
        else
            printf '%s\t%s\t%s\tDOWN\t\t\t\t%s\n' "$now" "$t" "$n" "$acked" >> "$OUT"
        fi
    done
}

PYCEPH='
import sys, json
try:
    d = json.load(sys.stdin)
    o = d.get("osdmap", {}); o = o.get("osdmap", o)
    g = d.get("pgmap", {})
    clean = sum(s.get("count", 0) for s in g.get("pgs_by_state", []) if s.get("state_name") == "active+clean")
    print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (d.get("health", {}).get("status", "n/a"), o.get("num_up_osds", "n/a"), o.get("num_in_osds", "n/a"), o.get("num_osds", "n/a"),
          g.get("num_pgs", "n/a"), clean, g.get("degraded_objects", 0), g.get("misplaced_objects", 0), g.get("num_objects", "n/a")))
except Exception:
    print("PARSEFAIL\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a")
'
sample_ceph() {
    local now t acked raw out
    now="$(date +%s)"; t="$(date +%T)"
    acked="$(awk -F'\t' '$4=="ACK"' "$D/ledger.tsv" 2>/dev/null | wc -l)"
    raw="$(rx "$SELF" "timeout 20 cephadm shell -- ceph status -f json 2>/dev/null" 2>/dev/null)" || raw=""
    if [ -n "$raw" ]; then out="$(printf '%s' "$raw" | python3 -c "$PYCEPH" 2>/dev/null)" || out=""; else out=""; fi
    [ -n "$out" ] || out="$(printf 'NOQUORUM\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a')"
    printf '%s\t%s\t%s\t%s\n' "$now" "$t" "$out" "$acked" >> "$OUT"
}
if [ "$SYS" = ceph ]; then
    printf 'epoch\ttime\thealth\tosds_up\tosds_in\tosds_total\tpgs_total\tpgs_active_clean\tdegraded_objects\tmisplaced_objects\tobjects\tacked_so_far\n' > "$OUT"
    echo "repairwatch: system ceph, run dir $D, via $SELF, every $INTERVAL s, output $OUT"
    while :; do
        sample_ceph
        [ -e "$D/stop" ] && break
        sleep "$INTERVAL"
    done
    sample_ceph
    echo "repairwatch: stopped at $(date +%T), $(( $(wc -l < "$OUT") - 1 )) rows"
    exit 0
fi

printf 'epoch\ttime\tnode\tdata_dir\tobject_folders\tfiles\tbytes\tacked_so_far\n' > "$OUT"
echo "repairwatch: system $SYS, run dir $D, prefix $P, nodes $NODES, every $INTERVAL s, output $OUT"
while :; do
    sample
    [ -e "$D/stop" ] && break
    sleep "$INTERVAL"
done
sample
echo "repairwatch: stopped at $(date +%T), $(( $(wc -l < "$OUT") - 1 )) rows"
