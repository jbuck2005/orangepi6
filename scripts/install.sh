#!/bin/bash
# Install 6.18.14-sky1 next to Armbian and arm a ONE-SHOT boot into it.
# Armbian stays the GRUB default, so any reset after the test boot returns to it.
# Run: sudo WORK=/home/<user>/sky1-build bash scripts/install.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:?set WORK to the build directory}
V=6.18.14-sky1; SRC=$WORK/linux-6.18.14
ROOT_UUID=$(findmnt -no UUID /)
DTB=sky1-orangepi-6.dtb
cd "$SRC"; test -f arch/arm64/boot/Image; test -f arch/arm64/boot/dts/cix/$DTB
. "$WORK/env.sh"

make HOSTCC="$HOSTCC" CC="$CC" modules_install
cp arch/arm64/boot/Image /boot/vmlinuz-$V
cp arch/arm64/boot/dts/cix/$DTB /boot/$DTB
cp .config /boot/config-$V
update-initramfs -c -k $V

cat > /etc/grub.d/06_sky1 <<GRUB
#!/bin/sh
cat <<'MENU'
menuentry "Sky1 GPU test" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz-$V root=UUID=$ROOT_UUID ro acpi=off clk_ignore_unused efi=noruntime panic=10 rootwait console=tty1
    initrd /boot/initrd.img-$V
    devicetree /boot/$DTB
}
MENU
GRUB
chmod +x /etc/grub.d/06_sky1
grep -q '^GRUB_DEFAULT=0' /etc/default/grub || echo "WARNING: GRUB_DEFAULT is not 0"
update-grub

install -m755 "$REPO/scripts/boot-report.sh" /usr/local/sbin/sky1-boot-report
install -m644 "$REPO/systemd/sky1-boot-report.service" /etc/systemd/system/
systemctl daemon-reload; systemctl enable sky1-boot-report.service

grep -q 'menuentry "Sky1 GPU test"' /boot/grub/grub.cfg
grep -q next_entry /boot/grub/grub.cfg || { echo "grub.cfg lacks next_entry; one-shot boot unsupported"; exit 1; }
grub-reboot "Sky1 GPU test"; grub-editenv list
echo "Armed. 'sudo reboot' to test. A failed boot returns to Armbian on the next reset."
