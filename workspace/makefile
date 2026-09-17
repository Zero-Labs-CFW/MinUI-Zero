# workspace (all)

###########################################################

ifeq (,$(PLATFORM))
PLATFORM=$(UNION_PLATFORM)
endif

ifeq (,$(PLATFORM))
$(error please specify PLATFORM, eg. PLATFORM=trimui make)
endif

###########################################################

.PHONY: all

all:
	cd ./$(PLATFORM)/libmsettings && make
	cd ./$(PLATFORM) && make early # eg. other libs
# h700 has no keymon: minui reads evdev directly (platform.c), and as a GUEST inside muOS a
# second input daemon would fight the host's. Revisit with the boot-image milestone.
ifneq (h700,$(PLATFORM))
	cd ./$(PLATFORM)/keymon && make
endif
	cd ./all/minui/ && make clean && make
	cd ./all/minarch/ && make clean && make
	cd ./all/clock/ && make
	cd ./all/minput/ && make
	cd ./all/syncsettings/ && make
	cd ./all/say/ && make
	cd ./all/confirm/ && make
	cd ./all/settings/ && make
	cd ./all/status/ && make
	cd ./all/pick/ && make
	# Tune Voltage harness binaries (undervolt calibration) — build inside the mount;
	# the top makefile copies them into the pak host-side (build/ is outside the container).
	# tg5040-only: the TCS4838 PMIC engine and its aarch64 compiler path don't exist elsewhere.
ifeq (tg5040,$(PLATFORM))
	mkdir -p ./tg5040/undervolt/build
	/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -o ./tg5040/undervolt/build/uvtool ./tg5040/undervolt/uvtool.c
	/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -o ./tg5040/undervolt/build/stress ./tg5040/undervolt/stress.c -lpthread
	/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -o ./tg5040/undervolt/build/deadman ./tg5040/undervolt/deadman.c
endif
	# A release must not reuse an output .so built from an older checkout, patch, or flags.
	# Pin/patch verification runs inside the core makefile before this clean rebuild.
# h700 has no cores dir yet: hosted-dev runs the tg5040 gambatte build (same aarch64 A53
# target). A real pinned/patched core set arrives with the boot-image milestone.
ifneq (h700,$(PLATFORM))
	cd ./$(PLATFORM)/cores && make verify && make clean && make
endif
	cd ./$(PLATFORM) && make

# DEV LOOP: everything `all` builds EXCEPT the cores. The core step above (`make verify && make
# clean && make`) recompiles all eleven emulators with LTO on every run, ~20 min and enough VM memory
# to get the build killed on a busy Mac (2026-09-16: two launcher-only builds died that way). A
# launcher/minarch/tool change does not touch a core, so this reuses cores/output/*.so as-is. The
# host-side `cores` target still copies them and `check-payload` still gates the staged set, so a
# missing or foreign core fails the build exactly as before. Releases keep using `all`.
.PHONY: frontend
frontend:
	cd ./$(PLATFORM)/libmsettings && make
	cd ./$(PLATFORM) && make early
ifneq (h700,$(PLATFORM))
	cd ./$(PLATFORM)/keymon && make
endif
	cd ./all/minui/ && make clean && make
	cd ./all/minarch/ && make clean && make
	cd ./all/clock/ && make
	cd ./all/minput/ && make
	cd ./all/syncsettings/ && make
	cd ./all/say/ && make
	cd ./all/confirm/ && make
	cd ./all/settings/ && make
ifeq (tg5040,$(PLATFORM))
	mkdir -p ./tg5040/undervolt/build
	/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -o ./tg5040/undervolt/build/uvtool ./tg5040/undervolt/uvtool.c
	/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -o ./tg5040/undervolt/build/stress ./tg5040/undervolt/stress.c -lpthread
	/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -o ./tg5040/undervolt/build/deadman ./tg5040/undervolt/deadman.c
endif
	cd ./$(PLATFORM) && make

clean:
	cd ./$(PLATFORM)/libmsettings && make clean
ifneq (h700,$(PLATFORM))
	cd ./$(PLATFORM)/keymon && make clean
endif
	cd ./all/minui/ && make clean
	cd ./all/minarch/ && make clean
	cd ./all/clock/ && make clean
	cd ./all/minput/ && make clean
	cd ./all/syncsettings/ && make clean
	cd ./all/say/ && make clean
	cd ./all/confirm/ && make clean
	cd ./all/settings/ && make clean
	cd ./all/status/ && make clean
	cd ./all/pick/ && make clean
	cd ./$(PLATFORM) && make clean
