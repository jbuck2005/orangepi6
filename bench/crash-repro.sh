#!/bin/bash
# Reproducer for the corruption crashes under heavy module-link load (see bench/CRASH-ANALYSIS.md).
# Rebuilds every module of an already-built kernel tree (LD + pahole BTF + resolve_btfids), N times, while
# logging events to the kernel log (they reach the serial console) and temperatures to the run's folder.
#
#   TREE=<built kernel tree with CONFIG_DEBUG_INFO_BTF_MODULES=y> CPUS=0-11 J=6 N=3 [MAXF=<kHz> [MAXF_CPUS=10,11]] bench/crash-repro.sh
#
# MAXF caps scaling_max_freq for the run (Linux setting only; a reboot resets it): on every cpufreq policy, or with
# MAXF_CPUS (comma list of CPU numbers) only on the policies of those CPUs. MAXF=2400000 MAXF_CPUS=10,11 is the
# documented workaround (the weak cpu10-11 pair only).
# Results: $LOG_DIR (default ~/crash-repro/<time>-<tag>/): events.log, thermal.log, make<i>.log.
# A failed run shows as rc!=0 with "Segmentation fault", "Aborted" or "malloc(): ..." in make<i>.log, or as a
# kernel panic on the serial console (the board then reboots itself after panic=10).
set -uo pipefail
TREE=${TREE:?set TREE to a built kernel tree}; CPUS=${CPUS:-0-11}; J=${J:-6}; N=${N:-3}
TAG=${TAG:-cpus$CPUS${MAXF:+-$MAXF}${MAXF_CPUS:+-on${MAXF_CPUS//,/_}}}
R=${LOG_DIR:-$HOME/crash-repro/$(date +%Y%m%d-%H%M%S)-$TAG}; mkdir -p "$R"
cd "$TREE" || exit 1; [ -f Makefile ] && [ -f .config ] || { echo "not a kernel tree: $TREE"; exit 1; }
say() { local m="repro: $(date +%T) $*"; echo "$m" | tee -a "$R/events.log"; echo "<3>$m" | sudo tee /dev/kmsg >/dev/null; sync; }
if [ -n "${MAXF:-}" ]; then
  if [ -n "${MAXF_CPUS:-}" ]; then pols=(); for c in ${MAXF_CPUS//,/ }; do pols+=("/sys/devices/system/cpu/cpu$c/cpufreq"); done
  else pols=(/sys/devices/system/cpu/cpufreq/policy*); fi
  for p in "${pols[@]}"; do echo "$MAXF" | sudo tee "$p/scaling_max_freq" >/dev/null || { echo "cannot cap $p"; exit 1; }; done
fi
( while :; do
    echo "$(date +%T) $(cat /sys/class/thermal/thermal_zone*/temp | sort -n | tail -n 1) $(cut -d' ' -f1-3 /proc/loadavg) $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)" >> "$R/thermal.log"
    sleep 10
  done ) & TP=$!
trap 'kill $TP 2>/dev/null' EXIT
say "$TAG start $(uname -r) cpus=$CPUS j=$J n=$N maxf=${MAXF:-none}${MAXF_CPUS:+ on cpus $MAXF_CPUS}"
for i in $(seq 1 "$N"); do
  find . -name '*.ko' ! -path './.git/*' -delete
  t0=$SECONDS; taskset -c "$CPUS" make -j"$J" modules > "$R/make$i.log" 2>&1; rc=$?
  bad=$(grep -cE '^(Segmentation fault|Aborted|Bus error|Illegal instruction)|malloc\(\)|corrupted (double-linked|size)|double free' "$R/make$i.log")
  say "$TAG $i rc=$rc $(( SECONDS - t0 ))s tool_crashes=$bad max_temp=$(sort -k2 -n "$R/thermal.log" | tail -n 1 | cut -d' ' -f2)"
done
say "$TAG DONE"
