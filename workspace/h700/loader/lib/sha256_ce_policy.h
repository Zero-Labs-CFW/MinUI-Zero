/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZL_SHA256_CE_POLICY_H
#define ZL_SHA256_CE_POLICY_H
#include <stdint.h>

static inline int zl_sha256_ce_ok(uint64_t el, uint64_t isar, uint64_t cptr, uint64_t sctlr)
{
    unsigned sha2 = (isar >> 12) & 15;
    /* No trap/control writes: unknown CPUs or unsafe incoming state stay scalar. */
    return el == 12 && (sha2 == 1 || sha2 == 2) && !(cptr & (1u << 10)) &&
           (sctlr & 7) == 5; /* MMU + cache enabled, alignment traps disabled */
}
#endif
