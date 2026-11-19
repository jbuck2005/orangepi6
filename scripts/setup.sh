#!/bin/bash
# One-command install of the open GPU stack on an Orange Pi 6 (non-Plus) running stock Armbian.
#
#   git clone https://github.com/jbuck2005/orangepi6 && cd orangepi6 && scripts/setup.sh
#
# Steps (each one is checked; the script stops with a clear message on the first failure):
#   1. preflight   board, firmware, OS, disk space, network
#   2. packages    build dependencies and Mesa/Vulkan userspace from the Ubuntu archive (apt)
#   3. source      kernel.org $KV from kernel.conf (signature checked) + Sky1-Linux patches + this repo's DTS
#   4. build       Image, modules, DTBs (-j6, 20-60 min)
#   5. stage       /boot/sky1/*, modules, initramfs, NIC MAC pins; then install.sh verify
#   6. default     "Sky1 (acpi)" becomes the GRUB default; Armbian stays entry 0 and the
#                  automatic fallback if a sky1 boot never comes up
# Then reboot, and run `scripts/setup.sh check` to confirm the GPU.
#
#   scripts/setup.sh --prebuilt   skips steps 3-4: downloads the release kernel (same build process),
#                                 checks its SHA-256 against the release's SHA256SUMS, then steps 5-6.
#
# Re-running is safe: finished steps are skipped (state in $WORK/.setup-*). `setup.sh <step>` runs one step.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/sky1-build}
export WORK
# shellcheck disable=SC1091
. "$REPO/kernel.conf"
RELEASE_TAG=${RELEASE_TAG:-v2026.11.19.1}
RELEASE_URL=${RELEASE_URL:-https://github.com/jbuck2005/orangepi6/releases/download/$RELEASE_TAG}
STEPS="preflight packages source build stage default"
if [ "${1:-}" = --prebuilt ]; then PREBUILT=1; shift; set -- "${1:-all}"; fi
PREBUILT=${PREBUILT:-0}
[ "$PREBUILT" = 1 ] && STEPS="preflight packages fetch stage default"

say()  { printf '\n== %s\n' "$*"; }
ok()   { echo "  ok: $*"; }
warn() { echo "  WARNING: $*"; }
die()  { echo "  FAIL: $*" >&2; exit 1; }
done_mark() { touch "$WORK/.setup-$1"; }
is_done()   { [ -f "$WORK/.setup-$1" ]; }

preflight() {
  say "preflight"
  [ "$(id -u)" -ne 0 ] || die "run as your normal user (it uses sudo where needed)"
  sudo true || die "sudo is required"
  [ "$(uname -m)" = aarch64 ] || die "not an arm64 system"
  [ "$(cat /sys/class/dmi/id/board_name 2>/dev/null)" = "CIX Board" ] || die "not a CIX Sky1 board (DMI board_name)"
  local bios; bios=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)
  case "$bios" in
    OPI6BiosV0.*) warn "firmware $bios is the early release. Its default memory speed (6400 MT/s) produced
           DDR ECC errors and resets on our board. Update to opi6_bios_image_20261019 or later first
           (see INSTALL.md), or set Memory Data Rate to 5500 MT/s in setup." ;;
    *) ok "firmware $bios" ;;
  esac
  # non-Plus: two RTL8125 NICs and no PCIe x4 port in use. The Plus needs a different DTB.
  local nics; nics=$(grep -l 0x8125 /sys/bus/pci/devices/*/device 2>/dev/null | wc -l)
  [ "$nics" -ge 1 ] || die "no RTL8125 found; this script targets the Orange Pi 6 (non-Plus)"
  ok "$nics RTL8125 port(s)"
  [ -f /etc/armbian-release ] || warn "not Armbian; only tested on Armbian 26.x (Ubuntu 26.04)"
  grep -q '^ID=ubuntu' /etc/os-release && grep -q 'VERSION_ID="26' /etc/os-release || warn "tested on Ubuntu 26.04 userspace only"

  local free; free=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc 0-9)
  [ "$free" -ge 20 ] || die "need about 20 GB free in $HOME (have ${free} GB)"
  ok "${free} GB free"
  curl -fsI https://cdn.kernel.org >/dev/null || die "no internet access (cdn.kernel.org)"
  ok "internet"
  case "$WORK" in "$REPO"*) die "WORK must not be inside the repo (kernel would become -sky1+)";; esac
  if git -C "$WORK" rev-parse >/dev/null 2>&1; then die "WORK=$WORK is inside a git repository"; fi
}

packages() {
  say "packages (apt)"
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    build-essential flex bison bc cpio kmod xz-utils zstd libssl-dev libelf-dev patch \
    git curl gnupg ca-certificates device-tree-compiler dosfstools \
    mesa-vulkan-drivers mesa-utils vulkan-tools
  ls /lib/firmware/arm/mali/arch12.8/mali_csffw.bin >/dev/null || die "Mali CSF firmware missing (linux-firmware)"
  ok "build tools, Mesa, Mali firmware"
  # The build scripts read $WORK/env.sh; with system gcc it only has to exist.
  mkdir -p "$WORK"
  printf '# system toolchain (setup.sh)\nexport CC=gcc\nexport HOSTCC=gcc\n' > "$WORK/env.sh"
  ok "$WORK/env.sh (system gcc $(gcc -dumpversion))"
}

fetch() {
  say "fetch prebuilt kernel ($RELEASE_TAG)"
  local name="sky1-kernel-$KV-sky1-$RELEASE_TAG-arm64.tar.xz" d="$WORK/download"
  mkdir -p "$d"
  curl -fL --retry 4 -o "$d/SHA256SUMS" "$RELEASE_URL/SHA256SUMS" || die "cannot download SHA256SUMS from $RELEASE_URL"
  curl -fL --retry 4 -o "$d/$name" "$RELEASE_URL/$name" || die "cannot download $name"
  ( cd "$d" && grep " $name\$" SHA256SUMS | sha256sum -c - ) || die "checksum mismatch for $name"
  ok "sha256 matches SHA256SUMS"
  rm -rf "$WORK/linux-$KV"
  tar -C "$WORK" -xJf "$d/$name"
  [ "$(cat "$WORK/linux-$KV/include/config/kernel.release")" = "$KV-sky1" ] || die "unexpected kernel release in tarball"
  sed 's/^/  | /' "$WORK/linux-$KV/BUILDINFO"
  ok "kernel unpacked to $WORK/linux-$KV"
}

source_() {
  say "source"
  "$REPO/scripts/02-fetch-patch.sh"
}

build() {
  say "build (-j${JOBS:-6}, 20-60 min)"
  "$REPO/scripts/03-build.sh" > "$WORK/build.log.tail" 2>&1 || { tail -30 "$WORK/build.log"; die "build failed (see $WORK/build.log)"; }
  [ -f "$WORK/linux-$KV/arch/arm64/boot/Image" ] || die "no Image after build"
  ok "kernel built (03-build.sh synced it to disk)"
}

stage() {
  say "stage"
  # stage reads the NICs' real MAC addresses through Armbian's r8169 driver (sky1 can't, see install.sh)
  [ "$(uname -r)" != "$KV-sky1" ] || die "running $KV-sky1: boot Armbian's kernel for this step
         (sudo grub-reboot \"\$(grep -m1 -oP \"menuentry '\\KArmbian[^']*\" /boot/grub/grub.cfg)\" && sudo reboot)"
  sudo WORK="$WORK" bash "$REPO/scripts/install.sh" stage
  sync
}

default_() {
  say "make sky1 the default boot"
  sudo WORK="$WORK" bash "$REPO/scripts/install.sh" default
  echo
  echo "Done. Reboot now:  sudo reboot"
  echo "Afterwards:        $REPO/scripts/setup.sh check"
}

check() {
  say "check (after rebooting into sky1)"
  [ "$(uname -r)" = "$KV-sky1" ] || die "running $(uname -r), not $KV-sky1. If GRUB fell back to Armbian,
         see: sudo $REPO/scripts/install.sh bootlog"
  ok "kernel $(uname -r)"
  [ "$(sudo grub-editenv list | sed -n 's/^sky1_pending=//p')" = 0 ] || warn "boot not confirmed yet (sky1-boot-report runs at boot)"
  local km; km=$(sudo dmesg 2>/dev/null || true); grep -q 'Initialized panthor' <<<"$km" || die "panthor did not initialize"
  [ -e /dev/dri/renderD128 ] || die "no /dev/dri/renderD128"
  ok "panthor + render node"
  local vk; vk=$(vulkaninfo --summary 2>/dev/null || true); grep -qE 'driverName *= panvk' <<<"$vk" || die "Vulkan does not list panvk"
  ok "Vulkan: $(sed -n 's/.*deviceName *= //p' <<<"$vk" | head -1) (panvk)"
  local egl; egl=$(eglinfo -B -p surfaceless 2>/dev/null || true); grep -q 'Panfrost' <<<"$egl" || die "EGL/GLES does not use Panfrost"
  ok "GLES: Panfrost"
  [ -n "$(ip -4 route show default)" ] || warn "no default route (see INSTALL.md: NIC link training quirk)"
  # only now is the new kernel known good: drop module trees of older sky1 releases
  if [ "$(sudo grub-editenv list | sed -n 's/^sky1_pending=//p')" = 0 ]; then
    sudo bash "$REPO/scripts/install.sh" prune
  else
    warn "keeping older sky1 modules until the boot is confirmed (re-run check later)"
  fi
  echo; echo "All good. Benchmarks: $REPO/scripts/gpu-test.sh"
}

run() {  # $1 = step
  local fn=$1; [ "$1" = source ] && fn=source_; [ "$1" = default ] && fn=default_
  if [ "${FORCE:-0}" != 1 ] && is_done "$1"; then echo "== $1: already done (FORCE=1 to redo)"; return; fi
  "$fn"; [ "$1" = preflight ] || done_mark "$1"
}

mkdir -p "$WORK"
case "${1:-all}" in
  all) for s in $STEPS; do run "$s"; done ;;
  preflight|packages|fetch|source|build|stage|default) run "$1" ;;
  check) check ;;
  *) echo "usage: $0 [--prebuilt] [all|preflight|packages|fetch|source|build|stage|default|check]"; exit 2 ;;
esac
