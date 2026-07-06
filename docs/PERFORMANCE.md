# interdimux — performance plan (popup-spawn latency)

Goal: make `prefix+f` feel instant, so interdimux is viable as a *quick* window/pane/session
switcher. Today a cold popup can take several seconds on a busy host with many
windows/panes.

This plan is grounded in **measurements taken in this repo** (see Appendix) and a research
pass over `sesh` (the Go rewrite of the bash tool `t`), `tmux-sessionx`, `tmux-fzf`,
`tmux-sessionizer`, and the fzf man page + 0.36–0.74 changelog.

Effort: **S** ≲ 30 lines · **M** = a focused session · **L** = a real refactor.
Plugin floor is fzf ≥ 0.40, tmux ≥ 3.2; version gates are noted where a fix needs one.

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

Reproduce: the harness lives in the scratchpad used to build this plan; it creates N×M
detached sessions, times `bash script --{scope-prompt,header-for,preview,list}` warm/cold,
and cleans up on exit. The two numbers that matter: `ps`+tmux stay flat while `--list` and
`--header-for` scale with row count and system load — i.e. **forks, not data fetching.**
