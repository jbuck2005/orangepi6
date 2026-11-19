#!/bin/bash
# Orange Pi 6: power-cycle the two RTL8125 NICs from software.
#
# Why: after a warm reboot the firmware sometimes fails PCIe link training for both NICs
# ("Root Port 2/3: Link Up Fail,Ltssm State:40C80" on the serial console, LTSSM = Polling.Compliance:
# the RC sees a receiver but the NIC never sends training sets). Only removing power fixed it.
# Every failure in our serial log came right after a session that ran the NICs, never after a cold start.
#
# How: on this board each NIC's 3.3 V rail (3V3_LAN, 3V3_LAN_2) comes from +3.3V_ALW through a
# P-FET load switch (Q4711) whose gate is driven by SoC pad GPIO038 (NIC 1) / GPIO039 (NIC 2)
# through an N-FET (Q4712), with a 100K pull-up (schematic OPi_6 V1.1, pages 19-20).
#   pad high or floating (input) -> NIC powered;  pad driven low -> NIC unpowered.
# GPIO038/039 are lines 27/28 of the S5 GPIO controller (Cadence, MMIO 0x16004000); their pad
# mux registers are at 0x16007000 + 0xdc / 0xe0 (function bits 8:7, 0 = GPIO).
# Releasing a line (direction = input) always restores power through the pull-up, so a crash
# mid-cycle cannot leave the NICs off for longer than until the next boot.
#
# Under the sky1 kernel (S5 GPIO driver bound) it uses gpioset/gpioget on that chip. Under Armbian's generic
# kernel (no driver) it writes the registers through /dev/mem, touching only lines 27 and 28.
#
# Usage (as root):
#   nic-power.sh probe                 read-only: registers, pad mux, NICs, PCIe state
#   nic-power.sh cycle [SECONDS]       remove the NIC PCI devices, cut power, restore it, rescan
#   nic-power.sh selftest              cycle once (network drops ~15 s); if the NICs don't come back
#                                      within 60 s, reboot. Run detached: systemd-run --unit nic-selftest ...
#   nic-power.sh recover               boot-time: if NICs are missing, power-cycle and reboot (max 2 tries)
#   nic-power.sh shutdown-hook ACTION  systemd-shutdown hook: on reboot, power-cycle the NICs last thing
#   nic-power.sh install | uninstall   install the boot unit and the shutdown hook
set -uo pipefail

GPIO_BASE=0x16004000      # S5 GPIO0 (Cadence): 0x00 bypass, 0x04 dir (1=in), 0x08 out-en, 0x0c out, 0x10 in
PAD_BASE=0x16007000       # S5 iomux
LINES="27 28"             # GPIO038 -> NIC on 3V3_LAN, GPIO039 -> NIC on 3V3_LAN_2
PADS="0xdc 0xe0"
OFF_SECS=${OFF_SECS:-3}
EXPECT=${EXPECT_NICS:-2}
STATE=/var/lib/opi6-nic
LOGTAG=opi6-nic
SELF=/usr/local/sbin/opi6-nic-power

log() { echo "$LOGTAG: $*"; command -v logger >/dev/null && logger -t "$LOGTAG" -- "$*" 2>/dev/null; return 0; }
die() { log "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
command -v python3 >/dev/null || die "python3 is needed for /dev/mem access"

# mem OP ARGS: tiny /dev/mem helper. read ADDR | rmw ADDR CLEARMASK SETMASK
mem() {
  python3 -I - "$@" <<'PY'
import mmap, os, struct, sys
op, addr = sys.argv[1], int(sys.argv[2], 0)
page = addr & ~0xfff
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
o = addr - page
v = struct.unpack_from("<I", m, o)[0]
if op == "rmw":
    v = (v & ~int(sys.argv[3], 0)) | int(sys.argv[4], 0)
    struct.pack_into("<I", m, o, v & 0xffffffff)
    v = struct.unpack_from("<I", m, o)[0]
print("0x%08x" % v)
m.close(); os.close(fd)
PY
}
reg() { printf '0x%x' $(( GPIO_BASE + $1 )); }
mask() { local m=0 l; for l in $LINES; do m=$(( m | (1 << l) )); done; printf '0x%x' $m; }

nic_bdfs() {  # PCI addresses of RTL8125s (10ec:8125)
  local d
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10ec ] && [ "$(cat "$d/device" 2>/dev/null)" = 0x8125 ] && echo "${d##*/}"
  done
}
nic_count() { nic_bdfs | wc -l; }

pads_to_gpio() {  # make sure GPIO038/039 pads are muxed to GPIO (function 0)
  local p
  for p in $PADS; do mem rmw $(printf '0x%x' $(( PAD_BASE + p ))) 0x180 0 >/dev/null || return 1; done
}

# Under the sky1 kernel the S5 GPIO and iomux blocks are owned by kernel drivers, so go through
# libgpiod (gpioset/gpioget) on that chip. Under Armbian nothing owns them, so poke the registers.
iomem_owner() { awk -v a="$1" 'index($1, a"-") == 1 {print $3; exit}' /proc/iomem 2>/dev/null; }
gpio_chip() {  # gpiochip whose parent device owns the S5 GPIO0 MMIO block
  local owner c; owner=$(iomem_owner 16004000)
  [ -n "$owner" ] || return 1
  for c in /sys/bus/gpio/devices/gpiochip*; do
    readlink -f "$c" | grep -q "/$owner/" && { echo "${c##*/}"; return 0; }
  done
  return 1
}
gpiod_v2() { gpioset --version 2>/dev/null | grep -q 'v2'; }

power() {  # power off SECS (cut, wait, restore) | power on
  local M chip l args=() inargs=()
  M=$(mask)
  if chip=$(gpio_chip); then
    command -v gpioset >/dev/null || die "S5 GPIO is driver-owned ($chip); install gpiod (apt install gpiod)"
    for l in $LINES; do args+=("$l=0"); inargs+=("$l"); done
    if [ "$1" = off ]; then
      if gpiod_v2; then timeout "$2" gpioset -c "$chip" "${args[@]}" || true; else gpioset --mode=time --sec="$2" "$chip" "${args[@]}"; fi
    fi
    # Reading the lines requests them as inputs: the pull-ups switch the rails back on.
    if gpiod_v2; then gpioget -c "$chip" "${inargs[@]}" >/dev/null; else gpioget "$chip" "${inargs[@]}" >/dev/null; fi
    return
  fi
  [ -z "$(iomem_owner 16004000)" ] || die "S5 GPIO is owned by a driver but no gpiochip found for it"
  if [ "$1" = off ]; then
    [ -z "$(iomem_owner 16007000)" ] && { pads_to_gpio || return 1; }
    mem rmw "$(reg 0x00)" "$M" 0  >/dev/null &&   # GPIO mode (clear bypass)
    mem rmw "$(reg 0x0c)" "$M" 0  >/dev/null &&   # output value 0
    mem rmw "$(reg 0x08)" 0 "$M"  >/dev/null &&   # output enable
    mem rmw "$(reg 0x04)" "$M" 0  >/dev/null ||   # direction = output -> pads low -> rails off
      { mem rmw "$(reg 0x04)" 0 "$M" >/dev/null; return 1; }
    sleep "$2"
  fi
  mem rmw "$(reg 0x04)" 0 "$M"  >/dev/null        # direction = input -> pull-ups -> rails on
}

detach_nics() {  # unbind and remove the NIC PCI functions so nothing touches them while unpowered
  local b
  for b in $(nic_bdfs); do
    [ -e "/sys/bus/pci/devices/$b/driver" ] && echo "$b" > "/sys/bus/pci/devices/$b/driver/unbind" 2>/dev/null
    echo 1 > "/sys/bus/pci/devices/$b/remove" 2>/dev/null
  done
}

cycle() {
  local secs=${1:-$OFF_SECS}
  log "power-cycling NICs (${secs}s off); present before: $(nic_count)"
  detach_nics
  power off "$secs" || { power on; die "could not drive GPIO038/039"; }
  sleep 1
  echo 1 > /sys/bus/pci/rescan 2>/dev/null
  sleep 2
  log "power restored; present after rescan: $(nic_count)"
}

probe() {
  local M l p v
  M=$(mask)
  echo "== kernel $(uname -r)"
  echo "== /proc/iomem owners near S5 GPIO / iomux"; grep -iE '^ *1600[47]' /proc/iomem || echo "  (none: no kernel driver owns them)"
  echo "== S5 GPIO0 @ $GPIO_BASE (lines $LINES = GPIO038/GPIO039)"
  for o in 0x00:bypass 0x04:dir_in 0x08:out_en 0x0c:out 0x10:in; do
    v=$(mem read "$(reg ${o%%:*})") || die "/dev/mem read failed (CONFIG_STRICT_DEVMEM?)"
    printf '  %-7s %s ' "${o#*:}" "$v"; for l in $LINES; do printf ' line%s=%d' "$l" $(( (v >> l) & 1 )); done; echo
  done
  echo "  expect: in line27=1 line28=1 (pulled up = NICs powered)"
  echo "== pad mux (function bits 8:7, 0 = GPIO)"
  for p in $PADS; do v=$(mem read "$(printf '0x%x' $(( PAD_BASE + p )))"); printf '  pad +%s = %s  func=%d\n' "$p" "$v" $(( (v >> 7) & 3 )); done
  echo "== S5 GPIO0 owner: $(iomem_owner 16004000) -> chip: $(gpio_chip || echo 'none (registers via /dev/mem)')  gpioset: $(command -v gpioset || echo missing)"
  command -v gpioinfo >/dev/null && gpioinfo 2>/dev/null | grep -iE 'chip|line +2[78]:' | head -20
  echo "== RTL8125 PCI functions ($(nic_count) of $EXPECT)"
  for b in $(nic_bdfs); do echo "  $b driver=$(basename "$(readlink -f /sys/bus/pci/devices/$b/driver 2>/dev/null)" 2>/dev/null) net=$(ls /sys/bus/pci/devices/$b/net 2>/dev/null | tr '\n' ' ')"; done
  echo "== default route via: $(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)"
  echo "== pci tree"; command -v lspci >/dev/null && lspci -tv 2>/dev/null | head -30
  echo "== sky1-pcie link state"; for f in /sys/kernel/debug/*sky1*/link_status /sys/kernel/debug/*/*sky1*/link_status; do [ -r "$f" ] && echo "  $f: $(cat "$f")"; done 2>/dev/null
  dmesg 2>/dev/null | grep -iE 'sky1-pcie\.[34].*(link|fail)|PCIe link down' | tail -6
}

recover() {
  mkdir -p "$STATE"
  power on 2>/dev/null   # never leave the rails off from an interrupted cycle
  local i n
  for i in $(seq 1 20); do n=$(nic_count); [ "$n" -ge "$EXPECT" ] && break; sleep 1; done
  if [ "$n" -ge "$EXPECT" ]; then echo 0 > "$STATE/attempts"; log "both NICs present"; exit 0; fi
  local tries; tries=$(cat "$STATE/attempts" 2>/dev/null || echo 0)
  log "only $n of $EXPECT NICs present (failed link training); recovery attempt $((tries + 1))"
  cycle
  if [ "$(nic_count)" -ge "$EXPECT" ]; then echo 0 > "$STATE/attempts"; log "recovered without reboot"; exit 0; fi
  if [ "$tries" -ge 2 ]; then log "giving up after $tries reboots; needs a power cut"; exit 1; fi
  echo $((tries + 1)) > "$STATE/attempts"; sync
  # A sky1 default boot that reached userspace counts as up: clear GRUB's pending mark so the
  # recovery reboot doesn't fall back to Armbian. (Test boots, sky1test=acpi|dt, are skipped by the unit.)
  grep -q 'sky1test=default' /proc/cmdline && command -v grub-editenv >/dev/null && grub-editenv - set sky1_pending=0
  log "rebooting (the shutdown hook power-cycles the NICs just before reset)"
  systemctl reboot
}

case "${1:-}" in
  probe) probe ;;
  cycle) cycle "${2:-$OFF_SECS}" ;;
  on) power on ;;
  recover) recover ;;
  selftest)
    OUT=/var/log/opi6-nic-selftest.txt
    { echo "== $(date -Is) selftest on $(uname -r)"; probe; } > "$OUT" 2>&1
    cycle "$OFF_SECS" >> "$OUT" 2>&1
    for i in $(seq 1 60); do
      [ "$(nic_count)" -ge "$EXPECT" ] && [ -n "$(ip -4 route show default)" ] && break; sleep 1
    done
    { echo "== after ${i}s: $(nic_count) NICs, default route: $(ip -4 route show default | head -1)"; ip -br link; } >> "$OUT" 2>&1
    if [ "$(nic_count)" -ge "$EXPECT" ] && [ -n "$(ip -4 route show default)" ]; then
      echo "== PASS: NICs power-cycled and came back without a reboot" >> "$OUT"
    else
      echo "== NICs not back after 60 s; rebooting (they were just power-cycled, so firmware should train them)" >> "$OUT"
      sync; systemctl reboot
    fi ;;
  shutdown-hook)
    # systemd-shutdown runs this after all services stopped, before the kernel's reboot().
    [ "${2:-}" = reboot ] || exit 0
    [ -e "$STATE/disabled" ] && exit 0
    cycle "$OFF_SECS" ;;
  install)
    install -m755 "$0" "$SELF"
    install -d /usr/lib/systemd/system-shutdown
    printf '#!/bin/sh\nexec %s shutdown-hook "$1"\n' "$SELF" > /usr/lib/systemd/system-shutdown/opi6-nic-powercycle
    chmod 755 /usr/lib/systemd/system-shutdown/opi6-nic-powercycle
    install -m644 "$(dirname "$0")/../systemd/opi6-nic-recover.service" /etc/systemd/system/
    systemctl daemon-reload && systemctl enable opi6-nic-recover.service
    log "installed: reboots power-cycle the NICs; boots with missing NICs recover automatically" ;;
  uninstall)
    systemctl disable opi6-nic-recover.service 2>/dev/null
    rm -f /etc/systemd/system/opi6-nic-recover.service /usr/lib/systemd/system-shutdown/opi6-nic-powercycle "$SELF"
    systemctl daemon-reload; log "removed" ;;
  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
