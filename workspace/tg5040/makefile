###########################################################

ifeq (,$(PLATFORM))
PLATFORM=$(UNION_PLATFORM)
endif

ifeq (,$(PLATFORM))
$(error please specify PLATFORM, eg. PLATFORM=tg5040 make)
endif

###########################################################

REQUIRES_EVTEST=other/evtest
REQUIRES_JSTEST=other/jstest
REQUIRES_UNZIP60=other/unzip60
REQUIRES_COMMANDER=other/DinguxCommander-sdl2
COMMANDER_HASH=8eaa0efa132a6eae909df5aa1b31950044f568cc
EVTEST_HASH=b8343ec1124da18bdabcc04809a8731b9e39295d
JSTEST_HASH=b6703ebf04c839fc47f9e490b68c4d5d885f32f9
UNZIP60_HASH=f6389e3aafc0fc0d31209f7f2a33c4392f92342a
COMMANDER_PIN=$(REQUIRES_COMMANDER)/.minui-zero-$(COMMANDER_HASH)
EVTEST_PIN=$(REQUIRES_EVTEST)/.minui-zero-$(EVTEST_HASH)
JSTEST_PIN=$(REQUIRES_JSTEST)/.minui-zero-$(JSTEST_HASH)
UNZIP60_PIN=$(REQUIRES_UNZIP60)/.minui-zero-$(UNZIP60_HASH)
# File Transfer's FTP server: busybox ftpd + tcpsvd at the 1_36_1 tag, with one patch so the login is
# a one-time code from the environment instead of the system accounts (other/patches/busybox-ftpd.patch)
# and a config of only those applets (other/patches/busybox-ftpd.config). Replaced fclairamb/ftpserver, a 24.8 MB
# Go binary, the same day (Dan: "go smaller").
REQUIRES_BUSYBOX=other/busybox
BUSYBOX_HASH=1a64f6a20aaf6ea4dbba68bbfa8cc1ab7e5c57c4
BUSYBOX_PIN=$(REQUIRES_BUSYBOX)/.minui-zero-$(BUSYBOX_HASH)
BUSYBOX_BIN=$(REQUIRES_BUSYBOX)/busybox
# setup-env.sh puts the cross toolchain's UNPREFIXED as/ld first on PATH, so busybox's host-side
# helpers (fixdep, kconfig) assembled for aarch64 and the build died; the cross compiler is a full path
# in CROSS_COMPILE anyway, so busybox gets PATH without that one entry
BUSYBOX_PATH=$(subst /opt/aarch64-linux-gnu/aarch64-linux-gnu/bin:,,$(PATH))

.PHONY: $(COMMANDER_PIN) $(EVTEST_PIN) $(JSTEST_PIN) $(UNZIP60_PIN)

all: readmes
	cd show && make

early: $(EVTEST_PIN) $(JSTEST_PIN) $(UNZIP60_PIN) $(COMMANDER_PIN) $(BUSYBOX_BIN)
	mkdir -p other
	# Files for the h700 image: same source, keyboard-scancode key table (def.h PLATFORM_H700), since
	# the H's pad arrives as keyboard keys and the Brick's joystick table left it unusable. Built FIRST
	# with its objects removed after, so the tg5040 link below never picks up h700-flavoured objects.
	cd $(REQUIRES_COMMANDER) && rm -f src/*.o && make -j PLATFORM=h700 TARGET=DinguxCommander-h700 && rm -f src/*.o
	cd $(REQUIRES_COMMANDER) && make -j
	cd $(REQUIRES_EVTEST) && $(CROSS_COMPILE)gcc -o evtest evtest.c
	cd $(REQUIRES_JSTEST) && $(CROSS_COMPILE)gcc -o jstest jstest.c
	cd $(REQUIRES_UNZIP60) && make -f unix/Makefile.trimuismart unzip

clean:
	cd show && make clean
	cd $(REQUIRES_COMMANDER) && make clean && rm -f DinguxCommander-h700
	cd $(REQUIRES_UNZIP60) && make -f unix/Makefile.trimuismart clean
	rm -f $(BUSYBOX_PIN) $(BUSYBOX_BIN)

###########################################################

$(REQUIRES_COMMANDER):
	git clone https://github.com/shauninman/DinguxCommander-sdl2.git $(REQUIRES_COMMANDER)
$(REQUIRES_EVTEST):
	git clone https://github.com/freedesktop-unofficial-mirror/evtest.git $(REQUIRES_EVTEST)

$(REQUIRES_JSTEST):
	git clone https://github.com/datrh/joyutils.git $(REQUIRES_JSTEST)

# Runs every build, like the other pins: the checkout must be exactly the pinned commit plus our patch (its
# changed lines, compared as text). Anything else (a fresh tree, a new patch, a stray local edit in this
# ignored dir) resets it and touches the marker, which rebuilds the binary; a matching tree touches nothing,
# so nothing rebuilds. A separate verify target cannot do this: make has already read the marker's time
# (Codex review, 2026-10-05). Shallow fetch: the full busybox history is large and only this commit is built.
$(BUSYBOX_PIN): FORCE
	@want="$$(grep -E '^[-+]' other/patches/busybox-ftpd.patch | grep -vE '^(\+\+\+|---) ')"; \
	have="$$(git -C $(REQUIRES_BUSYBOX) diff HEAD 2>/dev/null | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ')"; \
	head="$$(git -C $(REQUIRES_BUSYBOX) rev-parse HEAD 2>/dev/null)"; \
	if [ -f $(BUSYBOX_PIN) ] && [ "$$head" = "$(BUSYBOX_HASH)" ] && [ "$$have" = "$$want" ]; then exit 0; fi; \
	echo "busybox: (re)pinning $(BUSYBOX_HASH) + patch"; set -e; \
	[ -d $(REQUIRES_BUSYBOX)/.git ] || (mkdir -p $(REQUIRES_BUSYBOX) && cd $(REQUIRES_BUSYBOX) && git init -q && git remote add origin https://github.com/mirror/busybox.git); \
	cd $(REQUIRES_BUSYBOX); \
	git cat-file -e $(BUSYBOX_HASH)^{commit} 2>/dev/null || git fetch -q --depth 1 origin $(BUSYBOX_HASH); \
	git checkout -q -f --detach $(BUSYBOX_HASH); git clean -qfdx; \
	git apply ../patches/busybox-ftpd.patch; \
	touch $(notdir $(BUSYBOX_PIN))
FORCE:
$(BUSYBOX_BIN): $(BUSYBOX_PIN) other/patches/busybox-ftpd.config
	cd $(REQUIRES_BUSYBOX) && PATH="$(BUSYBOX_PATH)" make -s allnoconfig
	cd $(REQUIRES_BUSYBOX) && awk -v on="$$(grep -E '^CONFIG_[A-Z0-9_]+=y' ../patches/busybox-ftpd.config | cut -d= -f1 | tr '\n' ' ')" \
		'BEGIN { n = split(on, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 } \
		/^# CONFIG_[A-Z0-9_]+ is not set/ { if (want[$$2]) { print $$2 "=y"; next } } \
		/^CONFIG_SH_IS_ASH=y/ { print "# CONFIG_SH_IS_ASH is not set"; next } \
		/^# CONFIG_SH_IS_NONE is not set/ { print "CONFIG_SH_IS_NONE=y"; next } \
		/^CONFIG_SHELL_ASH=y/ { print "# CONFIG_SHELL_ASH is not set"; next } \
		{ print }' .config > /tmp/busybox.config && cat /tmp/busybox.config > .config
	cd $(REQUIRES_BUSYBOX) && yes "" | PATH="$(BUSYBOX_PATH)" make -s oldconfig > /dev/null
	cd $(REQUIRES_BUSYBOX) && for s in $$(grep -E '^CONFIG_[A-Z0-9_]+=y' ../patches/busybox-ftpd.config | cut -d= -f1); do \
		grep -qx "$$s=y" .config || { echo "busybox: $$s did not stick"; exit 1; }; done
	cd $(REQUIRES_BUSYBOX) && PATH="$(BUSYBOX_PATH)" make -s -j CROSS_COMPILE=$(CROSS_COMPILE) busybox

$(REQUIRES_UNZIP60):
	git clone https://github.com/shauninman/unzip60.git $(REQUIRES_UNZIP60)

$(COMMANDER_PIN): $(REQUIRES_COMMANDER)
	cd $(REQUIRES_COMMANDER) && git checkout -- . && (git cat-file -e $(COMMANDER_HASH)^{commit} || git fetch origin $(COMMANDER_HASH))
	cd $(REQUIRES_COMMANDER) && git checkout --detach $(COMMANDER_HASH)
	cd $(REQUIRES_COMMANDER) && git diff --quiet && git diff --cached --quiet
	# local modifications ship as an in-repo patch, same discipline as cores/patches/ —
	# a direct edit of the checkout dies at the diff-quiet gate above on the next re-pin
	# (which is what protected this tree from exactly that, 2026-08-31)
	cd $(REQUIRES_COMMANDER) && git apply --unidiff-zero ../patches/DinguxCommander-sdl2.patch
	touch $(COMMANDER_PIN)
$(EVTEST_PIN): $(REQUIRES_EVTEST)
	cd $(REQUIRES_EVTEST) && (git cat-file -e $(EVTEST_HASH)^{commit} || git fetch origin $(EVTEST_HASH))
	cd $(REQUIRES_EVTEST) && git checkout --detach $(EVTEST_HASH)
	cd $(REQUIRES_EVTEST) && git diff --quiet && git diff --cached --quiet
	touch $(EVTEST_PIN)
$(JSTEST_PIN): $(REQUIRES_JSTEST)
	cd $(REQUIRES_JSTEST) && (git cat-file -e $(JSTEST_HASH)^{commit} || git fetch origin $(JSTEST_HASH))
	cd $(REQUIRES_JSTEST) && git checkout --detach $(JSTEST_HASH)
	cd $(REQUIRES_JSTEST) && git diff --quiet && git diff --cached --quiet
	touch $(JSTEST_PIN)
$(UNZIP60_PIN): $(REQUIRES_UNZIP60)
	cd $(REQUIRES_UNZIP60) && (git cat-file -e $(UNZIP60_HASH)^{commit} || git fetch origin $(UNZIP60_HASH))
	cd $(REQUIRES_UNZIP60) && git checkout --detach $(UNZIP60_HASH)
	cd $(REQUIRES_UNZIP60) && git diff --quiet && git diff --cached --quiet
	touch $(UNZIP60_PIN)

include ../all/readmes/makefile
