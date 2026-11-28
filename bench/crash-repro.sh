#!/bin/bash
# Reproducer for the corruption crashes under heavy module-link load (see bench/CRASH-ANALYSIS.md).
# Rebuilds every module of an already-built kernel tree (LD + pahole BTF + resolve_btfids), N times, while
# logging events to the kernel log (they reach the serial console) and sensors to the set's folder.
# Follow bench/TEST-PROCESS.md: boot loggers installed (bench/benchlog.sh), pre-flight passed, serial captured.
#
#   TREE=<built kernel tree with CONFIG_DEBUG_INFO_BTF_MODULES=y> CPUS=0-11 J=6 N=5 TAG=<set name> \
#     [MAXF=<kHz> [MAXF_CPUS=10,11]] EXPECT_KERNEL=7.3.5 EXPECT_CAPS="p0=2600 ... p10=2400" FAN=on \
#     bench/crash-repro.sh
#
# MAXF caps scaling_max_freq for the run (Linux setting only; a reboot resets it): on every cpufreq policy, or with
# MAXF_CPUS (comma list of CPU numbers) only on the policies of those CPUs. MAXF=2400000 MAXF_CPUS=10,11 is the
# documented workaround (the weak cpu10-11 pair only). The caps are applied, then bench/preflight.sh must pass
# (it reads every policy back against EXPECT_CAPS); PREFLIGHT=0 skips it, for experiments only.
#
# Results: $LOG_DIR (default ~/crash-repro/<time>-<tag>/), nothing in it is ever overwritten:
#   set.conf      what the set is (tag, N, kernel, caps, start)        preflight-<n>.txt  each start's pre-flight
#   results.csv   one row per run: run,start,end,secs,kernel,caps,result,signature,peak_cpu_c,peak_nvme_c,log
#   events.log    every event (also in the kernel log)                 sensors.csv / temps.log  samples every 10 s
#   make<i>.log   each run's full build output                         panic-run<i>/  pstore records of a crash
# result: pass, fail (rc!=0 or a tool crashed) or panic (the board went down during the run).
# After a panic or hang the board reboots (panic=10) or needs the power button. Then run the same command with
# LOG_DIR set to the same folder: the unfinished run is recorded as "panic" (signature from pstore, else see the
# serial capture), the caps are applied again, pre-flight runs again, and the set continues to N runs in total.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib-sensors.sh"
TREE=${TREE:?set TREE to a built kernel tree}; CPUS=${CPUS:-0-11}; J=${J:-6}; N=${N:-3}
TAG=${TAG:-cpus$CPUS${MAXF:+-$MAXF}${MAXF_CPUS:+-on${MAXF_CPUS//,/_}}}
R=${LOG_DIR:-$HOME/crash-repro/$(date +%Y%m%d-%H%M%S)-$TAG}; mkdir -p "$R"; R=$(cd "$R" && pwd)
cd "$TREE" || exit 1; [ -f Makefile ] && [ -f .config ] || { echo "not a kernel tree: $TREE"; exit 1; }
say() { local m="repro: $(date +%T) $*"; echo "$m" | tee -a "$R/events.log"; echo "<3>$m" | sudo tee /dev/kmsg >/dev/null; sync; }
csv() { printf '%s' "$*" | tr -d '\r' | tr ',\n' ';;' | cut -c1-200; }       # make a value safe for one CSV field
peak() {  # $1 = column (2 cpu, 3 nvme), $2 = from epoch, $3 = to epoch: peak from this set's temps.log (+-10 s)
  awk -v c="$1" -v a="$(( $2 - 10 ))" -v b="$(( $3 + 10 ))" '$1 >= a && $1 <= b && $c != "na" && $c > m { m = $c } END { print (m == "" ? "na" : m) }' "$R/temps.log" 2>/dev/null
}
record() {  # run start end result signature [caps]
  local log="make$1.log"; [ "$4" = panic ] && log="panic-run$1"
  echo "$1,$(date -u -d @"$2" +%FT%TZ),$(date -u -d @"$3" +%FT%TZ),$(( $3 - $2 )),$(uname -r),${6:-$(caps_line)},$4,$(csv "$5"),$(peak 2 "$2" "$3"),$(peak 3 "$2" "$3"),$log" >> "$R/results.csv"
  sync
}
[ -s "$R/results.csv" ] || echo "run,start,end,secs,kernel,caps,result,signature,peak_cpu_c,peak_nvme_c,log" > "$R/results.csv"

# A run that started but has no result: the board went down during it. Record it before anything else.
for m in "$R"/run*.started; do
  [ -e "$m" ] || continue
  i=$(basename "$m" .started); i=${i#run}; t0=$(cut -d'|' -f1 "$m"); c0=$(cut -d'|' -f2 "$m"); t1=$(tail -n 1 "$R/temps.log" 2>/dev/null | cut -d' ' -f1)
  mkdir -p "$R/panic-run$i"; sudo -n sh -c "cp -p /sys/fs/pstore/* '$R/panic-run$i/' 2>/dev/null"; sudo -n chown -R "$(id -u)" "$R/panic-run$i" 2>/dev/null
  sig=$(cat "$R/panic-run$i"/* 2>/dev/null | grep -a -m1 -oE 'Kernel panic - not syncing:.*|Unable to handle kernel.*|Internal error:.*|Watchdog detected hard LOCKUP.*|Kernel stack is corrupted.*|Oops.*')
  record "$i" "$t0" "${t1:-$t0}" panic "${sig:-board went down; no pstore record, see the serial capture}" "$c0"
  rm -f "$m"; say "$TAG $i recorded as PANIC: ${sig:-no pstore record}"
done
done_runs=$(( $(wc -l < "$R/results.csv") - 1 ))

if [ -n "${MAXF:-}" ]; then
  if [ -n "${MAXF_CPUS:-}" ]; then pols=(); for c in ${MAXF_CPUS//,/ }; do pols+=("/sys/devices/system/cpu/cpu$c/cpufreq"); done
  else pols=(/sys/devices/system/cpu/cpufreq/policy*); fi
  for p in "${pols[@]}"; do echo "$MAXF" | sudo tee "$p/scaling_max_freq" >/dev/null || { echo "cannot cap $p"; exit 1; }; done
fi
if [ "${PREFLIGHT:-1}" != 0 ]; then
  k=1; while [ -e "$R/preflight-$k.txt" ]; do k=$((k + 1)); done; pf=$R/preflight-$k.txt
  OUT=$pf TREE=$TREE "$HERE/preflight.sh" || { say "$TAG pre-flight FAILED, not starting (see $pf)"; exit 1; }
fi
[ "$(sed -n 's/^n=//p' "$R/set.conf" 2>/dev/null | tail -n 1)" = "$N" ] || [ ! -s "$R/set.conf" ] || echo "n=$N" >> "$R/set.conf"  # N changed on a resume
[ -s "$R/set.conf" ] || printf 'tag=%s\nn=%s\ncpus=%s\nj=%s\nmaxf=%s\nmaxf_cpus=%s\nkernel=%s\ncaps=%s\nstart=%s\ntree=%s\n' \
  "$TAG" "$N" "$CPUS" "$J" "${MAXF:-none}" "${MAXF_CPUS:-all}" "$(uname -r)" "$(caps_line)" "$(date -u +%FT%TZ)" "$TREE" > "$R/set.conf"

( [ -s "$R/sensors.csv" ] || sensors_header > "$R/sensors.csv"
  while :; do sensors_row >> "$R/sensors.csv"; echo "$(date +%s) $(cpu_temp) $(nvme_temp)" >> "$R/temps.log"; sync "$R/temps.log" 2>/dev/null; sleep 10; done ) & TP=$!
trap 'kill $TP 2>/dev/null' EXIT
say "$TAG start $(uname -r) cpus=$CPUS j=$J run $((done_runs + 1)) of $N maxf=${MAXF:-none}${MAXF_CPUS:+ on cpus $MAXF_CPUS} caps $(caps_line) fan=${FAN:-?} folder $R"
for i in $(seq $((done_runs + 1)) "$N"); do
  [ -e "$R/make$i.log" ] && { say "$TAG make$i.log already exists, refusing to overwrite it"; exit 1; }
  find . -name '*.ko' ! -path './.git/*' -delete
  t0=$(date +%s); echo "$t0|$(caps_line)" > "$R/run$i.started"; sync
  say "$TAG $i start cpu=$(cpu_temp)C nvme=$(nvme_temp)C"
  taskset -c "$CPUS" make -j"$J" modules > "$R/make$i.log" 2>&1; rc=$?; t1=$(date +%s); sync
  pat='^(Segmentation fault|Aborted|Bus error|Illegal instruction)|malloc\(\)|corrupted (double-linked|size)|double free|internal compiler error'
  bad=$(grep -cE "$pat" "$R/make$i.log"); sig=$(grep -m1 -E "$pat" "$R/make$i.log")
  res=pass; { [ $rc -ne 0 ] || [ "$bad" -gt 0 ]; } && res=fail
  [ $res = fail ] && [ -z "$sig" ] && sig="rc=$rc: $(grep -m1 -E 'Error [0-9]|error:' "$R/make$i.log")"
  record "$i" "$t0" "$t1" $res "$sig"; rm -f "$R/run$i.started"
  say "$TAG $i ${res^^} rc=$rc $(( t1 - t0 ))s tool_crashes=$bad peak cpu=$(peak 2 "$t0" "$t1")C nvme=$(peak 3 "$t0" "$t1")C ${sig:+sig: $sig}"
done
say "$TAG DONE $(awk -F, 'NR > 1 { n++; c[$7]++ } END { printf "%d runs: %d pass, %d fail, %d panic", n, c["pass"], c["fail"], c["panic"] }' "$R/results.csv")"
