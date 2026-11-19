# orangepi6

An open GPU stack for the **Orange Pi 6** (non-Plus: 90x90 mm board, CIX P1 / CD8180, Mali-G720, 2x RTL8125),
on Armbian userspace.

- Kernel: Linux **6.18.64** (6.18 LTS) from kernel.org plus the [Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1)
  LTS patches (commit `57e018a`, made for 6.18.14; the 5 that needed rebasing for 6.18.64 are in
  [patches/6.18.64/](patches/6.18.64/)), built on the board. The version is set in [kernel.conf](kernel.conf). It boots in the firmware's **ACPI** mode.
- GPU: mainline **panthor**, with Mesa from Ubuntu 26.04: **panvk** (Vulkan 1.4) and **Panfrost** (GLES 3.1).
- No CIX vendor kernel and no closed Mali (`mali_kbase` / `libmali`) stack.
- Armbian's own kernel stays installed as entry 0 in GRUB and as an automatic fallback.

**To install, see [INSTALL.md](INSTALL.md).** In short: update the board firmware if it's V0.8, install Armbian,
then run `scripts/setup.sh`.

## Results on our board
| | |
|---|---|
| Vulkan (vkpeak) | FP32 1.20 TFLOPS, FP16 2.11 TFLOPS, INT8 dot 4.86 TOPS |
| glmark2-es2-drm (off-screen) | 1591 |
| vkmark (headless) | 3460 (llvmpipe: 741) |
| llama.cpp CPU, Qwen2.5-1.5B Q4_K_M | 124 tok/s prompt, 36.6 tok/s generation |
| llama.cpp CPU, Qwen2.5-7B Q4_K_M | 33.7 / 8.75 tok/s |
| Memory stability | firmware 2026-10-19: 0 ECC errors at 5500/6000/6400 MT/s, including a 4 h combined soak |

Details: `bench/MEMORY-AB-REPORT.md` and `STATUS.md`.

## Layout
| Path | What |
|---|---|
| `scripts/setup.sh` | one-command install from stock Armbian (preflight, packages, source, build, stage, default, check) |
| `scripts/02-fetch-patch.sh`, `03-build.sh` | kernel source (signature checked), Sky1 patches, our DTS, config; build at `-j6` |
| `scripts/install.sh` | `stage`, `verify`, `default`/`undefault`, one-time test boots (`arm acpi\|dt`, `disarm`), `bootlog` |
| `scripts/boot-report.sh` | confirms default boots (clears GRUB's fallback mark); network fallback for test boots |
| `initramfs/`, `scripts/bootlog-area.sh` | early-boot logger: writes the kernel log to a raw disk area before root is mounted |
| `dts/sky1-orangepi-6.dts` | non-Plus device tree (for the optional DT/`acpi=off` route) |
| `bench/` | benchmark and memory-soak suite, Windows UART logger, A/B report |
| `tools/` | netconsole listener and self-test |
| `scripts/01-toolchain.sh` | unprivileged toolchain from Ubuntu debs (only needed without root; `setup.sh` uses apt instead) |

## Safety and verification
`install.sh verify` fails loudly if anything is missing or mismatched. It checks:
- the module tree and panthor vermagic for the exact release
- the built-in boot and network drivers
- that `/boot/sky1` matches the build
- that the DTB model is right
- that the initrd's tools run inside the initrd, with nothing leaked from the build environment
- the boot logger, by a self-test with the initrd's own `dd`
- the NIC MAC pins: present in the initrd, inert under Armbian
- the Mali firmware

GRUB changes are generated into a temp file, checked (`grub-script-check`, Armbian is still entry 0, the entries
are present), and only then installed.

## Device-tree route
Earlier notes said the GPU only powers on with `acpi=off` and a device tree (as documented for the Plus by
visorcraft). With the Sky1-Linux patches, the GPU is powered through SCMI in ACPI mode too, so the DT route isn't
needed. It's still available as a one-time test boot: `install.sh arm dt`.

## Known issues
See [INSTALL.md](INSTALL.md#known-issues): flaky NIC link training on warm reboots, slow and limited LLM inference on
panvk, panvk not yet conformant, and no GPU temperature readout.
