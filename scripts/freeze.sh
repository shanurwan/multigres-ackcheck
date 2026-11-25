set -u
NS=ha; OUT=/tmp/ack; RUN=${RUN:-freeze-1}
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
pgpids='for f in /proc/[0-9]*/comm; do [ "$(cat $f 2>/dev/null)" = postgres ] && d=${f%/comm} && echo ${d#/proc/}; done'
sig() { kubectl -n $NS exec $1 -c postgres -- sh -c "kill -$2 \$($pgpids) 2>/dev/null; echo sent"; }
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')" = Healthy ] && break; sleep 5; done
P=$(sh /tmp/primary.sh 2>/dev/null)
S=$(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##' | grep -v "$P")
echo "$(date -u +%T.%3N) primary=$P standbys=$(echo $S | tr '\n' ' ')"
/tmp/ackcheck run -dsn "$DSN" -run $RUN -workers 8 -rate 20 -timeout 30s -duration 150s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
sleep 20
for s in $S; do echo "$(date -u +%T.%3N) STOP $s $(sig $s STOP)"; done
for i in 1 2 3 4; do sleep 10; echo "$(date -u +%T.%3N) primary_now=$(sh /tmp/primary.sh 2>/dev/null | tail -c 3) notices=$(wc -l < $OUT/$RUN.notices.jsonl) acks=$(grep -c '"r":"ok"' $OUT/$RUN.events.jsonl)"; done
for s in $S; do echo "$(date -u +%T.%3N) CONT $s $(sig $s CONT)"; done
sleep 20
P2=$(sh /tmp/primary.sh 2>/dev/null); echo "$(date -u +%T.%3N) forcekill primary $P2"
kubectl -n $NS delete pod $P2 --grace-period=0 --force >/dev/null 2>&1
wait $APID
/tmp/ackcheck verify -dsn "$DSN" -run $RUN -out $OUT | python3 -c 'import json,sys; s=json.load(sys.stdin); print({k:s[k] for k in ["acked","failed","ambiguous","lost_acked","ambiguous_present","acked_with_syncrep_warning","lost_with_syncrep_warning","notices"]}); print("outages",[round(o["seconds"],1) for o in s["outages"]])'
