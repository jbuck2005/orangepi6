# Kernel 7 track (7.3.5)

This branch builds the Orange Pi 6 (non-Plus) kernel from **kernel.org 7.3.5 stable** instead of
6.18 LTS. Sky1-Linux/linux-sky1 has no 7.x patch set (its newest tracks are 6.18.14 LTS, 6.19.4,
and an rc/next set based on early 7.0 development), so this repo carries its own forward port in
`patches/7.3/`.

Status (2026-11-19): **compile-checked only**. A cross-build (Ubuntu 24.04, aarch64 gcc 13.3) of
`Image`, all modules and the DTBs finishes with no errors, and the checks `install.sh verify` makes
on the built-ins hold (nvme, ext4, Sky1 PCIe host + PHY, ramoops, r8125, netconsole; panthor and
the NPU as modules). **Not yet built natively or boot-tested on the board.** The board build uses
the distro gcc (15 on Ubuntu 26.04), which may flag things gcc 13 did not.

Known gap: the CIX display drivers (linlon-dp DPU, trilin DP, eDP panel) do not build on 7.x yet,
so `kernel.conf` turns `DRM_CIX` off on this track. They need the new DRM private-object
(`atomic_create_state`) and panel allocation APIs. The board runs headless, and Panthor does not
depend on them. `setup.sh --prebuilt` has no 7.x release to download yet; build from source.

## How the port was made

1. Sky1-Linux `patches-next/` at commit `57e018a` (43 patches, the consolidated set for mainline)
   applies cleanly to **v7.0-rc1**, so that is its base.
2. Each patch was committed on v7.0-rc1 and then cherry-picked onto v7.3.5. Cherry-pick is a real
   3-way merge (base = the patch's own parent tree), so changes upstream made between 7.0-rc1 and
   7.3.5 merge in where they don't overlap.
3. 26 of 43 picked cleanly. The other 17 had conflicts, resolved by hand (list below).
4. `0044` is ours: build fixes for 7.x API changes in Sky1 code that merged cleanly but no longer
   compiled (`pm_runtime_put()` now returns void, xHCI latency masks, `strncpy`, part of the DRM
   `drm_atomic_state` to `drm_atomic_commit` rename).
5. The result is exported as `patches/7.3/*.patch`, one file per Sky1 patch, keeping the original
   Sky1 author, date and description. Where the port changed a patch, a bracketed
   "Forward-ported ..." note in its description says what. Applying all 44 to a clean 7.3.5
   reproduces the compile-checked tree exactly.

`scripts/02-fetch-patch.sh` applies them with `git apply` and no fuzz (`ALLOW_FUZZ=0` in
`kernel.conf`): they were generated against 7.3.5 exactly, so any mismatch is an error.

## Shared tooling

Both tracks use the same scripts; only `kernel.conf` differs per branch:

| Setting | `lts-6.18` | kernel 7 |
|---|---|---|
| `KV` | 6.18.64 | 7.3.5 |
| `SKY1_PATCHES` | `patches` (applied) | `patches-next` (what the port came from) |
| `LOCAL_PATCHES` | unset | `patches/7.3` (applied instead of Sky1's) |
| `SKY1_CONFIG` | `config.sky1` | `config.sky1-next` |
| `ALLOW_FUZZ` | 1 | 0 |
| `KCONFIG_EXTRA` | unset | `--disable DRM_CIX --disable DRM_CIX_EDP_PANEL` |

The kernel.org URL takes its `v6.x`/`v7.x` directory from `KV`. To rebuild the port after a new
7.3.y, re-run the cherry-picks on the new tag and regenerate `patches/7.3/`.

## Audit: what 7.3 already has for Sky1, and what it lacks

The board boots in **ACPI mode** (that is what the firmware hands over, and what the working 6.18
kernel uses). Mainline 7.3 has **no ACPI support for any Sky1 device**: there is not a single CIX
ACPI ID (`CIXH....`) in the tree. Everything mainline has is device-tree only, and for the Radxa
Orion O6 / Sky1 XCP boards.

| Area | In mainline 7.3.5 | Missing, so carried in `patches/7.3/` |
|---|---|---|
| DTS (`arch/arm64/boot/dts/cix`) | `sky1.dtsi` (CPUs, SCMI, UARTs, I2C/SPI/I3C, GPIO, pinctrl, mailboxes, PCIe, DMA-350), `sky1-orion-o6.dts`, `sky1-xcp.dts` | Full SoC description (GPU, NPU, VPU, DPU/DP, USB, audio, thermal, power domains), Orion O6N and Orange Pi 6 Plus boards. Our own `dts/sky1-orangepi-6.dts` builds on the Sky1 `sky1.dtsi`, not the mainline one. |
| Clocks | Main clocks come from generic SCMI (`clk-scmi`); `clk-sky1-audss` (audio, DT, auxiliary-bus design) | ACPI clock lookup (`CLKT` tables, `clk-sky1-acpi`), SCMI clock tweaks. Sky1's own audss driver replaces mainline's (it matches the Sky1 DTS bindings). |
| Resets | `reset-sky1`, `reset-sky1-audss` (DT) | Sky1 versions with ACPI support, and the reset **lookup-table API** that ACPI consumers use. 7.3 rewrote the reset core around fwnodes; the port falls back to the lookup table when an ACPI fwnode has no reset description. |
| Pinctrl | `pinctrl-sky1` (DT) | ACPI support and updated pin tables |
| Mailbox | `cix-mailbox` (DT) | ACPI support, channel lookup by fwnode |
| SCMI over ACPI | none | ACPI match for the mailbox transport, ACPI shared-memory discovery, shared base channel for all protocols. Needed for every SCMI clock, power and perf domain in ACPI mode. |
| PCIe | `pci-sky1` (DT, on mainline's Cadence "HPA" core) | Sky1's vendor host driver with ACPI scan handler, reset, ASPM and link fixes, and its own Cadence core. This is the driver the working 6.18 kernel uses for the NVMe and both NICs, so it replaces mainline's. |
| GPU (Panthor) | Panthor supports Mali-G720 generically (DT) | CIX Sky1: ACPI ID `CIXH5000`, GPU power-on via raw SCMI-over-SMC call (ACPI has no `smc_devpd`), RCSU mapping, reset and Q-channel clock gating, ACE-Lite bus coherency with shareable cache, NC memory attributes without an IOMMU, SCMI perf-domain DVFS. Ported by hand (7.3 split the register headers and changed the register accessors). |
| GPU `_CCA` override | none | `soc/cix` ACPI scan handler that marks the GPU non-coherent (firmware says coherent; DT parity) |
| Network | `r8169` drives RTL8125, but can't run in this ACPI setup the way we need | Vendor `r8125` (built in, as on 6.18; `r8169` stays off), Cadence `macb` ACPI match |
| USB | `cdns3` (7.3 merged cdns3 and cdnsp into one `cdns.ko`) | Sky1 USBSSP glue (`cdnsp-sky1`, `cdnsp-plat`) with ACPI PHY references, RTS5453 Type-C PD. The port keeps mainline's merged core and adds the Sky1 glue as `USB_CDNSP_SKY1`. |
| Display | none | `linlon-dp` DPU, `trilin` DP, PS185 bridge, `sky1-drm` render bridge |
| Audio | `cix-ipbloq` HDA (DT) | ACPI support, I2S, SOF DSP, ALC256 quirk |
| NPU | none | `armchina-npu` (Zhouyi), with ACPI DVFS |
| VPU | none | Linlon video codec driver |
| SMMUv3 | generic | Sky1 boot-active bypass STEs under ACPI, PCIe ATS override, event suppression |
| Misc | `spi-cadence` (DT) | GPT timer, PDC irqchip, thermal + IPA, PWM, watchdog, fan, eFuse, socinfo, hwspinlock, DSP remoteproc, ACPI IDs for the rest |

## Conflicts resolved by hand

| Patch | What changed upstream since 7.0-rc1 | Resolution |
|---|---|---|
| 0001 DTS | mainline added nodes to `sky1.dtsi` / `sky1-orion-o6.dts` | Sky1's versions (they are a superset and match the Sky1 drivers) |
| 0002 hwspinlock | `HSEM_U8500` removed | Kept only the Sky1 entry |
| 0003 clk | mainline `clk-sky1-audss` added | Sky1's driver and Kconfig |
| 0004 reset | reset core moved to fwnode lookups with per-controller locks; mainline Sky1 reset drivers added | Lookup-table fallback for ACPI fwnodes, taken under the controller lock; Sky1 drivers; duplicate Kconfig/Makefile entries removed |
| 0005 mailbox | `TXDONE_BY_ACK` renamed, `IRQF_NO_SUSPEND`, local header dropped | Sky1 driver with those mainline changes reapplied |
| 0006 SCMI | transport "supplier" handles; `of_node_get` in bus | Kept both: supplier handling and the ACPI match argument; ACPI shared-channel fallback after the `-EEXIST` check |
| 0008 PCIe | Cadence core split into HPA/common modules, debugfs | Sky1's Cadence core and host driver (the proven 6.18 path); only Sky1 boards use it in this config |
| 0010 USB | cdns3/cdnsp merged into `cdns.ko` | Mainline core; Sky1 glue added as `USB_CDNSP_SKY1` |
| 0011 Panthor | registers split per block, accessors take an iomem base, coherency setup moved to `panthor_gpu.c`, `panthor_pwr` added | Hand port, see below |
| 0012 DRM Kconfig | `DRM_LIB_RANDOM` removed | Mainline Kconfig plus the CIX source line |
| 0013 macb | `of_match_ptr` dropped | Mainline line plus the ACPI match |
| 0014 audio | new ALC fixups, `SND_HDA_CIX_IPBLOQ` gained a 64-bit DMA dependency | Union of fixups; mainline Kconfig entry |
| 0016 NPU | Kconfig/Makefile context | Union |
| 0017 thermal/cpufreq | boost path no longer updates QoS; CPPC updates perf limits each call; SCMI PD removes child ids | Kept mainline logic, added `topology_update_freq_ref()`; dropped Sky1's "skip redundant CPPC update" (it would skip the new limits update); `of_node` guard kept |
| 0018 misc | new SMMU option bit 6, `pm_ptr()` in spi-cadence, Gunyah watchdog | Kept both sides |
| 0042 hdmi-codec | `guard(mutex)` locking, ELD parse moved | Sky1's "no sink is not an error" logic in the new structure |

### Panthor on 7.3 (the part most likely to need board testing)

- Coherency: Sky1 programs `GPU_COHERENCY_PROTOCOL` = ACE-Lite (+ shareable cache bit when the GPU
  reports it) while the CPU side stays non-coherent (write-combined mappings, no coherent page-table
  walks). Userspace is told **no coherency** (`selected_coherency = NONE`), the same as what Mesa saw
  on our 6.18 kernel (6.18 has no such field). Sky1's next track left that field at 0, which means
  ACE-Lite to Mesa; we did not copy that.
- Memory attributes: forced non-cacheable only on Sky1 when the GPU is not behind an IOMMU.
  Other platforms keep mainline behaviour.
- PBHA/SYSC register setup and shader-core harvesting stay DT-only, as in every Sky1 track.
- In ACPI mode the GPU is powered with a raw SCMI `POWER_STATE_SET` over SMC before any register
  access, as on 6.18.

## Board results

- 2026-11-19, first boot (commit 193c5c5): native build on the board (gcc 15.2) had 0 errors.
  The boot reached `Linux version 7.3.5-sky1` and then died. The NVMe root port's AER interrupt
  fired about 90 times a second right after PCIe link training, with no error latched anywhere
  (root error status 0, DEVSTA error bits 0). Each interrupt logged two lines to the serial
  console while holding a spinlock with interrupts off, which led to a hard lockup in the AER
  thread at 24.6 s and a panic. The Sky1 PCIe driver code is the same as on 6.18, so something in
  the 7.x core makes the line assert. Not root-caused yet.
- Fix in `0045`: an AER interrupt with nothing latched returns `IRQ_NONE`. After 64 in a row,
  that line is disabled. The AER logging is rate-limited and printed after the lock is dropped,
  and probe logs the local/AER IRQ numbers so the next boot log shows which line it is.

- 2026-11-19, retest with `0045` (commit e736ada): native build with 45 patches, 0 fuzz. Boots,
  `setup.sh check` passes (7.3.5-sky1, panthor with render node, panvk Mali-G720 MC10, Panfrost).
  All three PCIe links up with no spurious AER lines, so the storm is gone. NVMe and both r8125
  are fine, ACE-Lite coherency is on. cpufreq is cppc_cpufreq on 5 policies and cpuidle is
  acpi_idle with LPI-0/1/2, the same as 6.18. GPU is at parity with 6.18.14 (vkpeak
  1201/2116/4859, vkmark 3468). Three new issues:
  - A one-time `__setup_irq` warning from the NPU probe: it asks for `IRQF_ONESHOT` with no
    threaded handler. Fixed in `0046`.
  - scmi-hwmon "Error enabling sensor ... err=-2" for every temperature sensor. 7.x added a
    SENSOR_CONFIG_SET call that passes the array position, not the sensor id, and skips the
    thermal zone when it fails. Fixed in `0047`: uses the id and registers the zone anyway.
  - CPU performance 12-20% below 6.18.14 (llama.cpp 1.5B Q4, 8 threads: pp512 108.6 vs 123.8,
    tg128 29.5 vs 36.6). Candidates: the CPPC "skip redundant update" patch that was dropped in
    the port (restored in `0048`), and the new cache-aware load balancing (`CONFIG_SCHED_CACHE=y`,
    on by default in 7.x). `bench/cpu-diag.sh` records topology, governor and frequencies and runs
    the benchmark as booted, with LLC balancing off, with the performance governor, and pinned to
    the biggest cores. Run it on both kernels and compare.
- The AER storm also shows up now and then on 6.18.64, right after "waiting PHY is ready! retries =
  1", with `dev_sts 0x3950` repeated (DEVCTL 0x3950, DEVSTA 0: no error bits). So it is latent in
  the shared Sky1 PCIe driver, not a 7.x core change. Likely cause (from reading the code, not yet
  confirmed on the board): the driver masks the AER-class local errors (PHY error, replay timeouts,
  FC and completion errors) from the local IRQ, and only the local IRQ handler ever clears
  `I_LOCAL_ERR_STS_REG0`. A PHY error latched during the PHY retry is never cleared, while the AER
  handler only clears the AER capability registers, which are empty. `0049` clears stale local
  errors before the interrupts are enabled, and clears and names any latched local error when an
  AER interrupt finds the AER registers empty. If the storm comes back, the log now says
  `local err0 <name> latched, cleared`, which confirms this, or shows `spurious AER irq` lines if
  the source is something else. `0045` stays as the backstop.
- Also seen, not changed: when the old handler re-enables root error reporting it writes to the
  PCIe capability offset instead of the AER offset, so after the first handled AER interrupt the
  root port's error reporting stays off.
- Warm reboot from 7.3.5 hangs after systemd-reboot finishes. The last lines are "watchdog0:
  watchdog did not stop!" (twice), and the firmware never resets; 6.18.x reboots fine. Our boot
  entries pass `efi=noruntime`, so the reset goes through PSCI SYSTEM_RESET (restart handler
  priority 129, ahead of the Sky1 watchdog's 128). That PSCI code is the same in 6.18.14 and 7.3.5.
  So either a driver shutdown or syscore callback hangs before the reset, or the firmware's reset
  fails because of the state 7.x left behind. `0050` is a debug patch that logs each step
  ("reboot: calling restart handlers", "reboot: PSCI system reset ..."). `install.sh arm` now takes
  `EXTRA_CMDLINE` for a one-shot boot, so `initcall_debug` can print one line per device shutdown
  and per syscore callback. Test plan below.
- Not done yet: an hour of load and stability testing on 7.3.5.

- 2026-11-19, load test at 6400 MT/s (commit c83e43f) FAILED. The firmware reported DDRC ECC
  errors on serial: about 6 min into a -j6 build, single- then double-bit write errors on
  channel 3, and later during stress-ng, read errors on channel 0 ("Link ECC Error on Byte1
  Beat 1 Dq2"), then "DFI detected", and the board hung. 6.18.64 ran 1 h of the same load at
  6400 clean, and 6.18.14 passed a 4 h soak at 6400.
  - What differs in software: nothing that reaches the memory controller. In ACPI mode the
    only Sky1 drivers that touch DDR (`cix-ddr-lp`, DDR low-power control over a TF-A SMC, and
    `cix-bus-perf`, interconnect DVFS) match only DT compatibles, so they do not bind, and they
    are the same code in the LTS set. No patch touches a DDRC, DMC devfreq or DDR SCMI perf
    domain. The base configs differ only in filesystems, netfilter, crypto and similar; the new
    7.x defaults add SoC and erratum options for other vendors, plus `SCHED_CACHE`. Nothing
    there controls memory timing, refresh or voltage, which the firmware sets at boot.
  - The errors are DQ link ECC errors, which point to signal margin at 6400 (the shipped
    firmware threw the same kind at 6400). A kernel can only move that margin indirectly,
    through temperature and supply load: how hard and how long the cores and memory run. One
    clean run against one failed run doesn't separate a kernel effect from a marginal part.
  - Next step: `bench/thermal-log.sh` logs every thermal zone and hwmon sensor (now including
    DDR_top/DDR_btm on 7.3.5), CPU clocks and EDAC counts every 5 s. Run it during the same
    load on both kernels and compare the DDR temperatures, or run 7.3.5 at 6000 (the firmware's
    Auto setting) for an hour with it logging.

- 2026-11-20, 6000 MT/s run (commit 5306e16): the AER storm came back at boot on sky1-pcie.2,
  aer_nf (irq 55), with no "local err0 ... latched" line. So the latched-local-error theory
  behind `0049` is wrong, or at least not the whole story. `0045` cut the line off at 5.39 s
  after 64 interrupts, and the boot carried on. `0051` (debug) dumps the root port's AER and
  PCIe capability registers, root control and status, the local error registers, the debug
  status register, the RCSU app status words and the IRQ trigger type when that happens.

- Live readout during that run: root port status all clear (DevSta, UESta, CESta, RootSta),
  root error reporting off (RootCmd CERptEn- NFERptEn- FERptEn-), link 16 GT/s x4 with
  equalization complete. irq 55 is GIC SPI 437, level-triggered, and took exactly 64
  interrupts between 5.23 s and 5.39 s. So the line is raised briefly while the link comes up,
  by something outside the standard error registers. `0052` switches the line back on 2 s
  after a burst (up to 5 times), so non-fatal error reporting isn't lost for the whole boot.

- 2026-11-20, 1 h load at 6000 MT/s (commit 5306e16) PASSED: kernel build -j6 in 21 min,
  stress-ng vm+cpu with --verify 0 failures, no DDRC or ECC lines on serial, EDAC 0/0. Peak
  70 C (CPU_B0 65, DDR_top 64, DDR_btm 57). This fits the 6400 failure being a memory-margin
  problem, not the kernel; 6000 (the firmware's Auto) is the setting to use with this track.
- Reboot test A PASSED on the same boot: "reboot: Restarting system", "calling restart
  handlers", "PSCI system reset (mode 0, reset2 1)", then the firmware banner. The earlier hang
  was at 6400, so it may share the memory cause, or be the board's known flaky warm reset.
  Watch for it again; tests B and C are not needed for now.

- First `cpu-diag.sh` log on 7.3.5 (c83e43f at 6400): as booted pp512 109.3, tg128 30.1; LLC
  balancing off and the performance governor change nothing (109.1/30.0, 110.2/30.5). Pinned
  to the 8 big cores it gives pp512 121.4, tg128 35.0, close to 6.18.14 (123.8/36.6). So the
  CPU slowdown is task placement: some of the 8 threads land on the four A520 cores (capacity
  279). EAS is on (`sched_energy_aware` 1). The cache topology also looks uneven: the big
  cores report a last-level cache shared by the 8 big cores, the little cores one shared by all
  12. `cpu-diag.sh` now adds an EAS-off variant and logs the sched domains and every cache
  level, to compare with a 6.18 run.

- 2026-11-20 12:32Z: the board hung while building on Armbian's own 6.18.45 kernel at 6000 MT/s,
  with the same signature as the 7.3.5 hang at 6400 (draw drops from ~36 W to a steady 23 W,
  off the network, serial silent, no ECC lines). So sustained heavy load can hang this board
  on more than one kernel and at 6000 too. The 6400 ECC errors are real, but they may not be
  the whole cause of the hangs, and the 7.3.5 failure at 6400 is no longer evidence against or
  for kernel 7 on its own. Open causes: power delivery under load, memory margin at 6000 as
  well, or something tied to compile load (NVMe/PCIe traffic). The 4 h clean soak on 6.18.14
  was stress-ng plus vkmark, without a compile.

- 2026-11-20, f6a7895 boot: after each re-enable `aer_nf` burst again within 7-15 ms, five
  times, then stayed off (384 interrupts). The `0051` dump found the source: local err0 bit 31,
  the LTSSM-transition indication, latched and not masked (`sts 0x80000000`, mask
  `0x0403ff00`), with every AER register clear. The driver only ever acked that bit from the
  local IRQ handler, and here it arrives on aer_nf. `0053` acks it from the AER handler the same
  way (AXI slave indication bit, LTSSM status channels, latched bit). The guard stays, but now
  only counts bursts.
- Silent hangs under build load: a repeat build on Armbian 6.18.45 at 6000 did not hang, but
  the NVMe's sensor 1 peaked at 87 C and stayed at 80 C or more for about 13 minutes, while the
  CPU sat at 43-45 C. A drive that throttles hard or drops off the bus at that temperature would
  stall the root filesystem. The board would then look dead (no ssh) and fall to near-idle
  power, which matches the 23 W hang signature. Check `sudo nvme smart-log /dev/nvme0` for
  thermal throttle counts and time above the warning/critical temperature. On the next hang,
  use SysRq over the serial console (`w`, then `t`) to see whether tasks are stuck on I/O.

- 2026-11-20, `cpu-diag.sh` on both kernels, same board, 6000 MT/s (pp512/tg128, tok/s):

  | variant | 7.3.5 | 6.18.64 |
  |---|---|---|
  | as booted | 109.8 / 30.1 | 96.3 / 25.0 |
  | LLC balancing off | 110.1 / 30.0 | n/a |
  | EAS off | 108.8 / 30.1 | 97.4 / 24.5 |
  | performance governor | 110.6 / 30.5 | 98.5 / 24.9 |
  | pinned to 8 big cores | 121.3 / 34.6 | 95.7 / 25.4 |

  Topology, capacities, cpufreq, sched domains, caches and cpuidle read the same on both. On
  7.3.5 the results match the 6400 run, and only pinning helps, so its gap to 6.18.14
  (123.8/36.6) is thread placement and not EAS, LLC balancing or the governor. 6.18.64 is slower
  than both in every variant, and pinning does not help it. Its own 11-19 run at 6400 gave
  123.4/36.5, and a drop from 6400 to 6000 MT/s cannot explain a 20-30% loss. So 6.18.64 has a
  separate regression on this boot, which matters for the LTS release.

### Warm reboot test plan

Every hang needs a ~30 s power-off. Watch the serial log from Prometheus.

1. Build natively and stage, then do a one-shot boot with
   `sudo SERIAL=1 EXTRA_CMDLINE=initcall_debug ./scripts/install.sh arm acpi`.
2. Test A: `sudo systemctl reboot`. Note the last lines on the serial log:
   - the last "shutdown" device line or "PM: Calling ..." syscore line means that callback hangs;
   - "reboot: Restarting system" but no "reboot: calling restart handlers" means the hang is in
     the gap between them (CPU stop);
   - "reboot: PSCI system reset" as the last line means the firmware reset itself hangs.
3. Test B, only if A hung: boot the same entry again and run
   `echo 1 | sudo tee /proc/sys/kernel/sysrq; sync; echo b | sudo tee /proc/sysrq-trigger`.
   This skips every device shutdown and syscore callback. If B resets but A did not, a shutdown
   callback leaves the board in a state where it can't reset, and A's log names it.
4. Test C, only if B also hung at the PSCI line: boot with
   `EXTRA_CMDLINE="initcall_debug cpufreq.off=1"` and repeat A.
   With cpufreq off there are no CPPC requests to the SCP, which the reset also goes through, so this rules out a stuck SCP mailbox.

## Testing on the board

Done: boot, NVMe and both NICs, `setup.sh check`, GPU benchmarks. Still needed: the CPU
comparison with `bench/cpu-diag.sh` on both kernels, then an hour under load
(`bench/soak-load.sh`) before this track is trusted.
