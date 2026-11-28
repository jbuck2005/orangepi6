# orangepi6

An open, low-effort Linux install for the **Orange Pi 6** (standard, non-Plus: 90x90 mm board, CIX P1 / CD8180,
Mali-G720, Zhouyi X2 NPU, 2x RTL8125), on stock Armbian with a mainline-based kernel and open GPU and NPU drivers.
One script takes a fresh Armbian install to a working GPU, NPU and network in about 15 minutes of hands-on time.

## What works
| | State | How |
|---|---|---|
| CPU, memory, NVMe, both 2.5 GbE ports | working | sky1 kernel, mainline `r8169` for the NICs |
| GPU (Mali-G720) | working, open | mainline `panthor` + Mesa (panvk Vulkan 1.4, Panfrost GLES 3.1) |
| NPU (Zhouyi X2, 3 cores) | working, open | CIX's 6.2.0 driver + Arm China's `libaipudrv` 4.1.0, installed with `setup.sh npu` |
| Display output | not tested | the board runs headless; on kernel 7 the CIX display drivers are off |

- **Base OS:** stock Armbian generic **UEFI arm64** image (Ubuntu 26.04 "resolute" userspace) on an NVMe SSD.
- **Kernel (default):** Linux **7.3.5** from kernel.org with this repo's forward port of the
  [Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1) patches ([patches/7.3/](patches/7.3/),
  [docs/KERNEL-7.md](docs/KERNEL-7.md)). It boots in the firmware's **ACPI** mode and matches 6.18.64 on the GPU,
  the CPU and the NPU. The version is set in [kernel.conf](kernel.conf).
- **Kernel 6.18 LTS (alternative):** Linux **6.18.64** from kernel.org plus the Sky1-Linux patches (commit `57e018a`;
  the 5 that needed rebasing for 6.18.64, and our own fixes, are in [patches/6.18.64/](patches/6.18.64/)). The
  longest-tested kernel; install it with `KERNEL_TRACK=6.18`.
- **GPU:** mainline **panthor**, with Mesa from Ubuntu 26.04: **panvk** (Vulkan 1.4) and **Panfrost** (GLES 3.1).
  No CIX vendor kernel and no closed Mali (`mali_kbase` / `libmali`) stack.
- **NPU:** CIX's open **6.2.0** `armchina-npu` driver (replacing the old one in the Sky1 series, on both kernels) and
  Arm China's open user library **`libaipudrv` 4.1.0**. No firmware is needed. Models are precompiled `.cix` graphs
  from CIX's model hub; the model compiler is closed and x86-only, and only needed for your own models.
  See [docs/npu.md](docs/npu.md).
- **Safe by default:** Armbian's own kernel stays installed as GRUB entry 0 and as an automatic fallback.
- **Releases:** see [below](#releases); `setup.sh --prebuilt` installs the latest one.

This repo is for the **standard Orange Pi 6 only**. Don't use the Plus device tree (`sky1-orangepi-6-plus.dtb`) on it.

## Quick start
The full guide, with every firmware step, is [INSTALL.md](INSTALL.md). In short:

1. **Update the board firmware** to `opi6_bios_image_20261019` (or newer) if it shipped with V0.8.
   See [Firmware and BIOS](#firmware-and-bios).
2. **Install Armbian** (generic UEFI arm64, Ubuntu 26.04) on the NVMe, boot it and get on the wired network.
3. **Run the setup script** from Armbian:
   ```bash
   sudo apt-get install -y git
   git clone https://github.com/jbuck2005/orangepi6 && cd orangepi6
   scripts/setup.sh --prebuilt     # or scripts/setup.sh to build from source (20-60 min on the board)
   sudo reboot
   scripts/setup.sh check          # panthor, /dev/dri/renderD128, Vulkan = panvk, GLES = Panfrost, NPU driver
   scripts/setup.sh npu            # optional: NPU library and npu-run (built on the board)
   ```

Hands-on time is about 15 minutes. `--prebuilt` downloads the release kernel and checks it against the release's
`SHA256SUMS`; the source path fetches kernel.org 7.3.5, checks its signature, patches it strictly (no fuzz) and
builds it on the board. Either way the kernel goes into `/boot/sky1/` and every step is verified (`install.sh verify`).

`setup.sh npu` runs on the sky1 boot: it checks that the NPU driver is 6.2.0, builds and installs `libaipudrv` into
`/usr/local`, installs `npu-run` and prints what the NPU reports (target `X2_1204MP3`, 3 cores). Then fetch a model
from the hub and try it, for example `npu-run bench mobilenet_v2.cix 200`; the commands are in
[docs/npu.md](docs/npu.md#running-a-model).

For the 6.18.64 LTS kernel instead, put `KERNEL_TRACK=6.18` in front of the setup command
(`KERNEL_TRACK=6.18 scripts/setup.sh --prebuilt`, or without `--prebuilt` to build it). The choice is remembered, so
`scripts/setup.sh check` needs no prefix, and a board already set up on 6.18 stays on it. To switch an installed
board between 7 and 6.18, boot Armbian's kernel and run `FORCE=1 KERNEL_TRACK=<7|6.18> scripts/setup.sh --prebuilt`.
Only one sky1 kernel is installed at a time.

## Releases
Each release has a prebuilt kernel, its exact patched source and `SHA256SUMS`. Since v2026.11.23 it also has the kernel and the NPU
library as .deb packages (`sudo apt install ./orangepi6-kernel-7_*_arm64.deb`, see [docs/packages.md](docs/packages.md)).

| Release | Kernel | NPU | State |
|---|---|---|---|
| [v2026.11.25](../../releases/tag/v2026.11.25) | 7.3.5 and 6.18.64 LTS | 6.2.0 driver | **Latest**, both tracks in one release; what `setup.sh --prebuilt` installs (7.3.5, or 6.18.64 with `KERNEL_TRACK=6.18`); also as .deb packages |
| [v2026.11.24](../../releases/tag/v2026.11.24) | 7.3.5 | 6.2.0 driver | superseded by v2026.11.25 |
| [v2026.11.23](../../releases/tag/v2026.11.23) | 6.18.64 LTS | 6.2.0 driver | superseded by v2026.11.25 |
| [v2026.11.22.1](../../releases/tag/v2026.11.22.1) | 6.18.64 LTS | 6.2.0 driver | the same kernel, without packages |
| [v2026.11.22](../../releases/tag/v2026.11.22) | 7.3.5 | old driver (`setup.sh npu` refuses it) | pre-release, superseded by v2026.11.24 |
| v2026.11.19.1, v2026.11.19 | 6.18.64, 6.18.14 | old driver | superseded |

## Building for distribution
Every release asset is made on the board from a normal build, with these commands (nothing else goes into them):

```bash
# 1. build the kernel from source (kernel.org signature checked, strict patching), as in the quick start
scripts/setup.sh preflight && scripts/setup.sh packages && scripts/setup.sh source && scripts/setup.sh build
#    for the 6.18 LTS kernel instead: KERNEL_TRACK=6.18 in front of each command

# 2. package it: the prebuilt tarball, the patched source, the .deb packages and SHA256SUMS, into ~/sky1-build/release/
scripts/package-release.sh v2026.11.25         # the release tag; NPU_DEB=0 skips the NPU package
```

`package-release.sh` checks that the shipped source is the one that was built, then calls `scripts/package-deb.sh`,
which writes:

| File | What |
|---|---|
| `sky1-kernel-<release>-<tag>-arm64.tar.xz` | Image, non-Plus DTB, `.config`, modules (what `setup.sh --prebuilt` installs) |
| `linux-<release>-<tag>-source.tar.xz` | the exact patched source that was built |
| `orangepi6-kernel-7_<kernel>-<tag>-<rev>_arm64.deb` (or `-6.18`) | the same kernel as a package for `apt install` |
| `orangepi6-npu_4.1.0-<tag>-<rev>_arm64.deb` | Arm China's open NPU library, headers and `npu-run`, built on the board |
| `SHA256SUMS` | checksums of all of the above |

The packages can also be made on their own:

```bash
scripts/package-deb.sh from-release v2026.11.25          # kernel-7 package from a published release tarball
KERNEL_TRACK=6.18 scripts/package-deb.sh from-release v2026.11.25
scripts/package-deb.sh npu v2026.11.25                    # NPU package (on the board, arm64)
sha256sum ~/sky1-build/release/*.deb
```

Package versions are `<kernel>-<tag>-<rev>` (`7.3.5-2026.11.24-1`). `<rev>` is 1 for a tag's first build; a
rebuild of the same tag with changed packaging takes `DEB_REVISION=2`, 3, ... in front of the command, so `apt`
upgrades over it. `from-release` only repacks the published tarball after checking it against the release's `SHA256SUMS`, so it runs
on any Linux machine with `dpkg-deb`. What the packages do when installed: [docs/packages.md](docs/packages.md).

## Firmware and BIOS
Firmware setup opens with **Esc** (or **F2**) at power-on. Check the installed version there or from Linux with
`cat /sys/class/dmi/id/bios_version`.

- **Use firmware `opi6_bios_image_20261019`** (`bios_v1.0.bin`, from orangepi.org > Orange Pi 6 > Download > BIOS),
  flashed with `FlashUpdate.efi` from the UEFI Shell ([INSTALL.md step 1](INSTALL.md#1-update-the-board-firmware-if-it-shipped-with-v08)).
  The shipped **V0.8** firmware (April 2026) was unstable at its default 6400 MT/s: 1,227 corrected and 1
  uncorrectable DDR ECC errors in 3 minutes of stress, and resets under load.
- **Memory speed:** Esc > **CIX System Manager** > **Soc Configuration** > **Memory Configuration** >
  **Memory Data Rate**. On the 2026-10-19 firmware, `Auto` (6000 MT/s) and `6400` both passed 1 h of combined
  build + `stress-ng` load on 6.18.64 with 0 ECC errors and 0 resets (and an earlier 4 h CPU+RAM+GPU soak at 6400).
  We measured no speed difference for CPU, GPU or LLM work. If you're stuck on V0.8, use 5500.
- Then **Save & Exit** (F10, then Y) and let the board boot. Don't cut the power right after changing a setting:
  without an RTC battery (below), a power cut loses it.

## RTC battery
The board ships **without an RTC battery**, so every AC power loss resets the firmware settings: memory speed goes
back to `Auto` (6000) and "power on after power loss" goes back to off, so the board stays off after a power cut.

The board has a 2-pin **1.0 mm JRTC1** header with no battery holder, and the circuit does **not** charge the cell
(it's diode-fed). Fit a plain **CR2032** with an **SH1.0** (JST 1.0 mm) 2-pin lead, observing polarity. Don't use a
rechargeable cell. Until one is fitted, set the memory speed and power-loss behavior again after every power loss.

## Hardware notes
- **Network:** both RTL8125B 2.5 GbE ports use the mainline `r8169` driver, built into the sky1 kernel (as in
  Armbian's kernel), with the `rtl_nic/rtl8125b-2.fw` firmware from linux-firmware. Realtek's own `r8125` is still
  available (`NIC_DRIVER=r8125` for `02-fetch-patch.sh`), but with it every warm reboot loses both ports until a
  power cut, and it can't read the MACs in ACPI mode (`stage` then pins them with `.link` files). Trade-off:
  reports put `r8125` ahead at 2.5 Gbit/s (it spreads traffic over several cores); at 1 Gbit/s `r8169` reaches line
  rate (941 Mbit/s each way on our board). Full write-up: [docs/nic-r8125-vs-r8169.md](docs/nic-r8125-vs-r8169.md).
- **NVMe / PCIe:** the Sky1 PCIe driver could hit an **AER interrupt storm** on the NVMe root port (`sky1-pcie.2`)
  right after PHY bring-up, which caused silent resets under load. `post/0003` and `post/0004` fix it (spurious
  interrupts return `IRQ_NONE`, the line is disabled after 64 in a row, and latched local errors are cleared).
- **Cool the NVMe SSD.** The M.2 slot gets no airflow on a bare board. The controller of a heatsink-less SSD reached
  97-100 C during full kernel builds on our board, and that is when we saw a hang and a panic. With a small fan on the
  SSD, an 8.4 h run of 15 full builds and 14 `stress-ng` rounds at 6000 MT/s passed. Fit an M.2 heatsink or airflow.
- **NPU:** Arm China Zhouyi X2 (architecture v3), ACPI device `CIXH4000`, 3 cores behind the SMMU, `/dev/aipu`.
- **Power draw at the wall** (including the supply): ~1 W off, ~17 W idle, 30-36 W under build or stress load.
- **Power supply:** the official 20 V USB-C PD supply (the BIOS manual recommends 100 W).

## Results on our board
| | |
|---|---|
| GPU | panthor 1.5.0, Mali-G720 MC10, CSF firmware v3.13, Mesa 26.0.8 |
| Vulkan (vkpeak) | FP32 1.20 TFLOPS, FP16 2.11 TFLOPS, INT8 dot 4.86 TOPS |
| glmark2-es2-drm (off-screen) | 1591 |
| vkmark (headless) | 3460-3544 (llvmpipe: 741) |
| llama.cpp CPU, Qwen2.5-1.5B Q4_K_M | 124 tok/s prompt, 36.6 tok/s generation |
| llama.cpp CPU, Qwen2.5-7B Q4_K_M | 33.7 / 8.75 tok/s |
| NPU, CIX MobileNetV2 (s8), 6.18.64 | 1.58 ms per run, **631 runs/s** (`npu-run bench`, 200 runs) |
| NPU, CIX MobileNetV2 (s8), 7.3.5 | 1.78 ms per run, 562 runs/s |
| Memory stability | firmware 2026-10-19: 0 ECC errors at 5500/6000/6400 MT/s; 1 h load at 6000 and 6400 on 6.18.64 |

Details: [bench/MEMORY-AB-REPORT.md](bench/MEMORY-AB-REPORT.md), [docs/npu.md](docs/npu.md) and [STATUS.md](STATUS.md).

## Known issues
- **Network ports missing after a warm reboot (fixed):** with Realtek's `r8125` driver, every warm reboot from the
  sky1 kernel made the firmware fail PCIe link training for both RTL8125s (`ip -br link` shows only `lo`, even on
  Armbian) until a 30 s power cut. The sky1 kernel now uses `r8169`, which doesn't do this. If you still see it
  (for example after an `r8125` build), a second warm reboot or a power cut recovers.
- **Heavy full-chip load can corrupt memory.** Rebuilding every module of a large kernel tree (each post-processed
  by `pahole`) on all 12 cores at full speed makes build tools crash, and sometimes the kernel, within minutes (2 to 5
  of 5 runs failed, on both kernels and on Armbian's stock kernel). On our board it comes from one big A720 pair, cpu10-11
  (rated 2.5 GHz), which lacks margin under this load: capped at 2.4 GHz with every other core at full speed
  (cpu0-1 at 2.6 GHz), 0 of 20 runs failed, and 45 of 45 runs at that cap have been clean, while at 2.45 GHz and
  above it failed 10 of 15. Ordinary use, our own kernel builds and `stress-ng` don't trigger it. If you hit
  unexplained crashes under such load, cap that pair until the next boot (same command on both kernel tracks; it
  names CPUs, not cpufreq policies):
  `echo 2400000 | sudo tee /sys/devices/system/cpu/cpu{10,11}/cpufreq/scaling_max_freq`.
  Check it with `cat /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq`. Other boards may differ; capping all
  four big cores (`cpu{0,1,10,11}`) at 2.2 GHz is the more cautious fallback.
  Details: [bench/CRASH-ANALYSIS.md](bench/CRASH-ANALYSIS.md).
- **LLMs on the GPU:** llama.cpp on panvk is slow (~1.7 tok/s) and prompt processing fails with
  `ErrorOutOfDeviceMemory`. Use the CPU (`-dev none` in a Vulkan build).
- **panvk** is not yet a conformant Vulkan driver, and the GPU temperature sensors don't read.
- **NPU models:** only precompiled graphs from CIX's model hub run without the closed x86 compiler, and the hub has
  no YOLO graphs. Classification has been checked for consistency (same top 5 on both kernels), not yet against
  ImageNet ground truth. CIX's closed `libnoe` and ONNX Runtime provider are not used or shipped.
- **Kernel 7 (7.3.5) is the default but has less time on the board than 6.18.64.** Its proving run on the release
  build: 10 of 10 warm reboots and 3 of 3 cold boots clean, and 8 hours of full kernel builds and `stress-ng --verify`
  with all 16 stress rounds passing and 15 of 16 builds passing. One build failed after 49 s; its log was lost and
  no kernel or memory error was logged, so the cause is not known (logs are now kept per cycle). For the most proven
  kernel, use 6.18.64 (`KERNEL_TRACK=6.18`). Also:
  - the CIX display drivers do not build on 7.x and are off (the board runs headless; the GPU is unaffected);
  - two debug patches (`0050`, `0051`) are still in the series: they add a few log lines on each reboot and a
    register dump if an AER line is ever cut off;
  - a reboot less than about 40 s after a boot can make GRUB fall back to Armbian next time, because the boot had
    not been confirmed yet; `install.sh default` sets the default again.

## Debug serial console
The **2x2 "DEBUG" header** just below the left network jack is UART2: 3.3 V, **115200 8N1**. The row nearest the
jack is RX (left) and TX (right); the far row is GND. Cross TX/RX to a 3.3 V USB-serial adapter and leave its VCC
unconnected. The firmware, GRUB and the sky1 kernel all log there. The firmware has no SPCR table, so serial test
boots (`SERIAL=1 scripts/install.sh arm acpi`) use `earlycon=pl011,mmio32,0x040d0000`.
`bench/serial-log.ps1` is a timestamping logger for Windows. Every board test follows
[bench/TEST-PROCESS.md](bench/TEST-PROCESS.md): boot-persistent loggers, temperatures on the serial console,
pre-flight checks, per-run records and status reports.

<p>
  <img src="docs/images/debug-header-location.svg" width="600" alt="Orange Pi 6 top side to scale with all connectors: the 2x2 DEBUG header is just below the left network jack, beside the top of the 40-pin header">
  <img src="docs/images/debug-header-pinout.svg" width="600" alt="DEBUG header pinout: RX and TX on the row nearest the jack, GND on the far row; board TX to adapter RXD, board RX to adapter TXD, GND to GND, adapter VCC unconnected">
</p>

## Roadmap
- **Phase 1, GPU:** done (2026-11-18), released as v2026.11.19 and v2026.11.19.1.
- **Phase 2, NPU:** done (2026-11-22) on an open stack (CIX's 6.2.0 driver, Arm China's open `libaipudrv` 4.1.0),
  see [docs/npu.md](docs/npu.md). Released in v2026.11.22.1, v2026.11.23 and v2026.11.25 (6.18.64) and v2026.11.24 and v2026.11.25 (7.3.5).
- **Kernel 7:** 7.3.5 merged as an optional track on 2026-11-22 (pre-release v2026.11.22), proven on the board and
  made the default on 2026-11-24 in v2026.11.24 (CPU gap fixed, NPU driver 6.2.0). 6.18.64 LTS stays available.
- **Open:** NPU classification checked against ImageNet labels and more hub models; CIX display drivers on 7.x; an
  RTC battery. The full list is at the end of [HISTORY.md](HISTORY.md#open-items).
- Ruled out: the CIX/Canonical vendor kernel and closed Mali stack, NCZ-OS, and the original Orange Pi vendor image
  (it didn't boot on this board). See [HISTORY.md](HISTORY.md).

## History
[HISTORY.md](HISTORY.md) records every patch, change, release and finding to date, in order. It is updated with every
change (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Layout
| Path | What |
|---|---|
| `scripts/setup.sh` | one-command install from stock Armbian (preflight, packages, source, build, stage, default, check); `--prebuilt` uses the release |
| `scripts/02-fetch-patch.sh`, `03-build.sh` | kernel source (signature checked), Sky1 patches, our DTS, config; build at `-j6` |
| `scripts/install.sh` | `stage`, `verify`, `default`/`undefault`, one-time test boots (`arm acpi\|dt`, `disarm`), `bootlog`, `prune` |
| `scripts/boot-report.sh` | confirms the default boot (clears GRUB's fallback mark); network fallback for test boots |
| `scripts/gpu-test.sh` | vulkaninfo, glmark2 and vkmark, results to `/var/log/sky1-gpu-test.txt` |
| `scripts/package-release.sh` | builds the release tarballs, the .deb packages and `SHA256SUMS` |
| `scripts/package-deb.sh`, `packaging/` | the .deb packages: kernel per track and the NPU library ([docs/packages.md](docs/packages.md)) |
| `kernel.conf` | the two kernel tracks (`KERNEL_TRACK=7`, the default, or `6.18`): version and patch set used by every script |
| `patches/6.18.64/` | rebased Sky1 patches; `post/` holds our fixes (syscore API, r8125 netpoll, AER storm, NPU driver 6.2.0) |
| `patches/7.3/` | kernel 7 track: the Sky1 patches forward-ported to 7.3.5, plus our fixes (`0044`-`0055`) |
| `docs/` | kernel 7 notes and board results (`KERNEL-7.md`), the CPU scheduling fix, r8125 vs r8169, the NPU (`npu.md`) |
| `initramfs/`, `scripts/bootlog-area.sh` | early-boot logger: writes the kernel log to a raw disk area before root is mounted |
| `dts/sky1-orangepi-6.dts` | non-Plus device tree (for the optional DT/`acpi=off` route) |
| `bench/` | test process ([TEST-PROCESS.md](bench/TEST-PROCESS.md)), boot-persistent loggers, pre-flight and status tools, benchmark and memory-soak suite, crash reproducer, Windows UART logger and log puller, A/B report |
| `tools/` | netconsole listener and self-test; read-only smart-plug power report (`plug-power.py`); `npu-run` and `npu-prep.py` |
| `scripts/npu-umd.sh` | builds and installs Arm China's open NPU library (`libaipudrv` 4.1.0); `setup.sh npu` runs it |
| `scripts/01-toolchain.sh` | unprivileged toolchain from Ubuntu debs (only needed without root; `setup.sh` uses apt instead) |

## How the fallback works
GRUB marks every sky1 boot as pending, and `sky1-boot-report.service` clears the mark once userspace is up. If the
mark is still set at the next boot (a hang, panic or power loss), GRUB boots **Armbian** instead and keeps it as the
default until you run `scripts/install.sh default` again. `scripts/install.sh undefault` makes Armbian the default
for good. GRUB changes are generated into a temp file and checked (`grub-script-check`, Armbian is still entry 0)
before they're installed.

## Safety and verification
`install.sh verify` fails loudly if anything is missing or mismatched. It checks the module tree and panthor
vermagic for the exact release, the built-in boot and network drivers, that `/boot/sky1` matches the build, the DTB
model, that the initrd's tools run inside the initrd with nothing leaked from the build environment, the boot logger
(by a self-test with the initrd's own `dd`), the NIC MAC pins, and the Mali firmware.

## Device-tree route
With the Sky1 patches, the GPU is powered through SCMI in ACPI mode, so the `acpi=off` + device-tree route
documented for the Plus isn't needed. It's still available as a one-time test boot: `install.sh arm dt`.
