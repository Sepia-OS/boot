# Building the SepiaOS boot partition

This repository builds the **boot partition** of a SepiaOS SD card: the FAT32
partition the Raspberry Pi firmware reads at power-on. The `Makefile` downloads
the official Raspberry Pi boot artifacts, assembles them into an MBR disk image,
and can boot the result under QEMU.

Everything runs unprivileged. There is no `sudo`, no loop mounting and no
`sfdisk` anywhere in the build — the image is assembled with `mtools`, so the
same recipes work on macOS and Linux.

---

## 1. Prerequisites

| Tool | Why | Minimum |
|---|---|---|
| GNU Make | build driver | **4.0** |
| `curl` | fetches firmware, kernels and device trees | any |
| `git` | fetches the overlays directory in one request | 2.25 |
| `mtools` | creates the partition table and the FAT32 filesystem | 4.0 |
| `qemu-system-aarch64` | the `qemu` and `boot-check` targets only | see below |

The build is developed and tested against QEMU 11.1. Any version whose
`qemu-system-aarch64 -machine help` lists `raspi3b` and `raspi4b` should work;
check yours before filing a boot failure.

```sh
# macOS
brew install make mtools qemu

# Debian / Ubuntu
sudo apt install make mtools qemu-system-arm git curl
```

> **On macOS, run `gmake`, not `make`.**
> `/usr/bin/make` is GNU Make 3.81, which compares file timestamps only to the
> whole second and will silently reuse a stale object after a fast edit. The
> Makefile refuses to run on it rather than producing a subtly wrong boot
> partition. Every `gmake` below is plain `make` on Linux.

---

## 2. Quick start

```sh
gmake list-boards            # what can be built
gmake BOARD=pi3 image        # -> build/pi3/sepiaos-pi3.img
gmake BOARD=pi3 boot-check   # headless boot, asserts the card is readable
gmake BOARD=pi3 qemu         # interactive boot; exit with Ctrl-A then X
```

From a completely empty tree, a single-board build takes about 5 seconds and
downloads roughly 15 MB; `BOARD=universal` takes about 9 seconds and 28 MB.
Artifacts are cached in `downloads/<firmware-tag>/` and shared by every board,
so only the first build pays for the download.

Run `gmake help` at any time for the full target list and the variables that
steer it.

---

## 3. Supported boards

| `BOARD` | SoC | Device tree | QEMU machine | Notes |
|---|---|---|---|---|
| `pi-zero2w` | BCM2837 | `bcm2710-rpi-zero-2-w.dtb` | `raspi3b` | |
| `pi3` | BCM2837 | `bcm2710-rpi-3-b.dtb` | `raspi3b` | default |
| `pi4` | BCM2711 | `bcm2711-rpi-4-b.dtb` | `raspi4b` | |
| `cm4` | BCM2711 | `bcm2711-rpi-cm4.dtb` | `raspi4b` | |
| `pi5` | BCM2712 | `bcm2712-rpi-5-b.dtb` | — | builds, cannot be emulated |
| `cm5` | BCM2712 | `bcm2712-rpi-cm5-cm5io.dtb` | — | builds, cannot be emulated |

**Pi 5 and CM5 cannot be emulated.** QEMU has no BCM2712 machine type, so
`gmake BOARD=pi5 qemu` refuses with an explanation. Their images build normally
and are only testable on real hardware.

The firmware set differs per SoC, which is why one flat copy rule would be
wrong:

| SoC | Boards | Firmware on the card |
|---|---|---|
| BCM2837 | Pi 3, Zero 2 W | `bootcode.bin`, `start.elf`, `fixup.dat` |
| BCM2711 | Pi 4, CM4 | `start4.elf`, `fixup4.dat` — first stage is in SPI EEPROM, so no `bootcode.bin` |
| BCM2712 | Pi 5, CM5 | *none* — EEPROM firmware loads `config.txt` and the kernel directly |

---

## 4. One card for several boards

`BOARD` also accepts a **group**, and the image then carries the union of what
its members need:

| Group | Members |
|---|---|
| `bcm2837` | `pi-zero2w pi3` |
| `bcm2711` | `pi4 cm4` |
| `bcm2712` | `pi5 cm5` |
| `universal` | all six |

```sh
gmake BOARD=universal image                     # one card that boots all six
gmake BOARD=universal QEMU_BOARD=pi4 boot-check # boot that same card as a Pi 4
```

This works because the firmware selects the device tree from the board it
detects, and `config.txt` conditional filters carry the per-board differences —
the same mechanism Raspberry Pi OS uses to ship one image for every model.

The generated `config.txt` therefore has **no `device_tree=` line**. It does
state `kernel=` per board, because BCM2712 needs `kernel_2712.img` where the
others need `kernel8.img`, and guessing wrong is a silent non-boot:

```ini
[pi02]
kernel=kernel8.img

[pi3]
kernel=kernel8.img

[pi4]
kernel=kernel8.img

[cm4]
kernel=kernel8.img

[pi5]
kernel=kernel_2712.img

[cm5]
kernel=kernel_2712.img

[all]
```

Groups also ship the device tree *siblings* a board might resolve to instead of
the primary name — the four CM5 carrier variants, the Pi 5 D-stepping trees,
`bcm2711-rpi-400.dtb`. Shipping only the primary name is what makes a card boot
on one CM5 carrier and not another. See `DTB_EXTRA_*` in the `Makefile`.

A `universal` image uses about 27 MB, leaving 33 MB free on the default 60 MB
boot partition.

---

## 5. Targets

| Target | What it does |
|---|---|
| `help` | target list and variables (the default goal) |
| `list-boards` | boards and groups |
| `fetch` | download this board's artifacts, nothing more |
| `stage` | assemble the partition contents under `build/<board>/boot/` |
| `image`, `sd-image` | build `build/<board>/sepiaos-<board>.img` |
| `verify` | dump the MBR and list the FAT contents |
| `qemu`, `run` | boot the image interactively under QEMU |
| `boot-check` | boot headless and assert the kernel sees the partition |
| `checksums` | record SHA-256 of the downloaded artifacts |
| `verify-firmware` | check downloads against that manifest |
| `clean` | remove `build/`, keep `downloads/` |
| `distclean` | also remove `downloads/` |

## 6. Variables

| Variable | Default | Meaning |
|---|---|---|
| `BOARD` | `pi3` | board or group to build |
| `QEMU_BOARD` | first emulable member | which member of a group to emulate |
| `FIRMWARE_TAG` | `1.20260521` | pinned upstream firmware release |
| `IMAGE_SIZE_MIB` | `64` | whole-disk size; **must be a power of two** |
| `PART_START` | `8192` | partition start sector (4 MiB, as Raspberry Pi OS uses) |
| `VOLUME_LABEL` | `BOOT` | FAT volume label |
| `WITH_OVERLAYS` | `1` | include the device tree overlays |
| `CMDLINE_ROOT` | `/dev/mmcblk0p2` | `root=` written into `cmdline.txt` |
| `QEMU_TIMEOUT` | `40` | seconds `boot-check` waits |

### Image size

`IMAGE_SIZE_MIB` is the **whole disk**, not the partition. The first
`PART_START` sectors (4 MiB) are the gap before the partition starts, so the
default 64 MiB disk carries a **60 MiB boot partition** — 33 MiB of which is
still free after a `universal` build.

It must be a power of two, and the Makefile enforces that, because QEMU refuses
any other SD size (`Invalid SD card size`). This is also why the partition is
not simply rounded up to 64 MiB: that would need a 68 MiB disk, which QEMU
would reject, forcing 128 MiB and wasting more than it saved.

Changing any of these settings on the command line rebuilds the image even
though no file on disk changed — the build records a signature of them, so
`IMAGE_SIZE_MIB=128 gmake image` cannot hand back a stale card.

Upstream publishes no checksums for these artifacts, so `checksums` records
them at the pinned tag and `verify-firmware` checks against that manifest.
Commit `checksums/` to make the pin meaningful for everyone else.

---

## 7. What ends up on the partition

```
bootcode.bin          BCM2837 only
start.elf fixup.dat   BCM2837 only
start4.elf fixup4.dat BCM2711 only
kernel8.img           BCM2837 / BCM2711
kernel_2712.img       BCM2712
*.dtb                 device trees for the selected boards
overlays/             371 files: 368 .dtbo overlays, two map files, README
config.txt            generated
cmdline.txt           generated
LICENCE.broadcom
```

Inspect a built image at any time without mounting it:

```sh
gmake BOARD=pi3 verify
```

---

## 8. Running under QEMU

```sh
gmake BOARD=pi3 qemu
```

**Exit with `Ctrl-A` then `X`.** `Ctrl-C` goes to the guest, not to QEMU.

You should see the kernel come up and find the partition:

```
[    0.000000] Machine model: Raspberry Pi 3 Model B
[    1.966404] mmc0: new high speed SD card at address 9bf1
[    1.972030] mmcblk0: mmc0:9bf1 QEMU! 64.0 MiB
[    1.993816]  mmcblk0: p1
[    1.998320] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(179,2)
```

**That panic is the expected end state, not a failure.** This repository builds
the boot partition only; there is no root filesystem yet, so the kernel reaches
`rootwait`, finds no `p2`, and gives up. The line that matters is `mmcblk0: p1`
— it means the firmware image, the partition table and the FAT filesystem are
all well-formed.

`boot-check` automates exactly that check and is the fast regression gate:

```sh
$ gmake BOARD=pi4 boot-check
  BOOT     pi4 as raspi4b (max 40s)
  MODEL    Machine model: Raspberry Pi 4 Model B
  OK       kernel enumerated the boot partition
```

The emulated card is opened with `snapshot=on`, so a guest can never write back
into the build artifact.

### What QEMU proves, and what it does not

QEMU emulates the ARM side of a Raspberry Pi, **not** the VideoCore boot ROM. It
never executes `bootcode.bin` or `start.elf`, and it never reads `config.txt` or
`cmdline.txt` from the card. The `qemu` target therefore passes the kernel and
device tree on the command line with `-kernel` and `-dtb`, and supplies its own
kernel command line with `-append`.

| Exercised by `boot-check` | Only testable on real hardware |
|---|---|
| MBR partition table | `bootcode.bin` / `start.elf` chain |
| FAT32 filesystem | `config.txt` and its conditional filters |
| Kernel image loads and runs | `cmdline.txt` |
| Kernel enumerates the partition | device tree auto-selection |
| | overlay loading |

A green `boot-check` says nothing about whether `config.txt` is correct. Treat
any change to the generated boot files as unverified until a real board boots
it.

---

## 9. Writing to a real SD card

The Makefile has no card-writing target on purpose — it is destructive and
needs root. The image is a complete disk image (MBR plus one FAT32 partition),
so write it with the tool you already trust: Raspberry Pi Imager, `balenaEtcher`,
or `dd`.

```sh
# macOS - find the disk, note it is /dev/rdiskN (raw) for speed
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if=build/pi3/sepiaos-pi3.img of=/dev/rdiskN bs=4m status=progress
sync
```

```sh
# Linux
lsblk
sudo dd if=build/pi3/sepiaos-pi3.img of=/dev/sdX bs=4M status=progress conv=fsync
```

> **Check the device name twice.** `dd` to the wrong device destroys the disk
> it is pointed at, with no confirmation and no undo.

For serial console access on real hardware, `enable_uart=1` is already in the
generated `config.txt`. On Pi 3, Pi 4, CM4 and Zero 2 W the console is on GPIO
14/15. On Pi 5 and CM5 it is the dedicated 3-pin debug connector, because GPIO
14/15 belong to the RP1 southbridge.

---

## 10. Troubleshooting

**`make` fails immediately with a version error.**
You ran Apple's `/usr/bin/make`. Use `gmake`.

**`Invalid SD card size: … MiB` from QEMU.**
`IMAGE_SIZE_MIB` is not a power of two. The Makefile normally catches this
first.

**QEMU starts and prints absolutely nothing.**
Two known causes. Either the kernel command line lost `earlycon=` — without it
the UART stays silent, because the kernel stalls before `ttyAMA0` is registered
and nothing ever drains the log buffer — or `-kernel` was omitted, in which
case QEMU sits on a card it will never boot from (see §8).

**Nothing appears in `boot.log` but the interactive `qemu` target works.**
Same `earlycon` cause. `-serial file:` cannot pick up output the kernel never
produced.

**Boot stops at `Waiting for root device`.**
Expected. There is no root filesystem; see §8.

**A board boots on one carrier and not another.**
The right device tree is probably not on the card. Build the matching group
(`gmake BOARD=bcm2712 image`) so the sibling trees travel with it.

**`git clone` for overlays is slow or blocked.**
Build with `WITH_OVERLAYS=0` to skip it. The card will boot; overlays only
matter once you start using `dtoverlay=`.

---

## 11. How the image is assembled

For anyone changing the `Makefile`, the four steps and the reason each tool was
chosen:

1. **`dd`** creates a zeroed file of `IMAGE_SIZE_MIB`.
2. **`mpartition`** writes the MBR: one partition, type `0x0c` (FAT32 LBA),
   active, starting at sector `PART_START`. It is the one mtool that will not
   accept `-i image@@offset`, so the recipe generates a throwaway `mtoolsrc`
   rather than touching `~/.mtoolsrc`.
3. **`mformat -F`** makes the FAT32 filesystem inside the partition, addressed
   as `image@@byteoffset`.
4. **`mcopy -s -o`** copies the staged tree in, in a **single invocation**.

That last point is load-bearing: mtools has no locking, and concurrent `mcopy`
calls against one image silently drop files while still exiting 0. Never split
partition population across parallel Make targets.

The image is rebuilt from scratch every time rather than updated in place, so a
renamed or removed file cannot survive into a later build.
