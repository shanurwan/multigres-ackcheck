set -u
NS=ha; OUT=/tmp/ack; RUN=${RUN:-authchurn-1}; L=$OUT/$RUN.logs; mkdir -p $L
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
ts() { date -u +%T.%3N; }
pgpids='for f in /proc/[0-9]*/comm; do [ "$(cat $f 2>/dev/null)" = postgres ] && d=${f%/comm} && echo ${d#/proc/}; done'
role() { timeout 15 kubectl -n $NS exec $1 -c postgres -- env PGPASSWORD=postgres psql -h /var/lib/pooler/pg_sockets -U postgres -Atc "select pg_is_in_recovery()" 2>/dev/null; }
primary() { for p in $(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##'); do [ "$(role $p)" = f ] && echo $p; done | head -1; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')" = Healthy ] && break; sleep 5; done
GP=$(kubectl -n $NS get pods -o name | grep multigateway | head -1)
kubectl -n $NS logs -f $GP --since=1s > $L/gateway.log 2>&1 &
/tmp/ackcheck run -churn -dsn "$DSN" -run $RUN -workers 8 -rate 10 -timeout 3s -duration 230s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
T0=$(date +%s)
for at in 30 70 110 150 190; do
  sleep $(( at - ($(date +%s) - T0) ))
  P=$(primary); timeout 10 kubectl -n $NS exec $P -c postgres -- sh -c "kill -KILL \$($pgpids)" >/dev/null 2>&1
  echo "$(ts) t+${at}s SIGKILL postgres on primary ${P: -1}"
done
wait $APID
/tmp/ackcheck verify -dsn "$DSN" -run $RUN -out $OUT > $OUT/$RUN.verify.json 2>&1
python3 - "$OUT/$RUN.verify.json" <<'PY'
import json,sys; s=json.load(open(sys.argv[1]))
print("acked",s["acked"],"failed",s["failed"],"ambiguous",s["ambiguous"],"LOST",s["lost_acked"])
for k,v in sorted(s["error_kinds"].items(), key=lambda x:-x[1]): print(f"  {v:6d}  {k}")
PY
echo "gateway 'credential lookup failed' lines: $(grep -c 'credential lookup failed' $L/gateway.log)"
grep 'credential lookup failed' $L/gateway.log | python3 -c '
import sys,json,collections
c=collections.Counter()
for l in sys.stdin:
    try: d=json.loads(l); c[str(d.get("error",""))[:200]]+=1
    except Exception: pass
for k,v in c.most_common(8): print(f"  {v:5d}  {k}")'
echo AUTHCHURN_DONE
