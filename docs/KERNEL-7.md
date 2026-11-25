# Kernel 7 track (7.3.5)

The `KERNEL_TRACK=7` track builds the Orange Pi 6 (non-Plus) kernel from **kernel.org 7.3.5 stable** instead of
6.18 LTS. It is the default track since v2026.11.24. Sky1-Linux/linux-sky1 has no 7.x patch set (its newest tracks are 6.18.14 LTS, 6.19.4,
and an rc/next set based on early 7.0 development), so this repo carries its own forward port in
`patches/7.3/`.

Status (2026-11-24): **the default track**, released as **v2026.11.24** after a proving run on the release build
(10/10 warm reboots, 3/3 cold boots, 8 h of full builds and `stress-ng --verify` with 16/16 stress rounds and 15/16
builds). 6.18.64 LTS stays available with `KERNEL_TRACK=6.18`. It was merged into `main` on 2026-11-22 as an
optional track (pre-release v2026.11.22). The 7.3.5 build at `0abe703` (55 patches) boots in ACPI mode, passes
`setup.sh check`, matches 6.18 on the GPU, and since `0055` matches 6.18.64 on the CPU within about 2%. Earlier builds
of the track passed a 1 h load test at 6000 MT/s and a warm reboot test. Open: the final build has had one boot, and
the AER fix `0053` has not yet been seen on a boot that would have stormed. The board results below are in date order.
(History: on 2026-11-19 the track was compile-checked only, with a cross-build on Ubuntu 24.04, aarch64 gcc 13.3.)

Known gap: the CIX display drivers (linlon-dp DPU, trilin DP, eDP panel) do not build on 7.x yet,
so `kernel.conf` turns `DRM_CIX` off on this track (`KCONFIG_EXTRA`). They need the new DRM private-object
(`atomic_create_state`) and panel allocation APIs. The board runs headless, and Panthor does not
depend on them. `scripts/setup.sh --prebuilt` installs the v2026.11.24 release kernel.

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

Both tracks use the same scripts. `kernel.conf` sets these per track (`KERNEL_TRACK=7`, the default, or `6.18`):

| Setting | 6.18 | 7 |
|---|---|---|
| `KV` | 6.18.64 | 7.3.5 |
| `SKY1_PATCHES` | `patches` (applied) | `patches-next` (what the port came from) |
| `LOCAL_PATCHES` | unset | `patches/7.3` (applied instead of Sky1's) |
| `SKY1_CONFIG` | `config.sky1` | `config.sky1-next` |
| `ALLOW_FUZZ` | 0 (1 only for experiments) | 0 |
| `KCONFIG_EXTRA` | unset | `--disable DRM_CIX --disable DRM_CIX_EDP_PANEL` |
| `RELEASE_TAG_DEFAULT` (for `--prebuilt`) | v2026.11.19.1 | v2026.11.22 |

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
| Network | `r8169` drives the RTL8125B | Mainline `r8169` (+ `REALTEK_PHY`) since 2026-11-21, as on `main`; vendor `r8125` with `NIC_DRIVER=r8125`. The 2026-11-19 audit kept `r8125`, assuming `r8169` could not run in this ACPI setup; that was never tested, and on 6.18.64 `r8169` works and fixes the warm-reboot NIC loss. Cadence `macb` ACPI match |
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
- 2026-11-25, `0057` (from review of the same code on armbian/build#11552): the guard keeps a
  counter and re-arm state per AER line instead of one shared counter (a second storming line
  could slip past the exact-64 test), and suspend/remove disable the AER lines before cancelling
  the re-arm work. Compile-tested only; not yet in a release.
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

- 2026-11-20, 59181e1 boot (`0053`): no AER lines at all on sky1-pcie.2, but also no "LTSSM
  transition indication latched" line. That line is printed whenever the bit is found set, at
  interrupt enable or on an AER interrupt, so on this boot bit 31 never reached aer_nf. The
  storm is intermittent (it follows a PHY-ready retry), so one quiet boot does not prove `0053`;
  the local IRQ handler's "LTSSM_TRANS_DEBUG_CTRL_STATUS" / "ltssttran changed" lines show
  whether the bit was handled there instead.
- Same boot: r8125 read an all-zero MAC and picked random ones, and the `.link` pins did not
  apply. The random MAC then survived the warm reset in the NICs, so Armbian's r8169 read it
  too. `install.sh stage` builds the pins from what r8169 reads, so a stage run now would have
  pinned the random address. It now refuses locally administered (random) MACs and says to
  power the board off for 30 s, which reloads the factory address. Cause of the missed pins:
  under sky1 the NICs' ID_PATH carries the host bridge prefix
  (`platform-sky1-pcie.3.auto-pci-0000:61:00.0`), so the exact `Path=pci-...` never matched and
  99-default.link applied. Earlier boots only looked right because the NICs still held the real
  address from Armbian. The pins now match `Path=*pci-<address>`.

- 2026-11-21, 6.18.64 on a fresh boot at 6000: pp512/tg128 123.5/36.5 as booted, the same
  with EAS off, the performance governor or pinning. The 96/25 above came from one bad boot
  right after a warm reboot from 7.3.5. Memory bandwidth (`bw.sh`) is the same on both kernels
  (write ~18.3 GB/s, read ~11.8-12 GB/s). So 7.3.5 as booted is about 12% slower than 6.18.64,
  and only pinning to the big cores closes the gap: a placement change in the 7.x scheduler.
  EAS, LLC balancing and the governor are ruled out. `cpu-diag.sh` now also samples which CPU
  each busy benchmark thread is on.

- Placement suspects in the 7.x scheduler, from diffing kernel/sched against 6.18.14: sched
  domains, cache topology, EAS and LLC balancing are already ruled out. What is left is the
  newidle balancing that lets an idle big core pull a running thread off a little core. 7.x
  adds `NI_RATE` (newidle balancing throttled by a time-based rate) on top of `NI_RANDOM`,
  which 6.18 already had in a simpler form. `HRTICK` is new but compiled off here.
  `bench/sched-ab.sh` A/Bs both features at runtime through debugfs. If one of them closes the
  gap, the fix is a boot-time setting. Otherwise the next candidate is `CONFIG_UCLAMP_TASK=y`
  (off in both configs), so the benchmark can ask for big cores with `uclampset -m 1024`.

- 2026-11-21, thread placement on 7.3.5: in almost every sample, 1-4 of the 8 threads sit on a
  little core (cpu2-5) while a big core is idle; pinned, none do. Turning off `NI_RATE`,
  `NI_RANDOM` or both changes nothing, and neither does going back to the 6.18 misfit
  accounting (the first `0054` experiment, dropped). The `sched_verbose` dump showed a candidate:
  each CPU has a CLS domain (its cluster) under one MC domain with ASYM_CPUCAPACITY across all
  12 CPUs, and CLS still has `SD_PREFER_SIBLING`. 6.18's `sd_init()` cleared that flag on the
  child of an asymmetric-capacity domain; 7.x dropped the rule. Balancing at MC reads the flag
  from the busiest group (the child's flags), so it evens the thread count across the five
  clusters, the little one included. `0054` now restores the 6.18 rule. Cross-check on 6.18.64:
  same domains and MC flags, and CLS has no `SD_PREFER_SIBLING`, so that flag is the only
  difference.

- 2026-11-21, `0054` on the board (95fc193): the sched-domain flags now match 6.18.64 exactly,
  but throughput does not change (pp512/tg128 108.8/29.9 as booted, 119.9/34.5 pinned to the big
  cores). So the domain setup is not the cause. `0054` stays because it restores the 6.18
  behaviour and costs nothing, but it does not fix the gap.
- 2026-11-21, `bench/util-probe.sh` (tg only, `-p 0 -n 512 -t 8`) on both kernels: no thread
  ran on cpu2-5 on either kernel, and both stacked two threads on some big CPUs. Per-thread
  util_avg was 850-1018 on both, and per-thread runtime 28.5-29.3 s on both. Frequency
  invariance (PELT util against capacity) is therefore the same on both kernels and is ruled
  out. The little-core placement only shows up in the full pp512 + tg128 run, so it starts in
  the prompt-processing phase or at the change between phases. Threads that land on a little
  core during pp may stay there through tg, which would explain why tg128 is slower too. The
  probe now takes a mode: `util-probe.sh pp` (pp only) and `util-probe.sh both` (pp512 + tg128,
  sampled every 2 s, with a count of threads on little cores per sample). uutils `sort` (Ubuntu
  26.04) rejects `-t=`, so the probe no longer uses it.
- Next for the CPU gap: run `util-probe.sh pp` and `util-probe.sh both` on both kernels to see
  when threads move to the little cores and whether their util is low at that point. The pp
  phase has short bursts with many sleeps and wakeups between matrix ops, so wake placement
  (`select_idle_sibling` / `select_idle_capacity`, `asym_fits_cpu`) is the next suspect. That
  code is next to diff against 6.18. Workaround until then: `taskset -c 0,1,6-11`.
- 2026-11-22, likely cause found in the wakeup path: 7.x added the SIS_UTIL `nr_idle_scan` cut to
  `select_idle_capacity()`, the scan that picks an idle CPU for a waking task on an
  asymmetric-capacity system. With 8 of 12 CPUs busy the hint is about 6, so the scan stops after
  six CPUs counted from the wakeup target. The benchmark threads' util (~900) fits no CPU within
  the 80% capacity margin, so the scan keeps the highest-capacity idle CPU it has seen; from
  cpu0/1 the next CPUs are the little cpu2-5, and idle cpu6-11 are never looked at. 6.18 scanned
  the whole domain. The threads wake often in prompt processing and rarely in token generation,
  which fits the tg-only probe showing no little-core placement. Runtime test with no build:
  `bench/sched-ab.sh base no-sis-util` (turns SIS_UTIL off through debugfs). Fix: `0055` scans
  the whole domain again.
- 2026-11-22, confirmed on 7.3.5 (6000 MT/s, NVMe fan on), `sched-ab.sh base no-sis-util`:
  base 109.04/29.49 tok/s (pp512/tg128) with threads on little cores in 4 of 4 samples;
  NO_SIS_UTIL 122.06/35.88 with one thread on a little core in 1 of 3 samples. That is +12% pp
  and +22% tg, level with pinning to the big cores (121.4/34.7) and with 6.18.64 (123.5/36.5).
- 2026-11-22, 7.3.5 built with `0055` (0abe703, also the first 7.3.5 boot on r8169), `cpu-diag.sh`:
  base 121.67/35.70, pin-big 121.33/35.87, nollc 121.28/35.70, noeas 121.37/35.65, perf
  124.22/36.64. As booted now equals pinned (+0.3% pp, -0.5% tg) and is within about 2% of 6.18.64.
  One thread still often shows on cpu2/3 in a sample, at no measurable cost. The CPU gap is
  closed and `taskset` is no longer needed.
  Full write-up of the cause, the method, all numbers and how to reproduce: `docs/kernel7-cpu-scheduling.md`.
- 2026-11-21, warm reboots: every warm reboot from a sky1 kernel (6.18.64 or 7.3.5) into Armbian
  that night failed NIC link training (Root Port 2/3, LTSSM 0x40C80), and SysRq over serial
  recovered all 9. Reboots from Armbian into a sky1 kernel always trained. So the sky1 kernels
  leave the PCIe ports in a state the firmware's link training cannot recover from on reset,
  and Armbian's driver does not. The suspect is the sky1 PCIe driver's syscore shutdown hook
  (`sky1_pcie_syscore_op_shutdown`). It holds the endpoints in PERST and switches their power off
  (and their power-on pin, when it is not standard), but it leaves the root port's LTSSM and
  PHY as they are. To test: boot a sky1 kernel with that hook turned off (a one-line patch or a
  module parameter), warm reboot into Armbian a few times, and count link training failures.
  Result (on 6.18.64): not the PCIe driver. Realtek's `r8125` leaves the chip in that state at
  probe; with mainline `r8169` 5 of 5 warm reboots trained. See `docs/nic-r8125-vs-r8169.md`.
  The kernel 7 track builds with `r8169` too; the first 7.3.5 boot with it (2026-11-22) came up with the real MACs.

### Warm reboot test plan

Every hang needs a ~30 s power-off. Watch the serial log on the PC that captures it.

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

Done: boot, NVMe and both NICs, `setup.sh check`, GPU benchmarks, an hour under load at 6000 MT/s, a warm reboot
test, and the CPU comparison with `bench/cpu-diag.sh` on both kernels (gap closed by `0055`). Still wanted: more boots
and another long load run on the final build, and a boot where `0053` is seen to stop a storm.
