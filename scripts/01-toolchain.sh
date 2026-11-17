#!/bin/bash
# Unpack an Ubuntu build toolchain into $WORK/tc without root (apt-get download + dpkg -x).
set -euo pipefail
WORK=${WORK:-$HOME/sky1-build}; P=$WORK/tc
mkdir -p "$WORK/debs" "$P/rtlib"; cd "$WORK/debs"
PK=$(apt-get install -s --no-install-recommends gcc make flex bison libssl-dev libelf-dev bc cpio kmod xz-utils zstd 2>/dev/null | awk '/^Inst/{print $2}')
[ -n "$PK" ] && apt-get download $PK
for d in *.deb; do dpkg -x "$d" "$P"; done
ln -sfn usr/lib "$P/lib"; ln -sfn usr/bin "$P/bin"
for l in libgcc_s.so.1 libelf.so.1 libz.so.1 libzstd.so.1; do
  [ -e "$P/usr/lib/aarch64-linux-gnu/$l" ] || cp -L "/usr/lib/aarch64-linux-gnu/$l" "$P/usr/lib/aarch64-linux-gnu/"
done
for f in "$P"/usr/lib/aarch64-linux-gnu/lib{isl,mpc,mpfr,bfd,opcodes,ctf,sframe,jansson,gprofng,cc1,ssl,crypto}*so*; do
  [ -e "$f" ] && ln -sf "$f" "$P/rtlib/"
done
cat > "$WORK/env.sh" <<ENV
P=$P
export PATH=\$P/usr/bin:\$PATH
export LD_LIBRARY_PATH=\$P/rtlib
export CC="gcc --sysroot=\$P"
export HOSTCC="gcc --sysroot=\$P"
export M4=\$P/usr/bin/m4
export BISON_PKGDATADIR=\$P/usr/share/bison
ENV
echo "Toolchain ready: . $WORK/env.sh"
