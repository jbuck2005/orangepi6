# Status

## Phase 1: GPU (in progress)
- [x] Diagnosis: the generic Armbian 6.18 kernel has no panthor driver, boots ACPI, and leaves the GPU unbound with no `/dev/dri`.
- [x] Kernel 6.18.14 + Sky1-Linux patches apply cleanly. The build toolchain runs without root.
- [x] Non-Plus DTS written and checked against the board's ACPI PCIe description.
- [ ] Build finished
- [ ] Test boot: panthor probes, `/dev/dri/renderD128` exists, NVMe and both NICs come up
- [ ] vulkaninfo / eglinfo / clinfo / vkmark results

## Phase 2: NPU (later)
- Leads: [visorcraft/orange-pi-6-plus-npu](https://github.com/visorcraft/orange-pi-6-plus-npu), [Sky1-Linux/sky1-drivers-dkms](https://github.com/Sky1-Linux/sky1-drivers-dkms).
- The vendor NPU driver needs a kbuild rewrite, `-DCONFIG_ARMCHINA_NPU_ARCH_V3 -DBUILD_ZHOUYI_V37`, and `sky1_npu_remove` changed to return void.

## Ruled out
- The CIX/Canonical vendor kernel and the closed Mali stack (`Sky1-Linux/cix-gpu-kmd` + `libmali`): closed userspace and no Vulkan.
- NCZ-OS (including the old "Magnetar" net installer): RC kernel, Orange Pi 6 untested, vendor GPU stack by default, and telnet/root logins on by default.
- The earlier plan in this repo (an Orange Pi vendor image built with `orangepi-build`): abandoned.
