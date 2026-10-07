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
make smoke                 # tests/smoke.sh: the end-to-end check CI runs on Macs
make ci                    # CI's tests job: both renderer legs, strict
                           # (the rust leg with check-macos, msrv and smoke, as in CI)
make ci R=rust             # one leg
make ci-sigpipe            # the same with SIGPIPE ignored, as GitHub runs it
make versions              # every pinned tool, present and at its pin
make lint                  # tests/lint.sh, then actionlint, hadolint, lychee
make check-macos           # type-check the Rust core for x86_64 and arm64 macOS
make msrv                  # build and test the core on its rust-version (1.74)
make bench ARGS='HEAD~1'   # tests/bench.sh, this tree against a ref
make perfbench             # dev/perf/bench.sh: is this checkout slower than main?
make uxdiff                # dev/perf/uxdiff.sh: does it look any different?
make watch T=raw           # re-run those suites whenever a file changes
make shell                 # a shell inside (tmux there is the container's own)
make clean-volumes         # drop the work volumes of checkouts that are gone
```

The first run builds the image (about six minutes on 4 cores; most of it is
the six old bashes).  After that a command starts at once while `dev/` and
`rust/Cargo.*` are as the image was built from (it carries their checksum as a
label, so this needs neither the builder nor the network), and otherwise
rebuilds, visibly, only the stages whose pin or recipe changed.  One run at a
time per checkout: a second one is refused while the first holds the
checkout's work volume.  Other checkouts -- git worktrees, say -- have volumes
of their own, and the timing-sensitive commands (the suites, the benchmarks,
builds) take turns across all of them ([Several checkouts at
once](#several-checkouts-at-once)).

## Measuring a change: perfbench and uxdiff

Two A/B harnesses in `dev/perf/` answer what a change to the plugin has to
answer before it lands: is it slower, and does it look any different?  Both
compare `REF` -- any commit: `main` (the default), `HEAD~1`, a sha -- with
this checkout as it is, uncommitted edits included:

```sh
make perfbench                                   # every default scenario, ~2 min
make perfbench REF=HEAD~1 ARGS='-n 10 -s list,first-frame,footer'   # ~15 s
make perfbench ARGS=--list                       # the scenarios
make uxdiff ARGS=-q                              # the text entry points, ~1 min
make uxdiff                                      # and every screen, ~6 min
make uxdiff ARGS='-f screen/80x24/'              # the scenarios a regex matches
```

Inside (`dev/cmd.sh perfbench|uxdiff REF ARGS...`), `REF` is extracted from
the checkout's git with `git archive` into a temporary tree and given a Rust
core of its own -- a core built from other sources cannot serve its script --
built offline once per `rust/` tree and toolchain (`rustc -vV`, the linker,
the flags: the volume outlives image rebuilds, and after a `RUST_VERSION`
bump A must not keep the old compiler's core) and kept in the work volume
(`/work/rust/target/perf-ref/`).  This checkout's core is built as for `make
test`; B's header says "with uncommitted changes" when `git status` lists
anything, untracked files included.  Then `dev/perf/bench.sh ARGS <REF's
tree> /work` runs (or `uxdiff.sh`), with `IMUX_PERF_STRICT=1`: the image
has everything they use, so a missing zoxide fails them instead of quietly
measuring a picker without it.  Both scripts document every scenario and
option in their headers, and run as well outside the image on any two built
trees, on Linux (a WARNING says when there is no zoxide).

### perfbench: is B slower than A?

Every scenario is a path a keypress waits on, invoked as its real caller
invokes it -- the navigator opening to its first row, the `--list` reload, a
preview, the per-keystroke footer, the ctrl-o picker, `--doctor` and more --
against one fixture (12 sessions, 40 windows, 90 panes, an attached client)
that A and B share.  A and B run in pairs whose order alternates, after
warm-up pairs, and each run's CPU is the user+sys time of its whole process
tree, orphans included, plus what the tmux server spent meanwhile.

| column | |
|---|---|
| `dcpu%` | B's CPU shift against A: the Hodges-Lehmann estimate over the per-pair differences, in % of A's median |
| `noise%` | the half-width of that shift's 99% confidence interval: the smallest change this run could have seen |
| `verdict` | `REGRESSION` when `dcpu%` > max(2, `noise%`), `FASTER` when it is below minus that, else `ok`; `(n<8)` too few pairs to say; `FAILED` a run exited unexpectedly |
| `wall` | the same for wall time: `ok`, `SLOWER`, `FASTER` |
| `out` | B's output against A's, paths normalised: `same`, `DIFF` (a UX change: the first differing lines are printed), `vol` (A's own varied, so no comparison) |
| `n` | measured pairs; `c` when a flagged scenario was measured again on fresh pairs, the flag standing only if both sets agree |

It exits 0 when there is no CPU regression and every output is the same, 3 on
a `REGRESSION`, 4 when there is none but an output differs, 1 when the bench
itself failed and 2 on a usage error.  (`make` exits 2 whenever a command
fails, naming its status in `Error N`; `sh dev/run.sh perfbench REF ARGS...`
exits with the status itself, which is what a script should run.)  An `ok`
only says that no effect larger than `noise%` was there: A/A runs on this
4-CPU VPS, otherwise idle, put it at 3.7-6% for every scenario at the
default budget (30 to 40 pairs), 9% for `hint` (a 1.6 ms snippet), and at
8-14% with `-n 10`, once 25% (`footer`).  A line `noisy:`
names the scenarios where it was over 10%; re-run those with more pairs
(`ARGS='-n 40 -s footer'`).

### uxdiff: does B look different?

It renders one deterministic fixture through A and through B and compares
what a user would see, byte for byte, colours included.  The fixture has a
zoxide database, so the directory picker's zoxide rows are drawn (and
compared) too.  The text scenarios
run the script's entry points: `--list` on both renderers at five widths, the
preview of every row, the fzf callbacks, the directory picker, `--doctor`,
the effect of `--bind-keys`, and more.  The screen scenarios drive real fzf
in real tmux popups on a real attached client at 120x40, 80x24 and 80x16 --
the navigator, its dialogs and line editing, ctrl-o, the dashboard and its
modes, Health, Jobs, Agents -- captured with `capture-pane -e` and reduced to
each cell's visible style.

One line per scenario, `IDENTICAL` or `DIFF`; it exits 0 when all are
identical, 1 when anything differs or was skipped, 2 on a setup error (`sh
dev/run.sh uxdiff REF ARGS...` for the status itself, as above).  A
screen that differs is run again (`-r N`, default 2) before it counts: a
retry that matches is `IDENTICAL` (flagged "retried"), one that reproduces
both sides byte for byte is a `DIFF` at once.  `-q` runs the text scenarios
only, `-f REGEX` the ones whose name matches.  After the summary, the plain
text of every diff is printed; the full diffs, exact bytes too, and both
sides' captures stay in the work volume until the next `make uxdiff`:
`sh dev/run.sh run cat /work/rust/target/perf/uxdiff/diff/text/doctor-errlog-empty.diff`.

### Numbers worth believing

* **Nothing else heavy may run meanwhile** -- no suites, builds or other
  benchmarks, on the host either -- and only one timing-sensitive run at a
  time: perfbench compares CPU time, and uxdiff's screens wait, bounded, for
  fzf to settle.  perfbench reports the load average before and after (the
  host's: `/proc/loadavg` is not per container) against the host's CPU count,
  and warns about processes over 50% of a CPU -- but in a container it sees
  only the container's own.
* **Timing-sensitive runs take turns by themselves**, across every checkout
  ([Several checkouts at once](#several-checkouts-at-once)): a perfbench
  waits for a suite run from another worktree, saying so, and the other way
  round.  What they do not wait for -- a `make shell`, a `watch`, a `run`, a
  run from an older `dev/run.sh` -- each run names when it starts, and
  perfbench and uxdiff repeat it in their report as a WARNING.
* **Pin the container to CPUs**: `CPUSET=1-3` on 4 CPUs leaves CPU 0 to the
  host (docker, interrupts, your editor) and stops the scheduler from moving
  the run around.  Both sides run pinned alike.  Never `--cpus`: CFS
  throttling stalls the tmux server mid-format.
* perfbench's `-o FILE` and `-K` write inside the container, which is gone
  after the run: give `-o` a path under `/work/rust/target/`, which the work
  volume keeps, and use `-K` from `make shell`.

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
3. `make ci`, then commit both files.  CI builds the same versions; it can
   also be re-run from GitHub's Actions tab ("Run workflow"), without a push.

Old releases (`OLD_FZF_VERSIONS`, `OLD_BASH_VERSIONS`) follow the suites'
own lists, which are the authority: `tests/test_old_fzf.sh` and
`tests/test_bash_floor.sh` fail when a version they name is missing.

## How a run works

`dev/run.sh` builds the image when `dev/` changed, then starts a fresh
container (`--rm`):

* **The checkout is mounted read-only at `/src`** and copied (rsync) into
  `/work`, the checkout's own volume ([below](#several-checkouts-at-once)),
  where everything runs.  So nothing a run does reaches the checkout.  In
  particular it never rebuilds the checkout's `rust/target/release/imux`,
  which a live plugin installed from this checkout runs.  `/work/rust/target`
  survives between runs, so the core is rebuilt only when `rust/` changes:
  when the copy brings anything new under `rust/`, the core's cargo
  fingerprints are dropped, which cargo cannot overlook even for a restored
  file older than its last build.
* **Nothing else of the host is mounted**: no `/tmp`, no tmux socket, no home,
  no docker socket, and `TMUX` is not passed in.  A bare `tmux` inside can only
  reach servers the container started; your errors.log and recent dirs are out
  of reach.  The one exception is a git worktree's repository: its `.git` is a
  file naming a git dir in the main checkout's `.git`, which is mounted
  read-only at its own path, so git works inside (perfbench and uxdiff need
  it).  A plain checkout's `.git` is copied with the rest.
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

### Several checkouts at once

* **Each checkout has a work volume of its own**,
  `interdimux-dev-work-<arch>-<directory name>-<hash of its path>`, labelled
  with the path.  So runs from several checkouts -- agents in their own git
  worktrees, say -- go side by side; only a second run from the same checkout
  is refused.  `make clean` removes the images and this checkout's volumes;
  `make clean-volumes` removes the volumes whose checkout is gone, and only
  names those without a label (made by an older `dev/run.sh`, with one volume
  per architecture, which a checkout not yet updated still uses).
* **They share the image**, one tag per architecture.  A checkout whose
  `dev/` (but `dev/perf/`, which the image does not use), `rust/Cargo.*` and
  `.dockerignore` match the image's label runs it as it is, so worktrees of
  one branch never rebuild it for each other.  One whose `dev/` differs
  rebuilds it -- from the cache, in seconds -- and the next run from the
  other rebuilds it back.
* **Timing-sensitive runs take turns**: `test`, `smoke`, `ci`, `ci-sigpipe`,
  `bench`, `perfbench`, `uxdiff`, `msrv`, `check-macos`, `lint` and `image`,
  and any image build.  Each first takes an exclusive `flock` on a lock file
  -- by default `${XDG_RUNTIME_DIR:-/tmp}/interdimux-dev-<uid>.lock`, one per
  user, `LOCK=FILE` (`IMUX_LOCK`) for another -- and then waits while the
  container of any other such run is up (they carry the label `imux.turn`),
  saying which run it waits for and how long it waited.  The containers are
  what holds when the lock cannot: a run whose `docker` client was killed (a
  tool's timeout sends SIGKILL) leaves its container running and the lock
  free, and the next run still waits for that container; so does one that
  names another lock file, and so does a Mac, which has no `flock(1)`.
  `shell`, `run`, `watch` and `versions` take no turn unless `LOCK=FILE`
  names one (then they do, and others wait for them); `LOCK=none` waits for
  nothing, though a timing-sensitive command is still waited for by others.
  Two runs that name different lock files and start within the same second
  can still overlap.

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
| zoxide | `ZOXIDE_VERSION` | release binary in `/opt/zoxide/zoxide`, **off the PATH** (`IMUX_PERF_ZOXIDE` names it): only the A/B harness uses it; the suites, as on CI's runner, see no zoxide |
| zsh, dash, gawk (as `awk`), mawk, at, strace, procps, util-linux, perl, python3, fd-find (as `fdfind`, which the plugin uses when there is no `fd`), git, locales (C.UTF-8 and en_US.UTF-8), ncurses terminfo, entr, rsync, jq | noble | apt |

`make versions` prints all of them, and fails on anything missing or, for
each pinned one, at another version than its pin.

## The other architecture

`PLATFORM=linux/arm64 make ...` builds and runs the Apple Silicon image on an
amd64 machine (and `linux/amd64` the other way), through QEMU.  That is good for
proving the image builds and its tools run there.  It is not good for the
suites: emulation is several times slower, and many suites bound how long a
screen may take to settle.  Run those natively, on the Mac itself.

## What it does not cover

* **macOS's own userland.**  The plugin's macOS paths -- the ps and libproc
  process backends, BSD `at`/`atq` and `date -j`, `launchctl` for atrun, no
  `/proc`, `/private/var` -- run here only through the seams the suites
  already use (`INTERDIMUX_FORCE_PS`, `INTERDIMUX_REGISTRY_NO_PROC`,
  `INTERDIMUX_AT_DAEMON`, bash 3.2 from `/opt/bash-old`).  So CI runs them on
  real Macs instead: the `macos` job, on an Apple Silicon and an Intel runner,
  runs the Rust tests natively and `tests/smoke.sh`, which drives the plugin
  end to end on the macOS userland -- the list on every renderer and process
  backend, previews, the directory picker, scheduling through BSD `at`,
  `--doctor`, and the navigator in a real popup.  Its tmux is the pinned one,
  built as Homebrew builds it (utf8proc, jemalloc), with bash 5.3.20:
  `dev/install/macos.sh`, from the pins in `dev/versions.env`.  The suites
  themselves assume GNU tools, `/proc` and `strace`, and do not run on a Mac.
  `make smoke` runs the same smoke here, where it mostly proves the smoke.
* Real ssh/mosh remotes, network mounts, agent CLIs and a docker daemon for
  `test_title_apps`' container case (`INTERDIMUX_TEST_DOCKER=off`, as on CI).
* Profiling and debugging tools (perf, gdb, a debug tmux), and other tmux,
  fzf or base-image versions side by side.  None of these are in the image yet.

## Files

| | |
|---|---|
| `dev/versions.env` | every pin |
| `dev/checksums/*.sha256` | the sha256 of every artifact, all platforms (`make pin`) |
| `dev/install/*.sh` | the recipes, shared with CI; `lib.sh` fetches and verifies; `macos.sh` is CI's Mac toolchain |
| `dev/Dockerfile` | the image, one stage per component |
| `dev/run.sh` | the host side (POSIX sh), what `make` calls |
| `dev/entrypoint.sh`, `dev/cmd.sh` | inside: the root steps, then the commands |
| `dev/perf/` | the A/B harness, run from `/work` (not part of the image): `bench.sh` with `benchrun.c` (compiled per run), `uxdiff.sh` with its fixture, text and screen parts and `uxdiff-canon.pl` |
| `dev/lint-extra.sh` | actionlint, hadolint, lychee |
| `dev/pin.sh` | records the checksums |
| `Makefile`, `.dockerignore` | |
