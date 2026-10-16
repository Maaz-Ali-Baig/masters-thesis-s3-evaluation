"""Cells of the security comparison table (4 systems by 13 rows), filled by hand from the security records and checked by build_security.py.

Every cell has
  out       PASS, FAIL, REFUSED, NOT IN CLEAR, INFO or NOT TESTED. PASS and FAIL follow the pass conditions of security_method.md; REFUSED = the server refused the
            request that was meant to enable the feature; NOT IN CLEAR = the SSE request was accepted and the marker was not found on the drives (the strength of the
            encryption is not shown); INFO = a fact without a pass condition. A FAIL is a finding about the default deployment, not a judgement of the product.
  text      one line for the thesis table (short, only what the evidence shows)
  src       the record and the point of the record the cell comes from (results/<name>.txt)
  ev        evidence that build_security.py must find in the raw output: a list of (archive, member, regex[, min count]).
            archive = name of a results/<name>.tar.gz without the ending, or "file:results/<name>" for a plain file.
            regex "ABSENT" = the member must not exist in the archive (check was not run). Regexes are searched in the raw text with re.M.
A cell whose evidence is not found stops the script. A cell without ev (hand test) says so in its text and carries "hand" in ev_note.
"""

CEPH, CEPH_R = "sec-ceph-20261015-122716", "sec-ceph-replies-20261015-124414"
SW1, SW2, SW3 = "sec-seaweedfs-20261013-145754", "sec-seaweedfs-20261013-160404", "sec-seaweedfs-20261013-161312"
SW4 = "sec-seaweedfs-20261015-221614"
RF1, RF2, RF3 = "sec-rustfs-20261011-180911", "sec-rustfs-20261012-102351", "sec-rustfs-20261015-222451"
GA1, GA2, GA3 = "sec-garage-20261014-133307", "sec-garage-20261014-180515", "sec-garage-20261014-181146"
PS_G, PS_R, PS_S = "presign-garage-vm-20261008-142536", "presign-rustfs-vm-20261009-130903", "presign-seaweedfs-vm-20261008-200028"
PS_C = "file:results/security-presign-unsigned-header-ceph-20261005-230914.txt"

REC = {"ceph": "ceph-vm-security-2026-10-15", "seaweedfs": "seaweedfs-vm-security-2026-10-13", "rustfs": "rustfs-vm-security-2026-10-11", "garage": "garage-vm-security-2026-10-14"}

ROWS = [
    ("r1", "SEC1", "S3 port refuses anonymous requests (no signature)"),
    ("r2", "SEC3", "wrong secret and unknown access key refused"),
    ("r3", "SEC3", "presigned PUT with a header outside the signature"),
    ("r4", "SEC1", "answers without credentials on non S3 ports"),
    ("r5", "SEC2", "anonymous write through a non S3 port"),
    ("r6", "SEC2", "anonymous read of object data through a non S3 port"),
    ("r7", "SEC4", "key limited to read on one bucket"),
    ("r8", "SEC5", "object content on the wire (plain http)"),
    ("r9", "SEC6", "object stored without SSE on the data drives"),
    ("r10", "SEC6", "SSE-S3 request (header AES256)"),
    ("r11", "SEC6", "SSE-C request (customer key)"),
    ("r12", "SEC8", "failed attempt visible in the container log (default level)"),
    ("r13", "SEC7", "admin interface"),
]

CELLS = {
    # ---------------------------------------------------------------- Ceph
    ("ceph", "r1"): dict(out="PASS", text="403 for GET bucket, GET object, PUT and DELETE (three nodes)", src=REC["ceph"] + " SEC2, P-SEC-1",
        ev=[(CEPH, "sec3.txt", r"no signature: GET bucket 403 241, GET object 403 272, PUT object 403 241"), (CEPH, "sec1.txt", r"192\.168\.1\.70:80 PUT 403 241   DELETE 403 241")]),
    ("ceph", "r2"): dict(out="PASS", text="403 SignatureDoesNotMatch and 403 InvalidAccessKeyId (raw replies; the AWS CLI crashed on them)", src=REC["ceph"] + " SEC3",
        ev=[(CEPH_R, "replies.txt", r"right access key, wrong secret, list objects: http 403 code SignatureDoesNotMatch"), (CEPH_R, "replies.txt", r"fake access key, wrong secret, list objects: http 403 code InvalidAccessKeyId")]),
    ("ceph", "r3"): dict(out="PASS", text="p2 to p8 refused with 403; unsigned Content-Type also refused (p1 403); signed controls 200. Earlier run on the same VMs, 5 October", src="security-presign-unsigned-header-ceph-2026-10-05",
        ev=[(PS_C, "", r"p2  unsigned x-amz-meta-injected: yes\n +presigned PUT +HTTP 403"), (PS_C, "", r"p8  unsigned x-amz-copy-source from ANOTHER bucket.*\n +presigned PUT +HTTP 403"), (PS_C, "", r"s2  control, signed x-amz-meta-injected: yes\n +presigned PUT +HTTP 200")]),
    ("ceph", "r4"): dict(out="INFO", text="metrics text on 9093, 9095, 9100, 9283 and 9926 (service names not identified in this run); no status page of Ceph itself", src=REC["ceph"] + " SEC2, P-SEC-5",
        ev=[(CEPH, "sec1.txt", r"192\.168\.1\.72\t9095\t/metrics\t200 106674"), (CEPH, "sec1.txt", r"192\.168\.1\.72\t9283\t/metrics\t200 47558"), (CEPH, "sec1.txt", r"192\.168\.1\.72\t9926\t/metrics\t200 121375")]),
    ("ceph", "r5"): dict(out="PASS", text="no 2xx: PUT answered 404, 405 or 301 by every non S3 port that answered", src=REC["ceph"] + " SEC2",
        ev=[(CEPH, "sec2.txt", r"192\.168\.1\.70:9926 PUT 405"), (CEPH, "sec2.txt", r"192\.168\.1\.72:9283 PUT 301"), (CEPH, "sec2.txt", r"192\.168\.1\.72:9095 PUT 404")]),
    ("ceph", "r6"): dict(out="INFO", text="no non S3 data port in the SEC1 list", src=REC["ceph"] + " SEC1 (list of ports and 15 paths only)",
        ev=[(CEPH, "sec1.txt", r"listening tcp ports on 192\.168\.1\.70: 22 80 631 3300")]),
    ("ceph", "r7"): dict(out="PASS", text="list and read 200; put, delete and create bucket 403 AccessDenied; object still there (read only bucket policy, max_buckets -1)", src=REC["ceph"] + " SEC4, setup error kept",
        ev=[(CEPH_R, "replies.txt", r"scoped key, put object new\.txt: http 403 code AccessDenied"), (CEPH_R, "replies.txt", r"scoped key, delete sec-reply-del\.txt: http 403 code AccessDenied"), (CEPH_R, "replies.txt", r"create bucket secnew\d+ \(max_buckets -1\): http 403 code AccessDenied"), (CEPH_R, "replies.txt", r"scoped key, list objects \(expect 200\): http 200")]),
    ("ceph", "r8"): dict(out="FAIL", text="plain http, no TLS configured; 199 of 200 marker lines in the capture", src=REC["ceph"] + " SEC5, P-SEC-4",
        ev=[(CEPH, "sec5.txt", r"marker lines found in the capture: 199")]),
    ("ceph", "r9"): dict(out="FAIL", text="marker found on one raw OSD device (/dev/dm-0) of each of the three nodes (8 hits each)", src=REC["ceph"] + " SEC6, P-SEC-3",
        ev=[(CEPH, "sec6.txt", r"\s8 SECPROBE-REST-MARKER-\d+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-PLAIN", 3)]),
    ("ceph", "r10"): dict(out="REFUSED", text="400 InvalidArgument (no key service for SSE-S3 configured)", src=REC["ceph"] + " SEC6b; ceph-sse-s3-vault-check-2026-10-02",
        ev=[(CEPH_R, "replies.txt", r"SSE-S3 put \(header AES256\): http 400 code InvalidArgument")]),
    ("ceph", "r11"): dict(out="REFUSED", text="400 InvalidRequest over plain http (reason: HYPOTHESIS, not read)", src=REC["ceph"] + " SEC6b",
        ev=[(CEPH_R, "replies.txt", r"SSE-C put \(customer key, http\): http 400 code InvalidRequest")]),
    ("ceph", "r12"): dict(out="FAIL", text="not visible: 0 lines with the fake key; the RGW container log holds 0 to 1 lines in total, also for successful requests (control)", src=REC["ceph"] + " SEC8",
        ev=[(CEPH, "sec8.txt", r"on 192\.168\.1\.72 \(one number per matching container\): 0"), (CEPH_R, "replies.txt", r"fake:0 ftbucket:0 lines:1")]),
    ("ceph", "r13"): dict(out="INFO", text="port 8443 (dashboard) listens on ceph0 and ceph1; its answer without credentials was not read", src=REC["ceph"] + " O4",
        ev=[(CEPH, "sec1.txt", r"listening tcp ports on 192\.168\.1\.72: .* 8443 "), (CEPH, "sec1.txt", r"listening tcp ports on 192\.168\.1\.71: .* 8443 ")]),
    # ---------------------------------------------------------------- SeaweedFS
    ("seaweedfs", "r1"): dict(out="PASS", text="403 for GET bucket, GET object, PUT; PUT and DELETE 403 on all three nodes", src=REC["seaweedfs"] + " SW-P1",
        ev=[(SW1, "sec3.txt", r"no signature: GET bucket 403 222, GET object 403 262, PUT object 403 270"), (SW1, "sec1.txt", r"192\.168\.1\.70:8333 PUT 403 268   DELETE 403 268")]),
    ("seaweedfs", "r2"): dict(out="PASS", text="SignatureDoesNotMatch and InvalidAccessKeyId", src=REC["seaweedfs"] + " SW-P1",
        ev=[(SW1, "sec3.txt", r"right access key, wrong secret:.*SignatureDoesNotMatch"), (SW1, "sec3.txt", r"fake access key, wrong secret:.*InvalidAccessKeyId")]),
    ("seaweedfs", "r3"): dict(out="PASS", text="p2 to p8 refused with 403; unsigned Content-Type accepted (p1 200); signed controls 200", src="seaweedfs-vm-compat-and-presign-2026-10-08",
        ev=[(PS_S, "console.txt", r"p2  unsigned x-amz-meta-injected: yes\n +presigned PUT +HTTP 403"), (PS_S, "console.txt", r"p8  unsigned x-amz-copy-source from ANOTHER bucket.*\n +presigned PUT +HTTP 403"), (PS_S, "console.txt", r"p1  unsigned Content-Type: application/octet-stream\n +presigned PUT +HTTP 200")]),
    ("seaweedfs", "r4"): dict(out="INFO", text="master (cluster status, topology), volume server status and filer root page answer on every node", src=REC["seaweedfs"] + " SW-P2",
        ev=[(SW1, "sec1.txt", r"192\.168\.1\.72\t9333\t/dir/status\t200 1028"), (SW1, "sec1.txt", r"192\.168\.1\.72\t8080\t/status\t200 12416"), (SW1, "sec1.txt", r"192\.168\.1\.72\t8888\t/\t200 11467")]),
    ("seaweedfs", "r5"): dict(out="PASS", text="filer PUT 401, master PUT 404, volume server upload with an assigned file id 401", src=REC["seaweedfs"] + " SW-P3",
        ev=[(SW1, "sec2.txt", r"192\.168\.1\.72:8888 PUT 401 21"), (SW1, "sec2.txt", r"192\.168\.1\.72:9333 PUT 404 19"), (SW1, "sec2.txt", r"volume server upload 401")]),
    ("seaweedfs", "r6"): dict(out="FAIL", text="the filer port 8888 returns object content without credentials (1 KiB object 200 on three nodes; 1 MiB object read with equal sha256, by hand)", src=REC["seaweedfs"] + " SW-P4, SW-O2",
        ev=[(SW2, "sec2.txt", r"filer read of ftbucket/fixed/head\.bin on 192\.168\.1\.72:8888: 200 1024"), (SW2, "sec2.txt", r"filer read of ftbucket/fixed/head\.bin on 192\.168\.1\.70:8888: 200 1024")]),
    ("seaweedfs", "r7"): dict(out="PASS", text="list and read ok; write, delete, read of another bucket and create bucket refused (AccessDenied or 403); bucket list shows only ftbucket (second S3 identity with Read and List on ftbucket; S3 port only, the filer port bypasses it, see row 6)", src=REC["seaweedfs"] + " ADDENDUM 15 October, SW-P9, SW-O9",
        ev=[(SW4, "sec4.txt", r"list allowed bucket \(expect ok\): +PRE"), (SW4, "sec4.txt", r"read allowed object \(expect ok\): scoped key test"),
          (SW4, "sec4.txt", r"write to allowed bucket \(expect refused\): upload failed.*AccessDenied"), (SW4, "sec4.txt", r"delete in allowed bucket \(expect refused\): delete failed.*AccessDenied"),
          (SW4, "sec4.txt", r"read another bucket \(expect refused\): .*\(403\)"), (SW4, "sec4.txt", r"create a bucket \(expect refused\): make_bucket failed.*AccessDenied"),
          (SW4, "sec4.txt", r"list all buckets \(expect refused or only the allowed one\): \{ +\"Buckets\": \[ +\{ +\"Name\": \"ftbucket\"")]),
    ("seaweedfs", "r8"): dict(out="FAIL", text="plain http, no TLS configured; 199 of 200 marker lines in the capture", src=REC["seaweedfs"] + " SW-P5",
        ev=[(SW1, "sec5.txt", r"marker lines found in the capture: 199")]),
    ("seaweedfs", "r9"): dict(out="FAIL", text="marker found in the volume file ftbucket_69.dat on all three nodes (random padded object; repetitive text objects were not found: possible compression, OPEN)", src=REC["seaweedfs"] + " SW-P6, SW-O1",
        ev=[(SW3, "sec6.txt", r"files containing the marker on 192\.168\.1\.72 .*: 1\n +/srv/s3/disk2/seaweedfs/ftbucket_69\.dat"), (SW3, "sec6.txt", r"files containing the marker on 192\.168\.1\.70 .*: 1\n +/srv/s3/disk2/seaweedfs/ftbucket_69\.dat")]),
    ("seaweedfs", "r10"): dict(out="REFUSED", text="InternalError in all three runs. Cause shown on the laptop with the same version: no SSE key set (with a key the header was accepted); not tested on the VM cluster", src=REC["seaweedfs"] + " SW-P7, SW-O3; s3-compat-three-systems-2026-09-30 SeaweedFS PROVEN 2",
        ev=[(SW1, "sec6.txt", r"SSE-S3 upload: upload failed:.*InternalError"), (SW3, "sec6.txt", r"SSE-S3 upload: upload failed:.*InternalError")]),
    ("seaweedfs", "r11"): dict(out="NOT IN CLEAR", text="accepted; no extra marker copy found in the volume file (4 occurrences = the plain object); not read back, encryption not proven", src=REC["seaweedfs"] + " SW-P7",
        ev=[(SW3, "sec6.txt", r"SSE-C upload: \{.*SSECustomerAlgorithm")]),
    ("seaweedfs", "r12"): dict(out="PASS", text="visible: 2 log lines on the node that served the request (InvalidAccessKeyId, no source address as read)", src=REC["seaweedfs"] + " SW-P8",
        ev=[(SW1, "sec8.txt", r"on 192\.168\.1\.72 \(one number per matching container\): 2"), (SW1, "sec8.txt", r"on 192\.168\.1\.71 \(one number per matching container\): 0")]),
    ("seaweedfs", "r13"): dict(out="INFO", text="master, volume server and filer pages open without a login (see row 4); no login tested", src=REC["seaweedfs"] + " SW-O6",
        ev=[(SW1, "sec1.txt", r"192\.168\.1\.72\t9333\t/cluster/status\t200")]),
    # ---------------------------------------------------------------- RustFS
    ("rustfs", "r1"): dict(out="PASS", text="403 for GET bucket, GET object, PUT; PUT and DELETE 403 on all three nodes", src=REC["rustfs"] + " SE-P1",
        ev=[(RF1, "sec3.txt", r"no signature: GET bucket 403 110, GET object 403 110, PUT object 403 110"), (RF1, "sec1.txt", r"192\.168\.1\.70:9000 PUT 403 110   DELETE 403 110")]),
    ("rustfs", "r2"): dict(out="PASS", text="SignatureDoesNotMatch and InvalidAccessKeyId", src=REC["rustfs"] + " SE-P1",
        ev=[(RF1, "sec3.txt", r"right access key, wrong secret:.*SignatureDoesNotMatch"), (RF1, "sec3.txt", r"fake access key, wrong secret:.*InvalidAccessKeyId")]),
    ("rustfs", "r3"): dict(out="PASS", text="p2 to p8 refused with 403; unsigned Content-Type accepted (p1 200); signed controls 200", src="rustfs-vm-compat-and-presign-2026-10-09",
        ev=[(PS_R, "console.txt", r"p2  unsigned x-amz-meta-injected: yes\n +presigned PUT +HTTP 403"), (PS_R, "console.txt", r"p8  unsigned x-amz-copy-source from ANOTHER bucket.*\n +presigned PUT +HTTP 403"), (PS_R, "console.txt", r"p1  unsigned Content-Type: application/octet-stream\n +presigned PUT +HTTP 200")]),
    ("rustfs", "r4"): dict(out="INFO", text="/health and /minio/health/cluster (readiness of storage, IAM and lock) on 9000 and 9001; the console page on 9001", src=REC["rustfs"] + " SE-P2",
        ev=[(RF1, "sec1.txt", r"192\.168\.1\.72\t9000\t/minio/health/cluster\t200 374"), (RF1, "sec1.txt", r"192\.168\.1\.72\t9001\t/rustfs/console/index\.html\t200 34536")]),
    ("rustfs", "r5"): dict(out="NOT TESTED", text="the script found no non S3 port that answered 200 or 3xx on /, so it made no write", src=REC["rustfs"] + " SEC2",
        ev=[(RF1, "sec2.txt", r"== anonymous PUT of a marker file to every non S3 port")]),
    ("rustfs", "r6"): dict(out="INFO", text="no non S3 data port in the SEC1 list (S3 on 9000, console on 9001)", src=REC["rustfs"] + " SEC1",
        ev=[(RF1, "sec1.txt", r"listening tcp ports on 192\.168\.1\.72: 22 631 9000 9001")]),
    ("rustfs", "r7"): dict(out="PASS", text="list and read ok; write, delete, read of another bucket and create bucket refused (AccessDenied or 403); bucket list shows only ftbucket (user with a policy GetObject and ListBucket on ftbucket, made with rc 0.1.36)", src=REC["rustfs"] + " ADDENDUM 15 October, SE-P8",
        ev=[(RF3, "sec4.txt", r"list allowed bucket \(expect ok\): +PRE"), (RF3, "sec4.txt", r"read allowed object \(expect ok\): scoped key test"),
          (RF3, "sec4.txt", r"write to allowed bucket \(expect refused\): upload failed.*AccessDenied"), (RF3, "sec4.txt", r"delete in allowed bucket \(expect refused\): delete failed.*AccessDenied"),
          (RF3, "sec4.txt", r"read another bucket \(expect refused\): .*\(403\)"), (RF3, "sec4.txt", r"create a bucket \(expect refused\): make_bucket failed.*AccessDenied"),
          (RF3, "sec4.txt", r"list all buckets \(expect refused or only the allowed one\): \{ +\"Buckets\": \[ +\{ +\"Name\": \"ftbucket\"")]),
    ("rustfs", "r8"): dict(out="FAIL", text="plain http, no TLS configured; 264 marker lines for 200 uploaded (count above 200 not explained, OPEN)", src=REC["rustfs"] + " ADDENDUM SE-P7, SE-O8",
        ev=[(RF2, "sec5.txt", r"marker lines found in the capture: 264")]),
    ("rustfs", "r9"): dict(out="FAIL", text="marker found in xl.meta of the plain object on one drive of each node (3 of 6 drives)", src=REC["rustfs"] + " SE-P3, SE-O1",
        ev=[(RF1, "sec6.txt", r"/srv/s3/disk\d/rustfs/ftbucket/secprobe-plain\.txt/xl\.meta", 3)]),
    ("rustfs", "r10"): dict(out="NOT IN CLEAR", text="accepted; marker of the SSE object not found on the drives (strength of the encryption not shown)", src=REC["rustfs"] + " SE-P4, SE-O2",
        ev=[(RF1, "sec6.txt", r"SSE-S3 upload: ?$"), (RF1, "sec6.txt", r"files containing the marker on 192\.168\.1\.72 \(plain \+ SSE-S3 \+ SSE-C objects together\): 1\n +/srv/s3/disk1/rustfs/ftbucket/secprobe-plain\.txt/xl\.meta")]),
    ("rustfs", "r11"): dict(out="NOT IN CLEAR", text="accepted; marker of the SSE-C object not found on the drives (not read back, encryption not proven)", src=REC["rustfs"] + " SE-P4, SE-O2",
        ev=[(RF1, "sec6.txt", r"SSE-C upload: \{.*SSECustomerAlgorithm")]),
    ("rustfs", "r12"): dict(out="FAIL", text="not visible: 0 log lines with the fake key on any node", src=REC["rustfs"] + " SE-P5",
        ev=[(RF1, "sec8.txt", r"on 192\.168\.1\.72 \(one number per matching container\): 0"), (RF1, "sec8.txt", r"on 192\.168\.1\.71 \(one number per matching container\): 0")]),
    ("rustfs", "r13"): dict(out="INFO", text="console page on 9001 is served without a login; the login itself was not tested", src=REC["rustfs"] + " SE-O3",
        ev=[(RF1, "sec1.txt", r"192\.168\.1\.72\t9001\t/rustfs/console/index\.html\t200 34536")]),
    # ---------------------------------------------------------------- Garage
    ("garage", "r1"): dict(out="PASS", text="403 for GET bucket, GET object, PUT; PUT and DELETE 403 on all three nodes", src=REC["garage"] + " G-P1",
        ev=[(GA1, "sec3.txt", r"no signature: GET bucket 403 205, GET object 403 220, PUT object 403 224"), (GA1, "sec1.txt", r"192\.168\.1\.70:3900 PUT 403 223   DELETE 403 223")]),
    ("garage", "r2"): dict(out="PASS", text="AccessDenied with the texts Invalid signature and No such key", src=REC["garage"] + " G-P1",
        ev=[(GA1, "sec3.txt", r"right access key, wrong secret:.*Invalid signature"), (GA1, "sec3.txt", r"fake access key, wrong secret:.*No such key")]),
    ("garage", "r3"): dict(out="PASS", text="p2 to p8 refused with 400 InvalidRequest (header should be signed); unsigned Content-Type accepted (p1 200); signed controls 200", src="garage-vm-compat-and-presign-2026-10-08",
        ev=[(PS_G, "console.txt", r"p2  unsigned x-amz-meta-injected: yes\n +presigned PUT +HTTP 400"), (PS_G, "console.txt", r"p8  unsigned x-amz-copy-source from ANOTHER bucket.*\n +presigned PUT +HTTP 400"), (PS_G, "console.txt", r"p1  unsigned Content-Type: application/octet-stream\n +presigned PUT +HTTP 200")]),
    ("garage", "r4"): dict(out="INFO", text="admin port 3902: /health and /metrics (194 to 359 KB) on every node", src=REC["garage"] + " G-P2",
        ev=[(GA1, "sec1.txt", r"192\.168\.1\.72\t3902\t/health\t200 102"), (GA1, "sec1.txt", r"192\.168\.1\.72\t3902\t/metrics\t200 359382")]),
    ("garage", "r5"): dict(out="NOT TESTED", text="the script found no non S3 port that answered 200 or 3xx on /; by hand: POST /v1/key on 3902 gave 403 and created no key (record only)", src=REC["garage"] + " SEC2 extension, G-P2",
        ev=[(GA1, "sec2.txt", r"== anonymous PUT of a marker file to every non S3 port")]),
    ("garage", "r6"): dict(out="INFO", text="no non S3 data port in the SEC1 list (S3 3900, RPC 3901, admin 3902)", src=REC["garage"] + " SEC1",
        ev=[(GA1, "sec1.txt", r"listening tcp ports on 192\.168\.1\.72: 22 631 3900 3901 3902")]),
    ("garage", "r7"): dict(out="PASS", text="list and read ok; write, delete, read of another bucket and create bucket refused (403 or AccessDenied); bucket list shows only its own bucket", src=REC["garage"] + " SEC4 run 2, G-P3",
        ev=[(GA2, "sec4.txt", r"write to allowed bucket \(expect refused\): upload failed.*AccessDenied"), (GA2, "sec4.txt", r"delete in allowed bucket \(expect refused\): delete failed.*AccessDenied"), (GA2, "sec4.txt", r"read another bucket \(expect refused\): .*\(403\)"), (GA2, "sec4.txt", r"create a bucket \(expect refused\): make_bucket failed.*AccessDenied")]),
    ("garage", "r8"): dict(out="FAIL", text="plain http, no TLS configured; 199 of 200 marker lines in the capture", src=REC["garage"] + " G-P4",
        ev=[(GA1, "sec5.txt", r"marker lines found in the capture: 199")]),
    ("garage", "r9"): dict(out="FAIL", text="marker found in one zstd block file on each of the three nodes (three copies)", src=REC["garage"] + " G-P6",
        ev=[(GA3, "sec6.txt", r"files containing the marker of the PLAIN object on 192\.168\.1\.72: 1"), (GA3, "sec6.txt", r"files containing the marker of the PLAIN object on 192\.168\.1\.70: 1")]),
    ("garage", "r10"): dict(out="FAIL", text="accepted without an error, but the marker of the SSE-S3 object is stored in clear in a block file on every node (as the plain control)", src=REC["garage"] + " G-P5, run 3",
        ev=[(GA3, "sec6.txt", r"SSE-S3 upload: ?$"), (GA3, "sec6.txt", r"files containing the marker of the SSES object on 192\.168\.1\.72: 1"), (GA3, "sec6.txt", r"files containing the marker of the SSES object on 192\.168\.1\.71: 1")]),
    ("garage", "r11"): dict(out="NOT IN CLEAR", text="accepted (ETag and VersionId returned; the archive line is cut before the SSE-C fields); marker of the SSE-C object found on no node (not read back, encryption not proven)", src=REC["garage"] + " Q1",
        ev=[(GA3, "sec6.txt", r"SSE-C upload: \{.*\"ETag\".*\"VersionId\""), (GA3, "sec6.txt", r"files containing the marker of the SSEC object on 192\.168\.1\.72: 0")]),
    ("garage", "r12"): dict(out="PASS", text="visible: 2 log lines on the node that served the request (content not read)", src=REC["garage"] + " G-P7, Q2",
        ev=[(GA1, "sec8.txt", r"on 192\.168\.1\.72 \(one number per matching container\): 2"), (GA1, "sec8.txt", r"on 192\.168\.1\.71 \(one number per matching container\): 0")]),
    ("garage", "r13"): dict(out="INFO", text="admin API on 3902 refuses calls without its token (403, by hand, record only); /health and /metrics are open", src=REC["garage"] + " G-P2",
        ev=[(GA1, "sec1.txt", r"192\.168\.1\.72\t3902\t/health\t200 102")]),
}
