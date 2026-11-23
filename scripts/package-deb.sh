#!/bin/bash
# Build .deb packages, as an alternative to `setup.sh` (build from source) and `setup.sh --prebuilt` (tarball):
#
#   orangepi6-kernel-6.18_<KV>-<rel>_arm64.deb   kernel 6.18.64-sky1: Image, non-Plus DTB, modules, install scripts
#   orangepi6-kernel-7_<KV>-<rel>_arm64.deb      kernel 7.3.5-sky1 (KERNEL_TRACK=7); conflicts with the 6.18 package
#   orangepi6-npu_4.1.0-<rel>_arm64.deb          Arm China's open NPU library libaipudrv 4.1.0, headers, npu-run
#
# <rel> is the release tag without its "v" (v2026.11.22.1 -> 6.18.64-2026.11.22.1), so later releases upgrade earlier
# ones. The kernel packages install exactly like setup.sh: into /boot/sky1/ with a private initramfs, "Sky1 (acpi)"
# as the GRUB default and Armbian's kernel as entry 0 and the fallback (see docs/packages.md). They never touch
# Armbian's kernel packages, so the Armbian holds stay as they are.
#
# Usage:
#   scripts/package-deb.sh kernel <tree> <tag> [outdir]   <tree> = a linux-<KV> directory laid out like the release
#                                                         tarball (Image, DTB, .config, kernel.release, BUILDINFO,
#                                                         modinst/); package-release.sh makes one from a build
#   scripts/package-deb.sh from-release <tag> [outdir]    the same, from a published release tarball (downloaded and
#                                                         checked against SHA256SUMS); KERNEL_TRACK picks the track
#   scripts/package-deb.sh npu <tag> [outdir]             builds libaipudrv (scripts/npu-umd.sh) and npu-run; arm64 only
# outdir defaults to $WORK/release.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/sky1-build}
MAINT="jbuck2005 <59450931+jbuck2005@users.noreply.github.com>"
HOMEPAGE=https://github.com/jbuck2005/orangepi6
die() { echo "package-deb: $*" >&2; exit 1; }
TMPS=(); trap 'rm -rf "${TMPS[@]}"' EXIT
newtmp() { NEWTMP=$(mktemp -d); TMPS+=("$NEWTMP"); }   # sets NEWTMP; removed on exit
command -v dpkg-deb >/dev/null || die "dpkg-deb not found"

# $1 = template, $2 = output; replaces @NAME@ with the shell variable NAME
fill() { local s; s=$(cat "$1"); for v in KREL KV TRACK UMD_COMMIT; do s=${s//@$v@/${!v:-}}; done; printf '%s\n' "$s" > "$2"; }

build_deb() {  # $1 = root, $2 = outdir; DEBIAN/control must exist
  local root=$1 out=$2 name ver
  name=$(sed -n 's/^Package: //p' "$root/DEBIAN/control"); ver=$(sed -n 's/^Version: //p' "$root/DEBIAN/control")
  # files root:root, dirs 755, nothing group/world writable
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f ! -path "$root/DEBIAN/*" -exec chmod go-w {} +
  mkdir -p "$out"
  dpkg-deb --root-owner-group -Zxz --build "$root" "$out/${name}_${ver}_arm64.deb" >/dev/null
  echo "  built $out/${name}_${ver}_arm64.deb ($(du -h "$out/${name}_${ver}_arm64.deb" | cut -f1))"
}

kernel() {  # $1 = tree, $2 = tag, $3 = outdir
  local T=$1 TAG=$2 OUT=${3:-$WORK/release}
  [ -f "$T/include/config/kernel.release" ] || die "$T: no include/config/kernel.release"
  KREL=$(cat "$T/include/config/kernel.release")
  case "$KREL" in 6.18.*-sky1) TRACK=6.18 ;; 7.*-sky1) TRACK=7 ;; *) die "unexpected kernel release $KREL" ;; esac
  # kernel.conf must agree with the tree: the package's install scripts use it to find the kernel version
  KV=$(KERNEL_TRACK=$TRACK WORK=/nonexistent bash -c ". '$REPO/kernel.conf'; echo \$KV")
  [ "$KREL" = "$KV-sky1" ] || die "tree is $KREL but kernel.conf's $TRACK track is $KV"
  local M=$T/modinst/lib/modules/$KREL DTB=$T/arch/arm64/boot/dts/cix/sky1-orangepi-6.dtb
  for f in arch/arm64/boot/Image .config BUILDINFO; do [ -s "$T/$f" ] || die "$T/$f missing"; done
  [ -s "$DTB" ] || die "non-Plus DTB missing"
  [ -s "$M/modules.order" ] && [ -s "$M/modules.builtin" ] || die "$M: modules missing"
  local P=orangepi6-kernel-$TRACK VER=$KV-${TAG#v}
  echo "== $P $VER"
  newtmp; local R=$NEWTMP
  # modules: /usr/lib/modules (= /lib/modules on usrmerged Ubuntu); depmod output is made by postinst
  mkdir -p "$R/usr/lib/modules"
  cp -a "$M" "$R/usr/lib/modules/"
  rm -f "$R/usr/lib/modules/$KREL/build" "$R/usr/lib/modules/$KREL/source"
  for f in alias alias.bin builtin.alias.bin builtin.bin dep dep.bin devname softdep symbols symbols.bin weakdep; do
    rm -f "$R/usr/lib/modules/$KREL/modules.$f"
  done
  # the kernel, laid out as install.sh expects a build tree ($WORK/linux-$KV)
  local L=$R/usr/lib/orangepi6/$KREL/linux-$KV
  install -D -m644 "$T/arch/arm64/boot/Image" "$L/arch/arm64/boot/Image"
  install -D -m644 "$DTB" "$L/arch/arm64/boot/dts/cix/sky1-orangepi-6.dtb"
  install -D -m644 "$T/.config" "$L/.config"
  install -D -m644 "$T/include/config/kernel.release" "$L/include/config/kernel.release"
  install -D -m644 "$T/BUILDINFO" "$L/BUILDINFO"
  # this repo's install scripts, at the same relative paths
  local S=$R/usr/share/orangepi6
  install -D -m644 "$REPO/kernel.conf" "$S/kernel.conf"
  for f in install.sh setup.sh bootlog-area.sh boot-report.sh gpu-test.sh; do install -D -m755 "$REPO/scripts/$f" "$S/scripts/$f"; done
  for f in "$REPO"/initramfs/*; do install -D -m755 "$f" "$S/initramfs/${f##*/}"; done
  install -D -m644 "$REPO/systemd/sky1-boot-report.service" "$S/systemd/sky1-boot-report.service"
  install -D -m755 "$REPO/packaging/kernel/orangepi6-check" "$R/usr/sbin/orangepi6-check"
  local D=$R/usr/share/doc/$P; mkdir -p "$D"
  fill "$REPO/packaging/kernel/copyright" "$D/copyright"; chmod 644 "$D/copyright"
  install -m644 "$T/BUILDINFO" "$D/BUILDINFO"
  mkdir -p "$R/DEBIAN"
  for s in preinst postinst prerm postrm; do fill "$REPO/packaging/kernel/$s" "$R/DEBIAN/$s"; chmod 755 "$R/DEBIAN/$s"; done
  cat > "$R/DEBIAN/control" <<CTRL
Package: $P
Version: $VER
Architecture: arm64
Maintainer: $MAINT
Installed-Size: $(du -sk --exclude=DEBIAN "$R" | cut -f1)
Depends: bash, kmod, initramfs-tools, grub-common, grub2-common, device-tree-compiler, e2fsprogs, util-linux, udev, systemd
Recommends: mesa-vulkan-drivers, mesa-utils, vulkan-tools
Suggests: orangepi6-npu
Provides: orangepi6-kernel
Conflicts: orangepi6-kernel
Replaces: orangepi6-kernel
Section: kernel
Priority: optional
Homepage: $HOMEPAGE
Description: Linux $KREL for the Orange Pi 6 (CIX Sky1), with open GPU and NPU drivers
 kernel.org Linux $KV with the Sky1-Linux patches and the non-Plus Orange Pi 6
 device tree. Installs beside Armbian's kernel into /boot/sky1 with its own
 initramfs and makes "Sky1 (acpi)" the GRUB default; Armbian's kernel stays
 entry 0 and is booted automatically if a sky1 boot never comes up.
 Only one orangepi6-kernel package is installed at a time.
CTRL
  build_deb "$R" "$OUT"
}

from_release() {  # $1 = tag, $2 = outdir
  local TAG=$1 OUT=${2:-$WORK/release} KV
  KV=$(WORK=/nonexistent bash -c ". '$REPO/kernel.conf'; echo \$KV")
  local name="sky1-kernel-$KV-sky1-$TAG-arm64.tar.xz" url=https://github.com/jbuck2005/orangepi6/releases/download/$TAG
  newtmp; local d=$NEWTMP
  curl -fsSL --retry 4 -o "$d/SHA256SUMS" "$url/SHA256SUMS" || die "cannot download $url/SHA256SUMS"
  curl -fsSL --retry 4 -o "$d/$name" "$url/$name" || die "cannot download $name"
  ( cd "$d" && grep " $name\$" SHA256SUMS | sha256sum -c --quiet - ) || die "checksum mismatch for $name"
  mkdir "$d/x"; tar -C "$d/x" -xJf "$d/$name"
  kernel "$d/x/linux-$KV" "$TAG" "$OUT"
}

npu() {  # $1 = tag, $2 = outdir
  local TAG=$1 OUT=${2:-$WORK/release}
  [ "$(uname -m)" = aarch64 ] || die "the NPU package is built natively on the board (arm64)"
  "$REPO/scripts/npu-umd.sh" > "$WORK/npu-umd.log" 2>&1 || { tail -20 "$WORK/npu-umd.log"; die "libaipudrv build failed"; }
  UMD_COMMIT=$(sed -n 's/^UMD_COMMIT=\([0-9a-f]*\).*/\1/p' "$REPO/scripts/npu-umd.sh")
  local B=$WORK/npu-umd/build/lib U=$WORK/npu-umd/src/Linux/driver P=orangepi6-npu VER=4.1.0-${TAG#v}
  echo "== $P $VER"
  newtmp; local R=$NEWTMP
  local LIB=$R/usr/lib/aarch64-linux-gnu INC=$R/usr/include/aipu
  install -D -m644 "$B/libaipudrv.so.6.0.0" "$LIB/libaipudrv.so.6.0.0"
  ln -s libaipudrv.so.6.0.0 "$LIB/libaipudrv.so.6"; ln -s libaipudrv.so.6 "$LIB/libaipudrv.so"
  install -D -m644 "$U/umd/include/standard_api.h" "$INC/standard_api.h"
  install -D -m644 "$U/kmd/armchina-npu/include/armchina_aipu.h" "$INC/kmd/armchina_aipu.h"
  install -D -m644 "$U/umd/include/kmd/tcb.h" "$INC/kmd/tcb.h"
  mkdir -p "$R/usr/bin"
  g++ -std=c++14 -O2 -I"$INC" -o "$R/usr/bin/npu-run" "$REPO/tools/npu-run.cpp" -L"$LIB" -laipudrv || die "npu-run build failed"
  strip "$R/usr/bin/npu-run"
  local D=$R/usr/share/doc/$P; mkdir -p "$D"
  fill "$REPO/packaging/npu/copyright" "$D/copyright"; chmod 644 "$D/copyright"
  # library dependencies, as dpkg-shlibdeps finds them (it needs a debian/control to run in)
  newtmp; local deps="libc6, libstdc++6, libgcc-s1" s t=$NEWTMP
  mkdir "$t/debian"; printf 'Source: orangepi6-npu\n\nPackage: orangepi6-npu\nArchitecture: arm64\n' > "$t/debian/control"
  if s=$(cd "$t" && dpkg-shlibdeps -O --ignore-missing-info -l"$LIB" "$LIB/libaipudrv.so.6.0.0" "$R/usr/bin/npu-run" 2>/dev/null); then
    s=${s#shlibs:Depends=}; [ -n "$s" ] && deps=$s
  fi
  mkdir -p "$R/DEBIAN"
  install -m755 "$REPO/packaging/npu/postinst" "$R/DEBIAN/postinst"
  echo "activate-noawait ldconfig" > "$R/DEBIAN/triggers"
  cat > "$R/DEBIAN/control" <<CTRL
Package: $P
Version: $VER
Architecture: arm64
Maintainer: $MAINT
Installed-Size: $(du -sk --exclude=DEBIAN "$R" | cut -f1)
Depends: $deps
Enhances: orangepi6-kernel
Section: libs
Priority: optional
Homepage: $HOMEPAGE
Description: Open user-space driver for the Orange Pi 6 (CIX Sky1) NPU
 Arm China's open Zhouyi NPU library libaipudrv 4.1.0 (standard API, for the
 X2 NPU, architecture v3), its headers in /usr/include/aipu, and npu-run, a
 small tool that reports the NPU and runs compiled .cix models. Needs a sky1
 kernel with CIX's 6.2.0 NPU driver (orangepi6-kernel from v2026.11.22.1 on).
CTRL
  build_deb "$R" "$OUT"
}

case "${1:-}" in
  kernel) kernel "${2:?tree}" "${3:?tag}" "${4:-}" ;;
  from-release) from_release "${2:?tag}" "${3:-}" ;;
  npu) npu "${2:?tag}" "${3:-}" ;;
  *) echo "usage: $0 kernel <tree> <tag> [outdir] | from-release <tag> [outdir] | npu <tag> [outdir]"; exit 2 ;;
esac
