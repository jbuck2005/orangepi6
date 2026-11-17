#!/bin/bash
# Raw boot-log area: a zero-filled, single-extent file on the root fs whose physical disk
# location is proven by reading the raw disk, so the initramfs can write to it with dd
# before any filesystem is mounted.
#
#   bootlog-area.sh setup <file> <conf>  create the file, prove its location, write conf
#   bootlog-area.sh prove <conf> <file>  re-prove that conf still points at the file
#   bootlog-area.sh read  <conf>         print the log from the raw disk
set -euo pipefail
SIZE=$((8 * 1024 * 1024))
die() { echo "FAIL: $*" >&2; exit 1; }

locate() {  # $1 file -> prints "DISK OFFSET"
  local f=$1 part disk pstart bs ext phys n
  part=$(findmnt -no SOURCE --target "$f")                 # e.g. /dev/nvme0n1p2
  [ -b "$part" ] || die "no block device for $f"
  disk=/dev/$(lsblk -no PKNAME "$part")
  [ -b "$disk" ] || die "no parent disk for $part"
  pstart=$(cat "/sys/class/block/$(basename "$part")/start") # 512-byte sectors
  bs=$(stat -f -c %S "$f")
  ext=$(filefrag -v "$f")
  n=$(grep -cE '^ +[0-9]+:' <<<"$ext")
  [ "$n" -eq 1 ] || die "$f has $n extents; need exactly 1"
  grep -qE 'unwritten' <<<"$ext" && die "$f has unwritten extents"
  phys=$(awk '/^ +0:/{gsub(/\.\./," "); print $4}' <<<"$ext")
  [ -n "$phys" ] || die "cannot parse filefrag output"
  echo "$disk $((pstart * 512 + phys * bs))"
}

prove() {  # $1 disk $2 offset $3 file : write a random pattern through the fs, read raw
  local disk=$1 off=$2 f=$3 pat raw
  pat=$(head -c 4096 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s' "$pat" | head -c 4096 | dd of="$f" bs=4096 count=1 conv=notrunc,fsync status=none
  raw=$(dd if="$disk" bs=4096 count=1 skip=$((off / 4096)) iflag=direct status=none | head -c 4096)
  [ "$raw" = "${pat:0:4096}" ] || die "raw read at $disk+$off does not match $f"
  dd if=/dev/zero of="$f" bs=4096 count=1 conv=notrunc,fsync status=none
}

case "${1:-}" in
  setup)
    f=${2:?file} conf=${3:?conf}
    rm -f "$f"; head -c "$SIZE" /dev/zero > "$f"; sync "$f"
    read -r disk off < <(locate "$f")
    [ $((off % 4096)) -eq 0 ] || die "offset $off not 4 KiB aligned"
    prove "$disk" "$off" "$f"
    printf 'DEV=%s\nOFFSET=%s\nSIZE=%s\nFILE=%s\n' "$disk" "$off" "$SIZE" "$f" > "$conf"
    echo "  ok: boot-log area $f = $disk+$off ($SIZE bytes), proven by raw read" ;;
  prove)
    conf=${2:?conf}; f=${3:?file}
    # shellcheck disable=SC1090
    . "$conf"
    read -r disk off < <(locate "$f")
    [ "$disk" = "$DEV" ] && [ "$off" = "$OFFSET" ] || die "conf no longer matches $f"
    prove "$DEV" "$OFFSET" "$f"
    echo "  ok: boot-log area still at $DEV+$OFFSET" ;;
  read)
    conf=${2:?conf}
    # shellcheck disable=SC1090
    . "$conf"
    dd if="$DEV" bs=4096 count=$((SIZE / 4096)) skip=$((OFFSET / 4096)) iflag=direct status=none | tr -d '\000' ;;
  *) echo "usage: $0 setup <file> <conf> | prove <conf> <file> | read <conf>"; exit 2 ;;
esac
