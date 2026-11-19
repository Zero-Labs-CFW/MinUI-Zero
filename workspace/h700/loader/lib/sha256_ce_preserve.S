/* SPDX-License-Identifier: GPL-2.0+ */
/* Preserve all Q0-Q26 and FPCR/FPSR, not just AAPCS64's D8-D15 minimum.
 * The caller checks SHA2, EL3, trap and memory state without changing controls. */
.text
.arch armv8-a
.global zl_sha256_ce_preserved
.hidden zl_sha256_ce_preserved
.type zl_sha256_ce_preserved, %function
zl_sha256_ce_preserved:
    cbz w2, 1f
    sub sp, sp, #480
    stp x29, x30, [sp]
    mrs x9, fpcr
    mrs x10, fpsr
    stp x9, x10, [sp, #16]
    stp q0, q1, [sp, #32]
    stp q2, q3, [sp, #64]
    stp q4, q5, [sp, #96]
    stp q6, q7, [sp, #128]
    stp q8, q9, [sp, #160]
    stp q10, q11, [sp, #192]
    stp q12, q13, [sp, #224]
    stp q14, q15, [sp, #256]
    stp q16, q17, [sp, #288]
    stp q18, q19, [sp, #320]
    stp q20, q21, [sp, #352]
    stp q22, q23, [sp, #384]
    stp q24, q25, [sp, #416]
    str q26, [sp, #448]
    bl sha256_armv8_ce_process
    ldp q0, q1, [sp, #32]
    ldp q2, q3, [sp, #64]
    ldp q4, q5, [sp, #96]
    ldp q6, q7, [sp, #128]
    ldp q8, q9, [sp, #160]
    ldp q10, q11, [sp, #192]
    ldp q12, q13, [sp, #224]
    ldp q14, q15, [sp, #256]
    ldp q16, q17, [sp, #288]
    ldp q18, q19, [sp, #320]
    ldp q20, q21, [sp, #352]
    ldp q22, q23, [sp, #384]
    ldp q24, q25, [sp, #416]
    ldr q26, [sp, #448]
    ldp x9, x10, [sp, #16]
    msr fpcr, x9
    msr fpsr, x10
    ldp x29, x30, [sp]
    add sp, sp, #480
1:  ret
.size zl_sha256_ce_preserved, .-zl_sha256_ce_preserved
.section .note.GNU-stack,"",%progbits
