#!/usr/bin/env bash
# ft-repairwatch.sh : per drive count of the probe objects of one fault tolerance run (repair after an outage)
#
# usage: bash ft-repairwatch.sh <run dir of ft.sh>        (start it while the scenario runs, it stops by itself)
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
[ -s "$D/prefix" ] || { echo "no $D/prefix (run made with a script older than f330983?)" >&2; exit 1; }
P="$(cat "$D/prefix")"
NODES="${RW_NODES:-192.168.1.72 192.168.1.71 192.168.1.70}"
DIRS="${RW_DIRS:-/srv/s3/disk1/rustfs/ftbucket /srv/s3/disk2/rustfs/ftbucket}"
INTERVAL="${RW_INTERVAL:-20}"
SELF="${RW_SELF:-192.168.1.72}"
SSHOPT="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new"
OUT="$D/repairwatch.tsv"

# one remote command prints, per data dir: dir, object folders, files, bytes
REMOTE='for d in '"$DIRS"'; do
  p="$d/'"$P"'"
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
        if out="$(rx "$n" "$REMOTE" 2>/dev/null)" && [ -n "$out" ]; then
            while read -r line; do
                set -- $line
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$t" "$n" "$1" "$2" "$3" "$4" "$acked" >> "$OUT"
            done <<< "$out"
        else
            printf '%s\t%s\t%s\tDOWN\t\t\t\t%s\n' "$now" "$t" "$n" "$acked" >> "$OUT"
        fi
    done
}

printf 'epoch\ttime\tnode\tdata_dir\tobject_folders\tfiles\tbytes\tacked_so_far\n' > "$OUT"
echo "repairwatch: run dir $D, prefix $P, nodes $NODES, every $INTERVAL s, output $OUT"
while :; do
    sample
    [ -e "$D/stop" ] && break
    sleep "$INTERVAL"
done
sample
echo "repairwatch: stopped at $(date +%T), $(( $(wc -l < "$OUT") - 1 )) rows"
