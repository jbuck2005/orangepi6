# Failure analysis: corruption crashes under full-chip load (2026-11-24)

Status: **open**. Reproducible in about 1 to 3 minutes. Avoided so far by capping every core at 2.2 GHz.

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

## Earlier events that may be the same thing

- The silent hangs and the kernel panic during full kernel builds (2026-11-21), put down to NVMe heat. The fan fixed
  the NVMe temperature, but this shows build-type load can also corrupt memory with a cool NVMe.
- The one 49 s build failure in the 8-hour kernel-7 run (2026-11-23), whose log was lost.

## Next steps

1. More runs at the all-12-core 2.2 GHz cap, to know how safe it is; try 2.3 and 2.4 GHz to find the edge. The test
   kernels built on 2026-11-25 (CIX 7.3, SIS_UTIL fix, misfit traces) were all built at 2.2 GHz without a crash.
2. Power: an A-B-A swap to a 65 W supply (above) showed it doesn't follow the supply. Measuring the board's own
   rails under load would still help; measure input current or voltage under the failing load if a USB-C meter
   is available. Try another supply.
3. Firmware: check whether the 2026-10-19 firmware exposes CPU or DDR voltage or power limits.
4. Report to Orange Pi / CIX with the reproducer if it holds, since a stock Armbian user would hit it on any big
   parallel build.
5. Decide whether the release should ship a frequency cap (a boot setting) until the cause is known.

## Logs

Kept off the repo (they contain the board's addresses): the serial capture since 09:30, the extracted panics and every
board-side run log (events, temperatures, make output) are archived on the logging PC under
`crash-analysis-20261124/`.
