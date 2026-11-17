# orangepi6

An open GPU stack for the **Orange Pi 6** (non-Plus: 90x90 mm board, CIX P1 / CD8180, Mali-G720, 2x RTL8125), running headless on Armbian.

The GPU uses the mainline **panthor** driver and Mesa (panvk for Vulkan, panfrost for GLES). It does not use the CIX vendor kernel or the closed Mali (`mali_kbase` / `libmali`) stack.

## Why device-tree boot
The board's UEFI firmware boots Linux with ACPI. In ACPI mode the firmware's power call for the GPU only does bookkeeping, so the Mali never powers on, and panthor has no ACPI binding anyway. With `acpi=off` and a device tree, the same firmware call really powers the GPU. This was documented by [visorcraft/orange-pi-6-plus-gpu](https://github.com/visorcraft/orange-pi-6-plus-gpu).

## Sources
| Piece | Source |
|---|---|
| Kernel | linux 6.18.14 from kernel.org, Greg Kroah-Hartman's signature checked |
| SoC patches and config | [Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1) LTS track (`patches/`, `config/config.sky1`), commit `57e018a` |
| Device tree | `dts/sky1-orangepi-6.dts` (this repo) |
| Mesa | Ubuntu 26.04 archive (Mesa 26) |
| GPU firmware | `arm/mali/arch12.8/mali_csffw.bin`, already shipped by Armbian/linux-firmware |

## Device tree for the non-Plus board
There is no upstream or Sky1-Linux DTS for the non-Plus Orange Pi 6. `dts/sky1-orangepi-6.dts` includes the Sky1-Linux Orange Pi 6 Plus DTS and then:
- keeps the three PCIe root ports this board actually uses: x8 for NVMe (x4 link), and x2 and x1_1 for the two RTL8125s. Their reset and power GPIOs match the board's own ACPI tables.
- disables the x4 and x1_0 root ports and their regulators, which the firmware turns off on this board.
- disables the Plus display chain (PS185 DP-to-HDMI bridge, eDP panel, backlight), because the board runs headless and that wiring hasn't been verified.

## Steps
```bash
export WORK=$HOME/sky1-build
scripts/01-toolchain.sh      # unprivileged toolchain from Ubuntu debs
scripts/02-fetch-patch.sh    # kernel.org + signature check + Sky1 patches + our DTS
scripts/03-build.sh          # Image, modules, dtbs (-j6; -j12 crashed the board once)
sudo WORK=$WORK bash scripts/install.sh   # kernel, initramfs, GRUB entry, one-shot boot
sudo reboot
# after the test boot:
cat /var/log/sky1-boot-report.txt
scripts/gpu-test.sh
```

## Safety
- Armbian stays the GRUB default (`GRUB_DEFAULT=0`). `install.sh` only arms a one-shot `grub-reboot` into "Sky1 GPU test", so any reset after a failed test boot lands back on Armbian.
- `sky1-boot-report.service` runs only when `acpi=off` is on the command line. It logs the GPU state, and reboots back to Armbian if there's no network within 180 s.
- `panic=10` reboots on a kernel panic.

## Known issues (from Sky1-Linux / visorcraft)
- GPU temperature sensors don't read.
- SIGKILL on a GPU process can wedge panthor until a reboot.
- panvk is not yet Vulkan-conformant.

See `STATUS.md` for where things stand.
