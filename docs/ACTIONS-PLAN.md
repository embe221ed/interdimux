# Custom actions — design and plan

*Not implemented. This is the design, written after surveying 16 extension
systems and reading interdimux's own seams. Nothing here has shipped.*

The motivating case: **a user-written script that starts a session a particular
way, reachable from `prefix + g`.** Everything below is the smallest system that
serves that and does not collapse the first time someone wants a second thing.

---

## What the survey settled

Sixteen systems, with their source read where it mattered: lazygit
`customCommands`, k9s `plugins.yaml`, tig, broot verbs, lf, nnn, yazi, zellij,
helix, neovim, VS Code `tasks.json`, JetBrains External Tools, fzf's own
`--bind` language, sesh, tmux-fzf, tmux-which-key.

**They all converge on one shape.** A declarative custom command is: a binding
(key + scope + label), a target (the selected row as named fields), a command
template, a small set of prompts collected *before* the command runs, and a
disposition (confirm? where does output go? refresh? close?). lazygit, k9s, tig,
broot, VS Code and JetBrains are all instances of exactly that; they differ only
in richness. Nothing outside that shape survives in a config file.

**The wall is always in the same four places, in this order:**

1. **Branching between prompts.** The moment "which prompt comes next depends on
   the last answer", you need an expression language. lazygit said yes and now
   ships Go templates plus a `condition:` field. VS Code said no, in writing:
   *"Nesting of input variables is not supported."* k9s said no — flat `inputs`,
   JSON-Schema `maxItems: 5`. **One linear prompt sequence is declarative; a
   decision tree is code.**
2. **Prompt options that must be computed.** "Menu of branches" needs a command.
   Everyone serious added a shell escape *inside* the config — lazygit has three
   (`menuFromCommand`, `suggestions.command`, `runCommand`), helix has `%sh{…}`,
   VS Code has `${command:…}`. So picking YAML does not dodge shell quoting; it
   arrives anyway.
3. **Reacting to the result.** Declarative actions are fire-and-forget —
   lazygit's entire post-action vocabulary is one boolean. nnn and lf solved it
   better, with a **back-channel** that lets the script command the host
   (`NNN_PIPE`, `lf -remote`). lf says so outright: *"Since lf does not have
   control flow syntax, remote commands are used for such needs."*
4. **Stateful or long-running behaviour.** Everyone needed a real language:
   yazi (Lua), zellij (WASM), helix (Steel, after years of debate), neovim
   (never attempted a declarative layer).

**The cost of crossing is real.** zellij is the warning: WASM means a per-plugin
toolchain, opaque binaries, and a permission system that is itself a bug farm.

---

## The design

### One schema, two bodies

Every system with two tiers pays for two parsers, two validators and two doc
pages, and users end up unsure which tier a feature lives in. interdimux does
not need that, because the metadata a host needs is identical either way.

- **The manifest is mandatory for both tiers** — one reader, one validator, one
  `--doctor` path, one documentation table.
- **The tier is where the *body* lives**: a one-line `run =` for the common
  case, an executable for everything else.

The motivating use case is an executable body with a normal manifest, and it
works on day one of Stage 1.

### Deliberate non-goals, stated in the docs rather than discovered

Following VS Code's honesty about its own limits:

- **One prompt maximum in the declarative tier.** No branching, no computed
  options, no conditions. Need two? Write a script and call `--dialog input`
  twice.
- **No control flow in config, ever.** (lf's line.)
- **Plugins contribute no rows to the picker list.** `--list` runs on every
  reload, resize and preview toggle; manifest I/O there would re-introduce the
  per-callback I/O that `PERFORMANCE.md` Tiers 0-5 spent months removing.
- **No project-local discovery.** See the security section — this is the one
  that makes `git clone` an execution vector.

### Layout and discovery

```
${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/
├── startup.conf          # EXISTING, untouched, and stays separate
├── actions.conf          # declarative records (one-line `run =` bodies)
└── actions.d/            # executables, each carrying the same manifest as a header
    ├── dev-stack.sh
    ├── _shared.sh        # ignored: leading underscore = library, not an action
    └── old.sh.disabled   # ignored
```

1. If the config dir is not a directory → **return immediately, zero further
   syscalls.** The default configuration must pay microseconds. `PERFORMANCE.md`
   Tier 5.1 is the story of a warm path that did not exist for the default
   config for months; do not repeat it.
2. `actions.conf` read with the same fork-free `while IFS= read -r line || [ -n
   "$line" ]` loop as `resolve_startup_command`.
3. `actions.d/*` at depth 1 only. Accepted only if `[ -f ]`, `[ -x ]`, `[ -O ]`
   (owner is the invoking user — a builtin, no fork), the basename matches
   `[A-Za-z0-9][A-Za-z0-9._-]*`, and it does not end in `.disabled`.
4. Only the **header** is read — lines until the first that is neither `#!…` nor
   `# …`, capped at 20. A 5,000-line plugin costs what a 10-line one costs.
5. Caps: 64 actions, 4 KiB per record, 512 bytes per field. Beyond that, dropped
   and reported. (k9s's `maxItems: 5` is the honest precedent: a declarative
   surface has a size limit and should admit it.)
6. Duplicate `id` or `key`: first wins, `--doctor` reports which.

### The manifest

**One field per line, `name = value`**, records separated by a blank line. Not
because it is prettier — because this repo has already paid for the alternative.
The `at` job header packed `pane=… target=… desc=…` onto one line and could not
be parsed back once a session name contained a space; the fix was one field per
line (`IDEAS.md` §4b). Field-per-line also gives `--doctor` real line numbers.

The format is also what the codebase already uses: `startup.conf` is a
line-oriented, pure-bash, zero-fork read. TOML or YAML would need a parser — a
fork per read and a new dependency — and would be against the grain.

| field | required | domain |
|---|---|---|
| `id` | yes (defaults to the filename stem in `actions.d`) | `[a-z0-9][a-z0-9_-]{0,31}` — **the only user string that ever crosses an fzf or tmux command string** |
| `label` | **yes** | printable, ≤32 cells after sanitising. Required: helix and tig both suffer for lacking it |
| `scope` | no (default `G`) | any subset of `SWPDG`, or `*`. `S`/`W`/`P`/`D` are the `SPEC_TYPE` values `parse_spec` already yields; `G` = needs no row |
| `key` | no | one printable char, or `^x` / `M-x`; leading `!` = explicit override of a built-in |
| `flags` | no (default `r`) | see below |
| `ask` / `ask_default` | no | at most one prompt |
| `run` | yes in `actions.conf`, forbidden in `actions.d` | one line |

An optional `key` is what kills keyspace exhaustion (lazygit's and JetBrains'
shared failure): an action with no key is still reachable from the dashboard and
the palette.

### Flags — the disposition vocabulary

| flag | meaning | implemented as |
|---|---|---|
| `c` | confirm first | the existing `confirm_dialog` |
| `d` | dangerous | `popup_accent danger` + `BOLD_RED`, implies `c` |
| `p` | prompt once | the existing `input_dialog` |
| `r` | refresh the list after *(default)* | `+reload($LIST_CMD)` |
| `x` | close the picker after | `+abort` |
| `s` | silent | `execute-silent(...)`, errors via `display-message` |
| `!` | show output, wait for a key | passthrough, then `read -rsn1` (nnn's model) |
| `&` | detached | `&` + `disown`, output to the log |

`c` and `p` live in the *declarative* tier here, where yazi needed Lua, purely
because interdimux already owns those primitives in bash. That asymmetry is why
its declarative tier can be richer than yazi's while its escape hatch stays far
cheaper.

### The runtime contract — frozen, and it is the whole API

**argv**: `$1` = the SPEC (`S:name`, `W:name:0`, `P:name:0:1`, `D:/path`, or
literal `G`). `$2` = the answer to `ask`, or empty. Nothing else, ever.

**environment**: `IMUX_API`, `IMUX_SELF`, `IMUX_ID`, `IMUX_LABEL`, `IMUX_SPEC`,
`IMUX_TYPE`, `IMUX_SESSION`, `IMUX_WINDOW`, `IMUX_PANE`, `IMUX_TARGET` (already
`=`-anchored), `IMUX_PATH`, `IMUX_BRANCH`, `IMUX_COMMAND`, `IMUX_QUERY`,
`IMUX_ANSWER`, `IMUX_MODE`, `IMUX_CALLER_PANE`, `IMUX_FZF`, `IMUX_ERR`, plus
inherited `TMUX`/`TMUX_PANE`. Values are raw bytes — no shell is involved, so
nothing needs quoting.

`IMUX_CALLER_PANE` is **not** `TMUX_PANE`: inside a popup that is the popup's own
id, which is the trap already documented at the `--bind-keys` binding.

**stdin** is never a pipe. A plugin that wants input calls
`"$IMUX_SELF" --dialog input …`.

**exit codes**: `0` ok; `1-123` failure (stderr tail in an `info_flash`, full
text to the existing error log); `124` timed out; `130` user cancelled, silently.

**back-channel**: append verbs, one per line, to `$IMUX_FZF`. The wrapper reads
the file after the plugin exits, validates each line against a closed list
(`reload`, `close`, `refresh-preview`, `query`, `prompt`, `message`) and builds
the fzf action string **itself**. The plugin never writes raw fzf syntax. This
is nnn's `NNN_PIPE` without the fifo, and it is what removes the pressure to
grow the config format at all.

**Dialogs are subcommands, not sourceable functions** — `--dialog
confirm|input|info|danger`. Each is a fresh `bash` (~12 ms warm), fine on the
action path and nowhere near the hot one. They are subcommands specifically so
`dialog_open`/`input_dialog` stay refactorable; lazygit keeping `Commit.Sha`
alive next to `Commit.Hash` forever is the cost of getting that wrong once.

### Where an action shows up

- **`prefix+g` → `Custom ▸` submenu.** One row, not N. **This matters more than
  it sounds:** an oversized `display-menu` silently draws nothing (measured — see
  `UI-EXPLORATION.md`; this 13-item menu appears on a 15-row client and not on a
  14-row one), so appending user entries to the flat menu could kill `prefix+g`
  outright on a short client. A submenu costs one row regardless of how many
  actions exist. The fzf fallback has no ceiling — its list scrolls.
- **The navigator, by key**, for scoped actions — same bind shape as every
  built-in, `wait+` included.
- **The navigator, by palette** (`alt-a`) — lazygit's `commandMenu`, and the
  reason `key` can be optional. One fork, only when pressed.
- **The hint bar — free.** Labels fold into the `INTERDIMUX_HDR_*` strings the
  navigator already builds once per open. The per-cursor-move path stays an
  inline `case` over env vars with zero forks.
- **Not in the list.** See non-goals.

### Hot-path cost

The rule: **discovery never forks, and the hot path never discovers.**

The navigator needs only *keys and labels*, and gets them as one pre-compiled
index string in an env var it already receives for free — one more `-e` flag on
the baked `prefix+f` binding, format-expanded in the server at keypress. Zero
forks, zero round-trips. This is the same "free cache validation" trick
`PERFORMANCE.md` Tier 6 identifies as the only cache design worth building.

Mandatory `#{q:}` on the way out — verified byte-exact for a payload containing
`\x1f`, `\x1e`, `"`, `#S` and `$HOME`, and verified to silently truncate at the
first `"` without it.

**The invalidation problem is designed away rather than solved: the index is
advisory, the disk is authoritative.** The index carries keys and labels (UI
only); the *command* is always re-read from disk at dispatch. A stale index can
under-bind a key or show a stale label — it can never run the wrong command.
That is exactly the property the rejected list-cache could not have.

Parsing the index must use the right form: measured at 32 records, `IFS`
word-splitting on `\x1e`/`\x1f` is ~1 ms, `mapfile` ~0.5 ms, and a
`${rest#*$RS}` loop is ~2.5 ms **and quadratic** — the trap `PERFORMANCE.md`
Tier 5.6 already documents, found again in a new place. Never `<<<` in a loop:
each here-string is a temp file (~3 ms per record).

### Failure handling

1. **Never `source`, always `exec`.** A plugin's `set -e`, `IFS`, traps and
   variable names cannot touch the navigator.
2. **Discovery is parse-only** — never `eval`, never source, never execute. A
   malformed record is skipped and recorded, and `--list` must be **byte
   identical** to a run with an empty config dir. That byte-identity is the
   test oracle.
3. **Dispatch runs inside the existing `--action` handler**, inheriting its
   `set +e`, its `INT`/`TERM`/`EXIT` cleanup trap (stty restore, cursor, border
   repaint — IDEAS #22, fixed the hard way) and its staleness check.
4. **stderr is captured, never painted over the list** — the popup's stderr *is*
   the popup.
5. **Timeouts** run the plugin as `timeout`'s **direct child with its own
   stdout** — `IDEAS.md` §4b lesson 3: `timeout` signals its direct child, not
   the tree, and an orphan holding the caller's stdout looks like a silent hang.
6. **Key collisions cannot silently shadow a built-in** — refused unless
   `!`-prefixed, reported either way.
7. **Malformed manifests fail in `--doctor` with a line number**, never at paint
   time. The repo's scar: a junk `@interdimux-recent-limit` printed errors onto
   the popup.

### Security posture

interdimux runs the user's own commands against the user's own tmux. A custom
action is a script the user wrote, can read, can `bash -x`, and can edit.
**That transparency is the security model.** A permission system would be pure
friction — zellij's exists because its plugins are opaque WASM binaries, and it
is itself a documented bug farm.

Trusted: files under the config dir owned by the invoking user. Nothing else.

**Not discovered, deliberately: project-local actions.** No
`./.interdimux/actions.d`. Auto-discovering an executable from a checkout makes
`git clone` an arbitrary-code-execution vector. Note the contrast with the
existing `.interdimux-startup`, which *is* read from a project directory but as
**text**, delivered by `send-keys` — same threat, already handled correctly, and
this design must not weaken it.

What the design prevents by construction: a session named `x'y$(id)#z` reaches a
plugin as raw env bytes and a `run =` only through `shq()`, never a bind string.
Only a charset-validated `id` crosses fzf or tmux. That retires the whole bug
class this repo has already paid for — `#` eaten at keypress, `printf %q`
producing `$'\t'` that dash reads literally, unanchored targets prefix-matching.

Not defended and not defensible: TOCTOU between reading and executing the body.
Say so plainly.

### Versioning

`# imux:v1` in headers (reusing the existing job-marker convention), `api = 1`
in records, `IMUX_API=1` in the child env. An unsupported `api` is loaded but
**not bound**, and doctor says "needs a newer interdimux" — fail loudly, never
silently do nothing. Fields are added, never repurposed.

The frozen surface is exactly: field names and domains, `{placeholder}` names,
`IMUX_*` names, argv order, exit-code meanings, back-channel verbs, and the
`--dialog` subcommands. Everything else stays renameable — which is the entire
reason plugins may not source the script.

---

## Staged order

| stage | what lands | effort | ~LOC |
|---|---|---|---|
| **0** | Reader + `--doctor` section + `--action-explain`. Parses and validates; **executes nothing** | M | 190 |
| **1** | `scope=G` end-to-end: index, `Custom ▸` submenu, dispatch, env/argv contract, error capture, timeouts | M | 150 |
| **2** | Declarative bodies: `run =`, `{placeholder}` through `shq()`, `cwd`, the `c`/`d` flags | S/M | 70 |
| **3** | The one prompt, via the existing `input_dialog` | S | 35 |
| **4** | Picker integration: scoped keys, hints folded into `INTERDIMUX_HDR_*`, the remaining dispositions, `alt-a` palette | S/M | 80 |
| **5** | `--dialog` subcommands + the back-channel verbs | S | 60 |
| **6** | `docs/ACTIONS.md`, three example actions, the frozen-API table | S | — |

**Stage 1 alone ships the motivating use case** — "my script appears in
`prefix+g` and runs with a full environment". Stage 0 first, so a user can author
and debug an action before a runtime exists to blame, and so the
"malformed manifest cannot affect the picker" invariant is provable while there
is nothing to execute.

~500 lines of bash total, ~190 of it validation and error handling — the right
ratio for this codebase.

### Tests, in the harness's established style

- `test_actions_parse.sh` — malformed records (unknown field, missing label, bad
  id, CRLF, duplicate key, `api=99`, non-executable, foreign-owned) each
  asserting: skipped, reported with the right **line number**, and `--list`
  byte-identical to an empty config dir.
- `test_actions_runtime.sh` — a fixture plugin dumping `env | grep ^IMUX_`;
  assert with `od -c` that a session named with `'`, `$(id)`, `#`, a newline and
  a tab arrives byte-exact and that `id` never ran.
- `test_actions_hotpath.sh` — process accounting: `--list` and one focus
  callback must spawn the same `clone`/`execve` counts with 20 actions installed
  as with 0. This is the regression guard for the whole performance argument.
- `test_actions_menu.sh` — 40 actions on a short client: assert `prefix+g` still
  draws (extends `test_dashboard.sh`, which already covers the empty case).
- `test_actions_index.sh` — the `#{q:}` round-trip with a `\x1f`/`"`/`#`-laden
  label, **plus a mutation check that dropping `#{q:}` fails the test** —
  otherwise the assertion proves nothing.

## Open questions

- Whether a value substituted from `#{@opt}` can be format-expanded a *second*
  time. The round-trip is verified byte-exact with `#{q:}`; the double-expansion
  case was not isolated, hence the belt-and-braces `#`-doubling in the label
  sanitiser.
- `#{q:}` availability on tmux 3.0-3.3. Irrelevant to correctness (the index
  only rides the `-e` path on the ≥ 3.4 binding) but worth confirming before
  documenting.
- The full-scan timing was taken with a pathological fixture (20 files × 220
  lines). A realistic 3-8 actions was not separately benchmarked.
