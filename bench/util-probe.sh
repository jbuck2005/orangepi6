#!/bin/bash
# Reads the scheduler's view of each busy benchmark thread: which CPU it is on and its PELT
# utilization (util_avg, util_est). Run on both kernels and compare: a thread spinning on a big
# core should show util near that core's capacity (866-1024). If 7.x reports much lower util,
# frequency invariance is off and the scheduler thinks the threads fit on the little cores.
# Read-only apart from the benchmark it starts. Log: ~/bench/util-probe-<kernel>-<mode>.log
#   util-probe.sh        tg only (-p 0 -n 512), the default
#   util-probe.sh pp     prompt processing only (-p 512 -n 0)
#   util-probe.sh both   pp512 + tg128, as cpu-diag.sh runs it; samples every 2 s across both phases
set -uo pipefail
cd ~/bench || exit 1
MODE=${1:-tg}
case $MODE in
  tg)   ARGS="-p 0 -n 512 -r 3"; ROUNDS=3; GAP=5 ;;
  pp)   ARGS="-p 512 -n 0 -r 10"; ROUNDS=3; GAP=5 ;;
  both) ARGS="-p 512 -n 128 -r 2"; ROUNDS=40; GAP=2 ;;
  *) echo "usage: $0 [tg|pp|both]"; exit 1 ;;
esac
LOG=~/bench/util-probe-$(uname -r)-$MODE.log
exec > >(tee "$LOG") 2>&1
M=models/qwen2.5-1.5b-instruct-q4_k_m.gguf
BENCH=llama.cpp/build/bin/llama-bench
[ -x "$BENCH" ] && [ -f "$M" ] || { echo "missing $BENCH or $M"; exit 1; }
echo "== $(date -Is) kernel $(uname -r) mode $MODE ($ARGS)"
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  printf 'cpu%s cap=%s ' "${c##*cpu}" "$(cat $c/cpu_capacity)"
done; echo
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo "${p##*/}: cur=$(cat $p/scaling_cur_freq) max=$(cat $p/scaling_max_freq) hw_max=$(cat $p/cpuinfo_max_freq)" \
       "base=$(cat $p/base_frequency 2>/dev/null || echo n/a)"
done
# shellcheck disable=SC2086
timeout 600 "$BENCH" -m "$M" -dev none -ngl 0 -t 8 $ARGS 2>&1 | grep -E '^\| qwen|error' &
[ "$MODE" = both ] && sleep 3 || sleep 20
pid=$(pgrep -n llama-bench) || { echo "benchmark not running"; exit 1; }
for round in $(seq "$ROUNDS"); do
  [ -d /proc/$pid ] || break
  echo "== sample $round $(date +%T)"
  for t in /proc/$pid/task/*; do
    s=$t/sched
    [ -r "$s" ] || continue
    psr=$(awk '{print $39}' $t/stat)
    ua=$(awk '/se.avg.util_avg/ {print $3}' $s)
    ue=$(awk '/se.avg.util_est/ {print $3}' $s)
    rt=$(awk '/se.sum_exec_runtime/ {print int($3)}' $s)
    echo "tid ${t##*/} cpu$psr util_avg=$ua util_est=$ue runtime_ms=$rt"
  done | awk '$4 != "util_avg=0" {split($4, a, "="); print a[2], $0}' | sort -n -k1,1 | cut -d' ' -f2-
  echo "little cores in use: $(ps -L -o psr=,pcpu= -p "$pid" 2>/dev/null | awk '$2 > 20 && $1 >= 2 && $1 <= 5' | wc -l)"
  sleep "$GAP"
done
wait
echo "== $(date -Is) done"
