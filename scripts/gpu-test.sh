#!/bin/bash
# Headless GPU checks for a Sky1 test boot (panthor + Mesa panvk/panfrost).
# Needs: mesa-vulkan-drivers mesa-utils vulkan-tools glmark2-es2-drm vkmark (install on Armbian).
# Writes everything to /var/log/sky1-gpu-test.txt as well as stdout.
set -u
OUT=${OUT:-/var/log/sky1-gpu-test.txt}
{
  echo "== $(date -Is) kernel $(uname -r)"; cat /proc/cmdline
  echo "== panthor"; dmesg | grep -i panthor | head -20
  echo "== nodes"; ls -la /dev/dri
  echo "== Vulkan"; timeout 60 vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|driverInfo|apiVersion|conformanceVersion|ERROR' | head -20
  echo "== EGL/GLES (surfaceless)"; timeout 60 eglinfo -B -p surfaceless 2>&1 | grep -E 'renderer|version string|Error' | head
  echo "== glmark2-es2-drm off-screen"; timeout 600 glmark2-es2-drm --off-screen 2>&1 | grep -E 'GL_RENDERER|GL_VERSION|Score|Error|error' | head -20
  echo "== vkmark headless"; timeout 600 vkmark --winsys headless 2>&1 | grep -E 'Vendor|Device|Score|Error|error' | head -20
  echo "== GPU-related kernel errors"; dmesg --level=err,crit,alert,emerg | grep -iE 'panthor|gpu|mali|drm' | grep -v trilin | head -20
  echo "== end $(date -Is)"
} 2>&1 | tee "$OUT"
