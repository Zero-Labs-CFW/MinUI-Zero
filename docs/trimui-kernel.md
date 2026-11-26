# TrimUI kernel

On the Brick, Brick Pro and Smart Pro, Zero starts its own Linux kernel instead of TrimUI's, so the menu comes up about 2.5 to 3 seconds sooner. TrimUI's own system stays installed and unchanged, and it takes over by itself whenever Zero's kernel doesn't make it to the menu.

* **What it is**: a Linux 4.9 kernel (4.9.191-zero) and a small startup program, built from Allwinner's A133 kernel source with patches from [plastron](https://github.com/ericreinsmidt/plastron) by Eric Reinsmidt and Zero's own on top. The full source and build scripts are in [zero-kernel-source](https://github.com/Zero-Labs-CFW/zero-kernel-source) (GPL-2.0). The PowerVR GPU libraries and firmware (DDK 1.11) are closed and ship unmodified, and the WiFi firmware is the device's own copy.
* **Why**: a faster start. From kernel start to menu: Brick about 1.2 to 1.5 s (was about 4.5 s before Zero's kernel), Brick Pro about 2.1 s (was about 4.9 s), Smart Pro about 1.6 to 1.8 s (was about 4.3 s). From power on, add about 3.3 s of TrimUI's loader, which runs the same either way.
* **How a start works**: Zero's kernel is never the device's default. Each start is a one-time pass: the loader puts the stock setting back before Zero's kernel even begins, so if that start fails for any reason, the next one is a normal stock start, with nothing to do. Zero sets up the next pass only after the menu is up and its checks pass.
* **Failed starts**: after two starts that don't reach the menu, the kernel turns itself off on that device, and `zero-kernel-FAILED.txt` on the card says why.
* **Dark screen**: turn the device off by holding power. After three starts in a row that end that way, the next start is stock. Three starts in a row that end without a normal power-off for any other reason (a flat battery counts) do the same.
* **What it changes**:
    * the boot settings: the start command, the one-time step that puts it back, and a few status entries of its own
    * the recovery partition, which TrimUI ships unused: its original content is backed up to `.userdata/shared/.minui/zerokernel/` on the card first, and the install waits until that backup is done. Keep it: on the Brick Pro and Smart Pro, undo puts the partition back from it.
    * its own files on internal storage, in `/usr/lib/zero`, plus the kernel's module folder and two small startup entries the system looks for at fixed places. These are added files; no TrimUI file is changed.
* **What it never touches**: the loader, TrimUI's kernel, TrimUI's system files, and your games and saves.
* **Install**: the first start with this release installs the kernel, and the next start uses it. It waits until the battery is at 15% or a charger is in, and needs about 80 MB free on the card for the backup.
* **Optimize CPU** measures on the stock kernel; the Zero kernel comes back after it finishes.
* **Turn it off**: put `restore-boot-env.txt` on the card root and boot once. The device starts the stock kernel from then on, the recovery partition is put back, Zero's files are removed, and the boot settings above go back to stock too. Doing that before the first boot keeps the kernel from ever being installed. If the undo can't finish, `zero-kernel-restore-FAILED.txt` appears and Zero retries at every start.
* **Turn it back on**: put `enable-zero-kernel.txt` on the card root and boot once. The boot settings come back and the kernel installs again, as on a first start. The file is removed once done, and you can turn it off and on as often as you like. If both files are on the card, the undo wins and the enable file is renamed `enable-zero-kernel-IGNORED.txt`. If it can't finish, `enable-zero-kernel-FAILED.txt` appears and Zero retries at every start; `restore-boot-env.txt` stops that.
* **A kernel that stopped itself** (failed starts or a dark screen) stays off, through any off and on, until a later Zero release with a new kernel.
* **Switching to another firmware**: put `restore-boot-env.txt` on your Zero card and boot once before you swap cards. If you forget, the first start without a MinUI Zero card restarts once into stock by itself.
* **Last resort**: TrimUI's own firmware flasher restores any of these devices. Zero never touches the parts of the device it relies on.

