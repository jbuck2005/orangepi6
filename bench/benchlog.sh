#!/bin/bash
# Boot-persistent bench loggers (see bench/TEST-PROCESS.md). Installed as two systemd services that start on every
# boot, so a crash and reboot can never leave a night without sensor data:
#   opi6-bench-sensors  every INTERVAL s (10) one CSV row of every thermal zone, every hwmon temperature (NVMe SSD
#                       included), each cpufreq policy's current and maximum clock, load and EDAC counts; every
#                       KMSG_EVERY s (60) one "bench-t:" summary line into the kernel log, so the temperatures also
#                       reach the serial console and survive in the PC's serial capture when the board dies
#   opi6-bench-kmsg     the whole kernel log of the boot, followed live (dmesg --follow)
# Each boot gets its own folder, $BENCH_LOG_BASE/boots/<sequence>-<date>-<boot id>/ (default /var/log/opi6-bench), so
# nothing is ever overwritten; "current" links to this boot's folder. On start the sensors service also copies any
# crash records the previous boot left in pstore (ramoops) into pstore/ there. Files are fsync'd every minute.
#
#   sudo bench/benchlog.sh install     copy the loggers to /usr/local/lib/opi6-bench, enable and start both services
#   sudo bench/benchlog.sh uninstall   stop and remove them (logs stay)
#   bench/benchlog.sh status           services, this boot's folder, age of the last sample, last kernel-log line
#   bench/benchlog.sh dir              print this boot's folder
#   benchlog.sh sensors | kmsg         the service bodies (run by systemd as root)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${BENCH_LOG_BASE:-/var/log/opi6-bench}
INTERVAL=${INTERVAL:-10}; KMSG_EVERY=${KMSG_EVERY:-60}
LIB=/usr/local/lib/opi6-bench
UNITS="opi6-bench-sensors opi6-bench-kmsg"

boot_dir() {  # this boot's folder: <sequence>-<date at first start>-<boot id>; found again by the boot id
  local id d; id=$(tr -d - < /proc/sys/kernel/random/boot_id | cut -c1-8)
  find1() { local x; for x in "$BASE"/boots/*-"$id"; do [ -d "$x" ] && { echo "$x"; return; }; done; }  # nullglob-safe
  d=$(find1)
  if [ -z "$d" ] && [ "${1:-}" = create ]; then
    mkdir -p "$BASE/boots"
    d=$( exec 9>"$BASE/.lock"; flock 9
         d=$(find1)
         # The clock can be wrong until NTP syncs (no RTC battery): the sequence number orders the boots, not the date.
         [ -n "$d" ] || { d=$BASE/boots/$(printf %04d $(( $(ls "$BASE/boots" | wc -l) + 1 )))-$(date +%Y%m%d-%H%M)-$id; mkdir -p "$d"; }
         echo "$d" )
  fi
  echo "${d:-$BASE/boots/(none yet for this boot)}"
}
kmsg() { echo "<3>$*" > /dev/kmsg 2>/dev/null || true; }   # level 3 reaches the console at the default loglevel

unit() {  # $1 = name, $2 = subcommand, $3 = description
  cat <<U
[Unit]
Description=Orange Pi 6 bench logger: $3
After=local-fs.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$LIB/benchlog.sh $2
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
U
}

case "${1:-status}" in
  install)
    [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
    install -d "$LIB" && install -m 0755 "$HERE/benchlog.sh" "$LIB/" && install -m 0644 "$HERE/lib-sensors.sh" "$LIB/"
    unit opi6-bench-sensors sensors "temperatures, clocks and load (CSV + kernel log)" > /etc/systemd/system/opi6-bench-sensors.service
    unit opi6-bench-kmsg kmsg "kernel log of every boot" > /etc/systemd/system/opi6-bench-kmsg.service
    systemctl daemon-reload && systemctl enable --now $UNITS && systemctl restart $UNITS
    [ -d /var/log/journal ] || echo "note: the systemd journal is not persistent (no /var/log/journal); the kmsg service covers the kernel log"
    sleep 3; exec "$0" status ;;
  uninstall)
    systemctl disable --now $UNITS 2>/dev/null
    rm -f /etc/systemd/system/opi6-bench-sensors.service /etc/systemd/system/opi6-bench-kmsg.service; systemctl daemon-reload
    echo "removed; logs kept in $BASE" ;;
  dir) boot_dir ;;
  status)
    rc=0; d=$(boot_dir)
    for u in $UNITS; do s=$(systemctl is-active $u 2>/dev/null); e=$(systemctl is-enabled $u 2>/dev/null); echo "$u: $s, $e"; [ "$s" = active ] && [ "$e" = enabled ] || rc=1; done
    echo "this boot: $d"
    if [ -s "$d/sensors.csv" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$d/sensors.csv") )); echo "last sample ${age}s ago: $(tail -n 1 "$d/temps.log" 2>/dev/null)"
      [ $age -le $(( INTERVAL * 3 )) ] || { echo "STALE: no sample for ${age}s"; rc=1; }
    else echo "MISSING: $d/sensors.csv"; rc=1; fi
    echo "last kernel-log summary: $(grep -a 'bench-t:' "$d"/dmesg-*.log 2>/dev/null | tail -n 1)"
    exit $rc ;;
  sensors)
    . "$(dirname "$(readlink -f "$0")")/lib-sensors.sh"
    d=$(boot_dir create); ln -sfn "$d" "$BASE/current"
    if compgen -G "/sys/fs/pstore/*" >/dev/null && [ ! -d "$d/pstore" ]; then
      mkdir -p "$d/pstore" && cp -p /sys/fs/pstore/* "$d/pstore/" && kmsg "bench-log: copied $(ls "$d/pstore" | wc -l) pstore records from the previous crash"
    fi
    f=$d/sensors.csv; h=$(sensors_header)
    # A restart within the boot appends; if the sensors changed (a module loaded), start a new file, never overwrite.
    if [ -s "$f" ] && [ "$(head -n 1 "$f")" != "$h" ]; then f=$d/sensors-$(date +%H%M%S).csv; fi
    [ -s "$f" ] || echo "$h" > "$f"
    kmsg "bench-log: start $(uname -r) up $(cut -d' ' -f1 /proc/uptime)s caps $(caps_line) folder $d"
    last=0
    while :; do
      sensors_row >> "$f"
      echo "$(date +%s) $(cpu_temp) $(nvme_temp)" >> "$d/temps.log"     # epoch cpu_C nvme_C, for quick peaks
      if [ $(( SECONDS - last )) -ge "$KMSG_EVERY" ] || [ $last = 0 ]; then
        kmsg "$(kmsg_line)"; sync "$f" "$d/temps.log" 2>/dev/null; last=$SECONDS
      fi
      sleep "$INTERVAL"
    done ;;
  kmsg)
    d=$(boot_dir create)
    f=$d/dmesg-$(date +%H%M%S).log      # one file per service start; the first holds the boot from its first line
    stdbuf -oL dmesg --follow --time-format iso >> "$f" & p=$!
    trap 'kill $p 2>/dev/null' EXIT TERM
    while kill -0 $p 2>/dev/null; do sleep 60; sync "$f" 2>/dev/null; done
    exit 1 ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
