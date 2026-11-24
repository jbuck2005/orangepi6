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

## Earlier events that may be the same thing

- The silent hangs and the kernel panic during full kernel builds (2026-11-21), put down to NVMe heat. The fan fixed
  the NVMe temperature, but this shows build-type load can also corrupt memory with a cool NVMe.
- The one 49 s build failure in the 8-hour kernel-7 run (2026-11-23), whose log was lost.

## Next steps

1. More runs at the all-12-core 2.2 GHz cap, to know how safe it is; try 2.3 and 2.4 GHz to find the edge.
2. Power: check the supply (100 W 20 V PD), and measure input current or voltage under the failing load if a USB-C meter
   is available. Try another supply.
3. Firmware: check whether the 2026-10-19 firmware exposes CPU or DDR voltage or power limits.
4. Report to Orange Pi / CIX with the reproducer if it holds, since a stock Armbian user would hit it on any big
   parallel build.
5. Decide whether the release should ship a frequency cap (a boot setting) until the cause is known.

## Logs

Kept off the repo (they contain the board's addresses): the serial capture since 09:30, the extracted panics and every
board-side run log (events, temperatures, make output) are archived on the logging PC under
`crash-analysis-20261124/`.
