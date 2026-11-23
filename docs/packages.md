# .deb packages

Besides building the kernel (`scripts/setup.sh`) or unpacking the release tarball (`scripts/setup.sh --prebuilt`),
the kernel and the NPU library come as Debian packages that install with plain `apt`:

| Package | Contents | Conflicts with |
|---|---|---|
| `orangepi6-kernel-6.18` | Linux 6.18.64-sky1 (the default): Image, non-Plus DTB, modules, the install scripts | `orangepi6-kernel-7` |
| `orangepi6-kernel-7` | Linux 7.3.5-sky1 (optional, newer, less tested; see [KERNEL-7.md](KERNEL-7.md)) | `orangepi6-kernel-6.18` |
| `orangepi6-npu` | Arm China's open NPU library `libaipudrv` 4.1.0, its headers, `npu-run` (see [npu.md](npu.md)) | |

The build script stays: the packages are made from the same build, and `scripts/setup.sh` is still how to build the
kernel yourself.

## Install

On the Orange Pi 6 (non-Plus) running Armbian, download the packages from a release and install them:

```bash
sudo apt install ./orangepi6-kernel-6.18_*_arm64.deb ./orangepi6-npu_*_arm64.deb
sudo reboot
orangepi6-check            # boot confirmed, panthor, Vulkan = panvk, GLES = Panfrost, NPU driver version
npu-run info               # optional: the NPU
```

`apt` also pulls in the tools the install needs (initramfs-tools, GRUB, device-tree-compiler) and, as recommended
packages, Mesa's Vulkan driver and its test tools. Check the files against the release's `SHA256SUMS` first
(`sha256sum -c --ignore-missing SHA256SUMS`).

To switch tracks, install the other kernel package; apt removes the first one. Reboot afterwards. To go back to
Armbian's kernel only, boot it and run `sudo apt remove orangepi6-kernel-6.18` (or `-7`).

## What the kernel package does

The postinst runs the same steps as `setup.sh stage` and `setup.sh default`, from the package's own copy of this
repo's scripts in `/usr/share/orangepi6`:

- the kernel, DTB and `.config` go to `/boot/sky1/`, with an initramfs built from a private configuration
  (`/etc/sky1/initramfs-tools`), and the boot logger and boot report are installed;
- every check of `install.sh verify` runs; a failed check stops the install, and the GRUB default is not changed;
- "Sky1 (acpi)" becomes the GRUB default. Armbian's kernel stays entry 0, and GRUB boots it automatically if a sky1
  boot never comes up. To install without changing the default, put `SKY1_MAKE_DEFAULT=no` in
  `/etc/default/orangepi6-kernel` first.

Removing the package hands the default back to Armbian and empties `/boot/sky1`. It refuses to remove the kernel
that is running (boot Armbian's kernel first, or set `SKY1_REMOVE_RUNNING=1`). Purging the last kernel package also
removes the boot logger and boot report.

### Why not `make bindeb-pkg`

The kernel's own `bindeb-pkg` target makes `linux-image-<release>` packages that install `/boot/vmlinuz-<release>`
and run the system's kernel hooks. On Armbian that makes `10_linux` add GRUB entries for the sky1 kernel next to
Armbian's, and builds its initramfs with Armbian's configuration: the setup this repo avoids (its first install did
exactly that; `install.sh disarm` still cleans up after it). These packages keep the `/boot/sky1` layout, the private initramfs and the
GRUB fallback that `setup.sh` uses.

### Living with Armbian's packages

The packages have their own names and never replace or depend on Armbian's kernel packages, so they don't change
what `apt upgrade` does to Armbian's kernel. Keep Armbian's holds (`linux-image-current-arm64`,
`linux-dtb-current-arm64`, `armbian-firmware-full`) as they are.

Versions are `<kernel>-<release tag>`, e.g. `6.18.64-2026.11.22.1`, so a later release's package upgrades an earlier
one. An upgrade that keeps the same kernel release (a rebuild of 6.18.64) replaces the running kernel's modules:
reboot right after it.

## Making the packages

`scripts/package-release.sh <tag>` makes them with the other release assets, from the board's build, and lists them
in `SHA256SUMS`. Separately:

```bash
scripts/package-deb.sh from-release v2026.11.22.1        # the 6.18 kernel package, from a published release tarball
KERNEL_TRACK=7 scripts/package-deb.sh from-release v2026.11.22
scripts/package-deb.sh kernel <tree> <tag>               # from a tree laid out like the release tarball
scripts/package-deb.sh npu <tag>                         # builds libaipudrv and npu-run; on the board (arm64)
```

`from-release` and `kernel` only repack files, so they run on any Linux machine with `dpkg-deb`; the result is
always an arm64 package. Output goes to `$WORK/release` unless an output directory is given.
