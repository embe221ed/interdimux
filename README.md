# interdimux

A portal gun for your tmux sessions.

`interdimux` is a fuzzy tmux navigator for quickly jumping between sessions, windows, and panes with a fast keyboard-driven workflow.

## Features

- Fuzzy switching between sessions, windows, and panes in a single list
- Most-recently-used ordering: the previous session sits on top (empty
  query + `Enter` = toggle between your two latest sessions); the current
  session is parked at the bottom
- Find-or-create: `Enter` on a query that matches nothing creates a session
  with that name (resolved as a path, then via zoxide, then under `$HOME`);
  `Alt-Enter` creates it even when something matches. fzf's search syntax is
  not part of the name, so `'docs` creates `docs`, and a query with fzf's OR
  (`|`) is a filter that creates nothing
- Scoped fuzzy matching — queries match names and commands, not paths,
  padding, badges, or tree glyphs; cycle the scope with `Ctrl-]`
  (name / path / cmd / all / name+cmd, fzf >= 0.58). The searchable columns
  are the bright ones, and the bright band moves with the scope
- Session groups are ruled off, so a flat list still reads as a tree — at
  the cost of no extra rows
- Warm fzf theme matched to the list palette; popups inherit your
  `popup-border-style` / `popup-border-lines` settings, with titled
  frames on tmux >= 3.3 and a red frame during kill prompts and kill
  mode on tmux >= 3.6 (only the colour is overridden — your border
  lines and background are kept; with `padded` lines, which have no line
  to colour, the frame's background turns red instead). Kill mode's prompt
  is red too, on any tmux and any border — with `none` there is no frame
- Dashboard as a native tmux menu, or a scrolling fzf menu on a client too
  short for it
- Proper confirmation dialogs (centered boxes, `y`/`n`/`esc`) instead of raw
  prompts; rename pre-fills the current name with readline editing, by word
  too (`Alt-b`/`Alt-f` or `Ctrl-←`/`Ctrl-→`, `Alt-d`, `Alt-Backspace`)
- Actions run in place — kill/rename/zoom/swap reload the list without
  restarting fzf, keeping your query and the cursor's row (the row, not the
  item: after a kill it rests on whatever moved into that row)
- Optional live preview with a title line (target, command, path) and a
  window summary for sessions — off by default, toggle with `Ctrl-/`
- Metadata: window count, attached marker `●`, last-used age, zoomed `Z` /
  bell `!` / activity `#` flags, current-target markers
- Git branch display (`‹branch›` badge) with detached HEAD support
- SSH-aware display: highlights `user@host` for SSH/mosh connections
- Editor-aware display: highlights the filename for vim, nvim, emacs, etc.
- Panes only shown for multi-pane windows (keeps the list clean)
- Columns sized to the actual content (longest name / window / path) and
  the popup width, so window names keep their space even under a long
  session name; panes/windows stay aligned across the tree
- Create new sessions from a directory picker
- Key hints in a footer, out of the anchor zone at the top, tiered to the
  width available instead of truncated — and they change with the selection
- A health check in the dashboard, `:checkhealth` style — a popup you can page,
  search and re-run, leading with the verdict
- Dedicated modes for kill, rename, zoom, swap, detach, and send operations
- Configurable key binding, popup size, ordering, preview, and extra fzf flags

## Dependencies

- **`tmux` >= 3.6 — a hard requirement, not a recommendation.** Every row is
  delimited with a raw US byte (`\x1f`) inside a `tmux -F` format, and tmux
  3.5a and older rewrite that byte as the four characters `\037`. The whole row
  then parses as one field, the session name comes out empty, and the picker is
  simply blank. Measured: 3.4 → 0 rows, 3.5a → 0 rows, 3.6 → works. Note that
  Ubuntu 24.04 ships 3.4 and Debian 13 ships 3.5a. On Debian 13, enable
  trixie-backports and `apt install -t trixie-backports tmux` (3.6b); Ubuntu
  26.04 ships 3.6a; on Ubuntu 24.04, build tmux from source.
- **`fzf` >= 0.40, and 0.74 for everything.** Below 0.40 the picker refuses to
  start, and says so. From 0.40 up it opens a working picker, and every newer
  feature is version-gated and degrades on its own (0.46 the find-or-create
  announcement, `Alt-Enter` and re-fitting on resize, 0.51 a hint bar that
  follows the cursor without starting a process per move, 0.52 full-line
  highlight, 0.53 errors logged instead of drawn over the list, 0.58
  match-scope cycling, 0.61 ghost text, 0.63 the footer hint bar, 0.66 the
  scope highlight, 0.67 the frozen identity column, 0.74 raw filter mode) —
  but 0.74 is the only version the test suite exercises in full;
  `tests/test_old_fzf.sh` checks just that 0.40, 0.44 and 0.52 open and draw.
- `bash` >= 4.3, on the tmux server's PATH (macOS's own `/bin/bash` is 3.2). An
  older one is refused with a one-line error — on the status line, too, when
  tmux runs it — rather than failing somewhere inside.
- A UTF-8 locale. The tree glyphs are multibyte and every column width is
  counted in cells. The Rust core counts cells in any locale. The list's bash
  renderer picks `C.UTF-8` (or another UTF-8 locale that is installed) by
  itself when nothing names one, as for a tmux server started with no
  `LANG`, but keeps an `LC_ALL` or `LC_CTYPE` you set. Anywhere else — the
  dialogs, the dashboard — bash counts bytes in a locale that is not UTF-8,
  and columns misalign. `--doctor` says so.
- `fd` or `find` (for directory picker)
- `at` (optional — the Schedule and Jobs entries; needs its job-runner enabled)
- `zoxide` (optional — feeds the recent tier and find-or-create)
- A Rust toolchain (optional, recommended — builds the fast renderer; see
  [The Rust core](#the-rust-core-optional-recommended))

CI builds tmux 3.7b and installs fzf 0.74 rather than using the distro packages,
for exactly these reasons — see [docs/CI.md](docs/CI.md).

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'embe221ed/interdimux'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/embe221ed/interdimux.git ~/.tmux/plugins/interdimux
```

Add to your `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/interdimux/interdimux.tmux
```

Reload tmux:

```bash
tmux source-file ~/.tmux.conf
```

### The Rust core (optional, recommended)

The list is rendered by a small Rust binary when there is one, and by a bash
fallback when there is not. The fallback works, but it slows down as the list
grows — 1.7× slower at a dozen rows, 7.8× at five hundred — and it pads columns
by character count, so a CJK or emoji name shifts every column after it.

When `cargo` is on the tmux server's `PATH` (or in `~/.cargo/bin`, where rustup
puts it), the plugin builds the binary itself. Loading it — `prefix + I`, a
`tmux source-file`, a new server — starts `cargo build --release` in the
background whenever `rust/target/release/imux` is missing or older than its
sources. Nothing waits for it: tmux starts and the keys are bound while it
compiles, niced; the status line says when it is done or has failed, and the
output goes to `~/.local/state/interdimux/build.log` (`$XDG_STATE_HOME`). The
first build downloads one crate. A build that fails is announced once and not
repeated on every load: it is tried again when the sources or cargo change, or
quietly a day later, and `--doctor` names the failure meanwhile.
`set -g @interdimux-autobuild 'off'` stops it, and this is the same build by
hand (a retry at once, say):

```bash
cd ~/.tmux/plugins/interdimux/rust && cargo build --release
```

No cargo? Install Rust from [rustup.rs](https://rustup.rs), or use an `imux`
built elsewhere by naming it in the tmux server's environment (in
`~/.tmux.conf`, or run once):

```tmux
set-environment -g INTERDIMUX_BIN '/path/to/imux'
```

Rebuild that one whenever you update the plugin. A binary that speaks another
row protocol is refused: the list falls back to the bash renderer, and the
status line says so once, naming the binary. One built from older sources that
still speak the same protocol is not caught, and renders as that version did.

That is an environment variable, not a tmux option, on purpose: it chooses the
program every picker runs. `--doctor` says which binary the popups use, whether
the one in this checkout is older than its sources, and what to do when there
is none. More in [rust/README.md](rust/README.md).

## Usage

There are two entry points:

### Dashboard (`prefix + g`)

A menu that provides access to all features — rendered as a native tmux
menu (one keypress per action: `s`, `e`, `n`, `r`, `i`, `w`, `z`, `d`, `t`,
`a`, `o`, `h`), or, on a client too short for that menu, as a compact fzf menu,
where you type to filter and press `Enter` instead (`--doctor` says which one
your client gets):

- **Switch** (`s`) — Navigate & jump to target
- **Agents** (`e`) — The agents waiting on you, e.g. `Agents (2 need you)`:
  the navigator, opened on them, marked (see [Agents and pane titles](#agents-and-pane-titles))
- **New session** (`n`) — Create session from directory
- **Rename** (`r`) — Rename a session or window
- **Kill** (`i`) — Remove sessions, windows, or panes
- **Swap** (`w`) — Swap windows or panes
- **Zoom** (`z`) — Toggle pane zoom
- **Detach** (`d`) — Detach clients from session
- **Send keys** (`t`) — Send a command, or a key such as `C-c`, to a pane
- **Schedule** (`a`) — Run a command later, via `at`
- **Jobs** (`o`) — See and cancel scheduled commands
- **Health** (`h`) — Check the setup, like nvim's `:checkhealth`

In the native menu `Kill` is drawn in the danger colour, and an entry that
cannot do anything is greyed out and loses its key rather than opening a popup
to say so: `Agents` when no agent needs you and `Jobs` when nothing is queued
(each shows its count otherwise), and both scheduling entries when `at` is not
installed.

Select an action to launch the corresponding tool. Action modes open the navigator with a modified prompt — `Enter` performs the action on the selected target, and the list reloads in place so you can repeat. Press `Esc` when done.

### Navigator (`prefix + f`)

The fuzzy navigator for quick switching, with shortcut keys for power users:

| Key | Action |
|---|---|
| `Enter` | Switch to the selected target — or create a session named after the query when nothing matches. fzf's search syntax is left out of the name: `'docs`, `^docs`, `docs$` and `!docs` all name `docs`, and `my\ proj` (one term, an escaped space) names `my-proj`. A query with fzf's OR, `foo \| bar`, is a filter: it names no session, and `Enter` there closes the navigator without creating one |
| `Alt-Enter` | Create a session named after the query even when rows match (or switch to it, when a session has that name). A long command line — `kubectl logs -f deployment/payments-api …` — fuzzy-matches almost any short word, and `Enter` would switch to that pane instead. While a query is typed the bar names what `Alt-Enter` makes: `M-⏎ create docs` (fzf >= 0.63; the key itself works from 0.46). An empty query does nothing |
| `Ctrl-x` | Kill the selected session, window, or pane — killing a session with clients on it, yours included, first hops them to the most recent other session (no surprise detach). So does killing its last window or last pane, which closes the session too; the dialog says so before you answer |
| `Ctrl-e` | Rename the selected session or window (pre-filled with the current name) |
| `Ctrl-o` | Open directory picker to create a new session |
| `Ctrl-z` | Toggle zoom on the selected pane |
| `Ctrl-s` | Swap the selected window or pane |
| `Ctrl-d` | Detach clients from the selected session |
| `Ctrl-t` | Send a command to the selected pane — typed as text, then Enter. A text that is exactly one key name in tmux's spelling (`C-c`, `M-x`, `C-M-x`, `^x`, `Escape`, `Up`/`Down`/`Left`/`Right`, `PPage`/`NPage`, `BTab`, `F1`–`F12`) is pressed instead, with no Enter: `C-c` interrupts the program, in every pane of a window or session row. A pane scrolled back in copy-mode is taken out of it first, so the command runs |
| `Ctrl-]` | Cycle the match scope: name / path / cmd / all / name+cmd (fzf >= 0.58). The prompt names the active scope |
| `Ctrl-/` | Toggle preview pane |
| `Ctrl-r` | Reload the list |
| `Ctrl-n` / `Ctrl-p` | Next / previous match: in raw mode (fzf >= 0.74, below) they skip the dimmed rows that `Up`/`Down` stop on |
| `Esc` | Cancel |

The **hint bar sits at the bottom** and updates to show only the keybindings
that apply to the row you are on (session, window, or pane). It is at the bottom
because it is rewritten on every cursor move, and at the top that put moving text
exactly where the eye anchors while scrolling — lazygit, k9s and zellij all put
keys at the bottom for the same reason. It costs one list row, the same row the
old header was already spending.

It is also **tiered to the width available** rather than truncated. The full
session line is 73 cells and an 80-column terminal gives the bar about 61, so it
used to be cut from the right — which removed `^] scope`, the least discoverable
binding in the tool, first. Now the most obvious binding (`Enter`) is dropped
first and `^] scope` survives longest; below the narrowest tier the bar prints
nothing rather than something cut mid-word. It re-tiers live when you open the
preview or resize the client.

The popup title names the session you are in — the current row is marked in the
list, but that row scrolls out of view as soon as the list is longer than the
popup.

Two more things the picker does with what you can and cannot see:

- **The searchable columns are the bright ones.** With `Ctrl-]` on `name+cmd`
  (the default) the path column is dimmed; press `Ctrl-]` and the bright band
  moves to whatever the new scope matches. The prompt names the scope, but the
  rows show it. Turn it off with `@interdimux-scope-highlight 'off'`
  (needs fzf >= 0.66 — 0.65.1 fixed this exact pattern over coloured rows).
- **A long command scrolls without taking the row's identity with it.** Matching
  a token deep inside a full command line makes fzf scroll that row sideways;
  the identity column stays pinned, so you can still see which pane you are
  about to act on (needs fzf >= 0.67).

Sessions are listed most-recently-used first, with the **current session
last** — so opening the navigator and pressing `Enter` toggles to the
previous session, and the current session's windows are one `↑` away
(the list cycles). Set `@interdimux-order 'index'` to keep tmux's native
order instead.

Fuzzy queries match the identity column (session/window/pane names —
window and pane rows carry their session name, so `proj edit` finds the
editor window of the *proj* session) and the command column. Paths, git
badges, and metadata are visible but not matched — press `Ctrl-]` to
cycle the scope when you *do* want to search by path.

On fzf >= 0.74 the list filters in *raw* mode: a query dims the rows it does not
match instead of removing them, so the tree keeps its shape while you type, and
the cursor moves to the best match — and stays where it is when the list
reloads under it (`Ctrl-r`, the preview, a resize, a cancelled kill). With
nothing matched, `Enter` still creates a session from the query, and the other
action keys only say so. A dimmed row is never a target: `Up`/`Down` can still
move onto one, but `Enter` and the action keys then only say that it does not
match (`Ctrl-n`/`Ctrl-p` hop between the matches).
`set -g @interdimux-raw 'off'` gives plain filtering.

The session name on a window row is matched as it is *displayed*. A name
longer than 16 characters is shortened with `…`, and so is any name on a
popup too narrow for the rest of the row — the path and the branch badge
give way first, so that takes a genuinely narrow popup. Then type what you
see (`my-pr shell`). When a query matches nothing, the bar says what `Enter`
would create before you press it; when it matches something, what `Alt-Enter`
would.

When two rows match a query *equally well*, the list's own order decides. So an
existing session is picked ahead of a directory that is only being offered as a
new one — typing `circle` with a `circle/sui-cctp` session open goes there, not
into a fresh session made from a `Circle` directory — and a session is picked
ahead of its own windows. This is a tiebreak, not a rule that sessions always
win: a directory whose name is genuinely the better match is still picked first.

Any session name tmux will hold works here — `$1`, `my.app`, `c:d`, `a#Sb` —
for switching, previewing and killing alike, and a directory called `proj#Sync`
gives a session of exactly that name. Rename refuses two kinds of name that
tmux itself would take, because nothing could reach them by name afterwards
(`tmux attach -t` included): one containing `:`, where tmux splits a target, and
a session name starting with `$`, which tmux reads as a session ID.

### Numbered jumps (opt-in)

```tmux
set -g @interdimux-jump-keys 'M-1 M-2 M-3'
```

Binds one root-table key per position: `M-1` switches to session #1 in the
picker's own ordering, `M-2` to #2, and so on. Under the default MRU order #1
is the previous session, so this is a single keystroke to a fixed destination —
which is the point. A fuzzy query cannot promise that, and neither can a list
position that shifts as you type.

Off by default and you name the keys: claiming root-table keys in someone
else's tmux is not the plugin's to do. Note that a key you name is *taken* —
tmux offers no way to ask what it was bound to and restore it later.

The mode is also usable directly, for a different key layout or a different N:

```tmux
bind-key -n M-0 run-shell -b "TMUX_PANE=#{pane_id} INTERDIMUX_CLIENT=#{q:client_name} bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --jump 4"
```

`TMUX_PANE=#{pane_id}` is required, not decoration: `run-shell` passes the tmux
*server's* global environment, not the pressing client's pane, so without it
the "which session am I in" question — and therefore the numbering — can be
answered for the wrong session. `INTERDIMUX_CLIENT` does the same for the
client: with two terminals attached, the one you pressed the key on is the one
that moves, rather than whichever tmux last saw a key from.

### Directory picker (`Ctrl-o` / dashboard "New Session")

Creates (or switches to) a session from a directory. The list has three tiers:

- `★` recent — directories you created sessions from before (plus, when [zoxide](https://github.com/ajeetdsouza/zoxide) is installed, your most frecent zoxide dirs)
- `◆` projects — directories containing a project marker (`.git`, `package.json`, `Cargo.toml`, `go.mod`, …)
- `·` plain directories

A directory that already has a session is marked `▸` and shows which one, so
`Enter` there is visibly a switch rather than a create. A session belongs to the
directory it was started in, whatever it is called and even after you `cd`
somewhere else inside it:

```
  ▸  ~/code/api          → api
  ★  ~/code/worker
  ◆  ~/code/tools        Rust
```

By default the configured project directories (see `@interdimux-project-dirs`) are scanned one level deep. To go deeper:

| Key | Action |
|---|---|
| `Enter` | Create a session from the selected directory (or switch to it if one exists) |
| `Ctrl-f` | Deep search — re-scan using the current query. Path-style queries (`work/api`, `~/Desktop/proj`, `/abs/path`) are resolved as paths, including partially typed ones; name fragments (`aftermath`) match directory names case-insensitively at any depth (up to 2× scan depth). `~/Library` is skipped when searching from `$HOME`. The query is cleared once the results load, so every match is visible even when its displayed path is shortened |
| `Ctrl-g` | Browse into the highlighted directory |
| `Ctrl-r` | Reset to the default view |
| `Esc` | Cancel |

When a query matches nothing the prompt says so and points at `Ctrl-r`, so a
fruitless deep search is not a blank panel with no visible way back.

The preview shows project type, git branch/status/last commit, a README excerpt, and the directory contents. Session names are derived from the directory basename; when two projects share a basename, the new session is disambiguated with the parent directory name.

On a network or FUSE mount (see [Tree display](#tree-display)) a directory goes
without its type badge, and a recent one is offered without checking that it
still exists, so one stalled mount cannot hold up the list.

### Tree display

```
  ▸ my-project ─────────────────────────────────────────── 3 win ● 2h
* ├─ my-project 0:editor   │ ~/code/proj  Z ‹feature-x›    nvim main.c
  ├─ my-project 1:shell    │ ~/code/proj    ‹feature-x›    zsh
  └─ my-project 2:remote   │ ~/code/proj                   ssh user@host
    ├╴ my-project 2.0      │ ~/code/proj                   tail -f app.log
    └╴ my-project 2.1      │ ~/code/proj                   zsh
  ▸ other-session ──────────────────────────────────────── 1 win 3d
  └─ other-session 0:main  │ ~                             zsh
```

- `▸` session header with window count, attached marker `●`, and last-used age
- The rule after a session name is the **group separator** — a flat list has no
  other way to show where one session's windows end. It costs no extra rows: it
  is the padding that was already there, and it ends where the command column
  begins, so a session's metadata lines up with its windows' commands. It turns
  itself off on a popup too narrow to have a command column, and entirely with
  `@interdimux-session-rule 'off'`
- `├─` / `└─` tree branches for windows; `├╴` / `└╴` for panes
- Window/pane rows carry their (dimmed) session name, so rows stay
  identifiable while filtering and compound queries work
- `*` marks the current target
- `‹branch›` git branch badge (purple) for directories inside a git repo.
  Not on a network or FUSE mount (NFS, SMB, sshfs, 9p over the network, an
  automount point) other than the one your `$HOME` is on, directly or through
  a symlink: nothing there is probed before the list paints, because one
  stalled mount would otherwise freeze the popup for its timeout. Directory
  rows there also go without their type badge, and are offered without
  checking that they still exist. WSL2's `/mnt/c` is 9p to the local disk,
  not the network, and keeps its badges
- `Z` / `!` / `#` flags mark zoomed, bell, and activity windows, in a column
  of their own right after the path: a narrow popup can drop the branch badge,
  never the flags
- SSH and mosh rows name the host they connect to, `user@host` highlighted in
  blue — not a flag's value or a remote command after it
  (`ssh -p 2222 deploy@web1 tail -f app.log` reads `ssh deploy@web1`)
- Editors show the filename highlighted in green
- The command is the one in the pane's foreground — a job you backgrounded does
  not hide it, nor does a shell you started inside the pane's own (`bash`, then
  `make` in it, reads `make`) — and it is named, not pathed: `python3 tool.py`,
  not `/usr/bin/python3 /home/me/bin/tool.py`
- An idle shell is just its name (`zsh`, not `-zsh`) in the tree colour, so
  the rows where something is running are the ones that stand out
- Panes only shown for multi-pane windows
- Column widths adapt to the content and the popup width. When a row does not
  fit, what you only read gives way before what you type: the path shrinks
  (to 24 cells) to keep the branch badge, then the badge narrows (to 14, then
  10 cells), then it goes, then the path shrinks to 12 cells, and only then the
  session prefix and, last, the window name

### Agents and pane titles

tmux's own tree (`prefix + w`) shows the title a program gave its pane, which
is how it can say what a Claude or Codex pane is working on. interdimux reads
the same title — and two better sources of *state* — and puts both in the
command column, as plain words you can search for:

```
* ├─ work 0:claude   │ ~/code/app                claude ∣ working 2m ∣ Project review and suggestions
  ├─ work 1:codex    │ ~/code/app/src            codex ∣ approve ∣ Add tests
  │ ├╴ work 1.0      │ ~/code/app/src            codex ∣ working ∣ Fix login timeout
  ├─ work 2:prod     │ ~                         ssh web1 ∣ deploy@web1: ~/src
  └─ work 3:shell    │ ~                         zsh
```

The parts — the command, the state with its age, the description — are set
off by a short bar in the separator colour, and a part that is not there takes
its bar with it. The bar is `∣` (U+2223): your font draws it in its own weight
(JetBrains Mono, Ghostty's built-in font, does, as do Maple Mono, Hack,
DejaVu Sans Mono and Iosevka), and it is shorter than the `│` column rule.
`@interdimux-agent-separator` takes any other, up to three characters:
`❘` (U+2758) looks much the same but is missing from most coding fonts, so
the terminal borrows it from a fallback font, heavier and off-centre; `·` is
in every font; `off` leaves a blank alone.

- **Agents are named by what they are.** An npm or pip install runs as
  `node …/bin/codex` or `python …/bin/aider`, a package's own file as
  `node …/codex/bin/codex.js`, and `npx @google/gemini-cli` as npx itself
  (npm starts the agent under it); the row says `codex`, `aider`, `gemini`.
  Recognised: claude, codex, gemini, qwen, opencode, amp, goose, crush,
  kiro-cli, aider, copilot, cursor-agent — add your own with
  `@interdimux-agents`. This reads the process's arguments, so with
  `@interdimux-show-full-command 'off'` an npm-installed agent is just `node`,
  with no state from its title. `@interdimux-agents off` turns the naming off, and
  only that: rows keep their whole command line, and a state or description
  still follows it (`codex 2400 ∣ approve ∣ Fix the build`). Title rules go by the
  command's name, so a native `codex` keeps its state while
  `node …/bin/codex` — `node` to the rules — has none. With
  `@interdimux-agent-state` and `@interdimux-show-title` off as well, rows are
  what they were before any of this.
- **A state word, with its age** (from a minute on): `approve` (a permission
  waits — in the danger colour), `input` (a question or dialog is open),
  `working`, `idle`, `done`, `error`. Typing `approve` finds those rows — and
  any title or name with the word in it; for exactly the agents waiting on
  you, use the dashboard.
- **The dashboard counts them.** `prefix + g` shows `Agents (2 need you)` —
  the panes in `approve` or `input`, by the same rules as the rows, each pane
  once however many sessions show it — and its `e` opens the navigator on
  them. Each one's row is marked in the gutter, where `*` marks where you are:
  `!` for `approve`, `?` for `input` (one row per pane: the pane's own row
  where its window lists panes). The query `^! | ^?` is typed for you, and it
  matches exactly those rows: the cursor starts on the first of them, raw mode
  keeps the rest of the tree on screen, and editing the query searches as
  usual — while it still holds `^!`, `^?` or `|` it creates no session. With
  none waiting the entry is greyed out.
- **The description** is the agent's title with its status glyph and
  boilerplate removed. An agent row that shows a state or a description drops
  its arguments (`--resume <uuid>` …); the preview (`Ctrl-/`) names the agent
  the same way and has them on the line under its header
  (`codex resume 0199…`). `@interdimux-agent-args on` keeps them on the row.

Where the state comes from, first source that speaks wins:

1. **Claude Code's own session registry** (`~/.claude/sessions/<pid>.json`):
   busy / waiting (and for what) / idle, with no hooks or setup. On Linux the
   record is believed only while its pid is still that process (its start
   time) and runs in that pane. Without `/proc` (macOS) only that its pid is
   alive is checked, so a record whose pid was reused, or one for the same
   pane id on another tmux server, can put a state on a row there (not on a
   shell at its prompt). Claude's title cannot say this under tmux: its glyph
   is always `✳` there.
2. **Pane options other agent plugins publish** — read in the same single tmux
   query, no extra process. Built in: interdimux's own `@agent_state` /
   `@agent_desc`, [tmux-agent-sidebar](https://github.com/hiroppy/tmux-agent-sidebar)
   (`@pane_status`, `@pane_wait_reason`), tmux-agent-icons (`@claude_state`,
   `@codex_state`, `@opencode_state`), tmux-claude-status
   (`@claude_pane_status`), workmux (`@workmux_pane_status`), dmux
   (`@dmux_attention`). Anything that can run `tmux` can publish one — a
   hook, or a wrapper around a tool that has no state of its own:
   ```sh
   #!/bin/sh
   # my-agent, saying so in its pane; the state goes however it ends
   trap 'tmux set -pu -t "$TMUX_PANE" @agent_state' EXIT
   trap : INT
   trap 'exit 143' TERM
   trap 'exit 129' HUP
   tmux set -p -t "$TMUX_PANE" @agent_state working
   my-agent "$@"
   ```
   tmux keeps a pane option until something unsets it, and a state shows on
   whatever runs in the pane next (only a shell at its prompt shows none):
   a `set … done` at the end would be seen only on the *next* program, as
   would a `working` that Ctrl-C left behind. So the wrapper unsets it on
   the way out, and the other traps are what make that run whichever way it
   ends (dash, the `sh` of Debian and Ubuntu, skips an EXIT trap when a
   signal kills it): Ctrl-C goes to `my-agent`, which may only interrupt a
   turn, and the wrapper waits for it and exits with its status. A hook that
   publishes a state should clear it the same way when its agent ends.
   (`@agent_state` takes the words above; `@agent_desc` any text, shown as
   it is: the filters below are for titles, which can be stale or a copy of
   the command line, and only a description that is just the app's name is
   left out.)
3. **The title**, by per-app rules (below): codex's `[ ! ] Action Required`
   is `approve` and its spinner `working`; gemini's `✋` / `✦` / `◇`, qwen's
   `✳` / `◐`, amp's spinner and `◆` likewise. A title rule is chosen by the
   app, because the same glyph means different things: `✳` is Claude's
   constant mark but Qwen asking for approval.

**Other apps.** A few apps are a terminal *somewhere else*, and the title they
pass on says where — which neither the command (`ssh web1`) nor the directory
(where you started it) can. These show it by default:

```
  ├─ ops 0:web1      │ ~                         ssh deploy@web1: ~/app
  ├─ ops 1:db        │ ~/code/app                docker root@3f2a9c1b: /var/lib
  └─ ops 2:inner     │ ~                         tmux inner:0:edit
```

- `ssh`, `autossh`, `et` — the remote prompt: `user@host: ~/path` (the
  Debian and Ubuntu bashrc), `user@host:~/path` (Fedora, Arch, oh-my-zsh),
  fish's `[host] ~/p/dir`, or a remote tmux with `set-titles on`. `mosh-client`
  — the same, without mosh's `[mosh]`. ssh passes on your pane's `TERM`, and
  the Debian, Ubuntu and Fedora bashrc title only `xterm*` ones: with tmux's
  default `tmux-256color`, those hosts set no title.
- `docker`, `podman`, `nerdctl`, `kubectl`, `oc`, `lxc`, `incus`,
  `machinectl`, `toolbox`, `multipass` — the container's prompt
  (`docker run -it` gives the container `TERM=xterm`, so a stock Ubuntu image
  titles itself).
- `screen` — a prompt from another host that it passes on; `tmux` — a nested
  client's `session:index:window`, when its server has `set-titles on`.

Only these apps, and only those shapes, are read, because a title outlives the
program that set it when your shell sets none (plain bash under
`tmux-256color`). That keeps a gone container's prompt off the rows of other
apps (htop, vim…), and vim's or a preexec hook's leftovers off these. It
cannot keep a leftover *prompt* off the next ssh or docker row, though: until
the new host or container titles the pane, that row shows the one that has
gone. A shell that titles its own prompt fixes it — oh-my-zsh and fish do;
for bash, the line Debian's bashrc uses for `xterm*` terminals:

```sh
PS1="\[\e]0;\u@\h: \w\a\]$PS1"
```

That title is a prompt of *this* host, which no row shows (below). Most other
apps set no title (htop, less, lazygit, ranger, python…), editors set one only
with `set title` (and it names the file the row already shows), and yazi's or
mc's is the directory, which they change to, so the directory column already
has it.

A title no rule knows is not shown — on an agent's row too: an agent that
sets no title (aider, or one you add with `@interdimux-agents`) would show
whatever the last program left in the pane as its task. The agents that title
themselves have rules; for your own, add one (`myagent - = *` shows its whole
title). Nor is a title shown that repeats the row: tmux's default (the host
name), a prompt of *this* host (`user@thishost:…`, fish's `[thishost] …`) and
a preexec hook's copy of the command line. `@interdimux-show-title all` shows
every other title, the way `prefix + w` does.

#### From a status line, a script or a key

`--agents` prints the agent panes, by the same rules as the rows, most urgent
first — `approve`, `input`, `error`, `done`, `working`, `idle`, then an agent
with no state — and within a state the one that has been in it longest first:

```sh
$ bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --agents
%12	=work:=1.0	claude	approve	1790001200	Fix the parser
%15	=work:=2.0	codex	approve	-	Add tests
%9	=api:=0.1	claude	working	1790001500	Review the API
```

One line per pane (once, however many sessions show it, and none from a session
`@interdimux-hide` keeps out), with six tab-separated columns: the pane id, a
target for it, the agent, its state, since when (in epoch seconds; only Claude's
registry says), and its description as the row has it (but never cut short).
`-` is a value nothing gave. The columns keep their places: a new one only ever
goes at the end.

States, comma-separated, keep only those panes (`--agents approve,input`), and
`--count` prints how many, so a status line can say what the dashboard says —
Claude's state included, which no tmux format can see:

```tmux
set -ag status-right ' #(bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --agents --count approve,input)'
```

That is one bash and three short tmux calls every `status-interval` (its
version, the options and the panes; only the last is as big as your server),
and fzf is not needed.

`--agent-next` switches to the next agent that needs you (`approve` or `input`,
or the states you give it), with no popup: from anywhere else the first in that
order, and from one of them the one after it, so pressing it again visits each
in turn. With none, the status line says so. It is a key once you name one:

```tmux
set -g @interdimux-agent-next-key 'a'    # prefix + a
```

#### Title rules

Rules are lines of `APPS STATE DESC PATTERN`, in a file
(`@interdimux-title-rules`, default `~/.config/interdimux/titles`) that is read
before the built-in ones, so yours win:

```
# APPS (command names, comma-separated, or *)  STATE  DESC  PATTERN
nvim      -        $1   * - Nvim
myagent   approve  $1   [?] *
myagent   working  $1   %spin *
# @OPTION rules read a pane option instead of the title
@my_state approve  -    blocked
```

- `PATTERN` is literal text matched against the whole title; each `*`
  captures, greedily from the left. A leading `%spin` matches one braille
  spinner character.
- The file is UTF-8. A line that is not (a Latin-1 `é`, say) is skipped, and
  only that line; `--doctor` names it.
- A rule sees a title's first 256 characters. The program in a pane chooses
  its title (tmux keeps one of up to a megabyte), and a row shows at most 200
  characters of it, so a longer one is cut there before anything reads it.
- `STATE` is a word (approve input working idle done error) or `-`. Any
  other word, `Approve` included, counts as `-`: the rule still matches and
  still gives its `DESC`, but no state (`--doctor` names such lines).
- `DESC` is `-` (show nothing), `=` (the whole title) or a template such as
  `$1` or `$2: $1`.
- The first title rule that matches decides. Among `@option` rules, the first
  that gives a state gives it, and the first that gives a description gives
  that. An `@option` named in your file is added to the tmux query by itself.
- Window-scoped plugin options are not read by default — tmux resolves them
  for every pane of the window, so the state would show on the agent's
  neighbours too. To read them anyway:
  ```
  @ccm_prev_state      working  -  BUSY
  @ccm_prev_state      approve  -  PERMIT
  @ccm_prev_state      done     -  DONE
  @agent_status_state  approve  -  blocked
  @workmux_status      approve  -  💬
  @codex_attention     done     -  1
  ```

The built-in rules are `DEFAULT_TITLE_RULES` in `scripts/interdimux.sh`. Some
that are not, because they help only some setups:

```
# nvim / vim with `set title`: the buffer and its directory
nvim            -  $1  * - Nvim
vim,vi          -  $1  * - VIM
# zellij: its session name, then | the focused pane's title
zellij          -  =   *
# fish in a container (no SSH_TTY): the path alone
docker,podman   -  =   /*
docker,podman   -  =   ~*
# `sudo docker ...`: the row is sudo
sudo            -  =   *@*:*
```

## Checking your setup

**`prefix + g`, then `h`** — the Health entry pages the report in a popup, `^r`
re-runs the checks after you fix something, `Esc` closes. Or from a shell:

```sh
bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --doctor
```

It opens with the verdict, because in a popup the first line is the one you
actually read:

```
interdimux doctor                                    23 ok, 2 warn, 1 problem
────────────────────────────────────────────────────────────────────────────
1 problem needs attention
```

Reports what tmux, fzf and interdimux itself can see: versions and the features
they gate, whether the Rust helper is built *and newer than its sources* (and if
not, the command that builds it — or, with no cargo, where to get one), whether
the key bindings are actually installed, and set up for the fzf the popups run
now (after a new fzf, reload the plugin), whether the state directories are
writable, whether your locale is UTF-8 (the tree glyphs and every column width
assume it), whether `sort -s` works (the session order is stable and locale-free
only because of it), whether fzf accepts your `$FZF_DEFAULT_OPTS` — one flag it
does not know stops every picker, while its layout flags and a `--preview` are
harmless, because the pickers reset them — and which of the two dashboards your
client is tall enough for. Plus every `@interdimux-*` option you have set, with
its value checked: a value the plugin cannot use is replaced, not fatal, and the
report names what it uses instead (`@interdimux-agent-state 'yes'` stays on,
`@interdimux-title-max '500'` is 200, a word of `@interdimux-agents` that is
not a name is skipped).

That last part is the one worth running. tmux user options are free-form, so a
mistyped name is not an error to tmux — the setting simply never applies, with
nothing to tell you why:

```
✗ unknown option @interdimux-fzf-opt — did you mean @interdimux-fzf-opts?
✗ @interdimux-order = 'recent' — expected 'mru' or 'index'
✗ @interdimux-color-accent = '#ab' — a hex colour must be #rrggbb
```

Exits non-zero if anything is wrong, so it works in a health check.

The environment it checks is the one the popups get: the tmux server's `PATH`
(and the fzf and bash on it, versions included), locale, `$FZF_DEFAULT_OPTS`
and `INTERDIMUX_BIN`, not your shell's. The two differ exactly when it matters —
fzf on `PATH` only through a shell rc, a distro's old fzf ahead of the one you
installed, a UTF-8 locale that is named but not installed — so run from a
shell, it says which one it read.
`interdimux.sh --help` lists the other command-line modes, and `--version` prints
the version; an argument that is not a mode is refused with exit status 2
rather than opening the navigator.

It is also where past failures surface. The navigator sends its stderr, and
that of the list reloads and dialogs it runs, to the status line and to
`$XDG_STATE_HOME/interdimux/errors.log` rather than to the popup — anything
written to a popup's stderr is painted over the rendered rows and then vanishes
with the popup, which is how several silent failures stayed silent. `--doctor`
reports the log and quotes the most recent entry, dated. Once you have dealt
with what it logged, `interdimux.sh --doctor --ack` marks it as seen: `--doctor`
then mentions it as a warning and fails again only on a newer entry. Past
64 KB the log keeps its newest 50 entries. A picker that fails outright
— fzf missing from the tmux server's `PATH`, an option fzf refuses, a crash —
keeps its popup open with the error on it until you press a key, where it used
to flash shut and leave `prefix+f` looking dead.

A hide pattern that matches no session is called out too, and so is one whose
only match is the session you are in — that one never gets hidden, so the pattern
is doing nothing. `@interdimux-hide` is free-form, so a typo in it looks exactly
like a pattern whose session simply is not running: the list looks normal either
way.

The **agents** section says which of the signals a coding agent sends actually
reach tmux, and the one setting that fixes a missing one. Otherwise the way to
find out is to miss an approval prompt:

```
⚠ Claude's notifications go to Ghostty through tmux passthrough — tmux never sees them
    preferredNotifChannel is not set (auto) and the panes' TERM is xterm-ghostty, so Claude sends OSC 777 wrapped for passthrough
    allow-passthrough is on: only a pane on screen gets through — a background agent's alert is dropped
    to have tmux flag the window instead: "preferredNotifChannel": "terminal_bell" in ~/.claude/settings.json
    or: set -g allow-passthrough all — but then any hidden pane can write to your terminal
⚠ Codex never notifies inside tmux — focus-events is off, so it never hears that its pane lost focus
    set -g focus-events on — or in ~/.codex/config.toml, under [tui]: notification_condition = "always"
```

It looks at tmux's `allow-set-title` (titles), `monitor-bell` (the `!` a bell
leaves on a row), `allow-passthrough`, `focus-events` and `default-terminal`;
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE` in tmux's environment or Claude's
settings; Claude Code's session registry (how many records parse, and which are
live sessions in a pane here); `preferredNotifChannel` and `hooks` in
`~/.claude/settings.json`; the `[tui]` notification keys in
`~/.codex/config.toml`; which agent plugins publish state, on how many panes;
and your title rules file, naming any line that is not a rule or not UTF-8
(and a NUL, which ends what is read of a UTF-16 file). An agent that is
not installed is one dim line. It only reads: no agent is started, no option
value is shown, and no credential file (`~/.codex/auth.json`,
`~/.claude/.credentials*`, the registry's `.key` files) is opened. A config it
cannot read, or a value it does not know, is reported as unknown, never as
wrong, since agents change their settings between versions. These checks are
advice: they warn, and never change the exit status.

## Configuration

All options are set via tmux options in `~/.tmux.conf`:

```tmux
# Navigator key binding (default: f).  Any key tmux can bind: C-f, M-g, F5 …
set -g @interdimux-key 'f'

# Dashboard key binding (default: g)
set -g @interdimux-dashboard-key 'g'

# Numbered jumps: one root-table key per session position, in order.
# Off by default.  (default: unset)
set -g @interdimux-jump-keys 'M-1 M-2 M-3'

# A prefix key that switches to the next agent that needs you (--agent-next,
# see "From a status line, a script or a key").  Off by default, and never
# bound over the navigator's or the dashboard's key.  (default: unset)
set -g @interdimux-agent-next-key 'a'

# Keep sessions out of the list: space-separated glob patterns matched
# against session names.  The session you are currently in is never
# hidden, and a hidden session is still reachable by typing its exact
# name (nothing matches, so find-or-create switches to it).
# (default: unset)
set -g @interdimux-hide 'scratch floax-*'

# Popup dimensions (default: 80% x 75%)
set -g @interdimux-popup-width '80%'
set -g @interdimux-popup-height '75%'

# Preview pane (default: off — toggle in-session with Ctrl-/)
set -g @interdimux-show-preview 'off'

# Show full command line with arguments (default: on)
# Set to 'off' to show only the command name (faster for many panes).  Agents
# installed with npm or pip then show as node / python, without a state.
set -g @interdimux-show-full-command 'on'

# Show git branch in tree display (default: on)
set -g @interdimux-show-git-branch 'on'

# Draw the group rule after a session name (default: on).  Costs no extra
# rows, and switches itself off on a popup too narrow to keep a command
# column.  'off' restores the plain session header row.
set -g @interdimux-session-rule 'on'

# Dim the columns the current Ctrl-] scope does NOT search (default: on,
# fzf >= 0.66).  All-or-nothing: fzf cannot re-issue colours mid-session,
# so at the default 'name+cmd' scope the path column is permanently faint.
set -g @interdimux-scope-highlight 'on'

# Session ordering: 'mru' (most recently used first, current session
# last) or 'index' (tmux native order)  (default: mru)
set -g @interdimux-order 'mru'

# Raw filtering (fzf >= 0.74): a query dims the rows it does not match
# instead of hiding them, so the tree keeps its shape (default: on)
set -g @interdimux-raw 'on'

# Extra fzf flags appended to every picker (advanced; applied after the
# built-in theme so your colors win).
#
# This is also the place for fzf colors and layout: the pickers ignore the
# colors in $FZF_DEFAULT_OPTS (so your shell's fzf theme does not blend into
# this palette) and its --tmux/--popup, --height, --border, --margin,
# --padding and --style (they already run in a sized popup), and its --preview
# and a `hidden` preview window (the pickers that preview bring their own).
#
# Two notes now the hints live at the bottom: your own `--header` no longer
# replaces them, it draws as well — so the picker spends a second chrome row.
# And a `--with-shell` of your own turns off the inline callbacks, which costs
# a process per cursor move (see docs/PERFORMANCE.md); everything still works.
set -g @interdimux-fzf-opts '--color=bg+:237'

# Colon-separated list of directories to search for new sessions (ctrl-o)
# Defaults to ~/projects:~/code:~/src:~/repos:~/work:~/dev (whichever exist)
# A session can have its own: set -t SESSION @interdimux-project-dirs '...'
set -g @interdimux-project-dirs '~/projects:~/work'

# Max entries shown in the recent tier of the directory picker (default: 10)
set -g @interdimux-recent-limit '10'

# How deep the directory picker's deep search (ctrl-f) scans (default: 3)
set -g @interdimux-scan-depth '3'

# Merge zoxide results into the recent tier when zoxide is installed (default: on)
set -g @interdimux-use-zoxide 'on'

# Re-run the deep search automatically as you type, instead of on ctrl-f
# (default: off).  The scanner does the matching in this mode — fzf's own
# fuzzy filtering is disabled so no result is hidden by path shortening.
set -g @interdimux-dirs-live-search 'off'

# Colon-separated extra project markers, added to the built-in list
# (.git, package.json, Cargo.toml, go.mod, ...).  A path such as
# .github/workflows works too; an empty entry (a doubled ':') is ignored.
set -g @interdimux-project-markers 'Move.toml:deno.json'

# Show recent/zoxide directories inline in the navigator as dim '+ name'
# rows, so Enter opens a project whether or not it already has a session
# (default: on).  They are listed after the tmux tree and never delay it.
set -g @interdimux-show-dirs 'on'

# How many directory rows to show (default: 15)
set -g @interdimux-dirs-limit '15'

# Run a startup command in sessions interdimux creates (default: on)
set -g @interdimux-hydrate 'on'

# Fallback startup command, used when nothing more specific matches
set -g @interdimux-startup-command 'nvim .'

# Agent rows (see "Agents and pane titles").  Which pane titles to show:
# 'known' (those a title rule knows, an agent's included), 'all' (every title
# that adds something, as prefix+w does) or 'off'  (default: known)
set -g @interdimux-show-title 'known'

# Longest description shown, in characters: 8 to 200 (default: 40)
set -g @interdimux-title-max '40'

# A state word on agent rows, from Claude's registry, plugin options and
# titles (default: on)
set -g @interdimux-agent-state 'on'

# Keep an agent row's arguments when it shows a state or description; they
# stay with its name, `codex resume ∣ approve ∣ Add tests` (default: off)
set -g @interdimux-agent-args 'off'

# What sets an agent row's parts apart, up to three characters, or 'off' for
# a blank alone (default: ∣)
set -g @interdimux-agent-separator '∣'

# More agent names, space-separated, recognised as agents (their titles show
# only with a title rule for them); 'off' recognises none, so rows keep their
# whole command -- states still show, see "Agents and pane titles"
# (default: unset)
set -g @interdimux-agents 'myagent'

# Your title rules file (default: ~/.config/interdimux/titles)
set -g @interdimux-title-rules '~/.config/interdimux/titles'

# Where Claude Code keeps its config, when not ~/.claude or $CLAUDE_CONFIG_DIR
# as the tmux server sees it (default: unset)
set -g @interdimux-claude-dir '~/.claude'

# Build the Rust core in the background when the plugin loads, if cargo is
# available and the binary is missing or older than its sources (default: on).
# See "The Rust core" under Installation.
set -g @interdimux-autobuild 'on'
```

### Scheduled keys

Send a command to a pane at a future time. As with `Ctrl-t`, the command is
typed and then Enter is pressed, unless it is exactly one key name in tmux's
spelling (`C-c`, `M-x`, `Escape`, `Up`, `F5`, …): that key is pressed, with no
Enter, so `--send-in 600 %5 C-c` interrupts whatever still runs there in ten
minutes. Words that only look like keys (`Enter`, `Home`, `c-c`, `C-c C-c`)
are typed.

**From the dashboard:** `prefix + g`, then `a`. Pick the target in the usual
picker, type when, type the command. A window or session row narrows to that
window's *active* pane — a scheduled command fires into one pane, never
broadcast, because a fan-out you are not watching two hours later is a
different thing from one you are.

The confirmation screen shows the **resolved** absolute time, which is the
detail that matters: `1:10am` is tomorrow, and so is `13:00` typed at 13:31.
Press `u` there to undo. `prefix + g`, then `o` (Jobs) lists what is pending
and cancels with `Enter`.

The time field takes anything `at` understands, plus a relative shorthand:

| Typed | Means |
|-------|-------|
| `30s` `5m` `2h` `1d` | that far from now |
| `90` | 90 **minutes** (a bare 1–3 digit number is minutes) |
| `1730` | 17:30 — four digits are `at`'s own `HHMM` |
| `17:30` `1:10am` `noon tomorrow` `now + 2 hours` | passed to `at` verbatim |

The shorthand does not shadow anything `at` accepts: `at` rejects a bare
one-to-three digit number outright, and reads four digits as a clock time. If
`at` refuses the time, the field reopens with what you typed and **keeps the
command**, so a typo costs one keystroke rather than the whole entry.

**From the command line:**

```sh
# absolute or relative times — anything `at` understands
interdimux.sh --send-at "17:30"          '=work:1.0'  'make deploy'
interdimux.sh --send-at "now + 2 hours"  %5           'git pull'

# --send-in takes seconds; under a minute it uses tmux's own timer,
# because `at` has a hard one-minute floor
interdimux.sh --send-in 30  .  'echo back from lunch'

interdimux.sh --sched-list          # what's pending
interdimux.sh --sched-cancel 42     # drop one
```

The target is any tmux target (`%5`, `work:1.0`, `=name:`) or `.` for the
current pane, resolved to a pane id at submit time. `.` needs `$TMUX_PANE`,
so from cron or an ssh command it is refused: name the target there. If that
pane is scrolled back in copy-mode when the command fires, it is taken out of
copy-mode first, so the command runs instead of being read as copy-mode keys.

**Jobs refuse to fire if the tmux server has restarted.** Pane ids are recycled,
so `%0` after a restart is somebody else's pane — a scheduled `make deploy`
landing there is data loss, not a cosmetic bug. Each job records the server pid
and skips (with a message) rather than misfire.

Two more things worth knowing. interdimux uses its own `at` queue, so
`--sched-list` and `--sched-cancel` can never see or delete your unrelated `at`
jobs. And job output goes to
`~/.local/state/interdimux/scheduled.log` — the `at` daemon (`atd` on Linux,
`atrun` on macOS) mails it otherwise, which on a box with no MTA means it is
destroyed and the job merely *looks* like it never ran.

Sub-minute jobs use `run-shell -d`, which lives inside the tmux server: they are
lost if the server exits. `at` jobs outlive it, but only as queue entries: the
check above makes them skip once tmux has restarted, so after a reboot clear
them from Jobs and schedule them again.

`at`-backed jobs (anything ≥ 1 minute) only fire if the OS `at` daemon is
running. **macOS ships `atrun` disabled by default**, so a freshly scheduled job
queues but never runs; enable it once with
`sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.atrun.plist`
(Linux: `sudo systemctl enable --now atd`). Run `--doctor` to check — it reports
whether the job-runner is active.

### Startup commands

A session created by interdimux — from a directory row, from the `ctrl-o`
picker, or by find-or-create — can run a command as soon as it opens.
The first match wins:

1. **`~/.config/interdimux/startup.conf`** — `<glob><whitespace><command>`,
   one per line, `#` comments allowed. Put specific patterns first:

   ```
   ~/work/api*        make dev
   ~/code/*-cli       cargo watch -x run
   ~/notes            nvim index.md
   ```

   The pattern is matched against the directory's absolute path. A leading
   `~/` (or a bare `~`) means your home directory; nothing else is expanded, so
   `$HOME`, other variables and `~user` stay literal text. `*` also matches `/`,
   so `~/code/*-cli` matches `~/code/a/b-cli` too. When a line contains a TAB,
   everything before the first TAB is the pattern, so a pattern can contain
   spaces (`~/My Projects/*`, then a TAB, then the command); without a TAB the
   pattern ends at the first space.

2. **`.interdimux-startup`** in the directory itself — its contents are the
   command. Multiple lines are sent as separate commands, so this doubles as a
   small bootstrap script:

   ```sh
   nvim .
   ```

3. **`@interdimux-startup-command`** — the global fallback above.

The command is delivered with `send-keys`, so it appears at the prompt and
lands in your shell history exactly as if you had typed it. Every line is
typed: unlike `Ctrl-t`, a startup line that happens to be a key name such as
`C-c` is not pressed. interdimux waits
for the new shell to finish initialising first, so nothing is echoed before
your prompt appears. Set `@interdimux-hydrate off` to disable.

A directory can also be bound straight to a key, skipping the picker:

```tmux
bind-key C-a run-shell -b "TMUX_PANE=#{pane_id} INTERDIMUX_CLIENT=#{q:client_name} \
  bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --connect-dir ~/code/api"
```

(The two variables are the ones the [numbered jumps](#numbered-jumps-opt-in)
example explains.)

### Colors

Every color is a tmux option. A value is a hex `#rrggbb`, a 256-color
index (0-255), or `-1` / `default` (inherit the terminal); anything else is
treated as `-1`, so a typo costs a color, not the picker, and `--doctor` names
it. The defaults reproduce the built-in warm palette, so you only set what you
want to change. Hex values render as truecolor and need an RGB-capable terminal
(`$COLORTERM` = `truecolor`); the index defaults work everywhere.

The block below is an example, not the defaults: a gruvbox-material theme in
truecolor. Each line ends with the default it replaces, a 256-color index.

```tmux
set -g @interdimux-color-accent  '#e78a4e'  # commands, marker, hint keys, prompt, titles, menu selection (173)
set -g @interdimux-color-path    '#d8a657'  # paths, fzf match highlight (180)
set -g @interdimux-color-git     '#d3869b'  # ‹branch› badge (140)
set -g @interdimux-color-ssh     '#7daea3'  # ssh host, activity flag (109)
set -g @interdimux-color-editor  '#a9b665'  # editor filename, ● attached marker (150)
set -g @interdimux-color-success '#a9b665'  # ✓ marks, project-dir ◆ (150)
set -g @interdimux-color-danger  '#ea6962'  # kill accents, bell flag, danger border (167)
set -g @interdimux-color-tree    '#6b665f'  # tree glyphs, idle shells, fzf info (240)
set -g @interdimux-color-separator '#504945' # the │ column separator (245)
set -g @interdimux-color-query   '#ddc7a1'  # typed query text (223)
set -g @interdimux-color-match-current '#e78a4e' # highlight on the current row (215)
set -g @interdimux-color-current-bg '#32302f'    # current-line background (236)
set -g @interdimux-color-header  '#8d877d'  # fzf header text (246)
set -g @interdimux-color-border  '#504945'  # fzf borders / scrollbar (238)
set -g @interdimux-color-menu-sel-fg '#282828'   # dashboard menu selection text (235)
```

These pair with the popup border, which inherits your
`popup-border-style` / `popup-border-lines`. If you generate your dotfiles
with a theming tool, emit these options from your palette so interdimux
re-themes (light or dark) alongside the rest of your setup.

## TODO
- [ ] implement plugins system to define custom actions
  - [ ] once implemented, convert current actions to plugins system
- [x] fix issue with input popup (e.g. for rename) - rendered popup breaks once all characters are removed

See [docs/IDEAS.md](docs/IDEAS.md) for the researched UX/UI improvement
backlog (prioritized, with effort estimates and fzf/tmux version gates).

## License

MIT
