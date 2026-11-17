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
# optional netconsole target: $WORK/netconsole.conf with REMOTE_IP REMOTE_MAC LOCAL_IP LOCAL_MAC (not committed)
sudo WORK=$WORK scripts/install.sh stage      # modules, /boot/sky1/*, boot logger, initramfs; then verify
sudo WORK=$WORK scripts/install.sh arm acpi   # diagnostic: same kernel, ACPI mode (no GPU)
sudo WORK=$WORK scripts/install.sh arm dt     # device tree + acpi=off (GPU)
sudo reboot
# afterwards (whichever kernel came up):
sudo scripts/install.sh bootlog        # raw boot log written by the test boot's initramfs
cat /var/log/sky1-boot-report.txt      # only if the test boot reached userspace
scripts/gpu-test.sh
sudo scripts/install.sh disarm
```

## Boot logging (no monitor needed)
- **Raw disk log:** `stage` creates an 8 MiB single-extent file, `/var/lib/sky1/bootlog.bin`. It proves the file's physical location by writing a random pattern through the filesystem and reading it back from the raw disk. The test initramfs then writes the full kernel log there every 2 s with `dd`, before any filesystem is mounted, and once more just before switching to the real root.
- **netconsole:** built in, with the NIC driver built in. The kernel command line targets the log host and replays the whole log from boot. If that target doesn't come up in time, the initramfs adds one through configfs and replays the log. Receive it with `tools/netconsole-listener.py` on the log host, and prove the path first with `tools/netconsole-selftest.sh`.
- **ramoops/pstore:** built in, with a console record, for warm reboots.
- `ignore_loglevel`, `printk.devkmsg=on`, and in DT mode `earlycon` plus a serial console on ttyAMA2 for when a USB serial adapter is attached.
- The logger lives only in a private initramfs confdir, `/etc/sky1/initramfs-tools`, and is also guarded by kernel version, so Armbian's initramfs never includes it.

`verify` fails loudly if anything is missing or mismatched: the module tree for the exact release, panthor vermagic, the built-in boot and network drivers, the kernel and DTB in `/boot/sky1` matching the build, the DTB model and disabled PCIe ports, the initrd holding the modules, the logger, its config and its ORDER entries, a fresh raw-location proof of the log area, and the Mali firmware. `arm` builds grub.cfg into a temp file, then checks it: `grub-script-check`, Armbian is entry 0, exactly one test entry, and for DT the `devicetree` line and `acpi=off`. Only then does it install the file and arm a one-shot `grub-reboot`.

## Safety
- Kernel, initrd and DTB live in `/boot/sky1/`, so Armbian's `10_linux` never makes entries for them. The test entry comes from `/etc/grub.d/45_sky1`, after `10_linux`, so entry 0 (`GRUB_DEFAULT=0`) stays Armbian. `grub-reboot` arms exactly one boot.
- If the test kernel hangs, a power cycle boots Armbian. If it panics, `panic=10` reboots into Armbian. If it boots but has no network, `sky1-boot-report.service` reboots into Armbian after 180 s.

## Known issues (from Sky1-Linux / visorcraft)
- GPU temperature sensors don't read.
- SIGKILL on a GPU process can wedge panthor until a reboot.
- panvk is not yet Vulkan-conformant.

See `STATUS.md` for where things stand.
