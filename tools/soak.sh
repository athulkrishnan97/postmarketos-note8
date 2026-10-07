#!/bin/sh
# soak.sh SECONDS "CPUS": hash-loop on each listed CPU for SECONDS, print a
# heartbeat every 10 s (so a reset shows when it happened) and the result
# counts at the end; any digest mismatch is counted as "bad".
T=${1:-120}; CPUS=${2:-"0 1 2 3 4 5 6 7"}
[ -f /tmp/bb.bin ] || dd if=/dev/urandom of=/tmp/bb.bin bs=1M count=32 2>/dev/null
REF=$(sha256sum /tmp/bb.bin | cut -d" " -f1)
start=$(date +%s); end=$((start + T))
for c in $CPUS; do
	taskset -c $c sh -c "n=0; bad=0; while [ \$(date +%s) -lt $end ]; do h=\$(sha256sum /tmp/bb.bin | cut -d\" \" -f1); [ \"\$h\" = \"$REF\" ] || bad=\$((bad+1)); n=\$((n+1)); done; echo \"cpu$c: \$n runs, \$bad bad\"" &
done
while [ $(date +%s) -lt $end ]; do sleep 10; echo "t=$(( $(date +%s) - start ))s alive"; done
wait
