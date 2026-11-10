/* SPDX-License-Identifier: GPL-2.0+ */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "display_contract.h"

int main(void)
{
    struct zero_display_contract c, before;
    for (unsigned int profile = 0; profile <= 256; profile++) {
        memset(&c, 0xa5, sizeof(c));
        before = c;
        assert(!zero_display_profile(profile, NULL));
        if (profile == 1 || profile == 2) {
            assert(zero_display_profile(profile, &c));
            assert(zero_display_v1_compatible(&c));
            assert(c.lcd_width == 640 && c.lcd_height == 480);
        } else {
            assert(!zero_display_profile(profile, &c));
            assert(!memcmp(&c, &before, sizeof(c)));
        }
    }
    assert(!zero_display_profile(UINT32_MAX, &c));
    assert(!zero_display_v1_compatible(NULL));
    const unsigned dimensions[][2] = {{640,480}, {720,720}, {720,480}, {480,640}};
    for (unsigned i = 0; i < sizeof(dimensions) / sizeof(dimensions[0]); i++) {
        c.lcd_width = c.manager_width = c.frame_width = dimensions[i][0];
        c.lcd_height = c.manager_height = c.frame_height = dimensions[i][1];
        assert(zero_display_v1_compatible(&c)); /* Encoding, not profile admission. */
        before = c;
        c.manager_width++;
        assert(!zero_display_v1_compatible(&c));
        c = before; c.frame_height++;
        assert(!zero_display_v1_compatible(&c));
        c = before; c.lcd_width = 0;
        assert(!zero_display_v1_compatible(&c));
    }
    c.lcd_width = 480; c.lcd_height = 640;
    c.manager_width = c.frame_width = 640;
    c.manager_height = c.frame_height = 480;
    assert(!zero_display_v1_compatible(&c));
    puts("PASS shared display contract: admitted profiles, unchanged refusal output, shapes and rotated-v1 refusal");
    return 0;
}
