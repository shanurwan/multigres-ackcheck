# multigres-ackcheck

Checks one guarantee of a [Multigres](https://github.com/multigres/multigres) cluster from the client side: **a write the server acknowledged is still there after failures.**

`ackcheck` runs writers through Multigateway. Each writer inserts rows with a key nobody else uses (`run, worker, seq`) and logs the outcome of every attempt. Afterwards `ackcheck verify` reads the table back and compares.

| Outcome | Meaning | What verify checks |
|---|---|---|
| `ok` | the server acknowledged the commit | the row must be present; a missing row counts as **lost** |
| `failed` | not sent, or the server answered with an error | the row must be absent |
| `ambiguous` | the connection broke after the statement was sent | either is allowed; verify reports how many were present |

With `-churn`, every insert opens a new connection, so every write also authenticates.

`ackcheck` also records every NOTICE/WARNING the server sends with the write it came with, so an acknowledgement that Postgres gave after cancelling a synchronous-replication wait (`canceling wait for synchronous replication`) would be counted separately.

## Running it

```sh
go build -o ackcheck .
GW=$(kubectl -n <ns> get svc <cluster>-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:<password>@$GW:5432/postgres?sslmode=disable"

./ackcheck run    -dsn "$DSN" -run r1 -workers 8 -rate 50 -timeout 2s -duration 3m -out results
# inject faults while it runs (scripts/)
./ackcheck verify -dsn "$DSN" -run r1 -out results
```

`verify` prints a JSON summary: acknowledged, failed, ambiguous, lost, write outages (gaps with no acknowledged commit), and latency percentiles for acknowledged writes. It exits non-zero if any acknowledged write is lost.

## Fault scripts

All in `scripts/`, run from a host with `kubectl` access to the cluster:

- `drill.sh`: force-delete the primary pod, delete it gracefully, or SIGKILL its postmaster
- `freeze.sh`: SIGSTOP both standbys so commits block on synchronous replication
- `lagcrash.sh`: freeze one standby, then SIGKILL Postgres on the primary and the other standby together
- `starve.sh`: CPU starvation with an optional primary kill
- `nemesis.sh` and `campaign.sh`: randomized runs with 2–3 faults each (pod kills, Postgres kills, multiorch and gateway kills, standby freezes), half of them with the VM's CPU pinned to one host core. Logs from every component, the operator and Kubernetes events are kept per run.
- `twostandby.sh`: both standby pods force-deleted a few seconds apart, optionally followed by a multiorch kill
- `authchurn.sh` and `psqlrepro.sh`: logins during primary crashes (the repro for [#1728](https://github.com/multigres/multigres/issues/1728))

The scripts assume a cluster named `hac` in namespace `ha`, `ackcheck` at `/tmp/ackcheck`, and, for `campaign.sh`, a QEMU VM it can pin with `taskset`. They were written for this lab; adjust names before reusing them.

## Results

Setup: K3s v1.35.10 in one 4-vCPU / 5 GiB VM; multigres-operator main (817402a0) with its default images (multigres 08b06091); one cell, 3 poolers, `AT_LEAST_2`. 8 writers, 50 inserts/s each (20/s in the `two-*` runs); 2 s statement timeout except where a script sets another. "1 core" means the VM's QEMU process was pinned to a single host core during the faults; "host contention" means my own builds were running on the same host.

**37 runs, 1,355,685 acknowledged writes, 42 lost (all in one run, see below).**

| Run | Faults | CPU | Acknowledged | Failed | Ambiguous | Lost | Longest outage (s) |
|---|---|---|---|---|---|---|---|
| forcekill-1 | force-delete primary pod | normal | 42,520 | 0 | 8 (0 present) | **0** | 3.4 |
| forcekill-2 | force-delete primary pod | normal | 41,894 | 0 | 8 (0 present) | **0** | 3.8 |
| forcekill-3 | force-delete primary pod | host contention | 9,647 | 92 | 32 (24 present) | **0** | 6.4 |
| forcekill-4 | force-delete primary pod | host contention | 18,298 | 36 | 8 (0 present) | **0** | 11.5 |
| forcekill-5 | force-delete primary pod | host contention | 1,945 | 1,541 | 56 (48 present) | **42** | 4.8 |
| graceful-1 | graceful delete of primary pod | host contention | 7,163 | 22 | 46 (44 present) | **0** | 2.8 |
| podkill-1 | force-delete primary pod | normal | 63,093 | 8 | 8 (0 present) | **0** | 8.8 |
| authchurn-1 | new connection per insert, SIGKILL Postgres on primary x5 | normal | 15,371 | 1,903 | 0 | **0** | 10.1 |
| freeze-1 | SIGSTOP both standbys | normal | 3,272 | 38 | 26 (26 present) | **0** | 0.0 |
| lagcrash-1 | freeze one standby, SIGKILL Postgres on primary and the other standby | normal | 29,065 | 1,935 | 0 | **0** | 10.3 |
| starve-1 | 8 CPU burners in the VM, force-delete primary pod | normal | 52,621 | 0 | 8 (0 present) | **0** | 3.5 |
| starve-only-1 | none (starvation only) | 1 core | 26,511 | 0 | 0 | **0** | 0.0 |
| starve-only-2 | none (starvation only) | 1 core | 28,445 | 0 | 0 | **0** | 0.0 |
| starve-only-3 | none (starvation only) | 1 core | 14,061 | 0 | 0 | **0** | 0.0 |
| starve-pin-1 | force-delete primary pod | 1 core | 35,921 | 3,056 | 8 (0 present) | **0** | 43.8 |
| starve-pin-2 | force-delete primary pod | 1 core | 35,258 | 24 | 8 (0 present) | **0** | 8.3 |
| starve-pin-3 | force-delete primary pod | 1 core | 34,748 | 24 | 8 (0 present) | **0** | 8.5 |
| starve-pin-4 | force-delete primary pod | 1 core | 36,955 | 39 | 8 (0 present) | **0** | 12.0 |
| nem-0717-1 | freeze standby pgkill primary | 1 core | 42,523 | 68 | 0 | **0** | 16.5 |
| nem-0722-2 | pgkill primary kill primary pod | 1 core | 40,639 | 8,421 | 0 | **0** | 55.6 |
| nem-0726-3 | kill multiorch kill standby pod | 1 core | 46,064 | 0 | 0 | **0** | 0.0 |
| nem-0731-4 | kill multiorch freeze standby | 1 core | 45,746 | 0 | 0 | **0** | 0.0 |
| nem-0736-5 | pgkill primary pgkill standby | normal | 87,387 | 19 | 0 | **0** | 2.3 |
| nem-0741-6 | pgkill primary kill gateway kill standby pod | normal | 82,838 | 3,106 | 8 (6 present) | **0** | 8.3 |
| nem-0752-1 | pgkill primary kill primary pod kill primary pod | 1 core | 36,806 | 6,635 | 8 (0 present) | **0** | 45.5 |
| nem-0757-2 | kill standby pod kill standby pod | 1 core | 31,276 | 0 | 40 (40 present) | **0** | 12.1 |
| nem-0801-3 | freeze standby pgkill primary kill primary pod | 1 core | 18,474 | 18,362 | 57 (57 present) | **0** | 16.5 |
| nem-0806-4 | kill primary pod freeze standby | 1 core | 24,932 | 8,320 | 24 (8 present) | **0** | 37.7 |
| two-A1-0900 | force-delete both standby pods 14 s apart | normal | 49,221 | 0 | 80 (80 present) | **0** | 20.9 |
| two-A2-0907 | force-delete both standby pods 14 s apart | normal | 49,135 | 0 | 80 (80 present) | **0** | 21.3 |
| two-A3-0914 | force-delete both standby pods 14 s apart | normal | 49,234 | 0 | 80 (80 present) | **0** | 20.5 |
| two-B1-0921 | force-delete both standby pods 14 s apart, kill multiorch | normal | 49,514 | 0 | 72 (72 present) | **0** | 19.5 |
| two-B2-0928 | force-delete both standby pods 14 s apart, kill multiorch | normal | 49,103 | 0 | 80 (80 present) | **0** | 20.8 |
| two-B3-0935 | force-delete both standby pods 14 s apart, kill multiorch | normal | 50,662 | 0 | 40 (40 present) | **0** | 11.5 |
| two-C1-0942 | force-delete both standby pods 14 s apart, kill multiorch | 1 core | 29,311 | 2,261 | 317 (314 present) | **0** | 103.5 |
| two-C2-0951 | force-delete both standby pods 14 s apart, kill multiorch | 1 core | 37,651 | 0 | 104 (104 present) | **0** | 28.9 |
| two-C3-0958 | force-delete both standby pods 14 s apart, kill multiorch | 1 core | 38,381 | 0 | 80 (80 present) | **0** | 22.3 |

Notes:

- "Longest outage" is the longest gap with no acknowledged commit from any writer.
- In the `two-*` runs both standbys are down at once, so synchronous commits wait until one is back; the ~20 s gaps there are expected under `AT_LEAST_2`.
- Two runs are not in the table: `nem-1` (I reused a run id, so its keys collided with an earlier run) and `nem-0811-5`, where the shard never got a writable primary again ([multigres/multigres#1729](https://github.com/multigres/multigres/issues/1729)).

## What it found

- **[multigres/multigres#1728](https://github.com/multigres/multigres/issues/1728).** When Postgres on the primary crashes, the gateway answers logins with the correct password with `28P01 password authentication failed`. Reproduced on demand, with plain `psql` too: 10 of 3,031 logins over 3 crashes.
- **[multigres/multigres#1729](https://github.com/multigres/multigres/issues/1729).** Once, after two standby pods were killed 16 s apart under CPU starvation, the shard stayed without a writable primary for more than 45 minutes while the operator's resources reported `Healthy`. Not reproduced in 8 targeted trials. Logs and config are in `results/incident-stall-0811/`.

## Unverified: 42 acknowledged writes missing in `forcekill-5`

In `forcekill-5`, run while my own builds were starving the host, 42 acknowledged writes were missing from all three Postgres instances when verified. They were all acknowledged between 05:18:54 and 05:18:56.5 UTC, and each took 0.25 to 0.9 s. At 05:18:56.7 the primary's pooler first logged that its Postgres was unreachable; the container restarted, probably after failed liveness probes, but the Kubernetes events had expired before I looked.

I could not find out why. Multiorch's log for that minute was lost when its container restarted, and I deleted and recreated the cluster before investigating further, so the database is gone too. What is left is the client-side record in `results/incident-forcekill-5/`. The same harness ran 31 more times afterwards (18 of them with the VM pinned to one core) without losing an acknowledged write. Treat this as an observation, not a finding.

## Relation to Multigres's own tests

Multigres already checks write durability in its end-to-end tests (for example `go/test/endtoend/multiorch/dead_primary_recovery_test.go`), runs a `LeaderQuorumWritesStalled` analyzer in multiorch, and the operator's observer has a blocked-writes probe. Those run components as local processes or observe from inside the cluster. This harness checks from a client, through Multigateway, on Kubernetes, with faults delivered the way Kubernetes delivers them: pod deletions, liveness-probe kills, and CPU starvation.

## Limits

- One node, so no zone or node failures yet. The same harness is meant to run on a 3-AZ EKS cluster.
- Faults are injected at the pod and process level; no network partitions yet.
- Writes are single-row autocommit inserts. Multi-statement transactions and reads are not checked.
