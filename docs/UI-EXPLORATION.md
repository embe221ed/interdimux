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

### `--freeze-left=N`

Freezes leading fields during **horizontal** scrolling. interdimux pads every
row to exactly the available width, so no line ever overflows and fzf never
hscrolls. Rendered: no difference at all. A no-op here.

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

## Landed from this pass

* The dashboard greys out entries that cannot act (`Jobs` with an empty queue,
  both scheduling entries without `at`) and shows the queue count in the label.
  Verified against tmux 3.7b: a `display-menu` item name beginning with `-` is
  dimmed **and loses its key column**, and item names are formats so `#[fg=…]`
  styles them. Neither fact is visible from the source, so the tests render the
  real menu through a pair of private tmux servers and read it back.
* `Kill` is drawn in `@interdimux-color-danger` — the same colour as the frame
  it turns red, and the only dashboard entry that destroys anything.
