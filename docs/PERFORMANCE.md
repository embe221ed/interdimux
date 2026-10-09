# interdimux — performance plan (popup-spawn latency)

Goal: make `prefix+f` feel instant, so interdimux is viable as a *quick* window/pane/session
switcher. Today a cold popup can take several seconds on a busy host with many
windows/panes.

This plan is grounded in **measurements taken in this repo** (see Appendix) and a research
pass over `sesh` (the Go rewrite of the bash tool `t`), `tmux-sessionx`, `tmux-fzf`,
`tmux-sessionizer`, and the fzf man page + 0.36–0.74 changelog.

Effort: **S** ≲ 30 lines · **M** = a focused session · **L** = a real refactor.
Plugin floor is fzf ≥ 0.40, tmux ≥ 3.6 (hard: older tmux rewrites the US byte the rows are
split on — see the README); version gates are noted where a fix needs one.

---

## TL;DR — where the seconds actually go

The latency is **not** tmux and **not** `ps`. Those stay cheap even at 214 panes
(`ps -eo` ≈ 31 ms, the three bulk tmux queries ≈ 16 ms combined). The seconds are burned in
**needless process forks in bash**, and they blow up on a loaded box because every fork
competes for the CPU:

| Fork source | Where | Cost measured | Runs on |
|---|---|---|---|
| **~3–4 subshell forks per row** (`resolve_command`, `full_command`, `format_command`, `get_git_branch`, `wc -l`) | `gather_targets` (`scripts/interdimux.sh:856`) | `--list` = **1.1–2.1 s** at 79–154 windows | every list build + every reload |
| **~30 subshell forks** (`set_palette`) | `scripts/interdimux.sh:148` | a 32-fork storm = **~1 s** under load | **every** script invocation |
| **`fzf --version`** (fork+exec of the fzf binary) | preflight `scripts/interdimux.sh:34` | **113 ms** under load | **every** script invocation |
| **`tmux -V`** | preflight `scripts/interdimux.sh:56` | 24 ms | every invocation |
| **27× `tmux show-option`** | `get_opt` `scripts/interdimux.sh:69` | ~100 ms idle, seconds under load | cold launch only |

Two facts make this worse than it looks:

1. **The whole ~2270-line script is re-parsed and re-executed from the top on every fzf
   callback** — every `--preview` (each cursor move), every `--header-for` (each cursor
   move, via a *synchronous* `focus` bind), every `--list` reload, every `--action`. So the
   per-invocation fixed cost (`fzf --version` + `set_palette`'s ~30 forks ≈ **~1.1 s under
   load**, ~90 ms idle) is paid *per keystroke that moves the cursor*. That is the
   scroll-lag.
2. **The launch path pays the full startup twice**: `prefix+f` → `run-shell` spawns
   `bash … --launch switch` (full startup) → `exec display-popup` → popup runs `bash …`
   (full startup again) → `gather_targets` → fzf. Cold, under load, that is roughly
   `~1.5 s (launcher) + ~1.5 s (navigator) + ~1–2 s (gather)` ≈ **4+ seconds**.

**The fix is to delete forks, not to cache tmux.** Every competitor that feels instant does
the same thing sesh's Go rewrite did: one bulk query, then in-process work with *no
fork-per-item*. interdimux already does the bulk tmux queries right — it just spends the
savings back on subshell forks per row and per keystroke.

---

## Tier 0 — fork elimination (do these first; ~90% of the win, no version gate)

> ✅ **Done** (branch `perf/tier-0-fork-elimination`). Measured on a single `--list` at
> 85 rows (44 windows / 64 panes): **process spawns dropped from 494 to 73** — `clone`
> (subshell forks) 453 → 56, `execve` 41 → 17. `--list` output is **byte-for-byte identical
> to `main`** and all four `tests/*.sh` pass. The residual forks are all *per-gather* (`ps`,
> the three bulk tmux queries, the MRU `sort`) — verified zero per-row subshells remain.

These are pure micro-optimizations: no behavior change, no version gate, individually
testable against `tests/`. The REPLY-return pattern is **already established** in this code
(`detect_project_type:242`, `age_of:718`) — extend it to the hot path.

### 0.1 — Kill the per-row subshell forks in `gather_targets`  ·  **S/M** · biggest list-build win

`gather_targets` forks a subshell for every window and every pane, up to 4 times per row:

```
543:    fcmd=$(full_command "$pid")          # nested inside resolve_command
996/1038: raw_cmd=$(resolve_command …)       # 1 fork  (+ the nested full_command fork)
997/1039: cmd_formatted=$(format_command …)  # 1 fork
842:      gbranch=$(get_git_branch "$path")   # 1 fork  (forks even on a cache hit!)
955/1007: win_count=$(printf … | wc -l)       # fork + pipe per session / multi-pane window
```

At 154 windows + 214 panes that is **~1,200+ forks** — the entire 1–2 s list build. Turning
off `SHOW_FULL_COMMAND` alone (which skips `resolve_command`/`full_command`) cut the measured
build by ~25–30%, confirming the attribution.

**How:** convert `full_command`, `resolve_command`, `format_command`, and `get_git_branch`
to set a global (`REPLY`, or a dedicated var) instead of `printf`-ing, exactly like
`detect_project_type` does. Then the 6 call sites become `format_command "$x"; cmd=$REPLY`
with **zero** subshells. Replace the two `$(printf … | wc -l)` counts with a pure-bash
newline count:

```bash
# no fork, no pipe:
nl="${session_windows//[!$'\n']/}"; win_count=$(( ${#nl} + 1 ))
```

**Blast radius:** 6 call sites, all inside the gather path (`swap` also calls
`gather_targets`, so it inherits the win for free). No public interface changes.
**Impact:** list build (and every reload) drops by roughly half or more; larger the more
windows/panes you have. **Risk:** low — covered by `tests/test_list_format.sh`.

### 0.2 — Make `set_palette` fork-free  ·  **S** · helps *every* invocation

`set_palette` (`scripts/interdimux.sh:148`) builds ~16 colour escapes, each via
`VAR=$(esc …)`, and `esc`/`escb` internally do `s=$(sgr_of …)` — ~30 subshell forks that run
on **every** launch, list, preview, header, and scope-prompt call. Measured: a 32-fork storm
= ~1 s under load.

**How:** make `sgr_of` set `REPLY` (it already `printf`s a single value), and have
`esc`/`escb`/`tmux_color` assign into named-reference outputs instead of being called in
`$(…)`. `set_palette` then assigns 19 variables with no subshell at all. Pure string work —
no external commands are involved, so this is a mechanical rewrite.
**Impact:** removes ~30 forks (~1 s under load / ~27 ms idle) from **every** invocation,
including each cursor move. **Risk:** low.

### 0.3 — Forward `FZF_MINOR` + `TMUX_VNUM` via env (IDEAS #25)  ·  **S**

Every invocation re-runs `fzf --version` (**113 ms** under load — a fork+exec of the fzf
binary!) and `tmux -V` (24 ms) in preflight (`:34`, `:56`) just to re-derive two integers the
launcher already computed. Add `FZF_MINOR` and `TMUX_VNUM` to `env_fwd_vars`
(`scripts/interdimux.sh:1926`); in preflight, skip the version probes when those env vars are
already set and numeric.
**Impact:** ~140 ms saved per callback under load (preview/header/reload all benefit).
**Risk:** trivial. **Note:** the launcher still probes once (correct — it is the source of
truth), children read env.

> **Tier-0 combined expectation:** the per-keystroke fixed cost drops from ~1.1 s to a few
> tens of ms under load, and the list build roughly halves. On an idle box the popup should
> feel instant; on a loaded box it should feel responsive instead of laggy — *without any
> structural change or version gate.*

---

## Tier 1 — cheap launch & cheap callbacks (structural, low risk)

> ✅ **Done — config-resolution forks eliminated** (branch `perf/tier1-config-forks`). A
> re-profile after Tier 0 + 2 found the dominant remaining cost was config resolution: all 27
> options were read as `VAR=$(get_opt …)`, and that `$(…)` forked a subshell **even when the
> value came from an env var**. Fixes shipped: (a) `get_opt` now sets its target via a
> nameref — no subshell — resolving env → a **single** `tmux display-message` dump of every
> `@interdimux-*` option (format expansion, raw values, split on `US`) → default; (b)
> `SCRIPT_PATH` is built by param-expansion instead of `dirname`/`basename`/`cd&&pwd`
> subshells; (c) `NOW_EPOCH` uses `printf '%(%s)T'` instead of `$(date)`. **Measured:** warm
> fixed overhead `clone` **35 → 2**; cold `--scope-prompt` `clone` **95 → 11** / `execve`
> **34 → 5** (27 `tmux` reads → 1); warm `--list` `clone` **46 → 13**. `--list` byte-identical
> to `main` (warm *and* cold), the real navigator verified live, `tests/*.sh` pass.
>
> Still open below: **1.1** (early-dispatch) is now a minor cleanup; **1.3** (drop the
> launcher bash) remains the biggest structural first-paint win.

### 1.1 — Early-dispatch the callback modes  ·  **M**

> ✅ **Done another way** ([Tier 11](#tier-11--the-layout-each-mode-parses-only-what-it-runs-2026-10)):
> the setup stays shared, and the file is laid out so each mode parses only
> what it runs -- `--list` and the navigator's first list from a file of
> their own, each callback ahead of the code it never runs, and the modes the
> navigator never runs in a file it never reads.

Today the script runs all of preflight + config + `set_palette` + `build_fzf_theme` (lines
1–218) **before** it looks at `$1`, so a `--scope-prompt` (which needs nothing) or a
`--header-for` (which needs one colour) pays the entire startup. sesh's lesson: *a callback
should do only that callback's work.* tmux-sessionx's lesson: precompute once, don't rebuild.

**How:** branch on `$1` near the top and run only the setup each mode needs:
`--scope-prompt` → nothing; `--header-for` → just `ACCENT_ESC`; `--preview` → palette + tmux;
`--list` → the full gather setup; `--launch`/`--dashboard-launch` → config + env-forward
only (they never draw rows, so they need **no** palette or fzf theme). This also shrinks the
launcher's own cost (it currently builds a palette and fzf theme it never uses before
`exec`-ing the popup).
**Impact:** cheap callbacks become near-instant; the launcher stops doing ~30 palette forks
+ theme build. **Risk:** medium — reorders top-level flow; keep the preflight *guards*
(fzf/tmux presence, version floor) before any mode that spawns fzf.

### 1.2 — One `tmux show-options -g` dump instead of 27 reads  ·  **S**

`get_opt` fires a separate `tmux show-option -gqv` per option — 27 tmux round-trips on cold
launch (`~100 ms` idle, seconds under load). Dump all globals once and parse:

```bash
declare -A OPTS=()
while IFS=' ' read -r k v; do OPTS[$k]=$v; done \
  < <(tmux show-options -g 2>/dev/null; tmux show-options -gq 2>/dev/null | grep '^@interdimux-')
# get_opt: env override → ${OPTS[$name]} → default   (no fork)
```

Only the launcher pays config cost (children get everything via env), so this is a pure
first-paint win. **Risk:** low; watch quoting of values that contain spaces.

### 1.3 — Bake config into the keybinding at plugin-load, drop the launcher bash  ·  **M/L**

The single biggest first-paint lever: **eliminate the first of the two bash startups.**
`tmux-sessionx` precomputes its fzf args **once** at plugin-load and stores them in a tmux
option via `declare -p`, so the hot path only `eval`s them — zero config round-trips per
open. Apply the same idea: have `interdimux.tmux` resolve config + build the
env-forward flags at plugin-load, and bind `prefix+f` **directly** to
`display-popup … -e … -E "bash script"` (skipping `--launch` and its whole bash process).
**Impact:** removes ~1.5 s (under load) of launcher startup from every cold open. **Risk:**
medium — runtime `@interdimux-*` changes need a plugin reload to take effect (document it, or
add a lightweight `@interdimux-reload` binding); destructive-mode border recolouring still
needs the tiny per-mode wrapper. Consider this **after** Tier 0, since Tier 0 already makes
the launcher bash cheap.

---

## Tier 2 — kill the per-keystroke header subprocess  ·  fzf ≥ 0.63 (you run 0.72)

The fzf man page is explicit: **actions bound to `focus` run synchronously and "can make the
interface sluggish … every cursor movement will be noticeably affected by its execution
time."** The navigator's `focus:transform-header(bash '$SCRIPT_PATH' --header-for {-1})`
(`scripts/interdimux.sh:2190`) forks a fresh bash **and blocks the UI** on every cursor move.
Measured `--header-for` under load: **435 ms – 1.1 s** *per move*.

Two ways out — **2b was chosen** (it keeps the per-type hints; a static footer would flatten
them into one bar and show every key for every row type):

- **2a (recommended, and it's IDEAS #4) — static footer, no subprocess.** Move the key hints
  to a static `--footer` (fzf ≥ 0.63) or a plain literal `--header` set once. The per-row
  hint variation is a nice-to-have; a fixed footer with all keys is arguably *better* UX
  (hints stop jumping as focus moves) and removes the entire per-keystroke fork. **Effort S.**
- **2b — keep dynamic per-type hints, but async.** Swap `focus:transform-header` →
  `focus:bg-transform-header` (fzf ≥ 0.63). It runs the command in the background and applies
  the result when ready, so cursor movement never blocks; pair with `bg-cancel` to coalesce
  rapid moves. Still one process per focus, but off the critical path (and Tier 0.2/0.3 make
  that process cheap). **Effort S.**

Prefer `change-header(LITERAL)` over `transform-header(cmd)` anywhere the value is already
known — a literal spawns **no** subprocess.

**Impact:** this is the change that makes *scrolling* feel instant. **Risk:** low.

> ✅ **Done** (2b). `focus:transform-header` → `focus:bg-cancel+bg-transform-header` on
> fzf ≥ 0.63 (synchronous fallback retained below the gate). Verified live by driving arrow
> keys through a real fzf in a tmux pane: the header renders the correct per-type hints
> (session → `detach`, window → `swap`, pane → `zoom`/`send`) and updates asynchronously
> without blocking navigation. `bg-cancel` coalesces rapid scrolling. `tests/*.sh` pass.

---

## Tier 3 — two-phase async enrichment (the flagship)  ·  fzf ≥ 0.66 (`--listen`)

Even after Tier 0, the git-branch + full-command columns are the most expensive part of the
list build. `tmux-sessionx` solves this exact problem with fzf's `--listen`: **paint a cheap
list instantly, then fill in the expensive columns in the background.**

**How:**
1. First paint emits the bare tree (marker, tree glyphs, name, path, spec) — no git branch,
   no `ps`-based full-command resolution. fzf renders it immediately (it streams stdin
   asynchronously; do **not** use `--sync` or `--tac`, which force full buffering before
   first paint).
2. Open fzf with `--listen=/path.sock` (Unix socket, `$FZF_SOCK`, fzf ≥ 0.66).
3. A backgrounded `&` job computes git branch + full command (one `ps` snapshot, the pure-bash
   `.git/HEAD` reader already in the code) and pushes the enriched rows into the *live* fzf:
   `curl -s --unix-socket "$FZF_SOCK" -d "reload-sync(cat $tmp; rm -f $tmp)" http://x`.
   `reload-sync` swaps the list **without disturbing the user's query or cursor**.

**Impact:** first paint becomes effectively constant-time regardless of session/window/pane
count. **Effort L.** **Risk:** medium (background job lifecycle, socket cleanup on abort,
keep POST bodies small — fzf ≤ 0.73.0 had an O(n²) body-accumulation stall). With Tier 0
done, synchronous enrichment may already be fast enough that this is optional polish rather
than required — measure after Tier 0 before committing to it.

> ❌ **Rejected after Tier 5.** The whole premise was deferring the `ps` +
> full-command enrichment, but the `/proc` resolver (Tier 5.3) removes that cost
> *synchronously* for a fraction of the machinery — and the git-branch column was
> measured to cost essentially nothing (`SHOW_GIT_BRANCH=off` came out at 231 ms
> against a 220 ms reference — no change). There is little left to defer. Facts
> worth keeping if it is ever revisited: the O(n²) POST stall is **fixed in fzf
> 0.74**, `reload-sync` preserves query/cursor/match-count exactly, and
> `/dev/tcp` + `FZF_API_KEY` is a zero-dependency authenticated transport.

---

## Tier 4 — optional: stale-while-revalidate list cache  ·  **M**

sesh added an opt-in cache (`sessions.gob`, 5 s TTL, serve-stale + refresh in a background
goroutine, refresh again after every `connect`) as its headline perf fix. interdimux could
mirror it: write the assembled list to a tmpfile, serve it instantly on the next open, and
recompute in the background.

**Caveat — deprioritize this.** The competitor survey found list-caching **low-value** for
fzf tools: `tmux list-sessions` is a sub-millisecond local-socket call, and none of
tmux-sessionx / tmux-fzf / `t` cache the list. interdimux's cost was never the tmux queries —
it was the forks, which Tier 0 removes. Cache only if profiling *after* Tier 0 still shows the
gather itself (not forks) as the bottleneck. If you do, key freshness on a cheap tmux
"generation" token (e.g. `#{session_activity}` maxima) rather than a blind TTL.

> ❌ **Rejected after Tier 5.** Reading a cache is 1–2 ms against a gather that is
> now ~90 ms to first row, so the ceiling is imperceptible — while the cost lands
> on the picker's most reflexive interaction (open, Enter to hop back) as a
> `switch-client` to a session that no longer exists. The proposed freshness token
> is also unsound: `#{session_activity}` maxima do **not** change on a window
> rename, a pane split, or a new window in an idle session.

---

## What the research confirmed

- **sesh (Go rewrite of bash `t`):** the entire point of the rewrite was to move the hot path
  out of *fork-per-tmux-command bash* into one process that batches syscalls. One bulk
  `list-sessions -F` with ~21 packed fields; **MRU ordering comes free** from
  `#{session_last_attached}` in that same call; each preview does a **single-entry** lookup
  (capture-pane *or* one `ls`), never a re-list. Caching is opt-in, 5 s, stale-while-revalidate.
  Startup commands use `send-keys` (they tried baking the command into `new-session`'s initial
  shell-command in v2.26.0 and **reverted** in v2.26.2 — send-keys, with a shell-ready guard,
  is the robust mechanism; relevant to IDEAS #13).
- **fzf:** streaming first paint is real (no `--sync`/`--tac`); `focus` binds are synchronous
  (the scroll-lag culprit); `bg-transform-*` (0.63) moves them off the critical path;
  `--listen` (0.66 Unix socket) lets a warm helper answer callbacks; `change-header(LITERAL)`
  spawns nothing; preview is already async + partial-render, so it is **not** the stall —
  the header bind is.
- **tmux-sessionx / tmux-fzf / t:** precompute fzf args at plugin-load into a tmux option
  (`declare -p`) so the hot path just `eval`s them; use `reload`/`change-prompt` to switch
  data sources in the *live* fzf instead of relaunching; push filtering into tmux
  (`-f '#{!=:…}'`) instead of `grep`; do MRU sort in the pipeline + `--no-sort`; two-phase
  git enrichment over `--listen` + `reload-sync`.

---

## Tier 5 — what landed after re-profiling (branch `perf/tier2-first-paint`)

A second measured pass, after Tiers 0/1/2b were in. Every item below is
byte-compared against the previous `--list` on a 142-row bench with a
ref-vs-ref control, and covered by tests.

**Measured, 142 rows, quiet box (132 host processes), 13 reps interleaved:**

| | before | after |
|---|---|---|
| `--list` time to first row | 146 ms | **78 ms** (−47%) |
| `--list` total | 237 ms | 195 ms |
| header callback, per cursor move | 20 ms | **1 ms** |
| keypress → navigator bash | 45 ms | **12 ms** |

First row is the metric that matters — fzf paints rows as they stream in. The
two launch legs compose: `prefix+f` now reaches a painting fzf in roughly the
time the old code took just to *start* the launcher.

Process accounting for one warm `--list`, before → after: **5 tmux execs → 1**,
plus `ps` gone entirely.

1. **The warm path did not exist for the default config.** `get_opt` tests
   `[ -n "$env_val" ]`, so a forwarded-but-*empty* option was indistinguishable
   from an unset one. `@interdimux-fzf-opts` and `@interdimux-project-markers`
   both default to `""`, so every popup callback re-ran the tmux option dump —
   Tier 1's warm path only ever worked for users who happened to set both.
   Fixed with an `INTERDIMUX_OPTS_PRIMED=1` sentinel (2 clone + 2 execve → 0 + 1
   per callback). `tests/test_config_fwd.sh` now enforces the contract the
   sentinel depends on: a `get_opt`/`ENV_FWD` desync used to cost one wasted
   fork, but with the sentinel it would *silently ignore the user's option*.

2. **The two trivial per-keystroke callbacks are answered inline.** The focus
   header and the ctrl-] scope prompt only ever pick between strings the
   navigator already knows, so they are now `case` snippets in the fzf bind
   (with `--with-shell='sh -c'`, fzf ≥ 0.51) instead of a script re-exec.
   Three sharp edges, all covered by `tests/test_header_hints.sh`:
   with an **empty result list** fzf expands `{-1}` to *zero words*, so a bare
   `case {-1} in` becomes `case in` — a syntax error and a blank header (the
   `_{-1}` sentinel fixes it); the `action:rest-of-string` form avoids `)` in a
   case arm terminating fzf's argument parser; and fzf single-quotes the
   placeholder, so a row spec cannot inject shell.

3. **`ps -eo` is gone on Linux.** `build_process_table` forked `ps` and walked
   every process on the host before the first row could emit. `/proc` reads
   scale with pane count instead. Three traps, all covered by
   `tests/test_full_command.sh`:
   the "is this a shell?" test **must** come from the pane process's own argv —
   tmux's `#{pane_current_command}` names the tty's *foreground* process group,
   so gating on it inverts the test exactly when a command is running and every
   busy pane renders as `-zsh` (a `sleep X &` test case does *not* catch this);
   `/proc/<pid>/task/<pid>/children` has no trailing newline, so `read` assigns
   and *then* reports EOF, meaning `|| children=""` wipes what it just read;
   and `ps` was implicitly sanitizing argv — a raw newline splits a row and
   detaches its SPEC field, a raw `\x1f` reaches an fzf-visible field.
   `sanitize_args` reproduces `ps` byte-for-byte (NUL/newline → space, every
   other non-printable → `?`). `INTERDIMUX_FORCE_PS=1` pins the ps backend on
   both sides — bash's ps table and, since the macOS work in Tier 7 below, the
   Rust core's own ps snapshot.

4. **The last pre-`exec fzf` forks are gone**: `mktemp`, the `awk` in version
   parsing, three `$(sq_script)` subshells, and the dir picker re-exec'ing the
   whole script for a static header. `term_cols` prefers `$FZF_COLUMNS` so
   reloads skip the `stty` fork (it reads 0 during fzf's `start` event, hence
   the `^[1-9]` guard). `RESUME_FILE` only skips `mktemp` under
   `$XDG_RUNTIME_DIR` — a predictable name in a world-writable `/tmp` could be
   pre-created as a symlink that `: >` would then truncate.

**Also fixed: the test suites were dead.** `tmux_cmd` started the private test
server without `-f /dev/null`, so it inherited the developer's `~/.tmux.conf`;
with `base-index 1` every `:0` target failed and `test_list_format.sh` /
`test_send_keys.sh` aborted on the first command. Two of `test_list_format.sh`'s
assertions also passed *vacuously* — "no malformed rows" is trivially true
against zero rows — so a silently broken gather printed green ticks.

5. **`prefix+f` is bound straight to `display-popup`** (Tier 1.3). The old path
   forked `/bin/sh`, ran a full bash that resolved config it then discarded, and
   `exec`'d `display-popup` — a client round-trip — before the navigator bash
   even started. `run-shell -bC` runs the popup *in the server*, with no shell:
   **keypress → navigator bash 45 ms → 12 ms**.
   Values ride as tmux **format references**, not baked literals, so
   `@interdimux-*` edits still apply on the next open — there is no staleness and
   no reload step. That only works because the sentinel (5.1) makes an empty
   forwarded value mean "use the built-in default".
   Three traps, covered by `tests/test_bind_keys.sh`, which fires a *real*
   prefix+f through a nested client (`send-keys` writes to a pane's pty and can
   never trigger a key binding):
   every value needs **`#{q:}`**, because the expanded text is re-lexed by tmux's
   command parser and a raw `#{@x}` holding a `"` kills the binding outright —
   silently, with `prefix+f` simply doing nothing;
   **`#{?@x,…}` cannot test emptiness**, because tmux format truthiness treats the
   string `"0"` as false, so `color-tree 0` and `recent-limit 0` would be replaced
   by defaults (use `#{==:…,}`);
   and `TMUX_PANE` must be injected as `#{pane_id}` — a popup's command gets the
   server's *global* `TMUX_PANE`, whatever the process that started the server
   exported (another session's pane, or nothing), not the pressing pane, which
   silently kills both the current-row marker and MRU's move-current-to-end
   (see the comment above `_bk_who` in `--bind-keys`).
   `--bind-keys` dispatches **before** the preflight on purpose: if `fzf` is not on
   the tmux server's `PATH` (common — it is often only on `PATH` via a shell rc)
   the preflight exits 1, and doing that at plugin load would leave the user with
   *no bindings at all*.

6. **The four gather queries are one tmux invocation.** Each separate invocation
   costs ~5–6 ms of connect/teardown ahead of the first row.
   The obvious implementation is a trap in two ways: splitting the combined
   output with `${var#*RS}` is **quadratic** in the offset (682 ms on a 35 KB
   dump — far worse than the round-trips it replaces), so this word-splits on
   `IFS=RS`; and while tmux rejects RS in session and window *names*, a pane's
   **cwd can contain one**, which shifts every later section and silently
   truncates a path *and* drops the current-row marker. The split is accepted
   only when it yields exactly four sections. Command order matters too: tmux
   aborts the rest of a command list on failure, so the one fallible query (the
   current-target lookup, which depends on `$TMUX_PANE` still existing) goes
   **last**. `INTERDIMUX_NO_BATCH=1` forces the old path.

**Deliberately not done:** replacing the MRU `printf | sort` with a pure-bash
insertion sort. It wins below ~35 sessions but is 9× slower at 100 and 65× at
300, to save a ~5 ms fork. Tier 3 and Tier 4 are **rejected**, see below.

---

## Tier 6 — the cache and progressive-render question, answered with measurements

Re-opened 2026-07-26 because the Tier 4 rejection below contains a self-contradiction
("reading a cache is 1–2 ms against a ~90 ms gather, so the ceiling is imperceptible" — that
describes the *largest* remaining win and calls it negligible). A full survey + prototype +
adversarial verification pass followed. **Conclusion: do not build either.** The reasoning is
worth keeping, because the magnitude argument really is on their side and someone will propose
them again.

### Where the time actually goes now

Fetching is no longer the bottleneck — *formatting* is. Measured floors, same 136-row bench:

| | time to first row |
|---|---|
| `cat` a prebuilt cache file | 2 ms |
| bash reads that file and re-marks the current row | 8 ms |
| the single batched tmux query alone, no formatting | 9 ms |
| the real `--list` | 66 ms |

Instrumented phase split of a 142-row `--list`: dispatch 11–13 ms → query ~19 ms →
`measure_widths` **24 ms** → `compute_widths` 2 ms → MRU 6 ms → grouping 22 ms → **first row** →
emit 135 ms. So ~181 ms of the ~223 ms total is in-process bash with no I/O at all, and
emitting the first row *after* grouping costs +0 ms.

### Why the cache is not worth it — scale, not correctness

A working prototype was built and independently re-measured. It is genuinely fast and
byte-identical; the problem is who benefits:

| rows | first row now | with cache hit |
|---|---|---|
| 2 | 22 ms | 18 ms |
| 27 | 32 ms | 22 ms |
| 142 | 86 ms | 42 ms |
| 479 | 270 ms | 99 ms |

fzf suppresses all painting for the first **20 ms** (`initialDelay`, `src/constants.go:23`) and
paints exactly once if the whole stream lands inside that window. On a normal-sized server the
entire gather already fits there, so the cache buys nothing perceptible. It only pays from
~100 rows up.

Two defects also surfaced in verification, both fixable but both indicative of the complexity:
two clients attached at the same width **permanently evict each other's cache** (0% hit rate,
plus a wasted ~260 ms background refresh on every open) unless the cache key includes
`$TMUX_PANE`; and a single pane whose cwd contains `\x1e` trips the batched-query fallback,
which leaves the refresher firing on every close and throwing the result away.

And the content is far more volatile than sesh's: interdimux rows are a screenshot of a live
process table, so **rendered output changed on 9 of 10 samples taken 5 s apart** with only two
busy panes (the command column, from the /proc resolver). An identity-only projection changed
0 of 12 over 60 s. sesh's rows are static identity — that asymmetry, not the magnitude, is why
its design does not port unchanged.

### Why progressive rendering is worse, not better

- deferring the command column: **+6 ms** first paint, and **−192 ms** on time-to-correct-list
  (272 → 464 ms)
- session-rows-first: 320 ms of a confidently wrong `18/18` match count
- fzf has **no append action** — holding stdin open is the only true append, which the existing
  `gather_targets | fzf` pipe already does. Progressive rendering here is either free (already
  happening) or a regression.

### The lever to reach for first, if the picker ever feels slow at scale

**Digest-validated cache** — the only cache design worth building. `prefix+f` is already
`run-shell -bC "display-popup … -e … -E bash script"`, and `run-shell -C` format-expands *in
the server* at keypress, so a digest of everything rendered can ride in as one more `-e` var:
validation costs **zero tmux round-trips and zero forks**. Measured first row **6.2 ms** at
143 rows. Trap: `#{q:…}` escapes only a bare *variable* — `#{q:#{S:…}}` silently returns the
digest unescaped; escape per-variable inside the loop. Second trap: that digest is itself a
nested `#{S:#{W:#{P:…}}}` loop, so the time limit below applies to it. Keep it to fields that
expand cheaply (ids, names, flags, activity times), never `pane_current_command` or
`pane_current_path`: a digest cut short no longer covers the rows after the cut.

### Rejected outright

`awk` for the row renderer, and for a fused maxima+sort+grouping pass (17 ms → 5 ms): Debian and
Ubuntu ship **mawk**, where `length("żółć")` is 8 and `substr` splits UTF-8 mid-character, so
every padded column misaligns for non-ASCII names. Would need an explicit gawk dependency.

The **nested `#{S:#{W:#{P:…}}}` tree query** — one `display-message` returning the whole tree
grouped, which this section used to name as the first lever. Re-measured (136 panes, the
fields the gather carries), it saves 3.6 ms: 18.3 ms against 21.9 ms for the batched query.
Carrying the same fields it is the same size (9,739 bytes against 9,751), not 28% smaller, and
the ~22 ms of grouping loops it would delete no longer run on the default Rust path. And it
loses sessions: tmux 3.7 gives one format expansion 100 ms (`FORMAT_TIME_LIMIT`, format.c),
after which the remaining loop iterations expand to nothing — `display-message -v` logs
`# reached time limit` — so under load the dump simply stops early, and every session after
the cut is gone, with no error. With `pane_current_command` and `pane_current_path` in the
loop it came back short 10 times in 10 on a loaded box. `list-panes -a -F` and the other
`list-*` commands expand each row on its own, so a slow row costs at most that row's tail
(see the comment above `_sfmt` in `gather_targets`).

---

## Tier 7 — the Rust core was Linux-only; macOS ran the pre-Rust path (2026-07-27)

A user reported `prefix+f` "significantly slower" on a macOS laptop than on a Linux VPS with a
comparable session count. Measured on the Mac (15 sess / 75 win / 105 panes = ~150 rows, ~1300
host processes, medians): **`--list` ~1000 ms, vs ~200 ms for the same build with the Rust core
active** — a ~5× gap, with a far worse tail (10 s vs 0.5 s).

**Root cause.** The Rust core (Tier 5.3's follow-on) resolves the full-command column from
`/proc` and had **no other backend**, so the gate that hands rendering to it —
`[ -n "$IMUX_BIN" ] && { [ "$PROC_CMDLINE_OK" = 1 ] || [ "$SHOW_FULL_COMMAND" != "on" ]; }` —
was **false** on any host without `/proc` under the default `SHOW_FULL_COMMAND=on`. macOS has no
`/proc`, so every open fell to the bash renderer *and* `build_process_table` (fork `ps -eo`, then
a bash loop over **all** host processes, then a per-pane walk). Linux got the ~2 ms Rust render +
O(panes) `/proc` reads; macOS got the exact fork-heavy path the Rust core was built to retire.

**Fix.** Give the Rust core a **ps backend** (`rust/src/proc.rs`): where `/proc` is unavailable
(macOS/BSD) or `INTERDIMUX_FORCE_PS=1`, it takes one `ps -eo pid=,ppid=,args=` snapshot into the
same two maps bash builds (pid→argv, ppid→children in ps order) and walks them natively. The gate
relaxes to `[ -n "$IMUX_BIN" ]` (the binary resolves everywhere now); the empty-output
fall-through still covers a failing binary. `build_process_table` moves to the bash-renderer
*fallback* path only, so bash never forks `ps` when the binary works. Result on the Mac:
**~1000 ms → ~120 ms**, full command column intact.

Traps this reproduced (all covered by `tests/test_rust_parity.sh` + `tests/test_full_command.sh`,
with a new `INTERDIMUX_FORCE_PS=1` parity case so Linux CI exercises the ps backend too):

- **ps output is stored VERBATIM** (no re-sanitize) so it byte-matches bash's `PS_ARGS[$pid]="$args"`.
- **macOS `ps` escapes control bytes differently** than Linux `ps`: newline → `\012`, `\x1f` → `^_`
  (printable text), where Linux uses space / `?`. Both neutralize row-breakers; the test assertion
  is now OS-aware. Verified with `od -c` that no raw newline or `\x1f` reaches a field.
- **ASCII IFS, not Unicode.** The line splitter must mirror bash `read`'s default IFS (space/tab),
  **not** Rust's Unicode-aware `char::is_whitespace`/`trim_start` — macOS `ps` passes NBSP / U+2028 /
  U+2000 / U+3000 through verbatim and bash keeps a leading one in the args field. A Unicode strip
  diverged from bash at *shell detection* (which reads the un-trimmed argv0) on a pathological argv0
  like `\u{a0}-bash`: bash sees a non-shell, Rust saw `-bash` and descended. Found by an adversarial
  verification pass; fixed to ASCII-only and locked in with a regression test.

Byte-parity confirmed on this Mac: settled static load, 8/8 reps rust-ps == bash-ps; the whole
suite green. **On Linux the change is a no-op** — `PROC_CMDLINE_OK=1` already made the old gate's
first clause true, so the default Linux path (Rust + `/proc`) is unchanged.

### Tier 7.1 — libproc: kill the last `ps` fork on macOS

The ps backend still forks `ps -eo` once per build (and per reload) and reads every host process's
argv — ~100 ms, the whole remaining gap vs Linux's `/proc`. `rust/src/macproc.rs` replaces it with
per-pane kernel calls: `sysctl(KERN_PROCARGS2, pid)` for argv, `proc_listpids(PROC_PPID_ONLY, pid)`
for the first child. Cost scales with pane count, not host load — the native equivalent of the
`/proc` path. It is now the **default off-Linux backend**; the ps snapshot is retained for
`INTERDIMUX_FORCE_PS=1` and as the fallback (other BSDs, sandboxed libproc). Measured on the Mac:
full `--list` **250 ms → 135 ms**; `imux gather` on a captured dump **145 ms → 36 ms**; **zero**
`ps` forks on the default path (verified with a PATH shim). Full journey: **~1000 → ~135 ms** (~7×),
now the same performance class as the VPS.

The hard part is byte-parity with the bash **fallback**, which has no libproc and uses `ps`. `ps_vis`
reproduces macOS `ps -o args=` exactly for everything a real command carries — ASCII, valid UTF-8
(accents, CJK), and control-byte escaping (tab→`\011`, newline→`\012`, other C0 + DEL → caret). An
adversarial pass (multi-child ordering, KERN_PROCARGS2 parse, EPERM/dead-pid/races, an FFI-safety
audit with 3000 crash-hammers + fuzzing, and a full e2e sweep) confirmed libproc == bash+ps ==
rust-ps across the config space, with no OOB/UB/panics. Two **accepted, display-only** divergences,
documented in `macproc.rs`, neither reachable by a real command nor able to break the row contract:

- **child selection:** lowest-pid vs ps's `(tty, pid)`-order first child. Identical for every ordinary
  multi-child shell (jobs/pipelines/fg+bg all share the pane tty → pid-ascending). Differs only when a
  sibling `setsid()`s off the tty yet stays parented to the shell — both are valid children and the
  SPEC/target is identical, so Enter lands on the same pane either way.
- **invalid-UTF-8 argv** (binary/Latin-1 — never a real command): `ps` locale-escapes such bytes
  (locale-dependent); libproc maps them to U+FFFD like the Linux `/proc` backend, after escaping every
  control byte, so the row stays safe.

---

## Tier 8 — what the footer hint bar cost, and how it was paid back (2026-07-27)

Moving the key hints to a `--footer` and tiering them to the width added work to
the one path this document exists to protect: the navigator's, before fzf can
draw a first frame. Measured with a stub `fzf` on `PATH` that records its argv
and exits, min of 30 interleaved runs, so the number is the script's own cost
with fzf's startup removed.

```
before the change                                     41.8 ms
naive implementation                                  50.5 ms   (+21%)
  hint_cols (stty)                                     2.3-4.0 ms
  five ladders                                         6.3-8.6 ms
after the two fixes below                             43.5 ms   (+4%)
```

Two things were paying for it, and both had a cheap answer.

**The width measurement forked twice.** `hint_cols` needs the popup width, and
`$(term_cols)` is a subshell *plus* an `stty size` exec. The launch path already
made that call once — `INTERDIMUX_COLS` for the renderer — so the second one was
pure duplication. `term_cols_r` (REPLY-style, the idiom this file already uses
everywhere) plus a process-global memo makes it one exec again. Safe because the
only long-lived process is the navigator, and every event that can change the
width ends in a reload, which is a fresh child that measures again.

**The ladders were rebuilt from their parts, rung by rung.** Five row types × up
to eight rungs, each rung re-styling the same seven strings: O(rungs × hints).
Two changes, no behaviour difference (the packed ladders are byte-identical):

* style each hint **once**, then build each rung by CUTTING one fragment out of
  the previous one — one substitution per rung instead of a full rebuild;
* compute the drop order **once** with an insertion sort over ≤8 items, instead
  of re-scanning for the lowest priority on every rung. This was the bigger half:
  the re-scan was ~21 statements per rung and dominated the function.

The residual ~1.7 ms is the ladders themselves, and it buys a bar that fits at
every width and re-tiers on `^/` and on a resize with **no** process per cursor
move — which is the property Tier 2 spent its whole budget acquiring, so
spending a process here would have been the wrong trade.

## Tier 9 — what agent rows cost (gather3, 2026-09-25)

Agent rows (README "Agents and pane titles") put three new things on every
pane line of the batched query — `#{pane_id}`, `#{pane_title}`, and the values
of the pane options agent plugins publish — and a registry read and a rule
engine in front of the renderers. Measured on a private tmux 3.7b server, 97
panes unless said otherwise, on a noisy VM: wall times swung by ±10 ms between
runs, so the numbers that decided anything are interleaved medians of
`list-panes` alone (40 rounds) and CPU time (bash `time`, plus the tmux
server's own utime+stime from `/proc`).

```
list-panes -a, the old pane format                      10.3 ms
  + #{pane_id} #{pane_title}                            11.8 ms
  + 2 options, conditional #{?@x,x=#{s/…/:@x},}         12.6 ms
  + 4 options, conditional                              14.3 ms
  + 14 options, conditional                             20.7 ms   0.7 ms / option
  + 14 options, positional #{=128;s/…/:@x}              16.7 ms   0.35 ms / option
  + 14 options, raw #{@x}                               13.6 ms   (unsanitised: rejected)
  + a separate `list-panes -f '#{||:…}'` for options    32.7 ms   (rejected)
```

Three decisions came out of it.

**Positional values, sanitised, last on the line.** A conditional per option
cost twice the unconditional form: tmux parses and skips the branch text of a
`#{?…}` on every pane. So each option is one `#{=128;s/[GS RS US NL]/?/:@x}`
and a GS, in the order of `STATE_OPTS`, which both renderers know; an unset
option is an empty value. Unsanitised values were cheaper still but let a
newline in any plugin's option forge a pane line. The field is the last on the
line, so nothing in it can move another.

**Only pane-scoped plugin options by default** (10 names). A window-scoped
option resolves for every pane of its window, so the state showed on the
agent's neighbours; not reading them also saves ~1.4 ms per 100 panes. The
README lists them for users who want them anyway.

**The bash renderer parses rules lazily.** Parsing all the default rules
(some 70) up front cost ~18 ms (bash's UTF-8 regex compiles and multibyte substitutions),
and scanning every rule for every row ~0.7 ms a row. Now the first row that
needs a rule indexes the rule lines by app (first words only), and a rule is
split and compiled only when a row reaches it: a list of shells and editors
parses none. A title that cannot change its row (no rule for the app, not
`@interdimux-show-title all`) is not even cleaned.
`DEFAULT_STATE_OPTS` is spelled out, not derived from the rules on every list
(~5 ms of bash); tests/test_title_rules.sh keeps it in step with the rules.

End to end, CPU time of `--list` (client tree) and the tmux server:

| | 29 panes | 97 panes |
|---|---|---|
| Rust core, client | 63 → 64 ms | 59 → 66 ms |
| Rust core, tmux server | 2.3 → 3.7 ms | 4.0 → 11.0 ms |
| bash renderer, client | 100 → 124 ms | 174 → 222 ms |

(before → after; the tmux server figures have 10 ms tick granularity, means
of 20-30 runs, and were measured with the 14-option set, before the trim to
10.) That table UNDERSTATES the cost — see the re-measurement below: it was
taken on lists with no Claude records and few titles worth reading, and the
+1 ms on the Rust path was noise hiding ~6 ms.

### Re-measured, and what was paid back (reviews R09, R15)

Private tmux 3.7b servers of 30 and 100 panes, two kinds. *Plain*: idle
shells, sleeps, an editor with a title. *Agent-heavy*: of every six panes one
codex waiting on an approval (an 80-character title), one ssh with a prompt
title, one publishing `@agent_state`, plus three Claude panes with live
registry records and two stale records. CPU of the whole client tree
(user+sys through `wait4`), median; in brackets the tmux server's own CPU per
call (mean, 10 ms ticks). Interleaved runs — 40 per cell for Rust, 20 for
bash — on a 4-core VM that other work was loading, so read ±10%:

| `--list` | main | round2 (agent rows) | after R09/R15 |
|---|---|---|---|
| Rust, 30 plain | 40.8 [3.8] | 46.3 [6.5] | 46.8 [4.5] |
| Rust, 30 agent-heavy | 38.4 [2.3] | 47.8 [6.0] | 46.8 [5.8] |
| Rust, 100 plain | 52.8 [12.0] | 58.4 [16.8] | 60.2 [16.3] |
| Rust, 100 agent-heavy | 54.5 [11.8] | 65.3 [17.0] | 63.2 [17.8] |
| bash, 30 plain | 138 | 170 | 150 |
| bash, 30 agent-heavy | 124 | 183 | 160 |
| bash, 100 plain | 285 | 350 | 297 |
| bash, 100 agent-heavy | 290 | 404 | 363 |

Output is byte-identical between round2 and now on all four servers, in both
renderers. Where the Rust path's ~6-9 ms goes (`EPOCHREALTIME` stamps, 30
agent-heavy panes, minimum of 40): parsing the agent layer ~2 ms; reading the
rules file and building the option format 0.4 ms; the Claude registry ~0.35
ms a record; the tmux server formatting titles and option slots (1-2 ms at 30
panes, ~5 ms at 100); and the binary's own rule matching, under 1 ms.

Paid back:

* **Callbacks no longer parse the agent layer** (R15). bash parses a script as
  it runs it, and the ~850 lines sat above every dispatcher, so each callback
  fzf runs while you type or move paid ~2-3 ms for code only the lists, the
  dashboard and --doctor use. They now sit below those callbacks
  (tests/test_render_cost.sh checks it with bash's own trace). CPU per call,
  median of 40, round2 → now (main):
  `--footer-for` 24.4 → 21.2 ms (21.9), `--preview` 35.6 → 32.5 (32.3),
  `--describe-create` 27.0 → 24.8 (28.3), `--session-name-for` 33.5 → 30.7
  (29.1), `--scope-prompt` 23.5 → 18.6 (19.3).
* **The Claude registry** reads a record with two fewer regexes (bash compiles
  one on every `[[ =~ ]]`, ~30 µs each here) and drops a stale one after the
  pid, before the rest: 5 records 2.6 → 1.7 ms.
* **The bash renderer's read loops** (R09). `read` takes a here-string a byte
  per read(2), and every pane line carried its title and option values through
  measure_widths and the pane loop: ~2 system calls per title character per
  list (strace: 400-character titles on 30 panes cost 23,403 more read calls
  than 10-character ones; now 3). The fields are split in memory instead, and
  the title and options wait in a side table; measure_widths alone went from
  ~32 to ~7 ms at 100 panes.
* **Rows the agent layer cannot change** skip it: cmd_field returns the plain
  command for a row with no option published, no registry record, not an
  agent and no title a rule reads, in a few tests instead of agent_state_r
  (~40-80 µs a row here).

Left as it is, on purpose: `--list` still parses the agent layer (it draws
with it; splitting off the bash renderer's half would need a second `--list`
dispatch, for ~1.3 ms), the server-side option formatting (the decision
above), and an agent row's own ~1 ms on the bash renderer — cleaning its
title and matching its rules is what the row is for.

**A title is input from anywhere** (review R01, R13). The program in the pane
sets it — over ssh, from a container, from `cat` of a file — and tmux keeps an
OSC 2 title of up to `input-buffer-size` (1 MB) whole. Measured through the
dump seam, one row, `--list` wall time:

```
                                               bash renderer    Rust core
ssh row, 800 × "a:" (remote-shell rule)        0.14 s           1.79 s → 0.07 s
ssh row, 4000 × "a:"                           0.09 s           80 s   → 0.04 s
40,000 × "a", a rule for its app               1.59 s → 0.16 s  0.09 s
1 MB of U+200B (330,000 zero-width), same      88.6 s → 1.0 s   0.28 s
```

The Rust matcher backtracked (now it places the pattern's literal pieces from
the right, in linear time); the bash window row split its pane's
`id US title US options` with `${x#*"$US"}`, which is quadratic in where the
US is (now word splitting). Both renderers read only a title's first 256
characters (`TITLE_CAP`, `titles::head`), which bounds everything after the
split. tmux's `#{=256:pane_title}` would have cut it at the source, but it
counts cells — a title of zero-width characters passes it whole — and it
rewrites `###` as `####`. What is left at 1 MB is bash copying the line a
dozen times on its way to the cut.

The bash cleaning a title or a published description goes through was
quadratic as well, and a description is not cut at 256 (tmux caps an option
at 128 *cells*, and a C1 control is zero cells wide): the control-character
loop read `${s:i:1}`, O(i) per character in a UTF-8 locale, and the blank
trims were the `${t#"${t%%[! ]*}"}` idiom. Now two byte-wise substitutions
and two anchored regexes. prefix+g's count — always bash — with one codex
pane titled 5,000 × é and a U+0085: 4.3 s → 0.09 s.

### prefix+g's count (review R08)

The dashboard's Agents entry counts the waiting agents in bash, in a fresh
process, before display-menu can draw. Once ssh, docker, kubectl and the other
remote shells had title rules (none with a state), every such pane went
through `agent_state_r` -- a title parse and match -- for a state it could
never have, and so did every Claude pane, whose rules say only `working`; any
shell's default title (the host name) loaded the whole rule index first. Now a
pane reaches `agent_state_r` only when something could make it wait: a
registry record that says approve or input (one that says anything else is
final), a published option, an interpreter (named by its script), or a title
whose app has a rule that says approve or input -- `DEFAULT_AW_CAN` for the
shipped rules, spelled out because reading it off the rule text cost as much
as the index it saves. In that mode `agent_state_r` stops at the first source
that gives a state and skips the description. Duplicate lines (a session
group, a linked window) are dropped before any of it, and `load_title_rules`
no longer rewrites every line for a tab it does not have (~40% of its time).

Two private servers, each with a client attached from an outer one,
`--dashboard-launch` with display-menu stubbed, 50 interleaved runs, CPU time
of the process tree (getrusage) and the count's own wall time, min / median
in ms, on a box other agents were loading:

| | round 2 before | after | main (no count) |
|---|---|---|---|
| **31 panes**: 5 codex (1 as `./codex`), a Claude, 2 node, 14 ssh/docker, 8 shells | | | |
| the count alone | 39.7 / 52.5 | 27.0 / 36.2 | -- |
| whole launch, CPU | 76-88 / 100-108 | 81-84 / 96-102 | 62-63 / 74-79 |
| **30 panes**: 20 ssh, 10 shells, no agent | | | |
| the count alone | 25.7 / 31.7 | 13.6 / 17.0 | -- |
| whole launch, CPU | 76-85 / 100-109 | 64-72 / 88-92 | 67 / 78-81 |

(Ranges are two runs of the benchmark.) The count's remaining cost is mostly
the one `list-panes` (~11 ms wall of the 13.6), and with real agents to read,
the rule index (~5-8 ms) and their titles. "Before" also counted the
`./codex` pane as nothing (review R12). A count-only subcommand in the Rust
core would take the rest, for installs that have it.

## Tier 10 — what a keypress still forked (round 3, 2026-10)

Nothing counted what the paths a keypress waits on execute, so the 15-35%
that 49 merges added (TEST-33) showed only in how prefix+f felt. Now
`tests/test_exec_budget.sh` counts it without a clock -- the commands run,
through a PATH of logging shims, and bash's own forks, as distinct `$BASHPID`s
in an xtrace -- and holds each path to a budget; the per-row and per-match
paths must cost the same for 3 directories as for 30. The budgets were set
after these:

* **The navigator ran an `rm` before every first frame** (PERF-19), for a
  mount-table file that exists only after PID reuse. A builtin test first.
* **Every list waited for zoxide after its rows** (PERF-01): the Rust core
  ran the query at the directory rows, and bash captures its whole output.
  It starts before the first row now and is collected there. And
  `$(term_cols)`/`$(live_preview_state)` around the core's call were a
  subshell each (PERF-05); the REPLY forms take the values first.
* **A preview was three tmux clients** for a session row, two for a window
  or pane, plus two `$(dpad)` forks per window line and a `$(spec_target)`
  (PERF-06). One client now, its sections framed by RS as the gather's are.
* **The ctrl-o picker forked the script once per row** for its padding
  (PERF-07: `dpad_r`), and **a deep search ran a finder and a sed per
  matching directory** (PERF-08: `scan_roots`, one run over every root).

Measured outside the repo, with the A/B harness this round was checked with
(12 sessions / 40 windows / 90 panes, a 158x35 popup, 100 `svc-*` project
directories, 30-80 interleaved pairs, every output byte-identical), CPU of the
process tree and the tmux server, median ms, main → after:

| path | CPU | wall |
|---|---|---|
| navigator, to its first row | 111.7 → 103.2 (-4%, noise) | 101.4 → 90.5 (-9%) |
| `--list`, Rust core | 76.2 → 70.9 (-5%) | 77.0 → 69.6 (-10%) |
| `--preview` of a session | 69.7 → 30.4 (-56%) | 68.3 → 31.3 |
| `--preview` of a window / a pane | 39.9 / 38.1 → 30.9 / 28.9 (-21% / -25%) | 38.8 / 37.3 → 30.1 / 28.9 |
| `--dirs-list` (ctrl-o) | 202 → 134 (-34%) | 184 → 116 |
| `--dirs-list --deep svc`, 100 matches | 2695 → 585 (-78%) | 2320 → 543 |

That table is the perf group's branch on its own, where ~95 lines were added
above the callbacks and parsed in no measurable time. Merged, round 3 added
~22 KB there, and bash parses a script as it runs it, so every run of a
callback paid for them (~35 us a KB): `--scope-prompt` +5%, the footer,
`--describe-create`, `--session-name-for` and `--hint-ladder` +2-6%, all the
same sign. `--scope-prompt`, which needs nothing from the file, is now
answered at its top, and the hint bar sits before the scheduling modes and the
dialogs, which no callback uses. And BUG-108's narrower badge tiers had the
bash renderer ask whether any row has a git branch at 90-99 columns -- the
default popup of a 120-column terminal -- where main never asked: its list
was 16-22% slower there with identical rows, and the step was taken back.

The modes below the callbacks paid the same way, for ~44 KB in all: the
dashboard, its menu's `--launch`, Health and Jobs parsed the ~77 KB of
`--doctor` and the agents' modes; the scheduling modes and every callback
the rows' renderer (`gather_targets`, ~45 KB), which only a list runs; and
`--action`, the ctrl-o picker, `--list` and `--jump` the dashboard's count of
the agents that need you -- none of it used. Each of those blocks now sits
below its last user, moved whole: `--doctor` and the agents' modes last before
the navigator, the renderer after the scheduling modes, the count in the
dashboard's section, and `--dirs-hints` beside the hint bar.
`tests/test_render_cost.sh` checks the order from bash's own trace (`-x` for
what ran, `-v` for what was read). KB parsed before a mode's dispatch, main →
now: a preview 195 → 168, the footer 271 → 204, `--send-at` 232 → 220,
`--action` 322 → 342, `--list` 351 → 371, the dashboard 439 → 397, `--launch`
430 → 378, `--dirs-hints` 345 → 207, and `--doctor` 357 → 411: last in the
file, it is the one that parses the others now.

The merged tree, `bench.sh -s all` against main (12 sessions / 40 windows / 90
panes, 158x35), CPU median ms: first row 97.3 → 91.9, `--list` 65.3 → 61.7,
the bash renderer's 306.0 → 296.5, previews of a session, a window and a pane
65.5 / 36.8 / 33.8 → 27.6 / 26.6 / 24.0, the footer 29.2 → 25.8,
`--session-name-for` 29.6 → 27.0, `--dirs-list` 185.4 → 113.8, `--deep svc`
2208 → 475, `--dirs-preview` 52.5 → 49.8, `--hint-ladder` 20.1 → 16.4,
`--scope-prompt` 21.2 → 5.6; `--describe-create` (-4.8%), `--doctor` (-1.1%)
and the bash renderer's first row (-5.0%) within noise. `bash -n` of the whole
file, which no mode does, is +5.7% (400 pairs): the file is 9% larger. Modes
it has no scenario for, timed the same way on its fixture (60 pairs, a
stand-in `at`): `--send-at` -4.1%, `--sched-list` -7.0%, `--jobs-list` -8.8%,
`--launch` -7.8%, the ctrl-o picker -31%, its `--dirs-hints` -29%, `--jump`
-4.4%; `--action`'s kill and rename dialogs, Health and the dashboard's fzf
menu within noise.
zoxide's own 5-10 ms now overlaps the core's render instead of following it;
on a small server the render is short, so most of the query is still waited
for.

`tests/bench.sh [-n PAIRS] [-s SCENARIO,...] [REF]` is the in-repo A/B, with a
scenario for every row above, on a smaller fixture (6 sessions x 4 windows, 30
`svc-*` directories) and with plain medians, no noise estimate: it times these
paths for this checkout against REF, extracted with its own Rust core, and
refuses to compare unlike cores. Its run against main, 30 pairs, CPU ms, main
→ after: first row 85.0 → 77.0, `--list` 48.0 → 45.5, a session's preview
46.0 → 24.0, a window's 30.5 → 23.0, `--dirs-list` 146 → 86, `--deep svc` (30
matches) 1004 → 198; the footer, `--scope-prompt`, a directory row's preview,
`--doctor`, the bash renderer's list and `bash -n` within ±5% (noise). A
perf-relevant change pastes its table.

## Tier 11 — the layout: each mode parses only what it runs (2026-10)

bash parses a script as it runs it, so a mode pays for every line above its
own dispatch, comments included (~35 µs a KB), and the file had grown to
570 KB. Four changes, each measured on its own (the commit messages have
their tables):

* **`--list` draws its rows from a file of its own** (PERF-17). With the Rust
  core a reload runs only the fetch, the core's handoff and the title rules
  and registry they read: `scripts/interdimux-list.sh`, sourced right after
  the options and colours, which ends in `--list`'s fast path. It parsed
  ~400 KB first. A core that is missing, refuses or fails falls through to
  the bash renderer with what was fetched: one query, one refusal
  (`tests/test_list_fast.sh`). The modes below the callbacks source the file
  for the rules and the registry, and return before that fast path and the
  navigator's first list (~6 KB, ~0.3 ms a run).
* **The navigator's first list starts right after that file** (PERF-16,
  PERF-17): forked after ~27 KB of code instead of ~152 KB, so on the large
  fixture its rows are there when fzf starts (they came ~14 ms after its
  exec). A core that refuses or fails there hands the list to an exec'd
  `--list`.
* **The navigator no longer parses the modes it never runs** (PERF-13): the
  dialogs and `--action`, ctrl-o's picker, `--jump`, the launcher, Jobs, the
  dashboard, the agents' modes and `--doctor` are
  `scripts/interdimux-modes.sh`, sourced for any invocation with an argument,
  in their old order, so each parses what it did and one open more. ~180 KB
  less before fzf starts; the fork's head start keeps the large fixture's
  rows inside fzf's first paint step (~5 ms after its exec).
* **Each callback ahead of the code it never runs** (PERF-18): the
  preview's first half and the directory previews first, then a directory's
  session, the hint bar, the create resolver and the typed-query bar, then
  the preview of a session, window or pane; ctrl-o's list, a directory's
  Enter and the scheduling modes after them, and below every callback what
  only the navigator, the renderer and the other modes run (the pickers'
  theme, the git badge, command formatting, the rows' width helpers).
  `tests/test_render_cost.sh` holds the order, and runs each callback clean.

`dev/perf/bench.sh` against the tree before them (perf-r4), default budget,
large / small fixture, CPU unless said: the first paint -10.2% / -12.2% wall,
on fzf's first step 87% → 90% / 98% → 100% of opens; first-frame wall -25.6%
/ -21.2%, keypress wall -21.7% / -17.7%; `--list` -25.4% / -38.3%;
previews of a session -9.7% / -10.5%, a window -11.5% / -8.8%, a directory
row -24.6% / -15.6%; the footer -21.1% / -18.6%, `--describe-create` -18.2%
/ -18.3%, `--session-name-for` -23.7%, ctrl-o's header -28.6% and its
preview -18.4%; the rest level. The modes that source both files are not
quite: a sourced file is read whole, and `--action`, first in
`interdimux-modes.sh`, reads 128 KB of it that it never parses (~0.2 ms),
and parses the files' headers and the layout's notes (6.5 KB more comments
than before them, 339 bytes less code) — ^x, ^z and the other action keys
+1.7% to +1.9% over 200 pairs, which the bench calls ok, ~0.8 ms timed
directly; `--doctor`, last in the file, +0.1%. Against main, with the rounds
before: the first paint -35.8% / -34.2% wall (first step 0% → 100% / 16% →
98%), `--list` -33.6% / -42.2%, the footer -27.2% / -25.0%, a directory
row's preview -55.0% / -46.9%, `--action` (^x) -49.1%.

## Suggested rollout

1. **Tier 0 (0.1 + 0.2 + 0.3)** in one pass — pure fork removal, no gate, test-covered. This
   is the bulk of the win; re-measure with the Appendix harness afterward.
2. **Tier 2a** (static footer) — makes scrolling instant; also closes IDEAS #4.
3. **Tier 1.1 + 1.2** — cheap callbacks + single config dump.
4. Re-measure. Only if first paint is still not instant at your scale:
   **Tier 1.3** (drop the launcher bash) and/or **Tier 3** (`--listen` enrichment).
5. **Tier 4** only if profiling still points at the gather itself.

Keep the `\x1f` constraint in mind for any format-string change: it is fine as an *internal*
tmux-data delimiter but must never reach an fzf-visible spec field (see
`docs`/memory on the mangling bug). sesh uses `::`; `\t` is also safe.

---

## Appendix — benchmark methodology & raw numbers

Measured in-repo on this host (fzf 0.72.0, tmux 3.6a) with a synthetic load of extra
detached sessions (5 windows each, first window split to 3 panes). **The host was heavily
loaded (loadavg ~21)** — which inflates *absolute* fork cost and is representative of a busy
dev box; the *relative* attribution (forks vs tmux) is load-independent. "warm" = the config
env vars a child popup receives are pre-set, so the 27 `tmux show-option` reads are skipped.

Microbench — the core finding:

```
$(subshell) call : 0.85 ms each idle;  32-fork storm = ~1034 ms under load
REPLY-style call : 0.005 ms each       (≈170× cheaper; no fork)
fzf --version    : 113 ms under load   (runs in preflight on every invocation)
tmux -V          : 24 ms               (cheap, does not scale)
```

Script paths, warm, by scale:

| Invocation | 4 win / 4 panes | 79 win / 109 panes | 154 win / 214 panes |
|---|---|---|---|
| `--scope-prompt` (pure startup) | 94 ms | ~966 ms | ~956 ms |
| `--header-for` (per cursor move) | 93 ms | ~1290 ms | ~1097 ms |
| `--preview` (per cursor move) | 108 ms | ~357 ms | ~259 ms |
| `--list` (gather, full) | 156 ms | ~1085 ms | **~2092 ms** |
| `--list` (`SHOW_FULL_COMMAND=off`) | 130 ms | ~776 ms | ~1545 ms |
| `--list` (git off + fullcmd off) | 126 ms | ~770 ms | ~1348 ms |
| raw `ps -eo` | 16 ms | 23 ms | 31 ms |
| raw 3× tmux bulk queries | 13 ms | 13 ms | 16 ms |

Reproduce: the harness for these numbers lived in the scratchpad used to build this plan; it
created N×M detached sessions, timed `bash script --{scope-prompt,header-for,preview,list}`
warm/cold, and cleaned up on exit. `tests/bench.sh` is the in-repo A/B now (Tier 10), and
`tests/test_exec_budget.sh` holds the fork and exec counts these tiers removed. The two numbers that matter: `ps`+tmux stay flat while `--list` and
`--header-for` scale with row count and system load — i.e. **forks, not data fetching.**
