// SPDX-License-Identifier: GPL-2.0
/*
 * errata_probe: read (and optionally set) the A720/A520 erratum workaround bits that current TF-A sets at reset.
 *
 * Access to the IMPLEMENTATION DEFINED CPUACTLR*_EL1 registers from below EL3 is trapped unless ACTLR_EL3 grants it.
 * CIX's TF-A has a non-secure SiP call, 0xc200000e (CIX_SIP_PI_TEST_ENABLE), that sets ACTLR_EL3 |= 0x183 on the
 * calling CPU (and opens MDCR_EL3 debug access). We make that call on each CPU and only read the registers if it
 * returned 0 (SMC_OK). If the shipped BL31 doesn't implement it, it returns SMC_UNK and nothing else is touched.
 *
 *   insmod errata_probe.ko            # read only: report the bits per CPU
 *   insmod errata_probe.ko apply=1    # also set the workaround bits (lost when a core powers down: keep deep idle off)
 *
 * The module refuses to load (-EAGAIN) after reporting, so nothing stays resident. A reboot undoes everything.
 */
#include <linux/module.h>
#include <linux/smp.h>
#include <linux/arm-smccc.h>
#include <asm/cputype.h>
#include <asm/sysreg.h>

static bool apply;
module_param(apply, bool, 0444);

#define CIX_SIP_PI_TEST_ENABLE	0xc200000eUL
#define CPUACTLR_EL1		"S3_0_C15_C1_0"
#define CPUACTLR2_EL1		"S3_0_C15_C1_1"

#define rd(reg)		({ u64 __v; asm volatile("mrs %0, " reg : "=r"(__v)); __v; })
#define wr(reg, v)	asm volatile("msr " reg ", %0\n\tisb" : : "r"((u64)(v)))

static void probe_cpu(void *unused)
{
	struct arm_smccc_res res;
	u32 midr = read_cpuid_id();
	u32 part = MIDR_PARTNUM(midr);
	int cpu = smp_processor_id();

	arm_smccc_smc(CIX_SIP_PI_TEST_ENABLE, 0, 0, 0, 0, 0, 0, 0, &res);
	if (res.a0 != 0) {
		pr_info("errata_probe: cpu%d midr %08x: SiP 0xc200000e returned %ld, registers not readable\n",
			cpu, midr, (long)res.a0);
		return;
	}

	if (part == 0xd81) {		/* Cortex-A720 */
		u64 a = rd(CPUACTLR_EL1), a2 = rd(CPUACTLR2_EL1);

		pr_info("errata_probe: cpu%d A720 CPUACTLR %016llx CPUACTLR2 %016llx | 2729604(ACTLR[61:60])=%d 2792132(ACTLR2[26])=%d 2940794(ACTLR2[37])=%d\n",
			cpu, a, a2, (int)((a >> 60) & 3) == 3, !!(a2 & BIT_ULL(26)), !!(a2 & BIT_ULL(37)));
		if (apply) {
			wr(CPUACTLR_EL1, a | BIT_ULL(60) | BIT_ULL(61));
			wr(CPUACTLR2_EL1, a2 | BIT_ULL(26) | BIT_ULL(37));
			pr_info("errata_probe: cpu%d A720 now CPUACTLR %016llx CPUACTLR2 %016llx\n",
				cpu, rd(CPUACTLR_EL1), rd(CPUACTLR2_EL1));
		}
	} else if (part == 0xd80) {	/* Cortex-A520 */
		u64 a = rd(CPUACTLR_EL1);

		pr_info("errata_probe: cpu%d A520 CPUACTLR %016llx | 3685825(ACTLR[9])=%d 3631357(ACTLR[27])=%d\n",
			cpu, a, !!(a & BIT_ULL(9)), !!(a & BIT_ULL(27)));
		if (apply) {
			wr(CPUACTLR_EL1, a | BIT_ULL(9) | BIT_ULL(27));
			pr_info("errata_probe: cpu%d A520 now CPUACTLR %016llx\n", cpu, rd(CPUACTLR_EL1));
		}
	} else {
		pr_info("errata_probe: cpu%d midr %08x: unknown core, skipped\n", cpu, midr);
	}
}

static int __init errata_probe_init(void)
{
	pr_info("errata_probe: running at EL%d, apply=%d\n", is_kernel_in_hyp_mode() ? 2 : 1, apply);
	/* At EL1, ACTLR_EL2 would also have to grant access, and the SiP call only sets ACTLR_EL3. */
	if (!is_kernel_in_hyp_mode()) {
		pr_info("errata_probe: kernel not at EL2 (VHE), not probing\n");
		return -EAGAIN;
	}
	on_each_cpu(probe_cpu, NULL, 1);
	return -EAGAIN;		/* report only; don't stay loaded */
}
module_init(errata_probe_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Report/set Cortex-A720/A520 erratum workaround bits (test only)");
