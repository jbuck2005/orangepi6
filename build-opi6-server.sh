#!/usr/bin/env bash
# Build an Orange Pi 6 Ubuntu 24.04 (noble) SERVER image with the CIX vendor
# kernel (6.6-cix, "next" branch) plus the GPU, NPU and VPU drivers, on an x86_64 Docker host.
# Run on Zeus inside tmux:   tmux new -s opi6 'bash ~/build-opi6-server.sh 2>&1 | tee ~/opi6-build.log'
# The work dir defaults to opi6-build/ next to this script, whatever directory you run it from.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$SCRIPT_DIR/opi6-build}"
mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d orangepi-build ]]; then
  git clone --depth 1 -b next https://github.com/orangepi-xunlong/orangepi-build.git
fi
cd orangepi-build

# Patch: the noble tweaks edit /etc/gdm3 (GNOME login) unconditionally.
# Guard those edits so a server build doesn't trip on the missing file.
CIX=external/config/sources/families/cix.conf
if ! grep -q 'OPI6_SERVER_PATCH' "$CIX"; then
  perl -pi -e 's{^(\s*)(sed -i .*\$\{SDCARD\}/etc/gdm3/(\S+?))\s*$}{$1\[\[ ! -f \$\{SDCARD\}/etc/gdm3/$3 \]\] || $2 # OPI6_SERVER_PATCH\n}' "$CIX"
  echo "Patched gdm3 edits in $CIX:"
  grep -n 'OPI6_SERVER_PATCH' "$CIX"
fi

# Build inside the project's Ubuntu 22.04 Docker container (the host is 26.04).
# FORCE_USE_RAMDISK=no: Zeus has less than 6 GB of RAM free, so build on disk, not tmpfs.
./build.sh docker \
  BOARD=orangepi6 \
  BRANCH=next \
  RELEASE=noble \
  BUILD_OPT=image \
  BUILD_DESKTOP=no \
  BUILD_MINIMAL=no \
  KERNEL_CONFIGURE=no \
  FORCE_USE_RAMDISK=no \
  COMPRESS_OUTPUTIMAGE=xz

echo
echo "=== Done. Images:"
ls -lh output/images/*/ 2>/dev/null || ls -lhR output/images
echo
echo "=== CIX packages built (should include npu-driver, gpu-driver, vpu-driver and *-umd):"
ls output/debs/cix_debs-next/ 2>/dev/null || find output -name 'cix-*.deb' | head -40
