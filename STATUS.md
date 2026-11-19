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
- [x] sky1 is the default boot (`install.sh default`), with automatic fallback to Armbian

## Kernel 6.18.64 LTS (branch lts-6.18)
- [x] The Sky1-Linux 6.18.14 patches rebased onto 6.18.64 with a 3-way merge. 134 of 139 apply unchanged; 5 are
      refreshed in `patches/6.18.64/` (conflicts in alc269 audio, macb ACPI ID includes and arm_scmi ACPI resolved by
      hand; 0011 irqchip/iommu and 0118 smmu-v3 merged without conflicts). Patching is strict: no fuzz.
- [x] 6.18.64 has the stable backport of the new syscore API (`register_syscore`, callbacks take `void *data`).
      `patches/6.18.64/post/0001` converts the Sky1 PDC irqchip and PCIe drivers, as the Sky1 6.19 track does.
- [x] Cross-compile check for arm64 (compile only; the board build is native)
- [x] Board test (native build, gcc 15.2): 6.18.64-sky1 boots in ACPI mode; panthor, panvk and Panfrost OK
      (`setup.sh check`); NVMe, all 3 PCIe links (SMMU bypass STEs, no AER/SMMU faults) and both RTL8125 NICs up.
      Benchmarks match 6.18.14: vkpeak FP32 1205 GFLOPS, vkmark 3544.
- [x] netconsole warned once at boot ("exceeded budget in poll"): the r8125 "other" MSI-X vector reported work at
      netpoll's budget of 0. Fixed in `patches/6.18.64/post/0002`.
- [ ] Two silent resets under -j6 build load on 6.18.64 (none seen on 6.18.14 or Armbian 6.18.45). One later boot
      showed a sky1-pcie AER interrupt storm with nothing latched, right after "waiting PHY is ready! retries = 1",
      the same as the first kernel-7 boot. From kernel-7: `post/0003` returns IRQ_NONE for such interrupts, disables
      the line after 64 in a row and rate-limits AER logging; `post/0004` clears local errors latched during PHY
      bring-up, the likely source. Whether the storm causes the resets is not yet known; retest pending.

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

## Default boot (2026-11-18)
- `sudo WORK=... scripts/install.sh default` installs `/etc/grub.d/44_sky1_default`, which makes
  the "Sky1 (acpi)" entry the default; Armbian stays entry 0 as the fallback. `undefault` reverts.
- Fallback: GRUB sets `sky1_pending=1` when it boots that entry, and `sky1-boot-report` clears it
  once userspace is up. If GRUB still finds it set (a hang, panic or power loss before userspace),
  it boots Armbian and sets `sky1_failed=1`, so Armbian stays the default until `default` is run
  again. One-shot test boots (`arm`) are unaffected. Both paths were tested on the board.
- `stage` must run from Armbian (it reads the real NIC MACs from r8169); `verify`/`arm` work from either.

## Memory stability and benchmarks (2026-11-18)
- The shipped firmware (OPI6BiosV0.8, 2026-04-27) was unstable at its default 6400 MT/s: 1227 corrected
  + 1 uncorrectable DDR ECC errors in 3 min of stress on stock Armbian, plus board resets under load.
- The official 2026-10-19 firmware (`bios_v1.0.bin`, flashed with FlashUpdate.efi from the UEFI Shell)
  fixes it: 0 ECC errors at 5500, 6000 (its new Auto) and 6400, including a 4-hour combined
  CPU+RAM+GPU soak at 6400. Details and the table: `bench/MEMORY-AB-REPORT.md`.
- Benchmarks are the same at every rate: llama.cpp CPU Qwen2.5-1.5B Q4 124/36.6 tok/s (pp/tg),
  7B 33.7/8.75; vkpeak fp32 1.2 TF, fp16 2.1 TF, int8 4.86 TOPS. llama.cpp on panvk: tg ~1.7 tok/s,
  pp fails (ErrorOutOfDeviceMemory at CommandBuffer::end), so use the CPU for LLMs for now.
- Use `-dev none` for CPU-only llama-bench in a Vulkan build (otherwise it still offloads to the GPU).
- Scripts: `bench/` (suite, soak, bandwidth, build, UART logger for Windows).
