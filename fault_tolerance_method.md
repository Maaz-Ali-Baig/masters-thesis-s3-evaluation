# Fault tolerance method for the four systems on the university VMs

Status: DRAFT of 10 October 2026, not yet approved. Nothing in this file has been run. Statements about what a system
will do under failure are HYPOTHESES to be settled by the test, never findings.

## 1. Question

What happens to availability and to data when one node, or two of the three nodes, stop without warning, and what
does it take for the system to be whole again? Same failure, same probe, same checks for Ceph, SeaweedFS, RustFS and
Garage, one system at a time.

The redundancy is not the same in all four (Ceph, Garage and SeaweedFS keep three copies, RustFS 1.0.1 keeps an
erasure set of 3 data and 3 parity shards, record R1 of 9 October). The thesis reports the same observations for each
and does not call the systems equal. The exact redundancy setting of each system (for Ceph the pool size and min_size,
for SeaweedFS the replication setting, for Garage the replication factor, for RustFS the parity) is read from the running
system and recorded in the header of the result before the first scenario. Until then it is not written here.

Earlier record: Ceph, one node hard stopped, 21 and 22 September 2026 (results/ceph-faulttolerance-rerun-2026-09-22.txt,
268 probes, 0 failures, data redundancy restored in under 4 min 22 s, upper bound). That run had one OSD per host and
a probe against one endpoint only. It stays in the thesis as an earlier, differently configured run and is repeated here
with the common method.

## 2. How the failure is made

Hard stop of the virtual machine through Proxmox (power off, not a shutdown), done by Maaz. This is the closest to a power
loss that the platform allows and it is identical for all four systems. A container kill is not used as the main test
(the page cache of the host survives it). The containers have --restart no, so after the VM boots the system is started
again with its node script (Ceph starts by itself through its systemd target). The time between VM boot and system start
is kept short and written down.

Node roles: ceph0 runs the probe and the checks and is never stopped. ceph1 is stopped in scenario S1. ceph1 and ceph2 are
stopped together in S2. Where a system has a leader (SeaweedFS master, Ceph monitor), the leader at the time is read
and written in the record. If the leader is not ceph1, an extra run S1b with the leader stopped is done when time allows.

## 3. The probe (runs from the first baseline minute to the end of verification)

A script on ceph0, every 2 seconds:
1. For each of the three S3 endpoints: a HEAD of a fixed object. Logged as UP or DOWN with the HTTP code. Gives the
   state of each endpoint, with a bracket for the failure time (last UP to first DOWN).
2. One new object, 1 MiB of random content, number i, written through the first endpoint that works (the starting
   endpoint rotates). The script logs i, the endpoint, ACK or FAIL, the first 200 characters of the error and the
   sha256 of the content. Only objects with ACK count as written.
The AWS CLI is used with AWS_REQUEST_CHECKSUM_CALCULATION=when_required for all four systems (finding F1).
All times are the clock of ceph0. The time of the Proxmox click is not trusted; the failure is bracketed by the probe.

Before the first scenario a seed set is written: 40 objects of 1 MiB, 3 of 6 MiB and one of 100 MiB (multipart), with the
sha256 of each, kept on ceph0 and in the record.

## 4. Scenarios (each ends with full verification before the next begins)

S1, one node hard stopped.
1. Baseline 5 minutes, all up, probe running.
2. ceph1 hard stopped. Outage of 12 minutes (longer than the 600 s default after which Ceph marks an OSD out, so that
   this timer is part of the test for Ceph).
3. During the outage: the seed set is read through a surviving endpoint (hash compared), and the probe keeps writing.
4. ceph1 powered on, system started on ceph1, the moment it answers is logged.
5. Resync watched until stable (section 5), then verification (section 6).

S2, two nodes hard stopped (ceph1 and ceph2 at the same time).
1. Baseline 5 minutes. Both stopped. Outage of 6 minutes.
2. During the outage: what ceph0 answers for reads and writes (codes and messages), and what its own status says.
3. Both powered on, systems started, time until the first successful write and read through every endpoint,
   resync watched, verification.
Hypothesis (to be tested, not a result): with two of three nodes gone no system accepts writes, and reads of data whose
shards or copies were mostly on the missing nodes fail. The test shows what each system really does.

S3, optional if time remains: planned restart of one node (stop of the system service or container, no VM power off),
to separate a planned maintenance from a crash.

## 5. Recovery observations (from the moment the node is started)

Every 20 seconds on all three nodes, into one log: (a) bytes on the data directories (du -sb of the system's directory
on /srv/s3/disk1 and disk2), (b) the native status of the system (Ceph: the pgs line of ceph -s; Garage: garage status;
SeaweedFS: the master topology/volume list; RustFS: the command or endpoint that is found in the dry run). The native
command per system is fixed in the dry run on RustFS and for the other systems in their pre flight, and written in the
record. Resync is called finished when the bytes on the returned node are stable for 3 minutes and the native status
reports healthy. Two times are reported and never mixed: the time to reach healthy by the native status, and the time to
stable bytes. (The Ceph record of 22 September showed that a management check can delay HEALTH_OK long after the data is
safe.)

## 6. Verification (all must be answered, yes or no, with the evidence)

1. Every object with ACK in the ledger is read through each of the three endpoints and its sha256 equals the ledger.
2. The seed set is read through each endpoint, hashes equal.
3. Number of ACK and FAIL, first FAIL after the stop, longest gap without ACK, first ACK after the stop, first UP of each
   endpoint after start.
4. Objects written during the outage are present on the returned node (bytes grew, and the objects read through the
   returned node's own endpoint equal the ledger).
5. The record keeps the raw probe log and the hash of every log.

## 7. Safety and order

1. Never a write to /dev/sdb on the Ceph VMs.
2. The result files get hashes on the VM and on the laptop (as for the compat probe).
3. The VM Claude sessions are used as before: hostname first in every command, output copied character for character,
   important values checked by hash on the VM.
4. The first system is RustFS and its run is a dry run for the scripts. If the script has to be corrected, the first run
   stays in the record as a first run.
5. Time per system: S1 about 45 minutes, S2 about 40 minutes, plus set up and verification.

## 8. Threats to validity

1. Different redundancy per system (section 1).
2. The failure time is bracketed by a 2 second probe, so every time has an error of a few seconds.
3. Proxmox power off is one kind of failure. Disk failure, network partition and slow nodes are not tested.
4. One probe client on ceph0 with three endpoints; real clients with a load balancer could behave differently.
5. The observed recovery depends on how fast the system is started after the VM boots (written down).
6. One run per scenario and system. A single run shows what can happen, not how often.
7. Defaults of each system are used (timers like the Ceph out interval are part of the result).
