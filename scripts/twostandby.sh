# env: NS, C (cluster), RUN, KILLORCH=0|1, GAP (s between standby kills)
set -u
NS=${NS:-hb}; C=${C:-hbc}; RUN=${RUN:-two-1}; GAP=${GAP:-14}; KILLORCH=${KILLORCH:-0}
OUT=/tmp/ack; L=$OUT/$RUN.logs; mkdir -p $L
ts() { date -u +%T; }
pools() { kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##'; }
role() { timeout 10 kubectl -n $NS exec $1 -c postgres -- env PGPASSWORD=postgres psql -h /var/lib/pooler/pg_sockets -U postgres -Atc "select pg_is_in_recovery()" 2>/dev/null; }
primary() { for p in $(pools); do [ "$(role $p)" = f ] && echo $p; done | head -1; }
syncnames() { timeout 10 kubectl -n $NS exec $1 -c postgres -- sh -c 'grep synchronous_standby_names $(find /var/lib/pooler -name postgresql.auto.conf | head -1)' 2>/dev/null | sed 's/synchronous_standby_names = //'; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = Healthy ] && break; sleep 5; done
GW=$(kubectl -n $NS get svc $C-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
P=$(primary); set -- $(pools | grep -v "^$P$"); A=$1; B=$2
echo "$(ts) primary=${P: -1} A=${A: -1} B=${B: -1} sync=$(syncnames $P)"
for p in $(pools); do kubectl -n $NS logs -f $p -c multipooler --since=1s > $L/${p: -1}.multipooler.log 2>&1 & done
kubectl -n $NS logs -f $(kubectl -n $NS get pods -o name | grep multiorch | head -1) --since=1s > $L/multiorch.log 2>&1 &
/tmp/ackcheck run -dsn "$DSN" -run $RUN -workers 8 -rate 20 -timeout 2s -duration 330s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
sleep 30; kubectl -n $NS delete pod $A --grace-period=0 --force >/dev/null 2>&1; echo "$(ts) killed standby ${A: -1}"
sleep $GAP; kubectl -n $NS delete pod $B --grace-period=0 --force >/dev/null 2>&1; echo "$(ts) killed standby ${B: -1}"
[ "$KILLORCH" = 1 ] && { sleep 7; kubectl -n $NS delete $(kubectl -n $NS get pods -o name | grep multiorch | head -1) --grace-period=0 --force >/dev/null 2>&1; echo "$(ts) killed multiorch"; }
for i in $(seq 1 26); do
  sleep 10
  w=$(PGPASSWORD=postgres PGCONNECT_TIMEOUT=3 timeout 6 psql -h $GW -U postgres -Atc "select 1" 2>&1 | head -1 | cut -c1-60)
  echo "$(ts) write_path=[$w] acks=$(grep -c '"r":"ok"' $OUT/$RUN.events.jsonl) primary_sync=$(syncnames $P)"
done
wait $APID
/tmp/ackcheck verify -wait 30s -dsn "$DSN" -run $RUN -out $OUT > $OUT/$RUN.verify.json 2>&1; echo "verify: $(head -c 300 $OUT/$RUN.verify.json | tr '\n' ' ')"
