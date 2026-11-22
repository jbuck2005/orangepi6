#!/bin/bash
# Logs temperatures, CPU clocks and memory errors every few seconds, so two kernels can be
# compared under the same load. Usage: thermal-log.sh [interval-s] (default 5); stop with Ctrl-C
# or kill. Writes ~/bench/thermal-<kernel>-<date>.csv. Read-only, no sudo.
set -u
shopt -s nullglob
I=${1:-5}
OUT=~/bench/thermal-$(uname -r)-$(date +%Y%m%d-%H%M).csv
mkdir -p ~/bench
zones=(/sys/class/thermal/thermal_zone*)
hw=()
for f in /sys/class/hwmon/hwmon*/temp*_input; do [ -r "$f" ] && hw+=("$f"); done
pols=(/sys/devices/system/cpu/cpufreq/policy*)
{
  printf 'time'
  for z in "${zones[@]}"; do printf ',tz:%s' "$(cat "$z/type" 2>/dev/null)"; done
  for f in "${hw[@]}"; do
    d=${f%/*}; n=${f##*/}; l=${d}/${n%_input}_label
    printf ',hw:%s/%s' "$(cat "$d/name")" "$( [ -r "$l" ] && cat "$l" || echo "${n%_input}")"
  done
  for p in "${pols[@]}"; do printf ',mhz:%s' "${p##*/}"; done
  printf ',edac_ce,edac_ue\n'
} > "$OUT"
echo "logging to $OUT every ${I}s"
while :; do
  {
    printf '%s' "$(date +%H:%M:%S)"
    for z in "${zones[@]}"; do printf ',%s' "$(( $(cat "$z/temp" 2>/dev/null || echo 0) / 1000 ))"; done
    for f in "${hw[@]}"; do printf ',%s' "$(( $(cat "$f" 2>/dev/null || echo 0) / 1000 ))"; done
    for p in "${pols[@]}"; do printf ',%s' "$(( $(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 ))"; done
    ce=0; ue=0
    for m in /sys/devices/system/edac/mc/mc*; do
      [ -d "$m" ] || continue
      ce=$((ce + $(cat "$m/ce_count"))); ue=$((ue + $(cat "$m/ue_count")))
    done
    printf ',%s,%s\n' "$ce" "$ue"
  } >> "$OUT"
  sleep "$I"
done
