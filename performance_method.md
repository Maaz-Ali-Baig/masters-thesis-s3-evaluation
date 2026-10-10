# Performance method for the four systems on the university VMs

Status: DRAFT of 10 October 2026, not yet approved. Nothing in this file has been run. Every number below that is a
setting (not a result) is a proposal, and the places where a proposal rests on an earlier measurement name the record.

## 1. Question and scope

Question: how do Ceph (RGW), SeaweedFS, RustFS and Garage compare in throughput, request latency and scaling with
concurrency and object size, when deployed on the same three virtual machines with the same load generator, the same
workload and the same procedure, one system after the other (Prof. Baun, 22 September 2026)?

Not part of this method: fault tolerance (separate method, P2), security (P3), S3 compatibility (done), laptop runs
(they stay in the thesis, labelled as laptop runs and, for RustFS, as version 1.0.0-beta.8).

The systems do not store the same redundancy: Ceph, Garage and SeaweedFS keep three full copies, RustFS 1.0.1 keeps
an erasure coded set of 3 data and 3 parity shards (about 2.0 times raw size, proven in the RustFS record R1). So
equal "parameters" means equal hardware, client, workload and procedure, not equal internal cost. The thesis states
this next to every comparison.

## 2. Platform (as it is today)

1. Storage nodes: ceph0 (hostname debian, 192.168.1.72), ceph1 (.71), ceph2 (.70). 4 vCPU, 7.7 GiB RAM, two XFS data
   disks of 32 GB each (/srv/s3/disk1 and disk2), rootful podman, host networking. CPU model QEMU Virtual CPU 2.5+.
2. Systems and versions: Ceph Tentacle 20.2.4 (RGW), SeaweedFS 4.25 (pinned digest), Garage v1.0.0 (pinned digest),
   RustFS 1.0.1 (pinned digest). Deployed as in setup_notes.md, with the defaults of each system, no tuning.
3. One system runs at a time, the other three are stopped. Ceph is stopped with noout and norebalance set.

## 3. Load generator (the main open decision)

Evidence that placement matters: with the client on ceph0 against its own node, Ceph gave 45.45 to 47.31 MiB/s; with
the client on ceph2 against ceph0 the same batch gave 73.03 to 78.02 MiB/s (five runs each, ranges do not overlap,
results/warp-ceph-coresidency-2026-09-23.txt). A co-resident client takes CPU from the system under test, and that
bias is larger for a system that spends more CPU per request. So the load generator must not share a node with the
storage it measures.

Decision of 10 October 2026 (Maaz): nobody is asked for an extra VM, this is not a critical decision. Warp runs on ceph2
and talks to the S3 endpoints of all three nodes (option B). Then ceph2 carries the client cost for every system. The
bias is the same in kind for all four systems but not in size, and the thesis states it as a limit. An extra load VM
(option A, 4 vCPU on the same subnet) would be better and is named in the thesis as the improvement for later work.
Results of A and B would never be mixed in one chart.

Check on every run, either option: CPU of the load node (sar). A run with the load node above 80 percent busy is
marked as client limited and not used for a ranking.

## 4. Tool

1. Primary: Warp v1.8.0 (the version that works with Ceph RGW, Issue 12 in setup_notes.md; v1.5.0 and v1.7.0 were used
   earlier on the laptop and are not used here). The .deb file is hashed on install and the hash recorded.
2. Secondary (Prof. Baun's baseline tool): ossperf, small fixed set at the end, reported in its own table. Warp and ossperf
   answer different questions (persistent client against one AWS CLI process per file, record of 23 September 2026),
   so their numbers are never in one chart. Any AWS CLI step uses AWS_REQUEST_CHECKSUM_CALCULATION=when_required for all
   four systems (finding F1: Garage v1.0.0 rejects the default multipart checksums).
3. Warp options common to all runs: all three endpoints in --host (comma separated list, requests are spread by Warp),
   path style, --benchdata for every run, a dedicated bucket that Warp may wipe, credentials taken from the key file on
   the load node by the wrapper script and never printed. Garage needs --region garage and a key allowed to create buckets
   (or the bucket made with the Garage CLI first).

## 5. Workload

Fixed duration 60 seconds per recorded run, preceded by one warm up run of 30 seconds that is discarded. Three recorded
runs per configuration. Per configuration the thesis reports the median and the minimum and maximum of the three
runs. No significance claim is made from three runs. If two systems' ranges overlap, the thesis says "not separated".

Series:
1. Object size series, concurrency 8, PUT and GET: 50 KiB, 1 MiB, 16 MiB, 100 MiB. (8 configurations)
2. Concurrency series, 1 MiB, PUT and GET: 1, 4, 16, 64. Add 128 for a system whose throughput at 64 is still more than
   10 percent above the value at 16 (Ceph was still rising at 64 on 23 September). (8 configurations, plus 0 to 2)
3. Mixed workload, 1 MiB, concurrency 16, Warp default mix (GET, PUT, STAT, DELETE). (1 configuration)

1 GiB objects are not part of the cross system set (the Ceph 1 GiB point needed concurrency 2 and hit the capacity limit,
record of 23 September). The Ceph point stays as a Ceph only data point.

GET dataset: prepared once per configuration (not counted in the timing) and read by the warm up and the three recorded
runs. Size of the dataset: about 8 GiB, so that it is not smaller than the RAM of one node (7.7 GiB): 50 KiB 50000 objects
(2.4 GiB, the object count is the limit here), 1 MiB 8192 objects, 16 MiB 512 objects, 100 MiB 80 objects.
Page cache on the storage nodes is emptied before every GET run (sync, then echo 3 > /proc/sys/vm/drop_caches on the three
storage nodes, done by the script over key based ssh from ceph2). This is a deliberate step and it is written in the record.
How much of the GET result still comes from cache is not known and is a stated limit. Without the ssh key the script does not
do this and the record says so.

PUT: Warp writes new objects for 60 seconds and removes them at the end. Space on the data disks is checked with df on
the three nodes before every run, and a run does not start below 50 percent free (deletes are not instantly reclaimed:
Ceph needs garbage collection after a bucket removal, record of 24 September; SeaweedFS needs vacuum; Garage collects
blocks later; for each system the way back to the clean state is part of its wrapper script and is checked, not assumed).

## 6. Measured and reported

Per run: throughput in MiB/s (Warp's unit) and in Mbps (thesis standard, 1 MiB/s = 8.3886 Mbps, marked as converted),
objects per second, average latency, median, p90 and p99 latency, time to first byte for GET, number of errors, the
measured window (Warp trims ramp up and down; the measured window, not the requested duration, is quoted).
Per system and run in the background: sar on the three storage nodes and the load node (CPU, disk, network at 1 second
intervals), saved next to the Warp output.
Zero errors is expected. Any error count above zero is reported with the run, the run is not silently repeated: it is
repeated and BOTH records are kept.

## 7. Control measurements (before and after each system)

1. Network: iperf3 from the load node to each storage node (Ceph earlier: 8.64 Gbit/s between nodes).
2. Disk reference: dd with oflag=direct and conv=fsync of 2 GiB onto a scratch file on /srv/s3/disk1 of each storage node
   (a file on the mounted XFS filesystem, never the block device), removed afterwards.
3. Versions, container digests, uptime and free space recorded in the header of every result file.
Purpose: the systems run on different days on a shared hypervisor. If the reference values differ between the days, the
thesis says so and does not treat the difference between systems as clean.

## 8. Pre flight for each system (not counted)

1. All three S3 endpoints answer on the load node.
2. 20 second PUT and GET at 1 MiB, concurrency 4, zero errors (the pipeline check done on the laptop in August, repeated
   on the VMs with Warp v1.8.0).
3. One 100 MiB object through Warp (Warp switches to multipart above 16 MiB): this tests whether Garage and the others
   accept Warp's multipart upload. F1 was found with the AWS CLI, not with Warp, so it is not known if it applies here.
4. Warp options used in the wrapper (for example how a GET dataset is reused between runs) are checked against warp --help
   on the load node before the first run, because they are written here from memory.

## 9. Procedure per system (about 2 hours of load, one working day with set up and clean up)

1. System started, state checked, control measurements.
2. Pre flight.
3. Series 1, 2 and 3 in this order, each configuration: warm up, three recorded runs, free space check, clean state.
4. Control measurements again. Result files hashed and archived the same day. Output of the load node pulled out by
   the usual route (the VM Claude session or scp typed by the user).
Each step is a script with a pinned hash (like deploy/*/ *-tests.sh), run on the load node and ceph0 as needed.

## 10. Threats to validity (written down now, to be repeated in the thesis)

1. Redundancy differs (3 copies against 3+3 erasure coding), so write cost differs by design.
2. Durability settings differ by default (flush behaviour of each system is not yet documented here). To be read from the
   documentation and the running configuration for each system and recorded before the first run. OPEN.
3. Shared hypervisor: other guests can disturb a day. Control measurements show it only in part.
4. GET results can contain page cache effects (see section 5).
5. Three nodes, 60 second windows, three runs: ranges only, no statistical tests.
6. Load node option B (if used) adds client cost on ceph2 for every system.
7. Different versions of the systems exist in the laptop results (RustFS beta.8) and in the early Ceph figures (1 vCPU).
   Those results are not mixed with the VM results; the early Ceph single core figures are replaced by this series.
8. The S3 endpoint list per system (does each system answer S3 on all three nodes?) is assumed from the deployments and is
   checked in the pre flight. OPEN until then.

## 11. Decisions needed from Maaz before the first run

1. Load node: settled on 10 October, Warp on ceph2, nobody asked (section 3).
2. Series and sizes as in section 5 (16 configurations of 3.5 minutes plus the mixed run)?
3. drop_caches before every GET run on the storage nodes: yes (needs decision 5).
4. ossperf as small secondary set at the end: yes, or only if time remains?
5. Key based ssh from ceph2 to ceph0 and ceph1 (two commands typed by Maaz, the key pair is removed at the end of the VM
   work): needed for the free space check, the cache drop and sar on the storage nodes. The script scripts/perf-warp.sh also runs
   without it, but then only ceph2 is monitored and the record says so.

## 12. Script (written 10 October 2026)

scripts/perf-warp.sh <system> <preflight|controls|size|conc|mixed|all|one>, run on ceph2. Tested on the laptop against a throwaway
RustFS 1.0.1 single node container (Warp v1.5.0): the preflight and the mixed series ran. That test found that the flag for
reading existing objects is spelled --list-existing in Warp v1.5.0 (the script now detects the spelling) and that Warp draws a
progress bar that has to be stripped from the saved text. The laptop test says nothing about performance and uses no VM.
