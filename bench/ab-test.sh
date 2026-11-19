#!/bin/bash
# A/B memory + benchmark suite for aiPi, run from Prometheus (Git Bash).
# Usage: bash ab-test.sh <label>        e.g. bash ab-test.sh oldfw-5500
# Needs: the serial logger running (serial.log next to this script), ssh zeus -> ssh aipi.
# Counts DDR ECC errors (from the firmware's UART messages) per phase.
set -u
LABEL=${1:?label}
DIR=$(cd "$(dirname "$0")" && pwd)
L="$DIR/serial.log"
OUT="$DIR/results-$LABEL.txt"
remote() { ssh zeus "ssh aipi '$1'"; }
ecc_since() { tail -n +"$1" "$L" | grep -ac 'ECC_SBE'; }
dbe_since() { tail -n +"$1" "$L" | grep -ac 'ECC_DBE'; }

phase() {  # $1 name, $2 remote command
  echo "=== MARK ab-test $LABEL: $1 $(date +%H:%M:%S)" >> "$L"
  local n0; n0=$(wc -l < "$L")
  echo "== $1"
  remote "$2" 2>&1
  echo "   ECC corrected: $(ecc_since "$n0")  uncorrectable: $(dbe_since "$n0")"
}

{
  echo "# ab-test $LABEL  $(date -Is)"
  b=$(grep -an 'PM boot start' "$L" | tail -1 | cut -d: -f1)
  echo "firmware: $(tail -n +"$b" "$L" | grep -aoE 'UEFI:[^ ]+' | head -1)"
  echo "DDR: $(tail -n +"$b" "$L" | grep -aoE 'f2 [0-9]+Mhz' | head -1)"
  remote 'echo "kernel: $(uname -r)"'
  phase "stress-ng vm 6x60% 180s" 'stress-ng --vm 6 --vm-bytes 60% --verify --timeout 180s 2>&1 | grep -E "passed|failed:|successful"'
  phase "llama-bench CPU 1.5B Q4 (8 threads)" 'cd ~/bench && timeout 900 llama.cpp/build/bin/llama-bench -m models/qwen2.5-1.5b-instruct-q4_k_m.gguf -dev none -ngl 0 -t 8 -p 512 -n 128 -r 2 2>&1 | grep -E "^\| qwen|what"'
  phase "llama-bench GPU tg 1.5B Q4" 'cd ~/bench && timeout 600 llama.cpp/build/bin/llama-bench -m models/qwen2.5-1.5b-instruct-q4_k_m.gguf -ngl 99 -p 0 -n 64 -r 2 2>&1 | grep -E "^\| qwen|what"'
  phase "llama-bench CPU 7B Q4 (8 threads)" 'cd ~/bench && timeout 1200 llama.cpp/build/bin/llama-bench -m models/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf -dev none -ngl 0 -t 8 -p 256 -n 64 -r 1 2>&1 | grep -E "^\| qwen|what"'
  phase "vkpeak" 'cd ~/bench && timeout 600 vkpeak/build/vkpeak 0 2>&1 | grep -E "fp32-scalar|fp16-vec4|int8-dot|copy-d2d"'
  phase "stream-like memory bandwidth (stress-ng memrate 60s)" 'stress-ng --memrate 4 --memrate-bytes 256M --timeout 60s --metrics 2>&1 | grep -iE "memrate.*(read|write)64 " | head -4'
  remote 'echo "max temp: $(for z in /sys/class/thermal/thermal_zone*/temp; do cat $z; done | sort -n | tail -1)"'
  echo "board resets during run: $(( $(tail -n +"$b" "$L" | grep -ac 'PM boot start') - 1 ))"
  echo "# end $(date -Is)"
} 2>&1 | tee "$OUT"
