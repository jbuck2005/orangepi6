#!/bin/bash
# Build Arm China's open NPU user-mode library (libaipudrv, "standard API", Apache-2.0) for the Sky1 NPU
# (Zhouyi X2, architecture v3) and its sample program, natively on the board.
#
# Release 4.1.0 is the one whose ioctl ABI matches the kernel driver (CIX 6.2.0, patches 0012/0056);
# Arm China 4.2.0 and later changed struct aipu_buf_desc and aipu_job_desc.
#
# Usage: scripts/npu-umd.sh [install]
#   builds into $WORK/npu-umd (default $HOME/sky1-build/npu-umd); "install" (needs sudo) copies the library to
#   /usr/local/lib and the headers to /usr/local/include/aipu, then runs ldconfig.
set -euo pipefail
WORK=${WORK:-$HOME/sky1-build}
UMD_COMMIT=f35bac0513a7757f8ba6d314d93063214da89c28   # Compass_NPU_Driver "align with 4.1.0 release"
UMD_URL=https://github.com/Arm-China/Compass_NPU_Driver.git
D=$WORK/npu-umd
mkdir -p "$D"
if [ ! -d "$D/src/.git" ]; then
  git init -q "$D/src"
  git -C "$D/src" remote add origin "$UMD_URL"
fi
if [ "$(git -C "$D/src" rev-parse -q --verify HEAD 2>/dev/null)" != "$UMD_COMMIT" ]; then
  git -C "$D/src" fetch -q --depth 1 origin "$UMD_COMMIT"
  git -C "$D/src" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$D/src" rev-parse HEAD)" = "$UMD_COMMIT" ] || { echo "unexpected UMD commit"; exit 1; }

export COMPASS_DRV_BTENVAR_UMD_BUILD_DIR=$D/build/obj
export BUILD_AIPU_DRV_ODIR=$D/build/lib
export COMPASS_DRV_BTENVAR_UMD_V_MAJOR=6
export COMPASS_DRV_BTENVAR_UMD_V_MINOR=0.0
export COMPASS_DRV_BTENVAR_UMD_SO_NAME=libaipudrv.so
export COMPASS_DRV_BTENVAR_UMD_SO_NAME_MAJOR=libaipudrv.so.6
export COMPASS_DRV_BTENVAR_UMD_SO_NAME_FULL=libaipudrv.so.6.0.0
export COMPASS_DRV_BTENVAR_UMD_A_NAME=libaipudrv.a
export COMPASS_DRV_BTENVAR_UMD_A_NAME_FULL=libaipudrv.a.6.0.0
mkdir -p "$COMPASS_DRV_BTENVAR_UMD_BUILD_DIR" "$BUILD_AIPU_DRV_ODIR"
# The Makefile builds with -Werror; compilers newer than Arm China's add warnings (e.g. -Woverloaded-virtual),
# so keep them as warnings.
git -C "$D/src" checkout -q -- Linux/driver/umd/Makefile
sed -i 's/ -Werror / /' "$D/src/Linux/driver/umd/Makefile"
make -C "$D/src/Linux/driver/umd" -j"${JOBS:-6}" standard_api BUILD_AIPU_VERSION=aipu_v3 \
  BUILD_TARGET_PLATFORM=hw CXX="${CXX:-g++}"
ls -l "$BUILD_AIPU_DRV_ODIR"

if [ "${1:-}" = install ]; then
  sudo install -d /usr/local/include/aipu/kmd
  sudo install -m 644 "$BUILD_AIPU_DRV_ODIR/libaipudrv.so.6.0.0" /usr/local/lib/
  sudo ln -sf libaipudrv.so.6.0.0 /usr/local/lib/libaipudrv.so.6
  sudo ln -sf libaipudrv.so.6 /usr/local/lib/libaipudrv.so
  sudo install -m 644 "$D/src/Linux/driver/umd/include/standard_api.h" /usr/local/include/aipu/
  sudo install -m 644 "$D/src/Linux/driver/kmd/armchina-npu/include/armchina_aipu.h" \
    "$D/src/Linux/driver/umd/include/kmd/tcb.h" /usr/local/include/aipu/kmd/
  sudo ldconfig
  echo "installed libaipudrv 4.1.0 to /usr/local/lib, headers to /usr/local/include/aipu"
fi
