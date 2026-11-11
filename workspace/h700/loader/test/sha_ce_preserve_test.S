/* SPDX-License-Identifier: GPL-2.0+ */
.text
.arch armv8-a
.global zl_sha_ce_test_call
.type zl_sha_ce_test_call, %function
zl_sha_ce_test_call:
    sub sp, sp, #592
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    str q\n, [sp, #(\n*16)]
    .endr
    str x29, [sp, #512]
    str x30, [sp, #520]
    str x3, [sp, #528]
    mrs x9, fpcr
    mrs x10, fpsr
    str x9, [sp, #544]
    str x10, [sp, #552]
    str x18, [sp, #560]
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    movi v\n\().16b, #\n
    .endr
    mov x9, #0x400000
    msr fpcr, x9
    mov x9, #0x8000000
    msr fpsr, x9
    mov x18, #0x1818
#ifdef ZL_TEST_PROFILE
    bl profile_abi_call
    str w0, [sp, #568]
#else
    bl zl_sha256_ce_preserved
#endif
    mov x9, #0x1818
    cmp x18, x9
    cset w0, ne
#ifdef ZL_TEST_PROFILE
    ldr w9, [sp, #568]
    orr w0, w0, w9
#endif
    ldr x3, [sp, #528]
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    str q\n, [x3, #(\n*16)]
    .endr
    mrs x9, fpcr
    mrs x10, fpsr
    str x9, [x3, #512]
    str x10, [x3, #520]
    ldr x9, [sp, #544]
    ldr x10, [sp, #552]
    msr fpcr, x9
    msr fpsr, x10
    ldr x18, [sp, #560]
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    ldr q\n, [sp, #(\n*16)]
    .endr
    ldr x29, [sp, #512]
    ldr x30, [sp, #520]
    add sp, sp, #592
    ret
.size zl_sha_ce_test_call, .-zl_sha_ce_test_call
.section .note.GNU-stack,"",%progbits
