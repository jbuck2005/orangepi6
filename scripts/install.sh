#!/bin/bash
# Install the Sky1 test kernel beside Armbian, without touching Armbian's files or GRUB default.
#
#   sudo WORK=/home/<user>/sky1-build scripts/install.sh stage   # modules + /boot/sky1/* + initramfs, then verify
#   sudo WORK=...                     scripts/install.sh verify  # re-run every check (no changes)
#   sudo WORK=...                     scripts/install.sh arm     # add GRUB entry as the LAST entry and arm ONE boot
#   sudo                              scripts/install.sh disarm  # remove the entry, clear next_entry
#
# Kernel, initrd and DTB live in /boot/sky1/, so Armbian's 10_linux never generates entries for them.
# The GRUB snippet is 45_sky1 (after 10_linux), so entry 0, the default, stays Armbian.
set -euo pipefail

die()  { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
DTB_NAME=sky1-orangepi-6.dtb
BOOTDIR=${BOOTDIR:-/boot/sky1}
MODROOT=${MODROOT:-}   # test hook: alternate root for /lib/modules
GRUB_SNIPPET=/etc/grub.d/45_sky1
ENTRY="Sky1 GPU test"

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

verify() {
  echo "== verify $KREL"
  local M=$MODROOT/lib/modules/$KREL
  [ -d "$M" ] || die "$M missing"; ok "$M exists"
  for f in modules.dep modules.builtin modules.order; do [ -s "$M/$f" ] || die "$M/$f missing/empty"; done; ok "modules.dep/builtin/order present"
  for m in panthor r8125; do modinfo ${MODROOT:+-b "$MODROOT"} -k "$KREL" "$m" >/dev/null 2>&1 || die "module $m not found for $KREL"; done; ok "panthor and r8125 modules resolvable"
  local vm; vm=$(modinfo ${MODROOT:+-b "$MODROOT"} -k "$KREL" -F vermagic panthor | awk '{print $1}')
  [ "$vm" = "$KREL" ] || die "panthor vermagic '$vm' != '$KREL'"; ok "vermagic matches"
  for b in nvme ext4 pcie-sky1 phy-cix-pcie ramoops; do
    grep -qE "/$b\.ko|/${b//-/_}\.ko" "$M/modules.builtin" || die "$b not built in (needed before root mount)"
  done; ok "nvme, ext4, Sky1 PCIe host+PHY, ramoops built in"
  cmp -s "$BOOTDIR/vmlinuz" "$SRC/arch/arm64/boot/Image" || die "$BOOTDIR/vmlinuz missing or stale"; ok "kernel in $BOOTDIR matches build"
  cmp -s "$BOOTDIR/$DTB_NAME" "$SRC/arch/arm64/boot/dts/cix/$DTB_NAME" || die "DTB missing or stale"
  local D; D=$(dtc -q -I dtb -O dts "$BOOTDIR/$DTB_NAME") || die "dtc cannot read DTB"
  grep -q 'model = "Orange Pi 6";' <<<"$D" || die "DTB model is not Orange Pi 6"; for n in 0a070000 0a0d0000; do grep -A40 "pcie@$n {" <<<"$D" | grep -m1 'status =' | grep -q disabled || die "pcie@$n not disabled in DTB"; done
  ok "DTB is the non-Plus Orange Pi 6 (unused PCIe ports disabled)"
  [ -s "$BOOTDIR/initrd.img" ] || die "initrd missing"
  local L; L=$(lsinitramfs "$BOOTDIR/initrd.img")
  grep -q "lib/modules/$KREL/modules.dep" <<<"$L" || die "initrd has no modules for $KREL"
  grep -q "lib/modules/$KREL/kernel/drivers/net/ethernet/realtek/r8125/r8125.ko" <<<"$L" || echo "  note: r8125 not in initrd (loaded from root fs later; fine)"
  ok "initrd contains lib/modules/$KREL"
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
  mkinitramfs -o "$BOOTDIR/initrd.img" "$KREL"
  install -m755 "$REPO/scripts/boot-report.sh" /usr/local/sbin/sky1-boot-report
  install -m644 "$REPO/systemd/sky1-boot-report.service" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable -q sky1-boot-report.service
  verify
}

write_snippet() {  # $1 = output file
  local uuid; uuid=$(findmnt -no UUID /)
  [ -n "$uuid" ] || die "no root UUID"
  cat > "$1" <<GRUB
#!/bin/sh
cat <<'MENU'
menuentry "$ENTRY" {
    search --no-floppy --fs-uuid --set=root $uuid
    linux $BOOTDIR/vmlinuz root=UUID=$uuid ro acpi=off clk_ignore_unused efi=noruntime panic=10 rootwait console=tty1
    initrd $BOOTDIR/initrd.img
    devicetree $BOOTDIR/$DTB_NAME
}
MENU
GRUB
  chmod 755 "$1"
}

check_grub_cfg() {  # $1 = grub.cfg to check
  local cfg=$1 first
  grub-script-check "$cfg" || die "grub-script-check failed on $cfg"
  first=$(grep -m1 -E '^[[:space:]]*(menuentry|submenu) ' "$cfg")
  grep -q 'Armbian' <<<"$first" || die "first entry is not Armbian: $first"
  grep -q "$ENTRY" <<<"$first" && die "test entry is the first (default) entry"
  [ "$(grep -c "menuentry \"$ENTRY\"" "$cfg")" -eq 1 ] || die "test entry missing or duplicated"
  grep -qE '^GRUB_DEFAULT=0$' /etc/default/grub || die "GRUB_DEFAULT is not 0"
  grep -q 'next_entry' "$cfg" || die "grub.cfg lacks next_entry (no one-shot support)"
  ! grep -E "^menuentry 'Armbian.*sky1" "$cfg" >/dev/null || die "10_linux generated Armbian entries for the sky1 kernel"
  ok "grub.cfg: Armbian is entry 0, one test entry, syntax OK"
}

check_disarmed() {  # $1 = grub.cfg
  local first
  grub-script-check "$1" || die "grub-script-check failed on $1"
  ! grep -q "$ENTRY" "$1" || die "test entry still in $1"
  ! grep -q '6.18.14-sky1' "$1" || die "sky1 kernel still referenced in $1"
  first=$(grep -m1 -E '^[[:space:]]*(menuentry|submenu) ' "$1")
  grep -q "Armbian GNU/Linux, with Linux $(uname -r)'" <<<"$first" || die "first entry is not the running Armbian kernel: $first"
  ok "grub.cfg: only Armbian entries, running kernel is entry 0"
}

arm() {
  need_root; load_build; verify
  local tmpcfg; tmpcfg=$(mktemp)
  write_snippet "$GRUB_SNIPPET"
  grub-mkconfig -o "$tmpcfg" 2>/dev/null
  check_grub_cfg "$tmpcfg" || { rm -f "$GRUB_SNIPPET" "$tmpcfg"; exit 1; }
  install -m644 "$tmpcfg" /boot/grub/grub.cfg; rm -f "$tmpcfg"
  check_grub_cfg /boot/grub/grub.cfg
  grub-reboot "$ENTRY"
  local E; E=$(grub-editenv list)
  grep -qx "next_entry=$ENTRY" <<<"$E" || die "next_entry not set"
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
  arm) arm ;;
  disarm) disarm ;;
  *) echo "usage: $0 stage|verify|arm|disarm"; exit 2 ;;
esac
