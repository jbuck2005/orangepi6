#!/bin/bash
# CPU performance diagnosis: run on each kernel and compare the two logs.
# Collects scheduler / cpufreq / topology facts, then runs the CPU llama-bench
# (1.5B Q4, 8 threads) under a few variants to isolate a regression:
#   base        - as booted
#   nollc       - 7.x cache-aware load balancing off (debugfs llc_balancing/enabled=0)
#   perf        - cpufreq governor "performance" on every policy
#   noeas       - energy-aware scheduling off (kernel.sched_energy_aware=0)
#   pin-big     - threads pinned to the highest-capacity CPUs
# Every setting is restored on exit. Needs sudo. Log: ~/bench/cpu-diag-<kernel>.log
set -uo pipefail
cd ~/bench || exit 1
LOG=~/bench/cpu-diag-$(uname -r).log
exec > >(tee "$LOG") 2>&1
M=models/qwen2.5-1.5b-instruct-q4_k_m.gguf
BENCH=llama.cpp/build/bin/llama-bench
[ -x "$BENCH" ] && [ -f "$M" ] || { echo "missing $BENCH or $M (run bench-build.sh first)"; exit 1; }
LLC=/sys/kernel/debug/sched/llc_balancing/enabled
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

declare -A GOV
for p in /sys/devices/system/cpu/cpufreq/policy*; do GOV[$p]=$(cat "$p/scaling_governor"); done
LLC_OLD=$(sudo cat "$LLC" 2>/dev/null || echo "")
EAS=/proc/sys/kernel/sched_energy_aware
EAS_OLD=$(cat "$EAS" 2>/dev/null || echo "")
restore() {
  [ -n "$EAS_OLD" ] && echo "$EAS_OLD" | sudo tee "$EAS" >/dev/null
  for p in "${!GOV[@]}"; do echo "${GOV[$p]}" | sudo tee "$p/scaling_governor" >/dev/null; done
  [ -n "$LLC_OLD" ] && echo "$LLC_OLD" | sudo tee "$LLC" >/dev/null
}
trap restore EXIT

echo "== $(date -Is) kernel $(uname -r)"
echo "== cmdline: $(cat /proc/cmdline)"
echo "== preempt: $(sudo cat /sys/kernel/debug/sched/preempt 2>/dev/null || echo n/a)"
echo "== sched_energy_aware: $(cat /proc/sys/kernel/sched_energy_aware 2>/dev/null || echo n/a)"
echo "== llc_balancing: ${LLC_OLD:-not present}"
echo "== thp: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "== per cpu: capacity / cluster / llc-size / cpufreq policy"
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  n=${c##*cpu}
  llc=$(ls -d $c/cache/index* 2>/dev/null | tail -1)
  printf 'cpu%-2s cap=%-5s cluster=%-3s llc=%s shared=%s\n' "$n" \
    "$(cat $c/cpu_capacity 2>/dev/null)" "$(cat $c/topology/cluster_id 2>/dev/null)" \
    "$(cat $llc/size 2>/dev/null)" "$(cat $llc/shared_cpu_list 2>/dev/null)"
done
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo "${p##*/}: cpus=$(cat $p/related_cpus) drv=$(cat $p/scaling_driver) gov=$(cat $p/scaling_governor)" \
       "min=$(cat $p/scaling_min_freq) max=$(cat $p/scaling_max_freq) hw_max=$(cat $p/cpuinfo_max_freq)" \
       "boost=$(cat $p/boost 2>/dev/null || cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"
done
echo "== sched domains (cpu0, cpu2):"
sudo sh -c 'for c in 0 2; do for d in /sys/kernel/debug/sched/domains/cpu$c/domain*; do
  echo "cpu$c ${d##*/} $(cat $d/name 2>/dev/null) flags=$(cat $d/flags 2>/dev/null)"; done; done'
echo "== cache levels (cpu0, cpu2):"
for c in 0 2; do for i in /sys/devices/system/cpu/cpu$c/cache/index*; do
  echo "cpu$c ${i##*/} L$(cat $i/level) $(cat $i/type) $(cat $i/size) shared=$(cat $i/shared_cpu_list)"
done; done
echo "== cpuidle states (cpu0):"
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
  echo "${s##*/} $(cat $s/name) lat=$(cat $s/latency) disable=$(cat $s/disable)"
done

# Highest-capacity CPUs, 8 of them, for the pinned run.
BIG=$(for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "$(cat $c/cpu_capacity 2>/dev/null || echo 0) ${c##*cpu}"; done \
      | sort -k1,1nr -k2,2n | head -8 | awk '{print $2}' | paste -sd,)

run() {
  local name=$1; shift
  echo "== variant $name"
  ( while sleep 5; do
      printf 'freq:'; for p in /sys/devices/system/cpu/cpufreq/policy*; do printf ' %s=%s' "${p##*/}" "$(cat $p/scaling_cur_freq)"; done; echo
      # Where the benchmark's busy threads are right now: "count x cpuN" for threads using CPU.
      pid=$(pgrep -n llama-bench) && echo "cpus: $(ps -L -o psr=,pcpu= -p "$pid" | awk '$2 > 20 {print "cpu" $1}' | sort | uniq -c | awk '{printf "%sx%s ", $1, $2}')"
    done ) & local mon=$!
  "$@" timeout 900 "$BENCH" -m "$M" -dev none -ngl 0 -t 8 -p 512 -n 128 -r 2 2>&1 | grep -E '^\| qwen|error'
  kill $mon 2>/dev/null; wait $mon 2>/dev/null
}

run base
if [ -n "$LLC_OLD" ]; then
  echo 0 | sudo tee "$LLC" >/dev/null; run nollc; echo "$LLC_OLD" | sudo tee "$LLC" >/dev/null
fi
if [ -n "$EAS_OLD" ]; then
  echo 0 | sudo tee "$EAS" >/dev/null; run noeas; echo "$EAS_OLD" | sudo tee "$EAS" >/dev/null
fi
for p in "${!GOV[@]}"; do echo performance | sudo tee "$p/scaling_governor" >/dev/null; done
run perf
restore
run pin-big taskset -c "$BIG"
echo "== $(date -Is) done (pinned cpus $BIG)"
