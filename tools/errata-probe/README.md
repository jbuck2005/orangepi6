# errata-probe (test only)

Reads, and with `apply=1` sets, the Cortex-A720/A520 erratum workaround bits in CPUACTLR/CPUACTLR2 on every core,
using CIX's non-secure SiP call `0xc200000e`, which opens these registers to the kernel. Needs the kernel at EL2.
The module reports and refuses to stay loaded (`insmod` returns EAGAIN). A reboot undoes everything; core
power-down also clears the bits, so keep deep idle off while testing with `apply=1`.

    make -C <kernel build tree> M=$PWD modules
    sudo insmod errata_probe.ko            # read only
    sudo insmod errata_probe.ko apply=1    # set the bits until the next reboot
    sudo dmesg | grep errata_probe

Results on the Orange Pi 6: `bench/CRASH-ANALYSIS.md` (RMA evidence tests).
