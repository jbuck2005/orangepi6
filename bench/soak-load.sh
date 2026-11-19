#!/bin/bash
# Starts the soak loads on aiPi, detached. Usage: soak-load.sh <seconds>
S=${1:?seconds}
cd ~/bench
rm -f soak-stress.log soak-vkmark.log
nohup setsid stress-ng --vm 8 --vm-bytes 70% --verify --cpu 4 --timeout "${S}s" --metrics-brief </dev/null > soak-stress.log 2>&1 &
nohup setsid bash -c "end=\$((SECONDS+$S)); while [ \$SECONDS -lt \$end ]; do timeout 300 vkmark --winsys headless >> $HOME/bench/soak-vkmark.log 2>&1; done" </dev/null >/dev/null 2>&1 &
nohup setsid bash -c "end=\$((SECONDS+$S)); while [ \$SECONDS -lt \$end ]; do stress-ng --memrate 2 --memrate-bytes 256M --timeout 60s >/dev/null 2>&1; sleep 60; done" </dev/null >/dev/null 2>&1 &
echo started
