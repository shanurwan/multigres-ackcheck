# Minimal repro: 8 psql login loops through the gateway, SIGKILL Postgres on the primary 3 times.
NS=ha
GW=$(kubectl -n $NS get svc hac-multigateway -o jsonpath='{.spec.clusterIP}')
OUT=/tmp/ack/psqlrepro; mkdir -p $OUT; rm -f $OUT/*
loop() { end=$(( $(date +%s) + 140 )); while [ $(date +%s) -lt $end ]; do
  r=$(PGPASSWORD=postgres PGCONNECT_TIMEOUT=3 psql -h $GW -U postgres -d postgres -Atc 'select 1' 2>&1 | tr '\n' ' ')
  echo "$(date -u +%T.%3N) $r" >> $OUT/loop.$1; done; }
for i in 1 2 3 4 5 6 7 8; do loop $i & done
pgpids='for f in /proc/[0-9]*/comm; do [ "$(cat $f 2>/dev/null)" = postgres ] && d=${f%/comm} && echo ${d#/proc/}; done'
for n in 1 2 3; do
  sleep 35
  P=$(sh /tmp/primary.sh 2>/dev/null | head -1)
  kubectl -n $NS exec $P -c postgres -- sh -c "kill -KILL \$($pgpids)" >/dev/null 2>&1
  echo "$(date -u +%T.%3N) SIGKILL postgres on ${P: -1}"
done
wait
cat $OUT/loop.* > $OUT/all
echo "logins: $(wc -l < $OUT/all)  ok: $(grep -c '^[^ ]* 1 $' $OUT/all)"
grep -o 'FATAL: .*' $OUT/all | sed 's/ *$//' | sort | uniq -c | sort -rn
