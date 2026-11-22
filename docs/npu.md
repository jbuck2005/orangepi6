# NPU (Arm China Zhouyi X2) on the Orange Pi 6

Status: **working** on 7.3.5 (2026-11-22, module swap without a reboot). The 6.18.64 build and boot test is next.
Not in a release yet: v2026.11.22 and earlier have the old driver.

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

## Installing

On a board installed from this repo with a kernel that has the new driver, boot the sky1 kernel, then:

    scripts/setup.sh npu

It checks that the driver is 6.2.0, builds and installs `libaipudrv` (`/usr/local/lib`, headers in
`/usr/local/include/aipu`), builds `npu-run` into `/usr/local/bin`, and runs `npu-run info`:

    partitions: 1
    partition 0 cluster 0: 3 cores
    target: X2_1204MP3
    umd 6.0.0, kmd 6.2.0
    device status: idle

## Running a model

Compiled graphs are on CIX's model hub, `https://modelscope.cn/models/cix/ai_model_hub_26_Q2` (98 `.cix` graphs on
2026-11-22, no login; none of them is a YOLO model). Each model folder has the `.cix` graph, a `test_data/` folder
with sample inputs, and CIX's reference scripts. For example, MobileNetV2:

    HUB=https://modelscope.cn/models/cix/ai_model_hub_26_Q2/resolve/master
    M=models/ComputeVision/Image_Classification/onnx_mobilenet_v2
    curl -fLO $HUB/$M/mobilenet_v2.cix
    npu-run bench mobilenet_v2.cix 200
    tools/npu-prep.py photo.jpg photo.f32              # needs python3-pil and python3-numpy
    npu-run classify mobilenet_v2.cix photo.f32 imagenet_classes.txt

`classify` prints the top 5 ImageNet class indices (with names if you give it a labels file with one class per
line). `bench/npu-bringup.sh` does all of this, plus the driver swap below, in one go.

## Trying the driver without a reboot

On a sky1 boot whose build tree is still in `$WORK`, and whose kernel has `CONFIG_ARMCHINA_NPU=m`:

    KERNEL_TRACK=7 bench/npu-bringup.sh      # or the 6.18 track without KERNEL_TRACK

It patches the driver into the build tree (keeping a copy of the original), builds and swaps only the module, then
runs the library build and the model tests.

## Results

7.3.5-sky1, memory at 6000 MT/s, CIX's MobileNetV2 graph (s8 input 1x3x224x224, s8 output 1000):

| | |
|---|---|
| Graph load and job creation | 4.0-4.5 ms |
| Inference, 200 runs (input copy + run) | mean 1.84 ms, p50 1.89 ms, min 1.32 ms, max 2.16 ms: **542 runs/s** |
| `classify` on the 5 ImageNet validation images in `test_data/` | 1.65-1.81 ms each; top 5 in one family each time (snakes 61/62/54/60/66, birds 91/15/16/133/95, dogs 173/172/166/169/161) |
| Driver/library errors | none (after the free fix in the driver patch) |

For comparison, the reference results from the Orange Pi 6 Plus on CIX's own `libnoe` stack (visorcraft) were 13-16 ms
for CLIP and YOLOv8n graphs; MobileNetV2 is a much smaller network.

## Notes

- The first test showed every buffer free failing at teardown ("V3: invalid PA ... for ASID 48"): `libaipudrv`
  4.1.0 does not set `asid` in its free request, and CIX's custom per-ASID IOVA path trusted it. The driver patch now
  takes the ASID from the address (the ASID slots don't overlap).
- The 4.1.0 library builds with only `-Woverloaded-virtual` warnings on newer g++; `npu-umd.sh` drops `-Werror`.
- CIX's `libnoe` and ONNX Runtime provider should also work on this driver (they target the same ABI), but they are
  closed and not used here.
