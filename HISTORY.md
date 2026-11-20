# History

A running record of every patch, change, release and finding in this project, oldest first. It is updated with
every change (see [CONTRIBUTING.md](CONTRIBUTING.md)). Commit hashes refer to this repository; "Sky1 patches" means
[Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1) at commit `57e018a`.

Kernel lines:

| Line | Kernel | Where | State |
|---|---|---|---|
| 6.18.14 | kernel.org 6.18.14 + Sky1 patches (139) | `main` until PR #1 | released as **v2026.11.19**, superseded |
| 6.18 LTS | kernel.org 6.18.64 + Sky1 patches, 5 rebased, 4 post patches | `main` (PR #1) | released as **v2026.11.19.1** (current) |
| Kernel 7 | kernel.org 7.3.5 + our forward port of Sky1 patches-next (49 patches) | branch `claude/project-thread-cxukj3` | **experimental**, not released |

## Quick index of findings

| Finding | Detail |
|---|---|
| Shipped V0.8 firmware is unstable at 6400 MT/s | [2026-11-18](#2026-11-18-memory-stability-and-firmware) |
| Sky1 patches power the GPU in ACPI mode; DT route not needed | [2026-11-18](#2026-11-18-gpu-works-in-acpi-mode) |
| Silent resets were a PCIe AER interrupt storm, not RAM | [2026-11-19](#2026-11-19-silent-resets-the-aer-storm) |
| Load tests at 6000 and 6400 MT/s pass with the AER fixes | [2026-11-19](#2026-11-19-load-tests-with-the-aer-fixes) |
| No RTC battery: every power loss resets firmware settings | [2026-11-19](#2026-11-19-no-rtc-battery) |
| NICs lost after a warm reboot need a ~30 s power cut | [2026-11-19](#2026-11-19-nic-link-training-after-warm-reboots) |
| Software GPIO power switch for the NICs is a dead end | [2026-11-19](#2026-11-19-nic-link-training-after-warm-reboots) |
| Kernel 7 warm reboot hangs at the watchdog | [2026-11-19](#2026-11-19-kernel-7-track-735) |
| Board draws ~17 W idle and 30-36 W under load at the wall | [2026-11-20](#2026-11-20-power-draw) |
| Fuzzy patching misplaced an arm_scmi hunk into a NULL dereference | [2026-11-19](#2026-11-19-kernel-61864-lts) |

---

## 2026-11-15: first plan, vendor image

- `1ea430d` Headless GPU/NPU image build script (`build-opi6-server.sh`) and notes: an Orange Pi vendor image with the
  CIX vendor kernel, built with `orangepi-build`.
- `2d4c1cc` Keep LF line endings so the build script runs on Linux.

**Finding (2026-11-16):** the vendor image did not boot. The plan was abandoned, and the CIX/Canonical vendor kernel
and the closed Mali stack (`cix-gpu-kmd` + `libmali`) were ruled out (closed userspace, no Vulkan). NCZ-OS (and its
older "Magnetar" installer) was ruled out too: RC kernel, Orange Pi 6 untested, vendor GPU stack, telnet/root logins
on by default.

New route: stock **Armbian generic UEFI arm64** (Ubuntu 26.04 userspace) on the NVMe, plus a separately built
kernel.org kernel with the Sky1 patches, installed beside Armbian's own kernel.

## 2026-11-17: mainline panthor, install tooling, boot logging

- `42f2e82` Switch to the mainline **panthor** GPU driver (first via a device-tree boot); non-Plus device tree
  `dts/sky1-orangepi-6.dts`.
- `7a396a7` Install: a real one-shot test boot, the exact kernel release, loud verification (`install.sh verify`).
- `fc8711f` Boot logging that works without a monitor: an initramfs logger writes the kernel log to a raw disk area
  before root is mounted (`install.sh bootlog`).
- `8b5fbb1` Drop stray bytecode; ignore `__pycache__`.
- `3f5347f` netconsole self-test sends at KERN_ERR so a quiet console log level still passes; avoid pipefail SIGPIPE.
- `baaa947` GRUB test entry saves `sky1_picked`, so the boot log shows whether GRUB booted it.
- `d22ef01` GRUB test entry records `sky1_stage` after each step, so a silent fallback shows where it failed.
- `cbae967` `SCREEN=1`: earlycon on the EFI framebuffer and `panic=0`, so an early crash stays on screen.

## 2026-11-18: GPU works in ACPI mode

Debug serial console set up on the 2x2 `DEBUG` header (UART2, 3.3 V, 115200 8N1).

- `12d9389` `SERIAL=1`: earlycon from SPCR/stdout-path, `efi=debug` and `panic=0` for serial-logged test boots.
- `d527352` `SERIAL=1`: explicit `earlycon=pl011,mmio32,0x040d0000`, since the firmware has no SPCR table.
- `9bd1e77` Boot logger: klibc `dd` rejects `conv=fsync`, so flush explicitly; verify runs the logger with the
  initrd's own tools; `SERIAL=1` makes ttyAMA2 the console.
- `85bb459` Build the initramfs with a clean environment: the toolchain's `LD_LIBRARY_PATH` packed libcrypto from the
  build tree, so modprobe/udevd failed and init exited. Verify that initrd programs run inside the initrd.
- `615d271` Pin the NIC MACs for r8125 under sky1: in ACPI mode the vendor driver can't read them and picks random
  ones. `.link` files match `Driver=r8125` + PCI path, and are inert under Armbian's r8169. `stage` must run from
  Armbian.
- `0a140f5` `gpu-test.sh`: no installs, timeouts, `glmark2-es2-drm` and headless `vkmark`, results to
  `/var/log/sky1-gpu-test.txt`.
- `a78c5d2` STATUS: GPU results.
- `f2c5e9d` sky1 is the **default boot** (`install.sh default` / `undefault`) with automatic fallback to Armbian:
  GRUB sets `sky1_pending`, `sky1-boot-report` clears it once userspace is up; if it is still set at the next boot,
  GRUB boots Armbian and sets `sky1_failed`. Both paths tested on the board.

**Finding:** with the Sky1 patches, the GPU is powered through SCMI in **ACPI mode**, so the earlier belief that
`acpi=off` + a device tree was required (as documented for the Plus) does not hold here. The DT route stays as an
optional test boot (`install.sh arm dt`).

**Result (6.18.14):** panthor 1.5.0, Mali-G720 MC10, CSF firmware v3.13, Ubuntu Mesa 26.0.8 (panvk Vulkan 1.4,
Panfrost GLES 3.1). glmark2-es2-drm 1591, vkmark 3460 (llvmpipe 741). vkpeak FP32 ~1.2 TFLOPS, FP16 2.1, INT8 4.86 TOPS.

### 2026-11-18: memory stability and firmware

**Finding:** the shipped firmware (OPI6BiosV0.8, 2026-04-27) was unstable at its default 6400 MT/s: 1227 corrected +
1 uncorrectable DDR ECC errors in 3 minutes of stress on stock Armbian, plus resets under load. The official
**2026-10-19 firmware** (`opi6_bios_image_20261019`, `bios_v1.0.bin`, flashed with FlashUpdate.efi) fixes it:
0 ECC errors at 5500, 6000 (its new Auto) and 6400, including a 4 h combined CPU+RAM+GPU soak at 6400.
Benchmarks are the same at every rate (llama.cpp CPU Qwen2.5-1.5B Q4 124/36.6 tok/s, 7B 33.7/8.75).
llama.cpp on panvk is slow (~1.7 tok/s) and prompt processing fails with `ErrorOutOfDeviceMemory`, so LLMs use the CPU.

## 2026-11-19: one-command install and release v2026.11.19

- `91fd57f` Benchmark and memory-soak scripts; firmware A/B report (`bench/MEMORY-AB-REPORT.md`).
- `5137910` `setup.sh`: one-command install (from source or `--prebuilt`); `package-release.sh`; INSTALL.md; README
  rewritten for the ACPI route.
- `7b922b3` `setup.sh check`: avoid pipefail/SIGPIPE false failures.
- **Release v2026.11.19** (tag on this commit): open GPU kernel 6.18.14-sky1, published 2026-11-19.
- Repository made public; its history was rewritten to remove private network details. Commit hashes in this file
  are the current ones (after this rewrite and the authorship rewrite below). The v2026.11.19 BUILDINFO records
  `8ec21bb` for `5137910`.

## 2026-11-19: kernel 6.18.64 LTS

Branch `lts-6.18`, merged to `main` as PR #1 (`c3300f0`).

- `95dc04d` `kernel.conf`: one file sets the kernel version and Sky1 track (6.18.64) for every script.
- `4b99163` Refreshed patches for 6.18.64 and **strict patching** (no fuzz; `ALLOW_FUZZ=1` only for experiments).
  134 of 139 Sky1 patches apply unchanged. Five are rebased with a 3-way merge in `patches/6.18.64/` and replace the
  upstream file of the same name:
  - `0011` irqchip/iommu/perf: Add CIX Sky1 support (merged without conflicts)
  - `0056` ASoC/ALSA: CIX Sky1 audio fixes (alc269 conflict resolved by hand)
  - `0065` treewide: ACPI device IDs for Sky1 peripherals (macb include conflict resolved by hand)
  - `0074` firmware: arm_scmi ACPI boot support (conflict resolved by hand)
  - `0118` iommu/arm-smmu-v3: ACPI boot-active bypass STEs (merged without conflicts)
- `1586344` `post/0001` irqchip/sky1-pdc, PCI: sky1: use the `struct syscore` API that 6.18.64 backported
  (`register_syscore`, callbacks take `void *data`). Without it the build fails.
- `7cf2771` `kernel.conf`: document `patches/$KV/post`.
- `2d76555` Keep older sky1 module trees until the new kernel passes `setup.sh check` (`install.sh prune`).
  Board test at this commit passed (native gcc 15.2): NVMe, all 3 PCIe links, both RTL8125 NICs, panthor/panvk/Panfrost;
  vkpeak FP32 1205 GFLOPS, vkmark 3544.
- `cef182e` `post/0002` net: r8125: don't report work from the "other" MSI-X vector at netpoll's budget of 0
  (removes the netconsole "exceeded budget in poll" warning at boot).
- `7212a09` `setup.sh --prebuilt` defaults to release v2026.11.19.1.
- `a7d845a` `post/0003` PCI: sky1: stop AER interrupt storms (port of kernel-7 `0045`).
- `323a39d` `post/0004` PCI: sky1: clear latched local errors on AER interrupts (port of kernel-7 `0049`).
- `45ff162` `sync` to disk after build and stage.
- `c9644cf` STATUS: load tests pass with the AER fixes; INSTALL: RTC battery note.
- **Release v2026.11.19.1** (tag on `323a39d`): Linux 6.18.64 LTS, 1,530 modules, published 2026-11-19. Replaces
  v2026.11.19.

**Finding:** fuzzy patching (`patch -F3`) silently put a `0074` arm_scmi ACPI hunk in the wrong place, where it would
dereference NULL at boot. That is why patching is strict.

### 2026-11-19: silent resets, the AER storm

**Finding:** two silent resets under `-j6` build load on 6.18.64 (at 6400 MT/s), with nothing on the serial console.
A later boot showed the cause: right after "waiting PHY is ready! retries = 1", the NVMe root port (`sky1-pcie.2`)
fired AER interrupts nonstop, about 62,000 log lines in 13 minutes, while every AER status register read zero. The
Sky1 driver masks a group of local link/PHY errors from their own interrupt, but they still latch, and only that
interrupt's handler cleared them. **The resets were caused by the AER storm, not by RAM.** The same storm hung the
first kernel-7 boot, and the fixes (`0045`, `0049` there; `post/0003`, `post/0004` here) come from that work.

**Finding:** a reset two minutes after a build left every `.ko` zero-length (ext4 delayed allocation). `install.sh
verify` caught it; build and stage now `sync` (`45ff162`).

### 2026-11-19: load tests with the AER fixes

**Finding:** with `323a39d`, 1 h of combined load (kernel build at `-j6`, then `stress-ng --vm 6 --cpu 6`) at
**6000 MT/s** and at **6400 MT/s**: 0 resets, 0 DDR ECC errors, no AER storm, peak 70 °C. RAM speed was not the cause.

### 2026-11-19: no RTC battery

**Finding:** the board ships without an RTC battery (BIOS manual §3.4), so every AC power loss resets the firmware
settings: memory speed goes back to Auto (6000) and "power on after power loss" goes back to off, so the board stays
off after a power cut. Fix: fit a **CR2032** holder on the 2-pin 1.0 mm **JRTC1** connector. Until then, 6400 MT/s
must be set again at the keyboard after each power loss, and unattended recovery by power cycling is not possible.

### 2026-11-19: NIC link training after warm reboots

**Finding:** the firmware sometimes fails PCIe link training for the two RTL8125 NICs after a warm reset (serial log
over 40 boots: 5 failures, both ports in Polling.Compliance, each right after a sky1 session; seen on both firmware
versions). Then there is no network at all, even on Armbian. The fix is a **~30 s power cut**.

**Finding (dead end):** the NIC 3.3 V rails are switched by GPIO038/039. Switching them from software through
`/dev/mem` under Armbian **froze the board** three times. `scripts/nic-power.sh` is kept as an experimental probe,
gated behind `NIC_POWER_EXPERIMENTAL=1`.

Workaround on branch `claude/project-thread-kimygu` (not merged): a smart-plug power cycle. `tools/plug-watch.ps1`
watches the serial log for "Link Up Fail" and runs `tools/plug-powercycle.sh` (at most 3 cycles an hour), which turns
the plug off and on through the Home Assistant REST API, with retries and a loud failure. No scripts or automations
live in Home Assistant itself. Credentials stay in a local config outside the repo.

## 2026-11-19: kernel 7 track (7.3.5)

Branch `claude/project-thread-cxukj3`, **experimental**, built from source only (no release). Details:
`docs/KERNEL-7.md` on that branch.

- `193c5c5` Linux 7.3.5 with a forward port of the Sky1 patches. Sky1-Linux has no 7.x set: its `patches-next`
  (43 patches, applies cleanly to v7.0-rc1) was cherry-picked onto v7.3.5; 26 picked cleanly and 17 had conflicts
  resolved by hand (all listed in `docs/KERNEL-7.md`; Panthor was a hand port). Exported as `patches/7.3/0001`-`0043`, with our
  `0044` for 7.x API changes (`pm_runtime_put()` returns void, xHCI latency masks, `strncpy`, part of the
  `drm_atomic_state` rename). The CIX display drivers (`DRM_CIX`) don't build on 7.x and are disabled.
- `e736ada` `0045` PCI: sky1: stop AER interrupt storms (returns IRQ_NONE for spurious interrupts, disables the line
  after 64 in a row, rate-limits AER logging). Fixed the hang on the first 7.3.5 boot; passed a board retest.
- `e3b74d8` `0046` misc: armchina-npu: drop IRQF_ONESHOT from a non-threaded IRQ (warning); `0047` hwmon: scmi:
  enable sensors by id and keep thermal zones; `0048` cpufreq: cppc: skip redundant perf requests (restores a Sky1
  behavior dropped in the port); `bench/cpu-diag.sh` for the CPU regression.
- `eb703c3` `0049` PCI: sky1: clear latched local errors on AER interrupts.
- `e3f4f9c` `sync` to disk after build and stage (same as `45ff162` on main).

**Findings:**
- 7.3.5 boots in ACPI mode with the GPU at parity, but CPU throughput is ~12-20% lower than 6.18: the scheduler
  places work on the little cores. Pinning recovers it.
- **A warm reboot from 7.3.5 hangs** after "watchdog0: watchdog did not stop!". 6.18.x reboots fine. Open.

## 2026-11-19: authorship cleanup

- History rewritten on every branch and tag so that each commit is authored and committed by jbuck2005, with no
  `Co-Authored-By` or other attribution trailers (they had listed a second contributor on GitHub). File contents are
  unchanged; only commit metadata and hashes changed. Tags `v2026.11.19` and `v2026.11.19.1` were moved to the
  rewritten commits, and the release assets are unchanged. The v2026.11.19.1 BUILDINFO records `f0c8401` for
  `323a39d`.
- CONTRIBUTING.md: commits carry no attribution trailers.

## 2026-11-20: power draw

- `tools/plug-power.py`: read-only power report from a smart plug's power sensor in Home Assistant (min, mean and max
  watts, and Wh, over a time window, or raw samples as CSV). It reads the sensor's history through the HA REST API,
  never switches the plug, and never prints the URL or token. Setup is a small JSON config (see the script header).

**Finding:** wall power (including the power supply), from the plug's once-a-minute readings: off ~1 W, idle ~17 W,
kernel build ~35 W, kernel 7 load test 30-36 W, hung after an ECC error ~23 W.

## Open items

- NPU (phase 2): the in-tree `armchina` driver already probes on the sky1 ACPI boot. Leads:
  visorcraft/orange-pi-6-plus-npu, Sky1-Linux/sky1-drivers-dkms.
- Kernel 7: warm-reboot hang at the watchdog; CPU regression; CIX display drivers.
- NIC warm-reboot link training: smart-plug workaround pending merge; a real fix would need the firmware.
- RTC battery (CR2032 on JRTC1) to keep firmware settings across power loss.
