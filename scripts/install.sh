#!/bin/bash
# Install the Sky1 test kernel beside Armbian, without touching Armbian's files or GRUB default.
#
#   sudo WORK=/home/<user>/sky1-build scripts/install.sh stage      # modules, /boot/sky1/*, boot logger, initramfs; then verify
#   sudo WORK=...                     scripts/install.sh verify     # re-run every check (no changes)
#   sudo WORK=...                     scripts/install.sh arm dt     # GRUB entry (device tree, GPU) as LAST entry, arm ONE boot
#   sudo WORK=...                     scripts/install.sh arm acpi   # same kernel in ACPI mode (diagnostic: kernel/initrd OK?)
#   sudo                              scripts/install.sh disarm     # remove the entry, clear next_entry
#   sudo                              scripts/install.sh prune      # after a passed check: drop older sky1 module trees
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
# shellcheck disable=SC1091
. "$REPO/kernel.conf"
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
  SRC=$WORK/linux-$KV
  [ -f "$SRC/include/config/kernel.release" ] || die "no kernel.release; build not finished"
  KREL=$(cat "$SRC/include/config/kernel.release")
  [ -n "$KREL" ] || die "empty kernel release"
  [ -f "$SRC/arch/arm64/boot/Image" ] || die "Image missing"
  [ -f "$SRC/arch/arm64/boot/dts/cix/$DTB_NAME" ] || die "$DTB_NAME missing"
  [ "$SRC/arch/arm64/boot/Image" -nt "$SRC/.config" ] || die "Image older than .config; rebuild"
  # shellcheck disable=SC1091
  . "$WORK/env.sh"
}

# Under the sky1 kernel the vendor r8125 driver cannot read the NICs' MAC addresses in ACPI
# mode and picks random ones (new DHCP lease, netconsole target missing). Pin each port, by
# PCI path, to the address Armbian's r8169 reads. Driver=r8125 means Armbian never matches.
# The initramfs udev hook copies /etc/systemd/network/*.link, so it applies there too.
# Under sky1 the NICs sit behind platform host bridges, so their ID_PATH gains a prefix
# (platform-sky1-pcie.3.auto-pci-0000:61:00.0); Path= is a glob ending in the PCI address.
LINK_PREFIX=/etc/systemd/network/10-sky1-
write_links() {
  local n path mac drv count=0
  rm -f "$LINK_PREFIX"*.link
  for n in /sys/class/net/*; do
    drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null) || continue
    [ "$drv" = r8169 ] || continue
    path=$(udevadm info -q property -p "$n" | sed -n 's/^ID_PATH=//p')
    mac=$(cat "$n/address")
    [[ "$path" =~ ^pci-[0-9a-f:.]+$ ]] || die "unexpected ID_PATH '$path' for ${n##*/}"
    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] && [ "$mac" != 00:00:00:00:00:00 ] || die "bad MAC for ${n##*/}"
    # A random MAC from r8125 is locally administered (bit 1 of the first byte) and survives a
    # warm reset in the NIC, where r8169 then reads it. Never pin that; a full power-off (~30 s)
    # makes the NIC reload its factory address.
    (( (16#${mac:0:2} & 2) == 0 )) || die "${n##*/} has a locally administered MAC ($mac), probably a random one left by r8125 over a warm reset; power the board off for 30 s and run stage again"
    printf '[Match]\nDriver=r8125\nPath=*%s\n\n[Link]\nMACAddress=%s\nMACAddressPolicy=none\nNamePolicy=keep kernel database onboard slot path\nAlternativeNamesPolicy=database onboard slot path\n' \
      "$path" "$mac" > "$LINK_PREFIX$path.link"
    count=$((count + 1))
  done
  [ "$count" -ge 1 ] || die "no r8169 NICs found; run stage from Armbian"
  ok "pinned $count NIC MAC(s) for r8125 under sky1 ($LINK_PREFIX*.link)"
}

verify_links() {  # $1 = unpacked initrd root
  local f n cnt=0
  for f in "$LINK_PREFIX"*.link; do
    [ -f "$f" ] || die "no $LINK_PREFIX*.link (run stage)"
    grep -qx 'Driver=r8125' "$f" || die "$f does not match only r8125"
    cmp -s "$f" "$1/usr/lib/systemd/network/${f##*/}" || die "${f##*/} missing or stale in initrd"
    cnt=$((cnt + 1))
  done
  # On Armbian (r8169) the pin must not apply: udev must still pick its default .link.
  for n in /sys/class/net/*; do
    [ -e "$n/device" ] || continue
    # Under the sky1 kernel (r8125) the pin is supposed to apply; only check r8169 ports.
    [ "$(basename "$(readlink -f "$n/device/driver")")" = r8169 ] || continue
    ! udevadm test-builtin net_setup_link "$n" 2>&1 | grep -q '10-sky1-' || die "${n##*/}: sky1 .link applies under Armbian"
  done
  ok "$cnt NIC MAC pin(s) in initrd, inert under Armbian's r8169"
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
  local nic=r8125; grep -q "/r8169\.ko" "$M/modules.builtin" && nic=r8169  # NIC_DRIVER=r8169 build
  for b in nvme ext4 pcie-sky1 phy-cix-pcie ramoops $nic netconsole; do
    grep -qE "/$b\.ko|/${b//-/_}\.ko" "$M/modules.builtin" || die "$b not built in"
  done; ok "nvme, ext4, Sky1 PCIe host+PHY, ramoops, $nic, netconsole built in"
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
  # Nothing in the initrd may come from the build tree, and every dynamic program must find
  # all its libraries inside the initrd (checked with the initrd's own loader, chrooted).
  ! grep -q '^home/' <<<"$L" || { rm -rf "$T"; die "initrd contains files from /home (build env leaked into mkinitramfs)"; }
  local b missing=""
  for b in usr/sbin/modprobe usr/lib/systemd/systemd-udevd usr/bin/udevadm usr/bin/kmod; do
    [ -e "$IR/$b" ] || continue
    if ! chroot "$IR" /"$b" --version >/dev/null 2>&1; then missing="$missing /$b"; fi
  done
  [ -z "$missing" ] || { rm -rf "$T"; die "initrd programs cannot run inside the initrd:$missing"; }
  ok "initrd programs (modprobe, udevd, udevadm) run inside the initrd, nothing from /home"
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
  ( verify_links "$IR" ) || { rm -rf "$T"; die "NIC MAC pin check failed"; }
  rm -rf "$T"
  ok "initrd has modules for $KREL and the boot logger wired into init-top/init-bottom"
  verify_bootlog
  [ -f /lib/firmware/arm/mali/arch12.8/mali_csffw.bin ] || die "Mali CSF firmware missing"; ok "Mali CSF firmware present"
  echo "== all checks passed"
}

stage() {
  need_root; load_build
  echo "== stage $KREL"
  if [ -d "$SRC/modinst/lib/modules/$KREL" ]; then
    # prebuilt release (setup.sh --prebuilt): modules come ready-installed in modinst/
    rm -rf "/lib/modules/$KREL"
    cp -a "$SRC/modinst/lib/modules/$KREL" "/lib/modules/$KREL"
  else
    make -C "$SRC" HOSTCC="$HOSTCC" CC="$CC" -s modules_install
  fi
  depmod "$KREL"
  # Module trees of earlier sky1 releases stay until the new kernel has booted and passed
  # `setup.sh check`, which then runs `install.sh prune`.
  install -d "$BOOTDIR"
  install -m644 "$SRC/arch/arm64/boot/Image" "$BOOTDIR/vmlinuz"
  install -m644 "$SRC/arch/arm64/boot/dts/cix/$DTB_NAME" "$BOOTDIR/$DTB_NAME"
  install -m644 "$SRC/.config" "$BOOTDIR/config"
  echo "$KREL" > "$BOOTDIR/kernel.release"
  # boot logger: raw log area + private initramfs confdir
  install -d "$(dirname "$BOOTLOG_FILE")"
  "$REPO/scripts/bootlog-area.sh" setup "$BOOTLOG_FILE" "$BOOTLOG_CONF"
  if [ -f "$WORK/netconsole.conf" ]; then install -m644 "$WORK/netconsole.conf" "$NETCON_CONF"; fi
  write_links
  install -m755 "$REPO/initramfs/sky1-bootlog" /usr/sbin/sky1-bootlog
  rm -rf "$CONFDIR"; install -d "$(dirname "$CONFDIR")"
  cp -a /etc/initramfs-tools "$CONFDIR"
  install -D -m755 "$REPO/initramfs/hook-sky1-bootlog" "$CONFDIR/hooks/sky1-bootlog"
  install -D -m755 "$REPO/initramfs/init-top-sky1-bootlog" "$CONFDIR/scripts/init-top/sky1-bootlog"
  install -D -m755 "$REPO/initramfs/init-bottom-sky1-bootlog" "$CONFDIR/scripts/init-bottom/sky1-bootlog"
  # Clean environment: env.sh exports LD_LIBRARY_PATH=<toolchain>/rtlib, and copy_exec follows
  # it, which put libcrypto.so.3 under /home/.../tc/rtlib in the initrd (modprobe and udevd
  # then fail at boot). mkinitramfs must resolve libraries exactly as the booted system will.
  env -u LD_LIBRARY_PATH -u CC -u HOSTCC PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    mkinitramfs -d "$CONFDIR" -o "$BOOTDIR/initrd.img" "$KREL" 2> >(grep -v 'Kernel configuration /boot/config-' >&2)
  install -m755 "$REPO/scripts/boot-report.sh" /usr/local/sbin/sky1-boot-report
  install -m644 "$REPO/systemd/sky1-boot-report.service" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable -q sky1-boot-report.service
  sync   # modules, /boot/sky1 and the initrd must be on disk before anyone reboots
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
  local tag=$mode dbg=" ignore_loglevel printk.devkmsg=on"
  # DEFAULT=1: the everyday boot entry. Normal log level, panic reboots (so GRUB's fallback can
  # act), early console on the debug UART, sky1test=default (boot-report confirms, never reboots).
  if [ "${DEFAULT:-0}" = 1 ]; then panic=10; early=" earlycon=pl011,mmio32,0x040d0000"; tag=default; dbg=""; fi
  c="root=UUID=$uuid ro rootwait panic=$panic sky1test=$tag$dbg clk_ignore_unused efi=noruntime$early"
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
  if [ "${SERIAL:-0}" = 1 ]; then echo "$c$nc console=tty1 console=ttyAMA2,115200"
  elif [ "${DEFAULT:-0}" = 1 ]; then echo "$c$nc console=ttyAMA2,115200 console=tty1"
  else echo "$c$nc console=tty1"; fi
}

# ---- Sky1 as the default boot, with automatic fallback to Armbian ----
# GRUB sets sky1_pending=1 when it boots the default entry; sky1-boot-report clears it once
# userspace is up. If GRUB finds it still set, that boot never came up (hang, panic, power
# loss): it boots Armbian instead and sets sky1_failed=1, which keeps Armbian the default
# until "install.sh default" is run again. One-shot test boots (grub-reboot) are untouched.
DEFAULT_SNIPPET=/etc/grub.d/44_sky1_default
DEFAULT_ENTRY="Sky1 (acpi)"
write_default_snippet() {  # $1 = output file
  local uuid; uuid=$(findmnt -no UUID /); [ -n "$uuid" ] || die "no root UUID"
  cat > "$1" <<GRUB
#!/bin/sh
cat <<'MENU'
if [ "\${boot_once}" != "true" ]; then
  if [ "\${sky1_pending}" = "1" ]; then
    set sky1_failed=1
    set sky1_pending=0
    save_env sky1_failed sky1_pending
  fi
  if [ "\${sky1_failed}" != "1" ]; then
    set default="$DEFAULT_ENTRY"
  fi
fi
menuentry "$DEFAULT_ENTRY" {
    set sky1_pending=1
    save_env sky1_pending
    search --no-floppy --fs-uuid --set=root $uuid
    linux $BOOTDIR/vmlinuz $(DEFAULT=1 SERIAL=0 SCREEN=0 cmdline acpi "$uuid")
    initrd $BOOTDIR/initrd.img
}
MENU
GRUB
  chmod 755 "$1"
}

check_default_cfg() {  # $1 = grub.cfg
  local cfg=$1 first
  grub-script-check "$cfg" || die "grub-script-check failed on $cfg"
  first=$(grep -m1 -E '^[[:space:]]*(menuentry|submenu) ' "$cfg")
  grep -q 'Armbian' <<<"$first" || die "entry 0 (the fallback) is not Armbian: $first"
  [ "$(grep -c "menuentry \"$DEFAULT_ENTRY\"" "$cfg")" -eq 1 ] || die "default entry missing or duplicated"
  grep -q "set default=\"$DEFAULT_ENTRY\"" "$cfg" || die "default selection missing"
  grep -q 'set sky1_failed=1' "$cfg" || die "fallback logic missing"
  grep -A4 "menuentry \"$DEFAULT_ENTRY\"" "$cfg" | grep -q 'save_env sky1_pending' || die "entry does not set sky1_pending"
  grep -A8 "menuentry \"$DEFAULT_ENTRY\"" "$cfg" | grep -q 'sky1test=default' || die "entry lacks sky1test=default"
  grep -A8 "menuentry \"$DEFAULT_ENTRY\"" "$cfg" | grep -q 'panic=10' || die "entry would not reboot on panic"
  ok "grub.cfg: '$DEFAULT_ENTRY' is the default, Armbian is entry 0 and the fallback, syntax OK"
}

make_default() {
  need_root; load_build; verify
  systemctl is-enabled -q sky1-boot-report.service || die "sky1-boot-report.service not enabled (it confirms boots)"
  grep -q 'sky1_pending=0' /usr/local/sbin/sky1-boot-report || die "installed boot report cannot confirm boots; run stage"
  local tmpcfg; tmpcfg=$(mktemp)
  write_default_snippet "$DEFAULT_SNIPPET"
  grub-mkconfig -o "$tmpcfg" 2>/dev/null || { rm -f "$DEFAULT_SNIPPET" "$tmpcfg"; die "grub-mkconfig failed"; }
  ( check_default_cfg "$tmpcfg" ) || { rm -f "$DEFAULT_SNIPPET" "$tmpcfg"; die "generated grub.cfg rejected; nothing installed"; }
  install -m644 "$tmpcfg" /boot/grub/grub.cfg; rm -f "$tmpcfg"
  check_default_cfg /boot/grub/grub.cfg
  grub-editenv - unset sky1_failed sky1_pending
  ! grub-editenv list | grep -qE '^sky1_(failed|pending)=' || die "fallback state not cleared"
  ok "sky1 is the default boot; Armbian takes over automatically if a sky1 boot never comes up"
}

unmake_default() {
  need_root
  rm -f "$DEFAULT_SNIPPET"
  update-grub 2>/dev/null
  grub-script-check /boot/grub/grub.cfg || die "grub-script-check failed"
  ! grep -q "$DEFAULT_ENTRY" /boot/grub/grub.cfg || die "default entry still in grub.cfg"
  grub-editenv - unset sky1_failed sky1_pending
  ok "Armbian is the default again"
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
  ! grep -q "$KV-sky1" "$1" || die "sky1 kernel still referenced in $1"
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

prune() {  # remove module trees of sky1 releases other than the one running now
  need_root
  local cur old n=0; cur=$(uname -r)
  case "$cur" in *-sky1) ;; *) die "running $cur: prune only from a sky1 kernel that has passed setup.sh check";; esac
  [ "$(cat "$BOOTDIR/kernel.release" 2>/dev/null)" = "$cur" ] || die "$BOOTDIR holds a different kernel than the running $cur"
  for old in "$MODROOT"/lib/modules/*-sky1 "$MODROOT"/lib/modules/*-sky1+; do
    [ -d "$old" ] && [ "${old##*/}" != "$cur" ] || continue
    rm -rf "$old"; ok "removed old modules ${old##*/}"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || ok "no old sky1 modules"
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
  default) make_default ;;
  undefault) unmake_default ;;
  prune) prune ;;
  bootlog)
    echo "== GRUB markers: $(grub-editenv list | grep -E '^sky1_(picked|stage|pending|failed)=' | tr '\n' ' ' || true)"
    grub-editenv list | grep -q '^sky1_picked=' || echo "   (none: GRUB has not booted the test entry since arming)"
    "$REPO/scripts/bootlog-area.sh" read "$BOOTLOG_CONF" ;;
  *) echo "usage: $0 stage|verify|arm dt|arm acpi|disarm|default|undefault|prune|bootlog"; exit 2 ;;
esac
