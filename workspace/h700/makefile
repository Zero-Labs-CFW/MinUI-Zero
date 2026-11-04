# h700 (Anbernic RG35XX Plus / RG35XX-H) — hosted-dev alpha.
#
# Nothing platform-specific builds here yet: no keymon (minui reads evdev directly in
# platform.c), no vendored SDL (muOS's own SDL2 is the host), no extra tools. The targets
# exist so the shared workspace/makefile sequence runs unchanged. Real work arrives with
# the boot-image milestone (see platform/../README-BRINGUP.md "Order of work").

.PHONY: all early boards clean

all: boards
	cd ./boardpick && make
	mkdir -p ./tools/build && $(CROSS_COMPILE)gcc -O2 -Wall ./tools/nightlayer.c -o ./tools/build/nightlayer
	$(CROSS_COMPILE)gcc -O2 -Wall -static ./tools/bootclock.c -o ./tools/build/bootclock

# platform/boards.h: the board table as C, before anything compiles platform.c (workspace/makefile runs early first)
early: boards

boards:
	sh ./gen-boards.sh ./boards.txt ./platform/boards.h

clean:
	cd ./boardpick && make clean
	rm -f ./tools/build/nightlayer ./tools/build/bootclock
