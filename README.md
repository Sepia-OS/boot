# SepiaOS - boot

SepiaOS is an operating system based on the original Linux kernel, firmware etc. from the official RaspberryPi OS. It runs on Raspberry Pi Zero 2W, RaspberryPi 3, 4, 5, CM4 and CM5.

Everything on top of the kernel are custom developments.

This repository contains Makefiles for creating the `boot` partition for the SD card.

- [docs/BUILDING.md](docs/BUILDING.md) — building an image, board groups, every `make` target
- [docs/CI.md](docs/CI.md) — the GitHub Actions build and release pipelines

```sh
gmake list-boards               # what can be built
gmake BOARD=universal image     # one card that boots all six boards
```
