# History

A running record of every patch, change, release and finding in this project, oldest first. It is updated with
every change (see [CONTRIBUTING.md](CONTRIBUTING.md)). Commit hashes refer to this repository; "Sky1 patches" means
[Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1) at commit `57e018a`.

Kernel lines:

| Line | Kernel | Where | State |
|---|---|---|---|
| 6.18.14 | kernel.org 6.18.14 + Sky1 patches (139) | `main` until PR #1 | released as **v2026.11.19**, superseded |
| 6.18 LTS | kernel.org 6.18.64 + Sky1 patches, 5 rebased, 4 post patches | `main` (PR #1) | released as **v2026.11.19.1** (current) |
| Kernel 7 | kernel.org 7.3.5 + our forward port of Sky1 patches-next (54 patches) | branch `kernel-7` | **experimental**, not released |

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
| Smart-plug workaround for lost NICs merged (needs RTC battery) | [2026-11-21](#2026-11-21-smart-plug-workaround-for-lost-nics-merged) |
| Board draws ~17 W idle and 30-36 W under load at the wall | [2026-11-20](#2026-11-20-power-draw) |
| Build-load crashes at 6000 MT/s track NVMe controller heat; an 8 h full-build run passes with a fan on the SSD | [2026-11-21](#2026-11-21-stability-at-6000-mts-nvme-heat) |
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

Branch `kernel-7`; details in `docs/KERNEL-7.md` there.

- `85cdb1d` `0055` sched/fair: scan the whole asymmetric-capacity domain on wakeup. 7.x added the SIS_UTIL
  `nr_idle_scan` limit to `select_idle_capacity()`. With 8 of 12 CPUs busy it stops the scan after about 6 CPUs
  counted from the wakeup target, so from cpu0/1 it picks an idle little core (cpu2-5) before it reaches the idle
  big cores. 6.18 scanned the whole domain, and `0055` restores that. `bench/sched-ab.sh` gains a `no-sis-util`
  variant.

**Findings:**
- Turning SIS_UTIL off at runtime on 7.3.5 confirmed the cause: 109.0/29.5 → 122.1/35.9 tok/s (pp512/tg128).
- 7.3.5 built with `0055` (`0abe703`): as booted 121.7/35.7, pinned to the big cores 121.3/35.9. That is within
  about 2% of 6.18.64 (123.5/36.5), so `taskset` is no longer needed. The same boot was the first 7.3.5 boot on
  `r8169`, and it came up with the real MACs and both NICs.

## Open items

- NPU (phase 2): the in-tree `armchina` driver already probes on the sky1 ACPI boot. Leads:
  visorcraft/orange-pi-6-plus-npu, Sky1-Linux/sky1-drivers-dkms.
- Kernel 7: confirm `0053` on a storming boot; CIX display drivers.
- Silent hangs under build load: likely NVMe controller heat (see 2026-11-21); confirm with a no-fan A/B run.
- RTC battery (CR2032 on JRTC1) to keep firmware settings across power loss.
