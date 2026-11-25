# host side
QP=$(cat ~/mg/vm/vm.pid); N=${N:-30}
FAULTS_ALL="kill-primary-pod kill-standby-pod pgkill-primary pgkill-standby kill-multiorch kill-gateway freeze-standby"
for n in $(seq 1 $N); do
  RUN=nem-$(date -u +%H%M)-$n; k=$(shuf -i 2-3 -n1)
  F=$(for t in $(shuf -i 30-190 -n $k | sort -n); do echo "$t:$(echo $FAULTS_ALL | tr ' ' '\n' | shuf -n1)"; done | tr '\n' ' ')
  PIN=$(shuf -i 0-1 -n1)
  echo "$(date -u +%T) $RUN pin=$PIN faults=[$F]"
  ~/mg/vm/vssh "RUN=$RUN FAULTS='$F' bash /tmp/nemesis.sh > /tmp/ack/$RUN.out 2>&1" &
  VP=$!
  if [ $PIN = 1 ]; then sleep 40; taskset -a -p -c 5 $QP >/dev/null; sleep 150; taskset -a -p -c 0-11 $QP >/dev/null; fi
  wait $VP
  R=$(~/mg/vm/vssh "grep RESULT /tmp/ack/$RUN.out"); echo "$R pin=$PIN"
  case "$R" in *"LOST=0 "*) ;; *) echo "STOP: loss or verify failure in $RUN; state preserved"; break ;; esac
  sleep 30
done
taskset -a -p -c 0-11 $QP >/dev/null
echo CAMPAIGN_DONE
