#!/bin/sh
# prints the pool pod whose Postgres is not in recovery
NS=${NS:-ha}
for P in $(kubectl -n $NS get pods -l app.kubernetes.io/component=shard-pool -o name | sed 's#pod/##'); do
  R=$(kubectl -n $NS exec $P -c postgres -- env PGPASSWORD=postgres psql -h /var/lib/pooler/pg_sockets -U postgres -Atc 'select pg_is_in_recovery()' 2>/dev/null)
  [ "$R" = "f" ] && echo $P
done
