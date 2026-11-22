#!/bin/bash
# NPU bring-up test on a running sky1 kernel, without a reboot or a kernel rebuild:
#   1. patch the CIX 6.2.0 NPU driver into the existing build tree ($WORK/linux-$KV) and build only that module
#   2. swap the loaded armchina_npu module for it (the old one is kept and reloaded if the new one fails)
#   3. build Arm China's open libaipudrv 4.1.0 (scripts/npu-umd.sh) and tools/npu-run.cpp
#   4. npu-run info, then fetch two models from CIX's model hub and benchmark them
# Run from Armbian's sky1 boot as the normal user (it uses sudo for the module and the library install).
# Usage: bench/npu-bringup.sh [driver|umd|models]   (no argument: all steps)
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/sky1-build}
# shellcheck disable=SC1091
. "$REPO/kernel.conf"
KT=$WORK/linux-$KV
NPU=$WORK/npu
HUB=${NPU_HUB:-https://modelscope.cn/models/cix/ai_model_hub_26_Q2/resolve/master}
HUB_API=${NPU_HUB_API:-https://modelscope.cn/api/v1/models/cix/ai_model_hub_26_Q2/repo/files?Recursive=true}
mkdir -p "$NPU"
step() { echo; echo "=== $*"; }
want() { [ -z "${1:-}" ] || [ "$1" = "$2" ]; }

if want "${1:-}" driver; then
  step "kernel"
  uname -r
  [ "$(uname -r)" = "$KV-sky1" ] || { echo "running kernel is not $KV-sky1 (KERNEL_TRACK=$KERNEL_TRACK)"; exit 1; }
  [ -f "$KT/.config" ] || { echo "no build tree at $KT"; exit 1; }
  grep '^CONFIG_ARMCHINA_NPU=' "$KT/.config"
  grep '^CONFIG_ARMCHINA_NPU=m' -q "$KT/.config" || { echo "the NPU driver is built in; this test needs it as a module"; exit 1; }
  lsmod | grep -E '^armchina_npu' || echo "armchina_npu is not loaded"

  step "patch the driver into $KT"
  case $KERNEL_TRACK in
    7) P=$REPO/patches/7.3/0056-misc-armchina-npu-update-to-CIX-driver-6.2.0.patch ;;
    *) P=$REPO/patches/6.18.64/post/0012-misc-armchina-npu-update-to-CIX-driver-6.2.0.patch ;;
  esac
  # $NPU/applied.patch is the patch now in the tree; a newer one replaces it (from the saved original driver)
  if [ -f "$NPU/applied.patch" ] && cmp -s "$P" "$NPU/applied.patch"; then
    echo "already patched with this version"
  else
    if grep -q 'KMD_VERSION=\\"6.2.0\\"' "$KT/drivers/misc/armchina-npu/Makefile"; then
      [ -d "$NPU/armchina-npu.orig" ] || { echo "tree has another 6.2.0 patch and no saved original"; exit 1; }
      rm -rf "$KT/drivers/misc/armchina-npu" && cp -a "$NPU/armchina-npu.orig" "$KT/drivers/misc/armchina-npu"
      echo "restored the original driver"
    else
      rm -rf "$NPU/armchina-npu.orig" && cp -a "$KT/drivers/misc/armchina-npu" "$NPU/armchina-npu.orig"
    fi
    patch -p1 -d "$KT" -s --dry-run < "$P" && patch -p1 -d "$KT" -s < "$P" || { echo "patch failed"; exit 1; }
    cp "$P" "$NPU/applied.patch"
    echo "patched with ${P##*/} ($(sha256sum < "$P" | cut -c1-12))"
  fi

  step "build the module"
  # shellcheck disable=SC1091
  ( . "$WORK/env.sh"; make -C "$KT" HOSTCC="$HOSTCC" CC="$CC" -j"${JOBS:-6}" M=drivers/misc/armchina-npu modules 2>&1 | tail -3 )
  KO=$KT/drivers/misc/armchina-npu/armchina_npu.ko
  [ -f "$KO" ] || { echo "module not built"; exit 1; }
  modinfo "$KO" | grep -E '^(vermagic|alias)' | head -3
  cp "$KO" "$NPU/armchina_npu-6.2.0.ko"
  sync

  step "swap the module"
  sudo dmesg -C 2>/dev/null || true
  sudo modprobe -r armchina_npu 2>&1 || true
  if sudo insmod "$NPU/armchina_npu-6.2.0.ko"; then
    sleep 3
  else
    echo "insmod failed; reloading the old module"; sudo modprobe armchina_npu; exit 1
  fi
  sudo dmesg | grep -i -E 'aipu|npu|armchina' | tail -30
  ls -l /dev/aipu
fi

if want "${1:-}" umd; then
  step "build libaipudrv 4.1.0"
  WORK=$WORK "$REPO/scripts/npu-umd.sh" install 2>&1 | grep -E 'warning|error|installed|libaipudrv' | tail -8
  step "build npu-run"
  g++ -std=c++14 -O2 -Wall -I/usr/local/include/aipu -o "$NPU/npu-run" "$REPO/tools/npu-run.cpp" -laipudrv || exit 1
  step "npu-run info"
  "$NPU/npu-run" info
fi

if want "${1:-}" models; then
  step "model hub: compiled graphs"
  curl -fsSL "$HUB_API" -o "$NPU/hub-files.json" || { echo "cannot list the model hub"; exit 1; }
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for f in d["Data"]["Files"]:
    if f["Path"].endswith(".cix"): print(f["Path"], f.get("Size",0))' "$NPU/hub-files.json" | tee "$NPU/hub-cix.txt" | wc -l
  grep -i yolo "$NPU/hub-cix.txt" | head -20
  MNV2=
  for pat in 'mobilenet[_-]*v2' 'yolo[_-]*v8[_-]*n|yolov8' ; do
    p=$(grep -i -E "$pat" "$NPU/hub-cix.txt" | head -1 | cut -d' ' -f1)
    [ -n "$p" ] || { echo "no model matching $pat"; continue; }
    f=$NPU/models/${p//\//_}
    mkdir -p "$NPU/models"
    [ -s "$f" ] || curl -fsSL -o "$f" "$HUB/$p" || { echo "download failed: $p"; continue; }
    case $pat in mobilenet*) MNV2=$f ;; esac
    step "bench $p"
    "$NPU/npu-run" bench "$f" 200
  done

  step "classify with MobileNetV2"
  python3 -c 'import PIL, numpy' 2>/dev/null || sudo apt-get install -y -qq python3-pil python3-numpy >/dev/null
  mdir=$(grep -i -E 'mobilenet[_-]*v2' "$NPU/hub-cix.txt" | head -1 | cut -d' ' -f1); mdir=${mdir%/*}
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for f in d["Data"]["Files"]:
    if f["Path"].startswith(sys.argv[2] + "/"): print(f["Path"], f.get("Size",0))' "$NPU/hub-files.json" "$mdir" \
    | grep -v -i -E '\.(onnx|cix)( |$)' | head -40
  img=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for f in d["Data"]["Files"]:
    p=f["Path"]
    if p.startswith(sys.argv[2] + "/") and p.lower().endswith((".jpg",".jpeg",".png")):
        print(p)' "$NPU/hub-files.json" "$mdir" | head -3)
  lab=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for f in d["Data"]["Files"]:
    p=f["Path"]
    if "imagenet" in p.lower() and p.endswith(".txt"): print(p)' "$NPU/hub-files.json" | head -1)
  [ -z "$lab" ] || curl -fsSL -o "$NPU/labels.txt" "$HUB/$lab" || true
  for i in $img; do
    f=$NPU/images/${i##*/}; mkdir -p "$NPU/images"
    curl -fsSL -o "$f" "$HUB/$i" || continue
    python3 "$REPO/tools/npu-prep.py" "$f" "$f.f32" || continue
    echo "--- ${i##*/}"
    "$NPU/npu-run" classify "${MNV2:?no MobileNetV2 graph}" "$f.f32" "$NPU/labels.txt" 2>&1 | tail -6
  done
  sudo dmesg | grep -i -E 'aipu|armchina' | tail -10
fi
