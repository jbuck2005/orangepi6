#!/bin/bash
# Status report for a running test (bench/TEST-PROCESS.md). Prints the report exactly as it is posted, at most
# 15 minutes apart while tests run: live counts per set, CPU and SSD peaks (set, last 15 min) and now, logger health.
#
#   bench/status.sh [set folder ...]     default: crash-repro sets changed in the last 24 h
#   WINDOW=900                           seconds for the "last" peaks (default 15 min)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib-sensors.sh"
WINDOW=${WINDOW:-900}; now=$(date +%s)
sets=("$@"); [ ${#sets[@]} -gt 0 ] || mapfile -t sets < <(find "$HOME/crash-repro" -mindepth 1 -maxdepth 1 -type d -mmin -1440 2>/dev/null | sort)
pk() { [ -f "$3" ] || { echo na; return; }; awk -v c="$1" -v a="$2" '$1 >= a && $c != "na" && $c > m { m = $c } END { print (m == "" ? "na" : m) }' "$3" 2>/dev/null; }
up=$(cut -d. -f1 /proc/uptime)
echo "Status $(date -u '+%Y-%m-%d %H:%M UTC') ($(date '+%H:%M %Z')), kernel $(uname -r), up $(( up / 3600 ))h$(( up % 3600 / 60 ))m"
echo "Now: CPU $(cpu_temp) C, SSD $(nvme_temp) C, load $(cut -d' ' -f1 /proc/loadavg), caps $(caps_line)"
for s in "${sets[@]}"; do
  [ -f "$s/results.csv" ] || continue
  n=$(sed -n 's/^n=//p' "$s/set.conf" 2>/dev/null | tail -n 1); tag=$(sed -n 's/^tag=//p' "$s/set.conf" 2>/dev/null)
  read -r d p f k avg < <(awk -F, 'NR > 1 { n++; c[$7]++; t += $4 } END { printf "%d %d %d %d %d\n", n, c["pass"], c["fail"], c["panic"], (n ? t / n : 0) }' "$s/results.csv")
  run=""; for m in "$s"/run*.started; do [ -e "$m" ] && run="run $(basename "$m" .started | tr -dc 0-9) in progress $(( (now - $(cut -d'|' -f1 "$m")) / 60 )) min"; done
  state=${run:-$( [ "$d" -ge "${n:-0}" ] && echo done || echo "stopped, not running")}
  left=$(( ${n:-0} - d )); eta=""; [ $left -gt 0 ] && [ "$avg" -gt 0 ] && eta=", about $(( left * avg / 60 + 1 )) min left"
  echo "- ${tag:-$(basename "$s")}: $d of ${n:-?} runs, $p pass, $f fail, $k panic; $state$eta"
  echo "  peaks: set CPU $(pk 2 0 "$s/temps.log") C / SSD $(pk 3 0 "$s/temps.log") C; last $(( WINDOW / 60 )) min CPU $(pk 2 $((now - WINDOW)) "$s/temps.log") C / SSD $(pk 3 $((now - WINDOW)) "$s/temps.log") C"
  awk -F, 'NR > 1 && $7 != "pass" { printf "  %s run %s at %s: %s\n", toupper($7), $1, $3, $8 }' "$s/results.csv" | tail -n 5
done
b=$("$HERE/benchlog.sh" dir)
if "$HERE/benchlog.sh" status >/dev/null 2>&1; then h="OK"; else h="PROBLEM (bench/benchlog.sh status)"; fi
echo "Loggers: $h; boot log $(basename "$b"), $(ls -d "$(dirname "$b")"/* 2>/dev/null | wc -l) boots logged; last $(( WINDOW / 60 )) min CPU $(pk 2 $((now - WINDOW)) "$b/temps.log") C / SSD $(pk 3 $((now - WINDOW)) "$b/temps.log") C"
