# usage: FAULT=forcekill|graceful|pgkill RUN=name bash drill.sh
set -u
NS=ha; OUT=/tmp/ack; mkdir -p $OUT
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
DSN="postgres://postgres:postgres@$GW:5432/postgres?sslmode=disable"
for i in $(seq 1 60); do [ "$(kubectl -n $NS get shards -o jsonpath='{.items[0].status.phase}')" = Healthy ] && break; sleep 5; done
/tmp/ackcheck run -dsn "$DSN" -run $RUN -workers 8 -rate 50 -timeout 2s -duration 120s -out $OUT > $OUT/$RUN.run.log 2>&1 &
APID=$!
sleep 30
P=$(sh /tmp/primary.sh 2>/dev/null)
T0=$(date -u +%T.%3N)
case $FAULT in
  forcekill) kubectl -n $NS delete pod $P --grace-period=0 --force >/dev/null 2>&1 ;;
  graceful)  kubectl -n $NS delete pod $P --wait=false >/dev/null 2>&1 ;;
  pgkill)    kubectl -n $NS exec $P -c postgres -- sh -c 'kill -9 $(head -1 $(find /var/lib/pooler -name postmaster.pid | head -1))' >/dev/null 2>&1 ;;
esac
NP=""; T1=""
for i in $(seq 1 60); do sleep 1; NP=$(sh /tmp/primary.sh 2>/dev/null); [ -n "$NP" ] && [ "$NP" != "$P" ] && { T1=$(date -u +%T.%3N); break; }; done
wait $APID
/tmp/ackcheck verify -dsn "$DSN" -run $RUN -out $OUT > $OUT/$RUN.verify.log 2>&1; V=$?
python3 - "$OUT/$RUN.summary.json" "$FAULT" "$RUN" "$P" "$T0" "$NP" "$T1" "$V" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); f,run,p,t0,np,t1,v=sys.argv[2:]
o=max([x["seconds"] for x in s["outages"]] or [0])
print(f"{run} fault={f} killed={p[-1]}@{t0} newprimary={(np[-1] if np else '-')}@{t1 or '-'} acked={s['acked']} failed={s['failed']} ambiguous={s['ambiguous']} lost={s['lost_acked']} amb_present={s['ambiguous_present']} unexpected={s['unexpected_rows']} max_outage_s={o:.2f} outages={len(s['outages'])} p99ms={s['ok_latency_ms'].get('p99')} verify_exit={v}")
PY
