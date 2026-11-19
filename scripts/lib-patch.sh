# apply_sky1_patches <linux-sky1 dir> <log>: run inside the kernel tree.
# Needs REPO and kernel.conf. A file in $REPO/$SKY1_REFRESHED replaces the upstream patch of the same name.
apply_sky1_patches() {
  local s=$1 log=$2 p up out n=0 r=0 f=0
  : > "$log"
  for up in "$s/$SKY1_PATCHES"/*.patch; do
    p=$up
    if [ -n "${SKY1_REFRESHED:-}" ] && [ -f "$REPO/$SKY1_REFRESHED/${up##*/}" ]; then
      p=$REPO/$SKY1_REFRESHED/${up##*/}; r=$((r+1)); echo "== REFRESHED ${up##*/}" >> "$log"
    fi
    if git apply --whitespace=nowarn "$p" 2>/dev/null; then n=$((n+1)); continue; fi
    [ "${ALLOW_FUZZ:-0}" = 1 ] || { echo "patch failed: $p"; git apply --check --whitespace=nowarn "$p" 2>&1 | head -5; return 1; }
    if out=$(patch -p1 -F3 --no-backup-if-mismatch -r - < "$p" 2>&1) && ! grep -q FAILED <<<"$out"; then
      f=$((f+1)); { echo "== FUZZ ${p##*/}"; echo "$out"; } >> "$log"
    else
      { echo "== REJECT ${p##*/}"; echo "$out"; } >> "$log"; echo "patch rejected: $p (see $log)"; return 1
    fi
  done
  echo "patches: $n applied exactly ($r of them refreshed in this repo), $f with fuzz (see $log)"
}
