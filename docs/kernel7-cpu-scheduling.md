# Kernel 7 CPU scheduling fix (patch 0055)

Kernel 7.3.5 on the Orange Pi 6 ran CPU-bound multi-threaded work about 12% slower than 6.18.64. For llama.cpp
token generation it was about 18% slower. Patch `patches/7.3/0055-sched-fair-scan-the-whole-asym-capacity-domain-on-wakeup.patch`
on the `kernel-7` branch fixes it. With the patch, 7.3.5 as booted is as fast as 7.3.5 pinned to the big cores, and
within about 2% of 6.18.64. `taskset` is no longer needed.

This page covers the symptom, how the cause was found, the cause, the fix, every measurement, and how to reproduce
them.

The kernel 7 track, including `0055` and `docs/KERNEL-7.md`, lives on the `kernel-7` branch. The diagnostic scripts in
`bench/` (`cpu-diag.sh`, `sched-ab.sh`, `util-probe.sh`) are on both `main` and `kernel-7`, and they work on any
kernel.

## The board's CPUs

The CIX Sky1 has 12 CPUs in five clusters. These are the scheduler capacities read from
`/sys/devices/system/cpu/cpu*/cpu_capacity`:

| CPUs | Capacity | Kind |
|---|---|---|
| 0, 1 | 1024 | big |
| 2, 3, 4, 5 | 279 | little |
| 6, 7 | 905 | big |
| 8, 9 | 866 | big |
| 10, 11 | 984 | big |

The little cores are numbered between two groups of big cores. That matters below, because the kernel scans CPUs in
number order.

The firmware's ACPI PPTT reports one L3 shared by all the big cores, and L1/L2 shared by all 12 CPUs, so the
scheduler builds:

- a CLS domain for each cluster;
- one MC domain that spans all 12 CPUs, with `SD_ASYM_CPUCAPACITY` (the CPUs differ in capacity) and `SD_SHARE_LLC`
  (they appear to share a last-level cache).

The MC domain is both the "last-level cache" domain (`sd_llc`) and the asymmetric-capacity domain
(`sd_asym_cpucapacity`). On most big.LITTLE systems those are different domains. This board is unusual in that they
are the same one, and that is what lets the 7.x change below reach it.

## Symptom

Benchmark: `llama-bench`, Qwen2.5 1.5B Instruct Q4_K_M, CPU only (`-dev none -ngl 0`), 8 threads, prompt processing of
512 tokens (pp512) and generation of 128 tokens (tg128). Results are tokens per second, written as pp512/tg128.

| Kernel | As booted | Pinned to the big cores (`taskset -c 0,1,6-11`) |
|---|---|---|
| 6.18.64 | 123.5/36.5 | — |
| 7.3.5 before the fix | 109.8/30.1 | 121.0/34.6 |

Pinning recovered almost all of the gap, so the cores themselves, the memory and the clocks were fine. The problem was
where the scheduler put the threads.

`cpu-diag.sh` samples which CPU each busy thread is on every 5 s. On 7.3.5 it showed 1 to 4 of the 8 threads on a
little core (cpu2-5) in almost every sample, while big cores sat idle. Pinned, none were.

### Why one thread on a little core costs so much

llama.cpp splits each operation across its 8 threads, and every thread waits at a barrier for the others before the
next operation starts. The slowest thread therefore sets the pace for all 8. A thread on a 279-capacity core does its
share at roughly a third of the speed of a big core, so one such thread stalls the other seven at every barrier. The
cost is much more than one eighth of the work. That is why token generation, with its many small synchronized
steps, lost more (−18%) than prompt processing (−12%).

## How the cause was found

Every step below was tried on the board, mostly at runtime with no rebuild, using scripts in `bench/`.

| Suspect | Test | Result |
|---|---|---|
| Energy-aware scheduling | `cpu-diag.sh` `noeas` variant (`kernel.sched_energy_aware=0`) | no change |
| 7.x cache-aware (LLC) balancing | `cpu-diag.sh` `nollc` variant (debugfs `llc_balancing/enabled=0`) | no change |
| cpufreq governor | `cpu-diag.sh` `perf` variant (governor `performance`) | no change in placement |
| Memory bandwidth, clocks | same `cpu-diag.sh` logs on both kernels | equal |
| Topology, capacities, caches, cpuidle | `cpu-diag.sh` header on both kernels | identical |
| Newidle balancing (`NI_RATE`, new in 7.x; `NI_RANDOM`) | `sched-ab.sh` `no-ni-rate`, `no-ni-random`, `no-ni-both` | no change |
| Misfit-task accounting (changed in 7.x) | experimental build restoring the 6.18 logic | no change; dropped |
| `SD_PREFER_SIBLING` on CLS (7.x stopped clearing it under an asymmetric domain) | build with `0054` restoring the 6.18 rule | domain flags now match 6.18.64 exactly, but speed unchanged (108.8/29.9) |
| Frequency invariance / PELT utilization | `util-probe.sh` (tg only) on both kernels | per-thread util 850-1018 and runtime 28.5-29.3 s on both kernels; no little-core placement in tg-only runs |

The last result narrowed it down. In a token-generation-only run, no thread went to a little core on either kernel.
The misplacement only appeared in runs that included prompt processing. During prompt processing the worker threads
block and are woken again far more often than during generation. That pointed at the **wakeup** path, which picks a
CPU every time a thread wakes. The load balancer, which had been the focus until then, was not the cause.

A function-by-function diff of `kernel/sched/fair.c` wakeup code between 6.18 and 7.3.5 then showed the change in
`select_idle_capacity()`.

## Root cause

When a task wakes on a system with CPUs of different capacity, `select_idle_sibling()` calls
`select_idle_capacity(p, sd_asym_cpucapacity, target)`. It walks the CPUs of that domain in number order, starting at
`target` (the CPU the task last ran on, or the waker's CPU) and wrapping around. It returns:

- the first idle CPU on which the task "fits"; otherwise
- among the idle CPUs it saw, the one with the highest capacity.

A task fits a CPU when its utilization is below 80% of that CPU's capacity. The benchmark threads run flat out, with
util around 850-1018, so they fit no CPU on this board, not even a 1024 core (the limit there is 819). Every wakeup
therefore takes the second branch: the highest-capacity idle CPU **among those scanned**.

6.18 scanned the whole domain, so the highest-capacity idle CPU it found was always an idle big core when there was
one.

7.x added a limit to that scan, taken from the `SIS_UTIL` feature already used by `select_idle_cpu()`:

```c
if (sched_feat(SIS_UTIL) && sd->shared) {
	nr = READ_ONCE(sd->shared->nr_idle_scan) + 1;
	if (nr == 1)
		return -1;
}
...
for_each_cpu_wrap(cpu, cpus, target) {
	...
	if (!has_idle_core && --nr <= 0)
		return best_cpu;
```

`nr_idle_scan` is updated during periodic load balancing at the LLC domain (`update_idle_cpu_scan()`). It shrinks as
the domain gets busier:

```
x  = sum_util / 12                         (average util per CPU)
y  = 1024 - x² · 117² / (10000 · 1024)     (117 = imbalance_pct of the MC domain)
nr_idle_scan = 12 · y / 1024
```

With 8 threads at around 900 util, sum_util is around 7200, so x ≈ 600, y ≈ 543 and `nr_idle_scan` ≈ 6. The scan
then stops after **six CPUs** counted from `target`. Because the MC domain here is both the LLC domain (so
`sd->shared` exists) and the asymmetric domain, the limit applies to this scan. On a typical big.LITTLE system the
asymmetric domain sits above the LLC domain, has no `shared` data, and is never limited.

Which six CPUs are scanned depends on where the thread last ran:

| target | CPUs scanned | Highest-capacity idle CPU it can find |
|---|---|---|
| cpu0 | 0, 1, 2, 3, 4, 5 | a little core when cpu0/1 are busy |
| cpu1 | 1, 2, 3, 4, 5, 6 | cpu6 if idle, else a little core |
| cpu6 | 6, 7, 8, 9, 10, 11 | a big core |
| cpu10 | 10, 11, 0, 1, 2, 3 | a little core when 10, 11, 0 and 1 are busy |

So a waking thread on cpu0/1, or on the upper big cores with the others busy, is put on an idle little core, and the
idle big cores on the other side of cpu2-5 are never looked at. If load is above about 85%, `nr_idle_scan` drops to 0,
the scan returns at once, and the thread goes back to `target` even if it is busy.

Once on a little core, a thread's next wakeup scan starts from that little core. From cpu2 it covers 2-7, and from
cpu5 it covers 5-10, so it reaches only some of the big cores. When those are busy, the thread stays on a little
core. Threads moved during prompt processing can therefore still be on little cores when generation starts. That
would explain why tg128 in the combined run was slow too, while a tg-only run was not. This last point fits the
data but was not traced thread by thread.

## Confirming it without a build

`SIS_UTIL` can be switched off at runtime through `/sys/kernel/debug/sched/features`. With it off, the limit is gone
and the wakeup scan covers all 12 CPUs again. `bench/sched-ab.sh base no-sis-util` runs the benchmark with the feature
on and then off, samples thread placement every 5 s, and restores the feature on exit.

7.3.5 before the fix, 6000 MT/s:

| Variant | pp512 | tg128 | Samples with a thread on cpu2-5 |
|---|---|---|---|
| base (SIS_UTIL on) | 109.04 ± 0.27 | 29.49 ± 0.35 | 4 of 4 |
| no-sis-util | 122.06 ± 0.53 | 35.88 ± 0.06 | 1 of 3 (one thread on cpu5) |

That is +12% pp and +22% tg, the same as pinning to the big cores (121.4/34.7) and close to 6.18.64 (123.5/36.5).

## The fix: patch 0055

`0055` removes the scan limit from `select_idle_capacity()` only. The function scans the whole asymmetric-capacity
domain again, as 6.18 did. `SIS_UTIL` still limits `select_idle_cpu()`, the scan used when capacities are equal. The
domain is at most a few dozen CPUs on systems like this, so a full scan is cheap. The SMT idle-core logic 7.x added to
the same function is kept; it has no effect on this board, which has no SMT.

Switching `SIS_UTIL` off globally would have the same effect here, but it would also change the symmetric scan. The
patch is narrower and needs no boot-time setting.

## Results with 0055

7.3.5 built from `kernel-7` at `0abe703` (55 patches, 22 min native build at `-j6`), 6000 MT/s, NVMe fan on,
`bench/cpu-diag.sh`:

| Variant | pp512 | tg128 |
|---|---|---|
| base (as booted) | 121.67 ± 0.42 | 35.70 ± 0.03 |
| pin-big (`taskset` to the 8 big cores) | 121.33 ± 0.44 | 35.87 ± 0.12 |
| nollc | 121.28 | 35.70 |
| noeas | 121.37 | 35.65 |
| perf (governor `performance`) | 124.22 | 36.64 |

As booted is now level with pinned (+0.3% pp, −0.5% tg, within the run-to-run spread) and within about 1.5-2% of
6.18.64 as booted.

All results in one place (pp512/tg128, tok/s):

| Kernel / setting | Result | vs 6.18.64 |
|---|---|---|
| 6.18.64 as booted | 123.5/36.5 | — |
| 7.3.5 as booted, before the fix | 109.0/29.5 | −12% / −19% |
| 7.3.5 + 0054 only | 108.8/29.9 | −12% / −18% |
| 7.3.5 pinned, before the fix | 121.4/34.7 | −2% / −5% |
| 7.3.5 with SIS_UTIL off at runtime | 122.1/35.9 | −1% / −2% |
| 7.3.5 + 0055 as booted | 121.7/35.7 | −1.5% / −2% |
| 7.3.5 + 0055 pinned | 121.3/35.9 | −2% / −2% |

### Leftover little-core samples

With `0055`, a sample still often shows one thread on cpu2 or cpu3. These are short visits: the benchmark speed is the
same as pinned, so no thread stays long on a little core. A visit can happen when every big core is busy at the
moment of a wakeup, for example when another process (the monitor loop itself, systemd, a kworker) holds a big core.
The scan then correctly picks the best idle CPU available, which is a little one, and load balancing moves the thread
back. This is normal big.LITTLE behaviour, and 6.18.64 does the same.

### `taskset` is no longer needed

Before the fix, the workaround was to pin CPU-heavy work to the big cores with `taskset -c 0,1,6-11`. On a kernel with
`0055` that gives no gain (121.3/35.9 pinned against 121.7/35.7 as booted), so it can be dropped. Pinning can still be
useful to keep a workload off the little cores for other reasons, but it is not needed for speed.

## Same boot: first 7.3.5 boot on r8169

The `0055` build was also the first 7.3.5 build to use the mainline `r8169` driver for the two RTL8125 NICs (see
`docs/nic-r8125-vs-r8169.md`). Both NICs came up with their real factory MAC addresses on that boot.

## How to reproduce

On the board, with llama.cpp and the model built by `bench/bench-build.sh` under `~/bench`:

1. Check the kernel has the problem or the fix. On 7.3.5 without `0055`:

   ```
   cd ~/orangepi6 && git pull
   bash bench/sched-ab.sh base no-sis-util
   ```

   `base` should be about 109/29.5 with `cpus:` lines showing threads on cpu2-5. `no-sis-util` should be about
   122/36. The log is written to `~/bench/sched-ab-<kernel>.log`. The script needs sudo for debugfs and restores
   every feature it changes.

2. Full comparison on any kernel:

   ```
   bash bench/cpu-diag.sh
   ```

   It runs the `base`, `nollc`, `noeas`, `perf` and `pin-big` variants, and logs the topology, sched domains,
   cpufreq policies and thread placement to `~/bench/cpu-diag-<kernel>.log`. On a fixed kernel, `base` is within
   about 2% of `pin-big`.

3. Per-thread utilization and placement:

   ```
   bash bench/util-probe.sh        # tg only
   bash bench/util-probe.sh pp     # prompt processing only
   bash bench/util-probe.sh both   # pp512 + tg128, sampled every 2 s
   ```

   It prints each busy thread's CPU, `util_avg`, `util_est` and runtime, plus a count of threads on little cores per
   sample. The log is `~/bench/util-probe-<kernel>-<mode>.log`.

4. To confirm the code path on any kernel source, look at `select_idle_capacity()` in `kernel/sched/fair.c`. If it
   reads `sd->shared->nr_idle_scan` and has a `--nr <= 0` exit in its loop, the kernel has the limit. `0055` removes
   both.

The scripts work with the uutils `sort` that Ubuntu 26.04 ships (they do not use `sort -t=`).
