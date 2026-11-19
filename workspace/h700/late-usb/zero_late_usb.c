// zero_late_usb: start the H700's USB host controllers after boot instead of during it (boot speed, 2026-11-04).
//
// The vendor kernel starts every USB host controller before it runs init, about 70 ms per OHCI and 30 ms per EHCI,
// ~0.36 s of every boot on the RG35XX H, for ports a handheld rarely uses at the menu. The boot package's device tree
// (tools/h700-image/fastboot.py) marks the controllers below "late", which the kernel treats as unavailable, so it
// skips them. This module, loaded once the menu is up, sets each "late" node back to "okay" and creates its platform
// device; the built-in drivers then start it exactly as they would have at boot. The idea is BaseOS's
// (pvaibhav, docs/12-kernel-gzip.md); this is our own minimal implementation.
//
// Kept deliberately small for the 8 vendor kernels it must load on: it calls only symbols whose modversions CRCs were
// read from every one of those kernels (.notes/2026-11-04-boot-speed/kernel/symcrc.py, identical on all 8), and it
// touches no kernel structure but struct property's first three fields (name, length, value), unchanged for decades.
// The devices are created with no parent, so they appear under /sys/devices/platform rather than .../soc; nothing on
// this image looks them up by path. The kernels have no OF_DYNAMIC, so there is no property-update API, and a
// property's value still points into the flattened tree, which is mapped read-only (writing it in place oopsed on the
// H, 2026-11-04). So the status property is pointed at this module's own "okay" instead; the module has no exit
// function, which makes it permanent, so that string stays valid for as long as the kernel runs.
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/string.h>

static const char okay[] = "okay";

static const char *const late[] = {
	"allwinner,sunxi-ehci1", "allwinner,sunxi-ohci1", "allwinner,sunxi-ohci2",
	"allwinner,sunxi-ehci3", "allwinner,sunxi-ohci3",
};

static int __init zero_late_usb_init(void)
{
	int i, started = 0;

	for (i = 0; i < ARRAY_SIZE(late); i++) {
		struct device_node *np = of_find_compatible_node(NULL, NULL, late[i]);
		struct property *st;

		if (!np)
			continue;
		st = of_find_property(np, "status", NULL);
		if (!st || st->length != 5 || strcmp(st->value, "late"))
			continue;	// only nodes the boot files held back; anything else is left exactly as it is
		st->value = (void *)okay;	// same length (5), so ->length stays right
		if (of_platform_device_create(np, NULL, NULL))
			started++;
		else
			printk(KERN_WARNING "zero_late_usb: %s did not start\n", late[i]);
	}
	printk(KERN_INFO "zero_late_usb: started %d USB host controller(s)\n", started);
	return 0;
}

module_init(zero_late_usb_init);	// no module_exit: permanent, see above
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Start the H700 USB host controllers after boot");
