# h700 (Anbernic RG35XX Plus / RG35XX-H) — hosted-dev alpha.
#
# Nothing platform-specific builds here yet: no keymon (minui reads evdev directly in
# platform.c), no vendored SDL (muOS's own SDL2 is the host), no extra tools. The targets
# exist so the shared workspace/makefile sequence runs unchanged. Real work arrives with
# the boot-image milestone (see platform/../README-BRINGUP.md "Order of work").

.PHONY: all early clean

all:
	cd ./boardpick && make

early:

clean:
	cd ./boardpick && make clean
