#!/bin/bash
# A/B the 7.x scheduler features that can change thread placement on the big/little cores,
# without a rebuild. Runs the CPU llama-bench (1.5B Q4, 8 threads) per variant and samples
# which CPU each busy thread is on. Every feature is restored on exit. Needs sudo.
# Log: ~/bench/sched-ab-<kernel>.log
#   base          - as booted
#   no-ni-rate    - NO_NI_RATE: newidle balancing not throttled by its time-based rate (new in 7.x)
#   no-ni-random  - NO_NI_RANDOM: newidle balancing not skipped at random by its success ratio
#   no-ni-both    - both of the above
set -uo pipefail
cd ~/bench || exit 1
LOG=~/bench/sched-ab-$(uname -r).log
exec > >(tee "$LOG") 2>&1
M=models/qwen2.5-1.5b-instruct-q4_k_m.gguf
BENCH=llama.cpp/build/bin/llama-bench
[ -x "$BENCH" ] && [ -f "$M" ] || { echo "missing $BENCH or $M (run bench-build.sh first)"; exit 1; }
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
F=/sys/kernel/debug/sched/features
sudo test -w "$F" || { echo "no $F"; exit 1; }
ORIG=$(sudo cat "$F")
has() { grep -qw "$1" <<<"$ORIG" || grep -qw "NO_$1" <<<"$ORIG"; }
set_feat() { echo "$1" | sudo tee "$F" >/dev/null; }
restore() {  # put back NI_* exactly as booted
  for f in NI_RATE NI_RANDOM; do
    if grep -qw "NO_$f" <<<"$ORIG"; then set_feat "NO_$f"; elif grep -qw "$f" <<<"$ORIG"; then set_feat "$f"; fi
  done
}
trap restore EXIT

echo "== $(date -Is) kernel $(uname -r)"
echo "== features: $ORIG"

run() {
  local name=$1
  echo "== variant $name: $(sudo cat "$F" | tr ' ' '\n' | grep -E '^(NO_)?NI_' | paste -sd' ')"
  ( while sleep 5; do
      pid=$(pgrep -n llama-bench) && echo "cpus: $(ps -L -o psr=,pcpu= -p "$pid" | awk '$2 > 20 {print "cpu" $1}' | sort | uniq -c | awk '{printf "%sx%s ", $1, $2}')"
    done ) & local mon=$!
  timeout 900 "$BENCH" -m "$M" -dev none -ngl 0 -t 8 -p 512 -n 128 -r 2 2>&1 | grep -E '^\| qwen|error'
  kill $mon 2>/dev/null; wait $mon 2>/dev/null
}

run base
if has NI_RATE; then set_feat NO_NI_RATE; run no-ni-rate; restore; fi
if has NI_RANDOM; then set_feat NO_NI_RANDOM; run no-ni-random; restore; fi
if has NI_RATE && has NI_RANDOM; then set_feat NO_NI_RATE; set_feat NO_NI_RANDOM; run no-ni-both; restore; fi
echo "== $(date -Is) done"
