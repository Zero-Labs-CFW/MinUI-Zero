###########################################################

ifeq (,$(PLATFORM))
PLATFORM=$(UNION_PLATFORM)
endif

ifeq (,$(PLATFORM))
	$(error please specify PLATFORM, eg. PLATFORM=trimui make)
endif

###############################

# overrides shared by all cores

# commits after this one break save states (as of 20231025)
# gpsp_HASH = 1d1c719

###############################

# this logic was broken out from picoarch's all-in-one makefile

PATCH = git apply --unidiff-zero
# `?=` so a platform can dial this down before including this file. miyoomini does: its toolchain
# image is amd64-only, so on an arm64 host it runs emulated, and at -j4 gcc 8.3 intermittently
# SEGFAULTS mid-compile (seen on picodrive's tremor/mdct.c — the identical command succeeded
# serially straight afterwards). A build that randomly dies is not reproducible.
PROCS ?= -j4

###############################

BUILD_ROOT=../../$(PLATFORM)/cores

# The FILE a core produces, which is not always its name: fake-08 emits fake08_libretro.so via its
# *_CORE override. The build target, the mv, the clean rule and the gate must all derive it the same
# way or they disagree — they did, so `make clean` deleted a fake-08_libretro.so that never existed,
# leaving the real artifact from an older checkout in output/ and rebuilding the core every time
# (Codex review 2026-08-14).
CORE_ARTIFACT = $(if $($(1)_CORE),$($(1)_CORE),$(1)_libretro.so)

define TEMPLATE

$1_REPO ?= https://github.com/libretro/$(1)
# ISOLATE EVERY CORE FROM THE PARENT JOBSERVER. These are third-party makefiles that recurse, and
# several mishandle an inherited jobserver: the sub-make ignores our -jN and starts linking before
# its objects exist (picodrive: undefined lprintf/rfread/rfseek; fceumm the same on miyoomini). The
# giveaway is that they build perfectly standalone and via `make <core>`, and ONLY fail inside a
# full platform build. Clearing MAKEFLAGS makes $1_PROCS the single source of truth for how parallel
# a core is allowed to be (2026-08-14).
$1_MAKE ?= env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make $(and $($1_MAKEFILE),-f $($1_MAKEFILE)) platform=$(PLATFORM) $($(1)_FLAGS)
$1_BUILD_PATH ?= $(1)
# Per-core parallelism. Needed because a core can recurse into a sub-make that mishandles the
# jobserver: picodrive's Cyclone M68K generator dies with "write jobserver: Bad file descriptor"
# under any -jN, deterministically. Set <core>_PROCS = -j1 for those.
$1_PROCS ?= $(PROCS)

src/$(1):
	mkdir -p src
	cd src && git clone $(if $($1_HASH),,--depth 1) --recursive $$($(1)_REPO) $(1)
	# submodules must follow the PIN, not the clone-time HEAD: pcsx_rearmed's libpicofe pointer moved upstream
	# and a clean clone failed verify-source ("tracked source changes do not match declared patches") on the
	# v1.8.0 release build, 2026-09-22; the dev tree only passed because it was cloned when the pin was HEAD
	$(if $($1_HASH),cd src/$$($1_BUILD_PATH) && git checkout $($1_HASH) && git submodule update --init --recursive && echo $($1_HASH),)

src/$(1)/.patched: src/$(1)
	(test ! -f patches/$(1).patch) || (test -f src/$(1)/.patched) || (cd src/$(1) && $(PATCH) -p1 < ../../patches/$(1).patch && touch .patched && true)

src/$(1)/.patched-all:
	(test ! -d ../../all/cores/patches/$(1)) || (test -f src/$(1)/.patched-all) || (cd src/$(1) && $(foreach patch, $(sort $(wildcard ../../all/cores/patches/$(1)/*.patch)), $(PATCH) -p1 < ../../$(patch) &&) touch .patched-all && true)
	

.PHONY: verify-$(1)
verify-$(1): src/$(1)/.patched src/$(1)/.patched-all
	sh ../../all/cores/verify-source.sh src/$(1) "$(if $($1_HASH),$($1_HASH),HEAD)" $(if $(wildcard patches/$(1).patch),patches/$(1).patch) $(sort $(wildcard ../../all/cores/patches/$(1)/*.patch)) $(addprefix --ignore=,$($(1)_VERIFY_IGNORE))


output/$(call CORE_ARTIFACT,$(1)): src/$(1)/.patched src/$(1)/.patched-all | verify-$(1)
	mkdir -p output
	cd src/$$($1_BUILD_PATH) && $$($1_MAKE) $$($1_PROCS)
	mv src/$$($1_BUILD_PATH)/$(call CORE_ARTIFACT,$(1)) ./output

clone-$(1): src/$(1)

status-$(1): src/$(1)
	cd src/$(1) && git show --oneline -s

patch-$(1): src/$(1)/.patched

clean-$(1):
	test ! -d src/$(1) || cd src/$$($1_BUILD_PATH) && $$($1_MAKE) clean
	rm -rf output/$(call CORE_ARTIFACT,$(1))

$(1): output/$(call CORE_ARTIFACT,$(1))

endef

###############################

all: cores

$(foreach CORE,$(CORES),$(eval $(call TEMPLATE,$(CORE))))

cores: $(foreach CORE,$(CORES),$(CORE))
	@sh ../../all/cores/check-cores.sh output $(foreach C,$(CORES),$(call CORE_ARTIFACT,$(C)))
	
clean: $(foreach CORE,$(CORES),clean-$(CORE))

verify: $(foreach CORE,$(CORES),verify-$(CORE))
	
nuke:
	rm -rf ./output
	rm -rf ./src
