# Installing the open GPU stack on an Orange Pi 6

This guide is for the **Orange Pi 6 (non-Plus)**: a 90x90 mm board with a CIX P1 (CD8180), a Mali-G720 and 2x RTL8125.
The end result runs Armbian userspace on a mainline-based 6.18 kernel, with the **panthor** GPU driver and Mesa
(**panvk** Vulkan 1.4, **Panfrost** GLES 3.1). It uses no vendor kernel and no closed Mali blobs. Armbian's own
kernel stays installed as an automatic fallback.

Time needed: about 15 minutes of hands-on work, plus 20-60 minutes of unattended kernel build.

## 0. What you need
- An Orange Pi 6 (non-Plus) with an NVMe SSD and the official 20 V Type-C PD power supply (the BIOS manual recommends 100 W)
- A monitor and USB keyboard for the firmware steps (or a 3.3 V USB-serial adapter, see the end of this guide)
- Wired network

## 1. Update the board firmware (if it shipped with V0.8)
Check the version: in firmware setup (press **Esc** or **F2** at power-on) or under Linux, `cat /sys/class/dmi/id/bios_version`.

If it says `OPI6BiosV0.8...` (April 2026), update it. With that firmware's default memory speed (6400 MT/s), our
board logged **1,227 corrected and 1 uncorrectable DDR ECC errors in 3 minutes** of memory stress on stock Armbian, and
reset itself under load. With the 2026-10-19 firmware, the same board ran a **4-hour combined CPU+RAM+GPU stress at
6400 with zero errors** (see `bench/MEMORY-AB-REPORT.md`).

1. Download `opi6_bios_image_20261019.img` (or newer) from orangepi.org → Orange Pi 6 → Download → **BIOS**.
   If Google Drive says "quota exceeded", use "Make a copy" and download the copy.
2. The `.img` holds a FAT32 partition with `bios_flash/FlashUpdate.efi` and `bios_flash/bios_v1.0.bin` (the Linux
   build). Copy those two files to any FAT32 USB stick, or to the EFI partition of an installed system
   (`/boot/efi/bios_flash/`).
3. Power on and press **Esc** → **Boot Manager** → **UEFI Shell**.
4. `fs0:` then `ls`. If `bios_flash` isn't listed, try `fs1:`, `fs2:` and so on. Then `cd bios_flash`.
5. `FlashUpdate.efi -f bios_v1.0.bin`. It shows the old and new versions, flashes, and **reboots by itself**.
   Don't cut the power while it runs.

## 2. Firmware settings
In setup (**Esc**): CIX System Manager → Soc Configuration → **Memory Configuration** → **Memory Data Rate**.
- On the 2026-10-19 firmware, `Auto` (6000 MT/s) or `6400` are both fine. We measured no speed difference for CPU, GPU or LLM work.
- If you're stuck on V0.8, set **5500 MT/s**. That was error-free on our board.

Save with **F10**, then **Y**.

## 3. Install Armbian
Install the generic **Armbian UEFI arm64** image (we used Armbian 26.8.3 "resolute", Ubuntu 26.04 userspace)
onto the NVMe the usual way, boot it, and get on the network.

## 4. Run the setup script
```bash
sudo apt-get install -y git
git clone https://github.com/jbuck2005/orangepi6
cd orangepi6
scripts/setup.sh
```
`setup.sh` checks the board and firmware, installs the build tools and Mesa from the Ubuntu archive, fetches Linux
6.18.14 from kernel.org (and checks Greg Kroah-Hartman's signature), applies the Sky1-Linux patches and this repo's
non-Plus device tree, and builds the kernel (`-j6`, 20 minutes to an hour). It then installs the kernel into `/boot/sky1/`
and makes it the GRUB default. Every step is checked, and the script stops with a clear message on the first failure.
Re-running it skips steps that are already done.

**No time to build?** `scripts/setup.sh --prebuilt` downloads the ready-to-run kernel from this repo's GitHub
Releases instead. It's built by exactly this process, and its SHA-256 is checked against the release's `SHA256SUMS`.
That saves the hour. The matching patched kernel source is published next to it.

Then:
```bash
sudo reboot
scripts/setup.sh check        # panthor, /dev/dri/renderD128, Vulkan = panvk, GLES = Panfrost
scripts/gpu-test.sh           # optional: vulkaninfo, glmark2, vkmark
```

## How the fallback works
- Armbian's kernel stays entry 0 in GRUB. The sky1 kernel lives separately in `/boot/sky1/`, so Armbian kernel
  updates don't touch it.
- GRUB marks every sky1 boot as pending (`sky1_pending=1` in grubenv), and `sky1-boot-report.service` clears the
  mark once the system is up. If GRUB finds the mark still set (a hang, panic or power loss before boot finished),
  it boots **Armbian** instead and sets `sky1_failed=1`. Armbian then stays the default until you run
  `sudo WORK=~/sky1-build scripts/install.sh default` again.
- `scripts/install.sh undefault` makes Armbian the default for good.
- `scripts/install.sh bootlog` shows the GRUB markers and the raw early-boot log of the last sky1 boot.

## Known issues
- **Network ports missing after a reboot:** the firmware sometimes fails PCIe link training for the RTL8125s on a
  warm reboot (`ip -br link` shows only `lo`; the serial console shows `Root Port 2/3: Link Up Fail,Ltssm State:40C80`).
  It happens on both the V0.8 and the 2026-10-19 firmware, and only after a session that used the NICs. The fix is
  cutting the power for about 30 s. To automate it, put aiPi on a smart plug with a local HTTP API (Shelly Gen2+/Gen3
  with its cloud switched off, or a Tasmota plug) and run `tools/plug-watch.ps1` on the PC that logs the serial
  console: it power-cycles the board when the firmware reports the failure (at most 3 times an hour), and
  `-Once` does a cycle by hand. `tools/plug-powercycle.sh` does a single cycle from Linux. The plug's address
  and password live in a JSON file outside the repo. With **Home Assistant** (any plug HA can switch), create a long-lived
  access token and use `{"type":"homeassistant","url":"http://<ha>:8123","entity":"switch.<plug>","token_file":"<file>"}`
  (the file holds just the token, chmod 600; or add `"token_var":"HA_TOKEN"` to read one variable from an env file):
  the watcher calls `switch.turn_off`, waits 30 s, then `switch.turn_on`, retrying for up to 10 minutes and
  logging loudly if the plug doesn't come back on. (`scripts/nic-power.sh`, which switches the NIC rails
  through GPIO038/039, is experimental: it froze the board under Armbian.)
- **LLMs on the GPU:** llama.cpp's Vulkan backend on panvk generates text at only ~1.7 tok/s, and prompt processing
  fails with `ErrorOutOfDeviceMemory`. Use the CPU for now: Qwen2.5-1.5B Q4 runs at ~124 tok/s for prompts and ~37 tok/s
  for generation, and 7B at ~34/9 tok/s. In a Vulkan build, pass `-dev none`.
- **panvk** is not yet a conformant Vulkan driver. GPU temperature sensors don't read.
- After the kernel takes over, the vendor `r8125` driver can't read the NICs' MAC addresses. `stage` pins the real
  MACs from Armbian, so **run `stage` from Armbian's kernel** (`setup.sh` checks this).

## Debug serial console (optional)
The **2x2 "DEBUG" header** sits just below the left network jack. The row nearest the jack is RX (left) and TX
(right), and the far row is GND. It's UART2: 3.3 V, 115200 8N1. Connect adapter TX to board RX and adapter RX to
board TX, and leave the adapter's VCC unconnected. The firmware, GRUB and the sky1 kernel all log there.
`scripts/install.sh arm acpi` with `SERIAL=1` arms a one-time test boot that keeps all output on the serial console.
`bench/serial-log.ps1` is a timestamping logger for Windows.

## Benchmarks
`bench/` holds the A/B suite (`ab-test.sh`), the combined soak (`soak.sh`) and the results from our board.
