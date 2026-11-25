/* SPDX-License-Identifier: GPL-2.0+ */
#include <assert.h>
#include <asm/hwcap.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/auxv.h>
#include "lib/sha256.h"

void sha256_process_scalar(sha256_context *, const unsigned char *, unsigned int);
int zl_sha_ce_test_call(uint32_t *, const unsigned char *, unsigned int, void *);

int main(void)
{
    if (!(getauxval(AT_HWCAP) & HWCAP_SHA2)) return 77;
    unsigned char input[6416];
    for (unsigned i = 0; i < sizeof(input); ++i) input[i] = (unsigned char)(i * 17 + 9);
    const unsigned counts[] = {0, 1, 2, 16, 100};
    for (unsigned offset = 0; offset < 16; ++offset) {
        for (unsigned i = 0; i < sizeof(counts)/sizeof(counts[0]); ++i) {
            sha256_context scalar, ce;
            sha256_starts(&scalar); ce = scalar;
            unsigned char saved[528] __attribute__((aligned(16)));
            assert(!zl_sha_ce_test_call(ce.state, input + offset, counts[i], saved));
            sha256_process_scalar(&scalar, input + offset, counts[i]);
            assert(!memcmp(ce.state, scalar.state, sizeof(ce.state)));
            for (unsigned q = 0; q < 32; ++q)
                for (unsigned b = 0; b < 16; ++b) assert(saved[q*16+b] == q);
            uint64_t fpcr, fpsr;
            memcpy(&fpcr, saved+512, 8); memcpy(&fpsr, saved+520, 8);
            assert(fpcr == 0x400000 && fpsr == 0x8000000);
        }
    }
    puts("PASS SHA CE: 80 block/alignment cases, zero blocks, scalar equality, full Q0-Q31 + FPCR/FPSR + x18 preservation");
}
