#!/bin/bash
# Headless GPU checks on the device-tree boot.
set -u
sudo apt-get install -y -q mesa-vulkan-drivers mesa-utils vulkan-tools clinfo mesa-opencl-icd vkmark >/dev/null
echo "== kernel";  uname -r; sudo dmesg | grep -i panthor | head
echo "== nodes";   ls -la /dev/dri
echo "== Vulkan";  vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|apiVersion|driverInfo'
echo "== EGL/GLES (surfaceless)"; eglinfo -B -p surfaceless 2>&1 | grep -E 'renderer|version string' | head
echo "== OpenCL (rusticl)"; RUSTICL_ENABLE=panfrost clinfo -l 2>&1
echo "== vkmark (headless)"; vkmark --winsys headless 2>&1 | tail -15
