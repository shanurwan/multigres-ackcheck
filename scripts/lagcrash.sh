set -u
NS=ha; OUT=/tmp/ack; RUN=${RUN:-lagcrash-1}; L=$OUT/$RUN.logs; mkdir -p $L
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
pgpids='for f in /proc/[0-9]*/comm; do [ "$(cat $f 2>/dev/null)" = postgres ] && d=${f%/comm} && echo ${d#/proc/}; done'
sig() { timeout 10 kubectl -n $NS exec $1 -c postgres -- sh -c "kill -$2 \$($pgpids) 2>/dev/null; echo ok"; }
role() { timeout 4 kubectl -n $NS exec $1 -c postgres -- env PGPASSWORD=postgres psql -h /var/lib/pooler/pg_sockets -U postgres -Atc "select case when pg_is_in_recovery() then 'standby '||coalesce(pg_last_wal_replay_lsn()::text,'') else 'PRIMARY '||pg_current_wal_lsn() end" 2>/dev/null || echo down; }
ts() { date -u +%T.%3N; }
cleanup() { for p in $(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed "s#pod/##"); do sig $p CONT >/dev/null 2>&1; done; kill $(jobs -p) 2>/dev/null; }
trap cleanup EXIT
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')" = Healthy ] && break; sleep 5; done
PODS=$(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##')
P=""; for p in $PODS; do case "$(role $p)" in PRIMARY*) P=$p;; esac; done
set -- $(echo "$PODS" | grep -v "$P"); A=$1; B=$2
echo "$(ts) primary=${P: -1} A=${A: -1} B=${B: -1}"
MO=$(kubectl -n $NS get pods -o name | grep multiorch | head -1)
for p in $PODS; do for c in multipooler postgres; do kubectl -n $NS logs -f $p -c $c --since=1s > $L/${p: -1}.$c.log 2>&1 & done; done
kubectl -n $NS logs -f $MO --since=1s > $L/multiorch.log 2>&1 &
kubectl -n $NS logs -f deploy/hac-zone-a-multigateway-cfc4bf4e --since=1s > $L/gateway.log 2>&1 &
/tmp/ackcheck run -dsn "$DSN" -run $RUN -workers 8 -rate 20 -timeout 10s -duration 200s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
sleep 15; echo "$(ts) STOP B ${B: -1} $(sig $B STOP)"
sleep 15
echo "$(ts) roles: P=$(role $P) A=$(role $A)"
sig $P KILL >/dev/null & sig $A KILL >/dev/null & wait %-1 2>/dev/null; sleep 1
echo "$(ts) KILLED postgres on P and A; CONT B $(sig $B CONT)"
for i in $(seq 1 30); do sleep 5; echo "$(ts) P=$(role $P) A=$(role $A) B=$(role $B) acks=$(grep -c '"r":"ok"' $OUT/$RUN.events.jsonl)"; done
wait $APID
/tmp/ackcheck verify -dsn "$DSN" -run $RUN -out $OUT | python3 -c 'import json,sys; s=json.load(sys.stdin); print({k:s[k] for k in ["acked","failed","ambiguous","lost_acked","ambiguous_present","unexpected_rows","acked_with_syncrep_warning","notices"]}); print("outages",[round(o["seconds"],1) for o in s["outages"]])'
kill $(jobs -p) 2>/dev/null
