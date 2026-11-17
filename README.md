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
export WORK=$HOME/sky1-build           # must not be inside a git repo (kernel would become "6.18.14-sky1+")
scripts/01-toolchain.sh                # unprivileged toolchain from Ubuntu debs
scripts/02-fetch-patch.sh              # kernel.org + signature check + Sky1 patches + our DTS; checks release name
scripts/03-build.sh                    # Image, modules, dtbs (-j6; -j12 crashed the board once)
sudo WORK=$WORK scripts/install.sh stage    # modules, /boot/sky1/{vmlinuz,initrd.img,dtb}; then runs verify
sudo WORK=$WORK scripts/install.sh arm      # GRUB entry as the LAST entry + one-shot grub-reboot
sudo reboot
# after the test boot (or after falling back to Armbian):
cat /var/log/sky1-boot-report.txt
scripts/gpu-test.sh
sudo scripts/install.sh disarm         # remove the entry again
```
`verify` fails loudly if anything is missing or mismatched: the module tree for the exact kernel release, panthor/r8125 vermagic, built-in nvme/ext4/PCIe/ramoops, the kernel and DTB in `/boot/sky1` matching the build, the DTB model being "Orange Pi 6" with the unused PCIe ports disabled, the initrd holding the module tree, and the Mali firmware. `arm` checks the generated grub.cfg with `grub-script-check`, confirms entry 0 is still Armbian and that the test entry appears exactly once, and only then installs it.

## Safety
- Kernel, initrd and DTB live in `/boot/sky1/`, so Armbian's `10_linux` never makes entries for them. The test entry comes from `/etc/grub.d/45_sky1`, after `10_linux`, so entry 0 (`GRUB_DEFAULT=0`) stays Armbian. `grub-reboot` arms exactly one boot.
- If the test kernel hangs, a power cycle boots Armbian. If it panics, `panic=10` reboots into Armbian. If it boots but has no network, `sky1-boot-report.service` reboots into Armbian after 180 s.
- `CONFIG_PSTORE_RAM=y` and `PSTORE_CONSOLE=y` keep the last kernel log in RAM (ramoops) across a warm reboot, for diagnosis.

## Known issues (from Sky1-Linux / visorcraft)
- GPU temperature sensors don't read.
- SIGKILL on a GPU process can wedge panthor until a reboot.
- panvk is not yet Vulkan-conformant.

See `STATUS.md` for where things stand.
