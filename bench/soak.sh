#!/bin/bash
# Combined CPU+memory+GPU soak for the board, run from a PC (Git Bash); BOARD=<ssh host> (default opi6), JUMP=<jump host> optional.
# Usage: bash soak.sh <label> [minutes=60]
# Every 5 min: ECC corrected/uncorrectable since start (from serial.log), max temp, load, resets.
set -u
LABEL=${1:?label}; MIN=${2:-60}
DIR=$(cd "$(dirname "$0")" && pwd)
L="$DIR/serial.log"; OUT="$DIR/soak-$LABEL.txt"
remote() { if [ -n "${JUMP:-}" ]; then ssh "$JUMP" "ssh ${BOARD:-opi6} '$1'"; else ssh "${BOARD:-opi6}" "$1"; fi; }
echo "=== MARK soak $LABEL start $(date +%H:%M:%S)" >> "$L"
n0=$(wc -l < "$L")
SECS=$((MIN * 60))
# Start the loads on the board (~/bench/soak-load.sh), detached; each stops on its own after SECS.
remote "~/bench/soak-load.sh $SECS"
{
  echo "# soak $LABEL  ${MIN} min  $(date -Is)"
  t=0
  while [ $t -lt "$MIN" ]; do
    sleep 300; t=$((t + 5))
    sbe=$(tail -n +"$n0" "$L" | grep -ac ECC_SBE); dbe=$(tail -n +"$n0" "$L" | grep -ac ECC_DBE)
    rst=$(tail -n +"$n0" "$L" | grep -ac 'PM boot start')
    st=$(remote 'echo "temp=$(for z in /sys/class/thermal/thermal_zone*/temp; do cat $z; done | sort -n | tail -1) load=$(cut -d" " -f1 /proc/loadavg)"' 2>/dev/null || echo "UNREACHABLE")
    echo "$(date +%H:%M) +${t}min  ECC corrected=$sbe uncorrectable=$dbe resets=$rst  $st"
  done
  echo "== stress-ng"; remote 'tail -5 ~/bench/soak-stress.log' 2>/dev/null
  echo "== vkmark scores"; remote 'grep -a "vkmark Score" ~/bench/soak-vkmark.log | tr -s " " | sort | uniq -c' 2>/dev/null
  echo "# end $(date -Is)"
} 2>&1 | tee "$OUT"
