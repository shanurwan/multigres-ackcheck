# VM side. env: RUN, FAULTS="sec:fault ..." ; faults: kill-primary-pod kill-standby-pod pgkill-primary pgkill-standby kill-multiorch kill-gateway freeze-standby
set -u
NS=ha; OUT=/tmp/ack; L=$OUT/$RUN.logs; mkdir -p $L
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
ts() { date -u +%T.%3N; }
pgpids='for f in /proc/[0-9]*/comm; do [ "$(cat $f 2>/dev/null)" = postgres ] && d=${f%/comm} && echo ${d#/proc/}; done'
sig() { timeout 10 kubectl -n $NS exec $1 -c postgres -- sh -c "kill -$2 \$($pgpids) 2>/dev/null; echo ok" 2>/dev/null; }
pools() { kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##'; }
role() { timeout 15 kubectl -n $NS exec $1 -c postgres -- env PGPASSWORD=postgres psql -h /var/lib/pooler/pg_sockets -U postgres -Atc "select pg_is_in_recovery()" 2>/dev/null; }
primary() { for try in 1 2 3; do r=$(for p in $(pools); do [ "$(role $p)" = f ] && echo $p; done | head -1); [ -n "$r" ] && { echo $r; return; }; sleep 2; done; }
standby() { P=$(primary); pools | grep -v "^$P$" | shuf -n1; }
cleanup() { for p in $(pools); do sig $p CONT >/dev/null; done; kill $(jobs -p) 2>/dev/null; }
trap cleanup EXIT
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')" = Healthy ] && break; sleep 5; done
echo "$(ts) start faults=[$FAULTS] shard=$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')"
for p in $(pools); do for c in multipooler postgres; do kubectl -n $NS logs -f $p -c $c --since=1s > $L/$p.$c.log 2>&1 & done; done
kubectl -n $NS logs -f $(kubectl -n $NS get pods -o name | grep multiorch | head -1) --since=1s > $L/multiorch.log 2>&1 &
kubectl -n multigres-operator logs -f deploy/multigres-operator-controller-manager --since=1s > $L/operator.log 2>&1 &
kubectl -n $NS logs -f $(kubectl -n $NS get pods -o name | grep multigateway | head -1) --since=1s > $L/gateway.log 2>&1 &
kubectl -n $NS get events -w --output-watch-events > $L/events.log 2>&1 &
/tmp/ackcheck run -dsn "$DSN" -run $RUN -workers 8 -rate 50 -timeout 2s -duration 240s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
T0=$(date +%s)
for f in $FAULTS; do
  at=${f%%:*}; what=${f#*:}
  now=$(( $(date +%s) - T0 )); [ $at -gt $now ] && sleep $(( at - now ))
  case $what in
    kill-primary-pod) t=$(primary); kubectl -n $NS delete pod $t --grace-period=0 --force >/dev/null 2>&1 ;;
    kill-standby-pod) t=$(standby); kubectl -n $NS delete pod $t --grace-period=0 --force >/dev/null 2>&1 ;;
    pgkill-primary)   t=$(primary); sig $t KILL >/dev/null ;;
    pgkill-standby)   t=$(standby); sig $t KILL >/dev/null ;;
    kill-multiorch)   t=$(kubectl -n $NS get pods -o name | grep multiorch | head -1); kubectl -n $NS delete $t --grace-period=0 --force >/dev/null 2>&1 ;;
    kill-gateway)     t=$(kubectl -n $NS get pods -o name | grep multigateway | head -1); kubectl -n $NS delete $t --grace-period=0 --force >/dev/null 2>&1 ;;
    freeze-standby)   t=$(standby); sig $t STOP >/dev/null; ( sleep $(shuf -i 10-30 -n1); sig $t CONT >/dev/null ) & ;;
  esac
  echo "$(ts) t+${at}s $what target=${t##*/}"
done
wait $APID
for p in $(pools) $(kubectl -n $NS get pods -o name | grep -E "multiorch|multigateway" | sed 's#pod/##'); do
  for c in $(kubectl -n $NS get pod $p -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}'); do
    kubectl -n $NS logs $p -c $c --previous > $L/prev.$p.$c.log 2>/dev/null || rm -f $L/prev.$p.$c.log
  done
done
/tmp/ackcheck verify -dsn "$DSN" -run $RUN -out $OUT > $OUT/$RUN.verify.json 2>&1
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("RESULT", sys.argv[2], "acked=%d failed=%d ambiguous=%d LOST=%d amb_present=%d unexpected=%d syncwarn=%d max_outage=%.1f" % (s["acked"],s["failed"],s["ambiguous"],s["lost_acked"],s["ambiguous_present"],s["unexpected_rows"],s["acked_with_syncrep_warning"],max([o["seconds"] for o in (s["outages"] or [])] or [0])))' $OUT/$RUN.verify.json $RUN || echo "RESULT $RUN verify-failed"
