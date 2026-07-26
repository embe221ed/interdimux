# interdimux — improvement backlog

Curated from a research pass over `sesh` (source dive), other tmux managers
(tmux-sessionx, tmux-fzf, t, tmux-sessionizer, tmux-which-key, tmux-resurrect),
CLI/TUI design guidance (clig.dev, NN/g heuristics, terminal-color
accessibility), a live visual critique of the current build, and the fzf
0.56–0.73 changelogs.

Effort: **S** ≲ 30 lines · **M** = a focused session · **L** = a real feature.
Version gates are noted where a feature needs one (the plugin floor is
fzf ≥ 0.40, tmux ≥ 3.2; gated features degrade gracefully below their gate).

## 1. Quick wins

| # | Idea | Effort | Notes |
|---|------|--------|-------|
| 1 | ✅ **Done** — **Announce find-or-create in the zero-match state** — bind fzf's `zero:` event to a header like *"enter → create session 'api' in ~/code/api (zoxide)"* with the resolved name/dir. The feature is invisible today and typos create junk sessions silently. | S | fzf ≥ 0.40 |
| 2 | ✅ **Done** — **Cursor stability across reloads** — `--id-nth=-1` **without `--track`**; the SPEC field is a stable identity. Today every execute+reload can silently move the cursor to a different target (dangerous in kill mode). ⚠️ **Do NOT add `--track`:** it arms `trackBlocked`, which *discards* every keystroke except abort while a reload is in flight (`fzf src/terminal.go:6821-6827`) — worst exactly when the popup has just opened (measured keystroke loss vs 0/20 lost with `--id-nth` alone). `--id-nth` on its own never blocks and still restores identity across `reload-sync`. Pair with `enter:wait+accept` (fzf ≥ 0.74) so Enter during an in-flight reload can't accept an already-killed row. | S | fzf ≥ 0.71 |
| 3 | **Standalone `--last` toggle** — bindable (e.g. `prefix+L`) zero-UI switch to the previous session; recomputes MRU so it survives the last session being killed (tmux's built-in `switch-client -l` doesn't). | S | — |
| 4 | **Footer hint bar** — move key hints to `--footer`; header becomes purely per-row context and hints stop jumping as focus moves. | S | fzf ≥ 0.63 |
| 5 | **Responsive preview layout** — `--preview-window='right,50%,…,<90(up,40%,…)'` so narrow popups stack the preview below instead of starving both panes. | S | — |
| 6 | **Highlight the current session row** — render the current session/window name in amber bold; the lone `*` is easy to miss in 30+ rows. | S | — |
| 7 | **Session badge in the dir picker** — mark dirs that already have a running session (`●`) so Enter's switch-vs-create is predictable. One `tmux list-panes -a` call. | S | — |
| 8 | **Don't blank the popup behind dialogs** — drop the `\033[2J` clear in `dialog_open` so the confirm box floats over the frozen list (you keep seeing what you're about to kill). | S | — |
| 9 | **Kill dialog shows blast radius** — list the target's windows/commands in the confirm body ("3 windows: nvim, server, zsh…") instead of a generic warning. | S | — |
| 10 | **Dim idle shells** — strip login-dash/dirname from bare shells (`-bash`, `/bin/bash`) and dim them so rows doing real work pop. | S | — |
| 11 | **`--no-hscroll`** — command-column matches currently h-scroll individual rows, zigzagging the tree grid. | S | — |
| 12 | **Preview scroll binds** (`alt-u`/`alt-d`) and **fix "(cannot capture pane)"** shown for healthy-but-blank panes (distinguish capture failure from empty content). | S | — |

## 2. Flagship candidates

| # | Idea | Effort | Notes |
|---|------|--------|-------|
| 13 | ✅ **Done** — **Per-project startup commands / hydration** — after `new-session`, resolve a startup command (glob-matched `~/.config/interdimux/startup.conf` → per-repo `.tmux-sessionizer`-style file → `@interdimux-startup-command` default) and `send-keys` it. sesh tried exec-based delivery and reverted to send-keys (v2.26.2) — send-keys is the robust mechanism. Shipped: `~/.config/interdimux/startup.conf` globs → `.interdimux-startup` in the dir → `@interdimux-startup-command`; delivered via send-keys behind a shell-readiness wait; `@interdimux-hydrate off` disables. Layout *scripts* for multi-window bootstrapping are still open. | M | — |
| 14 | ✅ **Done** — **One-list model** — sesh's core UX: dim `+ dir` rows (recent/zoxide/projects, new `D:` spec) inline under session rows in the navigator, so Enter works without caring whether a session exists. Keep ctrl-o for deep-scan/browse. Shipped: `D:` rows from the recent list + zoxide, emitted *after* every tmux row so first paint is untouched and the tree's columns can't widen; directories that already have a session are skipped; `@interdimux-show-dirs` / `@interdimux-dirs-limit`. Still open: the project-dir tier (a filesystem scan would cost first paint) and `+ dir` rows *interleaved* per session rather than appended. | M | — |
| 15 | ✅ **Done** — **Raw filter mode** — the tree stays fully rendered while typing; non-matches dim (`--color nomatch:240:strip:dim`), ctrl-n/p hop between matches. Fixes the orphaned-`├─` collapse, the biggest visual weakness of tree-in-fzf. Needs care around find-or-create Enter semantics. | M | fzf ≥ 0.66 |
| 16 | **TAB multi-select kill** — sweep several dead sessions in one confirm. Verified: selections survive reloads only with `reload-sync` (not plain `reload`) and identity-matching needs `--id-nth`. `{+-1}` passes all selected SPECs to one `--action kill-multi`. | M | fzf ≥ 0.71 |
| 17 | **Help overlay** — `F1`/`alt-h` renders the full keymap in the preview pane (fzf's `preview()` action is ephemeral). About half the bindings are undiscoverable today. Plus a real `--help` CLI entry. | S/M | — |
| 18 | **Break out & move/link** — promote a pane/window to its own session (`break-pane`/`move-window`), and a two-step "move/link into…" mode (pick source, then destination session). Completes the manipulation story started by swap. | M | — |

## 3. Theme & accessibility (one coherent change)

| # | Idea | Effort | Notes |
|---|------|--------|-------|
| 19 | ✅ **Done** — **Configurable palette.** Every color is now an `@interdimux-color-*` option (hex / 256-index / `-1`) resolved through `set_palette()`; the built-in defaults reproduce the warm dark look. Light themes come from *feeding* those options (e.g. via interdotensional's per-theme config), which reconfigures the row ANSI that `@interdimux-fzf-opts` couldn't reach. | M | — |
| 20 | **Honor `NO_COLOR` / `TERM=dumb`** — blank the color vars (keep bold/dim; the NO_COLOR spec permits non-color styling), `--color=bw` for fzf. Still open: the palette is configurable but not auto-blanked. | S | — |
| 21 | ✅ **Done** — `separator` default changed from dim-white `2;37` to grey `245`, and is now the `@interdimux-color-separator` option. | S | — |

## 4. Robustness & speed (arguably bugs)

| # | Idea | Effort | Notes |
|---|------|--------|-------|
| 22 | ✅ **Done** — **Interrupt-safe dialogs** — Ctrl-C mid-dialog leaves the border stuck red and the cursor hidden; add an EXIT/INT trap in `--action`. Make rename cancellable with Esc (today: ctrl-u + Enter only). | S | — |
| 23 | ✅ **Done** — **Surface real failure reasons** — capture tmux stderr instead of discarding: "✗ session names cannot contain `.` or `:`" beats "✗ failed to rename". Pre-validate rename input. | S | — |
| 24 | ✅ **Done** (better than proposed) — `ps -eo` is gone entirely on Linux; full commands come from `/proc` per pane, so the cost scales with pane count instead of host process count. `ps` remains the macOS/BSD fallback. See PERFORMANCE.md Tier 5. | S | — |
| 25 | ✅ **Done** — both ride in via the popup's `-e` flags (Tier 0.3), and the per-cursor-move header no longer re-execs the script at all (Tier 5.2). | S | — |
| 26 | ✅ **Done** — **Stale widths after ctrl-/ toggle** — rows stay truncated for preview-on while half the popup is blank; track live preview state in a temp file, reload with corrected widths. | M | — |
| 27 | *(mostly done)* **Consistent keys across modes** — the ctrl-] cycle's fifth state (`1,3`) is labelled, the dir picker marks directories that already have a session, and the swap picker names its source in the prompt. Still open: ctrl-/ and ctrl-] are dead in action modes, and the swap destination picker has no preview. | S | — |
| 28 | ✅ **Done** — the PROMPT carries it, not the header (^f/^g own the header via transform-header). One `result` bind dispatching on `FZF_MATCH_COUNT`, not a `zero` + `result` pair: both events fire when the list empties and `result` runs last, so the pair rendered the message and immediately overwrote it. | S | fzf ≥ 0.51 |

## 4b. Landed from the reliability hunt

Found by adversarial review and each reproduced before being fixed. Listed
because the *class* is what is worth remembering, not the individual line.

| Bug | Class | How it presented |
|---|---|---|
| Scheduled commands quoted with bash `printf %q`, executed by `/bin/sh` | wrong shell | `at -c` shows the job starts `#!/bin/sh`, and `run-shell` hands its argument to `/bin/sh` too. dash has no `$'…'`, so a tab or newline in a scheduled command arrived as literal `$\t`. Fixed by `shq()`, POSIX single-quote escaping, everywhere a string is built for another shell. |
| A `#` in the install path killed the key bindings | format expansion | `run-shell` format-expands its argument, so `…/we#Sird/…` became `…/we<session>ird/…` and prefix+f silently ran a path that does not exist. Needs a `#` followed by a *format character* — `#ird` and `#1` are safe. |
| The directory picker dropped an early accept | `pipefail` | `sel=$(--dirs-list \| fzf) \|\| exit 1` with a slow streaming producer: accept before the scan finishes, the producer takes SIGPIPE, and pipefail reports 141 instead of fzf's 0. Same shape the navigator was already guarded against. |
| The zero-match header named a session Enter would not create | duplicated logic | `describe_create` and `create_from_query` derived the name independently, so with "api" open at `~/work/api`, typing `~/other/api` announced "create api" and created "other-api". |
| Emoji clusters measured per character | wrong oracle | `❤️` counted 1 cell but drew 2; `👨‍💻` counted 4 and drew 2. **The golden test that guards alignment used the same expression as the code**, so it could not fail. |
| A junk `@interdimux-recent-limit` printed errors onto the popup | unvalidated option | `[ "$count" -ge "lots" ]` → "integer expression expected", painted over the list. A junk `dirs-limit` made the Rust renderer drop every directory row. |
| An unwritable `$XDG_DATA_HOME` printed three errors onto the popup | best-effort not enforced | `mkdir`, `mktemp` and `echo > ""` all complained. Remembering a directory is a convenience; it must not cost the switch. |
| Dialogs overran a short popup | escapes counted as width | `${#text}` counts SGR bytes, so a coloured message that "fit" wrapped and overwrote the bottom border. |

Two recurring lessons, both of which cost real time here:

1. **A test that measures with the code's own expression proves nothing.** The
   alignment invariant passed for months while emoji shifted every column.
2. **A fixed sleep is a load-dependent assertion.** Four suites passed alone
   and failed in a batch; every one was a `sleep` that should have been a
   poll for the condition the test actually depended on.

## 5. Nice-to-haves

- **alt-1..5 numbered MRU quick-jump** (S) — deterministic muscle-memory jumps; alt-1 is always the previous session.
- **Pinned-sessions tier** (M) — harpoon-style anchors above MRU (`alt-p` toggle, state file like `recent_dirs`).
- **Hidden-session filter** (S) — `@interdimux-hide 'scratch floax-*'` + `_`-prefix convention; MRU makes scratch popups rank #1 today. Reveal toggle à la `sesh list -b`.
- **Clone git URL → session** (M) — find-or-create currently turns a pasted URL into a junk session named `https---github-com-…`; detect URLs, confirm, clone into the first project dir, hydrate.
- **Git-root awareness** (M) — jump-to-repo-root binding (`--root`); worktree sessions named `repo/worktree` so a repo's worktrees group.
- **Outside-tmux entry** (M) — `--cli [name]`: full-screen fzf + `attach`, so the picker works as the terminal's front door.
- **Restorable-sessions tier** (M) — dim ghost rows parsed from tmux-resurrect's `last` save for sessions that aren't running; the recovery UI resurrect never had.
- **Async list enrichment via `--listen`** (M) — first paint with cheap fields, background job POSTs a `reload-sync` with ps/git enrichment (working reference pattern exists in tmux-sessionx).
- **Zebra striping** (S, fzf ≥ 0.63) — `alt-bg` stripes; good for the flat dirs picker, **not** the tree (crosses session groups).
- **Column-title header row** (M, border needs fzf ≥ 0.59) — `--header-lines=1` pinned dim `TARGET │ PATH ‹BRANCH› CMD` labels; could also mark the active ctrl-] scope.
- **Preview title in the border label** (S) — `transform-preview-label` frees two lines of preview body; no gate (0.37 < floor).
- **Jump mode** (S) — `ctrl-j` + label letter = two-keystroke hop to any visible row (`jump:accept`); no tmux picker exposes this.
- **Live auto-refresh** (S, fzf ≥ 0.73) — `every(4)` + `FZF_IDLE_TIME` guard; safe once cursor tracking (#2) lands. Use `reload-sync` (not `reload`) so the swap preserves query/viewport, and `--id-nth` **without** `--track` — see the warning on #2; a periodic refresh with `--track` would drop keystrokes every tick.
- ~~**CJK/emoji display-width handling**~~ — done in the Rust core (cluster-aware `UnicodeWidthStr`, verified against tmux's own grid). Not backported to the frozen bash renderer.
- **`--info-command`** (S, fzf ≥ 0.54) — show `12/24 · mru` so the active ordering is visible.
- **Red Kill entry in the dashboard menu** (S) — `#[fg=colour167]Kill`, matching the danger vocabulary elsewhere.
- **Pluggable dir preview command** (S) — `@interdimux-dirs-preview-cmd 'eza -la {}'` for the listing body.
- **Recent (★) rows keep the project-type badge** (S) — currently the most-used dirs are the only ones missing it.
- **tmuxinator/tmuxp tier** (M) — list projects, start detached (`--no-attach` / `-d`) + switch-client, popup-safe.
- **fzf-marks merge** (S) — parse `~/.fzf-marks` into the recent tier; mark names become offered session names.
- **Clickable footer hints** (S, fzf ≥ 0.65) — `click-footer` + `trigger()` re-dispatches to existing binds.
- **Bound git-status cost in dir preview** (S) — `-uno --ignore-submodules` + `timeout 1` so huge repos can't freeze the preview.
- **Hold popup open on fatal errors** (S) — unexpected non-zero exit currently flashes and vanishes; trap and wait for a key.
- **`become()` instead of the RESUME_FILE restart loop** (M) — ctrl-o transitions navigator→dirs picker in-place, no restart flash; no gate (0.38 < floor).

## Suggested batches

1. All of **Quick wins (1–12)** in one pass.
2. **#13 startup commands + #14 one-list model** — the flagship pair.
3. **Theme & accessibility (19–21)** — the most-reported class of real-world
   complaint for fzf-based tools.
4. Robustness items (22–28) folded in opportunistically as their files are
   touched.
