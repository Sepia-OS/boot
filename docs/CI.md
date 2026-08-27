# Continuous integration on GitHub

The pipeline lives in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
and runs on GitHub Actions.

## What it does

| Step | When | What |
|---|---|---|
| `boot-images` | every push, PR, manual | builds and QEMU-boots `pi-zero2w`, `pi3`, `pi4`, `cm4` |
| `hardware-only-images` | every push, PR, manual | builds `pi5` and `cm5` (no QEMU machine exists for BCM2712) |
| `universal-image` | push to `main` | builds the all-boards card, boots it as a Pi 3 *and* a Pi 4, compresses it |
| `tag-and-release` | push to `main` | creates a GitHub release and uploads the image |

Steps run in order in a shared workspace, and the pipeline stops at the first
failure — so nothing is ever tagged or published unless every board built and
every emulable board booted.

A release is tagged `vYYYY.MM.DD-<pipeline number>` and carries two assets:

```
sepiaos-boot-universal-<tag>.img.xz    the universal card, xz-compressed (~22 MB)
SHA256SUMS                             its checksum
```

## One-time setup

No repository secret is required. The release job uses GitHub's automatically
provided `GITHUB_TOKEN`, and its write permission is limited to pushes on the
`main` branch.

## Notes on the pipeline

**Why `debian:trixie-slim`.** QEMU's `raspi4b` machine only arrived in **QEMU
9.0**. Debian 12 ships 7.2 and Ubuntu 24.04 ships 8.2, so on either of those the
Pi 4 and CM4 boot checks cannot run at all. Trixie ships QEMU 10.0. If you
change the base image, check `qemu-system-aarch64 -machine help | grep raspi4b`
first.

**Why `QEMU_TIMEOUT: 180`.** GitHub's hosted runners run the AArch64 kernels
under full TCG emulation. That is correct but much slower than an arm64 host,
and the Makefile's 40-second default is not enough headroom.

**Why tag events do not trigger the pipeline.** The workflow only listens for
pushes, pull requests, and manual dispatches. A release tag therefore cannot
start a second pipeline for the commit that just produced it.

**No download caching.** Each step re-fetches the ~28 MB of firmware. Adding a
cache is possible but was left out deliberately: the download is small, it keeps
the pipeline free of plugin dependencies, and it is polite to donated
infrastructure to keep the config simple.

## Reproducing a CI failure locally

The workflow only calls documented `make` targets, so any failure reproduces
directly:

```sh
make BOARD=pi4 image
make BOARD=pi4 boot-check
make BOARD=universal QEMU_BOARD=pi4 boot-check
```

To reproduce in the same container the runner uses:

```sh
docker run --rm -it -v "$PWD:/src" -w /src debian:trixie-slim bash -c '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    make mtools qemu-system-arm git curl ca-certificates xz-utils bsdextrautils
  QEMU_TIMEOUT=180 make BOARD=pi4 boot-check'
```

## Troubleshooting

**Everything is skipped / no workflow appears.**
Check that Actions are enabled in the repository and that the workflow file is
present on the branch being tested.

**Boot checks time out.**
The runner is slower than usual. Raise `QEMU_TIMEOUT` in the affected step.

**`raspi4b` is not a supported machine.**
The base image's QEMU is older than 9.0. See the note above.

**The release step fails after the tag was created.**
The tag now exists but the release does not. Delete the tag on GitHub and
re-run the workflow, or create the release by hand against the existing tag —
re-running as-is will fail, because the tag name is already taken.
