# Status

## Phase 1: GPU (working, 2026-11-18)
- [x] Diagnosis: the generic Armbian 6.18 kernel has no panthor driver, boots ACPI, and leaves the GPU unbound with no `/dev/dri`.
- [x] Kernel 6.18.14 + Sky1-Linux patches apply cleanly. The build toolchain runs without root.
- [x] Non-Plus DTS written and checked against the board's ACPI PCIe description.
- [x] Build finished
- [x] Test boot (ACPI mode, `install.sh arm acpi`): panthor probes, `/dev/dri/renderD128` exists, NVMe and NICs come up
- [x] Results (`scripts/gpu-test.sh`): Vulkan via panvk (Mesa 26.0.8, Ubuntu) on Mali-G720 MC10; GLES 3.1 via Panfrost;
      `glmark2-es2-drm --off-screen` 1591; `vkmark --winsys headless` 3460 (llvmpipe on Armbian: 741)
- [ ] Device-tree boot (`arm dt`): not needed for the GPU after all, since the Sky1 patches power the GPU in ACPI mode
- [ ] Make the sky1 kernel the default (Armbian stays the GRUB default until then)

### What it took (all checked by `install.sh verify`)
- The initramfs must be built with a clean environment. The toolchain's `LD_LIBRARY_PATH` made
  `copy_exec` pack libcrypto under the build tree, so modprobe/udevd failed and init exited.
- The initramfs `dd` is klibc's: no `conv=fsync`. The boot logger flushes explicitly instead.
- The vendor r8125 driver can't read the NICs' MACs in ACPI mode and picks random ones. `.link`
  files (match `Driver=r8125` + PCI path) pin the real MACs, and they are inert under Armbian's r8169.

### Debugging aids
- Debug UART: the 2x2 `DEBUG` header next to the left RJ45 (UART2, 3.3 V, 115200 8N1).
  Firmware, GRUB and kernel all log there. The firmware has no SPCR table, so test boots use
  `earlycon=pl011,mmio32,0x040d0000` (`SERIAL=1 install.sh arm ...`).
- The GRUB test entry saves `sky1_picked`/`sky1_stage` to grubenv. `install.sh bootlog` prints them
  with the raw-disk boot log.
- Known flake: firmware PCIe link training for the NICs sometimes fails at power-on, and then there's
  no network at all, even on Armbian. A 30 s power-off fixes it.

## Phase 2: NPU (next)
- Leads: [visorcraft/orange-pi-6-plus-npu](https://github.com/visorcraft/orange-pi-6-plus-npu), [Sky1-Linux/sky1-drivers-dkms](https://github.com/Sky1-Linux/sky1-drivers-dkms).
- The vendor NPU driver needs a kbuild rewrite, `-DCONFIG_ARMCHINA_NPU_ARCH_V3 -DBUILD_ZHOUYI_V37`, and `sky1_npu_remove` changed to return void.
- On the sky1 ACPI boot the in-tree `armchina` driver already probes (`sky1_npu_probe ... done`).

## Ruled out
- The CIX/Canonical vendor kernel and the closed Mali stack (`Sky1-Linux/cix-gpu-kmd` + `libmali`): closed userspace and no Vulkan.
- NCZ-OS (including the old "Magnetar" net installer): RC kernel, Orange Pi 6 untested, vendor GPU stack by default, and telnet/root logins on by default.
- The earlier plan in this repo (an Orange Pi vendor image built with `orangepi-build`): abandoned.
