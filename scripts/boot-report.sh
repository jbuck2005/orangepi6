#!/bin/bash
# Runs only on a Sky1 test boot (sky1test= on the command line). Records GPU state, and reboots
# back to Armbian (GRUB default) if the network never comes up, so a headless box recovers.
OUT=/var/log/sky1-boot-report.txt
{
  echo "== $(date -Is) $(uname -r)"; cat /proc/cmdline
  echo "== dmesg panthor/gpu/net/nvme"; dmesg | grep -iE 'panthor|mali|gpu|r8125|nvme' | head -80
  echo "== /dev/dri"; ls -la /dev/dri 2>&1
  echo "== lsmod"; lsmod | grep -E 'panthor|r812|drm'
  echo "== errors"; dmesg --level=err,crit,alert,emerg | head -60
} > "$OUT" 2>&1
chmod 644 "$OUT"
for i in $(seq 1 36); do
  if [ -n "$(ip -4 route show default)" ]; then
    { echo "== network up after $((i*5))s"; ip -br link; } >> "$OUT"; exit 0
  fi
  sleep 5
done
echo "== no network after 180s, rebooting to Armbian" >> "$OUT"; sync
systemctl reboot
