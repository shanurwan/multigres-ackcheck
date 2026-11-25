set -u
NS=ha; OUT=/tmp/ack; RUN=${RUN:-starve-1}; BURN=${BURN:-8}; L=$OUT/$RUN.logs; mkdir -p $L
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
ts() { date -u +%T.%3N; }
BPIDS=""
cleanup() { [ -n "$BPIDS" ] && kill $BPIDS 2>/dev/null; kill $(jobs -p) 2>/dev/null; }
trap cleanup EXIT
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')" = Healthy ] && break; sleep 5; done
P=$(timeout 20 sh /tmp/primary.sh 2>/dev/null)
echo "$(ts) start primary=${P: -1} burners=$BURN"
PODS=$(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##')
MO=$(kubectl -n $NS get pods -o name | grep multiorch | head -1)
for p in $PODS; do for c in multipooler postgres; do kubectl -n $NS logs -f $p -c $c --since=1s > $L/${p: -1}.$c.log 2>&1 & done; done
kubectl -n $NS logs -f $MO --since=1s > $L/multiorch.log 2>&1 &
kubectl -n $NS get events -w --output-watch-events > $L/events.log 2>&1 &
/tmp/ackcheck run -dsn "$DSN" -run $RUN -workers 8 -rate 50 -timeout 2s -duration 180s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
sleep 20
for i in $(seq 1 $BURN); do sh -c 'while :; do :; done' & BPIDS="$BPIDS $!"; done
echo "$(ts) burners on"
sleep 25
P2=""; [ "${NOKILL:-0}" = 1 ] || P2=$(timeout 20 sh /tmp/primary.sh 2>/dev/null); echo "$(ts) forcekill primary=${P2: -1}"
[ -n "$P2" ] && kubectl -n $NS delete pod $P2 --grace-period=0 --force >/dev/null 2>&1
sleep 65; [ -n "$BPIDS" ] && kill $BPIDS; BPIDS=""; echo "$(ts) burners off"
wait $APID
for p in $(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##') ${MO#pod/}; do
  for c in $(kubectl -n $NS get pod $p -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}'); do
    kubectl -n $NS logs $p -c $c --previous > $L/prev.${p}.$c.log 2>/dev/null || rm -f $L/prev.${p}.$c.log
  done
done
grep -E "Killing|OOM|liveness" $L/events.log | awk '{print $NF" "$0}' | cut -c1-200 | tail -20
/tmp/ackcheck verify -dsn "$DSN" -run $RUN -out $OUT | python3 -c 'import json,sys; s=json.load(sys.stdin); print({k:s[k] for k in ["acked","failed","ambiguous","lost_acked","ambiguous_present","unexpected_rows","acked_with_syncrep_warning","notices"]}); print("outages",[round(o["seconds"],1) for o in s["outages"]]); print("lost_sample",s.get("lost_acked_sample"))'
