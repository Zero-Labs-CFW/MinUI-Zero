/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZERO_PROFILE_POLICY_H
#define ZERO_PROFILE_POLICY_H

#include <stdint.h>

struct zero_display_contract {
    uint32_t lcd_width, lcd_height;
    uint32_t manager_width, manager_height;
    uint32_t frame_width, frame_height;
};

struct zero_profile_policy {
    unsigned int id, panel_rule, dram_types, ram_mask;
    struct zero_display_contract display;
};

#include "profile_policy.inc"

static inline const struct zero_profile_policy *zero_profile_policy(unsigned int id)
{
    for (unsigned int i = 0; i < sizeof(zero_profile_policies) / sizeof(zero_profile_policies[0]); i++)
        if (zero_profile_policies[i].id == id)
            return &zero_profile_policies[i];
    return 0;
}

static inline int zero_profile_memory(unsigned int id, uint32_t mib, uint32_t type)
{
    const struct zero_profile_policy *p = zero_profile_policy(id);
    if (!p || (mib != 1024 && mib != 2048) || (type != 7 && type != 8))
        return 0;
    return (p->dram_types & (1u << type)) && (p->ram_mask & (1u << (mib / 1024 - 1)));
}

#endif
