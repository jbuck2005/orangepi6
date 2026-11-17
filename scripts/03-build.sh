#!/bin/bash
# -j6 on purpose: a full 12-core build hard-crashed the board once.
set -euo pipefail
WORK=${WORK:-$HOME/sky1-build}; cd "$WORK/linux-6.18.14"
# shellcheck disable=SC1091
. "$WORK/env.sh"
make HOSTCC="$HOSTCC" CC="$CC" -j"${JOBS:-6}" Image modules dtbs 2>&1 | tee "$WORK/build.log"
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/cix/sky1-orangepi-6.dtb
