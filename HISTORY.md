# History

A running record of every patch, change, release and finding in this project, oldest first. It is updated with
every change (see [CONTRIBUTING.md](CONTRIBUTING.md)). Commit hashes refer to this repository; "Sky1 patches" means
[Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1) at commit `57e018a`.

Kernel lines:

| Line | Kernel | Where | State |
|---|---|---|---|
| 6.18.14 | kernel.org 6.18.14 + Sky1 patches (139) | `main` until PR #1 | released as **v2026.11.19**, superseded |
| 6.18 LTS | kernel.org 6.18.64 + Sky1 patches, 5 rebased, 6 post patches | `main`, `KERNEL_TRACK=6.18` (the default until 2026-11-24) | released as v2026.11.19.1, then v2026.11.22.1 with the NPU driver, then **v2026.11.23** with .deb packages (the LTS alternative) |
| Kernel 7 | kernel.org 7.3.5 + our forward port of Sky1 patches-next (56 patches) | `main`, `KERNEL_TRACK=7` (merged 2026-11-22, **the default since 2026-11-24**; developed on branch `kernel-7`) | released as v2026.11.22 (pre-release), then **v2026.11.24** (the default, with the NPU driver and .deb packages) |

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
| Kernel 7 AER storm: an unacked LTSSM-transition bit; CPU gap is thread placement | [2026-11-21](#2026-11-21-kernel-7-aer-fix-cpu-placement-warm-reboots-into-armbian) |
| Kernel 7 CPU gap: wakeup scan cut short by SIS_UTIL; fixed by `0055` | [2026-11-22](#2026-11-22-kernel-7-cpu-gap-fixed) |
| Kernel 7.3.5 merged as an optional track; v2026.11.22 pre-release | [2026-11-22](#2026-11-22-kernel-7-merged-into-main-as-an-optional-track-release-v20261122) |
| Smart-plug workaround for lost NICs merged (needs RTC battery) | [2026-11-21](#2026-11-21-smart-plug-workaround-for-lost-nics-merged) |
| Board draws ~17 W idle and 30-36 W under load at the wall | [2026-11-20](#2026-11-20-power-draw) |
| Build-load crashes at 6000 MT/s track NVMe controller heat; an 8 h full-build run passes with a fan on the SSD | [2026-11-21](#2026-11-21-stability-at-6000-mts-nvme-heat) |
| NPU works on an open stack (CIX driver 6.2.0, libaipudrv 4.1.0); no firmware needed | [2026-11-22](#2026-11-22-npu-phase-started-driver-updated-to-cix-620) |
| Fuzzy patching misplaced an arm_scmi hunk into a NULL dereference | [2026-11-19](#2026-11-19-kernel-61864-lts) |
| Full-load crash: not memory rate, PSU, heat, HDA or deep idle | [2026-11-26](#2026-11-26-crash-tests-no-ddr-ecc-reports-not-the-hda-driver-not-deep-idle-not-the-memory-rate) |
| Full-load crash: Armbian's stock kernel fails too; missing CPU errata aren't the cause | [2026-11-27](#2026-11-27-rma-evidence-stock-kernel-fails-too-missing-cpu-errata-arent-the-cause) |
| Full-load crash needs the big A720 pairs above 2.4 GHz; workaround caps only those | [2026-11-27](#2026-11-27-crash-workaround-narrowed-to-the-big-a720-cores) |

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

Branch `kernel-7` (named `claude/project-thread-cxukj3` until 2026-11-21), **experimental**, built from source only (no release). Details:
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

## 2026-11-20: README brought up to date

- README rewritten as the project's landing page: a quick-start install path (firmware, Armbian, `setup.sh
  --prebuilt`), firmware and BIOS (`opi6_bios_image_20261019`, the Memory Data Rate path, 6000 and 6400 tested on
  6.18.64, Save & Exit), the missing RTC battery (JRTC1 2-pin 1.0 mm, no holder, non-charging: CR2032 on an SH1.0
  lead), hardware notes (r8125, the NVMe AER storm fix, power draw), results, known issues (NIC loss after a warm
  reboot, kernel 7 experimental), the debug serial console, and the roadmap (NPU next).
- INSTALL.md: the RTC battery note matches (no holder, non-charging, SH1.0 lead), and settings are saved with Save & Exit.

## 2026-11-21: random NIC MACs survive a warm reset

**Finding:** on one kernel 7 boot r8125 read an all-zero MAC, picked random ones, and the `.link` pins did not
apply. The random MAC then stayed in the NICs over the warm reset, so Armbian's r8169 read it as the NIC's own
address. `install.sh stage` builds the pins from what r8169 reads, so a stage run then would have pinned the random
address. A full power-off (~30 s) makes the NICs reload their factory addresses.

**Cause:** the pins never matched under sky1. There the NICs sit behind platform host bridges, so udev's ID_PATH
is `platform-sky1-pcie.3.auto-pci-0000:61:00.0`, not `pci-0000:61:00.0`, and 99-default.link applied instead
(hashed, locally administered MACs). Earlier boots only looked right because the NICs still held the real
address from the previous Armbian boot.

- `install.sh stage` refuses to pin a locally administered (random) MAC and says to power the board off for 30 s and
  stage again, and the pins match `Path=*pci-<address>` so they apply under sky1. Same change on the kernel 7 branch (`55f2f7b`).

## 2026-11-21: kernel 7 AER fix, CPU placement, warm reboots into Armbian

Branch `kernel-7`; details in `docs/KERNEL-7.md` there.

- `2b00a9e` `0050` (debug) markers in the arm64 restart and PSCI reset paths, with a warm-reboot test plan. Reboot
  test A then passed on 7.3.5 (`77c5308`), so the watchdog hang did not come back.
- `5f42bf0` `0051` (debug) dumps the PCIe AER and local error registers when an AER line is cut off; `f6a7895` `0052`
  re-enables a cut-off AER line after 2 s, up to 5 times.
- `59181e1` `0053` PCI: sky1: ack the LTSSM-transition indication (local error bit 31) that held the `aer_nf` line
  asserted. This was the AER storm's cause. Quiet boots since, not yet seen on a boot that would have stormed.
- `5306e16` `bench/thermal-log.sh`; `4b5e8fe`, `f355515`, `46ff62c` `bench/cpu-diag.sh` gains EAS-off and pinned
  variants, sched-domain and cache dumps, and per-thread CPU sampling; `628a0b1` `bench/sched-ab.sh`;
  `2cb8915`, `1c5a8b7` `bench/util-probe.sh`.
- `95fc193` `0054` sched/topology: restore the 6.18 rule that clears `SD_PREFER_SIBLING` on the child of an
  asymmetric-capacity domain. Flags now match 6.18.64, but the CPU gap is unchanged.
- `55f2f7b`, `b8f6ea8` the MAC guard and `Path=*` glob pins, as on `main`.

**Findings:**
- CPU, llama.cpp 1.5B Q4, 8 threads, 6000 MT/s: 6.18.64 123.5/36.5 tok/s (pp512/tg128), 7.3.5 109.8/30.1, 7.3.5
  pinned to the big cores 121/34.6. 1-4 threads sit on a little core while a big core idles. Ruled out: EAS, LLC
  balancing, the governor, memory bandwidth, the newidle features, misfit accounting, the domain flags, and frequency
  invariance (per-thread util and runtime match on both kernels). It shows only with prompt processing in the run,
  so wake placement is next. Workaround: `taskset -c 0,1,6-11`.
- Every warm reboot from a sky1 kernel into Armbian that night (9 of 9) failed NIC link training; SysRq over serial
  recovered each. Armbian into sky1 always trained. Suspect: the sky1 PCIe syscore shutdown hook.
- Silent hangs under build load happen on several kernels, including Armbian 6.18.45 at 6000 MT/s. Cause unknown.

## 2026-11-21: smart-plug workaround for lost NICs merged

The NIC power work from 2026-11-19 is now on `main`, squashed from its working branch.

**Changes:**
- `tools/plug-watch.ps1` watches the serial log on the PC and power-cycles the board through a local smart plug
  when the firmware reports `Link Up Fail` (at most 3 times an hour; `-Once` for a manual cycle). It drives a
  Shelly, a Tasmota plug or Home Assistant directly, or runs `tools/plug-powercycle.sh` on another host over ssh.
- `tools/plug-powercycle.sh` does one cycle from Linux (Home Assistant `switch.turn_off`, wait, `switch.turn_on`
  with retries and a loud failure; or Shelly/Tasmota). The HA token can sit in its own chmod 600 file, or be read
  as one variable from an env file (parsed, not sourced).
- Plug address, entity and token live in a config file outside the repo: `opi6-plug.json` next to the serial log
  (PowerShell) or `~/.config/opi6-plug.json` (Linux). No addresses or tokens are committed.
- `scripts/nic-power.sh` and `systemd/opi6-nic-recover.service` (software power cycle of the NIC rails through
  GPIO038/039) are included but **experimental and gated**: writing the GPIO block from Armbian froze the board twice.
- INSTALL.md and STATUS.md describe the workaround and that it needs an RTC battery: without one a power cut resets
  the firmware settings and the board stays off after the plug comes back on.

## 2026-11-21: keep PERST# released on a warm reboot (6.18.64)

- `post/0005` PCI: sky1: on a reboot, the syscore shutdown hook now only disables the controller interrupts and no
  longer asserts PERST# or cuts endpoint power. The PERST# GPIOs sit in the always-on domain, so the old hook left
  both RTL8125 ports in reset across the warm reset and the firmware's link training failed (LTSSM `0x40C80`).
  Power-off is unchanged. Boot option `sky1_pcie_reboot_perst=1` restores the old reboot behaviour for A/B tests.
  Board result: the first warm reboot from sky1 into Armbian still failed on both ports, so PERST# alone is not
  the cause.

## 2026-11-21: next warm-reboot suspects (6.18.64)

- `post/0006` net: r8125: boot option `r8125.reboot_shutdown=0` skips the NIC driver's shutdown hook on a reboot.
  Default unchanged. Tests whether the state the driver leaves in the NIC (which keeps power) breaks the firmware.
- `post/0007` PCI: sky1: (debug) logs the refclk strap register before and after the driver writes it at probe.
  The driver sets external-refclk, termination and divider bits there; if they survive a warm reset, the firmware
  trains with the wrong clock setup, which would fit a link stuck in Polling. Read-only.
- Board results: a SysRq reboot straight from sky1 (no shutdown hooks) also fails, so `0006` is moot; `pcie_aspm=off
  r8125.aspm=0` fails; undoing every NIC config difference from Armbian (I/O enable, LTR, MRRS, AER status) fails.
  The refclk strap reads the same before and after the driver's write, so it is not the cause either. A sky1 boot
  whose NIC links never came up reboots into Armbian fine, which points at state the controller init leaves behind.
- `post/0008` PCI: sky1: (debug) dumps the RCSU strap and status words at probe and before a reboot, to find it.
  Result: the strap words before a reboot match the firmware's; only status words differ (link state). So the
  state is in the controller or PHY, not the RCSU straps.
- `post/0009` PCI: sky1: on a reboot, takes the x2/x1 ports (the NICs) down like the suspend path does (PME_Turn_Off,
  link disable, PERST#, PHY off, clocks off, endpoint power off). `sky1_pcie_reboot_reset=0` turns it off, `=2`
  applies it to all ports. Board result: FAILED at 1 and 2 (clean teardown, training still failed). Dropped.
- A sky1 boot with r8125 kept from loading (`initcall_blacklist=rtl8125_init_module`) reboots into Armbian fine,
  also with SysRq-b. So the bad state is something the r8125 driver leaves in the NIC chip, which keeps power
  through a warm reset. (Every boot after a failed training also trains, which had made the controller look guilty.)
- `post/0010` net: r8125: saves each EPHY (the chip's PCIe PHY) register before the driver first writes it and
  writes back any changed ones on a reboot, logging each. `r8125.reboot_ephy_restore=0` skips it. Board result:
  FAILED, and no EPHY register had changed. The NICs are RTL8125B (rev 05, XID 641).
- With r8125 loaded but the NICs never opened (network services masked), the reboot still failed, so the state is
  set at probe (hardware init, MCU code), not at open. `post/0011` (`r8125.no_mcu=` to skip the MCU code) was built
  for a bisect but not run, once the r8169 test passed.

## 2026-11-21: mainline r8169 for the NICs; warm reboots fixed

- The sky1 kernel now uses mainline `r8169` (+ `REALTEK_PHY`, firmware `rtl_nic/rtl8125b-2.fw` from linux-firmware)
  for the RTL8125B ports instead of Realtek's `r8125`. `NIC_DRIVER=r8125 scripts/02-fetch-patch.sh` still builds
  the old way. No earlier sky1 build had used `r8169`; Armbian's kernel does.
- Board result: 5 of 5 warm reboots trained both ports (3 plain sky1 -> Armbian, 1 SysRq-b, 1 sky1 -> sky1). Real
  MACs without pins, 1 Gbit/s link, ~941 Mbit/s each way. Reports put `r8125` ahead at 2.5 Gbit/s (multi-queue);
  noted in README/INSTALL.
- `install.sh`: MAC `.link` pins only for an `r8125` build; with `r8169`, `stage` removes old pins and `verify`
  checks none are left. `verify` accepts either driver as built in.
- Branch `kernel-7`: the same `r8169` default and MAC-pin handling ported (`1000f0a`, `dd2b957`). `KERNEL-7.md` there
  had kept `r8125` on the untested assumption that `r8169` could not run in this ACPI setup. Not yet booted on 7.3.5.
- `docs/nic-r8125-vs-r8169.md`: the symptom, every test and what it ruled out, MAC behaviour under each driver,
  the r8169 results, caveats (2.5 Gbit/s, `NIC_DRIVER=r8125`) and open questions. Linked from the README.
- The debug and r8125-only experiments `post/0006`-`0010` are dropped (`0009` already was). `post/0005` stays: it
  was in the tested build and only keeps PERST# released on a reboot.

## 2026-11-21: stability at 6000 MT/s; NVMe heat

Firmware v1.0_for_opi6_linux (2026-10-19), memory at 6000 MT/s unless noted. The test SSD is a Kingston NV3
(SNV3S1000G, DRAM-less, no heatsink) in the M.2 slot, which gets no airflow on a bare board.

- Two failures at 6000 under build load, both during a **full from-scratch build** (fresh `linux-sky1` clone,
  kernel tarball unpack, ~150 patches, then `-j6`), which is the heaviest NVMe I/O we run:
  - 2026-11-20: Armbian's own 6.18.45 hung silently about 25 minutes into such a build (wall power flat at ~23 W,
    no network, no serial output).
  - 2026-11-21: sky1 6.18.64 panicked about 2 minutes into one: `Unable to handle kernel paging request` in
    `percpu_ref_get_many` <- `charge_memcg` <- a page fault in `cc1`, i.e. a corrupt pointer. The firmware reported
    no DDR ECC error.
- The NVMe's controller sensor ("Sensor 1" in `nvme smart-log`) reached **97-100 C** during builds, and about 83 C
  idle. The composite temperature stayed around 60 C (warning 75 C, critical 80 C), and the drive logged no
  thermal throttling, so the drive itself never flagged it. Tilting the board for convection made no difference.
- 5500 MT/s, no SSD cooling: the full build plus 30 minutes of `stress-ng --vm 6 --vm-bytes 60% --verify --cpu 6`
  passed.
- 6000 MT/s, no SSD cooling, `bench/stability.sh` (clean rebuilds of an unpacked tree, i.e. light I/O, alternating
  with 10-minute verified `stress-ng` rounds), Armbian's kernel: **4 hours, 7 of 7 cycles passed**.
- 6000 MT/s with a small blower fan on the SSD, `bench/stability.sh FULL=1` (the full from-scratch build pattern
  that had failed, alternating with verified `stress-ng`), Armbian's kernel: **8.4 hours, 15 of 15 builds and 14 of
  14 stress rounds passed**, no panic, oops or DDR ECC line on the serial console. The controller sensor peaked at
  52-63 C depending on fan speed (averages 48-52 C), the composite at 44 C, the board at 44 C.
- Conclusion: the failures line up with an overheating NVMe controller under heavy I/O, not with the memory rate.
  Not proven (that needs the same full-build run without the fan), but 6000 MT/s is stable here once the SSD is
  cooled. INSTALL.md now recommends a heatsink or airflow on the SSD.
- `bench/stability.sh`: the multi-hour run. It logs every step to `~/stability.log` and to the kernel log, so the
  record survives on a serial capture if the board dies.

## 2026-11-22: kernel 7 CPU gap fixed

Branch `kernel-7`. The full write-up is [docs/kernel7-cpu-scheduling.md](docs/kernel7-cpu-scheduling.md); board logs and
the step-by-step results are in `docs/KERNEL-7.md` on `kernel-7`.

**Symptom:** llama.cpp on the CPU (Qwen2.5 1.5B Q4, 8 threads) ran 109.8/30.1 tok/s (pp512/tg128) on 7.3.5, against
123.5/36.5 on 6.18.64. Pinned to the big cores, 7.3.5 reached 121.0/34.6. Thread sampling showed 1-4 of the 8 threads
on the little cores (cpu2-5, capacity 279) while big cores idled. One slow thread holds up all 8 at every barrier,
so the cost was much larger than one eighth.

**Ruled out first** (runtime toggles in `bench/cpu-diag.sh` and `bench/sched-ab.sh`, or test builds): energy-aware
scheduling, 7.x cache-aware balancing, the cpufreq governor, memory bandwidth and clocks, topology and capacities, the
newidle-balance features `NI_RATE` and `NI_RANDOM`, misfit accounting, the CLS `SD_PREFER_SIBLING` flag (`0054`, kept:
it makes the domain flags match 6.18.64, but did not change speed), and frequency invariance (`bench/util-probe.sh`:
per-thread util and runtime equal on both kernels). Token generation alone showed no misplacement, so the problem
was in the wakeup path, which prompt processing exercises far more.

**Cause:** 7.x applies the SIS_UTIL `nr_idle_scan` hint to `select_idle_capacity()`, the scan that picks an idle CPU
for a waking task when CPUs differ in capacity. With 8 of 12 CPUs busy the hint is about 6. The scan walks CPUs in
number order from the wakeup target and stops after six. The threads' util (~900) fits no CPU within the 80% margin,
so the scan returns the highest-capacity idle CPU it saw. From cpu0/1 the next CPUs are the little cpu2-5, so the
idle big cores 6-11 are never reached. The limit reaches this scan only because the firmware's PPTT makes one MC domain
both the last-level-cache domain and the asymmetric-capacity domain. 6.18 always scanned the whole domain.

- `85cdb1d` `0055` sched/fair: scan the whole asymmetric-capacity domain on wakeup (removes the limit from
  `select_idle_capacity()` only; `select_idle_cpu()` keeps it).
- `bench/sched-ab.sh` gains a `no-sis-util` variant and takes variant names as arguments; `bench/util-probe.sh` gains
  `pp` and `both` modes. These, and `bench/cpu-diag.sh`, are now also on `main`.
- README: kernel 7 known issues updated.

**Results** (6000 MT/s, NVMe fan on, pp512/tg128 tok/s):

| Kernel / setting | Result |
|---|---|
| 6.18.64 as booted | 123.5/36.5 |
| 7.3.5 before the fix, as booted | 109.04/29.49 (threads on cpu2-5 in 4 of 4 samples) |
| 7.3.5 before the fix, pinned to the big cores | 121.4/34.7 |
| 7.3.5 before the fix, SIS_UTIL off at runtime | 122.06/35.88 (1 of 3 samples, one thread on cpu5) |
| 7.3.5 + `0055` (`0abe703`), as booted | 121.67/35.70 |
| 7.3.5 + `0055`, pinned to the big cores | 121.33/35.87 |
| 7.3.5 + `0055`, nollc / noeas / perf governor | 121.28/35.70, 121.37/35.65, 124.22/36.64 |

As booted now matches pinned and is within about 2% of 6.18.64, so `taskset -c 0,1,6-11` is no longer needed. With
`0055`, one thread still often shows on cpu2/3 in a sample, at no measurable cost: short visits when every big core is
busy at the moment of a wakeup. The same build was the first 7.3.5 boot on the mainline `r8169` driver, and both NICs
came up with their real MAC addresses.

## 2026-11-22: kernel 7 merged into main as an optional track; release v2026.11.22

The kernel 7 work (branch `kernel-7`) is merged into `main`. `main` now carries **two kernel tracks**, chosen with
`KERNEL_TRACK` (see `kernel.conf`):

| Track | Kernel | Patches | Default `--prebuilt` release |
|---|---|---|---|
| `6.18` (default) | kernel.org 6.18.64 LTS | Sky1-Linux `patches/` + `patches/6.18.64/` | v2026.11.19.1 |
| `7` | kernel.org 7.3.5 | this repo's `patches/7.3/` (55 patches) | v2026.11.22 |

**Why 6.18.64 stays the default:** it has days of board time, 1 h load tests at 6000 and 6400 MT/s, and many
boots. The final 7.3.5 build has one boot. Earlier 7.3.5 builds passed a 1 h load test at 6000 MT/s
and a warm reboot test, and performance now matches 6.18.64. But the AER storm fix `0053` has not yet been seen on a
boot that would have stormed, the CIX display drivers are off on 7.x, and two debug patches are still in the series.
7.3.5 is therefore offered as an option and released as a **pre-release**, so v2026.11.19.1 stays the "Latest"
release.

Changes in the merge (the merge keeps `main`'s versions of everything both branches touched, and adds the kernel 7
pieces on top):
- `kernel.conf`: a `case` on `KERNEL_TRACK` sets `KV`, `SKY1_PATCHES`, `SKY1_CONFIG`, `SKY1_REFRESHED`,
  `LOCAL_PATCHES`, `KCONFIG_EXTRA` and `RELEASE_TAG_DEFAULT`. The 6.18 values are unchanged, so existing installs build
  and update exactly as before. Without `KERNEL_TRACK`, the track recorded by the last `setup.sh stage` in
  `$WORK/.kernel-track` is used, so `setup.sh check` and later runs stay on the installed track. An unknown track
  stops with an error.
- `scripts/lib-patch.sh`: one function for both tracks: the linux-sky1 series with refreshed and post patches (6.18),
  or this repo's `patches/7.3/` (7). Strict on both (no fuzz unless `ALLOW_FUZZ=1`).
- `scripts/02-fetch-patch.sh`: applies the track's `KCONFIG_EXTRA` (7 turns `DRM_CIX` off).
- `scripts/setup.sh`: release tag per track; the step markers of the 6.18 track keep their names, other tracks add
  their kernel version (`$WORK/.setup-7.3.5-*`), so the two tracks don't skip each other's steps; `KERNEL_TRACK` is
  passed through `sudo` to `install.sh`. Switching an installed board: boot Armbian, then
  `FORCE=1 KERNEL_TRACK=<track> scripts/setup.sh [--prebuilt]`.
- `scripts/install.sh`: `EXTRA_CMDLINE` for one-shot debug boots (never the default entry), from `kernel-7`.
- `scripts/package-release.sh`: `BUILDINFO` names the local patch set and config changes for the 7 track.
- Added from `kernel-7`: `patches/7.3/` (`0001`-`0055`), `docs/KERNEL-7.md`, `bench/thermal-log.sh`.
- README, INSTALL and STATUS: the kernel 7 option, how to install and switch, and its known issues.

**Release v2026.11.22** (pre-release): `sky1-kernel-7.3.5-sky1-v2026.11.22-arm64.tar.xz`, the matching patched source,
and `SHA256SUMS`, packaged from the board's native build of `kernel-7` at `0abe703` (identical patches to `main`'s
`patches/7.3/`), built natively with the board's Ubuntu gcc at `-j6` in 22 minutes (the exact compiler is in `BUILDINFO`).

## 2026-11-22: no host names in the repo

- `bench/ab-test.sh`, `bench/soak.sh`: they reached the board through fixed host names. They now take `BOARD` (the
  board's ssh host, default `opi6`) and an optional `JUMP` host.
- Comments in `bench/` and the default log path of `tools/netconsole-listener.py` (now `~/opi6-netconsole/`) no
  longer use the board's local name.
- The GitHub repository description now says "built on device".

## 2026-11-22: NPU phase started, driver updated to CIX 6.2.0

Research (no board changes):
- The NPU is an Arm China Zhouyi X2 (architecture v3): ACPI device `CIXH4000`, 3 cores, behind the SMMU. Both of our
  kernels already build the Sky1 series' `armchina-npu` driver, and it probes on the ACPI boot (`/dev/aipu`,
  "ZHOUYI V3 AIPU", devfreq present).
- **No firmware is needed.** None of the driver versions loads a firmware file; the compiled model graphs carry the
  NPU code. The `armbian-firmware-full` hold doesn't matter for the NPU.
- The Sky1 series' driver is an old CIX build (KMD 1.0.0). Its ioctl ABI (32 ASID bases in `struct aipu_cap`, no
  `exec_id`, no DMA-buf bind) does not match current user space. Arm China's open user-mode library
  ([Compass_NPU_Driver](https://github.com/Arm-China/Compass_NPU_Driver) `libaipudrv` 4.1.0, Apache-2.0) and CIX's
  NOE 3.1.2 both expect the CIX 6.x driver. Arm China 4.2.0 and later changed the ABI again, so 4.1.0 is the
  matching release.
- CIX's 6.2.0 driver ([cix_opensource__npu_driver](https://github.com/cixtech/cix_opensource__npu_driver), branch
  `cix_mainline_dev`, GPL-2.0) supports ACPI and is Arm China's 4.1.0 driver plus a Sky1 layer. The 4.1.0 library
  with CIX's 6.2.0 driver is shown working on Sky1 under FreeBSD by
  [JamesKane/aipu-umd](https://github.com/JamesKane/aipu-umd).
- Models: precompiled `.cix` graphs from CIX's model hub on ModelScope. The compiler (CixBuilder/Compass) is closed
  and x86-only, needed only for custom models. CIX's `libnoe` and ONNX Runtime provider are closed and optional.

Change:
- `patches/6.18.64/post/0012` and `patches/7.3/0056` (same driver on both tracks): replace the driver with CIX 6.2.0.
  `sky1/sky1.c` is CIX's file with the Sky1 series' mainline changes kept (DVFS through the OPP core instead of the
  SCMI genpd's private struct; under ACPI the `perf` domain attached by index). `v3_1` is replaced by `v3_2`
  upstream. Compile-tested by cross-building the module against both patched trees (no errors; every undefined
  symbol is exported). Not yet booted.
- `scripts/npu-umd.sh`: builds Arm China's `libaipudrv` 4.1.0 (pinned commit `f35bac0`) natively and optionally
  installs it to `/usr/local`. `-Werror` is dropped from its Makefile (newer g++ warns about hidden overloads).
  Cross-built cleanly in the cloud.
- `tools/npu-run.cpp`: `info` (driver versions, partitions, cores), `bench` (load a `.cix` or ELF graph, time N runs)
  and `classify` (one float32 input, quantized with the graph's scale and zero point, top 5).
- `tools/npu-prep.py`: image to the float32 NCHW input `classify` reads (ImageNet resize, crop, normalise).
- First board test (7.3.5, module swap, no reboot): the 6.2.0 driver probes ("AIPU KMD (v6.2.0)", 1 partition,
  1 cluster, 3 cores, 4 TECs each, custom per-ASID IOVA), `npu-run info` reports target `X2_1204MP3`, UMD 6.0.0,
  KMD 6.2.0. CIX's MobileNetV2 graph (s8 in/out): **1.89 ms mean, 529 runs/s** over 200 runs. Every buffer free
  failed at teardown ("V3: invalid PA ... for ASID 48"): `libaipudrv` 4.1.0 leaves `asid` unset in its free request
  and the custom-IOVA path trusted it. Fixed in `0012`/`0056`: the ASID slots don't overlap, so the free takes the
  ASID from the PA when the given one doesn't hold it.
- Second board test (7.3.5, fixed patch): 0 UMD errors and no driver errors; MobileNetV2 1.84 ms mean, 542 runs/s;
  3 of the 5 ImageNet validation images in the model's `test_data/` classify into one family each (snakes, birds, dogs).
  The hub has no YOLO graphs.
- Third board test, the default track: a full 6.18.64 build from `npu` (145 patches exact, `0012` added, 21 min at
  `-j6`), staged from Armbian, one-shot boot. The driver loads at boot ("AIPU KMD (v6.2.0)", 3 cores); NICs up with
  real MACs. MobileNetV2 1.58 ms mean, **631 runs/s**; the same top 5 as on 7.3.5; 0 library or driver errors.
- `scripts/setup.sh npu` (optional step on the sky1 boot): checks the driver is 6.2.0, installs `libaipudrv`, installs
  `npu-run`, prints `npu-run info`. `setup.sh check` reports the NPU driver version (warning only).
- `docs/npu.md`, and the NPU in README, INSTALL and STATUS.
- `bench/npu-bringup.sh`: test on a running sky1 kernel without a reboot: patch the driver into the existing build
  tree, build and swap only the module, build the library and `npu-run`, fetch MobileNetV2 and YOLOv8n from the
  model hub and benchmark them.

## 2026-11-22: release v2026.11.22.1 (6.18.64 with the NPU driver)

- **Release v2026.11.22.1** (the new default, replaces v2026.11.19.1 as "Latest"): `sky1-kernel-6.18.64-sky1-v2026.11.22.1-arm64.tar.xz`,
  the matching patched source and `SHA256SUMS`, packaged from the board's native build of `npu` `7a835ef`, whose
  kernel inputs (patches, `kernel.conf` track settings, fetch/patch/build scripts, DTS) are identical to `main`
  `be8067b`. That build is the one tested above: the NPU driver loads at boot, MobileNetV2 at 631 runs/s.
- Since v2026.11.19.1 the 6.18 kernel also gained mainline `r8169` for the NICs (PR #9) and `post/0005` (PERST# kept
  released on warm reboot).
- `kernel.conf`: the 6.18 track's `RELEASE_TAG_DEFAULT` is now v2026.11.22.1, so `setup.sh --prebuilt` installs it.
- The 7.3.5 pre-release v2026.11.22 is unchanged and has the old NPU driver; `setup.sh npu` refuses it. Its next build
  (with `0056`) can come with the remaining kernel 7 work (more boots, a long load run).
- README, INSTALL, STATUS and `docs/npu.md` name the release.

## 2026-11-22: kernel 7 with the NPU, first boot

- A full 7.3.5 build from `main` at `6934fdf` (`KERNEL_TRACK=7`, 56 patches exact, `0055` scheduler fix and `0056`
  NPU driver included, `CONFIG_ARMCHINA_NPU=m`, `r8169`), 22 minutes at `-j6`, staged from Armbian, one-shot boot.
- NPU: the 6.2.0 driver loads at boot ("AIPU KMD (v6.2.0)", 3 cores, `/dev/aipu`); `npu-run info` reports
  `X2_1204MP3`, UMD 6.0.0, KMD 6.2.0. MobileNetV2: 1.78 ms mean, 562 runs/s over 200 runs (6.18.64: 1.58 ms,
  631/s). The three test images give the same top 5 as on 6.18.64. 0 library errors, 0 driver errors.
- NICs: both up on `r8169` with their real MACs. The warm reboot from 6.18.64 into Armbian before staging trained
  both ports.
- AER: this boot hit the condition `0053` fixes, for the first time on the board. The NVMe root port logged
  "aer_nf: LTSSM transition indication latched (ltssm status 0xff000008, axi ctrl 0x00000000), cleared" four times
  at 5.8 s, and then nothing: no spurious-interrupt or "disabling it" lines. So `0053` acks the bit and the storm
  never starts.

## 2026-11-23: README brought up to date

- README: a "What works" table (CPU/NICs, GPU, NPU, display); the NPU in the stack summary (CIX 6.2.0 driver,
  `libaipudrv` 4.1.0, no firmware, hub models, closed compiler only for custom models); `setup.sh npu` in the quick
  start; a releases table (v2026.11.22.1 Latest and the `--prebuilt` default, v2026.11.22 pre-release with the old
  NPU driver); NVMe cooling and the NPU under hardware notes; NPU results for both kernels (631/s and 562/s); kernel 7
  known issues updated after the 2026-11-22 boot (`0053` caught the condition once, no long run yet on the build with
  `0056`); NPU model limits as a known issue; roadmap marks the NPU phase done.
- `docs/npu.md`: status line and results table mention the 7.3.5 full build from `main`.

## 2026-11-23: debug header diagrams

- `docs/images/debug-header-location.svg`: the top side of the board drawn to scale (90 x 90 mm) with every
  connector, and the 2x2 `DEBUG` header circled just below the left network jack. Positions are measured from Orange
  Pi's published board photos; the underside connectors are listed in the caption.
- `docs/images/debug-header-pinout.svg`: the header's pinout (RX and TX on the row nearest the jack, GND on the far
  row) and the wiring to a 3.3 V USB-serial adapter (TX and RX crossed, adapter VCC unconnected).
- Both are drawn for this repository (no vendor images) and shown under "Debug serial console" in README and INSTALL.

## 2026-11-23: .deb packages

- `scripts/package-deb.sh`: the kernel as a Debian package per track, `orangepi6-kernel-6.18` (6.18.64-sky1) and
  `orangepi6-kernel-7` (7.3.5-sky1), which conflict with each other, and the NPU user library and `npu-run` as
  `orangepi6-npu` (libaipudrv 4.1.0 in `/usr/lib/aarch64-linux-gnu`, headers in `/usr/include/aipu`). Versions are
  `<kernel>-<tag>-<revision>`, e.g. `6.18.64-2026.11.22.1-1`. The build script and `setup.sh --prebuilt` stay.
- The kernel package's postinst runs `install.sh stage` and `default` from a copy of the scripts in
  `/usr/share/orangepi6`, so a package install is the same as `setup.sh`: `/boot/sky1`, private initramfs, every
  verify check, "Sky1 (acpi)" as the GRUB default with Armbian as entry 0 and the fallback. Not `make bindeb-pkg`,
  which installs into `/boot` and would bring back Armbian GRUB entries for the sky1 kernel. Removal hands the
  default back to Armbian. `orangepi6-check` runs `setup.sh check`.
- `install.sh`: `SKY1_PKG=1` mode for the postinst (modules already unpacked by dpkg, no build environment).
- `package-release.sh` adds the kernel and NPU packages to each release and to `SHA256SUMS`.
- `package-deb.sh from-release` repacks a published release tarball; the 6.18 and 7 packages for v2026.11.22.1 and
  v2026.11.22 build this way (29 MB and 30 MB).
- Board test (from Armbian 6.18.45, over a source-installed kernel): `apt install` of the 6.18 and NPU packages
  passes stage, every verify check and default; Armbian stays entry 0. The warm reboot came up on 6.18.64-sky1 by
  default, boot confirmed, NICs with their real MACs; `orangepi6-check` passes (panthor, panvk, Panfrost, NPU driver
  6.2.0) and `npu-run info` reports X2_1204MP3, UMD 6.0.0, KMD 6.2.0. Installing the 7 package while running 6.18.64
  failed: apt removes the old package with a plain `remove`, and the prerm refused the running kernel. The prerm now
  warns instead (as Debian's kernel packages do), and the second verify run in the postinst is skipped.
- Retest on the board with the fixed packages: from 6.18.64-sky1, `apt install` of the 7 package removes the 6.18
  package (with the warning), stages 7.3.5 and makes it the default; installing the 6.18 package switches back the
  same way. Armbian stayed entry 0 throughout, `/lib/modules` ends with only Armbian's and 6.18.64-sky1, `dpkg --audit`
  is clean, and after a warm reboot `orangepi6-check` passes. dpkg runs the installed package's own prerm, so the
  board's first (same-version) package had to be reinstalled first. Versioning (James): every package version ends in the
  release tag plus a Debian revision, `6.18.64-2026.11.22.1-1`; a rebuild of the same tag with changed packaging takes
  `DEB_REVISION=2`, 3, ... and upgrades over the earlier build.
- Retest with the revision: over the first test package, `apt install` of the `-1` 6.18 and NPU packages upgrades
  ("2 upgraded"), then 6.18 -> 7 -> 6.18 switches without `--reinstall`; `dpkg --audit` clean, `orangepi6-check`
  passes after a warm reboot. The GRUB check line printed twice is the generated and then the installed grub.cfg;
  it now says which.
- `docs/packages.md`; INSTALL points to it; README has a "Building for distribution" section with the full
  command sequence for the release assets, .deb packages included.

## 2026-11-23: release v2026.11.23 (6.18.64 as .deb packages)

- Release **v2026.11.23** (Latest), at `main` `0dd12fb`: the same 6.18.64 kernel as v2026.11.22.1 (the kernel inputs
  are identical; packaged again from the board's build in `~/sky1-build`), now with the .deb packages next to the
  tarballs. `package-release.sh` wrote all of the assets and checked that the shipped source is the one that was built:
  - `orangepi6-kernel-6.18_6.18.64-2026.11.23-1_arm64.deb`
  - `orangepi6-npu_4.1.0-2026.11.23-1_arm64.deb`
  - `sky1-kernel-6.18.64-sky1-v2026.11.23-arm64.tar.xz` and `linux-6.18.64-sky1-v2026.11.23-source.tar.xz`
  - `SHA256SUMS` covering all four
- Board check before publishing: `apt install` of both packages upgraded over the `-2026.11.22.1-1` builds ("2
  upgraded"), and every check passed with "Sky1 (acpi)" still the default. A download from the published release,
  without logging in, matched `SHA256SUMS`.
- `kernel.conf`: `setup.sh --prebuilt` on the 6.18 track now installs v2026.11.23. The 7.3.5 pre-release v2026.11.22
  is unchanged and has no packages; a kernel-7 package can be made from it with `KERNEL_TRACK=7 scripts/package-deb.sh
  from-release v2026.11.22`.
- README (releases table and examples), INSTALL, STATUS, `docs/npu.md` and `docs/packages.md` name the new release.

## 2026-11-23: stability runs keep every iteration's logs

- During the kernel 7 (7.3.5) overnight run, iteration 11's full build failed after 49 seconds (a normal full
  build takes about 21 minutes). Every other build and every stress round passed, and the kernel logged no
  errors. The run kept only the last 20 lines of the failure, ending in a `make` error after the DTB overlay steps,
  because each iteration overwrote the build log, so the cause is not known.
- `bench/stability.sh` now keeps everything: each iteration's `setup.sh` output, its `build.log` and `patch.log`
  (with `FULL=1`) and its stress output go to `~/stability-logs/<start time>/iter<N>-*.log`, and nothing is
  overwritten. The output is written there while it runs, so a hang or crash cannot lose it. `LOG_HOST=<ssh host>`
  also copies the logs off the board every 30 seconds and after each step.
- Its event lines go to the kernel log at level 3, so they also reach the serial console when the console
  loglevel is the quiet default (4). The earlier lines, at the default level, never reached it.

## 2026-11-24: kernel 7 proven on the board and made the default; release v2026.11.24

The proving run used the release build itself: 7.3.5 from `main` with `0055` (scheduler fix) and `0056` (NPU driver
6.2.0), installed from its .deb package (first as a local `~rc1` test build, then the release packages), at
6000 MT/s with the NVMe SSD cooled.
- **Warm reboots, 10 of 10:** each boot came up on 7.3.5 by default, with both RTL8125 ports trained and their real
  MACs. `orangepi6-check` passed, `npu-run` reported the NPU ready, and there was no AER storm and no kernel error.
  Two extra reboots made about 30 s after a boot fell back to Armbian: GRUB still saw `sky1_pending=1`, although the
  boot report had confirmed the boot. With 75 s between reboots it did not happen again. A known issue, not yet fixed.
- **Cold boots, 3 of 3:** each was a clean poweroff, a 30 s power cut at the smart plug, and the power button (the
  board doesn't power itself on without an RTC battery). The same checks passed each time, and memory trained at
  6000 MT/s.
- **8 hours of load** (`bench/stability.sh FULL=1`): all 16 stress rounds passed and 15 of 16 full builds passed. One
  build failed 49 s in; its log was lost (see "stability runs keep every iteration's logs" above). Peak temperatures:
  CPU 58 °C, NVMe controller 61 °C.
- The AER fix `0053` was seen working once, on 2026-11-22.

Change:
- `kernel.conf`: kernel 7 is the default track. `KERNEL_TRACK=6.18` selects 6.18.64 LTS. A board that is already set
  up keeps its track: the track recorded by the last `stage` (`$WORK/.kernel-track`) wins as before, and a board set
  up before tracks were recorded (6.18 step markers only) stays on 6.18.
- Release **v2026.11.24** (Latest), at `main` `b2b1b1c`: the 7.3.5 kernel tarball, its patched source,
  `orangepi6-kernel-7_7.3.5-2026.11.24-1_arm64.deb`, `orangepi6-npu_4.1.0-2026.11.24-1_arm64.deb` and `SHA256SUMS`,
  packaged from the board's build. Checked: `apt install` upgraded over the test packages, and the board rebooted
  into it with every check passing. A download from the published release, without logging in, matched
  `SHA256SUMS`. 6.18.64 stays available as v2026.11.23.
- README, INSTALL, STATUS, `docs/KERNEL-7.md`, `docs/packages.md` and `docs/npu.md`: kernel 7 as the default,
  6.18.64 LTS as the alternative.
- A 10-hour run on the release build, with per-cycle logs, started 2026-11-24.

## 2026-11-24: 10-hour run on the v2026.11.24 release build

- The release packages themselves (`orangepi6-kernel-7` 7.3.5-2026.11.24-1 and `orangepi6-npu` 4.1.0-2026.11.24-1),
  installed with `apt` and booted, at 6000 MT/s with the NVMe SSD cooled. `bench/stability.sh FULL=1 HOURS=10`, with
  every cycle's logs kept and copied off the board.
- **20 of 20** full from-scratch kernel builds (`-j6`, about 21 minutes each) and **19 of 19** `stress-ng --vm 6
  --verify --cpu 6` rounds passed ("passed: 12, failed: 0" each; the 20th cycle reached the time limit before its
  stress round). No oops, BUG or call trace in the kernel log, and no panic or DDR ECC report on the serial console,
  which this time also carried every progress line.
- Peak temperatures: CPU/SoC 56 °C; NVMe composite 41 °C, controller ("Sensor 1") 60 °C.
- The 49-second build failure from the 8-hour run did not recur.
- `bench/stability.sh`: the summary line of each stress round printed the failure count but not the pass count (the
  per-cycle stress log had both). Fixed; the stress log and the off-board copy are now written separately.

## 2026-11-24: scheduler regression reported upstream

- The kernel 7 CPU gap fixed by `0055` was reported to the Linux scheduler maintainers as a regression (LKML and the
  regressions list, 2026-11-24). It is caused by commit `61ea17a63719` ("sched/fair: Add SIS_UTIL support to
  select_idle_capacity()"), first in 7.2. `select_idle_capacity()` and `update_idle_cpu_scan()` are unchanged in
  7.4-rc4. `0054` (the `SD_PREFER_SIBLING` rule) made no difference and was not part of the report.
- **Correction:** `docs/kernel7-cpu-scheduling.md` said the limit only reached this board because its LLC and
  asymmetric-capacity domains are the same. That was wrong. Since 7.2 the asymmetric-capacity domain always gets
  `shared` data (`claim_asym_sched_domain_shared()`), so the limit applies on any big.LITTLE system. The doc is fixed.

## 2026-11-24: corruption crashes under full-chip build load

- Rebuilding the modules of a CIX-config kernel tree (4,443 modules, each post-processed by `pahole`) crashed the
  release kernel 5 times out of 5 at 6000 MT/s, cool and with the fan on: hard lockups, stack corruption, kernel
  Oopses (paging request, NULL, FPAC) and heap corruption in user-space tools.
- It follows total load: the little cores alone, the big cores alone at up to 2.5 GHz, and all 12 cores capped at
  1.8 or 2.2 GHz were clean; all 12 at 2.5 GHz or uncapped failed within 1 to 3 minutes. Likely a supply or voltage
  margin problem; not proven. Write-up: `bench/CRASH-ANALYSIS.md`; reproducer: `bench/crash-repro.sh`.

## 2026-11-25: upstream contributions, the 7.3.6 regulator bug, the SIS_UTIL candidate fix

- Issues and PRs sent upstream on 2026-11-24 and 2026-11-25:
  - cixtech/cix_opensource__npu_driver: issue #2 and PR #3 (V3 `AIPU_IOCTL_FREE_BUF` trusts `desc->asid`).
  - Arm-China/Compass_NPU_Driver: issue #5 (UMD frees with an uninitialised `aipu_buf_desc`).
  - Sky1-Linux/linux-sky1: PR #47 (AER storm fix), issue #48 (r8125 warm reboot), comment on #27 (the 7.3.5 port).
  - cixtech/cix-linux-main: PR #104 (regulator fix below), #103 (AER storm fix), #105 (scheduler stop-gap).
  - armbian/build: PR #11552 (the same three patches for its `cix-7.3` set).
- **Linux 7.3.6 breaks ACPI fixed regulators:** a new check at the top of `reg_fixed_voltage_probe()` rejects any
  device with no device-tree node that isn't named `reg-fixed-voltage`. Every ACPI `PRP0001` fixed regulator fails
  that check, so on this board the NVMe slot's power switch (`\_SB.PVC0`) never binds and a 7.3.6 kernel built from
  cixtech/cix-linux-main (and so Armbian's edge kernel) can't find the NVMe root. A one-line fix (let ACPI devices
  through) made it boot from NVMe; it's PR #104 / armbian #11552. Our own release is on 7.3.5 and isn't affected,
  but the next 7.3.y update will need the fix.
- CIX's 7.3 tree with our AER (4016) and scheduler (4017) patches, tested on this board: the AER patch runs on all
  three root ports (the storm didn't occur on that boot); llama-bench 121.9/35.9 tok/s, the same as 6.18.
- **SIS_UTIL candidate fix:** a maintainer's reply in the LKML thread scales `nr_idle_scan` up for small LLCs in
  `update_idle_cpu_scan()`. On 7.3.5 without our 0055, it gives 122.0/35.5 tok/s with SIS_UTIL on and 121.2/35.8 off
  (stock 109.0/29.5; 6.18 123.5/36.5). Tested-by sent to the thread. 0055 stays until a fix is merged.
- Full-load crashes (`bench/CRASH-ANALYSIS.md`): all 12 cores capped at 2.2 GHz passed 3 runs; test kernels in this
  work were built at that cap. A run with another power supply is next.

## 2026-11-25: AER storm guard rework after review

- Armbian's review bot (CodeRabbit) found two real edge cases in the AER storm guard (on #11552): one counter
  shared by the three AER lines, so a second storming line could slip past the exact-64 cut-off; and the re-arm
  work cancelled before the interrupts were disabled, so it could be queued again on suspend or remove. Fixed with
  a per-line guard and the stop order reversed: `patches/7.3/0057`, and updated in armbian/build#11552,
  cixtech/cix-linux-main#103 and Sky1-Linux/linux-sky1#47. Compile-tested; the storm path can't be triggered on
  demand. The next release build picks up 0057.
- Rule from now on: both kernel tracks get the same fixes in parallel. The 6.18 track had only the first two AER
  fixes, so `patches/6.18.64/post/0013` brings its AER handling to the same state as 7.3 (LTSSM-indication ack,
  register dump, burst-only counting with re-arm, and the per-line guard). Made by applying 7.3's 0051, 0052,
  0053 and 0057 to the 6.18 driver (offsets only, no fuzz); compile-tested on 6.18.64.

## 2026-11-25: patch parity audit between the two kernel tracks

Every fix of our own on one track, checked against the other (the Sky1-Linux base series differ by design and were
not compared):

| Fix | 6.18.64 | 7.3.5 | Result |
|---|---|---|---|
| AER storm fixes | `post/0003`, `0004`, now `0013` | `0045`, `0049`, `0051`-`0053`, `0057` | same since `post/0013` |
| r8125: no work at netpoll budget 0 | `post/0002` | missing | **ported** as `patches/7.3/0058` (applies unchanged, compile-tested; only used by `NIC_DRIVER=r8125` builds) |
| NPU driver 6.2.0 | `post/0012` | `0056` | same; the driver itself drops `IRQF_ONESHOT` on 7.x, so `0046`'s warning doesn't exist on 6.18 |
| syscore API | `post/0001` | in `0044` | same (each track's own kernel API) |
| SCMI hwmon sensor id | not needed | `0047` | the bug is in code added in 7.x; 6.18's driver has no sensor-config call |
| CPPC skip redundant requests | in the LTS series | `0048` | same (`0048` restores the LTS patch on 7.x) |
| Wakeup scan (SIS_UTIL) | not needed | `0055` | 7.2+ regression; 6.18 has no limit in `select_idle_capacity()` |
| `SD_PREFER_SIBLING` rule | 6.18 behaviour | `0054` | same (`0054` restores the 6.18 rule) |
| Reboot-path debug log | none | `0050` (DEBUG) | debug only, not ported; due to be dropped |
| PERST# kept released on warm reboot | `post/0005` | not carried | **dropped from 6.18** (see below) |

## 2026-11-25: PERST# warm-reboot patch dropped

- `post/0005` (keep PERST# released on a warm reboot, 2026-11-21) was a candidate fix for the NICs vanishing after
  a warm reboot. It didn't fix that (the cause was `r8125` at probe; `r8169` fixed it), and 7.3 never carried it.
  Dropped from the 6.18 track so both tracks behave the same on reboot; 7.3 has no equivalent code (its shutdown
  hook has no reboot special case). The boot option `sky1_pcie_reboot_perst=` goes with it.
- Board check: a 6.18.64 test kernel without it (with `post/0013`), 3 rounds of one-shot boot into it and a warm
  reboot out of it. Every time the firmware trained both NIC root ports ("Root Port 2/3: Link Up Success"), both
  RTL8125 ports were present on the next boot, and the cabled port came up. `post/0013` regenerated for the new base.

## 2026-11-25: full-load crashes don't follow the power supply

- A-B-A swap with the crash reproducer, uncapped: stock 100 W 5 of 5 failed (2026-11-24), a 65 W supply 3 of 5, the
  stock adapter again 2 of 5. An SSD heatsink fitted in between changed the SSD controller temperature by only a few
  degrees. So the crashes aren't caused by the external supply; memory or CPU voltage margin under full-chip load is
  still the lead. Details and the per-run table: `bench/CRASH-ANALYSIS.md`.

## 2026-11-26: firmware and kernel options for the full-load crashes (research)

- The stock firmware has no CPU voltage, power-cap or OPP settings. Decoding its `csu_pm_config.bin` shows the CPU
  rails get a +30 mV guard band (big and mid), the DSU and little rails are fixed regulators, and per-cluster power
  caps are 6.5-8 W. Raising the guard band needs a reflash, so it is the last resort.
- Similar reports: an Orion O6 at 6000 MT/s with the same `pahole`/BTF build failures (fixed there by a lower memory
  rate), and an MS-R1 whose build segfaults stopped after disabling `snd_hda_cix_ipbloq`. CIX's TF-A carries no
  A720/A520 errata workarounds.
- Ranked next tests (serial ECC lines, HDA driver blacklisted, deep idle off, a 5500 MT/s diagnostic run,
  `arm64.nomte`, asking Orange Pi / CIX, the reflash): `bench/CRASH-ANALYSIS.md`.

## 2026-11-26: crash tests: no DDR ECC reports, not the HDA driver, not deep idle, not the memory rate

- The firmware's `DDRC IRQ ECC` lines appear in the serial captures only during the 6400 MT/s and old-firmware tests
  (2026-11-18/19), never at 6000 MT/s, so never during the crashes.
- With `snd_hda_cix_ipbloq` blocked, the reproducer still failed 2 of 5 runs (a hard lockup, a heap corruption).
- With the deep idle states off, it failed 4 of 5, within about a minute (a hard lockup, broken BTF, heap corruption).
  Neither is the cause.
- At 5500 MT/s (diagnostic only, set back to 6000 afterwards) it failed 4 of 5, so it isn't the memory rate either.
  That leaves the CPU side under sustained full-chip load at full clock: voltage margin or CPU errata in the closed
  firmware, neither settable from Linux. The 2.2 GHz cap remains the only setting that never failed. Next: ask
  Orange Pi / CIX with the reproducer. Details: `bench/CRASH-ANALYSIS.md`.

## 2026-11-27: RMA evidence: stock kernel fails too; missing CPU errata aren't the cause

- Armbian's own stock kernel (6.18.45, none of our patches) failed the reproducer 4 of 5 times (three `Oops - FPAC`,
  one panic, one hang); our 6.18.64 release kernel 3 of 5. The failure follows the board, not our kernels.
- `stress-ng --verify` (cpu, matrix, vm) and memtester on all 12 cores passed with no errors.
- CIX's BL31 applies none of the A720/A520 errata workarounds (read on every core through a CIX SiP call). Setting
  them all at runtime didn't help (4 of 5 still failed). Details: `bench/CRASH-ANALYSIS.md`.

## 2026-11-27: crash workaround narrowed to the big A720 cores

- Per-cluster caps (release 7.3.5 kernel, 5 runs each): only the big pairs (cpu0-1 at 2.6 GHz, cpu10-11 at 2.5 GHz)
  capped at 2.2 GHz with everything else at full speed: 0 of 5 failed. Only the mid pairs capped with the big pairs at
  full speed: 4 of 5 failed (3 kernel panics). The failure needs the big cores at their top speeds, which share one
  regulator; this points at voltage margin on that rail.
- The workaround (README, INSTALL, release v2026.11.25 notes, `bench/CRASH-ANALYSIS.md`) now caps only
  `cpu{0,1,10,11}` at 2.2 GHz instead of every policy. It is a sysfs setting, the same on both kernel tracks.
  `bench/crash-repro.sh` gained `MAXF_CPUS` to cap only chosen CPUs.
- The big pairs capped at 2.4 GHz (the rest at full speed) also passed 5 of 5, so their edge is between 2.4 and
  2.5 GHz. The documented cap stays at 2.2 GHz until more runs back 2.4 GHz.
- The 16:41 UTC loss of network on the board was the network switch (rebooted), not the board.

## 2026-11-27: crash docs brought up to date

- `bench/CRASH-ANALYSIS.md` next steps: the 2.2/2.4/2.5 GHz edge, what is left to test, and the report to CIX
  (cixtech/bios#7 and its 2026-11-27 follow-up).
- `STATUS.md`: the kernel-7 10 h run marked passed (2026-11-24); a section on the full-load crash.
- README and INSTALL note that 2.4 GHz also passed; the advice stays at 2.2 GHz. Crash findings added to the
  index above; open items updated.

## 2026-11-27: the weak cores are cpu10-11, edge between 2.40 and 2.45 GHz

- Overnight sets on the release 7.3.5 kernel (all cores loaded): cpu0-1 at full 2.6 GHz with cpu10-11 capped,
  0 of 5 failed; cpu10-11 at full 2.5 GHz with cpu0-1 capped, 4 of 5 failed. Both pairs at 2.5 GHz failed 3 of 5,
  at 2.45 GHz 3 of 5, at 2.4 GHz 0 of 20. So one core pair (cpu10-11, policy10) lacks margin at its rated 2.5 GHz on
  this unit. Details: `bench/CRASH-ANALYSIS.md`. Next: cpu10-11 alone at 2.4 GHz as the lightest workaround.

## Open items

- NPU: check classification against ImageNet ground truth; more hub models.
- Kernel 7: the cause of the one 49 s build failure (not seen again in 20 builds); the
  quick-reboot fallback (`sky1_pending` still set after a confirmed boot); CIX display drivers; drop the debug
  patches `0050`/`0051`.
- Corruption crashes under full-chip load (`bench/CRASH-ANALYSIS.md`): not the external supply (A-B-A test); it
  needs the big A720 pairs at 2.5/2.6 GHz (edge between 2.4 and 2.5 GHz); find which pair is weak, a confidence run
  at 2.4 GHz, follow up with CIX on cixtech/bios#7, and decide whether to ship the cap as a boot setting. The
  earlier silent hangs under build load (2026-11-21, put down to NVMe heat) may be the same fault.
- Next 7.3.y kernel update: add the fixed-regulator ACPI fix (7.3.6 regression above) before moving past 7.3.5.
- Drop 0055 once a mainline SIS_UTIL fix lands; follow the upstream PRs and issues listed on 2026-11-25.
- RTC battery (CR2032 on JRTC1) to keep firmware settings across power loss.
