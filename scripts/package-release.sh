#!/bin/bash
# Package a finished build (setup.sh source+build) as release assets in $WORK/release/:
#   sky1-kernel-<KREL>-<tag>-arm64.tar.xz   ready-to-run: Image, non-Plus DTB, .config, modules
#   linux-<KREL>-<tag>-source.tar.xz        the exact patched source (kernel.org + Sky1 patches + our DTS + .config)
#   SHA256SUMS
# Usage: WORK=... scripts/package-release.sh <tag>      e.g. v2026.11.19
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/sky1-build}; KV=6.18.14
TAG=${1:?release tag}
SRC=$WORK/linux-$KV
KREL=$(cat "$SRC/include/config/kernel.release")
[ "$KREL" = "$KV-sky1" ] || { echo "unexpected release $KREL"; exit 1; }
[ "$SRC/arch/arm64/boot/Image" -nt "$SRC/.config" ] || { echo "Image older than .config; rebuild"; exit 1; }
OUT=$WORK/release; rm -rf "$OUT"; mkdir -p "$OUT"
# shellcheck disable=SC1091
. "$WORK/env.sh"

echo "== modules"
STAGE=$OUT/stage/linux-$KV
mkdir -p "$STAGE/include/config" "$STAGE/arch/arm64/boot/dts/cix"
make -C "$SRC" HOSTCC="$HOSTCC" CC="$CC" -s INSTALL_MOD_PATH="$STAGE/modinst" modules_install
rm -f "$STAGE/modinst/lib/modules/$KREL/build" "$STAGE/modinst/lib/modules/$KREL/source"
cp -p "$SRC/.config" "$STAGE/.config"
cp -p "$SRC/include/config/kernel.release" "$STAGE/include/config/"
cp -p "$SRC/arch/arm64/boot/dts/cix/sky1-orangepi-6.dtb" "$STAGE/arch/arm64/boot/dts/cix/"
cp -p "$SRC/arch/arm64/boot/Image" "$STAGE/arch/arm64/boot/Image"   # last, so it stays newer than .config
cat > "$STAGE/BUILDINFO" <<EOF
kernel: $KREL (kernel.org $KV, signature verified at fetch time)
patches: Sky1-Linux/linux-sky1 $(git -C "$WORK/linux-sky1" rev-parse --short HEAD) (patches/, config/config.sky1)
dts/scripts: jbuck2005/orangepi6 $(git -C "$REPO" rev-parse --short HEAD)
compiler: $(${CC%% *} --version | head -1)
built: $(date -Is) on $(uname -r)
EOF
tar -C "$OUT/stage" -cJf "$OUT/sky1-kernel-$KREL-$TAG-arm64.tar.xz" "linux-$KV"
rm -rf "$OUT/stage"

echo "== patched source"
P=$OUT/src; mkdir -p "$P"
tar -C "$P" -xf "$WORK/linux-$KV.tar.xz"
( cd "$P/linux-$KV"
  for p in "$WORK"/linux-sky1/patches/*.patch; do git apply --whitespace=nowarn "$p"; done
  cp "$REPO/dts/sky1-orangepi-6.dts" arch/arm64/boot/dts/cix/
  grep -q sky1-orangepi-6.dtb arch/arm64/boot/dts/cix/Makefile || echo 'dtb-$(CONFIG_ARCH_CIX) += sky1-orangepi-6.dtb' >> arch/arm64/boot/dts/cix/Makefile
  cp "$SRC/.config" .config )
# the shipped source must be the one that was built: same DTS, same config, same patched C files
cmp -s "$P/linux-$KV/arch/arm64/boot/dts/cix/sky1-orangepi-6.dts" "$SRC/arch/arm64/boot/dts/cix/sky1-orangepi-6.dts" || { echo "DTS differs"; exit 1; }
cmp -s "$P/linux-$KV/.config" "$SRC/.config" || { echo ".config differs"; exit 1; }
for f in drivers/gpu/drm/panthor/panthor_device.c drivers/net/ethernet/realtek/r8125/r8125_n.c arch/arm64/boot/dts/cix/Makefile; do
  cmp -s "$P/linux-$KV/$f" "$SRC/$f" || { echo "source differs from the built tree: $f"; exit 1; }
done
tar -C "$P" -cJf "$OUT/linux-$KREL-$TAG-source.tar.xz" "linux-$KV"
rm -rf "$P"

( cd "$OUT" && sha256sum ./*.tar.xz | sed 's| \./| |' > SHA256SUMS && cat SHA256SUMS )
ls -la "$OUT"
