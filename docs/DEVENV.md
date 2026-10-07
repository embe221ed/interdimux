# The dev environment

A container that is CI's runner: Ubuntu 24.04 with every tool the suites ask
for, at the versions `dev/versions.env` pins.  A strict run there
(`IMUX_STRICT=1`, where any skip fails) is what CI runs.  It works the same on
the VPS and on a Mac, because Docker on a Mac runs Linux too:

| machine | image | |
|---|---|---|
| Linux VPS, CI | `linux/amd64` | native |
| Intel Mac | `linux/amd64` | native, under Docker Desktop's (or OrbStack's, colima's) VM |
| Apple Silicon Mac | `linux/arm64` | native, the same Dockerfile built for arm64 |

What a Linux container cannot be is macOS itself: BSD `ps`/`at`/`date`, no
`/proc`, `/bin/bash` 3.2, Homebrew's tmux (built with utf8proc).  See
[What it does not cover](#what-it-does-not-cover).

## Using it

Docker and any GNU make (macOS's 3.81 is fine), or `sh dev/run.sh COMMAND`
without make.

```sh
make test                  # every suite (the Rust core built first)
make test T='raw sched'    # the suites whose names match
make test R=bash           # ... on the bash renderer, as a cargo-less install
make ci                    # CI's tests job: both renderer legs, strict
                           # (the rust leg with check-macos and msrv, as in CI)
make ci R=rust             # one leg
make ci-sigpipe            # the same with SIGPIPE ignored, as GitHub runs it
make versions              # every pinned tool, present and at its pin
make lint                  # tests/lint.sh, then actionlint, hadolint, lychee
make check-macos           # type-check the Rust core for x86_64 and arm64 macOS
make msrv                  # build and test the core on its rust-version (1.74)
make bench ARGS='HEAD~1'   # tests/bench.sh, this tree against a ref
make watch T=raw           # re-run those suites whenever a file changes
make shell                 # a shell inside (tmux there is the container's own)
```

The first run builds the image (about six minutes on 4 cores; most of it is
the six old bashes).  After that a command starts at once while `dev/` and
`rust/Cargo.*` are as the image was built from (it carries their checksum as a
label, so this needs neither the builder nor the network), and otherwise
rebuilds, visibly, only the stages whose pin or recipe changed.  One run at a
time per architecture: a second one is refused while the first holds the work
volume.

## Moving a version

Every version lives in [`dev/versions.env`](../dev/versions.env), and nothing
reads one from anywhere else: the Dockerfile gets them as build arguments, CI
appends the file to `$GITHUB_ENV`, `tests/lint.sh` reads its shellcheck there.
(Comments and docs that say "measured on tmux 3.7b" name the version a
measurement was taken on; they are history, not pins.)

1. Edit the line, e.g. `FZF_VERSION=0.74.5`.
2. `make pin`: downloads what the file now names, for every platform, and
   records each sha256 in `dev/checksums/`.  Where the project publishes its
   own checksums (fzf, actionlint, hadolint, lychee, rustup), the download must
   match them too, or nothing is recorded.  Nothing `dev/install/` fetches
   runs unless its checksum is recorded there: an installer refuses it,
   naming `make pin`.  (Rust's toolchains themselves come through rustup,
   which verifies its own downloads; in CI it is the runner's rustup.)
3. `make ci`, then commit both files.  CI builds the same versions.

Old releases (`OLD_FZF_VERSIONS`, `OLD_BASH_VERSIONS`) follow the suites'
own lists, which are the authority: `tests/test_old_fzf.sh` and
`tests/test_bash_floor.sh` fail when a version they name is missing.

## How a run works

`dev/run.sh` builds the image when `dev/` changed, then starts a fresh
container (`--rm`):

* **The checkout is mounted read-only at `/src`** and copied (rsync) into
  `/work`, a volume per architecture (`interdimux-dev-work-amd64`), where
  everything runs.  So nothing a run does reaches the checkout.  In particular
  it never rebuilds the checkout's `rust/target/release/imux`, which a live
  plugin installed from this checkout runs.  `/work/rust/target` survives
  between runs, so the core is rebuilt only when `rust/` changes.
* **Nothing else of the host is mounted**: no `/tmp`, no tmux socket, no home,
  no docker socket, and `TMUX` is not passed in.  A bare `tmux` inside can only
  reach servers the container started; your errors.log and recent dirs are out
  of reach.
* **Not as root.**  The entrypoint starts `atd` (no systemd in a container),
  then drops to the user `dev`.  As root, `test_doctor` and
  `test_doctor_agents` fail and `test_cli_guards` skips.
* **No terminal and no network** for test runs, as on CI: no tty means
  `stty size </dev/tty` reports nothing there either; tests never use the
  network, and the image fetched the crates.  `make shell` gets both, and
  `make watch` a terminal (entr needs one), so suites run from it can see
  that terminal's size.
* `tini -g` is PID 1, so the many tmux servers and `sleep` panes the suites
  leave behind are reaped.  Ctrl-C stops a run once the suite in progress
  ends, not at once: `tests/run_all.sh` runs each suite under `timeout`, in a
  process group of its own, which the signal does not reach.  `docker stop`
  on the container (`docker ps` names it) ends it at once.
* The image's environment carries only `INTERDIMUX_OLD_FZF_DIR`,
  `INTERDIMUX_OLD_BASH_DIR` and `INTERDIMUX_TEST_DOCKER=off`: `test_bind_keys`
  counts every other `INTERDIMUX_*` that reaches a popup.

`make ci-sigpipe` exists because GitHub starts every `run:` step with SIGPIPE
ignored, which no container does by default and which found a real bug once
([CI.md §10](CI.md#10-github-runs-run-steps-with-sigpipe-ignored)).

## What is in the image

| | version | from |
|---|---|---|
| tmux | `TMUX_VERSION` | source (`dev/install/tmux.sh`), stock configure |
| fzf | `FZF_VERSION` | release binary |
| old fzf | `OLD_FZF_VERSIONS` | release binaries in `/opt/fzf-old/<v>/fzf` |
| bash | 5.2 (noble) | apt |
| old bash | `OLD_BASH_VERSIONS` | source (`dev/install/bash-old.sh`), `/opt/bash-old/<maj.min>/bash` |
| Rust | `RUST_VERSION`, and the MSRV | rustup (`RUSTUP_INIT_VERSION`), minimal, with clippy, rustfmt and the two macOS std targets |
| shellcheck | `SHELLCHECK_VERSION` | release binary |
| actionlint, hadolint, lychee | `*_VERSION` | release binaries |
| zsh, dash, gawk (as `awk`), mawk, at, strace, procps, util-linux, perl, python3, fd-find, git, locales (C.UTF-8 and en_US.UTF-8), ncurses terminfo, entr, rsync, jq | noble | apt |

`make versions` prints all of them, and fails on anything missing or, for
each pinned one, at another version than its pin.

## The other architecture

`PLATFORM=linux/arm64 make ...` builds and runs the Apple Silicon image on an
amd64 machine (and `linux/amd64` the other way), through QEMU.  That is good for
proving the image builds and its tools run there.  It is not good for the
suites: emulation is several times slower, and many suites bound how long a
screen may take to settle.  Run those natively, on the Mac itself.

## What it does not cover

* **macOS's own userland.**  The plugin's macOS paths — the ps-based process
  backend, BSD `at`/`atq` and `date -j`, `launchctl` for atrun, no `/proc` —
  run on Linux only through the seams the suites already use
  (`INTERDIMUX_FORCE_PS`, `INTERDIMUX_REGISTRY_NO_PROC`,
  `INTERDIMUX_AT_DAEMON`, bash 3.2 from `/opt/bash-old`).  The Rust side is
  type-checked for both macOS targets (`make check-macos`, and in CI), but not
  run there.  The suites themselves assume GNU tools, `/proc` and `strace`, so
  they do not run natively on macOS today.
* **Homebrew's tmux**, which is built with utf8proc, so its character widths
  are utf8proc's, not glibc's.
* Real ssh/mosh remotes, network mounts, agent CLIs and a docker daemon for
  `test_title_apps`' container case (`INTERDIMUX_TEST_DOCKER=off`, as on CI).
* Profiling and debugging tools (perf, gdb, a debug tmux), and other tmux,
  fzf or base-image versions side by side.  None of these are in the image yet.

## Files

| | |
|---|---|
| `dev/versions.env` | every pin |
| `dev/checksums/*.sha256` | the sha256 of every artifact, all platforms (`make pin`) |
| `dev/install/*.sh` | the recipes, shared with CI; `lib.sh` fetches and verifies |
| `dev/Dockerfile` | the image, one stage per component |
| `dev/run.sh` | the host side (POSIX sh), what `make` calls |
| `dev/entrypoint.sh`, `dev/cmd.sh` | inside: the root steps, then the commands |
| `dev/lint-extra.sh` | actionlint, hadolint, lychee |
| `dev/pin.sh` | records the checksums |
| `Makefile`, `.dockerignore` | |
