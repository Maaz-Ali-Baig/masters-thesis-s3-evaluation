"""Inputs and readings of the S3 compatibility table (22 probe tests by the four systems), used by build_compat.py.

SOURCES   where the summary.tsv of each column comes from, its sha256 as written in the records, and what the records say about the VM run.
READINGS  one short reading per cell that is not PASS. TYPED BY HAND from the records (record and point in `src`). The script checks only that the
          regular expression `pat` is found in the sub-check detail of that cell in summary.tsv (so a reading cannot name a sub-check that did not fail);
          the cause stated in `text` is the claim of the record, it is not re-checked against the raw replies by the script.
A column of the table is a deployment, not a product: see `deploy` of each source.
"""

SOURCES = {
    "ceph": dict(
        label="Ceph", kind="tar", file="compat-ceph-vm-20261016-095804.tar.gz", member="summary.tsv",
        sha_summary="5e23204bcca8763eb3f6707e6d48dbf66df8c37843dfe2e9b1ac6a40c92a4ee0", sha_archive="b5b57bbae632fa37486a1602120506b376a956e581d826cfa7516690abe5c3b0",
        deploy="Ceph 20.2.4 RGW, 3 VMs, 6 OSDs, replicated 3, probe run on ceph0 against the RGW on ceph0 (localhost:80), 16 October 2026 07:58 UTC, HEALTH_OK (repeat of the run of 2 October)",
        vm="The run is the VM run itself (archive in results/, sha256 in vm-archives-ceph0-SHA256SUMS.txt). Its summary.tsv equals the summary.tsv of the run of 2 October (see CROSS_CHECK).",
        record="compatibility-cross-system-2026-10-15 (Ceph repeat), s3-compat-ceph-2026-10-02"),
    "seaweedfs": dict(
        label="SeaweedFS", kind="tar", file="compat-seaweedfs-20260930-205945.tar.gz", member="summary.tsv",
        sha_summary="ab8f15223ef382852a4835bbfc2d7918a764d07eb70979545c109a073a81eb61",
        deploy="SeaweedFS 4.25, 3 VMs, replication 002, probe on ceph0 (localhost:8333), 8 October 2026; the file here is the laptop single node run of 30 September",
        vm="Record: summary.tsv of the VM run has the same sha256 (sha256sum -c on ceph0), so the VM file is byte for byte this file. The VM archive is on ceph0 only.",
        record="seaweedfs-vm-compat-and-presign-2026-10-08"),
    "rustfs": dict(
        label="RustFS", kind="tar", file="compat-rustfs101-laptop-ssekey-20261009.tar.gz", member="summary.tsv",
        sha_summary="008bb153ec17d8596c66627e530dce03adbd35d9dd9af8d06abb167527de3158",
        deploy="RustFS 1.0.1, 3 VMs, erasure coding 3+3, SSE-S3 master key set (as in every later VM series), probe on ceph0 (localhost:9000), 9 October 2026 evening; the file here is the laptop single node run with a throwaway key",
        vm="Record: summary.tsv of the VM run has the same sha256 (sha256sum -c on ceph0). The VM archive is on ceph0 only.",
        record="rustfs-vm-compat-and-presign-2026-10-09 section 4"),
    "rustfs_default": dict(
        label="RustFS, no SSE key", kind="tar", file="compat-rustfs101-laptop-20261009-131301.tar.gz", member="summary.tsv",
        sha_summary="fff93eca987be3d720ea470b6e25659f0234996b11a32ed5b843dfd5c8eeb648",
        deploy="RustFS 1.0.1, 3 VMs, no SSE-S3 master key, probe on ceph0, 9 October 2026 (first run); the file here is the laptop single node run",
        vm="Record: summary.tsv of the VM run has the same sha256 (sha256sum -c on ceph0). The VM archive is on ceph0 only.",
        record="rustfs-vm-compat-and-presign-2026-10-09 section 1"),
    "garage": dict(
        label="Garage", kind="tar", file="compat-garage-20260930-210449.tar.gz", member="summary.tsv",
        sha_summary="bef965838671722571e2ecac53025ca4b44650ce76fc466b07f416904b9960fb",
        deploy="Garage v1.0.0, 3 VMs, replication factor 3, probe on ceph0 (localhost:3900), 8 October 2026; the file here is the laptop single node run of 30 September",
        vm="Record: summary.tsv of the VM run has the same sha256 (sha256 compared with the laptop file). The VM archive is on ceph0 only.",
        record="garage-vm-compat-and-presign-2026-10-08"),
}

# The Ceph probe of 2 October (text copy of the run, pinned sha256 of the file) must have a summary.tsv equal to the one of the repeat of 16 October.
CROSS_CHECK = dict(file="compat-ceph-20261002-072634-evidence.txt", sha_file="2dd6b3a5cab6a0726a559a50260b95e432c63265569bea762bc39b1bbc62bb1c", member="summary.tsv")

# Totals written in the records (PASS, FAIL, UNSUPPORTED). The script stops if its own count differs.
TOTALS_RECORD = {"ceph": (20, 2, 0), "seaweedfs": (18, 4, 0), "rustfs": (20, 2, 0), "rustfs_default": (19, 3, 0), "garage": (7, 9, 6)}

# Columns of the old matrix (results/compat-matrix-four-systems-2026-10-02.tsv) that must equal the recomputed verdicts.
# RustFS is not in this list: the old column is RustFS 1.0.0-beta.8 on the laptop. The record states the differences to 1.0.1 (C08, C20, and C18 without a key).
OLD_MATRIX_SAME = {"seaweedfs": "seaweedfs", "garage": "garage", "ceph": "ceph"}
RUSTFS_DIFF_TO_OLD = {"rustfs": {"C08", "C20"}, "rustfs_default": {"C08", "C18", "C20"}}

C = "s3-compat-three-systems-2026-09-30"
R = "rustfs-vm-compat-and-presign-2026-10-09"

# (system, test): dict(text, src, pat)  pat = regex that must be found in the sub-check detail of the cell.
READINGS = {
    # SeaweedFS
    ("seaweedfs", "C18"): dict(text="Header answered with HTTP 500 InternalError, nothing stored. Same image with an SSE key set: 200. The deployment has no SSE key; the key was not tested on the VM cluster.",
        src=C + " SeaweedFS PROVEN 2, OPEN O4", pat=r"put_sse:FAIL\(InternalError"),
    ("seaweedfs", "C19"): dict(text="Canned ACL on a key with a path prefix returns 500 (flat key 200). Object ACL public-read is listed but anonymous GET stays 403 (public read is decided per bucket).",
        src=C + " SeaweedFS PROVEN 3 and 4", pat=r"put_acl_prefixed:FAIL\(InternalError\)"),
    ("seaweedfs", "C21"): dict(text="A key ending in / reads back as 0 bytes. A path component of 256 bytes is refused (KeyTooLongError); total key length 1024 is accepted.",
        src=C + " SeaweedFS PROVEN 5 and 6", pat=r"trailing_slash:FAIL"),
    ("seaweedfs", "C22"): dict(text="DeleteBucket of a bucket that still holds objects succeeds and destroys the data (HTTP 204). Cause: server option -s3.allowDeleteBucketNotEmpty, default true. Not an error code difference only.",
        src=C + " SeaweedFS PROVEN 1", pat=r"delete_nonempty_BucketNotEmpty:FAIL"),
    # RustFS
    ("rustfs", "C19"): dict(text="ACL calls succeed and change nothing: no AllUsers grant is shown and anonymous access stays 403 (RustFS ignores ACLs and fails closed). Bucket policy works (C14 PASS).",
        src=C + " RustFS PROVEN 3 (beta.8, cross checks); the 1.0.1 summary line is byte identical to the beta.8 line (" + R + " section 1)", pat=r"public_read_enforced_flat:FAIL\(http=403\)"),
    ("rustfs", "C21"): dict(text="A path component of 256 bytes is refused (InvalidArgument); component limit 255 bytes, total key 1024 accepted and 1025 refused.",
        src=C + " RustFS PROVEN 4 (beta.8); the 1.0.1 summary line is byte identical (" + R + " section 1)", pat=r"component_256:FAIL\(put: InvalidArgument\)"),
    ("rustfs_default", "C18"): dict(text="Header refused with InvalidRequest: SSE-S3 needs RUSTFS_SSE_S3_MASTER_KEY when KMS is not configured. With the key set on all three nodes C18 passes (API only, encryption at rest not shown).",
        src=R + " sections 1 and 4", pat=r"put_sse:FAIL\(InvalidRequest.*RUSTFS_SSE_S3_MASTER_KEY"),
    ("rustfs_default", "C19"): dict(text="Same as RustFS with key.", src=R + " section 1", pat=r"public_read_enforced_flat:FAIL\(http=403\)"),
    ("rustfs_default", "C21"): dict(text="Same as RustFS with key.", src=R + " section 1", pat=r"component_256:FAIL\(put: InvalidArgument\)"),
    # Ceph
    ("ceph", "C18"): dict(text="HTTP 400 InvalidArgument with an empty message. Cause: rgw_crypt_sse_s3_backend is vault and no Vault token file is configured (RGW log and source v20.2.4). Bucket default encryption round trip passes. SSE-S3 with a key service was not tested.",
        src="s3-compat-ceph-2026-10-02 CEPH PROVEN 4, OPEN O2", pat=r"put_sse:FAIL\(InvalidArgument"),
    ("ceph", "C20"): dict(text="A wrong SHA-256 sent as a header is accepted (success and ETag); curl shows the same for SHA-1 and no checksum header on HEAD. In the curl control the three laptop systems answered 400. That RGW ignores these headers entirely is HYPOTHESIS H1, not proven. The trailer form was not tested.",
        src="s3-compat-ceph-2026-10-02 CEPH PROVEN 2, HYPOTHESIS H1, OPEN O1", pat=r"wrong_sha256_refused:FAIL\(rc=0"),
    # Garage
    ("garage", "C08"): dict(text="Two parts of 1 MiB are accepted in a multipart upload (AWS: EntityTooSmall). Other multipart steps pass.",
        src=C + " Garage PROVEN 2", pat=r"min_part_size_enforced:FAIL"),
    ("garage", "C09"): dict(text="NotImplemented (the Garage documentation lists tagging as missing).", src=C + " Garage PROVEN 1", pat=r"put_tagging:FAIL\(NotImplemented\)"),
    ("garage", "C10"): dict(text="NotImplemented when versioning is enabled.", src=C + " Garage PROVEN 1", pat=r"enable:FAIL\(NotImplemented\)"),
    ("garage", "C11"): dict(text="If-Match with a wrong ETag and If-Unmodified-Since in the year 2000 are accepted and ignored (200, AWS 412). If-None-Match on GET works (304).",
        src=C + " Garage PROVEN 2", pat=r"if_match_mismatch_412:FAIL"),
    ("garage", "C12"): dict(text="If-None-Match: * on PUT of an existing key is ignored (200, AWS 412).", src=C + " Garage PROVEN 2", pat=r"second_write_refused:FAIL"),
    ("garage", "C13"): dict(text="The URL works and a tampered signature is refused. An expired URL is refused with HTTP 400 where AWS answers 403 (the URL is refused either way; AWS CLI run only).",
        src=C + " Garage OPEN O2", pat=r"expired_rejected:FAIL\(http=400\)"),
    ("garage", "C14"): dict(text="NotImplemented (PutBucketPolicy).", src=C + " Garage PROVEN 1", pat=r"put_policy:FAIL\(NotImplemented"),
    ("garage", "C15"): dict(text="CORS is applied on real requests, but the preflight answer is allow-origin * for allowed, unlisted and unconfigured origins, and reading the CORS configuration after deleting it returns 204 (AWS 404).",
        src=C + " Garage PROVEN 3 and 4", pat=r"preflight_other_origin_refused:FAIL"),
    ("garage", "C16"): dict(text="Reading the lifecycle configuration after deleting it returns 204 (AWS 404 NoSuchLifecycleConfiguration).", src=C + " Garage PROVEN 4", pat=r"delete_lifecycle:FAIL"),
    ("garage", "C17"): dict(text="NotImplemented for the object lock configuration; lock headers on a normal bucket are accepted (200, AWS 400).", src=C + " Garage PROVEN 1 and 2", pat=r"lock_enabled:FAIL\(got= NotImplemented\)"),
    ("garage", "C18"): dict(text="SSE-S3 header accepted but not echoed; bucket default encryption NotImplemented. The documentation says server side encryption is not implemented. On the VMs the marker of an SSE-S3 object was found in clear on the drives (security table, SEC6).",
        src=C + " Garage PROVEN 1 and 2; garage-vm-security-2026-10-14 G-P5", pat=r"bucket_default_roundtrip:FAIL\(NotImplemented"),
    ("garage", "C19"): dict(text="NotImplemented for ACL reads and writes.", src=C + " Garage PROVEN 1", pat=r"get_bucket_acl:FAIL\(NotImplemented\)"),
    ("garage", "C20"): dict(text="CRC64NVME is accepted but the checksum is not returned (AWS CLI run only, no second client). Wrong SHA-256 and wrong MD5 are refused.",
        src=C + " Garage OPEN O2", pat=r"CRC64NVME:FAIL"),
    ("garage", "C21"): dict(text="Keys up to 479 bytes work; 480 bytes and above fail with HTTP 503 ServiceUnavailable (server message: LMDB MDB_BAD_VALSIZE). AWS allows 1024 and answers 400. The 479 = 511 minus 32 explanation is HYPOTHESIS H1, not proven.",
        src=C + " Garage PROVEN 5, HYPOTHESIS H1", pat=r"total_917_in_10_parts:FAIL\(put: ServiceUnavailable\)"),
    ("garage", "C22"): dict(text="Invalid bucket name returns InvalidRequest (AWS InvalidBucketName); a wrong Content-MD5 returns InvalidDigest (AWS BadDigest).", src=C + " Garage PROVEN 6", pat=r"invalid_bucket_name:FAIL\(rc=254 InvalidRequest\)"),
}
