// zero_late_mmc: start the H700's second card slot and its WiFi slot after boot instead of during it (boot speed,
// 2026-11-04). The same method as zero_late_usb.c (read its header for why the property is repointed, why there is no
// exit function and which kernel symbols are safe): the boot package's device tree (tools/h700-image/fastboot.py)
// marks both controllers "late", and this module, loaded by early.sh as soon as init runs, starts them.
//
// Each controller's probe sleeps through a fixed power-up sequence, ~55 ms for the second card slot (sdc2) and ~59 ms
// for WiFi (sdc1), and the kernel probes them one after another before it runs init: ~0.13 s off every boot on the
// RG35XX H, measured. The main card (sdc0) is untouched.
//
// ORDER MATTERS: they start second card first, then WiFi, the order the kernel used, so the hosts keep their numbers
// (mmc1 = second card, mmc2 = WiFi). muOS tests for WiFi at /sys/bus/mmc/devices/mmc2:0001; starting only the second
// card late swapped them (measured on the H). WiFi's controller shares its compatible with the main card's, so the loop
// takes only nodes that say exactly "late".
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/string.h>

static const char okay[] = "okay";

static const char *const late[] = {
	"allwinner,sunxi-mmc-v4p6x",	// sdc2, the second card slot -> mmc1
	"allwinner,sunxi-mmc-v4p1x",	// sdc1, WiFi (SDIO) -> mmc2; sdc0 shares this compatible but is never "late"
};

static int __init zero_late_mmc_init(void)
{
	int i, started = 0;

	for (i = 0; i < ARRAY_SIZE(late); i++) {
		struct device_node *np = NULL;

		while ((np = of_find_compatible_node(np, NULL, late[i]))) {
			struct property *st = of_find_property(np, "status", NULL);

			if (!st || st->length != 5 || strcmp(st->value, "late"))
				continue;
			st->value = (void *)okay;
			if (of_platform_device_create(np, NULL, NULL))
				started++;
			else
				printk(KERN_WARNING "zero_late_mmc: %s did not start\n", late[i]);
		}
	}
	printk(KERN_INFO "zero_late_mmc: started %d card controller(s)\n", started);
	return 0;
}

module_init(zero_late_mmc_init);	// no module_exit: permanent, see zero_late_usb.c
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Start the H700 second card and WiFi controllers after boot");
