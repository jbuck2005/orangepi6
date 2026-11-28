# Test bench process (mandatory)

Every test on the board follows this process: stability runs, crash reproducers, A/B comparisons, benchmarks that
are run for a result. It exists because results were lost in the past: logs overwritten by the next iteration, a
temperature logger that stopped at a crash reboot and was never restarted (a whole night of runs without SSD
temperatures), and status updates that drifted. None of those can happen if the steps below are followed.

## Rules

1. **Nothing is overwritten.** Every set has its own folder, every run its own log file, every boot its own logger
   folder. A failing log is never touched again; a re-run gets a new number.
2. **Logs leave the board while the test runs.** The PC captures the serial console and pulls the board's log
   folders every minute. A result that only exists on the board does not count until it is on the PC.
3. **Loggers survive reboots.** The board's loggers are systemd services enabled at boot. A crash, a panic reboot
   or a power cycle cannot leave a set without data.
4. **Temperatures go to the serial console.** Serial carries only kernel messages, so the board writes a
   temperature line into the kernel log every minute. The serial capture then holds temperatures up to the moment
   the board died, even when the disk lost its last writes.
5. **Pre-flight before every set and after every reboot.** A set does not start, or continue after a crash, until
   `bench/preflight.sh` passes.
6. **One set at a time**, and one heavy job at a time on the board.
7. **Status at most 15 minutes apart** while a test runs, in the template below, plus at once on a failure,
   a crash, a logger problem, or when an operator is needed.
8. **Every run gets a record**: pass, fail or panic, its failure signature, and its peak CPU and SSD temperatures.

## One-time setup

### Board

```bash
sudo bench/benchlog.sh install      # boot-persistent loggers: opi6-bench-sensors and opi6-bench-kmsg
bench/benchlog.sh status            # both active and enabled, a fresh sample, a recent kernel-log line
sudo apt install stress-ng          # for stability runs
```

`benchlog.sh install` copies the loggers to `/usr/local/lib/opi6-bench/` and enables two services:

| Service | What it logs | Where (per boot, never reused) |
|---|---|---|
| `opi6-bench-sensors` | every 10 s: every thermal zone (CPU/SoC), every hwmon temperature (the NVMe SSD is hwmon `nvme`: Composite and its sensors), each cpufreq policy's current and maximum clock, load, EDAC counts | `sensors.csv`, `temps.log` (`epoch cpu_C nvme_C`) |
| `opi6-bench-sensors` | every 60 s: one `bench-t:` line into the kernel log (so to the serial console) | kernel log, serial capture |
| `opi6-bench-sensors` | at start: the previous crash's pstore (ramoops) records | `pstore/` |
| `opi6-bench-kmsg` | the whole kernel log of the boot, followed live | `dmesg-<time>.log` |

The folder is `/var/log/opi6-bench/boots/<sequence>-<date>-<boot id>/`, and `/var/log/opi6-bench/current` points at
this boot's folder. The sequence number orders boots; the date can be wrong until NTP syncs, because the board has no
RTC battery. Files are fsync'd every minute, so a hard reset loses at most the last minute (a hard reset right after
heavy writes has zeroed unsynced files before).

The SSD temperature comes from the kernel's NVMe hwmon sensor (`CONFIG_NVME_HWMON`, enabled in our builds after
v2026.11.25), which needs no tools and no root. The v2026.11.25 kernels and older lack it; there the loggers read the
SMART log with nvme-cli (`sudo apt install nvme-cli`; the services run as root, pre-flight uses `sudo -n`). With
neither, pre-flight fails rather than running a set without SSD data. The value is the hottest of the Composite
temperature and the sensors, leaving out a sensor that reads exactly the warning threshold (WCTEMP): the Kingston NV3
reports "Temperature Sensor 2" as a fixed 75 C. `nvme smart-log /dev/nvme0` gives the readings by hand.

Power: the board has no voltage, current or power sensors (hwmon has temperatures only). Wall power comes from a
smart plug, read on the PC with `tools/plug-power.py --start <set start> --end <set end>`; add its min/mean/max to the
set's results when power matters.

### PC

```powershell
# serial console: USB-serial adapter on the DEBUG header (UART2, 115200 8N1), see README "Debug serial console"
powershell -File bench\serial-log.ps1 -Port COM<n> -Log <capture folder>\serial.log
# board logs, copied every minute (key login over ssh)
powershell -File bench\pull-logs.ps1 -Board <board ssh host> -Dest <capture folder>\bench-logs
```

Both run for the whole test, in their own windows. `serial-log.ps1` timestamps every line, only appends, reconnects
when the adapter drops, and writes `=== NO SERIAL DATA for 3 min` when the board goes quiet (it prints a `bench-t:`
line every minute, so silence means it is down, hung, or the adapter is lost). `pull-logs.ps1` only replaces a PC
copy with a board copy that is at least as long, so it never shortens a file the board lost the end of in a crash,
and it writes `BOARD UNREACHABLE` to `pull.log` when the board stops answering.

On the board, Armbian runs `serial-getty@ttyAMA2` on the same UART, and `sysrq` is enabled, so the serial console is
also the way in when the network is gone.

### Why temperatures go through the kernel log

The serial console carries the kernel's console output and, with the getty, a login, nothing else. A user-space
process cannot print to it alongside the kernel without fighting the getty, but anything written to `/dev/kmsg` is a
kernel message and goes out on every console. The loggers write at level 3 (`<3>`) because the default console log
level (4) only lets levels 0 to 3 through; the lines start with `bench-t:` (temperatures), `bench-log:` (logger
start, pstore copy), `bench-preflight:` and `repro:`/`stability:` (test events), so they are easy to grep and easy
to tell from real kernel errors. (`scripts/boot-report.sh` leaves them out of its error list.) One line a minute is far below the kernel's `/dev/kmsg` rate limit (bursts of 10 per
5 s); pre-flight reports if any line was dropped. Example:

```
bench-t: cpu=52C nvme=58C mhz=2600/1800/2300/2200/2400 cap=p0=2600,p2=1800,p6=2300,p8=2200,p10=2400 load=6.12
```

`mhz` and `cap` list policy0 (cpu0-1), policy2 (cpu2-5), policy6 (cpu6-7), policy8 (cpu8-9) and policy10 (cpu10-11).

## Pre-flight checklist

Run before every set and again after every reboot during a set (`crash-repro.sh` runs it itself):

```bash
EXPECT_KERNEL=7.3.5 FAN=on \
EXPECT_CAPS="p0=2600 p2=1800 p6=2300 p8=2200 p10=2400" EXPECT_MEM=6000 bench/preflight.sh
```

| Check | How | Fails when |
|---|---|---|
| Kernel | `uname -r` | it does not contain `EXPECT_KERNEL` |
| Caps | every policy's `scaling_max_freq` **read back** | it differs from `EXPECT_CAPS` (a driver can round a value; caps reset at every boot) |
| Fan | the operator sets `FAN=on` or `FAN=off` (software cannot see the SSD fan) | not given |
| SSD sensor | hwmon `nvme`, else nvme-cli's SMART log | neither gives a reading |
| Memory rate | SMBIOS (`dmidecode`, with `EXPECT_MEM`) | different |
| Loggers | both services active and enabled, a sample under 60 s old, a `bench-t:` line under 3 min old | any of them not |
| Disk space | log and work file systems | under 5 GB |
| Clock | NTP synced | not synced (times in the records would be wrong) |

It also prints each policy's CPUs, cap, top clock and governor, the current temperatures, the boot command line
options that matter (`panic=` and others) and any pstore records. The report goes to the kernel log and, from
`crash-repro.sh`, into the set folder as `preflight-<n>.txt`. Before the first set of a session, also check by eye
that the serial capture on the PC shows the `bench-preflight:` line and that `pull-logs.ps1` copied this boot's
folder.

## Running a set

A set is one configuration run N times, for example "cpu10-11 at 2.4 GHz, everything else full, 20 runs". Give it a
short unique `TAG`; its folder is named after the time and the tag.

```bash
TREE=<built kernel tree> TAG=conf-p10-2400 N=20 CPUS=0-11 J=6 MAXF=2400000 MAXF_CPUS=10,11 \
  EXPECT_KERNEL=7.3.5 EXPECT_CAPS="p0=2600 p2=1800 p6=2300 p8=2200 p10=2400" FAN=on \
  nohup setsid bash bench/crash-repro.sh > /dev/null 2>&1 &
```

`crash-repro.sh` applies the caps, runs pre-flight, and then for each run writes a start marker, the run's own
`make<i>.log`, and a row in `results.csv`. It refuses to write over an existing `make<i>.log`. For multi-hour build
and stress runs, `bench/stability.sh` keeps one log per iteration under `~/stability-logs/<start time>/`; run
pre-flight by hand first.

### Per-run record

`results.csv` in the set folder, one row per run:

| Field | Meaning |
|---|---|
| `run`, `start`, `end`, `secs` | run number and UTC times |
| `kernel`, `caps` | `uname -r` and every policy's cap as read back at the start of the run |
| `result` | `pass`; `fail` (non-zero exit or a tool crash in the build log); `panic` (the board went down during the run) |
| `signature` | the first crash line: `malloc(): unaligned tcache chunk detected`, `Unable to handle kernel paging request ...`, or "no pstore record, see the serial capture" |
| `peak_cpu_c`, `peak_nvme_c` | hottest CPU/SoC zone and hottest NVMe sensor during the run |
| `log` | the run's log, or `panic-run<i>/` with the pstore records |

`set.conf` holds what the set is (tag, N, cores, caps, kernel, start time); `events.log` every event; `sensors.csv`
and `temps.log` the set's own samples (next to the boot loggers).

## Crash and reboot handling

The board's default boots use `panic=10`: after a kernel panic it reboots by itself in 10 seconds. A hard hang needs
the power button (an outlet power cycle alone does not start the board: no RTC battery).

1. **Do not touch the logs.** Note the time of the crash from the serial capture (the last `bench-t:` line and the
   panic text are there).
2. Once the board is back: the loggers have started a new boot folder on their own, and the sensors service has
   copied the crash's pstore records into it. Check with `bench/benchlog.sh status`.
3. **Resume the set** with the same command and `LOG_DIR=<the set folder>`. `crash-repro.sh` records the unfinished
   run as `panic` (signature from pstore, else "see the serial capture"), applies the caps again (a reboot resets
   them), runs pre-flight again, and continues until N runs are done. The panic counts as one of the N runs.
4. After a hang that needed the power button, check the memory rate in pre-flight (`EXPECT_MEM`): a power loss can
   reset the firmware settings.
5. Report the crash at once (rule 7), with its signature and the serial lines around it.

Before any planned reboot or power cut, run `sync` on the board; never power off right after heavy writes without it.

## Status reports

While a test runs, a status goes out **at most 15 minutes apart**, and at once on a failure, a crash, a logger
problem (`STALE`, `MISSING`, `NO SERIAL DATA`, `BOARD UNREACHABLE`) or when an operator is needed. Every report uses
live numbers from the board, never an estimate from the plan. `bench/status.sh` prints the body:

```
Status 2026-11-28 14:05 UTC, kernel 7.3.5-sky1, up 2h11m
Now: CPU 49 C, SSD 57 C, load 6.20, caps p0=2600 p2=1800 p6=2300 p8=2200 p10=2400
- conf-p10-2400: 12 of 20 runs, 12 pass, 0 fail, 0 panic; run 13 in progress 1 min, about 22 min left
  peaks: set CPU 54 C / SSD 61 C; last 15 min CPU 53 C / SSD 60 C
Loggers: OK; boot log 0042-20261128-1154-3f9c1a2b, 42 boots logged; last 15 min CPU 53 C / SSD 60 C
```

Add to it: the serial capture state (last `bench-t:` line time), the pull state (last `pull.log` line), what runs
next, and anything needed from the operator, first. A report that says "due to finish" without counts is not a status.

## After a set

1. Check the PC copy: `bench-logs/` holds the set folder with every `make<i>.log`, `results.csv`, and the boot
   folders of every boot during the set; the serial capture covers the whole set.
2. Write the result into the analysis document (for the crash work, `bench/CRASH-ANALYSIS.md`): the configuration,
   runs/failed/panicked, each failure's time and signature, peak CPU and SSD temperatures. No host names, addresses,
   user names or personal paths.
3. Add an entry to `HISTORY.md` (see `CONTRIBUTING.md`).
4. Remove caps that were only for the set (or reboot), and leave the boot loggers installed.
