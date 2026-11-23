#!/bin/bash
# Usage (as root; RUN_AS=<user> owns the builds, default $SUDO_USER): FULL=1 HOURS=8 nohup setsid bash bench/stability.sh &
# Multi-hour memory/stability run for the board: repeated kernel builds at -j6 alternating with
# stress-ng --vm --verify intervals, until HOURS have passed or something fails.
# Every event goes to ~/stability.log and to the kernel log (/dev/kmsg, so it also lands on the serial console
# and survives in a serial capture even if the board dies). Run as root under nohup setsid.
#   HOURS (default 4)  STRESS_MIN (default 10)  TREE (kernel tree to rebuild; default the kernel-7 tree, not staged)
#   FULL=1: each build is a full from-scratch 6.18.64 setup.sh source+build into ~/sky1-stab (heavy NVMe I/O)
#   LOG_DIR (default ~/stability-logs/<start time>): per-iteration logs, kept; LOG_HOST: also rsync them to that host
set -u
RUN_AS=${RUN_AS:-${SUDO_USER:-$USER}}; HOME_DIR=$(getent passwd "$RUN_AS" | cut -d: -f6)
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}; export REPO
HOURS=${HOURS:-4}; STRESS_MIN=${STRESS_MIN:-10}
TREE=${TREE:-$HOME_DIR/sky1-build-7/linux-7.3.5}
L=$HOME_DIR/stability.log
# Every iteration keeps its own logs here; nothing is overwritten. LOG_HOST=<ssh host> also copies them off the
# board after each step (needs passwordless ssh from the board), so a hang or crash cannot lose them.
LD=${LOG_DIR:-$HOME_DIR/stability-logs/$(date +%Y%m%d-%H%M%S)}; mkdir -p "$LD"; chown "$RUN_AS" "$LD" 2>/dev/null
W=$HOME_DIR/sky1-stab
if [ -n "${LOG_HOST:-}" ]; then  # also stream the live logs off the board every 30 s while this runs
  ( while kill -0 $$ 2>/dev/null; do sudo -u "$RUN_AS" rsync -aq "$LD/" "$LOG_HOST:$(basename "$(dirname "$LD")")/$(basename "$LD")/" 2>/dev/null; sleep 30; done ) &
fi
keep() {  # $1 = iteration: save this iteration's build output and patch log under $LD
  local p=$LD/iter$1
  cp -p "$p.out.part" "$p-setup.log" 2>/dev/null; rm -f "$p.out.part"
  [ "${FULL:-0}" = 1 ] && { cp -p "$W/build.log" "$p-build.log" 2>/dev/null; cp -p "$W/patch.log" "$p-patch.log" 2>/dev/null; }
  [ -n "${LOG_HOST:-}" ] && sudo -u "$RUN_AS" rsync -aq "$LD/" "$LOG_HOST:$(basename "$(dirname "$LD")")/$(basename "$LD")/" 2>/dev/null
  sync
}
# Events go to the kernel log at level 3 so they reach the serial console even with a quiet console loglevel (4).
say() { local m="stability: $(date +%T) $*"; echo "$m" >> $L; echo "<3>$m" > /dev/kmsg; }
edac() { echo "ce=$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | paste -sd+) ue=$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null | paste -sd+)"; }
temps() { echo "max=$(( $(cat /sys/class/thermal/thermal_zone*/temp | sort -n | tail -1) / 1000 ))C"; }
: > $L
say "start $(uname -r) hours=$HOURS stress=${STRESS_MIN}min full=${FULL:-0} logs=$LD"
END=$(( SECONDS + HOURS * 3600 )); i=0; fails=0
while [ $SECONDS -lt $END ]; do
  i=$((i + 1))
  t0=$SECONDS
  say "iter $i build start $(temps)"
  if [ "${FULL:-0}" = 1 ]; then
    # full from-scratch build (fresh clone/untar/patch: the heavy-NVMe pattern that failed at 6000)
    sudo -u "$RUN_AS" env WORK=$W REPO="$REPO" FORCE=1 bash -c 'cd "$REPO" && scripts/setup.sh packages >/dev/null && scripts/setup.sh source && scripts/setup.sh build' > "$LD/iter$i.out.part" 2>&1
  else
    ( cd "$TREE" && sudo -u "$RUN_AS" make -s clean && sudo -u "$RUN_AS" make -s -j6 ) > "$LD/iter$i.out.part" 2>&1
  fi
  rc=$?
  keep $i
  say "iter $i build rc=$rc $(( (SECONDS - t0) / 60 ))min $(temps) $(edac)"
  if [ $rc -ne 0 ]; then fails=$((fails + 1)); tail -20 "$LD/iter$i-setup.log" >> $L; say "iter $i BUILD FAILED (full logs: $LD/iter$i-*.log)"; fi
  sync
  [ $SECONDS -ge $END ] && break
  t0=$SECONDS
  out=$(stress-ng --vm 6 --vm-bytes 60% --verify --cpu 6 --timeout ${STRESS_MIN}m 2>&1)
  pass=$(echo "$out" > "$LD/iter$i-stress.log"; echo "$out" | grep -iE "fail|error|verif" | head -5 >> $L; keep $i| grep -oE "passed: [0-9]+" | head -1); fail=$(echo "$out" | grep -oE "failed: [0-9]+" | head -1)
  say "iter $i stress $pass $fail $(( (SECONDS - t0) / 60 ))min $(temps) $(edac)"
  echo "$out" | grep -iE "fail|error|verif" | head -5 >> $L
  [ "${fail#failed: }" != "0" ] && { fails=$((fails + 1)); say "iter $i STRESS FAILED"; }
  sync
done
say "STABILITY-DONE iterations=$i failures=$fails after $(( SECONDS / 60 ))min"
sync
