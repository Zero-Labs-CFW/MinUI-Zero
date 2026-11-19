/* SPDX-License-Identifier: GPL-2.0+ */
#include "sha256.h"
#include "sha256_ce_policy.h"

void sha256_process_scalar(sha256_context *, const unsigned char *, unsigned int);
void zl_sha256_ce_preserved(uint32_t *, const unsigned char *, unsigned int);

void sha256_process(sha256_context *ctx, const unsigned char *input, unsigned int blocks)
{
    uint64_t el, isar, cptr, sctlr;
    if (!blocks)
        return;
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
    if (el == 12) {
        __asm__ volatile("mrs %0, ID_AA64ISAR0_EL1\n"
                         "mrs %1, CPTR_EL3\n"
                         "mrs %2, SCTLR_EL3" : "=r"(isar), "=r"(cptr), "=r"(sctlr));
        if (zl_sha256_ce_ok(el, isar, cptr, sctlr)) {
            zl_sha256_ce_preserved(ctx->state, input, blocks);
            return;
        }
    }
    sha256_process_scalar(ctx, input, blocks);
}
