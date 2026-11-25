/* SPDX-License-Identifier: GPL-2.0+ */
#include <assert.h>
#include <stdio.h>
#include "lib/sha256_ce_policy.h"
int main(void)
{
    unsigned cases = 0;
    for (unsigned el = 0; el <= 12; el += 4)
        for (unsigned sha = 0; sha < 16; ++sha)
            for (unsigned trap = 0; trap < 2; ++trap)
                for (unsigned control = 0; control < 8; ++control) {
                    int want = el == 12 && (sha == 1 || sha == 2) && !trap && control == 5;
                    assert(zl_sha256_ce_ok(el, (uint64_t)sha<<12, (uint64_t)trap<<10, control) == want);
                    assert(zl_sha256_ce_ok(el, ((uint64_t)sha<<12)|0xf0000000, ((uint64_t)trap<<10)|1, control|0x1000) == want);
                    cases += 2;
                }
    printf("PASS SHA CE policy: %u feature/EL/trap/alignment/cache cases\n", cases);
}
