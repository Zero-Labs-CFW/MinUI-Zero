# MinUI

# NOTE: this runs on the host system (eg. macOS) not in a docker image
# it has to, otherwise we'd be running a docker in a docker and oof

# prevent accidentally triggering a full build with invalid calls
ifneq (,$(PLATFORM))
ifeq (,$(MAKECMDGOALS))
$(error found PLATFORM arg but no target, did you mean "make PLATFORM=$(PLATFORM) shell"?)
endif
endif

ifeq (,$(PLATFORMS))
# This is a Brick/Smart Pro (tg5040) focused fork. Other platforms are frozen in
# workspace/_unmaintained/ (NextUI-style) and are not built or supported.
PLATFORMS = tg5040
endif

###########################################################

# Append -dirty when the tree has uncommitted changes. Without this an artifact built from WIP
# stamps itself with the last clean SHA and claims to be a commit it is not — which makes every
# "what exactly is on this card?" question unanswerable, and burned a review cycle.
BUILD_HASH:=$(shell git rev-parse --short HEAD)$(shell test -n "$$(git status --porcelain)" && echo -dirty)
ZERO_VERSION=v1.7.4
RELEASE_TIME:=$(shell TZ=GMT date +%Y%m%d)
RELEASE_BETA=
# Device family for the release name: tg5040 -> trimui, miyoomini -> miyoo. Per-family zips keep
# the mature trimui build from being re-cut every time the new miyoo port churns.
FAMILY_tg5040=trimui
FAMILY_miyoomini=miyoo
FAMILY=$(if $(FAMILY_$(firstword $(PLATFORMS))),$(FAMILY_$(firstword $(PLATFORMS))),$(firstword $(PLATFORMS)))
# No -alpha suffix (dropped 2026-09-04): the ports fix more stock MinUI bugs than they lack, so the
# "alpha" label undersold them. Maturity nuance lives in the per-device README sections instead.
RELEASE_BETA_miyoo=
RELEASE_BASE=MinUI-Zero-$(FAMILY)-$(RELEASE_TIME)$(RELEASE_BETA)$(RELEASE_BETA_$(FAMILY))
# highest existing suffix + 1 — counting files breaks after any deletion (a stale count
# can re-issue an existing name and zip -r would append into the shipped artifact)
RELEASE_DOT:=$(shell find -E ./releases/. -regex ".*/${RELEASE_BASE}-[0-9]+\.zip" | sed -E 's/.*-([0-9]+)\.zip/\1/' | awk 'BEGIN{m=-1}{if($$1+0>m)m=$$1+0}END{print m+1}')
RELEASE_NAME=$(RELEASE_BASE)-$(RELEASE_DOT)
LICENSE_CORES=fceumm gambatte gpsp pcsx_rearmed picodrive snes9x2005_plus mednafen_pce_fast mednafen_vb mednafen_supafaust mgba fake-08

###########################################################

.PHONY: build

export MAKEFLAGS=--no-print-directory

all: setup $(PLATFORMS) special package done
	
shell:
	make -f makefile.toolchain PLATFORM=$(PLATFORM)

name:
	@echo $(RELEASE_NAME)

# host-side unit tests (no device, no toolchain)
.PHONY: test-governor test-telemetry test-save-io test-ff-audio test-undervolt test-reproducibility test-wakeup test-gov-memory test-dupskip test-snd-pacing test-shellquote test-install-safety test-cfg-migrate check-parity check-threading-policy
test-governor:
	sh ./workspace/all/common/run-governor-tests.sh
test-shellquote:
	sh ./workspace/all/common/run-shellquote-tests.sh
# All three install-safety harnesses, not just the Miyoo one. The tg5040 installer and BOTH outer
# bootstraps are equally able to strand a device, and a harness that has to be remembered by hand
# is one that stops being run.
test-install-safety:
	sh ./workspace/all/common/run-install-safety-tests.sh
	sh ./workspace/all/common/run-install-safety-tests-tg5040.sh
	sh ./workspace/all/common/run-bootstrap-safety-tests.sh
test-cfg-migrate:
	sh ./workspace/all/common/run-cfg-migrate-tests.sh
check-parity:
	sh ./tools/check-parity.sh
	sh ./tools/check-plat-surface.sh
test-telemetry:
	sh ./workspace/all/common/run-telemetry-tests.sh
test-save-io:
	sh ./workspace/all/common/run-save-io-tests.sh
test-ff-audio:
	sh ./workspace/all/common/run-ff-audio-tests.sh
test-undervolt:
	sh ./workspace/tg5040/undervolt/run-tests.sh
test-reproducibility:
	sh ./workspace/all/cores/run-source-verifier-tests.sh
test-wakeup:
	sh ./workspace/all/common/run-wakeup-tests.sh
test-gov-memory:
	sh ./workspace/all/common/run-gov-memory-tests.sh
test-dupskip:
	sh ./workspace/all/common/run-dupskip-tests.sh
test-audioservo:
	sh ./workspace/all/common/run-audioservo-tests.sh
test-snd-pacing:
	sh ./workspace/all/common/run-snd-pacing-tests.sh
check-threading-policy:
	sh ./workspace/all/common/check-threading-policy.sh
# threading v2 framering protocol module (host; TSan/ASan are SEPARATE builds per contract)
.PHONY: test-frame-pool test-framering test-framering-tsan test-framering-asan
test-frame-pool:
	sh ./workspace/all/common/run-frame-pool-tests.sh
test-framering:
	sh ./workspace/all/common/run-framering-tests.sh plain
test-framering-tsan:
	sh ./workspace/all/common/run-framering-tests.sh tsan
test-framering-asan:
	sh ./workspace/all/common/run-framering-tests.sh asan
# threading v2 frontend_core lifecycle engine (host; F31 cleanup oracle + adversarial runtime)
.PHONY: test-frontend-core test-frontend-core-tsan test-frontend-core-asan
test-frontend-core:
	sh ./workspace/all/common/run-frontend-core-tests.sh plain
test-frontend-core-tsan:
	sh ./workspace/all/common/run-frontend-core-tests.sh tsan
test-frontend-core-asan:
	sh ./workspace/all/common/run-frontend-core-tests.sh asan
.PHONY: check-forbidden-globals
check-forbidden-globals:
	sh ./workspace/all/common/check-forbidden-globals.sh

build:
	# ----------------------------------------------------
	make build -f makefile.toolchain PLATFORM=$(PLATFORM)
	# ----------------------------------------------------

# h700 (Anbernic RG35XX Plus/H) does NOT ship as a zip like the other platforms: it is an OWNED OS,
# so the release artifact is a flashable SD-card image built by stripping a muOS donor rootfs. See
# docs/h700-release.md for the donor requirement (the one input that is not in this repo).
#   make h700-build   binaries only (the on-device dev loop, workspace/h700/README-BRINGUP.md)
#   make h700-image   dev image: bakes in the builder's ssh key + devmode.txt (stay-awake)
#   make h700         release image: no ssh key, no devmode.txt, version from the git tag
h700-build:
	echo $(BUILD_HASH) > ./workspace/hash.txt
	make build -f makefile.toolchain PLATFORM=h700

h700-image: h700-build
	H700_MODE=dev sh ./tools/build-h700-stripped.sh

h700: h700-build
	H700_MODE=release sh ./tools/build-h700-stripped.sh

system:
	make -f ./workspace/$(PLATFORM)/platform/makefile.copy PLATFORM=$(PLATFORM)
	
	# populate system
	cp ./workspace/$(PLATFORM)/keymon/keymon.elf ./build/SYSTEM/$(PLATFORM)/bin/
	cp ./workspace/$(PLATFORM)/libmsettings/libmsettings.so ./build/SYSTEM/$(PLATFORM)/lib
	cp ./workspace/all/minui/build/$(PLATFORM)/minui.elf ./build/SYSTEM/$(PLATFORM)/bin/
	cp ./workspace/all/minarch/build/$(PLATFORM)/minarch.elf ./build/SYSTEM/$(PLATFORM)/bin/
	cp ./workspace/all/syncsettings/build/$(PLATFORM)/syncsettings.elf ./build/SYSTEM/$(PLATFORM)/bin/
	cp ./workspace/all/say/build/$(PLATFORM)/say.elf ./build/SYSTEM/$(PLATFORM)/bin/
	cp ./workspace/all/confirm/build/$(PLATFORM)/confirm.elf ./build/SYSTEM/$(PLATFORM)/bin/
	cp ./workspace/all/clock/build/$(PLATFORM)/clock.elf ./build/EXTRAS/Tools/$(PLATFORM)/Clock.pak/
	cp ./workspace/all/minput/build/$(PLATFORM)/minput.elf ./build/EXTRAS/Tools/$(PLATFORM)/Input.pak/
	# The miyoomini libSDL2 is NOT stock: it carries SDL2's OSS backend so audio routes through the
	# vendor audioserver, which is what keeps the codec powered and removes the game-boundary pops
	# (see MinUI.pak/launch.sh). Losing it is SILENT on device -- audio still works, the pop just
	# comes back -- so the artifact is checked rather than trusted. Rebuild with
	# tools/build-miyoomini-sdl2.sh.
	# WIFI SHIP-CHECK (2026-08-31): the MMP has NO wifi driver in its internal firmware — the
	# 8188fu module and the wifi.txt bring-up MUST travel in every artifact, or a clean update
	# leaves the device unable to network at all (exactly what happened to the first card).
	@if [ "$(PLATFORM)" = "miyoomini" ]; then \
		test -f ./build/SYSTEM/miyoomini/lib/modules/8188fu.ko || { echo "ERROR: miyoomini artifact is missing lib/modules/8188fu.ko — wifi would be dead on-device"; exit 1; }; \
		grep -q 'wifi.txt' ./build/SYSTEM/miyoomini/paks/MinUI.pak/launch.sh || { echo "ERROR: miyoomini launch.sh lost the wifi.txt bring-up"; exit 1; }; \
	fi
	if [ "$(PLATFORM)" = "miyoomini" ]; then \
		strings ./build/SYSTEM/miyoomini/lib/libSDL2-2.0.so.0 | grep -q "OSS /dev/dsp standard audio" || \
			{ echo "ERROR: shipped libSDL2 has no OSS backend — the audio pop would return"; exit 1; }; \
		echo "miyoomini libSDL2: OSS backend present"; \
	fi
	# Artifact hygiene, enforced by the build rather than by a comment. History: a STALE, gitignored
	# overclock.elf sat in skeleton/SYSTEM/miyoomini/bin and `cp -R ./skeleton ./build` shipped it in
	# every artifact, invisible to git (*.elf is ignored) — exactly how six foreign cores shipped
	# before. Scoped to the platform being built.
	#
	# AMENDED 2026-07-28 with the overclock rule (CLAUDE.md: quality gameplay outranks it):
	# miyoomini now ships overclock.elf DELIBERATELY — built from our pinned source by
	# workspace/miyoomini/makefile, invoked only by PLAT_setCPUMaxFreq's MINARCH_OC_KHZ translation
	# (PS1 receipt: p95 needs ~1.5GHz vs the 1200 stock top). The check therefore verifies the
	# shipped binary IS our build (md5 against the workspace artifact) instead of banning it; a
	# stale/foreign copy still fails. as_preload.so stays banned everywhere. tg5040 still ships no
	# overclock binary at all.
	@if [ "$(PLATFORM)" = "miyoomini" ]; then \
		WANT=$$(md5 -q ./workspace/miyoomini/overclock/overclock.elf 2>/dev/null || md5sum ./workspace/miyoomini/overclock/overclock.elf | cut -d' ' -f1); \
		GOT=$$(md5 -q ./build/SYSTEM/miyoomini/bin/overclock.elf 2>/dev/null || md5sum ./build/SYSTEM/miyoomini/bin/overclock.elf | cut -d' ' -f1); \
		[ -n "$$WANT" ] && [ "$$WANT" = "$$GOT" ] || { echo "ERROR: shipped overclock.elf is not our build (want $$WANT got $$GOT)"; exit 1; }; \
		echo "miyoomini overclock.elf: matches our build"; \
	else \
		if find ./build/SYSTEM/$(PLATFORM) ./build/EXTRAS/Tools/$(PLATFORM) -name 'overclock.elf' 2>/dev/null | grep -q .; then \
			echo "ERROR: $(PLATFORM) artifact contains an overclock binary this platform does not ship:"; \
			find ./build/SYSTEM/$(PLATFORM) ./build/EXTRAS/Tools/$(PLATFORM) -name 'overclock.elf' 2>/dev/null; \
			exit 1; \
		fi; \
	fi
	@if find ./build/SYSTEM/$(PLATFORM) ./build/EXTRAS/Tools/$(PLATFORM) -name 'as_preload.so' 2>/dev/null | grep -q .; then \
		echo "ERROR: $(PLATFORM) artifact contains as_preload.so, which this fork never ships:"; \
		find ./build/SYSTEM/$(PLATFORM) ./build/EXTRAS/Tools/$(PLATFORM) -name 'as_preload.so' 2>/dev/null; \
		exit 1; \
	fi
	# Tune Voltage harness binaries -> the pak (tg5040 only)
	if [ "$(PLATFORM)" = "tg5040" ]; then \
		mkdir -p "./build/EXTRAS/Tools/tg5040/Optimize CPU.pak/bin"; \
		cp ./workspace/tg5040/undervolt/build/uvtool "./build/EXTRAS/Tools/tg5040/Optimize CPU.pak/bin/"; \
		cp ./workspace/tg5040/undervolt/build/stress "./build/EXTRAS/Tools/tg5040/Optimize CPU.pak/bin/"; \
		cp ./workspace/tg5040/undervolt/build/deadman "./build/EXTRAS/Tools/tg5040/Optimize CPU.pak/bin/"; \
		cp ./workspace/tg5040/undervolt/uvmap.sh "./build/EXTRAS/Tools/tg5040/Optimize CPU.pak/bin/"; \
	fi

cores: # TODO: can't assume every platform will have the same stock cores (platform should be responsible for copy too)
ifeq (miyoomini,$(PLATFORM))
	# The core set matches tg5040 exactly, INCLUDING cores no Miyoo pak loads yet. Adding a system
	# here then needs no core work, and it kills the failure mode where a pak names a core this
	# platform never built (SFC.pak was moved to supafaust purely because snes9x2005_plus was
	# missing, and kept a comment describing the core it had stopped loading).
	cp ./workspace/miyoomini/cores/output/fceumm_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/gambatte_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/gpsp_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/picodrive_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/pcsx_rearmed_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/mednafen_supafaust_libretro.so ./build/SYSTEM/miyoomini/cores
	# dormant on this device today — shipped so parity with tg5040 is a fact, not an intention
	cp ./workspace/miyoomini/cores/output/snes9x2005_plus_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/mednafen_pce_fast_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/mednafen_vb_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/mgba_libretro.so ./build/SYSTEM/miyoomini/cores
	cp ./workspace/miyoomini/cores/output/fake08_libretro.so ./build/SYSTEM/miyoomini/cores
	# Guard against silently shipping a foreign binary again: every core in the artifact must
	# come from OUR toolchain. The six that shipped before this were Buildroot 2017.11 / gcc 7.2
	# lifted off the stock card, and nothing in the build noticed.
	@for f in ./build/SYSTEM/miyoomini/cores/*.so; do \
		strings "$$f" | grep -q "GNU Toolchain for the A-profile" || \
			{ echo "ERROR: $$f was not built by our toolchain — refusing to ship a foreign core"; exit 1; }; \
	done; echo "miyoomini cores: all built by our toolchain"
else
	# stock cores
	cp ./workspace/$(PLATFORM)/cores/output/fceumm_libretro.so ./build/SYSTEM/$(PLATFORM)/cores
	cp ./workspace/$(PLATFORM)/cores/output/gambatte_libretro.so ./build/SYSTEM/$(PLATFORM)/cores
	cp ./workspace/$(PLATFORM)/cores/output/gpsp_libretro.so ./build/SYSTEM/$(PLATFORM)/cores
	cp ./workspace/$(PLATFORM)/cores/output/picodrive_libretro.so ./build/SYSTEM/$(PLATFORM)/cores
	cp ./workspace/$(PLATFORM)/cores/output/snes9x2005_plus_libretro.so ./build/SYSTEM/$(PLATFORM)/cores
	cp ./workspace/$(PLATFORM)/cores/output/pcsx_rearmed_libretro.so ./build/SYSTEM/$(PLATFORM)/cores
	cp ./workspace/$(PLATFORM)/cores/output/mednafen_supafaust_libretro.so ./build/SYSTEM/$(PLATFORM)/cores # SNES default (SUPA in base)
	
	# extras
	# Extra systems ship DORMANT in the base: cores live in their paks under .system, but no
	# Roms folder is created for them, so MinUI doesn't show them out of the box. A user who
	# wants one just makes a Roms folder with the matching tag (eg. "Virtual Boy (VB)") and it
	# lights up — the tuned core is already there. One download, clean default, no extras zip.
	cp ./workspace/$(PLATFORM)/cores/output/mgba_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/MGBA.pak
	cp ./workspace/$(PLATFORM)/cores/output/mgba_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/SGB.pak
	cp ./workspace/$(PLATFORM)/cores/output/mednafen_pce_fast_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/PCE.pak
	cp ./workspace/$(PLATFORM)/cores/output/picodrive_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/GG.pak
	cp ./workspace/$(PLATFORM)/cores/output/picodrive_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/SMS.pak
	cp ./workspace/$(PLATFORM)/cores/output/mednafen_vb_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/VB.pak
	cp ./workspace/$(PLATFORM)/cores/output/fake08_libretro.so ./build/SYSTEM/$(PLATFORM)/paks/Emus/P8.pak
endif

# ORDERED DELIBERATELY. `cores` here only COPIES core artifacts into build/; the actual core build
# and its stub gate happen inside `build`. Listed as plain prerequisites they may run concurrently
# under -j, so the copy can take a stale output/ core while the build validates the new one, and the
# staged payload silently disagrees with what was checked (Codex review 2026-08-14).
#
# Order-only prerequisites (|) rather than a bare `.NOTPARALLEL:`, which has no prerequisites in
# make 3.81 and therefore serializes the ENTIRE makefile — a global switch to express one local
# ordering constraint, with no hint to the next person why nothing ever parallelizes.
system: | build
cores: | build
common: build system cores
	
clean:
	rm -rf ./build

setup: name
	# ----------------------------------------------------
	# make sure we're running in an input device (non-fatal: allow headless/CI builds)
	tty -s || true
	
	# ready fresh build
	rm -rf ./build
	mkdir -p ./releases
	cp -R ./skeleton ./build
	
	# remove authoring detritus
	cd ./build && find . -type f -name '.keep' -delete
	cd ./build && find . -type f -name '*.meta' -delete

	# Ship only the platform(s) actually being built. `cp -R ./skeleton ./build` brings EVERY
	# platform along, so a Miyoo artifact carried .system/tg5040 and Tools/tg5040 — aarch64
	# binaries a Miyoo can never execute, inflating install/update I/O and making "what is on this
	# card?" unanswerable. `res` is shared assets and always stays.
	@for d in ./build/SYSTEM/* ./build/EXTRAS/Tools/*; do \
		[ -d "$$d" ] || continue; \
		n=$$(basename "$$d"); \
		[ "$$n" = "res" ] && continue; \
		echo "$(PLATFORMS)" | grep -qw "$$n" || { echo "  pruned foreign payload: $$d"; rm -rf "$$d"; }; \
	done
	echo $(BUILD_HASH) > ./workspace/hash.txt
	
	# copy readmes to workspace so we can use Linux fmt instead of host's
	mkdir -p ./workspace/readmes
	cp ./skeleton/BASE/README.txt ./workspace/readmes/BASE-in.txt
	cp ./skeleton/EXTRAS/README.txt ./workspace/readmes/EXTRAS-in.txt
	
done:
	say "done" 2>/dev/null || true

# Card-root bootstrap folders per family. The stock loader looks in a directory fixed BY MODEL, so
# a card only serves more than one model if each model's directory is present. The Miyoo entry is
# therefore a list, not a name: identical payloads, with Mini/Plus/Mini-Flip resolved at runtime.
#   miyoo    = Miyoo Mini (original)   miyoo354 = Miyoo Mini Plus   miyoo285 = Miyoo Mini Flip
# See the `special` target for why miyoo355 (Miyoo Flip) is deliberately absent.
BOOT_DIR_trimui=trimui
BOOT_DIR_miyoo=miyoo miyoo354 miyoo285
BOOT_DIR=$(BOOT_DIR_$(FAMILY))

special:
ifeq (trimui,$(FAMILY))
	# tg5040 (TrimUI Brick / Smart Pro): set up the trimui .tmp_update bootstrap only
	mv ./build/BOOT/common ./build/BOOT/.tmp_update
	mv ./build/BOOT/trimui ./build/BASE/
	cp -R ./build/BOOT/.tmp_update ./build/BASE/trimui/app/
else
	# miyoo: the stock loader runs <boot-dir>/app/<platform>.sh from the card root, and WHICH
	# boot-dir it looks in is fixed per model. One card serves the whole Mini family only if every
	# model's directory is present, so ship all three as copies of the same payload — identical
	# binaries, with the Mini/Plus/Mini-Flip split resolved at RUNTIME (is_plus from
	# /customer/app/axp_test, has_axp additionally from the hall sensor). Upstream MinUI does
	# exactly this (miyoo -> miyoo354/miyoo355/miyoo285) and spruceOS resolves the same split at
	# runtime from the same two files.
	#   miyoo    = Miyoo Mini (original)
	#   miyoo354 = Miyoo Mini Plus     <- the only model whose panel rate we have MEASURED
	#   miyoo285 = Miyoo Mini Flip
	# NOT miyoo355 (Miyoo Flip): that is a different SoC needing its own platform build and an
	# init/squashfs payload we do not produce. Shipping an empty miyoo355 would let a Flip boot
	# into a card with no runtime, which is worse than not being recognised at all.
	# These were `2>/dev/null || true`. A suppressed failure here does not fail the build — it
	# SHIPS a short bootstrap, and since the model directories below are copies, one partial write
	# is duplicated identically into all three. The device then finds an incomplete bootstrap and
	# the on-card recovery logic is what has to cope. Fail the build instead.
	mv ./build/BOOT/common ./build/BOOT/.tmp_update
	mv ./build/BOOT/miyoo ./build/BASE/
	cp -R ./build/BOOT/.tmp_update ./build/BASE/miyoo/app/
	cp -R ./build/BASE/miyoo ./build/BASE/miyoo354
	cp -R ./build/BASE/miyoo ./build/BASE/miyoo285
endif

tidy:
	# ----------------------------------------------------
	# copy update from merged platform to old pre-merge platform bin so old cards update properly
ifneq (,$(findstring tg5040, $(PLATFORMS)))
	mkdir -p ./build/SYSTEM/tg3040/paks/MinUI.pak/
	cp ./build/SYSTEM/tg5040/bin/install.sh ./build/SYSTEM/tg3040/paks/MinUI.pak/launch.sh
endif

.PHONY: check-payload
# ITERATES $(PLATFORMS), NOT $(PLATFORM). `make tg5040` expands to a chain in which `make package`
# is its own make invocation with PLATFORM unset, so the first version of this gate resolved to
# ./build/SYSTEM//paks/Emus, found nothing, and passed every build silently — the exact vacuous
# pass it was written to prevent (Codex review 2026-08-14, round 2). Everything else in `package`
# already uses $(PLATFORMS) for this reason.
check-payload:
	@for p in $(PLATFORMS); do \
		sh ./workspace/all/cores/check-payload.sh ./build/SYSTEM/$$p $$p || exit 1; \
	done

# GATED. package used to depend only on `tidy`, so a manually staged or interrupted build could be
# zipped without the core gate ever running (Codex review 2026-08-14). check-payload verifies the
# staged cores in build/ before anything is compressed.
package: tidy check-payload
	# ----------------------------------------------------
	# zip up build
		
	# move formatted readmes from workspace to build
	cp ./workspace/readmes/BASE-out.txt ./build/BASE/README.txt
	cp ./workspace/readmes/EXTRAS-out.txt ./build/EXTRAS/README.txt
	rm -rf ./workspace/readmes
	
	cd ./build/SYSTEM && echo "$(ZERO_VERSION) ($(RELEASE_TIME)-$(RELEASE_DOT))\n$(BUILD_HASH)" > version.txt
	./commits.sh > ./build/SYSTEM/commits.txt
	cd ./build && find . -type f -name '.DS_Store' -delete
	mkdir -p ./build/PAYLOAD
	mv ./build/SYSTEM ./build/PAYLOAD/.system
	cp -R ./build/BOOT/.tmp_update ./build/PAYLOAD/
	# Tools ship INSIDE the updater payload too: existing users update by dropping
	# MinUI.zip alone (per README), and tool fixes must reach them (audit 2026-07-11 —
	# v1.3's Optimize CPU fixes would otherwise never reach v1.2 cards).
	cp -R ./build/EXTRAS/Tools ./build/PAYLOAD/Tools

	# license compliance (audit 2026-07-11): GPL'd cores ship as binaries, so their license
	# texts, the fork's own terms, and a corresponding-source statement travel in the artifact.
	# INSIDE .system (moved 2026-08-31): the texts must accompany the distribution, but nothing
	# requires them at the visible card root, where the folder just read as clutter next to Roms.
	# Living in .system also puts them inside MinUI.zip, so update-only installs carry them too.
	mkdir -p ./build/PAYLOAD/.system/LICENSES
	cp LICENSE.md THIRD_PARTY_NOTICES.md ./build/PAYLOAD/.system/LICENSES/
	for plat in $(PLATFORMS); do \
		for n in $(LICENSE_CORES); do \
			d=./workspace/$$plat/cores/src/$$n/; \
			for f in COPYING Copying COPYING.LIB copyright COPYRIGHT LICENSE LICENSE.MD LICENSE.md LICENSE.txt; do \
				if [ -f "$$d$$f" ]; then mkdir -p ./build/PAYLOAD/.system/LICENSES/$$n && cp "$$d$$f" ./build/PAYLOAD/.system/LICENSES/$$n/; fi; \
			done; \
		done; \
	done; true
	@if [ -f ./workspace/tg5040/other/unzip60/LICENSE ]; then \
		mkdir -p ./build/PAYLOAD/.system/LICENSES/unzip60 && \
		cp ./workspace/tg5040/other/unzip60/LICENSE ./build/PAYLOAD/.system/LICENSES/unzip60/; \
	fi
	printf 'Corresponding source\n====================\nMinUI Zero source: https://github.com/Zero-Labs-CFW/MinUI-Zero\nThe exact MinUI Zero commit is recorded in MinUI.zip/.system/version.txt. Emulator cores\nare built from the upstream repositories and exact commits pinned in\nworkspace/<platform>/cores/makefile at that commit; local modifications ship as patches in\nworkspace/<platform>/cores/patches/. Each core binary remains under its own license\n(texts in this folder).\n' > ./build/PAYLOAD/.system/LICENSES/SOURCES.txt
	cd ./build/PAYLOAD && zip -r MinUI.zip .system .tmp_update Tools
	mv ./build/PAYLOAD/MinUI.zip ./build/BASE
	
	# v1: ONE download. Base is the whole product — 6 systems shown, extra systems dormant in
	# .system (add a Roms folder to unlock), and the 4 curated Tools. No extras zip to maintain.
	cp -R ./build/EXTRAS/Tools ./build/BASE/Tools
	@if [ -e ./releases/$(RELEASE_NAME).zip ]; then echo "ERROR: ./releases/$(RELEASE_NAME).zip already exists — refusing to overwrite a release"; exit 1; fi
	# BOOT_DIR is the per-family bootstrap folder that must sit at the card root
	# NOTE: this list is EXPLICIT, so anything added to skeleton/BASE is silently dropped from the
	# release until it is named here. wifi.txt.example shipped into build/BASE on 2026-08-28 and
	# never reached a single card for exactly that reason (caught preparing the Brick Pro card).
	cd ./build/BASE && zip -r ../../releases/$(RELEASE_NAME).zip Bios Roms Saves Tools $(BOOT_DIR) MinUI.zip README.txt wifi.txt.example .metadata_never_index .fseventsd
	echo "$(RELEASE_NAME)" > ./build/latest.txt
	
###########################################################

.DEFAULT:
	# ----------------------------------------------------
	# $@
	# a bare platform target (eg. `make tg5040`) runs the full release chain — without
	# setup/package it died at final packaging with nothing staged (Codex audit 2026-07-09)
	@echo "$(PLATFORMS)" | grep -q "\b$@\b" && (make setup && make common PLATFORM=$@ && make special && make package && make done) || (exit 1)
	
