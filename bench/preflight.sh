#!/bin/bash
# Pre-flight check before any test set (bench/TEST-PROCESS.md). Every line is PASS, FAIL or INFO; any FAIL exits 1
# and the set must not start. The report also goes to the kernel log (so it is on the serial capture) and, with
# OUT=<file>, into the set's folder.
#
#   EXPECT_KERNEL=7.3.5 EXPECT_CAPS="p0=2600 p2=1800 p6=2300 p8=2200 p10=2400" FAN=on bench/preflight.sh
#
#   EXPECT_KERNEL  required: text that `uname -r` must contain
#   EXPECT_CAPS    required: every cpufreq policy's scaling_max_freq as read back, in MHz, exactly as
#                  `bench/preflight.sh` prints it on the "caps" line (the driver can round a value it was given)
#   FAN            required: on or off, the SSD fan state as seen by the operator (software cannot see that fan)
#   EXPECT_MEM     optional: memory rate in MT/s, checked against the firmware's SMBIOS table (needs sudo)
#   MIN_FREE_GB    free space needed on the log and work file systems (default 5)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib-sensors.sh"
BASE=${BENCH_LOG_BASE:-/var/log/opi6-bench}; MIN_FREE_GB=${MIN_FREE_GB:-5}
fails=0; rep=""
line() { rep+="$1 $2"$'\n'; echo "$1 $2"; [ "$1" = FAIL ] && fails=$((fails + 1)); return 0; }

k=$(uname -r)
if [ -z "${EXPECT_KERNEL:-}" ]; then line FAIL "kernel $k: EXPECT_KERNEL not set"
elif [[ $k == *"$EXPECT_KERNEL"* ]]; then line PASS "kernel $k"; else line FAIL "kernel $k, expected $EXPECT_KERNEL"; fi
line INFO "cmdline $(tr ' ' '\n' < /proc/cmdline | grep -E '^(panic|sky1test|loglevel|quiet|printk|console)' | paste -sd' ')"

caps=$(caps_line)
if [ -z "${EXPECT_CAPS:-}" ]; then line FAIL "caps $caps: EXPECT_CAPS not set"
elif [ "$caps" = "$EXPECT_CAPS" ]; then line PASS "caps $caps"; else line FAIL "caps $caps, expected $EXPECT_CAPS"; fi
for p in "${_pols_sorted[@]}"; do
  line INFO "${p##*/} cpus $(cat "$p/related_cpus" | tr ' ' ,) max $(( $(cat "$p/scaling_max_freq") / 1000 )) of $(( $(cat "$p/cpuinfo_max_freq") / 1000 )) MHz, now $(( $(cat "$p/scaling_cur_freq") / 1000 )), governor $(cat "$p/scaling_governor")"
done

case "${FAN:-}" in on|off) line INFO "SSD fan $FAN (operator)";; *) line FAIL "FAN not set to on or off";; esac
t=$(cpu_temp); n=$(nvme_temp)
line INFO "temps now: cpu ${t} C, nvme ${n} C"
[ "$n" = na ] && line FAIL "no NVMe temperature sensor (hwmon 'nvme' missing): the SSD would not be logged"

if [ -n "${EXPECT_MEM:-}" ]; then
  m=$(sudo -n dmidecode -t memory 2>/dev/null | grep -m1 -oE 'Configured (Memory|Clock) Speed: [0-9]+' | grep -oE '[0-9]+$')
  if [ -z "$m" ]; then line FAIL "memory rate unreadable (sudo dmidecode)"; elif [ "$m" = "$EXPECT_MEM" ]; then line PASS "memory $m MT/s"; else line FAIL "memory $m MT/s, expected $EXPECT_MEM"; fi
fi

# Loggers: both boot services running, a fresh sample on disk, and this boot's summary line in the kernel log.
for u in opi6-bench-sensors opi6-bench-kmsg; do
  s=$(systemctl is-active $u 2>/dev/null); e=$(systemctl is-enabled $u 2>/dev/null)
  [ "$s" = active ] && [ "$e" = enabled ] && line PASS "$u active, enabled" || line FAIL "$u is ${s:-?}/${e:-?} (sudo bench/benchlog.sh install)"
done
d=$("$HERE/benchlog.sh" dir)
if [ -s "$d/sensors.csv" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$d/sensors.csv") ))
  [ $age -le 60 ] && line PASS "sensor log $d, last sample ${age}s ago" || line FAIL "sensor log stale: last sample ${age}s ago"
else line FAIL "no sensor log for this boot ($d)"; fi
kl() { dmesg 2>/dev/null || sudo -n dmesg 2>/dev/null; }   # the kernel log, also with dmesg_restrict
lk=$(kl | grep -a 'bench-t:' | tail -n 1)
if [ -n "$lk" ]; then
  ts=$(echo "$lk" | grep -oE '^\[ *[0-9]+' | tr -dc 0-9); up=$(cut -d. -f1 /proc/uptime)
  [ -n "$ts" ] && [ $(( up - ts )) -le 180 ] && line PASS "kernel-log temperatures $(( up - ts ))s ago (they reach the serial console)" \
    || line FAIL "last kernel-log temperature line is old: $lk"
else line FAIL "no bench-t: line in the kernel log"; fi
sup=$(kl | grep -a -c 'output lines suppressed due to ratelimiting')
[ "$sup" -gt 0 ] && line INFO "kernel log: $sup notes of user-space lines dropped by the /dev/kmsg rate limit"
np=$(ls /sys/fs/pstore 2>/dev/null | wc -l)
[ "$np" -gt 0 ] && line INFO "pstore holds $np records from an earlier crash (copied to $d/pstore by the logger)"
for fs in "$BASE" "${TREE:-$HOME}"; do
  while [ ! -e "$fs" ] && [ "$fs" != / ]; do fs=$(dirname "$fs"); done
  g=$(df -P -BG "$fs" 2>/dev/null | awk 'NR==2 {print $4+0}')
  [ -n "$g" ] && [ "$g" -ge "$MIN_FREE_GB" ] && line PASS "free space $fs ${g} GB" || line FAIL "free space $fs ${g:-?} GB (< $MIN_FREE_GB)"
done
sy=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
[ "$sy" = yes ] && line PASS "clock synced $(date -u +%FT%TZ)" || line FAIL "clock not NTP-synced (no RTC battery: times would be wrong)"

res=PASS; [ $fails -gt 0 ] && res="FAIL ($fails)"
line INFO "PREFLIGHT $res"
[ -n "${OUT:-}" ] && printf '%s' "$rep" > "$OUT"
echo "<3>bench-preflight: $res kernel=$k caps=$(echo "$caps" | tr ' ' ,) fan=${FAN:-?} cpu=${t}C nvme=${n}C" | sudo -n tee /dev/kmsg >/dev/null 2>&1
[ $fails = 0 ]
