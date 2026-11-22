# NPU (Arm China Zhouyi X2) on the Orange Pi 6

Status: **in progress** (2026-11-22). The driver and user library build; the board test is pending.

## What the NPU is

- Arm China Zhouyi X2, architecture v3, in the CIX Sky1: 1 partition, 1 cluster, 3 cores.
- ACPI device `CIXH4000` (`\_SB_.NPU0`, one power resource per core), behind the SMMU; DVFS through an SCMI perf
  domain (`/sys/class/devfreq/CIXH4000:00`).
- **No firmware.** No version of the driver loads a firmware file. The code the NPU runs comes in the compiled model
  graph.

## Stack (all open except the model compiler)

| Layer | What | License |
|---|---|---|
| Kernel driver | `drivers/misc/armchina-npu`, CIX 6.2.0 (`patches/6.18.64/post/0012`, `patches/7.3/0056`) | GPL-2.0 |
| User library | Arm China `libaipudrv` 4.1.0 ([Compass_NPU_Driver](https://github.com/Arm-China/Compass_NPU_Driver) `f35bac0`), `scripts/npu-umd.sh` | Apache-2.0 |
| Test tool | `tools/npu-run.cpp` (`info`, `bench`, `classify`) | this repo |
| Models | compiled `.cix` graphs from CIX's model hub on ModelScope (`cix/ai_model_hub_26_Q2`) | per model |
| Compiler (optional) | CixBuilder / Compass, for your own models | closed, x86-64 only |
| `libnoe`, ONNX Runtime provider (optional) | CIX's higher-level APIs, on top of `libaipudrv` | closed |

## Why the driver is replaced

The Sky1 patch series carries an old CIX build of the driver (KMD 1.0.0). Its ioctl ABI has 32 ASID bases in
`struct aipu_cap` and lacks `exec_id` and the DMA-buf bind calls, so no current user library works with it. CIX's
6.2.0 driver is Arm China's 4.1.0 driver plus a Sky1 layer, and Arm China's 4.1.0 library matches it (4.2.0 and later
changed `struct aipu_buf_desc` and `struct aipu_job_desc` again). Our `sky1.c` is CIX's 6.2.0 file with the Sky1
series' mainline changes kept: DVFS through the OPP core rather than the SCMI genpd's private struct, and under ACPI
the `perf` domain attached by index.

## Trying it without a reboot

On a sky1 boot whose build tree is still in `$WORK`:

    KERNEL_TRACK=7 bench/npu-bringup.sh      # or the 6.18 track without KERNEL_TRACK

It patches the driver into the build tree, builds and swaps only the module, builds and installs `libaipudrv`,
builds `npu-run`, and benchmarks MobileNetV2 and YOLOv8n from the model hub.

## Results

Pending.
