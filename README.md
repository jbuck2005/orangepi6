# orangepi6

A headless Ubuntu 24.04 (noble) image for the **Orange Pi 6** (16 GB, CIX P1, not the 6 Plus) with the **GPU and NPU** working, for local AI. It is built on Zeus and flashed to the Pi's NVMe.

## Hosts
| Host | Address | Role |
|---|---|---|
| Zeus | `james@192.168.0.50` | x86_64 build server (Docker) |
| aiPi | `james@aipi` / `192.168.0.202` | Orange Pi 6 target |

## Build
`build-opi6-server.sh` is a copy of `~/build-opi6-server.sh` on Zeus. It clones `orangepi-build` (branch `next`), guards the gdm3 edits in `cix.conf`, then runs:

```
./build.sh docker BOARD=orangepi6 BRANCH=next RELEASE=noble BUILD_OPT=image \
  BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no FORCE_USE_RAMDISK=no COMPRESS_OUTPUTIMAGE=xz
```

Run it on Zeus with:

```bash
tmux new -s opi6 'bash ~/build-opi6-server.sh 2>&1 | tee ~/opi6-build.log'
```

When it finishes, check that `output/debs` includes `cix-gpu-*`, `cix-npu-*`, `cix-vpu-*`, `cix-gpu-umd`, `cix-npu-umd` and `cix-noe-umd`.

## Staged on Zeus (`~/opi6-staging/`)
- `pi-backup/`: the Pi's backup tarball, migration notes and `.ssh`, each checksum-verified
- `debs/cix-npu-onnxruntime_1.2.0_arm64.deb`: NPU onnxruntime, which the server build leaves out

After flashing, copy it to the Pi with:

```bash
scp -r james@192.168.0.50:opi6-staging james@aipi:
```

## Plan B: strip the official desktop image
1. `sudo systemctl set-default multi-user.target`, then reboot.
2. `apt-mark manual` every `cix-*`, mesa, libdrm, libglvnd and Vulkan package.
3. `apt purge --simulate` the GNOME, gdm3 and chromium packages. Review the list, and the `autoremove` list, before running them for real.

## References
- https://github.com/orangepi-xunlong/orangepi-build: the vendor build system
- https://github.com/orangepi-xunlong/component_cix-next: CIX packages and releases
- https://github.com/visorcraft/orange-pi-6-plus-npu: NPU driver on mainline, plus the NOE inference guide
- https://github.com/visorcraft/orange-pi-6-plus-gpu: Panthor GPU on mainline (needs device-tree boot; 6 Plus only)
- https://github.com/Sky1-Linux: community mainline kernel and acpi-to-dts-tools
