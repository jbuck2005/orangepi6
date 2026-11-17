#!/bin/bash
# Fetch kernel.org 6.18.14, verify Greg K-H's signature, apply Sky1-Linux LTS patches,
# add the Orange Pi 6 (non-Plus) device tree, and configure.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/sky1-build}; KV=6.18.14; SKY1_COMMIT=57e018a
cd "$WORK"
[ -d linux-sky1 ] || git clone https://github.com/Sky1-Linux/linux-sky1.git
git -C linux-sky1 checkout -q $SKY1_COMMIT
[ -f linux-$KV.tar.xz ] || curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KV.tar.xz
curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KV.tar.sign
export GNUPGHOME=$WORK/gnupg; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg -q --auto-key-locate wkd --locate-keys gregkh@kernel.org >/dev/null
SIG=$(xz -dc linux-$KV.tar.xz | gpg --verify linux-$KV.tar.sign - 2>&1) || { echo "$SIG"; echo "BAD SIGNATURE"; exit 1; }
grep -q 'Good signature from "Greg Kroah-Hartman' <<<"$SIG" || { echo "$SIG"; echo "unexpected signer"; exit 1; }
rm -rf linux-$KV && tar xf linux-$KV.tar.xz && cd linux-$KV
for p in ../linux-sky1/patches/*.patch; do git apply --whitespace=nowarn "$p" || { echo "patch failed: $p"; exit 1; }; done
cp "$REPO/dts/sky1-orangepi-6.dts" arch/arm64/boot/dts/cix/
if ! grep -q sky1-orangepi-6.dtb arch/arm64/boot/dts/cix/Makefile; then
  # shellcheck disable=SC2016  # literal make syntax
  echo 'dtb-$(CONFIG_ARCH_CIX) += sky1-orangepi-6.dtb' >> arch/arm64/boot/dts/cix/Makefile
fi
# shellcheck disable=SC1091
. "$WORK/env.sh"
cp ../linux-sky1/config/config.sky1 .config
./scripts/config --set-str LOCALVERSION "-sky1" --disable DEBUG_INFO_BTF --disable DEBUG_INFO \
  --enable DEBUG_INFO_NONE --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --disable DEBUG_INFO_DWARF5 \
  --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG
make HOSTCC="$HOSTCC" CC="$CC" olddefconfig >/dev/null
KREL=$(make -s kernelrelease)
[ "$KREL" = "$KV-sky1" ] || { echo "unexpected kernel release $KREL (is $WORK inside a git repo?)"; exit 1; }
echo "Source ready in $WORK/linux-$KV ($KREL)"
