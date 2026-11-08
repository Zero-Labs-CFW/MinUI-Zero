#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "lib/sha256.h"
#include "profile.h"

int main(void)
{
    static const unsigned char want[32] = {
        0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
        0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad
    };
    for (unsigned int chunk = 1; chunk <= 3; chunk++) {
        sha256_context ctx;
        unsigned char digest[32];
        sha256_starts(&ctx);
        for (unsigned int i = 0; i < 3; i += chunk)
            sha256_update(&ctx, (const unsigned char *)"abc" + i, chunk < 3-i ? chunk : 3-i);
        sha256_finish(&ctx, digest);
        assert(!memcmp(digest, want, 32));
    }
    const void *parts[8] = {0};
    const uint32_t lengths[8] = {0};
    assert(zl_profile_match(parts, lengths, 1024) == 0);
    assert(zl_profile_match(parts, lengths, 2048) == 0);
    assert(zl_preflight(NULL) == 0);
    puts("PASS production SHA256 chunking and unknown-profile/null-entry refusal");
    return 0;
}
