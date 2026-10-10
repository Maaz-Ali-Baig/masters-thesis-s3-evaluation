#!/usr/bin/env bash
#
# Resource use per recorded run, from the sar log of ONE node and the runs.tsv of a perf-warp.sh output folder.
# Run it on EACH of the three VMs (the sar log is on the node it was recorded on; runs.tsv is only on ceph2, so
# copy it first: scp root@192.168.1.70:<folder>/runs.tsv <folder>/runs.tsv).
#
#   bash perf-sar.sh <output folder>
#
# It reads <folder>/sar-<hostname>.txt (made by "S_TIME_FORMAT=ISO sar -u -r -d -n DEV 1") and <folder>/runs.tsv and prints,
# for every recorded run (kind "run"), the mean over the run window of:
#   cpu_busy      100 minus %idle of the line "all" (percent)
#   iowait        %iowait (percent)
#   rd_MiBs       disk read rate summed over the disks of the data filesystems (MiB/s), device names from sar -d
#   wr_MiBs       disk write rate (MiB/s)
#   net_rx_MiBs   network receive rate of the interface that is not lo (MiB/s)
#   net_tx_MiBs   network transmit rate (MiB/s)
# Which block devices are the data disks is not guessed: all devices that sar -d lists with a name starting sd or vd,
# except the system disk, which is the device that holds / (read from lsblk when available, else sda). The method and its
# limits are in the result record that cites the output.
# Output: <folder>/sar-runs-<hostname>.tsv and the same on the screen, with its sha256.

set -eu
D="${1:?usage: bash perf-sar.sh <output folder of perf-warp.sh>}"
H="$(hostname)"
SAR="$D/sar-$H.txt"
RUNS="$D/runs.tsv"
[ -s "$SAR" ] || { echo "perf-sar: $SAR missing (run this on a node that recorded sar)" >&2; exit 1; }
[ -s "$RUNS" ] || { echo "perf-sar: $RUNS missing (copy it from ceph2)" >&2; exit 1; }
SYS="$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -1 || true)"
SYS="${SYS:-sda}"
OUT="$D/sar-runs-$H.tsv"
# flatten the sar text into one line per sample and kind: epoch  kind  key  v1 v2 ...
awk -v sysdev="$SYS" '
    # section headers contain the column names; data lines start with an ISO time (hh:mm:ss) or a date
    /%idle/ { mode="cpu"; next }
    /rkB\/s/ { mode="disk"; next }
    /rxkB\/s/ { mode="net"; next }
    /kbmemfree/ { mode="mem"; next }
    /^Linux/ || /^$/ || /^Average/ { next }
    {
        t=$1
        if (t !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) next
        if (mode=="cpu" && $2=="all") { print t "\tcpu\tall\t" $NF "\t" $(NF-2) }
        else if (mode=="disk" && ($2 ~ /^(sd|vd)/) && $2 != sysdev) { print t "\tdisk\t" $2 "\t" $4 "\t" $5 }
        else if (mode=="net" && $2 != "lo" && $2 != "IFACE") { print t "\tnet\t" $2 "\t" $5 "\t" $6 }
    }' "$SAR" > "$OUT.flat"
# date of the sar file: the file has the date in the first line "Linux ... (host) 2026-10-10 ..."
DATE="$(head -1 "$SAR" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1 || true)"
[ -n "$DATE" ] || DATE="unknown"
printf 'run\tcpu_busy\tiowait\trd_MiBs\twr_MiBs\tnet_rx_MiBs\tnet_tx_MiBs\tsamples\n' > "$OUT"
awk -F'\t' 'NR>1 && $2=="run"{print $1 "\t" $6 "\t" $7}' "$RUNS" | while IFS=$'\t' read -r label s e; do
    s_t="$(date -d "@$s" +%T)"; e_t="$(date -d "@$e" +%T)"
    awk -F'\t' -v a="$s_t" -v b="$e_t" -v lab="$label" '
        $1>=a && $1<=b {
            if ($2=="cpu") { idle+=$4; iow+=$5; n++ }
            else if ($2=="disk") { rd+=$4; wr+=$5 }
            else if ($2=="net") { rx+=$4; tx+=$5 }
        }
        END { if (n==0) { printf "%s\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\t0\n", lab; exit }
              printf "%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%d\n", lab, 100-idle/n, iow/n, rd/n/1024, wr/n/1024, rx/n/1024, tx/n/1024, n }' "$OUT.flat" >> "$OUT"
done
rm -f "$OUT.flat"
echo "== host $H, sar log $SAR, system disk excluded: $SYS, date $DATE"
cat "$OUT"
sha256sum "$OUT"
