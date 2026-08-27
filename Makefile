# SepiaOS - boot partition builder
#
# Downloads the official Raspberry Pi boot artifacts, assembles them into a
# FAT32 boot partition inside an MBR disk image, and can boot the result under
# QEMU.
#
#   make list-boards            what can be built
#   make BOARD=pi3 image        build build/pi3/sepiaos-pi3.img
#   make BOARD=pi3 qemu         boot it under QEMU (exit: Ctrl-A then X)
#   make help                   every target
#
# No root, no loop mounts, no sfdisk: the image is built with mtools, so the
# same recipe works on macOS and Linux.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Pinned upstream release. Tags are immutable, so a build is reproducible.
# Newer tags: https://github.com/raspberrypi/firmware/tags
FIRMWARE_TAG   ?= 1.20260521

BOARD          ?= pi3

# Whole-disk size, of which PART_START (4 MiB) is the gap before the partition,
# so the boot partition itself is 4 MiB smaller. Must be a power of two: QEMU
# rejects any other SD size. 64 leaves ~33 MiB free even for BOARD=universal.
IMAGE_SIZE_MIB ?= 64

# Raspberry Pi OS starts its boot partition at 4 MiB.
PART_START     ?= 8192
VOLUME_LABEL   ?= BOOT

# Device tree overlays cost an extra ~55 MiB of git objects to fetch.
WITH_OVERLAYS  ?= 1

FW_BASE_URL := https://raw.githubusercontent.com/raspberrypi/firmware/$(FIRMWARE_TAG)/boot
FW_GIT_URL  := https://github.com/raspberrypi/firmware.git

DL_DIR    := downloads/$(FIRMWARE_TAG)
BUILD_DIR := build/$(BOARD)
STAGE_DIR := $(BUILD_DIR)/boot
IMAGE     := $(BUILD_DIR)/sepiaos-$(BOARD).img
MTOOLSRC_FILE := $(BUILD_DIR)/mtoolsrc
CONFIG_STAMP  := $(BUILD_DIR)/.config

# Settings that change what lands in the image. Overriding one of these on the
# command line does not touch any file, so without this signature Make would
# happily leave a stale image in place - `IMAGE_SIZE_MIB=64` would report
# "Nothing to be done" and hand back the old 256 MiB card.
CONFIG_SIG = $(BOARD)|$(IMAGE_BOARDS)|$(FIRMWARE_TAG)|$(IMAGE_SIZE_MIB)|$(PART_START)|$(VOLUME_LABEL)|$(WITH_OVERLAYS)|$(CMDLINE_ROOT)

# ---------------------------------------------------------------------------
# Board matrix
#
# QEMU columns are what was actually observed to boot, not what looks
# plausible: the Zero 2 W device tree takes a synchronous external abort in
# bcm2835_power_probe on raspi3ap, so it is emulated as raspi3b.
#
#   board       SoC       QEMU machine   card device under QEMU
#   pi-zero2w   BCM2837   raspi3b        mmcblk0
#   pi3         BCM2837   raspi3b        mmcblk0
#   pi4         BCM2711   raspi4b        mmcblk1
#   cm4         BCM2711   raspi4b        mmcblk1
#   pi5         BCM2712   -              -
#   cm5         BCM2712   -              -
# ---------------------------------------------------------------------------

BOARDS := pi-zero2w pi3 pi4 cm4 pi5 cm5

SOC_pi-zero2w := bcm2837
SOC_pi3       := bcm2837
SOC_pi4       := bcm2711
SOC_cm4       := bcm2711
SOC_pi5       := bcm2712
SOC_cm5       := bcm2712

DTB_pi-zero2w := bcm2710-rpi-zero-2-w.dtb
DTB_pi3       := bcm2710-rpi-3-b.dtb
DTB_pi4       := bcm2711-rpi-4-b.dtb
DTB_cm4       := bcm2711-rpi-cm4.dtb
DTB_pi5       := bcm2712-rpi-5-b.dtb
DTB_cm5       := bcm2712-rpi-cm5-cm5io.dtb

# Siblings the firmware may pick instead, depending on board stepping or
# carrier. Shipping only the primary name is what makes a card boot on one
# CM5 carrier and not another, so the whole family travels together.
DTB_EXTRA_pi3 := bcm2710-rpi-3-b-plus.dtb
DTB_EXTRA_pi4 := bcm2711-rpi-400.dtb bcm2711-rpi-cm4s.dtb
DTB_EXTRA_cm4 := bcm2711-rpi-cm4-io.dtb
DTB_EXTRA_pi5 := bcm2712-d-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-rpi-500.dtb
DTB_EXTRA_cm5 := bcm2712-rpi-cm5-cm4io.dtb bcm2712-rpi-cm5l-cm5io.dtb bcm2712-rpi-cm5l-cm4io.dtb

# config.txt conditional filter that selects each board. [cm4] also sees [pi4]
# and [cm5] also sees [pi5], so the per-board blocks below are redundant for
# those two but never wrong.
FILTER_pi-zero2w := pi02
FILTER_pi3       := pi3
FILTER_pi4       := pi4
FILTER_cm4       := cm4
FILTER_pi5       := pi5
FILTER_cm5       := cm5

DESC_pi-zero2w := Raspberry Pi Zero 2 W
DESC_pi3       := Raspberry Pi 3 Model B
DESC_pi4       := Raspberry Pi 4 Model B
DESC_cm4       := Compute Module 4
DESC_pi5       := Raspberry Pi 5
DESC_cm5       := Compute Module 5 (CM5IO carrier)

# The firmware set genuinely differs per SoC; a flat copy rule would be wrong.
#   BCM2837 - GPU reads bootcode.bin from the card, then start.elf.
#   BCM2711 - first stage lives in SPI EEPROM, so no bootcode.bin.
#   BCM2712 - EEPROM firmware loads config.txt and the kernel directly;
#             there is no start*.elf for it in the firmware repository at all.
FW_bcm2837 := bootcode.bin start.elf fixup.dat
FW_bcm2711 := start4.elf fixup4.dat
FW_bcm2712 :=

KERNEL_bcm2837 := kernel8.img
KERNEL_bcm2711 := kernel8.img
KERNEL_bcm2712 := kernel_2712.img

QEMU_MACHINE_pi-zero2w := raspi3b
QEMU_MACHINE_pi3       := raspi3b
QEMU_MACHINE_pi4       := raspi4b
QEMU_MACHINE_cm4       := raspi4b

# PL011 base address differs with the peripheral base of each SoC.
EARLYCON_bcm2837 := 0x3f201000
EARLYCON_bcm2711 := 0xfe201000

# Under QEMU the Pi 4 exposes the card as mmcblk1; real hardware uses mmcblk0.
QEMU_ROOTDEV_bcm2837 := /dev/mmcblk0p2
QEMU_ROOTDEV_bcm2711 := /dev/mmcblk1p2

# ---------------------------------------------------------------------------
# Board groups
#
# One card can serve several boards: the firmware picks the device tree from
# the board it finds itself on, and config.txt conditional filters let one file
# hold per-board settings. This is how Raspberry Pi OS ships a single image for
# every model. BOARD therefore accepts a group name as well as a board name,
# and the image carries the union of what its members need.
# ---------------------------------------------------------------------------

GROUP_bcm2837   := pi-zero2w pi3
GROUP_bcm2711   := pi4 cm4
GROUP_bcm2712   := pi5 cm5
GROUP_universal := pi-zero2w pi3 pi4 cm4 pi5 cm5
GROUPS          := bcm2837 bcm2711 bcm2712 universal

GDESC_bcm2837   := Every BCM2837 board
GDESC_bcm2711   := Every BCM2711 board
GDESC_bcm2712   := Every BCM2712 board
GDESC_universal := All six boards on one card

# BOARD may name one board or one group.
IMAGE_BOARDS := $(strip $(or $(GROUP_$(BOARD)),$(filter $(BOARD),$(BOARDS))))
IMAGE_SOCS   := $(sort $(foreach b,$(IMAGE_BOARDS),$(SOC_$(b))))
FW_FILES     := $(sort $(foreach s,$(IMAGE_SOCS),$(FW_$(s))))
KERNELS      := $(sort $(foreach s,$(IMAGE_SOCS),$(KERNEL_$(s))))
DTBS         := $(sort $(foreach b,$(IMAGE_BOARDS),$(DTB_$(b)) $(DTB_EXTRA_$(b))))

# Emulation needs one specific board; default to the first member QEMU can run.
QEMU_CANDIDATES := $(strip $(foreach b,$(IMAGE_BOARDS),$(if $(QEMU_MACHINE_$(b)),$(b))))
QEMU_BOARD      ?= $(firstword $(QEMU_CANDIDATES))
QEMU_SOC        := $(SOC_$(QEMU_BOARD))
QEMU_MACHINE    := $(QEMU_MACHINE_$(QEMU_BOARD))
QEMU_DTB        := $(DTB_$(QEMU_BOARD))
QEMU_KERNEL     := $(KERNEL_$(QEMU_SOC))
EARLYCON        := $(EARLYCON_$(QEMU_SOC))
QEMU_ROOTDEV    := $(QEMU_ROOTDEV_$(QEMU_SOC))

# Validate only for goals that actually need a board, so `help` still works.
BOARD_GOALS := image sd-image stage qemu run fetch verify checksums boot-check
ifneq ($(filter $(BOARD_GOALS),$(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))),)
  ifeq ($(IMAGE_BOARDS),)
    $(error Unknown BOARD '$(BOARD)'. Boards: $(BOARDS). Groups: $(GROUPS))
  endif
  ifeq ($(filter $(IMAGE_SIZE_MIB),1 2 4 8 16 32 64 128 256 512 1024 2048 4096 8192),)
    $(error IMAGE_SIZE_MIB must be a power of two (QEMU rejects any other SD size), got $(IMAGE_SIZE_MIB))
  endif
endif

TOTAL_SECTORS := $(shell echo $$(( $(IMAGE_SIZE_MIB) * 1024 * 1024 / 512 )))
PART_SECTORS  := $(shell echo $$(( $(TOTAL_SECTORS) - $(PART_START) )))
PART_OFFSET   := $(shell echo $$(( $(PART_START) * 512 )))

DOWNLOADS := $(addprefix $(DL_DIR)/,$(FW_FILES) $(KERNELS) $(DTBS) LICENCE.broadcom)
ifeq ($(WITH_OVERLAYS),1)
  OVERLAY_STAMP := $(DL_DIR)/.overlays.stamp
endif

# ---------------------------------------------------------------------------
# Generated boot files
# ---------------------------------------------------------------------------

# No device_tree= line: the firmware picks the device tree from the board it
# detects, which is the whole reason one card can serve several models. kernel=
# is stated per board anyway, because BCM2712 needs a different image from the
# rest and guessing wrong is a silent non-boot.
#
# Deliberately minimal - this is an OS boot partition, not a desktop image. See
# RPi-Distro/pi-gen for the settings Raspberry Pi OS adds on top.
define board_config_block
echo ""; echo "[$(FILTER_$(1))]"; echo "kernel=$(KERNEL_$(SOC_$(1)))";
endef

# console=serial0 follows the firmware's own serial alias, so one line is right
# whether the console lands on the PL011 or the mini UART. On Pi 5 / CM5 that
# alias is the dedicated 3-pin debug connector (uart10), because GPIO 14/15
# belong to the RP1 southbridge. To move the Pi 5 console onto the 40-way
# header instead, add dtparam=uart0_console under [pi5].
CMDLINE_ROOT ?= /dev/mmcblk0p2
define CMDLINE_TXT
console=serial0,115200 console=tty1 root=$(CMDLINE_ROOT) rootfstype=ext4 fsck.repair=yes rootwait
endef
export CMDLINE_TXT

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

.PHONY: fetch
fetch: $(DOWNLOADS) $(OVERLAY_STAMP) ## Download this board's official Raspberry Pi artifacts

# --fail keeps a 404 page from being saved as if it were firmware; the
# .part/mv pair keeps an interrupted transfer from looking like a good file.
$(DL_DIR)/%:
	@mkdir -p $(@D)
	@echo "  FETCH    $* ($(FIRMWARE_TAG))"
	@curl --fail --silent --show-error --location \
	      --retry 3 --retry-delay 2 --retry-connrefused \
	      -o $@.part "$(FW_BASE_URL)/$*"
	@mv -f $@.part $@

# 371 overlays would be 371 requests over HTTP. A blobless sparse clone gets
# them in one, and still pins the exact tag.
$(DL_DIR)/.overlays.stamp:
	@mkdir -p $(DL_DIR)
	@echo "  FETCH    overlays/ ($(FIRMWARE_TAG))"
	@rm -rf $(DL_DIR)/.fwgit
	@git -c advice.detachedHead=false clone --quiet --depth 1 \
	     --filter=blob:none --sparse \
	     --branch $(FIRMWARE_TAG) $(FW_GIT_URL) $(DL_DIR)/.fwgit
	@git -C $(DL_DIR)/.fwgit sparse-checkout set --no-cone boot/overlays >/dev/null
	@rm -rf $(DL_DIR)/overlays
	@cp -R $(DL_DIR)/.fwgit/boot/overlays $(DL_DIR)/overlays
	@rm -rf $(DL_DIR)/.fwgit
	@touch $@

CHECKSUM_FILE := checksums/firmware-$(FIRMWARE_TAG).sha256
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

.PHONY: checksums
checksums: $(DOWNLOADS) ## Record SHA-256 of the downloaded artifacts
	@mkdir -p checksums
	@cd $(DL_DIR) && $(SHA256) $(FW_FILES) $(KERNELS) $(DTBS) > $(CURDIR)/$(CHECKSUM_FILE)
	@echo "  WROTE    $(CHECKSUM_FILE)"

.PHONY: verify-firmware
verify-firmware: ## Check downloads against the recorded SHA-256 manifest
	@test -f $(CHECKSUM_FILE) || { echo "No $(CHECKSUM_FILE); run 'make checksums' first." >&2; exit 1; }
	@cd $(DL_DIR) && $(SHA256) --check --quiet $(CURDIR)/$(CHECKSUM_FILE)
	@echo "  OK       $(CHECKSUM_FILE)"

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

.PHONY: stage
stage: $(STAGE_DIR)/.stamp ## Assemble the boot partition contents on disk

# Rewritten only when the signature actually changes, so it works as a normal
# prerequisite instead of forcing a rebuild every run.
.PHONY: FORCE
FORCE:

$(CONFIG_STAMP): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(CONFIG_SIG)' | cmp -s - $@ || printf '%s\n' '$(CONFIG_SIG)' > $@

$(STAGE_DIR)/.stamp: $(DOWNLOADS) $(OVERLAY_STAMP) $(CONFIG_STAMP) Makefile
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)
	@echo "  STAGE    $(BOARD) [$(IMAGE_BOARDS)]"
	@cp $(DOWNLOADS) $(STAGE_DIR)/
ifeq ($(WITH_OVERLAYS),1)
	@cp -R $(DL_DIR)/overlays $(STAGE_DIR)/overlays
endif
	@{ echo "# SepiaOS boot partition"; \
	   echo "# Boards:   $(IMAGE_BOARDS)"; \
	   echo "# Firmware: $(FIRMWARE_TAG)"; \
	   echo "#"; \
	   echo "# The firmware selects the device tree from the board it detects,"; \
	   echo "# so no device_tree= line belongs here."; \
	   echo ""; \
	   echo "arm_64bit=1"; \
	   echo "enable_uart=1"; \
	   echo "disable_overscan=1"; \
	   $(foreach b,$(IMAGE_BOARDS),$(call board_config_block,$(b))) \
	   echo ""; echo "[all]"; \
	 } > $(STAGE_DIR)/config.txt
	@printf '%s\n' "$$CMDLINE_TXT" > $(STAGE_DIR)/cmdline.txt
	@touch $@

# ---------------------------------------------------------------------------
# Disk image
#
# mformat/mcopy address the partition directly as image@@byteoffset, so they
# need no drive letter. mpartition is the one tool that insists on one, hence
# the generated mtoolsrc; it is written per build so ~/.mtoolsrc is untouched.
# ---------------------------------------------------------------------------

.PHONY: image sd-image
image sd-image: $(IMAGE) ## Build the bootable FAT32 disk image

$(IMAGE): $(STAGE_DIR)/.stamp $(CONFIG_STAMP)
	@mkdir -p $(@D)
	@echo "  IMAGE    $@ ($(IMAGE_SIZE_MIB) MiB)"
	@rm -f $@.part
	@dd if=/dev/zero of=$@.part bs=1048576 count=$(IMAGE_SIZE_MIB) status=none
	@printf 'drive z: file="%s" partition=1 mformat_only\n' "$(CURDIR)/$@.part" > $(MTOOLSRC_FILE)
	@MTOOLSRC=$(MTOOLSRC_FILE) mpartition -I -c -a \
	    -b $(PART_START) -l $(PART_SECTORS) -T 0x0c z:
	@mformat -F -v $(VOLUME_LABEL) -i $@.part@@$(PART_OFFSET) ::
	@mcopy -s -o -i $@.part@@$(PART_OFFSET) $(STAGE_DIR)/* ::
	@mv -f $@.part $@
	@echo "  OK       $@"

.PHONY: verify
verify: $(IMAGE) ## List what ended up on the boot partition
	@echo "== partition table =="
	@$(SHA256) $(IMAGE) | sed 's/^/  sha256 /'
	@hexdump -C -s 446 -n 66 $(IMAGE)
	@echo "== boot partition =="
	@mdir -i $(IMAGE)@@$(PART_OFFSET) ::

# ---------------------------------------------------------------------------
# Emulation
#
# QEMU implements the ARM side of a Pi, not the VideoCore boot ROM: it never
# reads bootcode.bin, start.elf or config.txt from the card, so the kernel and
# device tree have to be handed to it on the command line. The image is still
# attached, and the kernel does enumerate its partition.
#
# earlycon is not decoration. Without it the UART stays silent, because the
# kernel stalls before ttyAMA0 is registered and nothing ever drains the log.
#
# So this proves the kernel and the partition layout. It proves nothing about
# config.txt, cmdline.txt, bootcode.bin, start.elf, device tree auto-selection
# or overlay loading - all of which only run on real hardware.
#
# snapshot=on keeps the guest from writing back into the build artifact.
# ---------------------------------------------------------------------------

QEMU_APPEND := console=ttyAMA0,115200 earlycon=pl011,$(EARLYCON) root=$(QEMU_ROOTDEV) rootwait

define require_qemu_board
	@test -n "$(QEMU_BOARD)" || { \
	  echo "Nothing in '$(BOARD)' [$(IMAGE_BOARDS)] can be emulated:" >&2; \
	  echo "QEMU has no BCM2712 machine, so pi5 and cm5 are hardware-only." >&2; \
	  echo "Emulable boards: $(foreach b,$(BOARDS),$(if $(QEMU_MACHINE_$(b)),$(b)))" >&2; \
	  exit 1; }
endef

.PHONY: qemu run
qemu run: $(IMAGE) ## Boot the image under QEMU (exit with Ctrl-A then X)
	$(require_qemu_board)
	@echo "  QEMU     $(QEMU_BOARD) as $(QEMU_MACHINE) -- exit with Ctrl-A then X"
	qemu-system-aarch64 \
	    -machine $(QEMU_MACHINE) \
	    -nographic -no-reboot \
	    -kernel $(DL_DIR)/$(QEMU_KERNEL) \
	    -dtb $(DL_DIR)/$(QEMU_DTB) \
	    -drive file=$(IMAGE),format=raw,if=sd,snapshot=on \
	    -append "$(QEMU_APPEND)"

# Non-interactive counterpart: boot, capture serial to a file, report.
QEMU_LOG      ?= $(BUILD_DIR)/boot.log
QEMU_TIMEOUT  ?= 40

.PHONY: boot-check
boot-check: $(IMAGE) ## Boot under QEMU headless and assert the card is readable
	$(require_qemu_board)
	@echo "  BOOT     $(QEMU_BOARD) as $(QEMU_MACHINE) (max $(QEMU_TIMEOUT)s)"
	@rm -f $(QEMU_LOG)
	@qemu-system-aarch64 \
	    -machine $(QEMU_MACHINE) -display none -no-reboot \
	    -serial file:$(QEMU_LOG) \
	    -kernel $(DL_DIR)/$(QEMU_KERNEL) -dtb $(DL_DIR)/$(QEMU_DTB) \
	    -drive file=$(IMAGE),format=raw,if=sd,snapshot=on \
	    -append "$(QEMU_APPEND)" </dev/null >/dev/null 2>&1 & \
	  qemu_pid=$$!; \
	  for i in $$(seq $(QEMU_TIMEOUT)); do \
	    sleep 1; \
	    grep -aq 'mmcblk[0-9]: p1' $(QEMU_LOG) 2>/dev/null && break; \
	    kill -0 $$qemu_pid 2>/dev/null || break; \
	  done; \
	  kill -9 $$qemu_pid 2>/dev/null || true; wait $$qemu_pid 2>/dev/null || true
	@grep -aq 'Machine model' $(QEMU_LOG) || { echo "kernel produced no serial output" >&2; exit 1; }
	@sed -n 's/.*\(Machine model.*\)/  MODEL    \1/p' $(QEMU_LOG) | head -1
	@grep -aq 'mmcblk[0-9]: p1' $(QEMU_LOG) \
	  && echo "  OK       kernel enumerated the boot partition" \
	  || { echo "  FAIL     kernel never saw the boot partition (see $(QEMU_LOG))" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: list-boards
list-boards: ## Show supported boards and board groups
	@printf '%-12s %-8s %-28s %-10s %s\n' BOARD SOC DTB QEMU DESCRIPTION
	@$(foreach b,$(BOARDS),printf '%-12s %-8s %-28s %-10s %s\n' \
	    '$(b)' '$(SOC_$(b))' '$(DTB_$(b))' \
	    '$(or $(QEMU_MACHINE_$(b)),-)' '$(DESC_$(b))';)
	@echo
	@echo "Groups (one card that boots every member):"
	@printf '%-12s %-40s %s\n' GROUP MEMBERS DESCRIPTION
	@$(foreach g,$(GROUPS),printf '%-12s %-40s %s\n' \
	    '$(g)' '$(GROUP_$(g))' '$(GDESC_$(g))';)

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf build

.PHONY: distclean
distclean: clean ## Also remove downloaded artifacts
	rm -rf downloads

# Read one variable's value, for scripts and CI: make -s print-FIRMWARE_TAG
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS boot partition builder"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z_-]+([ ]+[a-zA-Z_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-16s %s\n" \
	  "BOARD"          "board OR group (default $(BOARD)); see make list-boards" \
	  "QEMU_BOARD"     "which member of a group to emulate (default: first emulable)" \
	  "FIRMWARE_TAG"   "upstream firmware release (default $(FIRMWARE_TAG))" \
	  "IMAGE_SIZE_MIB" "image size, power of two (default $(IMAGE_SIZE_MIB))" \
	  "WITH_OVERLAYS"  "include device tree overlays (default $(WITH_OVERLAYS))" \
	  "CMDLINE_ROOT"   "root= written to cmdline.txt (default $(CMDLINE_ROOT))"
	@echo
	@echo "Examples:"
	@echo "  make BOARD=pi4 image                     one board"
	@echo "  make BOARD=universal image               one card for all six boards"
	@echo "  make BOARD=universal QEMU_BOARD=pi4 qemu boot that card as a Pi 4"
