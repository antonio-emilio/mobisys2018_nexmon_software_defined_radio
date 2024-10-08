GIT_VERSION := $(shell git describe --abbrev=4 --dirty --always --tags)
include ../version.mk
include $(FW_PATH)/definitions.mk

ifeq ($(TEMPLATERAMSTART_PTR), 0x0)
LOCAL_SRCS=$(wildcard src/*.c) src/ucode_compressed.c
else
LOCAL_SRCS=$(wildcard src/*.c) src/ucode_compressed.c src/templateram.c
endif
COMMON_SRCS=$(wildcard $(NEXMON_ROOT)/patches/common/*.c)
FW_SRCS=$(wildcard $(FW_PATH)/*.c)

ifdef UCODEFILE
ifeq ($(wildcard src/$(UCODEFILE)), )
$(error selected src/$(UCODEFILE) does not exist)
endif
endif

ADBFLAGS := $(ADBSERIAL)

UCODEFILE=ucode.asm

OBJS=$(addprefix obj/,$(notdir $(LOCAL_SRCS:.c=.o)) $(notdir $(COMMON_SRCS:.c=.o)) $(notdir $(FW_SRCS:.c=.o)))

CFLAGS= \
	-fplugin=$(CCPLUGIN) \
	-fplugin-arg-nexmon-objfile=$@ \
	-fplugin-arg-nexmon-prefile=gen/nexmon.pre \
	-fplugin-arg-nexmon-chipver=$(NEXMON_CHIP_NUM) \
	-fplugin-arg-nexmon-fwver=$(NEXMON_FW_VERSION_NUM) \
	-fno-strict-aliasing \
	-DNEXMON_CHIP=$(NEXMON_CHIP) \
	-DNEXMON_FW_VERSION=$(NEXMON_FW_VERSION) \
	-DWLC_UCODE_WRITE_BL_HOOK_ADDR=$(WLC_UCODE_WRITE_BL_HOOK_ADDR) \
	-DHNDRTE_RECLAIM_0_END_PTR=$(HNDRTE_RECLAIM_0_END_PTR) \
	-DTEMPLATERAMSTART_PTR=$(TEMPLATERAMSTART_PTR) \
	-DPATCHSTART=$(PATCHSTART) \
	-DUCODESIZE=$(UCODESIZE) \
	-DGIT_VERSION=\"$(GIT_VERSION)\" \
	-DBUILD_NUMBER=\"$$(cat BUILD_NUMBER)\" \
	-Wall -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-function -Werror -O2 -nostdlib -nostartfiles -ffreestanding -mthumb -march=$(NEXMON_ARCH) \
	-ffunction-sections -fdata-sections \
	-I$(NEXMON_ROOT)/patches/include \
	-Iinclude \
	-I$(FW_PATH)

all: $(RAM_FILE)

init: FORCE
	$(Q)if ! test -f BUILD_NUMBER; then echo 0 > BUILD_NUMBER; fi
	$(Q)echo $$(($$(cat BUILD_NUMBER) + 1)) > BUILD_NUMBER
	$(Q)touch src/version.c
	$(Q)make -s -f $(NEXMON_ROOT)/patches/common/header.mk
	@printf "\033[0;31m  CREATING DIRECTORIES\033[0m obj, gen, log\n"
	$(Q)mkdir -p obj gen log

obj/%.o: src/%.c
	@printf "\033[0;31m  COMPILING\033[0m %s => %s (details: log/compiler.log)\n" $< $@
	$(Q)cat gen/nexmon.pre 2>>log/error.log | gawk '{ if ($$3 != "$@") print; }' > tmp && mv tmp gen/nexmon.pre
	$(Q)$(CC)gcc $(CFLAGS) -c $< -o $@ >>log/compiler.log

obj/%.o: $(NEXMON_ROOT)/patches/common/%.c
	@printf "\033[0;31m  COMPILING\033[0m %s => %s (details: log/compiler.log)\n" $< $@
	$(Q)cat gen/nexmon.pre 2>>log/error.log | gawk '{ if ($$3 != "$@") print; }' > tmp && mv tmp gen/nexmon.pre
	$(Q)$(CC)gcc $(CFLAGS) -c $< -o $@ >>log/compiler.log

obj/%.o: $(FW_PATH)/%.c
	@printf "\033[0;31m  COMPILING\033[0m %s => %s (details: log/compiler.log)\n" $< $@
	$(Q)cat gen/nexmon.pre 2>>log/error.log | gawk '{ if ($$3 != "$@") print; }' > tmp && mv tmp gen/nexmon.pre
	$(Q)$(CC)gcc $(CFLAGS) -c $< -o $@ >>log/compiler.log

gen/nexmon2.pre: $(OBJS)
	@printf "\033[0;31m  PREPARING\033[0m %s => %s\n" "gen/nexmon.pre" $@
	$(Q)cat gen/nexmon.pre | awk '{ if ($$3 != "obj/flashpatches.o" && $$3 != "obj/wrapper.o") { print $$0; } }' > tmp
	$(Q)cat gen/nexmon.pre | awk '{ if ($$3 == "obj/flashpatches.o" || $$3 == "obj/wrapper.o") { print $$0; } }' >> tmp
	$(Q)cat tmp | awk '{ if ($$1 ~ /^0x/) { if ($$3 != "obj/flashpatches.o" && $$3 != "obj/wrapper.o") { if (!x[$$1]++) { print $$0; } } else { if (!x[$$1]) { print $$0; } } } else { print $$0; } }' > gen/nexmon2.pre

gen/nexmon.ld: gen/nexmon2.pre $(OBJS)
	@printf "\033[0;31m  GENERATING LINKER FILE\033[0m gen/nexmon.pre => %s\n" $@
	$(Q)sort gen/nexmon2.pre | gawk -f $(NEXMON_ROOT)/buildtools/scripts/nexmon.ld.awk > $@

gen/nexmon.mk: gen/nexmon2.pre $(OBJS) $(FW_PATH)/definitions.mk
	@printf "\033[0;31m  GENERATING MAKE FILE\033[0m gen/nexmon.pre => %s\n" $@
	$(Q)printf "%s: gen/patch.elf FORCE\n" $(RAM_FILE) > $@
	$(Q)sort gen/nexmon2.pre | \
		gawk -v src_file=gen/patch.elf -f $(NEXMON_ROOT)/buildtools/scripts/nexmon.mk.1.awk | \
		gawk -v ramstart=$(RAMSTART) -f $(NEXMON_ROOT)/buildtools/scripts/nexmon.mk.2.awk >> $@
	$(Q)printf "\nFORCE:\n" >> $@
	$(Q)gawk '!a[$$0]++' $@ > tmp && mv tmp $@

gen/flashpatches.ld: gen/nexmon2.pre $(OBJS)
	@printf "\033[0;31m  GENERATING LINKER FILE\033[0m gen/nexmon.pre => %s\n" $@
	$(Q)sort gen/nexmon2.pre | \
		gawk -f $(NEXMON_ROOT)/buildtools/scripts/flashpatches.ld.awk > $@

gen/flashpatches.mk: gen/nexmon2.pre $(OBJS) $(FW_PATH)/definitions.mk
	@printf "\033[0;31m  GENERATING MAKE FILE\033[0m gen/nexmon.pre => %s\n" $@
	$(Q)cat gen/nexmon2.pre | gawk \
		-v fp_data_base=$(FP_DATA_BASE) \
		-v fp_config_base=$(FP_CONFIG_BASE) \
		-v fp_data_end_ptr=$(FP_DATA_END_PTR) \
		-v fp_config_base_ptr_1=$(FP_CONFIG_BASE_PTR_1) \
		-v fp_config_end_ptr_1=$(FP_CONFIG_END_PTR_1) \
		-v fp_config_base_ptr_2=$(FP_CONFIG_BASE_PTR_2) \
		-v fp_config_end_ptr_2=$(FP_CONFIG_END_PTR_2) \
		-v ramstart=$(RAMSTART) \
		-v out_file=$(RAM_FILE) \
		-v src_file=gen/patch.elf \
		-f $(NEXMON_ROOT)/buildtools/scripts/flashpatches.mk.awk > $@

gen/memory.ld: $(FW_PATH)/definitions.mk
	@printf "\033[0;31m  GENERATING LINKER FILE\033[0m %s\n" $@
	$(Q)printf "rom : ORIGIN = 0x%08x, LENGTH = 0x%08x\n" $(ROMSTART) $(ROMSIZE) > $@
	$(Q)printf "ram : ORIGIN = 0x%08x, LENGTH = 0x%08x\n" $(RAMSTART) $(RAMSIZE) >> $@
	$(Q)printf "patch : ORIGIN = 0x%08x, LENGTH = 0x%08x\n" $(PATCHSTART) $(PATCHSIZE) >> $@
	$(Q)printf "ucode : ORIGIN = 0x%08x, LENGTH = 0x%08x\n" $(UCODESTART) $$(($(FP_CONFIG_BASE) - $(UCODESTART))) >> $@
	$(Q)printf "fpconfig : ORIGIN = 0x%08x, LENGTH = 0x%08x\n" $(FP_CONFIG_BASE) $(FP_CONFIG_SIZE) >> $@

gen/patch.elf: patch.ld gen/nexmon.ld gen/flashpatches.ld gen/memory.ld $(OBJS)
	@printf "\033[0;31m  LINKING OBJECTS\033[0m => %s (details: log/linker.log, log/linker.err)\n" $@
	$(Q)$(CC)ld -T $< -o $@ --gc-sections --print-gc-sections -M >>log/linker.log 2>>log/linker.err

$(RAM_FILE): init gen/patch.elf $(FW_PATH)/$(RAM_FILE) gen/nexmon.mk gen/flashpatches.mk
	$(Q)cp $(FW_PATH)/$(RAM_FILE) $@
	@printf "\033[0;31m  APPLYING FLASHPATCHES\033[0m gen/flashpatches.mk => %s (details: log/flashpatches.log)\n" $@
	$(Q)make -f gen/flashpatches.mk >>log/flashpatches.log 2>>log/flashpatches.log
	@printf "\033[0;31m  APPLYING PATCHES\033[0m gen/nexmon.mk => %s (details: log/patches.log)\n" $@
	$(Q)make -f gen/nexmon.mk >>log/patches.log 2>>log/flashpatches.log

###################################################################
# ucode compression related
###################################################################

gen/ucode.asm: $(FW_PATH)/ucode.bin
	$(NEXMON_ROOT)/buildtools/b43/disassembler/b43-dasm $< $@ --arch 15 --format raw-le32
	$(NEXMON_ROOT)/buildtools/b43/debug/b43-beautifier --asmfile $@ --defs $(NEXMON_ROOT)/buildtools/b43/debug/include > tmp && mv tmp $@

gen/ucode_mfg.asm: $(FW_PATH)/ucode.bin
	$(NEXMON_ROOT)/buildtools/b43/disassembler/b43-dasm $(NEXMON_ROOT)/firmwares/bcm4339/6_37_34_1_mfg/ucode.bin $@ --arch 15 --format raw-le32
	$(NEXMON_ROOT)/buildtools/b43/debug/b43-beautifier --asmfile $@ --defs $(NEXMON_ROOT)/buildtools/b43/debug/include > tmp && mv tmp $@

ifneq ($(wildcard src/$(UCODEFILE)), )
gen/ucode.bin: src/$(UCODEFILE)
	@printf "\033[0;31m  ASSEMBLING UCODE\033[0m %s => %s\n" $< $@

ifneq ($(wildcard $(NEXMON_ROOT)/buildtools/b43/assembler/b43-asm.bin), )
	$(Q)PATH=$(PATH):$(NEXMON_ROOT)/buildtools/b43/assembler $(NEXMON_ROOT)/buildtools/b43/assembler/b43-asm $< $@ --format raw-le32
else
	$(error Warning: please compile b43-asm.bin first)
endif

else
gen/ucode.bin: $(FW_PATH)/ucode.bin
	@printf "\033[0;31m  COPYING UCODE\033[0m %s => %s\n" $< $@
	$(Q)cp $< $@
endif

gen/ucode_compressed.bin: gen/ucode.bin
	@printf "\033[0;31m  COMPRESSING UCODE\033[0m %s => %s\n" $< $@
	$(Q)cat $< | $(ZLIBFLATE) > $@

src/ucode_compressed.c: gen/ucode_compressed.bin
	@printf "\033[0;31m  GENERATING C FILE\033[0m %s => %s\n" $< $@
	$(Q)printf "#pragma NEXMON targetregion \"ucode\"\n\n" > $@
	$(Q)cd $(dir $<) && xxd -i $(notdir $<) >> $(shell pwd)/$@

src/templateram.c: $(FW_PATH)/templateram.bin
	@printf "\033[0;31m  GENERATING C FILE\033[0m %s => %s\n" $< $@
	$(Q)printf "#pragma NEXMON targetregion \"ucode\"\n\n" > $@
	$(Q)cd $(dir $<) && xxd -i $(notdir $<) >> $(shell pwd)/$@

###################################################################

check-nexmon-setup-env:
ifndef NEXMON_SETUP_ENV
	$(error run 'source setup_env.sh' first in the repository\'s root directory)
endif

install-firmware: $(RAM_FILE)
	@printf "\033[0;31m  REMOUNTING /system\033[0m\n"
	$(Q)adb $(ADBFLAGS) shell 'su -c "mount -o rw,remount /system"'
	@printf "\033[0;31m  COPYING TO PHONE\033[0m %s => /sdcard/%s\n" $< $<
	$(Q)adb $(ADBFLAGS) push $< /sdcard/ >> log/adb.log 2>> log/adb.log
	@printf "\033[0;31m  COPYING\033[0m /sdcard/fw_bcmdhd.bin => /vendor/firmware/fw_bcmdhd.bin\n"
	$(Q)adb $(ADBFLAGS) shell 'su -c "rm /vendor/firmware/fw_bcmdhd.bin && cp /sdcard/fw_bcmdhd.bin /vendor/firmware/fw_bcmdhd.bin"'
	@printf "\033[0;31m  RELOADING FIRMWARE\033[0m\n"
	$(Q)adb $(ADBFLAGS) shell 'su -c "ifconfig wlan0 down && ifconfig wlan0 up"'

install-rpi3plus: brcmfmac43455-sdio.bin
ifeq ($(shell uname -m),$(filter $(shell uname -m), armv6l armv7l))
	@printf "\033[0;31m  COPYING\033[0m brcmfmac43455-sdio.bin => /lib/firmware/brcm/brcmfmac43455-sdio.bin\n"
	$(Q)cp brcmfmac43455-sdio.bin /lib/firmware/brcm/brcmfmac43455-sdio.bin
ifeq ($(shell lsmod | grep "^brcmfmac" | wc -l), 1)
	@printf "\033[0;31m  UNLOADING\033[0m brcmfmac\n"
	$(Q)rmmod brcmfmac
endif
	$(Q)modprobe brcmutil
	@printf "\033[0;31m  RELOADING\033[0m brcmfmac\n"
ifeq ($(findstring 6.6,$(shell uname -r)),6.6)
	@printf "\033[0;31m  LOADING\033[0m ../../../driver/brcmfmac_6.6.y-nexmon/brcmfmac.ko\n"
	$(Q)insmod ../../../driver/brcmfmac_6.6.y-nexmon/brcmfmac.ko
else ifeq ($(findstring 4.14,$(shell uname -r)),4.14)
	@printf "\033[0;31m  LOADING\033[0m ../../../driver/brcmfmac_4.14.y-nexmon/brcmfmac.ko\n"
	$(Q)insmod ../../../driver/brcmfmac_4.14.y-nexmon/brcmfmac.ko
endif
else
	$(warning Warning: Cannot install firmware on this arch., bcm43430-sdio.bin needs to be copied manually into /lib/firmware/brcm/ on your RPI3)
endif

backup-firmware: FORCE
	adb $(ADBFLAGS) shell 'su -c "cp /vendor/firmware/fw_bcmdhd.bin /sdcard/fw_bcmdhd.orig.bin"'
	adb $(ADBFLAGS) pull /sdcard/fw_bcmdhd.orig.bin

install-backup: fw_bcmdhd.orig.bin
	adb $(ADBFLAGS) shell 'su -c "mount -o rw,remount /system"' && \
	adb $(ADBFLAGS) push $< /sdcard/ && \
	adb $(ADBFLAGS) shell 'su -c "cp /sdcard/fw_bcmdhd.bin /vendor/firmware/fw_bcmdhd.bin"'
	adb $(ADBFLAGS) shell 'su -c "ifconfig wlan0 down && ifconfig wlan0 up"'

clean-firmware: FORCE
	@printf "\033[0;31m  CLEANING\033[0m\n"
	$(Q)rm -fr fw_bcmdhd.bin obj gen log src/ucode_compressed.c src/templateram.c

clean: clean-firmware
	$(Q)rm -f BUILD_NUMBER

FORCE:
