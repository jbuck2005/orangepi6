#!/bin/bash
# Runs on Sky1 boots only (sky1test= on the command line). Records GPU/NIC state.
#  sky1test=default: the everyday boot. Clears GRUB's sky1_pending, confirming the boot came up
#                    (otherwise the next GRUB run falls back to Armbian). Never reboots.
#  sky1test=acpi|dt: one-shot test boot. Reboots to Armbian if there's no network after 180 s.
OUT=/var/log/sky1-boot-report.txt
MODE=$(sed -n 's/.*sky1test=\([a-z]*\).*/\1/p' /proc/cmdline)
if [ "$MODE" = default ]; then
  grub-editenv - set sky1_pending=0 && echo "== $(date -Is) boot confirmed (sky1_pending=0)" > "$OUT.confirm"
fi
{
  echo "== $(date -Is) $(uname -r) mode=$MODE"; cat /proc/cmdline
  echo "== dmesg panthor/gpu/net/nvme"; dmesg | grep -iE 'panthor|mali|gpu|r8125|r8169|nvme' | head -80
  echo "== /dev/dri"; ls -la /dev/dri 2>&1
  echo "== lsmod"; lsmod | grep -E 'panthor|r812|drm'
  echo "== errors"; dmesg --level=err,crit,alert,emerg | grep -vE 'bench-(t|log|preflight):|repro:|stability:' | head -60
} > "$OUT" 2>&1
chmod 644 "$OUT"
for i in $(seq 1 36); do
  if [ -n "$(ip -4 route show default)" ]; then
    { echo "== network up after $((i*5))s"; ip -br link; } >> "$OUT"; exit 0
  fi
  sleep 5
done
if [ "$MODE" = default ]; then
  echo "== no network after 180s (default boot: not rebooting; check NIC link training)" >> "$OUT"; exit 0
fi
echo "== no network after 180s, rebooting to Armbian" >> "$OUT"; sync
systemctl reboot
