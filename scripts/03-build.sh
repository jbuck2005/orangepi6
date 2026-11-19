#!/bin/bash
# -j6 on purpose: a full 12-core build hard-crashed the board once.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$REPO/kernel.conf"
WORK=${WORK:-$HOME/sky1-build}; cd "$WORK/linux-$KV"
# shellcheck disable=SC1091
. "$WORK/env.sh"
make HOSTCC="$HOSTCC" CC="$CC" -j"${JOBS:-6}" Image modules dtbs 2>&1 | tee "$WORK/build.log"
# a reset soon after a build once left every .ko zero-length (ext4 delayed allocation): flush now
sync
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/cix/sky1-orangepi-6.dtb
