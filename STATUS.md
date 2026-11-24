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
- [x] Two silent resets under -j6 build load on 6.18.64 before the fixes. A later boot showed the cause: a sky1-pcie.2
      (NVMe) AER interrupt storm with nothing in the AER registers, right after "waiting PHY is ready! retries = 1",
      the same as the first kernel-7 boot. From kernel-7: `post/0003` returns IRQ_NONE for such interrupts, disables
      the line after 64 in a row and rate-limits AER logging; `post/0004` clears local errors latched during PHY
      bring-up (masked from the local IRQ, so nothing else cleared them).
- [x] With the fixes (323a39d): 1 h load tests (kernel build at -j6, then `stress-ng --vm 6 --cpu 6`) at 6000 and
      6400 MT/s, 0 resets, 0 ECC errors, no AER storm, peak 70 °C. RAM speed was not the cause.
- [x] A reset 2 min after a build left every `.ko` zero-length (ext4 delayed allocation, caught by `install.sh
      verify`). Build and stage now `sync`.

### What it took (all checked by `install.sh verify`)
- The initramfs must be built with a clean environment. The toolchain's `LD_LIBRARY_PATH` made
  `copy_exec` pack libcrypto under the build tree, so modprobe/udevd failed and init exited.
- The initramfs `dd` is klibc's: no `conv=fsync`. The boot logger flushes explicitly instead.
- The NICs (RTL8125B, rev 05) now use mainline r8169, which reads the real MACs. With an r8125 build
  (`NIC_DRIVER=r8125`), that driver can't read them in ACPI mode, so `stage` pins them with `.link` files
  (match `Driver=r8125` + PCI path).

### Debugging aids
- Debug UART: the 2x2 `DEBUG` header next to the left RJ45 (UART2, 3.3 V, 115200 8N1).
  Firmware, GRUB and kernel all log there. The firmware has no SPCR table, so test boots use
  `earlycon=pl011,mmio32,0x040d0000` (`SERIAL=1 install.sh arm ...`).
- The GRUB test entry saves `sky1_picked`/`sky1_stage` to grubenv. `install.sh bootlog` prints them
  with the raw-disk boot log.
- FIXED 2026-11-21 (r8169 default): firmware PCIe link training for the NICs failed after every warm reboot
  from a sky1 kernel with r8125, and then there was no network at all, even on Armbian. Cause: state r8125 sets in
  the chip at probe (it also fails with the NICs never opened); not PERST#, the shutdown hooks, ASPM, the NIC config
  space, EPHY or the PCIe controller. With r8169: 5 of 5 reboots trained. Earlier notes: Serial log (40 firmware boots, 2026-11-17..19): 5 failures, every one right
  after a sky1 session, both ports `Ltssm State:40C80` = Polling.Compliance (receiver detected, NIC silent).
  Empty ports read 40080 = Detect.Quiet. A 30 s power-off fixes it. The NIC rails are switched by GPIO038/039
  (S5 GPIO0 lines 27/28, schematic p19-20; firmware drives them as outputs, high). Switching them from
  Armbian through /dev/mem froze the board twice, so `scripts/nic-power.sh` is experimental and gated.
  Supported workaround: a local smart plug driven by `tools/plug-watch.ps1` from the serial log (tested: one
  cycle through Home Assistant, 2026-11-19). Needs an RTC battery (CR2032 on JRTC1): without one a
  power cut resets the firmware settings (6400 -> 6000 MT/s, power-on-after-AC-loss off) and the board stays off.

## Kernel 7.3.5 (`KERNEL_TRACK=7`, merged 2026-11-22, the default since v2026.11.24)
- [x] Sky1-Linux `patches-next` (made for v7.0-rc1) forward-ported to kernel.org 7.3.5: 26 patches picked cleanly,
      17 conflicts resolved by hand (Panthor hand-ported), `0044` for 7.x API changes. Details in `docs/KERNEL-7.md`.
- [x] Native build on the board; boots in ACPI mode; `setup.sh check` passes; GPU benchmarks at parity with 6.18.
- [x] PCIe AER interrupt storm on 7.x: `0045` guard, `0049` local-error clearing, `0052` re-arm, and `0053`, which acks
      the LTSSM-transition indication that held the line asserted (the root cause). Quiet on every boot since; not
      yet seen on a boot that would have stormed.
- [x] 1 h load test at 6000 MT/s passed; warm reboot test passed.
- [x] CPU scheduling gap (12-20% slower, threads on the little cores) found and fixed: `0055` (wakeup scan cut short by
      SIS_UTIL). As booted now equals pinned and is within about 2% of 6.18.64. See `docs/kernel7-cpu-scheduling.md`.
- [x] Mainline `r8169` for the NICs (same as 6.18 on `main`); real MACs on the first 7.3.5 boot with it.
- [x] Released as v2026.11.22 (pre-release).
- [x] `0053` confirmed on a boot where the storm would have happened (the bit was latched, cleared, no storm).
- [x] Proving run on the release build (with `0056`): 10/10 warm reboots, 3/3 cold boots, 8 h of full builds and
      `stress-ng --verify` (16/16 stress rounds, 15/16 builds; one 49 s build failure, cause unknown, log lost).
- [x] Released as **v2026.11.24** and made the default; 6.18.64 LTS stays available with `KERNEL_TRACK=6.18`.
- [ ] A 10 h run with per-cycle logs (running), and the cause of the one build failure if it repeats.
- [ ] CIX display drivers (`DRM_CIX`) port to the 7.x DRM APIs (off for now; headless board).
- [ ] Drop the debug patches `0050`, `0051` once the reboot and AER work is closed.

## Phase 2: NPU (working, 2026-11-22)
Details: [docs/npu.md](docs/npu.md).
- [x] No firmware needed. The Sky1 series' driver (CIX KMD 1.0.0) has an ABI no current user library speaks.
- [x] CIX's 6.2.0 driver replaces it on both tracks (`post/0012`, `7.3/0056`), with the Sky1 mainline DVFS/ACPI
      changes and a fix for buffer frees from `libaipudrv` 4.1.0.
- [x] Arm China's open `libaipudrv` 4.1.0 builds on the board (`scripts/npu-umd.sh`, `setup.sh npu`).
- [x] 7.3.5 (module swap, no reboot): probes, 3 cores, MobileNetV2 1.84 ms / 542 per second, sensible ImageNet labels.
- [x] 6.18.64 full build and boot: loads at boot, MobileNetV2 1.58 ms / 631 per second, same labels as 7.3.5.
- [ ] Check classification results against the ImageNet labels; more hub models (detection, segmentation).
- [x] Released in v2026.11.22.1 and v2026.11.23 (6.18.64). The 7.3.5 pre-release (v2026.11.22) keeps the old driver until its next build.

## Phase 3: bird recognition (planning, 2026-11-24)
Plan: [docs/bird-recognition.md](docs/bird-recognition.md).
- [ ] Hub CLIP graph with float embeddings, compared with FP32 CLIP on the CPU.

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
