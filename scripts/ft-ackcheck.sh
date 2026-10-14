#!/usr/bin/env bash
#
# ft-ackcheck.sh : does an acknowledgement of the probe client mean a stored object? (open question Q1 of the Garage S1 and S2 records and of the SeaweedFS S1 record)
#
#   bash ft-ackcheck.sh <system> <output folder> <seconds>        system: garage (the only one supported so far)
#
# Run on ceph0 while one node is stopped, or while the Garage container of one node is frozen (see AC_PAUSE_IP). For <seconds> it writes random 1 MiB objects with THREE clients one after the other:
#   cp    aws s3 cp            exactly as the probe of ft.sh (connect timeout 3 s, read timeout 25 s, AWS_MAX_ATTEMPTS=1, standard retry mode, checksum when_required)
#   api   aws s3api put-object the same limits; the answer (ETag) is kept
#   curl  curl --aws-sigv4     max time 30 s; HTTP code and ETag header kept (x-amz-content-sha256 sent with the real hash)
# The live endpoints rotate (default 192.168.1.72:3900 and 192.168.1.70:3900, override AC_EPS). After the loop and a settle time (AC_SETTLE, default 60 s) every key is read with
# head-object through the first endpoint. Output in <folder>: attempts.tsv (client, i, endpoint, start epoch, seconds, ACK or FAIL, ETag, detail), verify.tsv (adds exists YES or NO),
# summary.txt (per client: attempts, ACK, FAIL, ACK but missing, FAIL but present, longest ACK), events.log, and the same on the screen.
# Optional freeze instead of a Proxmox stop: AC_PAUSE_IP=192.168.1.71 AC_PAUSE_AT=30 AC_PAUSE_FOR=180 runs "podman pause garage" on that node over ssh at AC_PAUSE_AT seconds after the start
# and "podman unpause garage" AC_PAUSE_FOR seconds later (and again on exit). A frozen container is NOT the same as a stopped VM: the kernel of the node still accepts connections.
# Keys are read from /root/garage-key.txt and never printed; the curl client passes the key with --user, so it is visible in the process list of ceph0 while the script runs.
# All objects are written under ackcheck-<time>/ in the bucket (AC_BUCKET, default ftbucket) and are removed at the end.

set -u
SYS="${1:?usage: bash ft-ackcheck.sh garage <output folder> <seconds>}"
OUT="${2:?output folder}"
SECS="${3:?seconds}"
B="${AC_BUCKET:-ftbucket}"
case "$SYS" in
    garage) KEYFILE="${AC_KEYFILE:-/root/garage-key.txt}"; AKL="Key ID"; REGION=garage; EPS="${AC_EPS:-192.168.1.72:3900 192.168.1.70:3900}"; CONT=garage ;;
    *) echo "ft-ackcheck: system $SYS not supported" >&2; exit 1 ;;
esac
[ -s "$KEYFILE" ] || { echo "ft-ackcheck: $KEYFILE missing" >&2; exit 1; }
AK="$(awk -F': *' -v k="$AKL" '$1==k{print $2}' "$KEYFILE")"
SK="$(awk -F': *' '$1=="Secret key"{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || { echo "ft-ackcheck: cannot parse $KEYFILE" >&2; exit 1; }
export PATH=/opt/aws-cli-new/bin:$PATH
export AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_DEFAULT_REGION="$REGION"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard
mkdir -p "$OUT"
PFX="ackcheck-$(date +%Y%m%d-%H%M%S)"
echo "$PFX" > "$OUT/prefix"
ATT="$OUT/attempts.tsv"; VER="$OUT/verify.tsv"; EV="$OUT/events.log"
printf 'client\ti\tendpoint\tstart_epoch\tseconds\tresult\tetag\tdetail\n' > "$ATT"
: > "$EV"
set -- $EPS; NEP=$#; FIRST="$1"
ev() { echo "$(date +%T) $*" | tee -a "$EV"; }
s3ep() { local ep="$1"; shift; aws --endpoint-url "http://$ep" --cli-connect-timeout 3 --cli-read-timeout 25 "$@" 2>&1; }
unpause() { [ -n "${AC_PAUSE_IP:-}" ] && ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$AC_PAUSE_IP" "podman unpause $CONT" >> "$EV" 2>&1; }
trap 'unpause' EXIT

ev "start, system $SYS, endpoints $EPS, prefix $PFX, loop $SECS s"
if [ -n "${AC_PAUSE_IP:-}" ]; then
    (
        sleep "${AC_PAUSE_AT:-30}"
        ev "freeze: podman pause $CONT on $AC_PAUSE_IP"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$AC_PAUSE_IP" "podman pause $CONT" >> "$EV" 2>&1
        sleep "${AC_PAUSE_FOR:-180}"
        ev "unfreeze: podman unpause $CONT on $AC_PAUSE_IP"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$AC_PAUSE_IP" "podman unpause $CONT" >> "$EV" 2>&1
    ) &
fi

T0="$(date +%s)"; i=0; n=0
while [ $(( $(date +%s) - T0 )) -lt "$SECS" ]; do
    i=$((i+1))
    head -c 1048576 /dev/urandom > "$OUT/obj.tmp"
    sha="$(sha256sum "$OUT/obj.tmp" | cut -d' ' -f1)"
    for cl in cp api curl; do
        n=$((n+1)); idx=$(( n % NEP + 1 )); ep="$(echo $EPS | cut -d' ' -f$idx)"
        key="$PFX/$cl-$i"; etag=""; detail=""
        st="$(date +%s.%N)"
        case "$cl" in
            cp)   if out="$(s3ep "$ep" s3 cp "$OUT/obj.tmp" "s3://$B/$key" --only-show-errors)"; then res=ACK; else res=FAIL; fi
                  detail="$(echo "$out" | tr '\n\t' '  ' | cut -c1-110)" ;;
            api)  if out="$(s3ep "$ep" s3api put-object --bucket "$B" --key "$key" --body "$OUT/obj.tmp" --query ETag --output text)"; then res=ACK; etag="$out"; else res=FAIL; detail="$(echo "$out" | tr '\n\t' '  ' | cut -c1-110)"; fi ;;
            curl) code="$(curl -s -m 30 -X PUT --aws-sigv4 "aws:amz:$REGION:s3" --user "$AK:$SK" -H "x-amz-content-sha256: $sha" --data-binary "@$OUT/obj.tmp" -D "$OUT/hdr.tmp" -o /dev/null -w '%{http_code}' "http://$ep/$B/$key")"
                  etag="$(grep -i '^etag:' "$OUT/hdr.tmp" 2>/dev/null | head -1 | tr -d '\r\n' | cut -d' ' -f2-)"
                  if [ "$code" = 200 ]; then res=ACK; else res=FAIL; fi; detail="http $code" ;;
        esac
        en="$(date +%s.%N)"
        sec="$(awk -v a="$en" -v b="$st" 'BEGIN{printf "%.1f", a-b}')"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cl" "$i" "$ep" "${st%.*}" "$sec" "$res" "${etag:-none}" "${detail:-}" >> "$ATT"
    done
done
rm -f "$OUT/obj.tmp" "$OUT/hdr.tmp"
ev "loop finished after $i rounds, settle ${AC_SETTLE:-60} s"
unpause
sleep "${AC_SETTLE:-60}"

printf 'client\ti\tendpoint\tstart_epoch\tseconds\tresult\tetag\tdetail\texists\n' > "$VER"
tail -n +2 "$ATT" | while IFS=$'\t' read -r cl ii ep st sec res etag detail; do
    if s3ep "$FIRST" s3api head-object --bucket "$B" --key "$PFX/$cl-$ii" >/dev/null; then ex=YES; else ex=NO; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cl" "$ii" "$ep" "$st" "$sec" "$res" "$etag" "$detail" "$ex" >> "$VER"
done
{
    echo "== per client (attempts, ACK, FAIL, ACK but missing, FAIL but present, longest ACK in s)"
    awk -F'\t' 'NR>1{a[$1]++; if($6=="ACK"){k[$1]++; if($5>m[$1])m[$1]=$5; if($9=="NO")am[$1]++} else {f[$1]++; if($9=="YES")fp[$1]++}}
        END{for(c in a) printf "%s\t%d\t%d\t%d\t%d\t%d\t%.1f\n", c, a[c], k[c], f[c], am[c], fp[c], m[c]}' "$VER" | sort
    echo "== ACK but missing, and FAIL but present (client, i, endpoint, start, seconds, result, etag, detail, exists)"
    awk -F'\t' 'NR>1 && (($6=="ACK" && $9=="NO") || ($6=="FAIL" && $9=="YES"))' "$VER" | while IFS=$'\t' read -r cl ii ep st sec res etag detail ex; do echo "$cl $ii $ep $(date -d "@$st" +%T) $sec $res $etag $detail $ex"; done
    echo "== attempts that took 10 s or more (client, i, endpoint, start, seconds, result, exists)"
    awk -F'\t' 'NR>1 && $5>=10 {print $1, $2, $3, $4, $5, $6, $9}' "$VER" | while read -r cl ii ep st sec res ex; do echo "$cl $ii $ep $(date -d "@$st" +%T) $sec $res $ex"; done
} | tee "$OUT/summary.txt"

ev "removing the test objects"
s3ep "$FIRST" s3 rm "s3://$B/$PFX/" --recursive --only-show-errors > /dev/null
( cd "$OUT" && sha256sum attempts.tsv verify.tsv summary.txt events.log prefix )
grep -rlF "$SK" "$OUT" > /dev/null 2>&1 && echo "ft-ackcheck: WARNING secret key found in the output" || echo "ft-ackcheck: secret key found in output files: 0"
