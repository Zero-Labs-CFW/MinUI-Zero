/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZERO_DISPLAY_CONTRACT_H
#define ZERO_DISPLAY_CONTRACT_H

#include "profile_policy.h"

/* LCD timing, display manager and presented frame need not share orientation.
 * A model's physical screen dimensions alone cannot establish this contract. */
static inline int zero_display_profile(unsigned int profile,
                                       struct zero_display_contract *out)
{
    const struct zero_profile_policy *p = zero_profile_policy(profile);
    if (!out || !p)
        return 0;
    *out = p->display;
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
