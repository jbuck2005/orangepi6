# Sensor helpers shared by the bench tools (sourced, not run). Read-only sysfs, no sudo.
#   sensors_header / sensors_row   one CSV line: every thermal zone, every hwmon temperature (the NVMe SSD's
#                                  controller shows up as hwmon "nvme"), each cpufreq policy's current and
#                                  maximum clock, load average, EDAC counts
#   cpu_temp    hottest thermal zone (CPU/SoC), whole degrees C
#   nvme_temp   hottest NVMe hwmon sensor, whole degrees C ("na" if the kernel has no NVMe hwmon)
#   caps_line   every policy's scaling_max_freq read back, in MHz: "p0=2600 p2=1800 p6=2300 p8=2200 p10=2400"
#   kmsg_line   the one-line summary written to the kernel log (and so to the serial console)
: "${SYSFS:=/sys}"   # SYSFS=<dir> reads a copy of /sys instead (for testing the tools off the board)
shopt -s nullglob
_zones=($SYSFS/class/thermal/thermal_zone*)
_pols=($SYSFS/devices/system/cpu/cpufreq/policy*)
_pols_sorted=(); for _n in $(for p in "${_pols[@]}"; do echo "${p##*policy}"; done | sort -n); do _pols_sorted+=("$SYSFS/devices/system/cpu/cpufreq/policy$_n"); done
_hw=(); _nvme=()
for _f in $SYSFS/class/hwmon/hwmon*/temp*_input; do
  [ -r "$_f" ] || continue; _hw+=("$_f")
  [ "$(cat "${_f%/*}/name" 2>/dev/null)" = nvme ] && _nvme+=("$_f")
done
shopt -u nullglob   # only for the lists above; the scripts that source this keep normal globbing
_c() { local v; v=$(cat "$1" 2>/dev/null) && [ -n "$v" ] && echo $(( v / 1000 )) || echo na; }
cpu_temp() { local m=na v; for z in "${_zones[@]}"; do v=$(_c "$z/temp"); [ "$v" != na ] && { [ "$m" = na ] || [ "$v" -gt "$m" ]; } && m=$v; done; echo "$m"; }
nvme_temp() { local m=na v; for f in "${_nvme[@]}"; do v=$(_c "$f"); [ "$v" != na ] && { [ "$m" = na ] || [ "$v" -gt "$m" ]; } && m=$v; done; echo "$m"; }
caps_line() { local p o=""; for p in "${_pols_sorted[@]}"; do o+="${o:+ }p${p##*policy}=$(( $(cat "$p/scaling_max_freq") / 1000 ))"; done; echo "$o"; }
freqs_line() { local p o=""; for p in "${_pols_sorted[@]}"; do o+="${o:+/}$(( $(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 ))"; done; echo "$o"; }
edac_counts() {
  local ce=0 ue=0 m n=0
  for m in $SYSFS/devices/system/edac/mc/mc*; do [ -d "$m" ] || continue; ce=$((ce + $(cat "$m/ce_count"))); ue=$((ue + $(cat "$m/ue_count"))); n=1; done
  [ $n = 1 ] && echo "$ce,$ue" || echo "na,na"
}
sensors_header() {
  local z f d n l p
  printf 'time'
  for z in "${_zones[@]}"; do printf ',tz:%s' "$(cat "$z/type" 2>/dev/null)"; done
  for f in "${_hw[@]}"; do
    d=${f%/*}; n=${f##*/}; l=$d/${n%_input}_label
    printf ',hw:%s/%s' "$(cat "$d/name")" "$( [ -r "$l" ] && cat "$l" | tr -d ', ' || echo "${n%_input}")"
  done
  for p in "${_pols_sorted[@]}"; do printf ',cur_mhz:%s,max_mhz:%s' "${p##*/}" "${p##*/}"; done
  printf ',load1,edac_ce,edac_ue\n'
}
sensors_row() {
  local z f p
  printf '%s' "$(date -u +%FT%TZ)"
  for z in "${_zones[@]}"; do printf ',%s' "$(_c "$z/temp")"; done
  for f in "${_hw[@]}"; do printf ',%s' "$(_c "$f")"; done
  for p in "${_pols_sorted[@]}"; do printf ',%s,%s' "$(( $(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 ))" "$(( $(cat "$p/scaling_max_freq" 2>/dev/null || echo 0) / 1000 ))"; done
  printf ',%s,%s\n' "$(cut -d' ' -f1 /proc/loadavg)" "$(edac_counts)"
}
kmsg_line() { echo "bench-t: cpu=$(cpu_temp)C nvme=$(nvme_temp)C mhz=$(freqs_line) cap=$(caps_line | tr ' ' ,) load=$(cut -d' ' -f1 /proc/loadavg)"; }
