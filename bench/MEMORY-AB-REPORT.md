# Orange Pi 6 memory stability: firmware and speed A/B, 2026-11-18

Board: Orange Pi 6 (non-Plus), CIX P1, 16 GB LPDDR5 (4 ch). Official power supply. Kernel 6.18.14-sky1 (ACPI).
ECC counts come from the firmware's own UART messages (`DDRC IRQ ECC_SBE_WR` / `ECC_DBE_WR`), captured on the debug UART.

| Firmware | Memory rate | Test | ECC corrected | ECC uncorrectable | Resets |
|---|---|---|---|---|---|
| OPI6BiosV0.8 (2026-04-27, shipped) | 6400 (Auto) | stress-ng vm 3 min (Armbian) | **1227** | **1** | 2 under build/LLM load |
| OPI6BiosV0.8 | 6400 (Auto) | stress-ng vm 3 min (sky1) | 17 | 0 | 0 |
| OPI6BiosV0.8 | 5500 | suite (~8 min) | 0 | 0 | 0 |
| v1.0_for_opi6_linux (2026-10-19) | 5500 | suite + 1 h combined soak | 0 | 0 | 0 |
| v1.0_for_opi6_linux | 6000 (new Auto) | suite + 1 h combined soak | 0 | 0 | 0 |
| v1.0_for_opi6_linux | 6400 | suite + **4 h** combined soak | 0 | 0 | 0 |

Combined soak = stress-ng 8x vm (70% RAM, verify) + 4x cpu, vkmark looping on the GPU, and memrate bursts.
Temperatures held at 66-73 C. The 6400 soak ran 98 vkmark runs (median 1303).

Performance was the same at every rate (within noise):
- llama.cpp CPU (8 threads) Qwen2.5-1.5B Q4_K_M: pp512 ~124 tok/s, tg128 ~36.6 tok/s
- llama.cpp CPU Qwen2.5-7B Q4_K_M: pp256 ~33.7, tg64 ~8.75 tok/s
- llama.cpp Vulkan (panvk, Mesa 26.0.8) tg ~1.6-1.8 tok/s; pp fails at CommandBuffer::end with ErrorOutOfDeviceMemory
- vkpeak: fp32 1.20 TFLOPS, fp16-vec4 2.11 TFLOPS, int8-dot 4.86 TOPS
- stress-ng memrate: write ~17.6-18.6 GB/s; read 8.2-12.1 GB/s (large run-to-run spread at every rate)

Conclusion: on the shipped firmware the board was unstable at its default memory rate (6400). The
2026-10-19 firmware fixes it: 6400 is now clean through a 4-hour combined load, and the new default is 6000.

Scripts: ab-test.sh (suite), soak.sh + ~/bench/soak-load.sh (soak), ~/bench/bw.sh (bandwidth), serial-log.ps1 (UART logger).
Raw results: results-*.txt, soak-*.txt, bw-*.txt.

## Follow-up (2026-11-21): 6000 MT/s, long runs, and NVMe heat

Later, two failures at 6000 MT/s under build load (a hang and a kernel panic with no DDR ECC report) looked like
memory trouble again. Both happened during full from-scratch kernel builds, the heaviest NVMe I/O we run, while
the uncooled SSD's controller sensor read 97-100 C.

| Memory rate | SSD cooling | Run | Result |
|---|---|---|---|
| 5500 | none | full build + 30 min stress-ng verify | pass |
| 6000 | none | `bench/stability.sh`, 4 h (clean rebuilds, light I/O) | 7/7 cycles pass |
| 6000 | blower fan | `bench/stability.sh FULL=1`, 8.4 h (full builds, heavy I/O) | 15/15 builds, 14/14 stress rounds pass |

With the fan, the SSD controller peaked at 52-63 C. So 6000 MT/s is stable once the SSD is cooled; the failures
point at NVMe heat rather than the memory rate. Details in HISTORY.md (2026-11-21).
