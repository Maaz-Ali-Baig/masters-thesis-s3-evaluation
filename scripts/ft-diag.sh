#!/usr/bin/env bash
#
# ft-diag.sh : write-and-read-back probe for ONE outage of a SeaweedFS cluster (answers "why was a write acknowledged but not stored?")
#
#   bash ft-diag.sh <output folder> [count]        run on ceph0 while one node is down; count = number of 1 MiB writes (default 20)
#
# For every write it records, with plain curl (SigV4 by curl --aws-sigv4, no aws cli, so the raw HTTP answer is visible):
#   put_code, put_time     status code and time of the PUT of a random 1 MiB object to one live S3 endpoint (the live endpoints alternate)
#   etag                   ETag header of the answer (empty if none)
#   get_same               status code and sha256 check of a GET of the same key through the same endpoint, right after the PUT (OK, BAD, or the code)
#   filer                  status code of the filer entry of the key on the same node (http://<node>:8888/buckets/<bucket>/<key>)
#   get_other              the same GET through the other live endpoint 5 s later
#   assign                 answer of the master of ceph0 to /dir/assign for the collection and replication of the bucket (error text or "fid"), cut to 80 characters
#   writable               number of writable volumes of the collection in the master layout (from /dir/status), or "n/a"
# Output: <folder>/diag.tsv, <folder>/headers-<i>.txt (response headers of the PUT) and the same table on the screen, with its sha256.
# The PUT sends the header x-amz-content-sha256 with the real payload hash (without it curl 7.88.1 gets 403 SignatureDoesNotMatch from SeaweedFS, tested on 13 October on the healthy cluster:
# no header 403, real hash 200, UNSIGNED-PAYLOAD 200). The key is passed to curl with --user, so it is visible in the process list of ceph0 while the script runs.
# Keys are read from /root/seaweedfs-config/s3_credentials.txt (override: DG_KEYFILE) and never printed. It writes only keys under diag-<time>/ in the bucket.
# Settings by environment: DG_BUCKET (ftbucket), DG_EPS (live endpoints, default "192.168.1.72:8333 192.168.1.70:8333"), DG_MASTER (192.168.1.72:9333),
# DG_COLLECTION (the bucket name), DG_REPL (002), DG_REGION (us-east-1).

set -u
OUT="${1:?usage: bash ft-diag.sh <output folder> [count]}"
N="${2:-20}"
B="${DG_BUCKET:-ftbucket}"
EPS="${DG_EPS:-192.168.1.72:8333 192.168.1.70:8333}"
MASTER="${DG_MASTER:-192.168.1.72:9333}"
COLL="${DG_COLLECTION:-$B}"
REPL="${DG_REPL:-002}"
REGION="${DG_REGION:-us-east-1}"
SYS="${DG_SYSTEM:-seaweedfs}"
# DG_SYSTEM=garage (added 14 October 2026): key file /root/garage-key.txt with the labels "Key ID" and "Secret key", region garage,
# live endpoints default 192.168.1.72:3900 and 192.168.1.70:3900, and the SeaweedFS columns filer, assign and writable are written as n/a.
if [ "$SYS" = garage ]; then
    KEYFILE="${DG_KEYFILE:-/root/garage-key.txt}"; AKL="Key ID"; REGION="${DG_REGION:-garage}"
    EPS="${DG_EPS:-192.168.1.72:3900 192.168.1.70:3900}"
else
    KEYFILE="${DG_KEYFILE:-/root/seaweedfs-config/s3_credentials.txt}"; AKL="Access key"
fi
# Garage answers a GET without the header x-amz-content-sha256 with 400 InvalidRequest (tested on 14 October 2026 on the healthy cluster:
# no header 400, sha256 of the empty body 200, UNSIGNED-PAYLOAD 200), so for Garage every GET sends the hash of the empty body.
GH=""
[ "$SYS" = garage ] && GH="-H x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
[ -s "$KEYFILE" ] || { echo "ft-diag: $KEYFILE missing" >&2; exit 1; }
AK="$(awk -F': *' -v k="$AKL" '$1==k{print $2}' "$KEYFILE")"
SK="$(awk -F': *' '$1=="Secret key"{print $2}' "$KEYFILE")"
[ -n "$AK" ] && [ -n "$SK" ] || { echo "ft-diag: cannot parse $KEYFILE" >&2; exit 1; }
mkdir -p "$OUT"
TS="$(date +%Y%m%d-%H%M%S)"
PFX="diag-$TS"
TSV="$OUT/diag.tsv"
set -- $EPS
NEP=$#
printf 'time\ti\tendpoint\tput_code\tput_time\tetag\tget_same\tfiler\tget_other\tassign\twritable\n' > "$TSV"

signed() { # method url [curl args...]  (key passed through --user, not printed)
    local m="$1" u="$2"; shift 2
    curl -s -m 30 -X "$m" --aws-sigv4 "aws:amz:$REGION:s3" --user "$AK:$SK" "$@" "$u"
}

for i in $(seq 1 "$N"); do
    idx=$(( (i - 1) % NEP + 1 ))
    ep="$(echo $EPS | cut -d' ' -f$idx)"
    oidx=$(( idx % NEP + 1 ))
    oep="$(echo $EPS | cut -d' ' -f$oidx)"
    head -c 1048576 /dev/urandom > "$OUT/obj.tmp"
    sha="$(sha256sum "$OUT/obj.tmp" | cut -d' ' -f1)"
    t0="$(date +%T)"
    res="$(signed PUT "http://$ep/$B/$PFX/$i" -H "x-amz-content-sha256: $sha" --data-binary "@$OUT/obj.tmp" -D "$OUT/headers-$i.txt" -o "$OUT/put-body-$i.txt" -w '%{http_code} %{time_total}')"
    pcode="${res%% *}"; ptime="${res#* }"
    etag="$(grep -i '^etag:' "$OUT/headers-$i.txt" 2>/dev/null | head -1 | tr -d '\r\n' | cut -d' ' -f2-)"
    g="$(signed GET "http://$ep/$B/$PFX/$i" $GH -o "$OUT/get-same.tmp" -w '%{http_code}')"
    if [ "$g" = 200 ] && [ "$(sha256sum "$OUT/get-same.tmp" | cut -d' ' -f1)" = "$sha" ]; then gs=OK; elif [ "$g" = 200 ]; then gs=BAD; else gs="$g"; fi
    fnode="${ep%%:*}"
    if [ "$SYS" = garage ]; then fc="n/a"; asg="n/a"; wr="n/a"; else
    fc="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://$fnode:8888/buckets/$B/$PFX/$i")"
    asg="$(curl -s -m 10 "http://$MASTER/dir/assign?collection=$COLL&replication=$REPL" | tr '\n\t' '  ' | cut -c1-80)"
    wr="$(curl -s -m 10 "http://$MASTER/dir/status" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    n = 0
    for l in d.get("Topology", {}).get("Layouts", []) or []:
        if l.get("collection") == sys.argv[1] and l.get("replication") == sys.argv[2]:
            n += len(l.get("writables") or [])
    print(n)
except Exception:
    print("n/a")
' "$COLL" "$REPL" 2>/dev/null)"
    fi
    sleep 5
    go="$(signed GET "http://$oep/$B/$PFX/$i" $GH -o "$OUT/get-other.tmp" -w '%{http_code}')"
    if [ "$go" = 200 ] && [ "$(sha256sum "$OUT/get-other.tmp" | cut -d' ' -f1)" = "$sha" ]; then go=OK; elif [ "$go" = 200 ]; then go=BAD; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t0" "$i" "$ep" "$pcode" "$ptime" "${etag:-none}" "$gs" "$fc" "$go" "${asg:-none}" "${wr:-n/a}" >> "$TSV"
done
rm -f "$OUT/obj.tmp" "$OUT/get-same.tmp" "$OUT/get-other.tmp"
cat "$TSV"
sha256sum "$TSV"
grep -rlF "$SK" "$OUT" >/dev/null 2>&1 && echo "ft-diag: WARNING secret key found in the output" || echo "ft-diag: secret key found in output files: 0"
