# CI, and why it needs more than `apt-get install tmux fzf`

The workflow used to install tmux and fzf from apt and loop over `tests/*.sh`.
It failed on every push. This is what was actually wrong, measured in a
container replicating `ubuntu-latest` (= ubuntu-24.04) rather than reasoned
about — every number here came from a run.

Baseline, the workflow exactly as it was: **172 assertions passed, 13 failed,
and six suites died without producing a result line at all.**

After the workflow fixes below: **477 passed, 2 failed**, plus 80 Rust tests
that had never run. The last two needed changes outside the workflow — one in a
test that assumed the developer's tmux, one in a test whose `sort -n` fed a
`comm` that collates lexicographically — and with those, **522 passed, 0
failed**.

Then the first green-looking run on the *real* runner came back **441 passed, 2
failed**, which no container reproduced. Both failures had one cause, §10.

### Reading the totals

Several different numbers are correct at once, so it is worth pinning down.
The first three rows are the history this document records.  The rest are a
snapshot, measured at `6f29bfd` on the development box: every suite added
since reads higher, so re-measure rather than trust them.

The box has neither `INTERDIMUX_OLD_FZF_DIR` nor `INTERDIMUX_OLD_BASH_DIR`, so
there `tests/test_old_fzf.sh` skips (0) and `tests/test_bash_floor.sh` runs
only its dash and current-bash cases (14).  CI fetches and builds those
binaries (§5, §12), and with them the two suites count 10 and 43 — so each CI
leg reads **39 higher** than the same leg run locally.  The CI rows below are
the local measurement plus those 39, both suites measured against the binaries
the CI steps produce.  (CI has since added bash 4.4 and 5.0 and fzf 0.40.0
(§12), and with those the two suites count 15 and 67, so the difference is now
68.)

| where | shell | rust | printed |
|---|---|---|---|
| `tests/run_all.sh` locally, then | 443 | +80 | **523** |
| the workflow's "Shell tests" step, then | 443 | — | **443** |
| that step before §10 was fixed | 441 + 2 failed | — | **441** |
| `tests/run_all.sh` locally, at `6f29bfd` | 1251 | +131 | **1382** |
| `IMUX_RENDERER=bash tests/run_all.sh` locally | 1183 | — | **1183** |
| "Shell tests", `rust` leg | 1251 + 39 | — | **1290** |
| "Shell tests", `bash` leg (`IMUX_RENDERER=bash`) | 1183 + 39 | — | **1222** |

`run_all.sh` runs `cargo test` itself and folds those 131 into its own total; CI
passes `IMUX_SKIP_RUST=1` because Rust already ran as its own step. So a CI
total 131 lower than a local one (before the 39) is the *expected* reading, not
a coverage gap — every one of the 1251 shell assertions runs in both places.
The `bash` leg reads 68 lower again: `test_rust_parity.sh`, which compares the
two renderers itself, is skipped there (§11); every other suite counts the
same in both legs.

## 1. tmux 3.4 makes the picker empty — this is the big one

Rows are `IDENT \t CTX \t CMD \t SPEC`, but the *tmux* side of the pipe uses a
raw US byte (`\x1f`) to separate fields inside a `-F` format, because a session
name can legally contain almost anything else. tmux did not always pass that
byte through:

| tmux | `-F "x<US>y"` emits | `--list` rows |
|---|---|---|
| 3.4 (Ubuntu 24.04) | `x\037y` — four literal characters | **0** |
| 3.5a (Ubuntu 25.04, Debian 13) | `x\037y` | **0** |
| 3.6 | `x` `0x1f` `y` | 3 |
| 3.7b | `x` `0x1f` `y` | 3 |

With the delimiter gone every row parses as ONE field, `session_name` comes out
empty, the emit loop `continue`s on all of them, and `--list` prints nothing.
Nothing downstream can work: `test_list_format` reported `--list produced rows
to check (got 0, expected >= 8)` and five other suites died outright.

`bash -x` shows it from the other side. On 3.6+ bash prints the captured output
as `$'…\037…'` (ANSI-C quoting, i.e. real control bytes); on 3.4 as `'…\037…'`
(plain quotes, i.e. literal backslash-zero-three-seven).

One wrinkle worth knowing, because it makes casual probing misleading: even on
3.7b the byte only survives when the client counts as UTF-8 — invoked **from
inside tmux** (`$TMUX` set), or with a UTF-8 `LC_ALL`, `LC_CTYPE` or `LANG`.
Called with `-L` from a plain shell in the C locale, tmux sanitises it to `_`.
The plugin always runs inside tmux, so this never bites in production — but a
probe run from a plain shell can tell you the opposite of the truth.

**Fix:** build tmux from source in CI. The jobs run on `ubuntu-24.04`, whose
apt tmux is 3.4. Newer releases do package a new enough one — Ubuntu 26.04 has
3.6a, Debian 13's trixie-backports 3.6b — so on a 26.04 image the build could
become optional, as `ci.yml` notes where it names the image.

## 2. Ubuntu's `awk` is mawk, and mawk counts bytes

Several assertions measure a rendered row in *cells* with `awk '{print
length($0)}'`. gawk counts characters in a UTF-8 locale; **mawk counts bytes,
always** — and mawk is Ubuntu's default `awk`.

```
$ printf '─────\n' | gawk '{print length($0)}'   # 5
$ printf '─────\n' | mawk '{print length($0)}'   # 15
```

So `a very wide terminal is capped at 96 cells` reported `got 288` — 96 × 3.

**Fix:** install `gawk` and `update-alternatives --set awk /usr/bin/gawk`.

## 3. No locale

Runners do not reliably set one; the container reported `ANSI_X3.4-1968`. On its
own this changed almost nothing (172 → 171 passed), because the suites that care
already pin their own. It matters in combination with #2, and it is one line.

**Fix:** `LANG`/`LC_ALL` = `C.UTF-8` at the workflow level.

## 4. `at` is absent, so the schedule suites SKIP

They do not fail — they report `0 passed, 0 failed`, which in a total is
indistinguishable from coverage. Two suites, ~60 assertions, silently absent.

**Fix:** install `at` and start `atd`.

## 5. fzf 0.44 turns picker suites into skips

`ubuntu-24.04`'s apt fzf is 0.44.1. `test_picker_ui` and `test_raw_mode` skip
below their version floors. Installing 0.74 was worth +22 assertions on its own.

**Fix:** install the fzf release tarball, not the distro package.

The skip also hid that on that very fzf the navigator did not open at all: an
unconditional `resize` bind (an event from 0.46) made 0.44 refuse to start, and
on 0.46–0.52, which draw their whole interface on stderr, the navigator's
stderr log swallowed it and the popup stayed black. `tests/test_old_fzf.sh`
runs the navigator on real 0.40.0, 0.44.1 and 0.52.1 release binaries (0.40.0
is the README's floor, and the only release under test on the `fzf_ge 42`
false branch, which 0.41 is on too), which the workflow fetches into the
directory named by `INTERDIMUX_OLD_FZF_DIR`.  Without the variable it skips,
naming each version; with it, a version it names that is not there fails.

The fetch itself failed the first time it was written, and took the whole job
with it. fzf's release tags gained their `v` at 0.54.0 — `0.53.0` and older are
bare — so `releases/download/v0.44.1/…` is a 404. Piped into `tar`, the empty
download surfaced as gzip's `unexpected end of file`, the step exited 2, and
every step after it, the Rust build and both test steps included, never ran.
The step now picks the tag per version and downloads to a file first, so a
failed fetch fails as `curl`, naming the URL; and "Versions under test" runs
each old binary, so a missing one fails there rather than becoming a skip.

## 6. The Rust core was never built

Without `rust/target/release/imux` every suite runs against the bash fallback,
and `test_rust_parity.sh` — whose entire job is "these two renderers agree
byte for byte" — skips itself. The runner has Rust preinstalled; nothing was
using it.

**Fix:** `cargo build --release` and `cargo test --release`.

That fix had a cost nobody noticed, which is §11.

## 7. The test step stopped at the first failure

```yaml
for t in tests/test_*.sh; do bash "$t"; done
```

`run:` steps execute under `bash -e`, so this aborts at the first failing suite
and reports nothing about the other twenty — which is why the failure always
looked like one problem instead of six. `tests/run_all.sh` already runs every
suite, totals the assertions, and treats a suite that died without a `Results:`
line as a failure rather than as silence.

## 8. Only one locale exists, so a regression guard silently skipped

`tests/test_rust_parity.sh` guards a bug that shipped: the MRU sort ordered tied
timestamps by the user's collation, so the two renderers disagreed on any
machine that was not in the C locale. The guard works by comparing two locales
whose collation actually differs — and it probes for one rather than assuming,
skipping when there is none.

The runner image has exactly `C`, `C.utf8` and `POSIX`. So the guard skipped,
and six assertions — including the regression test for a bug that reached main —
quietly did not run. `locale-gen en_US.UTF-8` restores them: 31 assertions
become 37.

This is the same class as #4: a skip is not a pass, and a total is the worst
place to notice the difference.

## 9. shellcheck exits 1 on 52 warnings

31 × SC2155, 15 × SC2034, and six one-offs. Almost every one is an idiom this
codebase uses on purpose — the `export X="$(tmux …)"` test harnesses, the
deliberately unquoted RS split under `set -f`, `--"$HINT_BAR"="$REPLY"` as an
array element.

Almost. Three of the SC2034s were in the shipped script, and two of those were
genuinely dead: `REPLY_W`, set by `hint_r` and read by nobody since `hint_tiers`
stopped calling it, and `lo`, left in a `local` list when a min-scan became an
insertion sort. The lint was right and had been for two commits.

So the workflow lints **twice**, holding the plugin to the stricter bar:

```
scripts/ + interdimux.tmux   -e SC2191,SC2206
tests/                       -e SC2155,SC2034,SC2164,SC2010,SC2154
```

One invocation needs the union of those lists, and that union is exactly what
hid the dead variables behind the harnesses' deliberate SC2034s. Split, the
plugin is linted with SC2034 and SC2155 **on**.

Both invocations live in `tests/lint.sh`, which is all the shellcheck job runs.
It pins the version too: when the `shellcheck` on PATH is not 0.10.0 (the
image's apt one is 0.9.0 on 24.04 and 0.11.0 on 26.04), it fetches the 0.10.0
release into `~/.cache/shellcheck/`, checksummed, and uses that.  So an image
bump cannot fail the lint with new SC codes, and the lint a push will get can
be run before the push — three lint-fix commits in round 2 were made after
pushing, because the commands lived only in the workflow.

## 10. GitHub runs `run:` steps with SIGPIPE ignored

The one failure mode no container reproduced, because no container has it.
GitHub starts a `run:` step with SIGPIPE set to `SIG_IGN`, and an ignored
disposition survives `execve` — so every process the suite spawns inherits it.
Bash cannot undo it: a signal ignored at shell entry is a *hard* ignore that
`trap` cannot reach.

```
trap - PIPE               -> PIPESTATUS=1      # bash cannot reset it
perl $SIG{PIPE}=DEFAULT   -> PIPESTATUS=141
env --default-signal=PIPE -> PIPESTATUS=141
```

Reproduce it anywhere: `( trap '' PIPE; bash tests/run_all.sh )`. In the runner
replica that yields **441 passed, 2 failed** — the real runner's numbers, to the
assertion.

It broke two things.

**`test_pipefail.sh` asserts that a producer dies of SIGPIPE**, and nothing can
die of a signal that is ignored, so `PIPESTATUS[0]` is 0 rather than 141. The
64 KB pipe-buffer theory in that test's own comment was wrong and had sent the
investigation the wrong way: `--dirs-list` emits 36,070 bytes against that
fixture (47,330 at its widest — `DIRS_PATH_W` clamps at 64), a 189 KB fixture
still returns 0 when SIGPIPE is ignored, and a 178-byte one still returns 141
when it is not. Size never controlled the outcome in either direction; duration
and unbuffered per-row `printf` do. The probe now runs under
`env --default-signal=PIPE` (with a `perl` fallback for BSD `env`), so it tests
the mechanism it names on any host.

**`--send-at` printed 49,917 lines of `printf: write error: Broken pipe`.** This
one was a real defect, and only this environment could surface it. `at` parses
its time from argv and exits *before* reading stdin, so a bad spec closes the
pipe under `sched_job_body`. With SIGPIPE at its default the writer dies
silently; with SIGPIPE ignored it does not die, and bash reports every failed
write. Those go to the script's own stderr — the `2>&1` on that line binds to
`at` — and they arrive *while the pipeline is still running*, ahead of the
`printf '%s\n' "$_out" >&2` that emits at's real message afterwards. The caller
shows the first non-`interdimux:` line, so the schedule dialog read

```
✗ /home/runner/work/interdimux/interdimux/scripts/interdimux.sh: line…
```

instead of `✗ syntax error. Last token seen: n`. Fixed by silencing the writer,
which is pure `printf` and has no other stderr.

**How much this can bite a user: less than it looks, but not zero.** tmux resets
SIGPIPE to its default for panes *and* for `run-shell` children (measured:
`SigIgn 0x300000`, `PIPESTATUS=141`) even though the server itself ignores it —
so no in-tmux path reaches this. It needs the CLI driven from a SIGPIPE-ignoring
parent: a CI step, or `--send-at` called from a systemd unit, where
`IgnoreSIGPIPE` defaults to true.

**Do not "fix" a future SIGPIPE failure by wrapping the whole suite** in
`env --default-signal=PIPE`. It works, and it would have hidden the second bug
above. CI is the only place this project ever runs with SIGPIPE ignored, and
that is coverage worth keeping — `ci.yml` says so at the "Shell tests" step.

## 11. Building the core hid the renderer most installs run

§6 built `rust/target/release/imux` so the parity suite would run.  But the
script prefers a built binary everywhere, so from then on every suite that did
not pin a renderer ran the Rust core — and the bash renderer, which is what
every install WITHOUT cargo runs (nothing built `rust/` for a TPM install until
`interdimux.tmux` learned to build it when cargo is present, and without cargo
it still cannot), was exercised only in the handful of places a suite forced it
with `INTERDIMUX_USE_RUST=off`.

**Fix:** the `tests` job is a matrix over `renderer: [rust, bash]`.  The `bash`
leg runs `IMUX_RENDERER=bash tests/run_all.sh`, which exports
`INTERDIMUX_USE_RUST=off`; the private tmux servers the suites start inherit it
into their global environment, so every pane, popup and `run-shell` inside them
renders with bash too.  It skips `test_rust_parity.sh` (it compares both
renderers itself) and the Rust tests (renderer-independent), but still builds
the binary: the suites that compare renderers, and `--doctor`'s helper checks,
pin it on.  The job's check names are now "tests (rust renderer)" and "tests
(bash renderer)" — anything that required the old "tests" check needs the new
names.

A canary copy of the script that logged every Rust render, run through the
whole suite under `IMUX_RENDERER=bash`, confirmed the leg does what it says:
the only Rust renders left were the cases that pin it on to compare.  The first
bash-leg run failed 15 assertions in six suites:

* **one real defect.** In raw mode, ^r, ^/ and a resize threw the cursor to the
  first row: a bug already fixed, but, it turned out, only for the core.  Every
  navigator reload was a plain `reload`, which shows rows as they stream in;
  the core's rows arrive in one write, bash's row by row, and fzf keeps the
  cursor by row NUMBER.  Fixed with `reload-sync`.
* **suites that assumed the core**: two that `unset` the variable after their
  own renderer loop (silently flipping the rest of the suite back to Rust),
  `--doctor`'s suites reading its "rust helper disabled" warning as a problem,
  `INTERDIMUX_BIN` cases that never ran the helper at all, and a count of the
  popup's `INTERDIMUX_*` variables that counted the override.
* the two `‹main›` scope-highlight failures every non-`main` checkout had.

The leg also needs the suites that compare the renderers to pin BOTH sides.
`test_squeeze.sh`'s parity sweep pinned only its bash pass, so under
`IMUX_RENDERER=bash` its "rust" pass inherited `INTERDIMUX_USE_RUST=off` and
the sweep compared bash with bash — a check that could not fail, counted as a
pass.  It now pins the core on, and runs it through a stand-in that logs each
run, so the sweep fails unless the core really drew one side of every
comparison (a refused or failing core falls back to bash just as quietly).

`tests/test_corpus_parity.sh` closes the other half of the gap without a
server: `INTERDIMUX_DUMP_IN=<file>` feeds a recorded dump to the bash renderer
at the same fetch site tmux would, so every `rust/tests/corpus/*.dump` is
rendered by both, and the bash output must equal the blessed golden.

## 12. The bash floor was tested, but nowhere ran the test

The script's floor is bash 4.3, and 3.2 (macOS's `/bin/bash`) and 4.2 (RHEL
7's) must be refused in one line rather than dying somewhere inside.
`tests/test_bash_floor.sh` checks both, but only with real old binaries in
`INTERDIMUX_OLD_BASH_DIR` — and nothing set it, so on every run its old-bash
cases printed "skipped" and the only bash under test was the runner's 5.2.

5.2 is the version that hides the difference that mattered.  Up to 5.1,
`[[ -v "assoc[$key]" ]]` expands the subscript a second time, so on 4.3–5.1 a
`$` in a session name emptied the list (`work: unbound variable` for a
session named `$work`, under `set -u`), and a `$(…)` in one ran; every suite passed on 5.2.  The CI-built
4.3.30 and 5.1.16 both reproduce it, and 5.2 does not.  (The script now tests
keys with `${assoc[$key]+x}`, which expands once on every version, and the
suite's `$`-name cases hold it there.)

**Fix:** the tests job builds bash 3.2.57, 4.2.53, 4.3.30, 4.4.18, 5.0 and
5.1.16 (4.4 is RHEL 8's, 5.0 Ubuntu 20.04's, 5.1 Ubuntu 22.04's) from the GNU
tarballs, caches them by the version list and the image, and exports
`INTERDIMUX_OLD_BASH_DIR`, so `run_all.sh` runs the suite's real cases in both
legs.  Two things the build needed, both found by running it:

* `-std=gnu89` and the `-Wno-implicit-*`, `-Wno-int-conversion` and
  `-Wno-incompatible-pointer-types` flags, in `CFLAGS` and in
  `CFLAGS_FOR_BUILD`: these K&R-era sources lean on exactly what gcc 14
  turned from warnings into errors (24.04's gcc 13 still only warns).
  `CFLAGS_FOR_BUILD` is what the build-time helpers (`mkbuiltins`,
  `mksignames`, …) are compiled with, and 3.2's and 4.2's configure set it
  to a bare `-g` instead of inheriting `CFLAGS`.  gcc 15, 26.04's, compiles
  as C23 by default, where `int f();` declares a function of NO arguments,
  so without it `mkbuiltins.c` stops at "number of arguments doesn't match
  prototype".  Reproduced by giving gcc 13 that default
  (`CC="gcc -std=gnu2x"`): 3.2.57 and 4.2.53 failed with `CFLAGS` alone, and
  all six versions built with both;
* NO `-O2` — which also means CFLAGS must be given, since configure's default
  is `-g -O2`.  With it, 3.2's `configure` spun in its `mktime` probe (a
  minute of CPU before it was killed): the probe's loop,
  `for (time_t_max = 1; 0 < time_t_max; time_t_max *= 2)`, relies on signed
  overflow wrapping, which the optimiser may assume never happens.

A cold cache costs about two and a half minutes for the first four (measured
on 4 cores), and about four for all six (the step as written, run on a
4-core Ubuntu 24.04 box that was busy with other work).  "Versions under
test" runs each one, so a build that went missing fails that step instead of
turning the suite back into skips.

That step only knew the workflow's own list, though, and for a while that list
was 3.2, 4.2, 4.3 and 5.1 while the suite also ran 4.4 and 5.0 — the rest of
the range that expands a subscript twice — whenever they were there.  They
never were: twelve written assertions skipped on every run while the totals
read green.  The suites' lists are now the authority.  With
`INTERDIMUX_OLD_BASH_DIR` set, a version `tests/test_bash_floor.sh` names that
is not there FAILS, by name (`tests/test_old_fzf.sh` does the same with
`INTERDIMUX_OLD_FZF_DIR`), so the workflow's list cannot fall behind unseen.
Each bash goes under its major.minor cut from the tarball's name: `${v%.*}`,
as the step had it, would have put 5.0 in `5/`.

Both jobs name their image, `ubuntu-24.04`, rather than `ubuntu-latest`, which
moves to 26.04 from 2026-10-19 (actions/runner-images#14748), and the tmux and
bash caches are keyed on it (`matrix.os`).  A warm cache would not have shown
the gcc 15 failure above: a bash built on 24.04 runs unchanged on 26.04, and
actions/cache does not version an entry by image.  But GitHub evicts a cache
nobody restored for seven days, and pushes here are often weeks apart, so the
first push after the move would have built cold and gone red for a reason
that has nothing to do with the code.  A move is now a one-line change to the
`os` list, which rebuilds everything on the new image; adding it as a second
entry first tries it without giving up the old one.

## 13. A skip still read as a pass

§4, §5, §8 and §12 are one failure, found four times: a suite that cannot run
something skips it, and the skip disappears into a total.  `run_all.sh` gave
a suite that skipped itself whole ("Results: 0 passed, 0 failed") the same
green tick as one that passed, and a suite that skipped some of its cases left
no trace at all.  Each was found by reading a log line by line.

**Fix:** `run_all.sh` reports a whole skip as SKIPPED and a partial one next
to the suite's passes, each with the skip lines the suite printed, and names
every skipping suite under the total.  `IMUX_STRICT=1`, which the "Shell
tests" step sets, fails the run on any of them once every suite has run.
`tests/test_run_all.sh` holds `run_all.sh` to that.

For a strict run to pass, the job provides everything the suites ask for.
`zsh` was the one thing missing: `test_foreground_job.sh`'s nested zsh and
`test_raw_fallback.sh`'s `--with-shell='zsh -c'` skipped on every run.  The one
case CI deliberately does not run, `test_title_apps.sh`'s real container shell
(it needs `ubuntu:24.04` already pulled), is switched off with
`INTERDIMUX_TEST_DOCKER=off`, which that suite reports as a choice rather than
a skip.  A skip line is one a suite prints starting `  (` or `  - ` and saying
"skipped"; a new skip path has to say so to be counted.  Eleven did not at
first: ten suites that run half their cases without the Rust core said only
"(the Rust core is not built: only the bash renderer is checked)" or the like,
and `test_bash_floor.sh` "(no bash from 4.3 to 5.1 to run these on)".  So
`tests/test_run_all.sh` also reads every suite's source for a note of that
shape on stdout that does not say "skipped", and fails on one.

## Why a dev shell and CI disagree

Worth recording, because it is why local runs and CI disagreed for so long, and
because this section used to blame a "locally patched" `/usr/local/bin/tmux`.
That binary is the stock 3.7b source build, byte for byte. Neither difference
comes from the build; both come from where the server and the client start:

* **`TMUX_PANE` is whatever the starting shell had.** A server started from a
  shell inside tmux copies that shell's `TMUX_PANE` into its global
  environment, and `run-shell` and `display-popup` children get the global
  environment, never the target's pane: only a pane's own process is given its
  id (`environ_for_session` in environ.c; spawn.c sets `TMUX_PANE`, nothing
  else does). Measured on stock 3.5a, 3.6a and 3.7b: a server started with
  `TMUX_PANE=%7` hands every `run-shell -t <target>` child `%7`, one started
  without hands it nothing. So a suite run from a dev pane resolves "the
  current pane" against the developer's pane id — on the private server, an
  unrelated pane or none — while in CI it is unset.
  `tests/test_list_format.sh` passes the pane explicitly, as the real key
  bindings do (`TMUX_PANE=#{pane_id}`); a suite that leaves it to the
  environment can pass in one place and fail in the other.
* **A raw control byte in `-F` output survives only in a UTF-8 client.** tmux
  counts the client as UTF-8 when `TMUX` is set, or when the first of
  `LC_ALL`, `LC_CTYPE` and `LANG` that is set names UTF-8 (tmux.c); otherwise
  the byte comes out as `_` (§1). A dev shell has `TMUX`, and CI sets
  `LC_ALL=C.UTF-8` (§3), so both keep it — but a probe from a plain shell in
  the C locale does not.

If a test passes locally and fails in CI, these are the first things to suspect.
