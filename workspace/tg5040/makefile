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
# File Transfer's Browser mode: dufs (sigoden/dufs, Apache-2.0), a web file manager + WebDAV server in one
# static binary (5 MB). Prebuilt for aarch64 musl (no Rust in this toolchain), pinned by version AND tarball
# hash; the build fails rather than ship a different file.
DUFS_VERSION=0.46.0
DUFS_SHA256=1472123ae3aa07e49404d16b20305c2dec90c59883ebda9308717f7205e6511b
DUFS_BIN_SHA256=5753d125dedb51bc4194e491de7d9081d7a1914a62c1fb4390d68ae55620334b
DUFS_BIN=other/dufs/dufs
# File Transfer's USB (MTP) mode: uMTP-Responder (viveris/uMTP-Responder, GPL-3.0), the MTP server muOS runs
# (its script/system/usb_gadget.sh). The firmware's own MtpDaemon shared only internal storage and failed every
# transfer from a Mac (2026-10-05). Built from the umtprd-1.8.1 tag's commit, verified every build like busybox.
REQUIRES_UMTPRD=other/umtprd
UMTPRD_HASH=8f87f7b19034055e2665eaaf07f84a41aa5f25e0
UMTPRD_BIN=$(REQUIRES_UMTPRD)/umtprd
# setup-env.sh puts the cross toolchain's UNPREFIXED as/ld first on PATH, so busybox's host-side
# helpers (fixdep, kconfig) assembled for aarch64 and the build died; the cross compiler is a full path
# in CROSS_COMPILE anyway, so busybox gets PATH without that one entry
BUSYBOX_PATH=$(subst /opt/aarch64-linux-gnu/aarch64-linux-gnu/bin:,,$(PATH))
# Build stamps (Codex review 3): the source checks alone let a binary through that was not built from that source
# (an older or altered binary copied over it, or an untracked extra .c that the wildcard builds pick up). After a
# verified build each tree gets .minui-zero-build = sha256 of the binary + sha256 of the inputs it was built from;
# every build re-checks both, and any untracked, non-ignored file in the tree also forces a clean rebuild.
STAMP_OK=stamp_ok() { s="$$1/.minui-zero-build"; [ -f "$$2" ] && [ -f "$$s" ] && \
	[ "$$(sha256sum "$$2" | cut -d" " -f1)" = "$$(sed -n 1p "$$s")" ] && \
	[ "$$(cat $$3 | sha256sum | cut -d" " -f1)" = "$$(sed -n 2p "$$s")" ] && \
	[ -z "$$(git -C "$$1" status --porcelain --untracked-files=all | grep "^??" | grep -v "\.minui-zero-")" ]; }
STAMP_WRITE=stamp_write() { { sha256sum "$$2" | cut -d" " -f1; cat $$3 | sha256sum | cut -d" " -f1; } > "$$1/.minui-zero-build"; }

.PHONY: $(COMMANDER_PIN) $(EVTEST_PIN) $(JSTEST_PIN) $(UNZIP60_PIN)

all: readmes
	cd show && make

early: $(EVTEST_PIN) $(JSTEST_PIN) $(UNZIP60_PIN) $(COMMANDER_PIN) $(BUSYBOX_BIN) $(DUFS_BIN) $(UMTPRD_BIN)
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
	rm -f $(BUSYBOX_PIN) $(BUSYBOX_BIN) $(UMTPRD_BIN)

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
	$(STAMP_OK); \
	if [ -f $(BUSYBOX_PIN) ] && [ "$$head" = "$(BUSYBOX_HASH)" ] && [ "$$have" = "$$want" ] && \
		{ [ ! -f $(BUSYBOX_BIN) ] || stamp_ok $(REQUIRES_BUSYBOX) $(BUSYBOX_BIN) "other/patches/busybox-ftpd.patch other/patches/busybox-ftpd.config"; }; then exit 0; fi; \
	echo "busybox: (re)pinning $(BUSYBOX_HASH) + patch"; set -e; \
	[ -d $(REQUIRES_BUSYBOX)/.git ] || (mkdir -p $(REQUIRES_BUSYBOX) && cd $(REQUIRES_BUSYBOX) && git init -q && git remote add origin https://github.com/mirror/busybox.git); \
	cd $(REQUIRES_BUSYBOX); \
	git cat-file -e $(BUSYBOX_HASH)^{commit} 2>/dev/null || git fetch -q --depth 1 origin $(BUSYBOX_HASH); \
	git checkout -q -f --detach $(BUSYBOX_HASH); git clean -qfdx; \
	git apply ../patches/busybox-ftpd.patch; \
	touch $(notdir $(BUSYBOX_PIN))
FORCE:
# Every build: the checkout must be exactly the pinned commit plus other/patches/umtprd-minui.patch (run without
# POSIX message queues, which TrimUI's kernel lacks and stock umtprd exits on; send Android's MS OS "MTP"
# descriptor so Windows binds MTP to the vendor-class interface), or it is reset, patched and rebuilt. Plain C,
# no host tools, so the cross compiler (a full path in CROSS_COMPILE) is all it needs.
$(UMTPRD_BIN): FORCE
	@want="$$(grep -E '^[-+]' other/patches/umtprd-minui.patch | grep -vE '^(\+\+\+|---) ')"; \
	have="$$(git -C $(REQUIRES_UMTPRD) diff HEAD 2>/dev/null | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ')"; \
	head="$$(git -C $(REQUIRES_UMTPRD) rev-parse HEAD 2>/dev/null)"; \
	$(STAMP_OK); $(STAMP_WRITE); \
	if [ "$$head" = "$(UMTPRD_HASH)" ] && [ "$$have" = "$$want" ] && \
		stamp_ok $(REQUIRES_UMTPRD) $(UMTPRD_BIN) other/patches/umtprd-minui.patch; then exit 0; fi; \
	echo "umtprd: (re)building $(UMTPRD_HASH) + patch"; set -e; \
	[ -d $(REQUIRES_UMTPRD)/.git ] || (mkdir -p $(REQUIRES_UMTPRD) && cd $(REQUIRES_UMTPRD) && git init -q && git remote add origin https://github.com/viveris/uMTP-Responder.git); \
	cd $(REQUIRES_UMTPRD); \
	git cat-file -e $(UMTPRD_HASH)^{commit} 2>/dev/null || git fetch -q --depth 1 origin $(UMTPRD_HASH); \
	git checkout -q -f --detach $(UMTPRD_HASH); git clean -qfdx; \
	git apply ../patches/umtprd-minui.patch; \
	make -s CC=$(CROSS_COMPILE)gcc; \
	cd ../..; stamp_write $(REQUIRES_UMTPRD) $(UMTPRD_BIN) other/patches/umtprd-minui.patch
# Every build: the binary itself must hash to the pin, or it is fetched again (and the tarball checked) and
# must then match. A stale binary from an older DUFS_VERSION, or an altered one, can no longer ship (Codex review).
$(DUFS_BIN): FORCE
	@echo "$(DUFS_BIN_SHA256)  $(DUFS_BIN)" | sha256sum -c --status 2>/dev/null && exit 0; \
	echo "dufs: fetching $(DUFS_VERSION)"; set -e; mkdir -p other/dufs; \
	wget -q -O other/dufs/dufs.tar.gz https://github.com/sigoden/dufs/releases/download/v$(DUFS_VERSION)/dufs-v$(DUFS_VERSION)-aarch64-unknown-linux-musl.tar.gz; \
	echo "$(DUFS_SHA256)  other/dufs/dufs.tar.gz" | sha256sum -c -; \
	tar -xzf other/dufs/dufs.tar.gz -C other/dufs dufs; rm -f other/dufs/dufs.tar.gz; \
	echo "$(DUFS_BIN_SHA256)  $(DUFS_BIN)" | sha256sum -c -
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
	@$(STAMP_WRITE); stamp_write $(REQUIRES_BUSYBOX) $(BUSYBOX_BIN) "other/patches/busybox-ftpd.patch other/patches/busybox-ftpd.config"

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
