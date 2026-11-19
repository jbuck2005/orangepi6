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

## Testing on the board

Not done yet. Needed, in order: boots and reaches userspace (else the GRUB fallback returns to
Armbian), NVMe and both NICs, `setup.sh check` (panthor, render node, panvk, Panfrost), then the GPU
benchmarks against the 6.18 numbers in STATUS.md.
