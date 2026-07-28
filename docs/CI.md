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
3.7b the byte only survives when tmux is invoked **from inside tmux** (`$TMUX`
set). Called with `-L` from outside, tmux sanitises it to `_`. The plugin always
runs inside tmux, so this never bites in production — but a probe run from a
plain shell will tell you the opposite of the truth.

**Fix:** build tmux from source in CI. There is no apt route: no Ubuntu or
Debian release currently packages >= 3.6.

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

`ubuntu-latest`'s apt fzf is 0.44.1. `test_picker_ui` and `test_raw_mode` skip
below their version floors. Installing 0.74 was worth +22 assertions on its own.

**Fix:** install the fzf release tarball, not the distro package.

## 6. The Rust core was never built

Without `rust/target/release/imux` every suite runs against the bash fallback,
and `test_rust_parity.sh` — whose entire job is "these two renderers agree
byte for byte" — skips itself. The runner has Rust preinstalled; nothing was
using it.

**Fix:** `cargo build --release` and `cargo test --release`.

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

## What the developer's tmux does that no released tmux does

Worth recording, because it is why local runs and CI disagreed for so long.
`/usr/local/bin/tmux` on the development box is a local build, and it differs
from every released tmux tested (3.4 apt, 3.5a apt, 3.6 from source, 3.7b from
source, 3.7b Debian package) in two ways:

* `run-shell -t <target> "cmd"` **exports `TMUX_PANE`** to the child. No stock
  build does. `tests/test_list_format.sh` depends on this: without it the
  "current session" falls back to the most recently attached one and the MRU
  assertion gets `alpha charlie bravo` instead of `bravo alpha charlie`.
  Production is unaffected — the real key bindings pass `TMUX_PANE=#{pane_id}`
  explicitly rather than relying on the implicit export.
* A raw control byte in a `-F` format survives even when tmux is invoked from
  *outside* tmux. Stock builds sanitise it to `_`.

If a test passes locally and fails in CI, this is the first thing to suspect.
