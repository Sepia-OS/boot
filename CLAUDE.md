# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from the official Raspberry Pi OS; everything above the kernel is custom. Supported targets are Pi Zero 2W, Pi 3, Pi 4, Pi 5, CM4 and CM5.

This repository is the `boot` component: a Makefile that assembles the **boot partition** of the SD card. That means the FAT partition the Pi firmware reads at power-on — the Raspberry Pi boot firmware blobs, `config.txt`, `cmdline.txt`, device tree blobs and overlays, and the kernel image.

Two facts drive the shape of the build:

- The firmware set differs per SoC, in three tiers, so a single flat copy rule would be wrong (the Makefile encodes this as `FW_bcm2837` / `FW_bcm2711` / `FW_bcm2712`):
  - **BCM2837** (Pi 3, Zero 2W) — the GPU reads `bootcode.bin` from the card, then `start.elf`/`fixup.dat`.
  - **BCM2711** (Pi 4, CM4) — first stage lives in SPI EEPROM, so no `bootcode.bin`; the card supplies `start4.elf`/`fixup4.dat`.
  - **BCM2712** (Pi 5, CM5) — the EEPROM firmware loads `config.txt` and the kernel directly; no `start*.elf` on the card at all.
- Pi 5 and CM5 (BCM2712) differ further: the debug UART is on the dedicated 3-pin connector rather than GPIO 14/15, because those pins belong to the RP1 southbridge. That affects generated `config.txt`/`cmdline.txt` console settings, not just file placement.

## Layout

Everything that matters is checked in and small:

| Path | |
|---|---|
| [Makefile](Makefile) | the entire build — there is no other build script, no submodules, no vendored source |
| [docs/BUILDING.md](docs/BUILDING.md) | user-facing build guide: boards, groups, every target and variable, QEMU, flashing |
| [docs/CI.md](docs/CI.md) | the two GitHub Actions pipelines and the reasoning behind them |
| [checksums/firmware-1.20260521.sha256](checksums/firmware-1.20260521.sha256) | pinned artifact manifest; upstream publishes no checksums, so this repo records its own |
| [.github/workflows/](.github/workflows/) | `ci.yml` (build + boot) and `release.yml` (manual publish) |

`build/`, `downloads/` and `dist/` are generated and gitignored. Licence is Apache 2.0.

The Makefile, `docs/BUILDING.md` and `docs/CI.md` deliberately overlap. Changing the board matrix, a target, a variable or a default means updating `docs/BUILDING.md` in the same change; changing a workflow means updating `docs/CI.md`.

## Commands

**Use `gmake`, not `make`.** The Makefile hard-errors on Make 3.81 (`/usr/bin/make` on macOS).

```sh
gmake help                      # every target, with the variables that steer them
gmake list-boards               # boards and groups
gmake BOARD=pi3 image           # build/pi3/sepiaos-pi3.img
gmake BOARD=pi3 qemu            # boot it under QEMU (exit: Ctrl-A then X)
gmake BOARD=pi3 boot-check      # headless boot, asserts the kernel sees the partition
gmake BOARD=pi3 verify          # dump the MBR and list the FAT contents
gmake BOARD=universal checksums # record SHA-256 of the downloaded artifacts
gmake verify-firmware           # check downloads against that manifest
gmake clean                     # drop build/, keep downloads/
gmake distclean                 # also drop downloads/
gmake -s print-IMAGE            # read any variable's value (used by release.yml)
```

Variables: `BOARD` (default `pi3`), `QEMU_BOARD`, `FIRMWARE_TAG` (default `1.20260521`), `IMAGE_SIZE_MIB` (default `64`, power of two only), `WITH_OVERLAYS`, `CMDLINE_ROOT`, `PART_START`, `VOLUME_LABEL`, `QEMU_TIMEOUT` (default `40`).

`boot-check` is the fast regression gate — it boots the image and greps the serial log for `mmcblk*: p1`. A full clean build plus boot-check takes a few seconds.

## One Card, Several Boards

`BOARD` takes a **group** as well as a single board — `bcm2837`, `bcm2711`, `bcm2712`, or `universal` (all six). The image then carries the union of its members' firmware, kernels and device trees:

```sh
gmake BOARD=universal image                     # one card that boots all six
gmake BOARD=universal QEMU_BOARD=pi4 boot-check # boot that same card as a Pi 4
```

This works because the firmware picks the device tree from the board it detects, and `config.txt` conditional filters carry the per-board differences — the mechanism Raspberry Pi OS uses to ship a single image for every model. So the generated `config.txt` deliberately has **no `device_tree=` line**; it states `kernel=` per board under `[pi02]`/`[pi3]`/`[pi4]`/`[cm4]`/`[pi5]`/`[cm5]`, because BCM2712 needs `kernel_2712.img` where the others need `kernel8.img`. Verified: one `universal` image, unchanged SHA-256, boots as Zero 2 W, Pi 3, Pi 4 and CM4.

Groups also ship the DTB siblings a board might resolve to instead of the primary name (`bcm2711-rpi-400.dtb`, the four CM5 carrier variants, the Pi 5 D-stepping trees) — `DTB_EXTRA_*` in the Makefile. Shipping only the primary name is what makes a card boot on one CM5 carrier and not another.

`universal` is what a release ships, and the only configuration CI runs `verify-firmware` on.

## Non-Obvious Constraints

All of these were established by running the tools, not from documentation, and each one silently produces a broken or confusing result if violated:

- **QEMU never runs the VideoCore boot chain.** It emulates the ARM side only, so it ignores `bootcode.bin`, `start.elf` and `config.txt` on the card. The kernel and DTB must be passed as `-kernel`/`-dtb`. Booting an image with no `-kernel` produces *no output at all*, which reads like a broken image but isn't.
- **`earlycon=` is mandatory under QEMU** or the serial console stays completely silent — the kernel stalls before `ttyAMA0` registers and nothing ever drains the log buffer. The PL011 base differs per SoC: `0x3f201000` (BCM2837), `0xfe201000` (BCM2711).
- **QEMU rejects any SD image whose size is not a power of two** ("Invalid SD card size"). Hence `IMAGE_SIZE_MIB` is validated.
- **The Zero 2 W device tree does not work on `raspi3ap`** — it takes a synchronous external abort in `bcm2835_power_probe`. It is emulated as `raspi3b`, which works.
- **The Pi 4 exposes the card as `mmcblk1` under QEMU but `mmcblk0` on real hardware.** So the QEMU `-append` root device and the `root=` in the generated `cmdline.txt` deliberately differ.
- **`mpartition` is the one mtool that will not take `-i image@@offset`**; it needs a drive letter, so the image rule generates a throwaway `mtoolsrc` rather than touching `~/.mtoolsrc`. `mformat`, `mcopy` and `mdir` all take `-i` directly.
- **The partition must be populated by a single `mcopy` invocation.** mtools has no locking: concurrent `mcopy` calls against one image silently drop files while still exiting 0. Never split partition population across parallel Make targets.
- **`$(file >…)` cannot be used in a recipe that creates its own directory.** Make expands a recipe in full before running any line, so the write happens before `mkdir`. The generated `config.txt`/`cmdline.txt` go through exported environment variables instead.
- **A variable override touches no file, so Make cannot see it.** `CONFIG_SIG` and the `build/<board>/.config` stamp exist for that: without them `IMAGE_SIZE_MIB=64 gmake image` reports "Nothing to be done" and hands back the old 256 MiB card. Any new variable that changes what lands in the image must be added to `CONFIG_SIG`.
- **`checksums` writes a per-tag file but board-dependent content.** `gmake BOARD=pi3 checksums` overwrites the committed 23-entry universal manifest with pi3's six files; `verify-firmware` would then still pass while checking almost nothing. Always regenerate with `BOARD=universal`. The manifest covers firmware, kernels and DTBs only — not `overlays/`.
- A boot partition alone boots the kernel to `Kernel panic … VFS: Unable to mount root fs`. That is the expected end state, not a failure — there is no root filesystem yet.
- **`dtparam=uart0_console` does not do what its name suggests on Pi 5.** Per the overlays README it is 2712-only and moves the console *to UART0 on pins 6, 8 and 10 of the 40-way header* — away from the dedicated debug connector. Plain `enable_uart=1` is what puts the console on the 3-pin connector.
- **`boot-check` proves the kernel and the partition layout, and nothing else.** QEMU never executes `bootcode.bin`, `start.elf`, `config.txt`, device tree auto-selection or overlay loading, so a green boot-check says nothing about whether those are correct. Only real hardware tests them — which is why no `config.txt` change can be considered verified here, in CI or locally.

## CI and Releases

Full reasoning in [docs/CI.md](docs/CI.md); the parts that constrain changes here:

- **CI** ([ci.yml](.github/workflows/ci.yml)) runs on every branch and every PR against `main`: a six-entry `board` matrix (the four emulable ones are booted, `pi5`/`cm5` are built only), plus a `universal` job gated to `main` that boots the one card as all four emulable boards and is the only job running `verify-firmware`.
- **Both workflows only call documented `make` targets**, so any CI failure reproduces locally verbatim. Keep it that way — no shell logic in a workflow that the Makefile could own.
- **`debian:trixie-slim` is deliberate.** QEMU's `raspi4b` machine arrived in QEMU 9.0; Debian 12 ships 7.2 and Ubuntu 24.04 ships 8.2, so `pi4`/`cm4` cannot be booted at all on those. Check `qemu-system-aarch64 -machine help | grep raspi4b` before changing the base image.
- **`QEMU_TIMEOUT: 180` in CI** because hosted runners are x86_64 and run the AArch64 kernels under full TCG. The 40 s local default is not enough headroom there.
- **Build tools are installed before `actions/checkout`.** Without `git` in the container, checkout silently falls back to a tarball download — and the Makefile needs `git` for the sparse overlays clone.
- **Releases are never automatic** ([release.yml](.github/workflows/release.yml)). Manual dispatch only; the dispatched ref is ignored and the release always comes from `main`'s head, which the `gate` job resolves once and reuses for the CI check, the `rel-<version>` branch, the release target and the notes. `gate` refuses a commit with no green `ci.yml` run, and `rollback` deletes the release branch if the build fails.
- `release.yml` calls `make -s print-FIRMWARE_TAG` and `make -s print-IMAGE`, so the `print-%` target and those two variable names are a CI contract.
- The `publish` job sits with no output for ~14 minutes uploading the ~21 MiB asset. That is measured, not a hang.

## Build Environment

The user develops on macOS (`darwin`). Two things that repeatedly matter for Pi build tooling there:

- **GNU Make ≥ 4.0 is required**, which on macOS means `gmake` (`brew install make`), not `/usr/bin/make`. Make 3.81 compares timestamps only to the second and silently uses stale outputs after a fast edit, so the Makefile refuses to run on it rather than producing a subtly wrong boot partition.
- macOS lacks the Linux disk utilities (`sfdisk`, loop mounts). Everything touching the partition table or the FAT filesystem goes through `mtools`, so the build runs unprivileged on both macOS and Linux.

Required tools: `gmake`, `curl`, `git`, `mtools`, and `qemu-system-aarch64` for the emulation targets (`brew install make mtools qemu`). Developed against QEMU 11.1.
