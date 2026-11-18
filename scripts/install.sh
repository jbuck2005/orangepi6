#!/bin/bash
# Install the Sky1 test kernel beside Armbian, without touching Armbian's files or GRUB default.
#
#   sudo WORK=/home/<user>/sky1-build scripts/install.sh stage      # modules, /boot/sky1/*, boot logger, initramfs; then verify
#   sudo WORK=...                     scripts/install.sh verify     # re-run every check (no changes)
#   sudo WORK=...                     scripts/install.sh arm dt     # GRUB entry (device tree, GPU) as LAST entry, arm ONE boot
#   sudo WORK=...                     scripts/install.sh arm acpi   # same kernel in ACPI mode (diagnostic: kernel/initrd OK?)
#   sudo                              scripts/install.sh disarm     # remove the entry, clear next_entry
#   sudo                              scripts/install.sh bootlog    # print the raw boot log written by the last test boot
#
# Kernel, initrd and DTB live in /boot/sky1/, so Armbian's 10_linux never generates entries for them.
# The GRUB snippet is 45_sky1 (after 10_linux), so entry 0, the default, stays Armbian.
# The initramfs is built from a private confdir, /etc/sky1/initramfs-tools, which Armbian never uses.
set -euo pipefail

die()  { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
DTB_NAME=sky1-orangepi-6.dtb
BOOTDIR=${BOOTDIR:-/boot/sky1}
MODROOT=${MODROOT:-}   # test hook: alternate root for /lib/modules
GRUB_SNIPPET=/etc/grub.d/45_sky1
ENTRY_PREFIX="Sky1 test"
CONFDIR=/etc/sky1/initramfs-tools
BOOTLOG_FILE=/var/lib/sky1/bootlog.bin
BOOTLOG_CONF=/etc/sky1-bootlog.conf
NETCON_CONF=/etc/sky1-netconsole.conf

load_build() {
  : "${WORK:?set WORK to the build directory}"
  SRC=$WORK/linux-6.18.14
  [ -f "$SRC/include/config/kernel.release" ] || die "no kernel.release; build not finished"
  KREL=$(cat "$SRC/include/config/kernel.release")
  [ -n "$KREL" ] || die "empty kernel release"
  [ -f "$SRC/arch/arm64/boot/Image" ] || die "Image missing"
  [ -f "$SRC/arch/arm64/boot/dts/cix/$DTB_NAME" ] || die "$DTB_NAME missing"
  [ "$SRC/arch/arm64/boot/Image" -nt "$SRC/.config" ] || die "Image older than .config; rebuild"
  # shellcheck disable=SC1091
  . "$WORK/env.sh"
}

verify_bootlog() {
  [ -f "$BOOTLOG_CONF" ] || die "$BOOTLOG_CONF missing"
  "$REPO/scripts/bootlog-area.sh" prove "$BOOTLOG_CONF" "$BOOTLOG_FILE"
  if [ -f "$NETCON_CONF" ]; then
    # shellcheck disable=SC1090
    . "$NETCON_CONF"
    for v in REMOTE_IP REMOTE_MAC LOCAL_IP LOCAL_MAC; do [ -n "${!v:-}" ] || die "$v empty in $NETCON_CONF"; done
    ok "netconsole target configured"
  else
    echo "  note: no $NETCON_CONF; netconsole disabled"
  fi
}

verify() {
  echo "== verify $KREL"
  local M=$MODROOT/lib/modules/$KREL
  [ -d "$M" ] || die "$M missing"; ok "$M exists"
  for f in modules.dep modules.builtin modules.order; do [ -s "$M/$f" ] || die "$M/$f missing/empty"; done; ok "modules.dep/builtin/order present"
  modinfo ${MODROOT:+-b "$MODROOT"} -k "$KREL" panthor >/dev/null 2>&1 || die "module panthor not found for $KREL"
  local vm; vm=$(modinfo ${MODROOT:+-b "$MODROOT"} -k "$KREL" -F vermagic panthor | awk '{print $1}')
  [ "$vm" = "$KREL" ] || die "panthor vermagic '$vm' != '$KREL'"; ok "panthor module present, vermagic matches"
  for b in nvme ext4 pcie-sky1 phy-cix-pcie ramoops r8125 netconsole; do
    grep -qE "/$b\.ko|/${b//-/_}\.ko" "$M/modules.builtin" || die "$b not built in"
  done; ok "nvme, ext4, Sky1 PCIe host+PHY, ramoops, r8125, netconsole built in"
  cmp -s "$BOOTDIR/vmlinuz" "$SRC/arch/arm64/boot/Image" || die "$BOOTDIR/vmlinuz missing or stale"; ok "kernel in $BOOTDIR matches build"
  cmp -s "$BOOTDIR/$DTB_NAME" "$SRC/arch/arm64/boot/dts/cix/$DTB_NAME" || die "DTB missing or stale"
  local D; D=$(dtc -q -I dtb -O dts "$BOOTDIR/$DTB_NAME") || die "dtc cannot read DTB"
  grep -q 'model = "Orange Pi 6";' <<<"$D" || die "DTB model is not Orange Pi 6"
  for n in 0a070000 0a0d0000; do grep -A40 "pcie@$n {" <<<"$D" | grep -m1 'status =' | grep -q disabled || die "pcie@$n not disabled in DTB"; done
  ok "DTB is the non-Plus Orange Pi 6 (unused PCIe ports disabled)"
  [ -s "$BOOTDIR/initrd.img" ] || die "initrd missing"
  local L; L=$(lsinitramfs "$BOOTDIR/initrd.img")
  grep -q "lib/modules/$KREL/modules.dep" <<<"$L" || die "initrd has no modules for $KREL"
  grep -qx 'usr/bin/sky1-bootlog' <<<"$L" || die "initrd lacks the boot logger"
  grep -qx 'etc/sky1-bootlog.conf' <<<"$L" || die "initrd lacks the boot-log config"
  grep -qx 'scripts/init-top/sky1-bootlog' <<<"$L" || die "initrd lacks init-top/sky1-bootlog"
  local T; T=$(mktemp -d)
  unmkinitramfs "$BOOTDIR/initrd.img" "$T"
  local IR=$T; [ -d "$T/main" ] && IR=$T/main
  grep -q '^/scripts/init-top/sky1-bootlog ' "$IR/scripts/init-top/ORDER" || { rm -rf "$T"; die "init-top ORDER does not run sky1-bootlog"; }
  grep -q '^/scripts/init-bottom/sky1-bootlog ' "$IR/scripts/init-bottom/ORDER" || { rm -rf "$T"; die "init-bottom ORDER does not run sky1-bootlog"; }
  cmp -s "$IR/etc/sky1-bootlog.conf" "$BOOTLOG_CONF" || { rm -rf "$T"; die "initrd boot-log config differs from $BOOTLOG_CONF"; }
  # Run the initrd's own logger with the initrd's own tools (klibc dd etc.) against a scratch
  # file, so a tool incompatibility shows up here and not as an empty log after a test boot.
  local S; S=$(mktemp -d)
  head -c 65536 /dev/zero > "$S/area"
  printf 'DEV=%s\nOFFSET=8192\nSIZE=16384\n' "$S/area" > "$S/conf"
  env -i PATH="$IR/usr/bin:$IR/usr/sbin:$IR/bin:$IR/sbin" SKY1_BOOTLOG_CONF="$S/conf" SKY1_TMP="$S/tmp" \
    SKY1_DMESG="echo sky1-selftest-dmesg" "$IR/usr/bin/sh" "$IR/usr/bin/sky1-bootlog" dump
  if ! dd if="$S/area" bs=4096 skip=2 count=4 status=none | tr -d '\000' | grep -q 'sky1-selftest-dmesg'; then
    rm -rf "$S" "$T"; die "initrd's boot logger, run with the initrd's own tools, wrote nothing"
  fi
  [ "$(head -c 8192 "$S/area" | tr -d '\000' | wc -c)" -eq 0 ] || { rm -rf "$S" "$T"; die "initrd's boot logger wrote outside its area"; }
  rm -rf "$S"
  ok "initrd's boot logger works with the initrd's own dd (self-test)"
  rm -rf "$T"
  ok "initrd has modules for $KREL and the boot logger wired into init-top/init-bottom"
  verify_bootlog
  [ -f /lib/firmware/arm/mali/arch12.8/mali_csffw.bin ] || die "Mali CSF firmware missing"; ok "Mali CSF firmware present"
  echo "== all checks passed"
}

stage() {
  need_root; load_build
  echo "== stage $KREL"
  make -C "$SRC" HOSTCC="$HOSTCC" CC="$CC" -s modules_install
  depmod "$KREL"
  install -d "$BOOTDIR"
  install -m644 "$SRC/arch/arm64/boot/Image" "$BOOTDIR/vmlinuz"
  install -m644 "$SRC/arch/arm64/boot/dts/cix/$DTB_NAME" "$BOOTDIR/$DTB_NAME"
  install -m644 "$SRC/.config" "$BOOTDIR/config"
  echo "$KREL" > "$BOOTDIR/kernel.release"
  # boot logger: raw log area + private initramfs confdir
  install -d "$(dirname "$BOOTLOG_FILE")"
  "$REPO/scripts/bootlog-area.sh" setup "$BOOTLOG_FILE" "$BOOTLOG_CONF"
  if [ -f "$WORK/netconsole.conf" ]; then install -m644 "$WORK/netconsole.conf" "$NETCON_CONF"; fi
  install -m755 "$REPO/initramfs/sky1-bootlog" /usr/sbin/sky1-bootlog
  rm -rf "$CONFDIR"; install -d "$(dirname "$CONFDIR")"
  cp -a /etc/initramfs-tools "$CONFDIR"
  install -D -m755 "$REPO/initramfs/hook-sky1-bootlog" "$CONFDIR/hooks/sky1-bootlog"
  install -D -m755 "$REPO/initramfs/init-top-sky1-bootlog" "$CONFDIR/scripts/init-top/sky1-bootlog"
  install -D -m755 "$REPO/initramfs/init-bottom-sky1-bootlog" "$CONFDIR/scripts/init-bottom/sky1-bootlog"
  mkinitramfs -d "$CONFDIR" -o "$BOOTDIR/initrd.img" "$KREL" 2> >(grep -v 'Kernel configuration /boot/config-' >&2)
  install -m755 "$REPO/scripts/boot-report.sh" /usr/local/sbin/sky1-boot-report
  install -m644 "$REPO/systemd/sky1-boot-report.service" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable -q sky1-boot-report.service
  verify
}

cmdline() {  # $1 = mode (dt|acpi), $2 = root uuid
  local mode=$1 uuid=$2 c nc="" panic=10 early=""
  # SCREEN=1 (someone at the monitor): print from the very first instruction on the EFI
  # framebuffer and stop on a panic instead of rebooting, so the message stays on screen.
  if [ "${SCREEN:-0}" = 1 ]; then panic=0; early=" earlycon=efifb keep_bootcon"; fi
  # SERIAL=1 (debug UART logged): earlycon straight on UART2 (SBSA/PL011 at 0x040d0000, the
  # board's DEBUG header; the firmware has no SPCR table, so a bare "earlycon" prints nothing in
  # ACPI mode). efi=debug makes the EFI stub report each step. Stop on panic, keep the text.
  if [ "${SERIAL:-0}" = 1 ]; then panic=0; early=" earlycon=pl011,mmio32,0x040d0000 keep_bootcon efi=debug"; fi
  c="root=UUID=$uuid ro rootwait panic=$panic sky1test=$mode ignore_loglevel printk.devkmsg=on clk_ignore_unused efi=noruntime$early"
  if [ -f "$NETCON_CONF" ]; then
    # shellcheck disable=SC1090
    . "$NETCON_CONF"
    nc=" netpoll.carrier_timeout=15 netconsole=+6665@$LOCAL_IP/$LOCAL_MAC,6666@$REMOTE_IP/$REMOTE_MAC"
  fi
  case "$mode" in
    dt)   [ -n "$early" ] || c="$c earlycon"; c="$c acpi=off console=ttyAMA2,115200" ;;
    acpi) c="$c acpi=force arm-smmu-v3.disable_bypass=0" ;;
    *) die "mode must be dt or acpi" ;;
  esac
  # The last console= becomes /dev/console, which gets the initramfs and init messages.
  # With SERIAL=1 that is the debug UART (ttyAMA2), so they reach the serial log.
  if [ "${SERIAL:-0}" = 1 ]; then echo "$c$nc console=tty1 console=ttyAMA2,115200"; else echo "$c$nc console=tty1"; fi
}

write_snippet() {  # $1 = output file, $2 = mode
  local uuid entry dtline=""
  uuid=$(findmnt -no UUID /); [ -n "$uuid" ] || die "no root UUID"
  entry="$ENTRY_PREFIX ($2)"
  # sky1_stage records the last GRUB step reached, so a failure that falls back to Armbian
  # (hidden menu, timeout 0) still says where it failed. "boot_returned" = kernel was started
  # but its EFI stub returned to GRUB.
  [ "$2" = dt ] && dtline="    if devicetree $BOOTDIR/$DTB_NAME; then set sky1_stage=dtb_ok; else set sky1_stage=dtb_failed; fi
    save_env sky1_stage"
  cat > "$1" <<GRUB
#!/bin/sh
cat <<'MENU'
menuentry "$entry" {
    set sky1_picked="$entry"
    set sky1_stage=picked
    save_env sky1_picked sky1_stage
    if search --no-floppy --fs-uuid --set=root $uuid; then set sky1_stage=search_ok; else set sky1_stage=search_failed; fi
    save_env sky1_stage
    if linux $BOOTDIR/vmlinuz $(cmdline "$2" "$uuid"); then set sky1_stage=linux_ok; else set sky1_stage=linux_failed; fi
    save_env sky1_stage
    if initrd $BOOTDIR/initrd.img; then set sky1_stage=initrd_ok; else set sky1_stage=initrd_failed; fi
    save_env sky1_stage
$dtline
    boot
    set sky1_stage=boot_returned
    save_env sky1_stage
}
MENU
GRUB
  chmod 755 "$1"
}

check_grub_cfg() {  # $1 = grub.cfg to check, $2 = mode
  local cfg=$1 entry="$ENTRY_PREFIX ($2)" first
  grub-script-check "$cfg" || die "grub-script-check failed on $cfg"
  first=$(grep -m1 -E '^[[:space:]]*(menuentry|submenu) ' "$cfg")
  grep -q 'Armbian' <<<"$first" || die "first entry is not Armbian: $first"
  ! grep -q "$ENTRY_PREFIX" <<<"$first" || die "test entry is the first (default) entry"
  [ "$(grep -c "menuentry \"$entry\"" "$cfg")" -eq 1 ] || die "test entry missing or duplicated"
  [ "$(grep -c "menuentry \"$ENTRY_PREFIX" "$cfg")" -eq 1 ] || die "more than one test entry"
  grep -qE '^GRUB_DEFAULT=0$' /etc/default/grub || die "GRUB_DEFAULT is not 0"
  grep -q 'next_entry' "$cfg" || die "grub.cfg lacks next_entry (no one-shot support)"
  grep -A3 "menuentry \"$entry\"" "$cfg" | grep -q 'save_env sky1_picked' || die "test entry lacks the sky1_picked marker"
  ! grep -E "^menuentry 'Armbian.*sky1" "$cfg" >/dev/null || die "10_linux generated Armbian entries for the sky1 kernel"
  if [ "$2" = dt ]; then
    grep -A20 "menuentry \"$entry\"" "$cfg" | grep -q "devicetree $BOOTDIR/$DTB_NAME" || die "dt entry lacks devicetree line"
    grep -A20 "menuentry \"$entry\"" "$cfg" | grep -q 'acpi=off' || die "dt entry lacks acpi=off"
  fi
  ok "grub.cfg: Armbian is entry 0, one test entry ($2), syntax OK"
}

check_disarmed() {  # $1 = grub.cfg
  local first
  grub-script-check "$1" || die "grub-script-check failed on $1"
  ! grep -q "$ENTRY_PREFIX" "$1" || die "test entry still in $1"
  ! grep -q '6.18.14-sky1' "$1" || die "sky1 kernel still referenced in $1"
  first=$(grep -m1 -E '^[[:space:]]*(menuentry|submenu) ' "$1")
  grep -q "Armbian GNU/Linux, with Linux $(uname -r)'" <<<"$first" || die "first entry is not the running Armbian kernel: $first"
  ok "grub.cfg: only Armbian entries, running kernel is entry 0"
}

arm() {  # $1 = mode
  local mode=${1:?usage: arm dt|acpi}
  [ "$mode" = dt ] || [ "$mode" = acpi ] || die "mode must be dt or acpi"
  need_root; load_build; verify
  local tmpcfg; tmpcfg=$(mktemp)
  write_snippet "$GRUB_SNIPPET" "$mode"
  grub-mkconfig -o "$tmpcfg" 2>/dev/null || { rm -f "$GRUB_SNIPPET" "$tmpcfg"; die "grub-mkconfig failed"; }
  ( check_grub_cfg "$tmpcfg" "$mode" ) || { rm -f "$GRUB_SNIPPET" "$tmpcfg"; die "generated grub.cfg rejected; nothing installed"; }
  install -m644 "$tmpcfg" /boot/grub/grub.cfg; rm -f "$tmpcfg"
  check_grub_cfg /boot/grub/grub.cfg "$mode"
  grub-editenv - unset sky1_picked sky1_stage
  grub-reboot "$ENTRY_PREFIX ($mode)"
  local E; E=$(grub-editenv list)
  grep -qx "next_entry=$ENTRY_PREFIX ($mode)" <<<"$E" || die "next_entry not set"
  ! grep -qE '^sky1_(picked|stage)=' <<<"$E" || die "sky1_picked/sky1_stage markers not cleared"
  grep -A20 "menuentry \"$ENTRY_PREFIX ($mode)\"" /boot/grub/grub.cfg | sed 's/^/    /'
  ok "armed for ONE boot; afterwards GRUB falls back to entry 0 (Armbian)"
}

disarm() {
  need_root
  rm -f "$GRUB_SNIPPET" /etc/grub.d/06_sky1
  # leftovers of the first (broken) install, which made 10_linux add sky1 entries
  rm -f /boot/vmlinuz-6.18.14-sky1 /boot/initrd.img-6.18.14-sky1 /boot/config-6.18.14-sky1 /boot/sky1-orangepi-6.dtb
  rm -rf "/lib/modules/6.18.14-sky1+"
  update-grub 2>/dev/null
  check_disarmed /boot/grub/grub.cfg
  grub-editenv - unset next_entry
  local E; E=$(grub-editenv list)
  ! grep -q '^next_entry=.' <<<"$E" || die "next_entry still set"
  ok "disarmed; GRUB default is Armbian"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0   # allow sourcing for tests
case "${1:-}" in
  stage) stage ;;
  verify) load_build; verify ;;
  arm) arm "${2:-}" ;;
  disarm) disarm ;;
  bootlog)
    echo "== GRUB markers: $(grub-editenv list | grep -E '^sky1_(picked|stage)=' | tr '\n' ' ' || true)"
    grub-editenv list | grep -q '^sky1_picked=' || echo "   (none: GRUB has not booted the test entry since arming)"
    "$REPO/scripts/bootlog-area.sh" read "$BOOTLOG_CONF" ;;
  *) echo "usage: $0 stage|verify|arm dt|arm acpi|disarm|bootlog"; exit 2 ;;
esac
