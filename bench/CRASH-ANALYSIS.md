# Failure analysis: corruption crashes under full-chip load (2026-11-24)

Status: **open**. Reproducible in about 1 to 3 minutes. Avoided by capping one big A720 pair, cpu10-11
(policy10, rated 2.5 GHz), at 2.4 GHz with every other core at full speed:
`echo 2400000 | sudo tee /sys/devices/system/cpu/cpu{10,11}/cpufreq/scaling_max_freq` (until the next boot; same on
both kernel tracks). See [Weak-core hunt](#weak-core-hunt-and-clock-steps-2026-11-27-evening). Earlier workarounds:
every core at 2.2 GHz (until 2026-11-27), then the four big cores at 2.2 GHz (2026-11-27 to 2026-11-28).

## Symptom

On the release kernel (7.3.5-sky1, v2026.11.24 debs), with memory at 6000 MT/s and the NVMe fan running, rebuilding
the modules of a large kernel tree crashes the board within minutes. The crashes take many forms, which points to data
corrupted in hardware rather than to one software bug:

| Time | Where | What |
|---|---|---|
| 10:08 | kernel, idle CPUs 1, 8, 10 | `Watchdog detected hard LOCKUP` on three CPUs at once; "failed to stop secondary CPUs" |
| 13:58 | kernel, idle CPU 10 | `stack-protector: Kernel stack is corrupted in: return_address` |
| 14:07 | user space, `pahole` x2 | `malloc(): unaligned tcache chunk detected`, then a segfault, in two different modules |
| 14:12 | user space, 3 tools | `corrupted double-linked list`, two `Aborted` |
| 14:14 | kernel, CPU 11 (`resolve_btfids`) | `Unable to handle kernel paging request` in `update_process_times`, panic in interrupt |
| 14:52 | kernel, CPU 0 (`pahole`) | NULL dereference in `ktime_get_update_offsets_now`, panic in interrupt |
| 15:55 | kernel, CPU 0 (`pahole`) | `Oops - FPAC` (pointer authentication failure), panic |

The same step re-run straight after a failure can pass (14:09: clean). Temperatures stayed low in every run: CPU
at most 52 C, NVMe controller (sensor 1) 45-55 C. The kernel has no EDAC device, so memory ECC errors are not visible.

## Load that triggers it

`make -j6 modules` in a tree built with CIX's `config-7.3.defconfig` (cixtech/cix-linux-main): 4,443 modules, each
linked and then post-processed by `pahole` (BTF) and `resolve_btfids` (`CONFIG_DEBUG_INFO_BTF_MODULES=y`). That is
many short, memory-heavy, multi-threaded processes on all 12 cores at once. Our own sky1 config builds 1,559 modules
without BTF; it and `stress-ng --vm --verify --cpu` ran 10 hours uncapped without an error (HISTORY.md, 2026-11-24).

Reproducer: `bench/crash-repro.sh` (rebuilds all modules N times; optional core set and frequency cap).

## Results

Memory 6000 MT/s, fan on, release kernel, `-j6` unless noted. "Clean" = all runs finished with no tool crash.

| Cores | Cap (all policies) | Runs | Result |
|---|---|---|---|
| all 12 | none (2.6 GHz top) | 5 | **fail every time**: 3 kernel panics (10:08, 13:58, 14:14), 2 runs with tool crashes (14:07, 14:12) |
| A520 x4 (2-5), `-j4` | none (1.8 GHz top) | 2 | clean (17 min each) |
| A720 x8 (0, 1, 6-11) | none | 1 | **fail**: kernel panic after 2.5 min |
| A720 x8 | 1.8 GHz | 2 | clean |
| A720 x8 | 2.2 GHz | 2 | clean |
| A720 x8 | 2.3 GHz | 2 | clean |
| A720 x8 | 2.5 GHz (only cores 0-1 affected) | 2 | clean |
| all 12 | 1.8 GHz | 2 | clean |
| all 12 | 2.2 GHz | 3 | clean |
| all 12 | 2.5 GHz | 2 | **fail**: tool crash after 76 s, then kernel panic (FPAC) |

## What it suggests

- It depends on how hard the whole chip works, not on one core or one frequency step: eight big cores at up to
  2.5 GHz pass, but all twelve at 2.5 GHz fail. The little cores alone never failed.
- Heat is not it (cool in every run), and the memory speed was the same in passing and failing runs.
- Most likely: a supply rail sagging under the combined load (CPU and/or DDR rails, or the 20 V input), or too little
  voltage margin at the top frequencies. **Not proven**; it needs measurements we can't take from software.

## Power supply A-B-A test (2026-11-25)

Same reproducer, all 12 cores uncapped (2.6 GHz top), memory 6000 MT/s, release 7.3.5 kernel. Between the 100 W runs
of 2026-11-24 and these, a 3 mm aluminium heatsink was fitted to the SSD (same fan, same placement). Each run rebuilds
every module once; "time" is from the start of the run (run 1 on 65 W started from a cold tree, so it also compiled).

| Supply | Run | Result | Time | Failure |
|---|---|---|---|---|
| 100 W stock, fan only (2026-11-24) | 5 runs | 5 failed | 1-6 min | 3 kernel panics (hard lockup, stack corruption, paging Oops), 2 runs with tool heap corruption |
| 65 W, fan + heatsink | 1 | **fail** | 52 min (cold) | hard LOCKUP on CPUs 3, 6, 10 |
| 65 W, fan + heatsink | 2 | **fail** | 4.5 min | kernel Oops (paging request) in `resolve_btfids`, panic |
| 65 W, fan + heatsink | 3 | pass | 6.0 min | |
| 65 W, fan + heatsink | 4 | **fail** | 2.4 min | kernel Oops (paging request) in `resolve_btfids`, panic |
| 65 W, fan + heatsink | 5 | pass | 5.7 min | |
| 100 W stock, fan + heatsink | 1 | pass | 5.7 min | |
| 100 W stock, fan + heatsink | 2 | pass | 5.6 min | |
| 100 W stock, fan + heatsink | 3 | **fail** | 2.2 min | 3 tools: `corrupted double-linked list`, segfaults (no kernel crash) |
| 100 W stock, fan + heatsink | 4 | pass | 5.5 min | |
| 100 W stock, fan + heatsink | 5 | **fail** | 1.7 min | 2 tools: segfaults (no kernel crash) |

- The failures follow neither supply: 65 W failed 3 of 5, the stock adapter 2 of 5 on the same day. The weaker supply
  did not make it worse, so an undersized adapter is not the explanation.
- Fewer failures than on 2026-11-24 (2-3 of 5 against 5 of 5). The heatsink barely changed the SSD controller
  (sensor 1 averaged 53 C with and without it; maximum 54 C against 57 C), and the CPU stayed below 52 C in every run,
  so the difference is more likely chance with 5 runs each, or ambient conditions, than cooling.
- When a run fails, it fails early (1.7-4.5 min, apart from the cold-tree run); runs that pass take 5.5-6 min.
- The kernel exposes no voltage, current or power sensors on this board (hwmon has temperatures only, `AC` reports
  online, no USB-PD class), so supply behaviour can't be logged from software.
- The release build's usual stress test (full from-scratch kernel builds + `stress-ng --vm --verify`, 65 min,
  uncapped) passed with no errors on the stock adapter. The failure needs this heavier `pahole`/`resolve_btfids` load.

Updated view: memory or CPU voltage margin under full-chip load, independent of the external supply. The 2.2 GHz cap
still avoids it (3 of 3 clean). Next: more runs at 2.3-2.5 GHz on all cores to find the edge, and a report to Orange Pi.

## Firmware and kernel options (research, 2026-11-26)

Desk research; options 1-4 were tested on 2026-11-26 (next section).

### What the stock firmware can and can't change

- **No voltage, power-cap or OPP menu.** The Orange Pi firmware's setup pages (CIX System Manager > Soc
  Configuration) offer, for the CPU, only `LPI Max State`, `CPPC Interface Type` and per-core enables, plus the memory
  data rate. Nothing for CPU or SoC voltage.
- **The voltage plan lives in `csu_pm_config.bin`** (a 4 KB flash region read by the power-management firmware in
  `bootloader1`). Decoded from the 2026-10-19 Orange Pi 6 image (as extracted in
  [HeyMeco/edk2-cix-sky1](https://github.com/HeyMeco/edk2-cix-sky1) `vendor/orangepi/opi6/`, format v3.2):

  | Rail | Regulator | Power cap | Boot voltage | Guard band (`delta_mV`) |
  |---|---|---|---|---|
  | CPU little (A520 x4) | fixed | 2.5 W | 815 mV | +25 mV |
  | CPU mid 0 / mid 1 (A720) | MP2845 buck 2 (shared) | 6.5 W each | 790 mV | +30 mV |
  | CPU big 0 / big 1 (A720) | MP2845 buck 3 (shared) | 8 W each | 790 mV | +30 mV |
  | DSU (L3, cluster logic) | fixed | 5.5 W | 815 mV | +15 mV |
  | GPU | MP2845 buck 1 | 12 W | 790 mV | +20 mV |
  | SoC | MP2845 buck 0 | 9 W | 790 mV | +15 mV |

  The guard band is added to every OPP voltage by the power firmware. The OPP table itself is not in this file (it
  is built into `bootloader1`), and the newer `bootloader1` builds no longer take OPP overrides from it
  ([cixtech/bios#4](https://github.com/cixtech/bios/issues/4)); whether they still honour `delta_mV` is not known.
  The DSU and little-core rails are fixed regulators, so firmware can't raise them at all. The kernel can't set any
  of these: frequencies go through SCMI and the voltages are chosen by the power firmware.
- **Raising `delta_mV`** (e.g. +30 to +50 mV on the big and mid rails) would be the direct test of the voltage
  theory, but it means editing and reflashing the SPI flash (the region is CRC-protected; the CIX `pm_config`
  generator rebuilds it byte-identically). A bad flash needs a 1.8 V SPI programmer to recover. Not worth trying
  before the cheap tests below.
- **Other firmware.** No Orange Pi release newer than 2026-10-19 is known.
  [Neol00/edk2-cix-unlocked](https://github.com/Neol00/edk2-cix-unlocked) has a voltage/OPP/TDP menu, but only for
  the Orion O6 and only with an old `bootloader1` signed with a different key, so it can't run on this board.
  HeyMeco's tree boot-tests on the Orange Pi 6 but reuses the vendor `bootloader1` and `csu_pm_config.bin`, so it
  adds no voltage control.

### Other reports that look like this one

- [cixtech/bios#2](https://github.com/cixtech/bios/issues/2), Orion O6 at 6000 MT/s: intermittent `pahole`/BTF
  failures, `llvm-ar` segfaults and `free(): invalid pointer` during kernel builds, gone on retry. A CIX
  collaborator said an early O6 with similar trouble was fixed by lowering the memory rate, and Radxa's firmware 1.3.0
  lowered the O6 from 6000 to 5500. Separately, MTE misbehaved until an MTE option was enabled in the firmware.
- [cixtech/cix-linux-main#81](https://github.com/cixtech/cix-linux-main/issues/81), MS-R1: the compiler segfaults
  in every kernel build on CIX-patched kernels. The reporter's corruption stopped after disabling
  `CONFIG_SND_HDA_CIX_IPBLOQ` (`CONFIG_CIX_DST` was not enough). Our kernels build `CONFIG_SND_HDA_CIX_IPBLOQ=m`
  and have no `CIX_DST`. [cix-linux-main#70](https://github.com/cixtech/cix-linux-main/issues/70) (Orange Pi 6
  Plus) also saw HDA DMA errors before memory corruption.
- [cixtech/bios#5](https://github.com/cixtech/bios/issues/5), another MS-R1: DRAM corruption at one fixed spot even
  at 3200 MT/s and on kernels with no CIX patches, which looks like a faulty unit rather than this pattern.
- CPU errata: CIX's public TF-A (v2.7, June 2022) has only pre-release support for the A720 ("cortex_hunter") and
  A520 ("cortex_hayes") with no errata workarounds. Current TF-A applies, for A720 r0p0-r0p1, 2792132 (loads crossing
  a 4 KiB boundary may return corrupt data) and 2940794 (a load crossing a 64-byte boundary may return corrupt data),
  and for A520 3685825 (a CAS may lose its write). These are set in EL3 at reset, so Linux can't apply them, and
  whether CIX's closed BL31 sets them is not known.
  ([Neol00/edk2-cix-unlocked#9](https://github.com/Neol00/edk2-cix-unlocked/issues/9) lists them.)

### Options, ranked (benefit for the risk)

1. **Check the serial captures for firmware DDR ECC lines** (`DDRC IRQ ECC_SBE` / `ECC_DBE`) around the failing runs.
   The firmware reported these in the 2026-11-18 memory tests. None near the crashes points away from the DRAM and
   towards the CPU side; any near them points at the 6000 MT/s rate. No risk.
2. **Uncapped runs with `snd_hda_cix_ipbloq` blacklisted** (5 runs). Matches #81 and #70; a DMA fault would also
   explain corruption on idle CPUs. One modprobe line, reversible. A pass would also argue against the voltage theory.
3. **Uncapped runs with deep idle states off** (`cpupower idle-set -D 0`, or the firmware's `LPI Max State`). Three
   of the crashes hit idle CPUs (hard lockup on CPUs 1, 8 and 10; stack corruption on idle CPU 10), and many cores
   leaving power-down at once is the largest load step a shared buck sees. Runtime setting, reversible.
4. **Uncapped runs at 5500 MT/s, as a diagnostic only** (not a setting to keep). Tells a memory-controller margin
   problem at 6000 from a CPU one: the O6 report above was cured that way. Needs a firmware-menu change at the
   keyboard over the serial console.
5. **`arm64.nomte` on the kernel command line** (if `/proc/cpuinfo` lists `mte`), for one test set, after the O6
   MTE report. Reversible.
6. **Ask Orange Pi / CIX** with the reproducer: whether the closed BL31 applies the A720/A520 errata above, and for
   a firmware build with a larger CPU guard band. No risk, slow.
7. **Edit `delta_mV` in `csu_pm_config.bin` and reflash.** The only real voltage lever, but untested on this
   firmware generation and needs an SPI programmer as a fallback. Last resort.

The 2.2 GHz cap stays the workaround until one of these explains the failures (narrowed to the big A720 pairs on
2026-11-27, below).

## Tests of options 1-4 (2026-11-26)

Release 7.3.5 kernel, memory 6000 MT/s, stock adapter with the SSD heatsink, all 12 cores uncapped, the same
reproducer (`bench/crash-repro.sh`, one rebuild of every module per run; a passing run takes about 5.6 min).

**1. Firmware DDR ECC lines in the serial captures.** The capture (since 2026-11-18) has 2,567 `DDRC IRQ ECC` lines
(`ECC_SBE_WR`, `ECC_SBE_RD`, `ECC_DBE_RD`). All of them are from 2026-11-18 and 2026-11-19, the old-firmware and
6400 MT/s tests; the last one is at 19:53 on 2026-11-19 during a 6400 MT/s load run. None appear after the switch to
6000 MT/s on 2026-11-20, so none during any crash or failed run of 2026-11-24 to 2026-11-26. Either the corruption is
not in the DRAM, or the firmware's ECC report doesn't catch it at 6000.

**2. `snd_hda_cix_ipbloq` blocked** (`install snd_hda_cix_ipbloq /bin/false` and `blacklist` in modprobe.d; confirmed
not loaded after a reboot): **2 of 5 failed**, the same as without the block.

| Run | Result | Time | Failure |
|---|---|---|---|
| 1 | **fail** | 2.2 min | hard LOCKUP on CPUs 0 and 8, panic |
| 2 | pass | 5.7 min | |
| 3 | pass | 5.7 min | |
| 4 | pass | 5.6 min | |
| 5 | **fail** | 4.3 min | build tool heap corruption (`corrupted size vs. prev_size`) |

**3. Deep idle states off** (module loading again; sysfs: `disable=1` on LPI-1 and LPI-2 of every CPU, leaving only
LPI-0/WFI, re-applied after each reboot): **4 of 5 failed**, and faster.

| Run | Result | Time | Failure |
|---|---|---|---|
| 1 | **fail** | 2.3 min | hard LOCKUP on CPUs 6 and 10, panic |
| 2 | **fail** | 0.8 min | `pahole` produced broken BTF ("Error emitting field") and the build stopped |
| 3 | **fail** | 0.9 min | 3 build tools: heap corruption, segfault |
| 4 | **fail** | 1.2 min | 2 build tools: `malloc(): unsorted double linked list corrupted`, abort |
| 5 | pass | 5.6 min | |

**4. Memory at 5500 MT/s** (diagnostic only; set in the firmware setup, confirmed from the DMI tables; everything
else normal): **4 of 5 failed**, no better than 6000.

| Run | Result | Time | Failure |
|---|---|---|---|
| 1 | pass | 5.8 min | |
| 2 | **fail** | 5.3 min | build tools: bus error, illegal instruction, segfault |
| 3 | **fail** | 1.5 min | build tool heap corruption (`corrupted double-linked list`) |
| 4 | **fail** | 5.5 min | build tool heap corruption |
| 5 | **fail** | about 2 min | kernel NULL-pointer Oops on CPU 10, panic |

- Lowering the memory rate didn't help, unlike the Orion O6 report (cixtech/bios#2), so this is not a DRAM or memory
  controller timing margin at 6000.
- What's left: the CPU side under sustained full-chip load at full clock speed. All 12 cores capped at 2.2 GHz is the
  only setting that has never failed. Candidates are the cores' voltage margin (the power firmware's guard band, not
  settable from Linux) and the A720/A520 errata that a current TF-A applies at reset but CIX's closed BL31 may not.
  Both are firmware matters: next is option 6, asking Orange Pi / CIX with the reproducer.
- Memory set back to 6000 MT/s afterwards.

- The HDA driver is not the cause on this board (unlike cix-linux-main#81 on the MS-R1).
- Keeping the cores out of deep idle made it no better and probably worse (4 of 5, failing within about a minute).
  So it isn't the power-down/wake-up step of idle cores. Keeping every core awake raises the steady load on the
  shared rails instead, which fits a margin problem under sustained full-chip load.
- Normal config restored: modprobe.d entry removed (module loads), all idle states enabled.
- Option 4 (5500 MT/s) is above: not the memory rate either. Next: option 6 (ask Orange Pi / CIX).

## RMA evidence tests (2026-11-26 to 2026-11-27)

Same reproducer, all 12 cores uncapped (2.6 GHz top), memory 6000 MT/s (checked from the DMI tables), stock 100 W
adapter, SSD heatsink fitted. The SSD fan was off from 2026-11-27 12:13 UTC (factory-like) and at 5 V from 13:24 UTC.

**A stock kernel with none of this repo's patches fails too.** Armbian's own `6.18.45-current-arm64` (the kernel of
the stock Armbian image, booted one-shot from GRUB entry 0, `cppc_cpufreq`, up to 2.6 GHz): **4 of 5 failed.**

| Run | Result | Time | Failure |
|---|---|---|---|
| 1 | **fail** | 4.9 min | `Oops - FPAC` in `pahole` (CPU 0), more Oopses on CPU 1, fatal panic in interrupt, hung (no `panic=` on that kernel) |
| 2 | **fail** | 4.6 min | `Oops - FPAC` in `resolve_btfids` (CPU 1); the build then stalled |
| 3 | pass | 5.4 min | |
| 4 | **fail** | 0.7 min | `Oops - FPAC` in `resolve_btfids` (CPU 0), "Fixing recursive fault but reboot is needed!", hung |
| 5 | **fail** | 0.7 min | 2 build tools: heap corruption (with `kernel.panic=10`, `panic_on_oops=1` set) |

**This repo's 6.18.64 LTS release kernel** (v2026.11.25 package; SSD fan off): **3 of 5 failed** (build-tool
crashes at 1.4 and 2.2 min; `Oops - FPAC` in `resolve_btfids` on CPU 10 and a fatal panic at about 3 min; two passes).
The SSD controller (sensor 1) reached 90 C with the fan off; the CPU stayed below 57 C.

**Self-checking stress without a compiler** (kernel 7.3.5, uncapped, 8 min each): `stress-ng --verify` with
`--cpu 12 --cpu-method all`, `--matrix 12` and `--vm 12 --vm-bytes 75% --vm-method all` passed 12 of 12 each, and 12
memtester instances of 700 MB (one pinned to each core, one loop) finished with 0 failures. So the failure needs the
`pahole`/`resolve_btfids` load; standard stress tools don't show it.

**CPU errata.** CIX's TF-A sources carry no Cortex-A720/A520 errata code, but have a non-secure SiP call
(`0xc200000e`, `CIX_SIP_PI_TEST_ENABLE`) that opens the CPUACTLR registers to the kernel. With it, a test module read
them on every core (MIDR: A720 `0x410fd811` r0p1, A520 `0x410fd801` r0p1):
- **All the workaround bits a current TF-A sets at reset were 0 on all 12 cores**: A720 2729604 (CPUACTLR[61:60]),
  2792132 (CPUACTLR2[26]) and 2940794 (CPUACTLR2[37]); A520 3685825 (CPUACTLR[9]) and 3631357 (CPUACTLR[27]). The
  shipped BL31 (`v2.7(debug):Beta_2.1.5_release`) doesn't apply them.
- With all of them set on every core (confirmed 12 of 12 before each run and still set after the last), and deep idle
  off so a core power-down couldn't clear them: **4 of 5 still failed** (segfault 2.5 min, bus error 3.3 min, heap
  corruption 3.4 and 3.2 min), the same as the 4 of 5 baseline with deep idle off. The missing errata are real but
  are not the cause.

What's left after every software-side test: the CPU side under sustained all-core load at full clock speed, most
likely voltage margin at the top operating points, which only the power firmware sets. All 12 cores capped at
2.2 GHz is still the only setting that has never failed.

## Per-cluster caps (2026-11-27)

Same reproducer and setup as above (release 7.3.5 kernel, memory 6000 MT/s, stock adapter, SSD heatsink, SSD fan at
5 V), 5 runs each, with only some cpufreq policies capped at 2.2 GHz and the rest at their full speed. The policies
on this board (the same on 6.18.64 and 7.3.5):

| Policy | CPUs | Top speed | Group | Regulator (firmware power table) |
|---|---|---|---|---|
| policy0 | 0, 1 | 2.6 GHz | A720 big | big-core rail (shared) |
| policy10 | 10, 11 | 2.5 GHz | A720 big | big-core rail (shared) |
| policy6 | 6, 7 | 2.3 GHz | A720 mid | mid-core rail (shared) |
| policy8 | 8, 9 | 2.2 GHz | A720 mid | mid-core rail (shared) |
| policy2 | 2-5 | 1.8 GHz | A520 little | fixed |

| Capped at 2.2 GHz | At full speed | Failed | Details |
|---|---|---|---|
| big pairs (cpu0-1, 10-11) | mid pairs, littles | **0 of 5** | all clean, 5.6-5.8 min each |
| mid pairs (cpu6-9) | big pairs (2.6 / 2.5 GHz), littles | **4 of 5** | 3 kernel panics (stack corruption, 2x `Oops - FPAC`), 1 build-tool crash |

- The failure needs the big A720 pairs at their top speeds while the rest of the chip is busy. The mid pairs and
  the littles at full speed are fine with the big pairs capped.
- The second set is close to uncapped: policy8 tops out at 2.2 GHz anyway, so it only lowered cpu6-7 from 2.3 GHz.
  It shows the failure doesn't need the mid pairs fast, and is a control for the first set rather than its mirror.
- 5 runs each is a small sample: 0 of 5 against an uncapped baseline of 2-5 of 5 is a clear difference, but not proof
  that the narrow cap never fails. More runs at it will follow in later test sets.
- **Workaround from 2026-11-27 to 2026-11-28** (since replaced by the cpu10-11-only cap below): cap only the big pairs (12-15% off their top speed). The speed gain over the all-core cap is
  small: that cap also slowed only cpu6-7 (2.3 to 2.2 GHz), since cpu8-9 and the littles already top out at or below
  2.2 GHz. Its value is that it names the cores at fault. The command:
  `echo 2200000 | sudo tee /sys/devices/system/cpu/cpu{0,1,10,11}/cpufreq/scaling_max_freq` (until the next boot).
  It names the CPUs, not the policies, so it doesn't depend on policy numbering. In the reproducer:
  `MAXF=2200000 MAXF_CPUS=0,1,10,11`.
- Together with the earlier tests this points at voltage margin on the big-core rail at 2.5-2.6 GHz under all-core
  load, a power-firmware setting.

**Big pairs at 2.4 GHz** (same setup; cpu0, 1, 10 and 11 capped at 2,400,000 kHz, read back exactly; the logged
clock of cpu0 sat at 2.4 GHz under load; mid pairs and littles at full speed; `panic_on_oops=1`): **0 of 5 failed**,
all runs clean in 5.5-5.6 min. With the earlier all-core 2.5 GHz set (2 of 2 failed, both big pairs at 2.5 GHz),
the edge for the big pairs lies between 2.4 and 2.5 GHz. A 2.4 GHz cap on those four cores (8% off cpu0-1, 4% off
cpu10-11) would be a lighter workaround than 2.2 GHz, but it rests on 5 runs only; the documented workaround stays
at 2.2 GHz until more runs back the 2.4 GHz one.

## Weak-core hunt and clock steps (2026-11-27 evening)

Release 7.3.5 kernel, memory 6000 MT/s, deep idle normal, SSD heatsink and fan at 5 V, all 12 cores loaded
(`CPUS=0-11 J=6`), per-policy caps set by hand (`scaling_max_freq`, read back exactly and confirmed under load from
the logged clock of cpu0), `panic_on_oops=1`, caps re-applied after every crash reboot, one run per rebuild of every
module.

| Set | policy0 (cpu0-1) | policy10 (cpu10-11) | Runs | Failed | Failures |
|---|---|---|---|---|---|
| 1a | 2.6 GHz (full) | 2.2 GHz | 5 | **0** | |
| 1b | 2.2 GHz | 2.5 GHz (full) | 5 | **4** | 3 kernel panics within 2 min (2x stack corruption, 1 Oops), 1 run with build-tool crashes at 1.7 min |
| 2a | 2.5 GHz | 2.5 GHz | 5 | **3** | build-tool crashes at 1.2 and 5 min, 1 kernel panic at about 4 min |
| 2b | 2.45 GHz | 2.45 GHz | 5 | **3** | 1 kernel panic (Oops) at about 4 min, build-tool crashes at 4.3 and 2.4 min |
| 3 | 2.4 GHz | 2.4 GHz | 20 | **0** | all 20 clean, 5.6 min each |

Mid pairs (cpu6-9) and the A520s at full speed in every set. CPU at most 55 C; SSD controller about 64-67 C.

- **The weak pair is cpu10-11 (policy10).** The fastest pair, cpu0-1 at its full 2.6 GHz, passed 5 of 5 with
  cpu10-11 capped; cpu10-11 at its full 2.5 GHz failed 4 of 5 with cpu0-1 capped.
- **Its edge is between 2.40 and 2.45 GHz** under this load: 2.45 GHz failed 3 of 5, and 2.4 GHz passed 20 of 20
  (plus 5 of 5 earlier the same day), 25 clean runs in all.
- A one-pair problem fits a part whose cpu10-11 pair has too little voltage margin at its rated 2.5 GHz on this unit,
  more than a board-wide supply issue: the other big pair shares the same regulator and is fine at 2.6 GHz.
- Lightest workaround the data supports: cap cpu10-11 alone at 2.4 GHz (4% off that pair, nothing off the rest).

**cpu10-11 alone at 2.4 GHz** (2026-11-28 00:50-02:55 UTC; policy10 at 2,400,000 kHz, cpu0-1 at its full 2.6 GHz,
mid pairs and A520s at full speed; same setup): **0 of 20 failed**, every run clean in 5.6 min. CPU at most 54 C, SSD
controller at most 67 C (fan at 5 V, logger checked before every run). Counting the two 2.4 GHz sets with both fast
pairs capped (25 runs) and this one, cpu10-11 at 2.4 GHz has passed 45 runs, while at 2.45 GHz and above it failed
10 of 15. On this unit, capping cpu10-11 at 2.4 GHz is the lightest workaround that has held, and since 2026-11-28 it
is the documented one (README, INSTALL, STATUS, the v2026.11.25 release notes):
`echo 2400000 | sudo tee /sys/devices/system/cpu/cpu{10,11}/cpufreq/scaling_max_freq`. cpu10 and cpu11 share one
cpufreq policy, so this caps exactly that pair; it names CPUs rather than policies, so it is the same on the 6.18 and
7 kernel tracks. In the reproducer: `MAXF=2400000 MAXF_CPUS=10,11`. The runs were on the 7.3.5 kernel; the same fault
shows on 6.18 (our 6.18.64 and Armbian's stock 6.18.45 both fail uncapped).

## Earlier events that may be the same thing

- The silent hangs and the kernel panic during full kernel builds (2026-11-21), put down to NVMe heat. The fan fixed
  the NVMe temperature, but this shows build-type load can also corrupt memory with a cool NVMe.
- The one 49 s build failure in the 8-hour kernel-7 run (2026-11-23), whose log was lost.

## Next steps

1. Done: the weak pair is cpu10-11 (edge 2.40-2.45 GHz), and a 20-run confidence set with only that pair at
   2.4 GHz passed, so that cap replaced the 2.2 GHz one as the advice on 2026-11-28. Still open: a confidence run
   with the cap on the 6.18 track, and whether to ship the cap as a boot setting. The test kernels built on 2026-11-25 (CIX 7.3, SIS_UTIL fix, misfit traces) were all built at the
   all-core 2.2 GHz cap without a crash.
2. Power: an A-B-A swap to a 65 W supply (above) showed it doesn't follow the supply. Measuring the board's own
   rails under load would still help; measure input current or voltage under the failing load if a USB-C meter
   is available. Try another supply.
3. Firmware: the 2026-10-19 firmware exposes no CPU or DDR voltage or power settings (see "Firmware and kernel
   options" above for the ranked tests instead).
4. Reported to CIX as [cixtech/bios#7](https://github.com/cixtech/bios/issues/7) (2026-11-26), with a follow-up
   on 2026-11-27 giving the stock-kernel, per-cluster and errata results and asking for a test firmware with a
   larger guard band or a lower top OPP for the big cores. A post on the Orange Pi forum is still to come.
5. Decide whether the release should ship the big-pairs frequency cap (a boot setting) until the cause is known.

## Logs

Kept off the repo (they contain the board's addresses): the serial capture since 09:30, the extracted panics and every
board-side run log (events, temperatures, make output) are archived on the logging PC under
`crash-analysis-20261124/`.
