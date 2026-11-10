/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZERO_DISPLAY_CONTRACT_H
#define ZERO_DISPLAY_CONTRACT_H

#include <stdint.h>

/* LCD timing, display manager and presented frame need not share orientation.
 * A model's physical screen dimensions alone cannot establish this contract. */
struct zero_display_contract {
    uint32_t lcd_width, lcd_height;
    uint32_t manager_width, manager_height;
    uint32_t frame_width, frame_height;
};

static inline int zero_display_profile(unsigned int profile,
                                       struct zero_display_contract *out)
{
    if (!out || (profile != 1 && profile != 2))
        return 0;
    /* Only the captured Plus/H paths are admitted. No fleet/revision inference. */
    out->lcd_width = out->manager_width = out->frame_width = 640;
    out->lcd_height = out->manager_height = out->frame_height = 480;
    return 1;
}

/* ZHL1 carries just one dimension pair. Never silently encode a rotated or
 * otherwise different scanout contract into that legacy record. */
static inline int zero_display_v1_compatible(const struct zero_display_contract *c)
{
    return c && c->lcd_width && c->lcd_height &&
           c->lcd_width == c->manager_width && c->lcd_height == c->manager_height &&
           c->lcd_width == c->frame_width && c->lcd_height == c->frame_height;
}

#endif
