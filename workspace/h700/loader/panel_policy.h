/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZL_PANEL_POLICY_H
#define ZL_PANEL_POLICY_H

#include "profile_policy.h"

/* Vendor rules, not model detection. Only admitted artifact profiles may select one. */
enum zl_panel_rule {
	ZL_PANEL_INVALID,
	ZL_PANEL_STRAP_PULL,
	ZL_PANEL_STRAP_UNCHANGED,
	ZL_PANEL_OLD,
	ZL_PANEL_BOE,
};

static inline enum zl_panel_rule zl_panel_rule_for_profile(unsigned int profile)
{
	const struct zero_profile_policy *p = zero_profile_policy(profile);
	return p ? (enum zl_panel_rule)p->panel_rule : ZL_PANEL_INVALID;
}

#endif
