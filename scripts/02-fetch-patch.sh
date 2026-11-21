#!/bin/bash
# Fetch kernel.org $KV (kernel.conf), verify Greg K-H's signature, apply Sky1-Linux LTS patches,
# add the Orange Pi 6 (non-Plus) device tree, and configure.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/sky1-build}
# shellcheck disable=SC1091
. "$REPO/kernel.conf"; . "$REPO/scripts/lib-patch.sh"; KM=${KV%%.*}
cd "$WORK"
[ -d linux-sky1 ] || git clone https://github.com/Sky1-Linux/linux-sky1.git
git -C linux-sky1 checkout -q $SKY1_COMMIT
[ -f linux-$KV.tar.xz ] || curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v$KM.x/linux-$KV.tar.xz
curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v$KM.x/linux-$KV.tar.sign
export GNUPGHOME=$WORK/gnupg; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg -q --auto-key-locate wkd --locate-keys gregkh@kernel.org >/dev/null
SIG=$(xz -dc linux-$KV.tar.xz | gpg --verify linux-$KV.tar.sign - 2>&1) || { echo "$SIG"; echo "BAD SIGNATURE"; exit 1; }
grep -q 'Good signature from "Greg Kroah-Hartman' <<<"$SIG" || { echo "$SIG"; echo "unexpected signer"; exit 1; }
rm -rf linux-$KV && tar xf linux-$KV.tar.xz && cd linux-$KV
apply_sky1_patches ../linux-sky1 "$WORK/patch.log"
cp "$REPO/dts/sky1-orangepi-6.dts" arch/arm64/boot/dts/cix/
if ! grep -q sky1-orangepi-6.dtb arch/arm64/boot/dts/cix/Makefile; then
  # shellcheck disable=SC2016  # literal make syntax
  echo 'dtb-$(CONFIG_ARCH_CIX) += sky1-orangepi-6.dtb' >> arch/arm64/boot/dts/cix/Makefile
fi
# shellcheck disable=SC1091
. "$WORK/env.sh"
cp "../linux-sky1/config/$SKY1_CONFIG" .config
./scripts/config --set-str LOCALVERSION "-sky1" --disable DEBUG_INFO_BTF --disable DEBUG_INFO \
  --enable DEBUG_INFO_NONE --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --disable DEBUG_INFO_DWARF5 \
  --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG \
  --enable NETCONSOLE --enable NETCONSOLE_DYNAMIC --enable NETPOLL --enable CONFIGFS_FS
# NIC driver for the two RTL8125 ports: Realtek's r8125 (default) or mainline r8169 (NIC_DRIVER=r8169,
# experimental; it needs rtl_nic/rtl8125*.fw from linux-firmware in the root filesystem).
case ${NIC_DRIVER:-r8125} in
  r8125) ./scripts/config --enable R8125 --disable R8169 ;;
  r8169) ./scripts/config --disable R8125 --enable R8169 --enable REALTEK_PHY ;;
  *) echo "NIC_DRIVER must be r8125 or r8169"; exit 1 ;;
esac
make HOSTCC="$HOSTCC" CC="$CC" olddefconfig >/dev/null
KREL=$(make -s kernelrelease)
[ "$KREL" = "$KV-sky1" ] || { echo "unexpected kernel release $KREL (is $WORK inside a git repo?)"; exit 1; }
echo "Source ready in $WORK/linux-$KV ($KREL)"
