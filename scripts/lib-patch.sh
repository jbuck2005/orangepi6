# apply_sky1_patches <linux-sky1 dir> <log>: run inside the kernel tree. Needs REPO and kernel.conf.
#   6.18 track: <linux-sky1>/$SKY1_PATCHES, where a file in $REPO/$SKY1_REFRESHED replaces the upstream patch of
#               the same name, then $REPO/$SKY1_REFRESHED/post/*.patch.
#   7 track:    $REPO/$LOCAL_PATCHES (this repo's forward port) instead of the linux-sky1 series.
apply_sky1_patches() {
  local s=$1 log=$2 dir p up out n=0 r=0 f=0
  dir=$s/$SKY1_PATCHES
  [ -z "${LOCAL_PATCHES:-}" ] || dir=${REPO:?REPO not set}/$LOCAL_PATCHES
  ls "$dir"/*.patch >/dev/null 2>&1 || { echo "no patches in $dir"; return 1; }
  : > "$log"
  for up in "$dir"/*.patch; do
    p=$up
    if [ -z "${LOCAL_PATCHES:-}" ] && [ -n "${SKY1_REFRESHED:-}" ] && [ -f "$REPO/$SKY1_REFRESHED/${up##*/}" ]; then
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
  # patches this repo adds after the series, for API changes in $KV (none fuzzed)
  if [ -z "${LOCAL_PATCHES:-}" ] && [ -n "${SKY1_REFRESHED:-}" ]; then
    for p in "$REPO/$SKY1_REFRESHED"/post/*.patch; do
      [ -f "$p" ] || continue
      git apply --whitespace=nowarn "$p" || { echo "patch failed: $p"; return 1; }
      n=$((n+1)); echo "== ADDED ${p##*/}" >> "$log"
    done
  fi
  echo "patches: $n applied exactly from $dir ($r of them refreshed in this repo), $f with fuzz (see $log)"
}
