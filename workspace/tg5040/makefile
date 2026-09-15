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

.PHONY: $(COMMANDER_PIN) $(EVTEST_PIN) $(JSTEST_PIN) $(UNZIP60_PIN)

all: readmes
	cd show && make

early: $(EVTEST_PIN) $(JSTEST_PIN) $(UNZIP60_PIN) $(COMMANDER_PIN)
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

###########################################################

$(REQUIRES_COMMANDER):
	git clone https://github.com/shauninman/DinguxCommander-sdl2.git $(REQUIRES_COMMANDER)
$(REQUIRES_EVTEST):
	git clone https://github.com/freedesktop-unofficial-mirror/evtest.git $(REQUIRES_EVTEST)

$(REQUIRES_JSTEST):
	git clone https://github.com/datrh/joyutils.git $(REQUIRES_JSTEST)

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
