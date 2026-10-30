# h700 (Anbernic RG35XX Plus / RG35XX-H) — hosted-dev alpha.
#
# Nothing platform-specific builds here yet: no keymon (minui reads evdev directly in
# platform.c), no vendored SDL (muOS's own SDL2 is the host), no extra tools. The targets
# exist so the shared workspace/makefile sequence runs unchanged. Real work arrives with
# the boot-image milestone (see platform/../README-BRINGUP.md "Order of work").

.PHONY: all early boards clean

all: boards
	cd ./boardpick && make

# platform/boards.h: the board table as C, before anything compiles platform.c (workspace/makefile runs early first)
early: boards

boards:
	sh ./gen-boards.sh ./boards.txt ./platform/boards.h

clean:
	cd ./boardpick && make clean
