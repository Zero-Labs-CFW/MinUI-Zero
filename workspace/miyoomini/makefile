###########################################################

ifeq (,$(PLATFORM))
PLATFORM=$(UNION_PLATFORM)
endif

ifeq (,$(PLATFORM))
$(error please specify PLATFORM, eg. PLATFORM=trimui make)
endif

###########################################################

REQUIRES_SDL=other/sdl
REQUIRES_COMMANDER=other/DinguxCommander
# File Transfer's FTP and Browser (D69; parity with tg5040, 2026-10-08). The SAME pins, patch and config as
# workspace/tg5040/makefile, built for armv7: the patch and config are read from the tg5040 tree, so the two
# platforms cannot drift apart (one source, not a copy). See that makefile for why each step is there.
TG5040_PATCHES=../tg5040/other/patches
REQUIRES_BUSYBOX=other/busybox
BUSYBOX_HASH=1a64f6a20aaf6ea4dbba68bbfa8cc1ab7e5c57c4
BUSYBOX_PIN=$(REQUIRES_BUSYBOX)/.minui-zero-$(BUSYBOX_HASH)
BUSYBOX_BIN=$(REQUIRES_BUSYBOX)/busybox
BUSYBOX_INPUTS=$(TG5040_PATCHES)/busybox-ftpd.patch $(TG5040_PATCHES)/busybox-ftpd.config
# dufs 0.46.0, the release's own armv7 musl build (static), pinned by tarball AND binary hash like tg5040's
# aarch64 one; the tarball hash matches the digest GitHub publishes for the asset
DUFS_VERSION=0.46.0
DUFS_SHA256=079f0b7ebfb50851a4c9f88c9b12e100322a1137eb57356d1e902f369618c9f6
DUFS_BIN_SHA256=555cd4f791c99dc8c40b8a7819ece313dce00591a9b3243f7eb53f6eaab8a0bf
DUFS_BIN=other/dufs/dufs
# build stamps, as in workspace/tg5040/makefile: binary hash + input hash, any untracked file forces a rebuild
STAMP_OK=stamp_ok() { s="$$1/.minui-zero-build"; [ -f "$$2" ] && [ -f "$$s" ] && \
	[ "$$(sha256sum "$$2" | cut -d" " -f1)" = "$$(sed -n 1p "$$s")" ] && \
	[ "$$(cat $$3 | sha256sum | cut -d" " -f1)" = "$$(sed -n 2p "$$s")" ] && \
	[ -z "$$(git -C "$$1" status --porcelain --untracked-files=all | grep "^??" | grep -v "\.minui-zero-")" ]; }
STAMP_WRITE=stamp_write() { { sha256sum "$$2" | cut -d" " -f1; cat $$3 | sha256sum | cut -d" " -f1; } > "$$1/.minui-zero-build"; }

all: readmes
	cd blank && make
	cd batmon && make
	cd lumon && make
	cd show && make
	# overclock.elf: pokes the SigmaStar MPLL via /dev/mem, beyond cpufreq's 1200 top step.
	# Excluded while never-overclock was a non-negotiable; that rule was amended 2026-07-28
	# (CLAUDE.md — quality gameplay outranks it, earned by receipts). The receipt: PS1 p95
	# needs ~1.5GHz (autotest 2026-07-27), and upstream MinUI ran this very tool at 1296/1488
	# as its NORMAL/PERFORMANCE clocks. The governor stays the only writer of cpufreq; the
	# ONLY caller of this tool is PLAT_setCPUMaxFreq's MINARCH_OC_KHZ translation, so the
	# "two writers fighting" hazard that motivated the exclusion cannot recur.
	cd overclock && make

early: $(REQUIRES_SDL) $(REQUIRES_COMMANDER) $(BUSYBOX_BIN) $(DUFS_BIN)
	cd other/sdl && ./make.sh
	cd other/logotweak && make
	cd other/latency_reduction && make
	cd other/DinguxCommander && make -j

clean:
	cd blank && make clean
	cd batmon && make clean
	cd lumon && make clean
	cd show && make clean
	cd other/sdl && make distclean
	cd other/latency_reduction && make clean
	cd other/DinguxCommander && make clean
	rm -f $(BUSYBOX_PIN) $(BUSYBOX_BIN)

###########################################################

$(REQUIRES_SDL):
	git clone --depth 1 --branch miniui-miyoomini https://github.com/shauninman/SDL-1.2.git $(REQUIRES_SDL)
$(REQUIRES_COMMANDER):
	git clone --depth 1 --branch miniui-miyoomini https://github.com/shauninman/DinguxCommander.git $(REQUIRES_COMMANDER)

# Every build: the checkout must be exactly the pinned commit plus the patch, and the binary must carry a stamp
# from those inputs, or it is reset, patched and rebuilt (same rule as tg5040's)
$(BUSYBOX_PIN): FORCE
	@want="$$(grep -E '^[-+]' $(TG5040_PATCHES)/busybox-ftpd.patch | grep -vE '^(\+\+\+|---) ')"; \
	have="$$(git -C $(REQUIRES_BUSYBOX) diff HEAD 2>/dev/null | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ')"; \
	head="$$(git -C $(REQUIRES_BUSYBOX) rev-parse HEAD 2>/dev/null)"; \
	$(STAMP_OK); \
	if [ -f $(BUSYBOX_PIN) ] && [ "$$head" = "$(BUSYBOX_HASH)" ] && [ "$$have" = "$$want" ] && \
		{ [ ! -f $(BUSYBOX_BIN) ] || stamp_ok $(REQUIRES_BUSYBOX) $(BUSYBOX_BIN) "$(BUSYBOX_INPUTS)"; }; then exit 0; fi; \
	echo "busybox: (re)pinning $(BUSYBOX_HASH) + patch"; set -e; \
	[ -d $(REQUIRES_BUSYBOX)/.git ] || (mkdir -p $(REQUIRES_BUSYBOX) && cd $(REQUIRES_BUSYBOX) && git init -q && git remote add origin https://github.com/mirror/busybox.git); \
	cd $(REQUIRES_BUSYBOX); \
	git cat-file -e $(BUSYBOX_HASH)^{commit} 2>/dev/null || git fetch -q --depth 1 origin $(BUSYBOX_HASH); \
	git checkout -q -f --detach $(BUSYBOX_HASH); git clean -qfdx; \
	git apply ../../$(TG5040_PATCHES)/busybox-ftpd.patch; \
	touch $(notdir $(BUSYBOX_PIN))
FORCE:
# the toolchain's PATH has no unprefixed cross as/ld (unlike tg5040's), so busybox's host helpers build as-is
$(BUSYBOX_BIN): $(BUSYBOX_PIN) $(TG5040_PATCHES)/busybox-ftpd.config
	cd $(REQUIRES_BUSYBOX) && make -s allnoconfig
	cd $(REQUIRES_BUSYBOX) && awk -v on="$$(grep -E '^CONFIG_[A-Z0-9_]+=y' ../../$(TG5040_PATCHES)/busybox-ftpd.config | cut -d= -f1 | tr '\n' ' ')" \
		'BEGIN { n = split(on, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 } \
		/^# CONFIG_[A-Z0-9_]+ is not set/ { if (want[$$2]) { print $$2 "=y"; next } } \
		/^CONFIG_SH_IS_ASH=y/ { print "# CONFIG_SH_IS_ASH is not set"; next } \
		/^# CONFIG_SH_IS_NONE is not set/ { print "CONFIG_SH_IS_NONE=y"; next } \
		/^CONFIG_SHELL_ASH=y/ { print "# CONFIG_SHELL_ASH is not set"; next } \
		{ print }' .config > /tmp/busybox.config && cat /tmp/busybox.config > .config
	cd $(REQUIRES_BUSYBOX) && yes "" | make -s oldconfig > /dev/null
	cd $(REQUIRES_BUSYBOX) && for s in $$(grep -E '^CONFIG_[A-Z0-9_]+=y' ../../$(TG5040_PATCHES)/busybox-ftpd.config | cut -d= -f1); do \
		grep -qx "$$s=y" .config || { echo "busybox: $$s did not stick"; exit 1; }; done
	cd $(REQUIRES_BUSYBOX) && make -s -j CROSS_COMPILE=$(CROSS_COMPILE) busybox
	@$(STAMP_WRITE); stamp_write $(REQUIRES_BUSYBOX) $(BUSYBOX_BIN) "$(BUSYBOX_INPUTS)"
# Every build: the binary itself must hash to the pin, or it is fetched again (tarball checked) and must match
$(DUFS_BIN): FORCE
	@echo "$(DUFS_BIN_SHA256)  $(DUFS_BIN)" | sha256sum -c --status 2>/dev/null && exit 0; \
	echo "dufs: fetching $(DUFS_VERSION)"; set -e; mkdir -p other/dufs; \
	wget -q -O other/dufs/dufs.tar.gz https://github.com/sigoden/dufs/releases/download/v$(DUFS_VERSION)/dufs-v$(DUFS_VERSION)-armv7-unknown-linux-musleabihf.tar.gz; \
	echo "$(DUFS_SHA256)  other/dufs/dufs.tar.gz" | sha256sum -c -; \
	tar -xzf other/dufs/dufs.tar.gz -C other/dufs dufs; rm -f other/dufs/dufs.tar.gz; \
	echo "$(DUFS_BIN_SHA256)  $(DUFS_BIN)" | sha256sum -c -

include ../all/readmes/makefile
