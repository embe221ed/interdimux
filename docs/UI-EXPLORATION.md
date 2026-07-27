# UI exploration

Companion to `IDEAS.md`. That file is a backlog; this one is a record of what
was **rendered and measured** on a real terminal, so an idea that looks good in
prose can be rejected on evidence.

## Method

Nothing here is reasoned from the fzf man page alone. Each candidate was drawn
on a real grid: a private tmux server, real rows produced by `interdimux.sh
--list` against real sessions, then `capture-pane -p` to read the cells back.
fzf 0.74.0, tmux 3.7b.

The reason for the ceremony is the lesson `IDEAS.md` already records twice — a
claim you did not measure is a claim about your own expectations. Two of the
seven candidates below died on contact, and one of those two (`--scheme=path`)
would have shipped as a plausible, wrong improvement.

---

## Baseline — what it draws today

118-column popup, no preview, directory rows on:

```
❯                                                                          20/20
─────────────────────────────────────────────────────────────────────────────────
  enter switch  ^x kill  ^e rename  ^o new  ^r reload  ^/ preview
▌   ▸ dotfiles         1 win now                                                │
    └─ dotfi… 0:zsh    │ ~                     bash …/pyenv-rehash              │
    ▸ long-running-an… 1 win now                                                │
    └─ long-… 0:zsh    │ /opt/tools/interdimux bash …/pyenv-rehash              │
  * ▸ work             2 win now                                                │
  * ├─ work 0:edit     │ /opt/tools/interdimux bash …/pyenv-rehash              │
  * │ ├╴ work 0.0      │ ~                     -zsh                            │
    │ └╴ work 0.1      │ /opt/tools/interdimux bash …/pyenv-rehash              │
    └─ work 1:build    │ /opt/tools/interdimux -zsh                             │
    + interdotensional │ /…/interdotensional   Python                           │
```

Three things this render settles that were not obvious from the source:

* The `│` running down the far right is fzf's **scrollbar**, not a column.
* The hint line sits between the prompt separator and the list, and it is the
  line a `focus` bind **rewrites on every cursor move**. So the top of the
  screen twitches while you scroll, at the exact spot the eye uses as its
  anchor.
* On the pane rows the dim part is `work 0.` and only the pane index is bright
  — a breadcrumb with the leaf emphasised. That is deliberate and good, and it
  is worth not breaking.

---

## Worth doing

### 1. Move the key hints from `--header` to `--footer` — S, high

fzf 0.74 has a sticky `--footer` that is unaffected by `--with-nth` and
processes ANSI. Moving the per-row hints there puts the changing text at the
bottom, where lazygit and k9s put keys, and leaves the top of the list still.

Measured cost, precisely: **one list row.** 19 visible rows become 18, because
the footer always draws its own separator line — `--footer-border=line` and no
border option at all produced byte-identical output.

```
today                                    with a footer
─────────────────────────────────        ─────────────────────────────────
❯                          20/20         ❯                          20/20
─────────────────────────────────        ─────────────────────────────────
enter switch ^x kill …   ← rewrites      ▌ ▸ dotfiles      1 win now
▌ ▸ dotfiles      1 win now                └─ dotfi… 0:zsh │ ~
  └─ dotfi… 0:zsh │ ~                      ▸ long-running… 1 win now
  … 19 rows                                … 18 rows
                                         ─────────────────────────────────
                                         enter switch ^x kill …  ← rewrites
```

Not free of consequence: `INTERDIMUX_HDR_S/W/P/D/X` and the
`focus:bg-transform-header` bind all become `transform-footer`, and
`--header-lines` interactions would need rechecking if a column-title row is
ever added (see 3). Needs fzf >= 0.65 for `--footer`.

### 2. The width squeeze drops the git branch to save two cells of path — S, high

This one is arguably a bug rather than a style question.

`rust/src/widths.rs` squeezes in a fixed order: session prefix down to its
floor, then **the git badge straight to 0**, then the path, then the window
name. The badge is all-or-nothing on purpose (a 3-cell badge is worse than
none), but it is the *second* thing sacrificed, and it is sacrificed before the
path gives up a single cell.

Rendered at 118 columns and at 80 (i.e. an 80% popup on a 100-column
terminal — very ordinary):

```
118 cols:  └─ long-running-an… 0:tmux  │ /opt/tools/interdimux ‹main›   bash …
 80 cols:  └─ long-… 0:zsh             │ /opt/tools/interdimux          bash …
                                                                 ^^^^^^
                                                        branch gone entirely
```

The arithmetic, from the source: at `avail = 72`, after the prefix hits its
floor of 6, `ident = 20` and `ctx = path(21) + 3 + badge(16) = 40`, so
`20 + 40 + 2 + CMD_MIN(12) = 74` — two cells over. Zeroing the badge frees 19.
Trimming the path from 21 to 19 frees exactly the 2 that were needed, and
`PATH_FLOOR` is 12, so there were nine cells available.

**Two cells of path currently cost the whole branch indicator.** Whether
`/opt/tools/interdimu…` is a fair price for `‹main›` is a judgement call — the
point is that the current order never asks.

Same behaviour with the preview open, which halves `avail`, so this is not a
narrow-terminal edge case:

```
preview off:  └─ long-running-an… 0:zsh  │ /opt/tools/interdimux ‹main›
preview on :  └─ long-… 0:zsh            │ /…/interdimux
```

Touches `rust/src/widths.rs`, the bash fallback's `compute_widths`, the golden
corpus and `test_rust_parity.sh` — the two renderers must stay byte-identical.

### 3. `--info-command` to name the active ordering — S, medium

Already in `IDEAS.md`; confirmed available and rendered:

```
❯                                                                    20/20 · mru
```

One caveat the backlog entry does not mention: `--info-command` has **no inline
form**, so unlike the header hints (which were deliberately reduced to an
inline `case` to avoid re-exec'ing the script) this is a real `sh -c` fork every
time the info line updates — i.e. per keystroke. The project already accepts one
such fork for `focus:bg-transform-header`, so this doubles that rather than
introducing something new. Worth stating before it lands, not after.

---

## Checked and rejected

### `--style=full`, and section borders generally

Inside a popup that already draws a rounded border you get a **second** nested
frame, and the scrollbar collides with the list border — note the `││`:

```
╭──────────────────────────────────────────────────────╮
│ ❯                                              20/20 │
╰──────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────╮
│   enter switch  ^x kill  ^e rename                   │
╰──────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────╮
│ ▌   ▸ dotfiles         1 win now                    ││   ← scrollbar vs border
```

`--input-border=horizontal --list-border=horizontal` is milder but stacks
**four** horizontal rules above the first row. Both cost rows and width for
structure the popup frame already provides.

Worth revisiting only for a future `--cli` mode, which runs outside tmux and has
no popup frame to nest inside.

### `--gap` / `--gap-line`

It is per **item**, not per group — so it rules between every row, halves the
list, and adds no session grouping:

```
▌   ▸ dotfiles         1 win now
  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
    └─ dotfi… 0:zsh    │ ~   bash …
  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
    ▸ long-running-an… 1 win now
```

Separating session groups in one flat list still has no answer from fzf's flag
surface. (`IDEAS.md` rejected zebra striping for the same reason — it crosses
group boundaries.)

### ~~`--freeze-left=N`~~ — **this rejection was wrong; see below**

The original entry read: *"interdimux pads every row to exactly the available
width, so no line ever overflows and fzf never hscrolls. Rendered: no difference
at all. A no-op here."*

The render was real; the conclusion was not. The corpus I measured had short
commands (`-zsh`, `bash …/pyenv-rehash`), so nothing overflowed — a true
observation about that corpus, generalised into a false claim about the tool.

Rows are **not** padded to the available width. `render.rs` pads `ident` and
`ctx`, but the command is the last field and is written unpadded
(`rust/src/main.rs:273`). With `SHOW_FULL_COMMAND=on` — the default — it is the
full argv from `/proc`, so overflow is routine. The rows already measured
exactly 118 cells in a 118-column popup, i.e. flush against the edge.

Reproduced with a long command and the query `zebra`:

```
without --freeze-left — the identity column is REPLACED by the ellipsis
  ▌ …tor     │ ~/code/proj ‹main›   nvim src/very/deep/…/handler_implementation_zebra.rs
    ^^^^ which pane is this?

with --freeze-left=1 — identity intact, match still visible
  ▌   ├─ proj 0:editor…roj ‹main›   nvim src/very/deep/…/handler_implementation_zebra.rs
      ^^^^^^^^^^^^^^^^
```

`IDEAS #11` proposes `--no-hscroll` for the same zigzag. Rendered, that fixes
alignment by **hiding the match** instead — `handler_implemen…` — which is the
wrong trade for the one scope (`^] cmd`) whose entire purpose is matching in
that column. Freeze, don't disable; keep `--no-hscroll` only as the pre-0.67
fallback.

Needs fzf >= 0.67, so gate it. Genuinely a no-op on short-command setups, which
is exactly how the original measurement fooled me.

**The lesson is the one this repo keeps paying for, in a new costume:** the
fixture decided the answer. A rendering probe is only as honest as the rows you
feed it, and mine contained nothing long enough to trigger the behaviour I was
testing for.

### `--scheme=path`

This looked like a clean win for the directory picker, and the man page
practically prescribes it ("choose this over default if you have many files
with spaces in their paths"). It genuinely does re-rank:

```
query "api", --scheme=default        query "api", --scheme=path
~/projects/my api notes/draft   ←     ~/src/rust/api
~/src/rust/api                        ~/work/api-gateway
~/work/api-gateway                    ~/dev/vechain/thor/api
~/dev/vechain/thor/api                ~/code/apidocs-generator
~/code/apidocs-generator              ~/repos/graphql-api-server
~/repos/graphql-api-server            ~/projects/my api notes/draft   ←
```

…and it is **useless here**, because the directory picker passes `--no-sort` to
preserve its tier order (★ recent, then project dirs). With `--no-sort` fzf
filters but never ranks, so the scoring scheme cannot affect anything. The
navigator does sort, but it matches `--nth=1,3` (name and command), not paths,
so `path` is the wrong scheme for it.

Recorded because the reasoning was sound and the conclusion was wrong — exactly
the kind of change that ships as an unnoticed no-op.

---

## The dashboard's two silent size failures

Found while adding entries to the `prefix+g` menu, and both are dead-key
failures with no diagnostic anywhere.

**`display-menu` taller than the client draws nothing and exits 0.** Menu height
is `items + 2`. Measured on 3.7b with the 13-item dashboard:

```
client 15 rows -> menu appears
client 14 rows -> nothing at all, rc 0, no message
```

Adding two entries moved that cliff from 11 rows to 14 without any sign of it.

**`display-popup` does not clamp either — it errors.** The limit is exactly the
client's size:

```
14-row client:  -h 14  rc=0
                -h 15  rc=1  "height too large"
90-col client:  -w 90  rc=0
                -w 92  rc=1  "width too large"
```

So the fzf fallback, at a fixed `64x19`, was the *same* dead key reached by the
other path — for anyone on a client under 64 columns or 19 rows.

Both are now guarded: the menu is chosen only when `#{client_height}` can hold
it, the fallback popup is clamped to the client, and `tests/test_dashboard.sh`
renders `prefix+g` at six client sizes plus a structural check that `MENU_ROWS`
still equals the menu it guards — so adding an eleventh entry cannot quietly
bring the cliff back.

The general lesson, which is the same one this repo keeps relearning: **tmux
reports geometry failures by not drawing.** Anything sized in absolute cells
needs a measured guard, not an assumption about how big terminals are.

---

## From the survey

A second pass studied the competitors (sesh, tmux-sessionx, tmux-fzf, tmuxinator,
tmux-menus, tmux-which-key, smug, tmuxp) and the modern TUIs people admire
(lazygit, k9s, zellij, helix, delta, gh-dash, atuin, yazi, television,
bubbles/lipgloss). Ranked by value per unit of effort. The first four were
re-verified here before being written down.

### 1. Make the `^]` scope visible in the rows — S, high · **verified**

`ctrl-]` cycles the match scope through `1|2|3|1,2,3|1,3` and announces it only
as a word in the prompt. Miss that word and the query looks broken.

fzf 0.58's `--color nth:ATTRS` restyles the `--nth` fields independently, so the
searchable columns become literally the bright part of the screen — and the
bright band **moves live** when `change-nth` fires, with no reload and no extra
bind. Confirmed by reading the emitted SGR:

```
--nth=1,3 :  "1:shell"  ESC[2m "      PATHCOL2 " ESC[0m  "zsh"     ← path dimmed
--nth=2   :  ESC[2m "  └─ proj 1:shell      " ESC[0m "PATHCOL2" ESC[2m " zsh"
             ^^^^ ident+cmd dimmed                      ^^^^ path bright
```

One token in `build_fzf_colors`, gated: `fzf_ge 58 && FZF_COLORS+=",fg:dim,nth:regular"`.

Caveat: `--color` cannot be re-issued mid-session, so it is all-or-nothing — it
cannot apply "only when the scope is non-default", and at the default `1,3` the
ctx column becomes permanently faint. That is a taste call.

### 2. `--freeze-left=1` — S, high · **verified** (see the corrected rejection above)

### 3. The hint bar is silently truncated on an ordinary terminal — S, high · **verified**

Measured, SGR stripped:

```
S row  73 cells   enter switch  ^x kill  ^e rename  ^d detach  ^o new  ^/ preview  ^] scope
W row  71 cells   enter switch  ^x kill  ^e rename  ^s swap  ^o new  ^/ preview  ^] scope
P row  70 cells   enter switch  ^x kill  ^z zoom  ^s swap  ^t send  ^/ preview  ^] scope
D row  51 cells   enter open  ^o new  ^r reload  ^/ preview  ^] scope
```

The popup is 80% of the client, so an 80-column terminal gives the header ~62
cells — every tmux-row hint overflows, and `^] scope`, the least discoverable
binding in the tool, is the **first** thing cut. Anything under ~95 columns is
affected, which includes a split pane on a wide monitor.

zellij's `render_controls_line` is the model: explicit width tiers written into
the code, and a floor below which it prints nothing rather than something
mangled. `hint_r` already takes (key, label) pairs and the strings are built
exactly once per open, so tiering costs nothing per cursor move. Pairs naturally
with moving them to `--footer` (§1 above).

### 4. The "you are here" anchor is dropped where it is needed most — S, high

The README already admits the row scrolls out of view. It is worse than that:
MRU deliberately moves the **current session to the end** of the list, so on any
list longer than the popup the anchor starts off-screen. And `--launch kill`
replaces the title's session name with the mode name, so the one remaining
"where am I" cue is gone in exactly the destructive mode.

Two small changes: append the mode to the title instead of replacing the session
(`interdimux · kill · work`), and add a jump-to-current bind. The Rust core
already knows the current row — it emits the `*` marker for it — so it can write
the index to a state file the way `PREVIEW_STATE_FILE` already works, and
`alt-h:clear-query+transform:printf 'pos(%s)+offset-middle'` centres it.
`clear-query` is load-bearing: `pos()` indexes the *filtered* list.

tmux's own `choose-tree` has had this as `H` for years.

### 5. Action modes promise a destructive Enter against an empty list — S, medium

The zero-match `result` bind exists only in the switch arm. Every action mode —
kill, rename, zoom, swap, detach, send, schedule — gets a static header and no
zero-match handling, so in kill mode a typo leaves an empty list under a header
that still says `enter kill`. One shared `result` bind dispatching on
`FZF_MATCH_COUNT`, exactly as IDEAS #28 established (one `result`, never a
`zero`+`result` pair).

### 6. Two backlog entries are wrong as written

- **IDEAS #5** proposes `--preview-window='right,50%,…,<90(up,40%,…)'`. With a
  50% split the threshold is measured against the *preview*, so `<90` fires
  until the popup is ~180 columns wide — the stacked layout would be the normal
  case and the side-by-side the exception, i.e. the opposite of the intent.
- **IDEAS #11** proposes `--no-hscroll`; see the freeze-left correction above.

### 7. Attach the rule to the session row — M, high

The group-separation problem `--gap` and zebra striping both failed to solve.
The session row emits `ident \t meta \t\t S:name` — field 3 is **empty** and
`--nth=1,3` never matches field 2, so a rule drawn there can never be
highlighted or hscrolled. Extending the session row's padding into a `─` run
costs **zero extra rows** and marks the boundary:

```
▌ ▸ proj ──────────────────────────────────────────────  3 win ● 2h
    ├─ proj 0:editor   │ ~/code/proj ‹main›   nvim main.c
    └─ proj 1:shell    │ ~/code/proj ‹main›   zsh
  ▸ other ─────────────────────────────────────────────  1 win 3d
    └─ other 0:main    │ ~                    zsh
```

M rather than S because `test_rust_parity.sh` enforces byte-identical output, so
it lands in both renderers or the suite fails.

### 8. The width work, extended — M, high

An independent rediscovery of the squeeze-order finding above, plus two more in
the same function: the flags are appended *after* the branch, so their x
position moves with branch length and they cannot be scanned as a column; and
the branch budget depends on the flag count, so the same branch truncates
differently on different rows. Fixed slot for flags, branch budget independent
of them, and one squeeze rung for the path before the badge is zeroed.

### The rest, in brief

| | idea | effort/value |
|---|---|---|
| 9 | Group the dashboard with unselectable `-` headings (same mechanism as the greyed-out entries already shipped) | S/med |
| 10 | Stop spending the accent colour on every command — it is currently the current-row marker, the pointer, the prompt *and* every command, so nothing stands out | S/high |
| 11 | A dead pane still advertises the command that died — `#{pane_dead}` is not queried | S/med |
| 12 | Window-flag vocabulary gap: `-` (last), `~` (silence), `M` (marked) are unimplemented; `-` is the target of `prefix + l` | S/med |
| 13 | Git-state badges (dirty/ahead/behind) are nearly free — `GitCache` already stats `.git` | S/med |
| 14 | `pane_title` as a *fallback* where the command heuristics miss, opt-in | S/med |
| 15 | A session group renders as two complete duplicate trees | S/med |
| 16 | Generate footer, help and dashboard from one keymap table — they have already drifted | M/high |
| 17 | Ride tmux's own marked pane (`select-pane -m`) instead of the bespoke two-step swap | M/high |
| 18 | Route action feedback into the popup as a self-clearing footer toast instead of the client status line | M/high |
| 19 | Let the tree collapse — a sessions-only view. interdimux is the only one of the three that always renders every window of every session | M/high |
| 20 | Preview a multi-pane window as its panes, as `choose-tree` does | M/med |
| 21 | An in-picker ordering toggle to pair with the ordering indicator | S/med |
| 22 | Multi-select needs a row treatment, not just a marker | M/med |
| 23 | The restorable-sessions tier is cheaper than the backlog assumes (forkless parse) | M/med |
| 24 | **Hold the line**: no icon column, no query sigils, no custom TUI — each has a specific answer grounded in this codebase | — |

## Landed from this pass

* The dashboard greys out entries that cannot act (`Jobs` with an empty queue,
  both scheduling entries without `at`) and shows the queue count in the label.
  Verified against tmux 3.7b: a `display-menu` item name beginning with `-` is
  dimmed **and loses its key column**, and item names are formats so `#[fg=…]`
  styles them. Neither fact is visible from the source, so the tests render the
  real menu through a pair of private tmux servers and read it back.
* `Kill` is drawn in `@interdimux-color-danger` — the same colour as the frame
  it turns red, and the only dashboard entry that destroys anything.
