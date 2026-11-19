# apply_sky1_patches <linux-sky1 dir> <log>: run inside the kernel tree.
apply_sky1_patches() {
  local s=$1 log=$2 p out n=0 f=0
  : > "$log"
  for p in "$s/$SKY1_PATCHES"/*.patch; do
    if git apply --whitespace=nowarn "$p" 2>/dev/null; then n=$((n+1)); continue; fi
    [ "${ALLOW_FUZZ:-0}" = 1 ] || { echo "patch failed: $p"; return 1; }
    if out=$(patch -p1 -F3 --no-backup-if-mismatch -r - < "$p" 2>&1) && ! grep -q FAILED <<<"$out"; then
      f=$((f+1)); { echo "== FUZZ $(basename "$p")"; echo "$out"; } >> "$log"
    else
      { echo "== REJECT $(basename "$p")"; echo "$out"; } >> "$log"; echo "patch rejected: $p (see $log)"; return 1
    fi
  done
  echo "patches: $n clean, $f with fuzz (see $log)"
}
