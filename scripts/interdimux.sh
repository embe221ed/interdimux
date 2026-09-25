#!/usr/bin/env bash
#
# interdimux — fuzzy tmux navigator
#
# Gathers sessions, windows, and panes into a tree-structured fzf list
# and switches to the selected target.  Supports kill, rename, and
# new-session-from-directory actions via fzf keybindings.

# bash >= 4.3, checked before anything can need it.  Every option read goes
# through a nameref (`local -n`), and namerefs and the rules this file writes its
# array expansions to are 4.3; macOS's own /bin/bash is 3.2.  (An assoc key is
# tested as `[[ ${arr[$k]+x} ]]`, never `[[ -v "arr[$k]" ]]`: every bash before
# 5.2 expands that subscript a second time, so a '$' in a session name or a
# directory was read as a parameter -- "unbound variable" under set -u, and a
# name like `$(cmd)` ran.)  Unchecked, 3.2 died at the first `declare -A` and
# 4.2 at the first `local -n`, each naming a builtin rather than the problem --
# and behind a key binding or in a popup nobody saw even that.  So it is said
# here: on stderr, and from inside tmux on the status line, which outlives a
# popup.
#
# POSIX sh, and BASH_VERSION rather than BASH_VERSINFO, because this has to run
# in whatever shell the file is handed to.  bash reads a script one command at a
# time, so a bash that fails this never parses the rest of the file.
case "${BASH_VERSION:-}" in
  4.[3-9]*|4.[1-9][0-9]*|[5-9].*|[1-9][0-9]*.*) ;;
  *)
    _imux_old="interdimux: bash >= 4.3 is required (found ${BASH_VERSION:+bash }${BASH_VERSION:-a shell that is not bash})"
    echo "$_imux_old" >&2
    [ -n "${TMUX:-}" ] && tmux display-message "$_imux_old" >/dev/null 2>&1
    exit 1 ;;
esac

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

US=$'\x1f'  # Unit separator — safe field delimiter for tmux data parsing

# Script path — used by fzf bindings to call back into this script.  Built
# without forks (the old dirname/basename/pwd subshells ran on every
# invocation).  Real launches already pass an absolute path; a relative one is
# anchored to $PWD.  It only re-invokes this script, so an unresolved symlink
# path is fine.
case "${BASH_SOURCE[0]}" in
  /*) SCRIPT_PATH="${BASH_SOURCE[0]}" ;;
  *)  SCRIPT_PATH="$PWD/${BASH_SOURCE[0]}" ;;
esac

# Same path with single quotes escaped, for embedding in tmux command strings.
# Precomputed because it never changes and every call site used to spend a
# subshell on it.
SQ_SCRIPT="${SCRIPT_PATH//\'/\'\\\'\'}"

# The same again, with '#' doubled, for embedding in anything tmux FORMAT-EXPANDS
# — which `run-shell` does to its argument, with or without -C.  An install path
# containing a '#' (`~/dev/#scratch/interdimux`) otherwise has that character and
# whatever follows it eaten at keypress: `#f`, `#S` and friends are formats, so
# prefix+f silently ran a command for a path that does not exist, or nothing at
# all.  '##' is tmux's escape and collapses back to a single '#'.
#
# The quoted pattern matters: in ${var//#/…} a bare '#' is the match-at-start
# anchor, not a literal.
SQ_SCRIPT_FMT="${SQ_SCRIPT//'#'/##}"

# The Rust core ("imux").  When present it renders the whole list — the part
# that was ~181 ms of in-process bash — in ~2 ms.  Everything below stays as the
# fallback, so the plugin works unchanged without it.
#
# Only an explicit path or the in-repo build is accepted; no bare PATH lookup,
# because "imux" is a short name that could plausibly be something else.  Set
# INTERDIMUX_BIN to use a binary installed elsewhere — for the popups, in the tmux
# server's environment (`tmux set-environment -g INTERDIMUX_BIN …`), which is the
# one they start from.  Deliberately NOT a tmux option: anything that can set an
# option could then choose the program every picker runs, and reading one here
# would cost a tmux round-trip on every cold invocation.
# INTERDIMUX_USE_RUST=off forces the bash renderer, which is how the parity
# tests compare the two.
IMUX_BIN=""
if [ "${INTERDIMUX_USE_RUST:-on}" != "off" ]; then
  _imux_repo="${SCRIPT_PATH%/scripts/*}"
  for _c in "${INTERDIMUX_BIN:-}" \
            "$_imux_repo/rust/target/release/imux" \
            "$_imux_repo/bin/imux"; do
    if [ -n "$_c" ] && [ -x "$_c" ]; then IMUX_BIN="$_c"; break; fi
  done
  unset _c _imux_repo
fi
# The stdin protocol the binary is asked to speak.  It is the SUBCOMMAND, and
# its name is its version: bump it with every change to the section framing or
# to the position of any field, in step with PROTOCOL in rust/src/main.rs.  A
# binary built from other sources -- routine after a `git pull` or a TPM update,
# which never rebuild rust/ -- then exits 2 on the name instead of reading new
# fields at old positions (when the session name moved to the front, an old
# binary drew every session as its timestamp and no window at all, with exit
# 0), and the list falls back to the bash renderer.  See imux_refused.
IMUX_PROTO=gather3

# ---------------------------------------------------------------------------
# Option table
# ---------------------------------------------------------------------------

# OPT_MAP is the single source of truth for "which option feeds which env var".
# Three consumers read it: the dump below, env_fwd_vars (popup -e flags), and
# --bind-keys (the baked prefix+f binding).  The env suffix is NOT always the
# option name with dashes swapped — fzf-opts feeds INTERDIMUX_FZF_OPTS,
# dirs-live-search feeds INTERDIMUX_DIRS_LIVE — which is exactly the kind of
# mismatch that silently drops a user's setting once the OPTS_PRIMED sentinel
# stops the child from re-reading tmux.  tests/test_config_fwd.sh cross-checks
# this table against the get_opt calls.
OPT_MAP=(
  "show-preview:SHOW_PREVIEW"           "show-full-command:SHOW_FULL_COMMAND"
  "show-git-branch:SHOW_GIT_BRANCH"     "popup-width:POPUP_WIDTH"
  "popup-height:POPUP_HEIGHT"           "order:ORDER"
  "fzf-opts:FZF_OPTS"                   "recent-limit:RECENT_LIMIT"
  "scan-depth:SCAN_DEPTH"               "use-zoxide:USE_ZOXIDE"
  "dirs-live-search:DIRS_LIVE"          "project-markers:PROJECT_MARKERS"
  "color-accent:COLOR_ACCENT"           "color-path:COLOR_PATH"
  "color-git:COLOR_GIT"                 "color-ssh:COLOR_SSH"
  "color-editor:COLOR_EDITOR"           "color-success:COLOR_SUCCESS"
  "color-danger:COLOR_DANGER"           "color-tree:COLOR_TREE"
  "color-separator:COLOR_SEPARATOR"     "color-query:COLOR_QUERY"
  "color-match-current:COLOR_MATCH_CURRENT" "color-current-bg:COLOR_CURRENT_BG"
  "color-header:COLOR_HEADER"           "color-border:COLOR_BORDER"
  "color-menu-sel-fg:COLOR_MENU_SEL_FG"
  "startup-command:STARTUP_COMMAND"  "hydrate:HYDRATE"
  "show-dirs:SHOW_DIRS"              "dirs-limit:DIRS_LIMIT"
  "raw:RAW"                          "hide:HIDE"
  "session-rule:SESSION_RULE"        "scope-highlight:SCOPE_HIGHLIGHT"
  "show-title:SHOW_TITLE"            "title-max:TITLE_MAX"
  "agents:AGENTS"                    "agent-args:AGENT_ARGS"
  "agent-state:AGENT_STATE"          "claude-dir:CLAUDE_DIR"
  "title-rules:TITLE_RULES"
)
OPT_NAMES=()
for _m in "${OPT_MAP[@]}"; do OPT_NAMES+=("${_m%%:*}"); done
unset _m

# ---------------------------------------------------------------------------
# --help / --version
# ---------------------------------------------------------------------------
#
# Answered here, ahead of --bind-keys and the preflight, so both work anywhere:
# outside tmux and without fzf, which is exactly where someone reading about the
# plugin types them.  Any OTHER argument nothing handles is refused at the end of
# the dispatch, just before the navigator — only there is "no mode took it"
# actually known, and a list of modes kept up here would drift from the handlers.
#
# The one version string the script has.  The Rust helper reports its own
# (`imux --version`, from rust/Cargo.toml).
VERSION=0.1.0

# Builtins only (no `cat`): --help has to work on a PATH that has nothing on it.
usage() {
  local text
  IFS= read -r -d '' text <<'USAGE' || :
usage: interdimux.sh [mode]

With no mode, runs the navigator.  It expects a tmux popup around it: prefix+f
opens one (the plugin binds it), and so does `--launch switch`.

  --doctor                   check the setup; exits 1 if anything is wrong
  --list                     print the navigator's rows
  --jump N                   switch to session #N, in the picker's own order
  --connect-dir DIR          switch to DIR's session, creating it if needed
  --session-name-for DIR     print the session name DIR would get
  --send-at WHEN TARGET CMD  type CMD into TARGET at WHEN (an at(1) time)
  --send-in SECS TARGET CMD  the same, SECS seconds from now
                             (a CMD that is one key name, e.g. C-c, is pressed)
  --sched-list               list what --send-at / --send-in have queued
  --sched-cancel ID          cancel one of those
  --launch MODE              open a picker in a popup: switch kill rename zoom
                             swap detach send dirs schedule jobs doctor agents
  --dashboard-launch         open the dashboard (what prefix+g runs)
  --bind-keys                install the key bindings (the plugin does this)
  --version                  print the version
  --help, -h                 print this
USAGE
  printf '%s' "$text"
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --version) printf 'interdimux %s\n' "$VERSION"; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Key bindings (called once by interdimux.tmux at plugin load)
# ---------------------------------------------------------------------------
#
# Binds prefix+f STRAIGHT to display-popup, so opening the picker costs no
# shell at all.  The old path was: run-shell -b forks /bin/sh, which starts a
# full bash on this 2500-line script, which resolves config it then throws
# away, and finally execs `tmux display-popup` — a client round-trip — before
# the real navigator bash even starts.  Measured ~40 ms of pure launcher
# overhead per open, and it scaled badly under load.
#
# `run-shell -bC` is the vehicle: -C runs the command IN THE SERVER (no shell),
# and run-shell format-expands its argument at keypress in the pressing
# client's context.  display-popup does NOT format-expand its own -e or
# shell-command, so the wrapper is required rather than a direct
# `bind-key … display-popup`.
#
# Values are forwarded as FORMAT REFERENCES, not baked literals, so runtime
# `set -g @interdimux-*` changes take effect on the very next open — no plugin
# reload, no staleness.
#
# This handler deliberately runs BEFORE the preflight below.  If fzf is missing
# from the tmux server's PATH (common: fzf is often only on PATH via a shell
# rc), the preflight exits 1 — and doing that here would leave the user with NO
# BINDINGS AT ALL, which is far worse than a popup that reports the error.
if [ "${1:-}" = "--bind-keys" ]; then
  set +e

  _bk_tvnum=999
  _bk_vstr=$(tmux -V 2>/dev/null)
  [[ "$_bk_vstr" =~ ([0-9]+)\.([0-9]+) ]] && \
    _bk_tvnum=$(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] ))

  _bk_nav=$(tmux show-option -gqv @interdimux-key 2>/dev/null);           _bk_nav="${_bk_nav:-f}"
  _bk_dash=$(tmux show-option -gqv @interdimux-dashboard-key 2>/dev/null); _bk_dash="${_bk_dash:-g}"

  # TMUX_PANE=#{pane_id} on every run-shell binding, not just the popup one.
  #
  # run-shell does NOT derive TMUX_PANE from the pressing client — it passes the
  # tmux SERVER's global environment, which holds whatever TMUX_PANE the process
  # that started the server happened to export.  Measured: a server started from
  # inside another tmux had `show-environment -g TMUX_PANE` = %8, a pane id that
  # did not exist in it, and every run-shell binding inherited that; tmux then
  # resolved `-t %8` to something arbitrary rather than failing.  Anything that
  # depends on "which pane am I in" — the current-row marker, MRU's
  # move-current-to-end, and --jump's numbering — silently answers for the wrong
  # session.  run-shell format-expands its argument, so #{pane_id} is the
  # pressing client's pane, resolved in-server at keypress.
  #
  # INTERDIMUX_CLIENT=#{client_name} rides along for the same reason, one level
  # up: which CLIENT pressed the key.  Everything the script later does to "the
  # current client" -- switch-client, display-popup, display-menu, a status
  # message -- otherwise lets tmux guess, and it guesses the attached client with
  # the most recent activity.  Keys typed into a popup or menu never update that
  # (tmux hands them to the overlay first), so while the picker is open a single
  # keystroke on another terminal attached to the same session made THAT one the
  # current client: Enter moved the other terminal, and the kill dialog's border
  # repaint opened a blocking shell popup on it.  Resolved at keypress, the name
  # is exact.  #{q:} because run-shell hands the expansion to /bin/sh; a client
  # name is a tty path or "client-<pid>", so in practice it is a no-op.
  _bk_who="TMUX_PANE=#{pane_id} INTERDIMUX_CLIENT=#{q:client_name}"

  # The dashboard is not the hot path — it keeps the simple launcher.
  tmux bind-key "$_bk_dash" run-shell -b "$_bk_who bash '$SQ_SCRIPT_FMT' --dashboard-launch"

  # Opt-in numbered jumps (@interdimux-jump-keys 'M-1 M-2 M-3').  Space-separated
  # keys, in order: the first jumps to session #1 in the picker's own ordering,
  # which under the default MRU is the previous session.
  #
  # Bound in the ROOT table (-n), no prefix: the entire point is a single
  # keystroke that always lands in the same place, which a prefix sequence and a
  # fuzzy query both fail at for different reasons.  Off by default and the user
  # names the keys, because silently claiming root-table keys in someone else's
  # tmux is not ours to do.
  #
  # Previously bound keys are NOT preserved -- tmux has no way to ask what a key
  # was bound to and restore it later, so the honest contract is "you named
  # these keys, they are ours now".
  _bk_jump=$(tmux show-option -gqv @interdimux-jump-keys 2>/dev/null)
  if [ -n "$_bk_jump" ]; then
    _bk_i=0
    for _bk_k in $_bk_jump; do
      _bk_i=$(( _bk_i + 1 ))
      tmux bind-key -n "$_bk_k" run-shell -b "$_bk_who bash '$SQ_SCRIPT_FMT' --jump $_bk_i" 2>/dev/null
    done
    unset _bk_i _bk_k
  fi

  # run-shell -C needs tmux >= 3.4; below it, keep the original binding.
  if [ "$_bk_tvnum" -lt 304 ]; then
    tmux bind-key "$_bk_nav" run-shell -b "$_bk_who bash '$SQ_SCRIPT_FMT' --launch switch"
    exit 0
  fi

  # fzf's minor version cannot come from a tmux format, so bake it as an
  # integer.  If fzf isn't visible from here, omit it and let the popup child
  # probe for itself rather than baking a wrong value.
  _bk_fzf=""
  _bk_fv=$(fzf --version 2>/dev/null); _bk_fv="${_bk_fv%% *}"
  IFS=. read -r _bk_fmaj _bk_fmin _ <<< "$_bk_fv"
  if [[ "${_bk_fmaj:-}" =~ ^[0-9]+$ && "${_bk_fmin:-}" =~ ^[0-9]+$ ]]; then
    _bk_fzf="$_bk_fmin"
    [ "$_bk_fmaj" -gt 0 ] && _bk_fzf=999
  fi

  # #{q:…} on every value is mandatory, not defensive: the expanded text is
  # re-lexed by tmux's command parser, so a bare #{@interdimux-x} whose value
  # contains a double quote either loses its quoting or kills the binding
  # outright — silently, with prefix+f simply doing nothing.
  #
  # An unset option expands to "", which get_opt's -n test skips, landing on
  # the built-in default.  That is correct ONLY because INTERDIMUX_OPTS_PRIMED
  # also stops the child re-reading tmux; the two go together.
  _bk_env=""
  for _m in "${OPT_MAP[@]}"; do
    _bk_env+=" -e \"INTERDIMUX_${_m#*:}=#{q:@interdimux-${_m%%:*}}\""
  done
  unset _m
  _bk_env+=" -e \"INTERDIMUX_OPTS_PRIMED=1\""
  # A popup natively exports TMUX_PANE as its OWN pane id, which resolves to an
  # empty target — current-row marker and MRU's move-current-to-end both break,
  # silently.  #{pane_id} is the pressing client's pane.
  _bk_env+=" -e \"TMUX_PANE=#{pane_id}\""
  # ...and the pressing CLIENT, for the reason given above _bk_who.
  _bk_env+=" -e \"INTERDIMUX_CLIENT=#{q:client_name}\""
  _bk_env+=" -e \"INTERDIMUX_TMUX_VNUM=$_bk_tvnum\""
  [ -n "$_bk_fzf" ] && _bk_env+=" -e \"INTERDIMUX_FZF_MINOR=$_bk_fzf\""
  # popup_accent re-sends -T on every repaint, and on tmux >= 3.6 a partial
  # display-popup resets omitted properties — without this the title vanishes
  # after the ctrl-x kill confirm.
  #
  # The title names the session you are IN.  The list marks the current row, but
  # that row scrolls out of view the moment the list is longer than the popup,
  # and then nothing on screen says where you are — which matters most in
  # exactly the case where you have enough sessions to need the picker.  The
  # title is the one thing always visible, and here it costs nothing: the name
  # comes from a tmux format expanded in-server at keypress, not a fork.
  #
  # #{q:} on the NAME only: a session name may contain a quote, which would
  # otherwise close the -e/-T token and kill the binding.  The surrounding
  # "#[bold]" stays unquoted, because rs_quote would double its '#' and '##['
  # does not collapse back before '['.
  _bk_title=' interdimux · #{q:session_name} '
  _bk_env+=" -e \"INTERDIMUX_TITLE=$_bk_title\""

  # #{?…,…,…} treats the string "0" as FALSE, so it cannot be used as an
  # emptiness test — #{==:…,} can.  (Width/height can't legitimately be 0, but
  # the same idiom is wrong for colour-tree 0 or recent-limit 0.)
  _bk_w='#{?#{==:#{@interdimux-popup-width},},80%,#{@interdimux-popup-width}}'
  _bk_h='#{?#{==:#{@interdimux-popup-height},},75%,#{@interdimux-popup-height}}'

  tmux bind-key "$_bk_nav" run-shell -bC \
    "display-popup -w \"$_bk_w\" -h \"$_bk_h\" -T \"#[bold]$_bk_title\"$_bk_env -E \"bash '$SQ_SCRIPT_FMT'\""
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Except for --doctor, whose job is to report exactly this: stopping it here
# printed one line where the report should have been.
if ! command -v fzf >/dev/null 2>&1 && [ "${1:-}" != "--doctor" ]; then
  echo "interdimux: fzf is not installed" >&2
  exit 1
fi

# The dynamic header uses transform-header, which needs fzf >= 0.40.
# Newer versions unlock extra polish (see build_fzf_theme); the version
# is parsed once here.  If the version string is unparseable, skip the
# check rather than block.
FZF_MINOR=0
if [[ "${INTERDIMUX_FZF_MINOR:-}" =~ ^[0-9]+$ ]]; then
  # Forwarded by the launcher (env_fwd) — skip the fzf --version fork+exec
  # (~100ms under load) that would otherwise run on every child callback
  # (preview/header/reload).
  FZF_MINOR="$INTERDIMUX_FZF_MINOR"
else
  fzf_version=$(fzf --version 2>/dev/null) || true
  fzf_version="${fzf_version%% *}"   # "0.74.0 (rev)" -> "0.74.0", no awk fork
  IFS=. read -r fzf_major fzf_minor _ <<< "$fzf_version"
  if [[ "${fzf_major:-}" =~ ^[0-9]+$ && "${fzf_minor:-}" =~ ^[0-9]+$ ]]; then
    if [ "$fzf_major" -eq 0 ] && [ "$fzf_minor" -lt 40 ] && [ "${1:-}" != "--doctor" ]; then
      echo "interdimux: fzf >= 0.40 is required (found $fzf_version)" >&2
      exit 1
    fi
    FZF_MINOR="$fzf_minor"
    [ "$fzf_major" -gt 0 ] && FZF_MINOR=999
  fi
fi

# True when fzf is at least 0.<arg>
fzf_ge() { [ "$FZF_MINOR" -ge "$1" ]; }

if [ -z "${TMUX:-}" ]; then
  echo "interdimux: not running inside tmux" >&2
  exit 1
fi

# tmux version as major*100+minor (3.4 → 304); unparseable builds
# (e.g. "master") are assumed modern.
if [[ "${INTERDIMUX_TMUX_VNUM:-}" =~ ^[0-9]+$ ]]; then
  TMUX_VNUM="$INTERDIMUX_TMUX_VNUM"   # forwarded by the launcher (env_fwd)
else
  TMUX_VNUM=999
  tmux_vstr=$(tmux -V 2>/dev/null || true)
  if [[ "$tmux_vstr" =~ ([0-9]+)\.([0-9]+) ]]; then
    TMUX_VNUM=$(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] ))
  fi
fi

# True when tmux is at least major*100+minor
tmux_ge() { [ "$TMUX_VNUM" -ge "$1" ]; }

# POSIX shell quoting.  Sets REPLY to a form that any POSIX sh reproduces
# verbatim: wrap in single quotes, and end/escape/reopen around each embedded
# single quote.
#
# NOT `printf %q`.  Bash's %q reaches for ANSI-C quoting the moment a control
# character appears — `echo a<TAB>b` becomes `echo\ a$'\t'b` — and every string
# built here is executed by some OTHER shell: at replays the job body under
# /bin/sh, and tmux runs `run-shell` and popup commands the same way.  On this
# box /bin/sh is dash, which has no $'...' at all and reads it as a literal '$'
# followed by a quoted string.  Verified: dash ran the %q form above and printed
# `echo a$\tb`, so a scheduled command containing a tab or a newline delivered
# the wrong text.
#
# Known limitation: fish cannot parse '\'' either (its only in-quote escapes are
# \' and \\).  This is strictly better than %q there too, and every shell that
# actually runs these strings is POSIX.
shq() {
  local s="$1"
  REPLY="'${s//\'/\'\\\'\'}'"
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Config resolution.  get_opt sets the named variable via a nameref (no
# subshell): env override → the one-shot tmux options dump → default.  It is
# called 27× at top level on every invocation, so the old VAR=$(get_opt …)
# form cost 27 subshell forks per run (warm) plus 27 `tmux` execs (cold).
#
# load_tmux_opts resolves every @interdimux-* option in ONE display-message
# via format expansion — raw, unquoted values, split on US.  Children receive
# every value through the env, so they never trigger the dump.
#
# (OPT_MAP / OPT_NAMES are defined near the top of the file — they must be
# available before the preflight, because --bind-keys runs ahead of it.)
declare -A TMUX_OPTS=()
_tmux_opts_loaded=0
load_tmux_opts() {
  [ "$_tmux_opts_loaded" = 1 ] && return 0
  # The launcher resolved every option and forwarded all of them, so a child
  # never needs the dump.  Without this, an option whose value is legitimately
  # EMPTY (fzf-opts and project-markers both default to "") is indistinguishable
  # from "not forwarded" in get_opt's -n test, and every popup callback --
  # preview, focus header, reload, action -- paid a subshell plus a tmux
  # round-trip.  In the default config that was every invocation.
  #
  # INTERDIMUX_OPTS_PRIMED is internal: it is only ever set via the
  # display-popup -e flags built by env_fwd_vars.  Direct/cold invocations
  # don't have it and still dump normally.
  if [ "${INTERDIMUX_OPTS_PRIMED:-}" = 1 ]; then
    _tmux_opts_loaded=1
    return 0
  fi
  _tmux_opts_loaded=1
  local fmt="" name raw
  local -a vals
  for name in "${OPT_NAMES[@]}"; do
    [ -n "$fmt" ] && fmt+="$US"
    fmt+="#{@interdimux-$name}"
  done
  # Anchored to $TMUX_PANE for the same reason gather_targets is: @interdimux-*
  # lookups are target-relative, so a bare display-message resolves session-local
  # overrides against whichever session was most recently attached.
  raw=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} "$fmt" 2>/dev/null) || return 0
  IFS="$US" read -r -a vals <<< "$raw"
  local i=0
  for name in "${OPT_NAMES[@]}"; do
    TMUX_OPTS["@interdimux-$name"]="${vals[i]:-}"
    i=$((i + 1))
  done
}

get_opt() {
  local -n _gv="$1"
  local env_val="$2" opt_name="$3" default="$4"
  if [ -n "$env_val" ]; then _gv="$env_val"; return 0; fi
  load_tmux_opts
  local v="${TMUX_OPTS[$opt_name]:-}"
  _gv="${v:-$default}"
}

get_opt SHOW_PREVIEW      "${INTERDIMUX_SHOW_PREVIEW:-}"      @interdimux-show-preview      off
get_opt SHOW_FULL_COMMAND "${INTERDIMUX_SHOW_FULL_COMMAND:-}" @interdimux-show-full-command on
get_opt SHOW_GIT_BRANCH   "${INTERDIMUX_SHOW_GIT_BRANCH:-}"   @interdimux-show-git-branch   on
get_opt POPUP_WIDTH       "${INTERDIMUX_POPUP_WIDTH:-}"       @interdimux-popup-width       80%
get_opt POPUP_HEIGHT      "${INTERDIMUX_POPUP_HEIGHT:-}"      @interdimux-popup-height      75%
get_opt ORDER            "${INTERDIMUX_ORDER:-}"             @interdimux-order             mru
get_opt FZF_USER_OPTS     "${INTERDIMUX_FZF_OPTS:-}"          @interdimux-fzf-opts          ""
get_opt RECENT_LIMIT      "${INTERDIMUX_RECENT_LIMIT:-}"      @interdimux-recent-limit      10
get_opt SCAN_DEPTH        "${INTERDIMUX_SCAN_DEPTH:-}"        @interdimux-scan-depth        3
get_opt USE_ZOXIDE        "${INTERDIMUX_USE_ZOXIDE:-}"        @interdimux-use-zoxide        on
get_opt DIRS_LIVE         "${INTERDIMUX_DIRS_LIVE:-}"         @interdimux-dirs-live-search  off
get_opt EXTRA_MARKERS     "${INTERDIMUX_PROJECT_MARKERS:-}"   @interdimux-project-markers   ""
get_opt STARTUP_COMMAND   "${INTERDIMUX_STARTUP_COMMAND:-}"  @interdimux-startup-command   ""
get_opt HYDRATE           "${INTERDIMUX_HYDRATE:-}"          @interdimux-hydrate           on
get_opt SHOW_DIRS         "${INTERDIMUX_SHOW_DIRS:-}"        @interdimux-show-dirs         on
get_opt DIRS_LIMIT        "${INTERDIMUX_DIRS_LIMIT:-}"       @interdimux-dirs-limit        15
get_opt RAW_MODE          "${INTERDIMUX_RAW:-}"              @interdimux-raw               on
get_opt HIDE_PATTERNS     "${INTERDIMUX_HIDE:-}"             @interdimux-hide              ""
get_opt SESSION_RULE      "${INTERDIMUX_SESSION_RULE:-}"     @interdimux-session-rule      on
get_opt SCOPE_HIGHLIGHT   "${INTERDIMUX_SCOPE_HIGHLIGHT:-}"  @interdimux-scope-highlight   on
get_opt SHOW_TITLE        "${INTERDIMUX_SHOW_TITLE:-}"       @interdimux-show-title        known
get_opt TITLE_MAX         "${INTERDIMUX_TITLE_MAX:-}"        @interdimux-title-max         40
get_opt AGENT_NAMES       "${INTERDIMUX_AGENTS:-}"           @interdimux-agents            ""
get_opt AGENT_ARGS        "${INTERDIMUX_AGENT_ARGS:-}"       @interdimux-agent-args        off
get_opt AGENT_STATE       "${INTERDIMUX_AGENT_STATE:-}"      @interdimux-agent-state       on
get_opt CLAUDE_DIR        "${INTERDIMUX_CLAUDE_DIR:-}"       @interdimux-claude-dir        ""
get_opt TITLE_RULES_FILE  "${INTERDIMUX_TITLE_RULES:-}"      @interdimux-title-rules       ""

# Numeric options reach `[ -ge ]`, `find -maxdepth` and arithmetic, so a junk
# value is not a harmless no-op.  Verified: a non-numeric @interdimux-recent-limit
# makes `[ "$count" -ge "$RECENT_LIMIT" ]` print "integer expression expected",
# and that stderr is painted over the rendered list; a non-numeric
# @interdimux-dirs-limit made the Rust renderer drop every directory row.
# scan-depth is quieter -- bash arithmetic reads a bare word as an unset variable
# and yields 0 rather than failing -- but it still has to be a number before the
# clamp below compares it.  Fall back to the default rather than fail; --doctor
# is where the user finds out they typed something wrong.
#
# `case`, not `[[ =~ ]]`: this runs on every popup open, including the hot path
# (the static prefix+f binding hands raw option values straight to the navigator,
# so there is no launcher left to validate them first).
case "$RECENT_LIMIT" in ''|*[!0-9]*) RECENT_LIMIT=10 ;; esac
case "$DIRS_LIMIT"   in ''|*[!0-9]*) DIRS_LIMIT=15   ;; esac
case "$SCAN_DEPTH"   in ''|*[!0-9]*) SCAN_DEPTH=3    ;; esac
case "$TITLE_MAX"    in ''|*[!0-9]*) TITLE_MAX=40    ;; esac
# And DECIMAL, whatever the leading zeros.  `[ -gt ]` reads 08 as eight, but
# bash arithmetic reads a leading 0 as OCTAL: @interdimux-title-max 08 made the
# title cut (${desc:0:TITLE_MAX-1}) fail with "value too great for base", which
# ended gather_targets and left the bash renderer's --list with no rows at all,
# and 050 cut at forty where the Rust core, which parses decimal, cut at fifty.
# scan-depth reaches $(( )) in the directory search the same way.  Stripped
# here, once, so every reader -- [ ], $(( )), find and the binary -- sees the
# one number the user meant.  Before the clamps, so 0040 is forty, not "more
# than three digits".
for _c in RECENT_LIMIT DIRS_LIMIT SCAN_DEPTH TITLE_MAX; do
  case "${!_c}" in
    0?*) _v="${!_c}"; _v="${_v#"${_v%%[!0]*}"}"; printf -v "$_c" '%s' "${_v:-0}" ;;
  esac
done
unset _c _v
# A deep scan is a footgun rather than a preference: `find -maxdepth 40` over
# $HOME does not return within a popup's lifetime.  The length first: `[ -gt ]`
# on a 20-digit number is not false but an error, on stderr.
{ [ "${#SCAN_DEPTH}" -gt 2 ] || [ "$SCAN_DEPTH" -gt 10 ]; } && SCAN_DEPTH=10
case "$ORDER" in mru|index) ;; *) ORDER=mru ;; esac
# The agent options (see "Agents" below).  A title cap under 8 would leave
# nothing but the ellipsis, and one over 200 is no cap.  --doctor names every
# value these replace (_check_value), in the same terms.
case "$SHOW_TITLE"  in known|all|off) ;; *) SHOW_TITLE=known ;; esac
case "$AGENT_ARGS"  in on|off) ;; *) AGENT_ARGS=off ;; esac
case "$AGENT_STATE" in on|off) ;; *) AGENT_STATE=on ;; esac
[ "${#TITLE_MAX}" -gt 3 ] && TITLE_MAX=200
[ "$TITLE_MAX" -lt 8 ] && TITLE_MAX=8
[ "$TITLE_MAX" -gt 200 ] && TITLE_MAX=200
# The two path options may start with ~ (a tmux option is not expanded).
case "$TITLE_RULES_FILE" in \~|\~/*) TITLE_RULES_FILE="$HOME${TITLE_RULES_FILE#\~}" ;; esac
case "$CLAUDE_DIR"       in \~|\~/*) CLAUDE_DIR="$HOME${CLAUDE_DIR#\~}" ;; esac

# ---------------------------------------------------------------------------
# Colours — configurable palette
# ---------------------------------------------------------------------------
#
# Every colour is a tmux option (env INTERDIMUX_COLOR_* → @interdimux-color-*
# → built-in default).  A value is a hex "#rrggbb", a 256-colour index 0-255,
# or "-1"/"default" (inherit the terminal); anything else inherits too, and
# --doctor names it.  The built-in defaults reproduce the
# original warm palette; a generator (e.g. interdotensional) can feed theme
# hexes over them to re-colour interdimux with the rest of the environment.

RST=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'

get_opt COLOR_ACCENT        "${INTERDIMUX_COLOR_ACCENT:-}"        @interdimux-color-accent        173
get_opt COLOR_PATH          "${INTERDIMUX_COLOR_PATH:-}"          @interdimux-color-path          180
get_opt COLOR_GIT           "${INTERDIMUX_COLOR_GIT:-}"           @interdimux-color-git           140
get_opt COLOR_SSH           "${INTERDIMUX_COLOR_SSH:-}"           @interdimux-color-ssh           109
get_opt COLOR_EDITOR        "${INTERDIMUX_COLOR_EDITOR:-}"        @interdimux-color-editor        150
get_opt COLOR_SUCCESS       "${INTERDIMUX_COLOR_SUCCESS:-}"       @interdimux-color-success       150
get_opt COLOR_DANGER        "${INTERDIMUX_COLOR_DANGER:-}"        @interdimux-color-danger        167
get_opt COLOR_TREE          "${INTERDIMUX_COLOR_TREE:-}"          @interdimux-color-tree          240
get_opt COLOR_SEPARATOR     "${INTERDIMUX_COLOR_SEPARATOR:-}"     @interdimux-color-separator     245
get_opt COLOR_QUERY         "${INTERDIMUX_COLOR_QUERY:-}"         @interdimux-color-query         223
get_opt COLOR_MATCH_CURRENT "${INTERDIMUX_COLOR_MATCH_CURRENT:-}" @interdimux-color-match-current 215
get_opt COLOR_CURRENT_BG    "${INTERDIMUX_COLOR_CURRENT_BG:-}"    @interdimux-color-current-bg    236
get_opt COLOR_HEADER        "${INTERDIMUX_COLOR_HEADER:-}"        @interdimux-color-header        246
get_opt COLOR_BORDER        "${INTERDIMUX_COLOR_BORDER:-}"        @interdimux-color-border        238
get_opt COLOR_MENU_SEL_FG   "${INTERDIMUX_COLOR_MENU_SEL_FG:-}"   @interdimux-color-menu-sel-fg   235

# One spelling per colour: "#rrggbb", an index 0-255, or -1.  Everything else --
# `default`, a typo, a name -- becomes -1, i.e. inherit the terminal.
#
# The three sinks disagree about what they accept, and each disagreement was a
# dead key.  fzf rejects `default` (only -1) and any value it cannot parse, and
# an invalid --color is FATAL: exit 2, nothing drawn, so every picker died on a
# spelling the README and --doctor both call valid.  tmux is the mirror image:
# its style parser rejects -1 (only `default`), and it drops the WHOLE style
# when one item fails.  And sgr_of fed '#12345g' to $((16#..)), which under
# set -e killed the script at top level, before any mode ran -- --doctor
# included, the one tool meant to explain the typo.  Normalised here, once,
# every sink downstream sees a value it accepts: fzf takes all three forms as
# they are, and tmux_color maps -1 back to tmux's `default`.
#
# Inherit rather than the built-in default because the Rust renderer already
# treats an unusable value that way (palette.rs), and because the built-in
# defaults are a DARK palette -- on a light terminal they would be the wrong
# fallback.  --doctor is where a typo is reported.
#
# Classes, not ranges: under a non-C locale a bracket RANGE is collation order
# on bash < 5.0, and [[:xdigit:]]/[[:digit:]] are ASCII-only either way.
for _c in COLOR_ACCENT COLOR_PATH COLOR_GIT COLOR_SSH COLOR_EDITOR COLOR_SUCCESS \
          COLOR_DANGER COLOR_TREE COLOR_SEPARATOR COLOR_QUERY COLOR_MATCH_CURRENT \
          COLOR_CURRENT_BG COLOR_HEADER COLOR_BORDER COLOR_MENU_SEL_FG; do
  case "${!_c}" in
    '#'[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]) ;;
    [[:digit:]]|[[:digit:]][[:digit:]]|[01][[:digit:]][[:digit:]]|2[01234][[:digit:]]|25[012345]) ;;
    *) printf -v "$_c" '%s' -1 ;;
  esac
done
unset _c

# Render a configured colour into the escape/style each sink needs.  These set
# REPLY instead of printing: set_palette runs on every script invocation (each
# fzf callback re-execs the script), so a $(…) subshell per colour is pure
# overhead — ~30 forks that cost ~1s under load.
#   sgr_of  "#rrggbb" -> "38;2;r;g;b"   "NNN" -> "38;5;NNN"   -1/empty -> ""
# The hex arm names its digits even though the palette is normalised above: a
# bare '#'?????? let '#12345g' reach $((16#..)), which is fatal under set -e.
# Anything else starting with '#' falls to inherit, as it does in palette.rs.
sgr_of() {
  case "$1" in
    '#'[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]])
      REPLY="38;2;$((16#${1:1:2}));$((16#${1:3:2}));$((16#${1:5:2}))" ;;
    ''|-1|default|*[!0-9]*) REPLY="" ;;
    *) REPLY="38;5;$1" ;;
  esac
}
# esc/escb set REPLY to the SGR escape.  The trailing test/assignment always
# yields status 0 so they are safe as bare calls under set -e.
esc()  { sgr_of "$1"; [ -z "$REPLY" ] || REPLY=$'\033['"$REPLY"'m'; }  # coloured
escb() { sgr_of "$1"; REPLY=$'\033[1'"${REPLY:+;$REPLY}"'m'; }         # bold+coloured
# tmux style value (-S/-H, #[fg=]): a hex passes through, a bare index needs
# "colour", and inherit is spelled `default` -- tmux rejects `-1` ("invalid
# style"), and display-popup -S / display-menu -H then drop the WHOLE style
# without a word, so the palette's -1 has to be translated here.
tmux_color() {
  case "$1" in
    '#'[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]) REPLY="$1" ;;
    ''|-1|default|*[!0-9]*) REPLY=default ;;
    *) REPLY="colour$1" ;;
  esac
}

# fzf --color chrome, rebuilt from the palette (fzf accepts hex/index/-1 as-is,
# and the palette is normalised to exactly those above).
#
# The leading `dark` is a base scheme, not a colour: fzf REPLACES the whole
# accumulated theme when it meets one, so every key $FZF_DEFAULT_OPTS set is
# dropped in a single token, while @interdimux-fzf-opts (appended after this)
# still wins key by key.  Without it the keys this string does not name -- fg,
# bg, preview-fg/bg, preview-border, disabled -- came from the user's shell
# theme, and the popup was a blend of two palettes (measured: the user's fg on
# every row body, their preview border beside this border).  `dark` rather than
# enumerating those keys because an unknown key is FATAL (below), and it is
# safe on a light terminal too: every colour Dark256 and Light256 disagree on is
# one this string sets, and the rest are the terminal's own fg/bg.  It parses on
# every fzf this script supports.
#
# Except under NO_COLOR, where the base is `bw`.  From 0.53 fzf honours a
# non-empty NO_COLOR by starting from its colourless theme, which also drops the
# colours of --ansi rows (their bold/dim stay), and `dark` threw that choice out
# along with $FZF_DEFAULT_OPTS: every tree glyph, path and command came back
# coloured.  `bw` is a base scheme too, so it still discards the shell theme, and
# it restores exactly the base fzf would have chosen; the keys below still colour
# the chrome, as they always did.  The test is fzf's own (non-empty), and below
# 0.53 fzf ignores NO_COLOR, so `dark` stays.
build_fzf_colors() {
  local base=dark
  [ -n "${NO_COLOR:-}" ] && fzf_ge 53 && base=bw
  FZF_COLORS="--color=${base},hl:${COLOR_PATH},hl+:${COLOR_MATCH_CURRENT}:bold,bg+:${COLOR_CURRENT_BG},prompt:${COLOR_ACCENT},pointer:${COLOR_ACCENT},marker:${COLOR_SUCCESS},spinner:${COLOR_ACCENT},info:${COLOR_TREE},header:${COLOR_HEADER},border:${COLOR_BORDER},separator:${COLOR_BORDER},scrollbar:${COLOR_BORDER},label:${COLOR_PATH},preview-label:${COLOR_PATH},gutter:-1,query:${COLOR_QUERY}"
  # Every one of these names must exist in the running fzf: an unknown colour
  # key is FATAL ("invalid color specification"), not ignored, so a picker that
  # names `footer:` on fzf < 0.63 does not open at all.  Verified on 0.74.
  if fzf_ge 63; then
    FZF_COLORS+=",footer:${COLOR_HEADER}"
  fi
  # Make the ^] match scope visible in the rows themselves.  fzf's `nth:`
  # restyles the --nth fields independently of everything else, so the
  # SEARCHABLE columns become literally the bright part of the screen — and the
  # bright band moves live when change-nth fires, with no reload and no extra
  # bind.  Measured: the dim is OR'd onto each row's own --ansi colour rather
  # than replacing it, and a match can only ever land in a bright field, so hl
  # is never dimmed.
  #
  # All-or-nothing by construction: --color cannot be re-issued mid-session (no
  # change-color action exists), so it cannot apply "only when the scope is
  # non-default", and at the default `1,3` the context column is permanently
  # faint.  That is a taste call, hence @interdimux-scope-highlight.
  #
  # fg+ carries `regular:bold` with it on: fzf's fg+ default is bold, and
  # overriding only the COLOUR leaves that bold in place — so the current row's
  # non-searchable half came out bold AND dim at once, a combination whose
  # rendering is terminal-dependent.  `regular` clears the inherited dim, `bold`
  # puts back the line-wide bold, and the result is byte-identical to today's
  # current row.  Measured, both halves of it.
  # 66, not 58, even though `nth:` landed in 0.58: fzf's own CHANGELOG records
  # "Fixed a highlighting bug when using --color fg:dim,nth:regular pattern over
  # ANSI-colored items" against 0.65.1, and every row here is --ansi coloured.
  # fzf_ge compares the minor only, so 65 would still admit the buggy 0.65.0.
  if [ "$SCOPE_HIGHLIGHT" = "on" ] && fzf_ge 66; then
    FZF_COLORS+=",fg:dim,nth:regular,fg+:${COLOR_QUERY}:regular:bold"
  else
    FZF_COLORS+=",fg+:${COLOR_QUERY}"
  fi
}

# Resolve the palette into the escapes/vars used across the script.
set_palette() {
  esc  "$COLOR_ACCENT";            DIM_CMD="$REPLY"
  escb "$COLOR_ACCENT";            BOLD_AMBER="$REPLY"
  escb "$COLOR_ACCENT";            MARKER_COLOR="$REPLY"
  esc  "$COLOR_ACCENT";            ACCENT_ESC="$REPLY"
  esc  "$COLOR_PATH";              DIM_PATH="$REPLY"
  esc  "$COLOR_SSH";               DIM_SSH="$REPLY"
  esc  "$COLOR_EDITOR";            DIM_EDIT="$REPLY"
  esc  "$COLOR_GIT";               DIM_GIT="$REPLY"
  esc  "$COLOR_TREE";              DIM_TREE="$REPLY"
  esc  "$COLOR_SEPARATOR";         DIM_SEP="$REPLY"
  esc  "$COLOR_SUCCESS";           GREEN="$REPLY"
  esc  "$COLOR_DANGER";            RED="$REPLY"
  escb "$COLOR_DANGER";            BOLD_RED="$REPLY"
  SEP="${DIM_SEP}│${RST}"
  tmux_color "$COLOR_DANGER";      POPUP_BORDER_DANGER="$REPLY"
  tmux_color "$COLOR_ACCENT";      MENU_SEL_BG="$REPLY"
  tmux_color "$COLOR_MENU_SEL_FG"; MENU_SEL_FG="$REPLY"
  build_fzf_colors
}
set_palette

# Title style is a bold delta only — keeps the user's popup border colours.
POPUP_TITLE_STYLE='#[bold]'

# ---------------------------------------------------------------------------
# The hint bar
# ---------------------------------------------------------------------------
#
# It lives at the BOTTOM (fzf >= 0.63's --footer), not above the list.  The bar
# is rewritten on every cursor move, and at the top that put moving text exactly
# where the eye anchors while scrolling; lazygit, k9s and zellij all put keys at
# the bottom for the same reason.  Measured cost with --footer-border=none:
# exactly one list row, i.e. the same row the --header was already spending.
# (The default footer border draws a separator too and costs TWO — verified on
# fzf 0.74 at 20 rows: 18 without a bar, 17 with a header, 17 with a borderless
# footer, 16 with a bordered one.)
#
# Below 0.63 every --footer here is a --header, and nothing else changes.

# Hint builder: accent key + dim label pairs.  Sets REPLY.
#
# It no longer tracks a width.  It used to also set REPLY_W, for a hint_tiers
# that built every rung by calling back into here; that version was replaced by
# one which styles each hint once and cuts fragments out of the widest line, and
# computes its own widths as it goes.  Nothing has read REPLY_W since.
hint_r() {
  local out="" k l
  while [ $# -ge 2 ]; do
    k="$1" l="$2"
    shift 2
    out+="${ACCENT_ESC}${k}"$'\033[0m\033[2m '"${l}"$'\033[0m'
    [ $# -ge 2 ] && out+="  "
  done
  REPLY="$out"
}
hint() { hint_r "$@"; printf '%s' "$REPLY"; }

# Share of the picker's width the PREVIEW takes, as a percentage; the list gets
# the rest.  Empty means work it out: the navigator's preview is a runtime
# toggle, so it has to be detected.  Pickers whose geometry is fixed declare it —
# and they must, because an `execute` child inherits the NAVIGATOR's
# FZF_PREVIEW_COLUMNS and would otherwise halve a bar that has no preview at all.
#
# Stated as the preview's share rather than the list's so the arithmetic below
# can SUBTRACT it, which is not pedantry: at an odd width fzf hands the list the
# ceiling half, and `c * 50 / 100` rounds the other way and quietly costs a cell.
HINT_PREVIEW_PCT=""

# Cells the bar actually gets.  Measured on fzf 0.74: `list width - 3` — a
# two-cell left indent, and fzf keeps the last column for the scrollbar whether
# or not one is drawn.  A right-hand preview halves the list width while
# FZF_COLUMNS stays at the full window width (measured), so the preview state
# has to be folded in by hand; FZF_PREVIEW_COLUMNS is set exactly while the
# preview is visible, which is the fork-free way to ask.  Sets REPLY.
_hint_cols_cached=""
hint_cols() {
  if [ -n "$_hint_cols_cached" ]; then REPLY="$_hint_cols_cached"; return 0; fi
  local c pct="$HINT_PREVIEW_PCT"
  term_cols_r; c="$REPLY"
  if [ -z "$pct" ]; then
    pct=0
    if [ -n "${FZF_PREVIEW_COLUMNS:-}" ]; then
      pct=50
    elif [ -z "${FZF_COLUMNS:-}" ]; then
      # launch time: there is no fzf yet, so ask the state file the way the
      # renderer does
      live_preview_state_r
      [ "$REPLY" = "on" ] && pct=50
    fi
  fi
  REPLY=$(( c - c * pct / 100 - 3 ))
  [ "$REPLY" -lt 0 ] && REPLY=0
  # Memoised because this runs on the navigator's pre-first-frame path, where
  # every fork is counted (docs/PERFORMANCE.md).  Safe: a picker sets
  # HINT_PREVIEW_PCT once, before its first call, and the callbacks that DO need
  # a fresh width are separate processes.
  _hint_cols_cached="$REPLY"
  return 0
}

# The bindings one row type advertises, as (key label priority) triples.
#
# ONE definition, read by the navigator (which packs the tiers into env vars for
# fzf's inline focus bind) and by the --footer-for handler (the fallback for old
# fzf, or a user-supplied --with-shell).  These used to be two hand-kept lists
# and a test existed purely to catch them drifting apart.
#
# PRIORITY is the drop order when the bar does not fit: lowest goes first.
# `enter` leads because it is the one binding nothing has to advertise; `^]
# scope` survives longest because it is the least discoverable thing in the tool
# and, being last in the line, was the first casualty of plain truncation.
# Array ORDER is what the eye sees and is unchanged from the pre-tier bar.
#
# `^r reload` is on every row type because the Gone dialog and the "is gone"
# status message both tell you to press it; S/W/P used to leave it out, so the
# advice named a key the bar never showed.  It sits where the D and X sets put
# it, and at priority 1 it goes second, right after `enter`, when space is short.
hint_set() {
  local -a scope=()
  fzf_ge 58 && scope=('^]' scope 9)
  case "${1:-}" in
    S) HINT_SET=(enter switch 1  ^x kill 7  ^e rename 5  ^d detach 3  ^o new 4  ^r reload 1  ^/ preview 2) ;;
    W) HINT_SET=(enter switch 1  ^x kill 7  ^e rename 5  ^s swap 3     ^o new 4  ^r reload 1  ^/ preview 2) ;;
    P) HINT_SET=(enter switch 1  ^x kill 7  ^z zoom 5    ^s swap 4     ^t send 3 ^r reload 1  ^/ preview 2) ;;
    D) HINT_SET=(enter open 3    ^o new 4   ^r reload 1  ^/ preview 2) ;;
    *) HINT_SET=(enter switch 1  ^x kill 7  ^e rename 5  ^o new 4      ^r reload 3 ^/ preview 2)
       scope=() ;;
  esac
  HINT_SET+=(${scope[@]+"${scope[@]}"})
  return 0
}

# Every tier of one hint set, packed widest-first as "W:LINE|W:LINE|…|0:".
# A POSIX snippet can then pick the right tier from the live width with no fork,
# which is what keeps the bar correct across ^/ (the preview halves the list)
# and a client resize without paying a process per cursor move.  Sets REPLY.
hint_tiers() {
  # Each hint is styled ONCE and the rungs are joins of the survivors.  The
  # obvious form — rebuild the whole line with hint_r for every rung — restyles
  # the same seven strings eight times over, five times per open, on the path
  # that runs before fzf can draw its first frame.
  local -a hp=() frag=() w=()
  local i n=0 live=0 loi packed="" line lw first
  while [ $# -ge 3 ]; do
    frag+=("${ACCENT_ESC}${1}"$'\033[0m\033[2m '"${2}"$'\033[0m')
    w+=($(( ${#1} + 1 + ${#2} )))
    hp+=("$3")
    n=$(( n + 1 )); live=$(( live + 1 ))
    shift 3
  done
  # Build the widest rung once, then CUT one fragment out of it per rung rather
  # than rebuilding the line from its parts each time.  Rebuilding is
  # O(rungs x hints) and measured at 6-9 ms for the five ladders the navigator
  # packs before it can draw a first frame; one substitution per rung is O(rungs)
  # and lands around 2.  Fragments are unique (no two hints share a key AND a
  # label), so the substitution can only ever match the one meant.
  line="" lw=0 first=1
  for (( i = 0; i < n; i++ )); do
    if [ "$first" = 1 ]; then first=0; else line+="  "; lw=$(( lw + 2 )); fi
    line+="${frag[i]}"; lw=$(( lw + w[i] ))
  done
  # The drop order, once.  Re-scanning for the lowest priority on every rung is
  # O(rungs x hints) and was measured as the bulk of this function's cost; an
  # insertion sort over at most eight items pays that scan a single time.
  local -a order=()
  local j k
  for (( i = 0; i < n; i++ )); do
    for (( j = ${#order[@]}; j > 0; j-- )); do
      k="${order[j-1]}"
      [ "${hp[k]}" -le "${hp[i]}" ] && break
      order[j]="$k"
    done
    order[j]="$i"
  done

  local cut
  while :; do
    packed+="${lw}:${line}|"
    [ "$live" -eq 0 ] && break
    loi="${order[n - live]}"
    cut="${frag[loi]}"
    live=$(( live - 1 ))
    if [ "${line/"$cut  "/}" != "$line" ]; then
      line="${line/"$cut  "/}"; lw=$(( lw - w[loi] - 2 ))
    elif [ "${line/"  $cut"/}" != "$line" ]; then
      line="${line/"  $cut"/}"; lw=$(( lw - w[loi] - 2 ))
    else
      line="${line/"$cut"/}"; lw=$(( lw - w[loi] ))
    fi
  done
  REPLY="${packed%|}"
}

# Pick the widest packed tier that fits.  Nothing fits below the last one, and
# an EMPTY bar is the right answer there: a transform that emits nothing removes
# the footer section outright and the list reflows into the row (measured), so
# the floor costs nothing rather than showing a line cut mid-word.  Sets REPLY.
hint_pick() {
  local avail="$1" rest="$2" x
  REPLY=""
  while [ -n "$rest" ]; do
    x="${rest%%|*}"
    if [ "$x" = "$rest" ]; then rest=""; else rest="${rest#*|}"; fi
    if [ "${x%%:*}" -le "$avail" ]; then REPLY="${x#*:}"; return 0; fi
  done
  return 0
}

# One fitted bar for a picker that has no per-row variation.  Sets REPLY.
hint_bar_r() {
  local w
  hint_cols; w="$REPLY"
  hint_tiers "$@"
  hint_pick "$w" "$REPLY"
}

# The bar FLAG for such a picker, as an array — empty when nothing fits, because
# `--footer=''` still draws the section (measured: one blank list row) where
# omitting the flag entirely does not.  Sets HINT_FLAG.
#
# An array rather than a string so the call sites need no command substitution:
# these run before the first frame, and $( ) there is a fork the old code did
# not pay.
hint_flag() {
  hint_bar_r "$@"
  HINT_FLAG=()
  [ -n "$REPLY" ] && HINT_FLAG=(--"$HINT_BAR"="$REPLY")
  return 0
}

# Shared fzf theme — applied to all pickers for consistency.  Built once,
# tiered by fzf version so old installs keep a working (plainer) UI.
FZF_THEME=()
build_fzf_theme() {
  local info=inline
  fzf_ge 42 && info=inline-right
  # $FZF_DEFAULT_OPTS (and _FILE) is parsed before these flags, and some of what
  # people put there is layout a picker inside an already-sized popup can never
  # want, so it is cancelled here rather than merely warned about:
  #   --tmux/--popup  fzf ignores it outside tmux, which is why it gets set
  #     globally -- but in here $TMUX is set, so fzf opened a SECOND popup (a
  #     floating pane on tmux 3.7) and left this one blank, keys echoing into it.
  #     Every picker was dead.  --no-tmux arrived with --tmux in 0.53 and also
  #     cancels the 0.71 `--popup` spelling (one option, two names).
  #   --height        not full-screen inside a popup that is already sized.
  #   --border/--margin/--padding, and 0.58's --style presets and per-section
  #     borders: they shrink fzf's window without shrinking FZF_COLUMNS, which
  #     is what compute_widths and the hint bar are sized from, so every row
  #     came out too wide and was clipped.  `--style=default` goes FIRST
  #     because the preset also resets --info, the gutter colour, the separator
  #     and --highlight-line, all of which are set below.
  # Each reset is fzf's own default, so without $FZF_DEFAULT_OPTS the screen is
  # unchanged.  @interdimux-fzf-opts is appended last and can still ask for any
  # of them -- that is the channel for a deliberate choice.
  FZF_THEME=()
  fzf_ge 58 && FZF_THEME+=(--style=default)
  FZF_THEME+=(
    --no-height
    --no-border
    --margin=0
    --padding=0
    --ansi
    --reverse
    --cycle
    --info="$info"
    --pointer='▌'
    --ellipsis='…'
    --tabstop=1
    "$FZF_COLORS"
  )
  fzf_ge 52 && FZF_THEME+=(--highlight-line)
  fzf_ge 53 && FZF_THEME+=(--no-tmux)
  # The footer's DEFAULT border draws a separator line and costs a second row.
  # Borderless, the hint bar costs exactly the one row the header was already
  # spending, so moving it down is free.  Harmless with no --footer set
  # (measured: same visible row count either way).
  fzf_ge 63 && FZF_THEME+=(--footer-border=none)
  # 0.66 made the gutter a visible bar by default (and gutter:-1 no
  # longer hides it) — blank it so the pointer marks the current line
  fzf_ge 66 && FZF_THEME+=(--gutter=' ')
  # fzf runs every child (preview, header, reload, execute) through
  # `$SHELL -c`.  Pin a POSIX shell: it starts faster than an interactive
  # user shell that sources rc files, and INLINE_CALLBACKS below emits
  # POSIX `case` snippets that a fish $SHELL could not parse at all.
  fzf_ge 51 && FZF_THEME+=(--with-shell='sh -c')
  # User passthrough (@interdimux-fzf-opts), appended last so user colors
  # win; structural flags (delimiter/nth/binds) are added per-picker.
  if [ -n "$FZF_USER_OPTS" ]; then
    local -a _user=()
    # Unparseable user opts (e.g. an unbalanced quote in .tmux.conf) are
    # dropped rather than allowed to kill every entry point under set -e.
    # shellcheck disable=SC2086  # word-splitting the option string is the contract
    if ! eval "_user=($FZF_USER_OPTS)" 2>/dev/null; then
      _user=()
    fi
    FZF_THEME+=(${_user[@]+"${_user[@]}"})
  fi
}
build_fzf_theme

# Which end of the picker the hint bar lives at.  --footer and its
# transform/bg-transform actions arrived together in fzf 0.63 (checked against
# fzf's own CHANGELOG); below that every bar here is a header, exactly as
# before.  Both spellings are used verbatim in flags (--$HINT_BAR=) and in bind
# actions (transform-$HINT_BAR), which is the only reason one variable can carry
# the whole switch.
HINT_BAR=header
fzf_ge 63 && HINT_BAR=footer

# Whether the cheap fzf callbacks (per-row header, match-scope prompt) can be
# answered by an inline POSIX snippet instead of re-exec'ing this script.  Both
# only ever pick between strings this process already knows, so the re-exec was
# pure overhead on every cursor move.
#
# Off when: fzf is too old for --with-shell (< 0.51), or the user set their own
# --with-shell in @interdimux-fzf-opts — user opts are appended last and win, so
# the snippet could land in a shell with no POSIX `case` (fish).  Either way the
# --footer-for / --scope-prompt handlers below remain as the fallback.
INLINE_CALLBACKS=0
if fzf_ge 51; then
  case "$FZF_USER_OPTS" in
    *--with-shell*) ;;
    *) INLINE_CALLBACKS=1 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Directory picker: project detection & history
# ---------------------------------------------------------------------------

PROJECT_MARKERS=(.git Makefile package.json Cargo.toml go.mod pyproject.toml CMakeLists.txt .hg .svn build.gradle pom.xml mix.exs flake.nix)

# Additional user-defined markers (colon-separated)
#
# A marker that names the directory ITSELF is dropped, because is_project_root
# tests `[ -e "$dir/$m" ]`, and for an empty marker that is `[ -e "$dir/" ]`:
# true for every directory there is.  `read -a` keeps the empty field a doubled
# or leading ':' produces ('Move.toml::deno.json', ':Gemfile' -- only a TRAILING
# ':' is dropped), so one typo turned every scanned directory into a ◆ project.
# '.', '..', '/' and './' are the same mistake spelled differently.  A marker
# with a real name in it -- '.github/workflows' -- is kept.
if [ -n "$EXTRA_MARKERS" ]; then
  IFS=':' read -ra _extra_markers <<< "$EXTRA_MARKERS"
  for _m in "${_extra_markers[@]}"; do
    IFS='/' read -ra _m_parts <<< "$_m"
    _m_named=0
    for _p in ${_m_parts[@]+"${_m_parts[@]}"}; do
      case "$_p" in ''|.|..) ;; *) _m_named=1 ;; esac
    done
    [ "$_m_named" = 1 ] && PROJECT_MARKERS+=("$_m")
  done
  unset _m _p _m_parts _m_named
fi

# ---------------------------------------------------------------------------
# Filesystems whose stat() can block: never probed before the first paint
# ---------------------------------------------------------------------------
#
# Every row can cost probes before anything paints: the git badge walks
# `<dir>/.git` up to `/`, a directory row's type badge is up to 11 marker tests,
# and a recent/zoxide directory is checked for existence.  On a stalled
# NFS/CIFS/sshfs mount, or an automount point that has to (re)mount, each one
# blocks for the mount's timeout -- measured with a FUSE filesystem whose
# lookups stall for 1 s, ONE such directory in the recent list made --list take
# 11 s.  So a path on such a filesystem is not probed at all: no git badge, no
# type badge, and a recent/zoxide entry is offered without an existence check.
#
# Classified from /proc/self/mountinfo (INTERDIMUX_MOUNTINFO overrides it, for
# tests), read on first use; without it (macOS, BSD) nothing is skipped.  `/` and
# the filesystem $HOME is on are never skipped: the picker touches both anyway
# (bash, the recent list), and an NFS home keeps its badges.  The same table as
# rust/src/mounts.rs -- keep them in step.
#
# Read once per NAVIGATOR SESSION, not once per process: the navigator (when
# bash draws the list) and the ctrl-o picker classify it up front and hand it to
# every fzf callback in INTERDIMUX_MOUNTS (mounts_export), and a process that
# inherits that never opens the mount table.  Each parse had been 2-25 ms of
# bash on every --dirs-preview cursor move and every --list reload, twice per
# --dirs-list.  A mount that comes or goes while one picker is open is picked
# up by the next one.
#
# When the Rust core draws the navigator's list, bash classifies nothing up
# front -- that would be a parse on the way to the first frame -- and the core,
# which classifies anyway, writes its answer in the same form to the file
# INTERDIMUX_MOUNTS_FILE names, on every list it renders (rust/src/mounts.rs).
# A directory row's preview, Enter on one and ctrl-o read that file, and parse
# the table themselves only while it is not there yet (review B08).
_MOUNTS_READ=0
_MOUNT_BPS=()                 # the points that can block -- usually one to three
declare -A _MOUNT_TBL=()      # point -> 1 (can block) | 0; the LAST mount at a point wins
_MOUNT_UNDER=0                # is_remote_path's last path lies below a blocking point

_mounts_read() {
  _MOUNTS_READ=1
  _MOUNT_BPS=() _MOUNT_TBL=()
  local -a _me=()
  if [ -n "${INTERDIMUX_MOUNTS+set}" ]; then
    local IFS=$'\n' _noglob=0
    case $- in *f*) _noglob=1 ;; esac
    set -f
    _me=($INTERDIMUX_MOUNTS)
    [ "$_noglob" = 1 ] || set +f
    _mounts_import ${_me[@]+"${_me[@]}"}
    return 0
  fi
  # Only a file of our own: in a shared /tmp, anyone could have put one there.
  if [ -n "${INTERDIMUX_MOUNTS_FILE:-}" ] && [ -f "$INTERDIMUX_MOUNTS_FILE" ] \
     && [ -O "$INTERDIMUX_MOUNTS_FILE" ] && mapfile -t _me 2>/dev/null < "$INTERDIMUX_MOUNTS_FILE"; then
    _mounts_import ${_me[@]+"${_me[@]}"}
    return 0
  fi
  local f="${INTERDIMUX_MOUNTINFO:-/proc/self/mountinfo}"
  [ -r "$f" ] || return 0
  # One buffered read.  `while read` on a /proc file seeks back after every
  # line, and the kernel regenerates the table up to the offset for each seek.
  local -a _ml=() _mf=() _cand=()
  mapfile -t _ml 2>/dev/null < "$f" || return 0
  [ "${#_ml[@]}" -gt 0 ] || return 0
  local line point b any=0 k s IFS=$' \t\n' _noglob=0
  case $- in *f*) _noglob=1 ;; esac
  set -f   # the fields are split by the shell: a mount point must not glob
  for line in "${_ml[@]}"; do
    # "<id> <parent> <maj:min> <root> <point> <opts> [optional...] - <fstype> <src> <superopts>"
    # Split in C by word splitting, not by pattern expansions (a `${line#* - }`
    # costs as much as the rest of the loop): mountinfo escapes every blank in
    # a field, and the " - " is followed by exactly three fields.
    # ([[ ]] and (( )) throughout: this body runs once per mount, and the
    # table has hundreds of them where snaps or containers are about.)
    _mf=($line); k=${#_mf[@]}; s=$((k - 4))
    if ((s < 5)) || [[ ${_mf[s]} != - ]]; then
      s=1; while ((s < k)) && [[ ${_mf[s]} != - ]]; do s=$((s + 1)); done
      ((s >= 5 && s < k)) || continue
    fi
    case ${_mf[s+1]:-} in
      nfs|nfs4|cifs|smb3|smbfs|ncpfs|afs|ceph|coda|lustre|gpfs|orangefs|beegfs|autofs|fuse) b=1 ;;
      # 9p by its transport: over tcp or rdma a network share; over fd WSL2's
      # drvfs (/mnt/c), over virtio/unix/xen a VM's share of its host's disk
      9p) case ",${_mf[s+3]:-}," in *,trans=tcp,*|*,trans=rdma,*) b=1 ;; *) b=0 ;; esac ;;
      # FUSE backed by local storage keeps its badges; fuseblk is a local disk
      fuse.gocryptfs|fuse.encfs|fuse.cryfs|fuse.securefs|fuse.bindfs|fuse.mergerfs|fuse.unionfs|fuse.unionfs-fuse|fuse.fuse-overlayfs) b=0 ;;
      fuse.*) b=1 ;;
      # A local mount only matters once it can shadow, or sit inside, a
      # blocking one -- which, in mount order, is after the first of those.
      *) ((any)) || continue; b=0 ;;
    esac
    any=1
    point=${_mf[4]}
    [[ $point == *\\* ]] && { _mount_unescape "$point"; point=$_MOUNT_DEC; }
    _MOUNT_TBL[$point]=$b
    ((b)) && _cand+=("$point")
  done
  [ "$_noglob" = 1 ] || set +f
  [ "$any" = 1 ] || return 0
  # never skip what the picker touches anyway (see above)
  local p
  for p in / "$HOME"; do
    [ -n "$p" ] || continue
    _mount_of "$p" && _MOUNT_TBL["$_MOUNT_AT"]=0
  done
  _mounts_bps ${_cand[@]+"${_cand[@]}"} || return 0
  # ... and the filesystem $HOME RESOLVES onto.  tmux reports a pane's cwd
  # resolved, so a HOME that is a symlink onto a network mount (/home/u ->
  # /gpfs/home/u, as on some clusters) is used through the mount's own path:
  # exempting only the literal one left every pane there badge-less.  Resolved
  # (a fork) only when a component of it IS a symlink -- the same test as
  # rust/src/mounts.rs's resolved_home.
  case "$HOME" in /*) ;; *) return 0 ;; esac
  p="$HOME"
  while [ -n "$p" ] && [ "$p" != / ]; do
    if [ -L "$p" ]; then
      p=$(cd -P -- "$HOME" 2>/dev/null && pwd) || return 0
      [ -n "$p" ] && _mount_of "$p" && _MOUNT_TBL["$_MOUNT_AT"]=0
      _mounts_bps ${_cand[@]+"${_cand[@]}"} || :
      return 0
    fi
    p="${p%/*}"
  done
}

# A mount point as mountinfo writes it, decoded, in _MOUNT_DEC -- not REPLY,
# for the reason _MOUNT_AT gives below.  The kernel escapes exactly four bytes,
# each as a backslash and THREE octal digits: blank \040, tab \011, newline
# \012 and the backslash itself \134, so every backslash left in a field starts
# one of these.  Not printf %b: its \0 takes up to three digits MORE, so
# `nas\0401` -- the mount point `nas 1` -- came out as `nas` and the byte 0x01,
# which no path is on, and every path under that NFS mount was probed.  The
# backslash goes last, so `\134040` stays the literal `\040`.  rust/src/mounts.rs
# unescape() decodes the same.  (mounts_export writes the same escapes for a
# newline and a backslash, so its import decodes with this too.)
_mount_unescape() {
  local p="$1" bs='\' nl=$'\n' tab=$'\t'
  p=${p//\\040/ }
  p=${p//\\011/"$tab"}
  p=${p//\\012/"$nl"}
  _MOUNT_DEC=${p//\\134/"$bs"}
}

# _MOUNT_BPS = those of $@ that still block after the exemptions.  With none
# left the table is emptied, so every check is free, and the status is 1.
_mounts_bps() {
  _MOUNT_BPS=()
  local p
  local -A seen=()
  for p in "$@"; do
    [ "${_MOUNT_TBL[$p]:-0}" = 1 ] && ! [[ ${seen[$p]+x} ]] || continue
    seen["$p"]=1
    _MOUNT_BPS+=("$p")
  done
  [ "${#_MOUNT_BPS[@]}" -gt 0 ] && return 0
  _MOUNT_TBL=()
  return 1
}

# Hand the table to every child of this process -- fzf's preview and reload
# callbacks -- in INTERDIMUX_MOUNTS: one line per mount point that decides
# anything, "1<point>" for one that blocks and "0<point>" for a local mount
# inside one (a tmpfs on an NFS tree); no other local mount changes an answer.
# Empty means "classified, and nothing blocks"; unset, "not classified".  '\'
# and newline are escaped as mountinfo does, so a line is a line.
mounts_export() {
  [ "$_MOUNTS_READ" = 1 ] || _mounts_read
  local out="" p e bp keep
  if [ "${#_MOUNT_BPS[@]}" -gt 0 ]; then
    for p in "${!_MOUNT_TBL[@]}"; do
      if [ "${_MOUNT_TBL[$p]}" = 0 ]; then
        keep=0
        for bp in "${_MOUNT_BPS[@]}"; do
          case "$p" in "$bp"/*) keep=1; break ;; esac
        done
        [ "$keep" = 1 ] || continue
      fi
      e="${p//\\/\\134}"; e="${e//$'\n'/\\012}"
      out+="${_MOUNT_TBL[$p]}$e"$'\n'
    done
  fi
  export INTERDIMUX_MOUNTS="$out"
}

# $@ = the lines of such a hand-off (INTERDIMUX_MOUNTS, or the Rust core's file).
_mounts_import() {
  local -a _cand=()
  local e p
  for e in "$@"; do
    p="${e:1}"
    case "$p" in /*) ;; *) continue ;; esac
    case "$p" in *\\*) _mount_unescape "$p"; p=$_MOUNT_DEC ;; esac
    case "$e" in
      1*) _MOUNT_TBL["$p"]=1; _cand+=("$p") ;;
      0*) _MOUNT_TBL["$p"]=0 ;;
    esac
  done
  _mounts_bps ${_cand[@]+"${_cand[@]}"} || :
}

# _MOUNT_AT = the recorded mount point $1 is on (the longest one covering it).
# Not REPLY: the callers are REPLY-returning functions (get_git_branch,
# detect_project_type) that must not have theirs overwritten by the check.
_MOUNT_AT=""
_mount_of() {
  local p="$1"
  case "$p" in /*) ;; *) return 1 ;; esac   # relative: on no recorded mount
  while :; do
    [[ ${_MOUNT_TBL[$p]+x} ]] && { _MOUNT_AT="$p"; return 0; }
    [ "$p" = / ] && return 1
    p="${p%/*}"; [ -n "$p" ] || p=/
  done
}

# Is $1 on a filesystem whose stat can block?  Also sets _MOUNT_UNDER: 0 when
# no blocking point is $1 or above it -- and then none is above any ancestor of
# $1 either, which is how get_git_branch stops asking on its walk up.
is_remote_path() {
  [ "$_MOUNTS_READ" = 1 ] || _mounts_read
  _MOUNT_UNDER=0
  [ "${#_MOUNT_BPS[@]}" -gt 0 ] || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  # The blocking points are few: a path below none of them is answered by one
  # prefix test each.  Only one below one pays for the walk that asks whether
  # a local mount inside it (a tmpfs on an NFS tree) is what it is really on.
  local bp
  for bp in "${_MOUNT_BPS[@]}"; do
    case "$1" in "$bp"|"$bp"/*) _MOUNT_UNDER=1; break ;; esac
  done
  [ "$_MOUNT_UNDER" = 1 ] || return 1
  _mount_of "$1" && [ "${_MOUNT_TBL[$_MOUNT_AT]}" = 1 ]
}

is_project_root() {
  local dir="$1"
  for m in "${PROJECT_MARKERS[@]}"; do
    [ -e "$dir/$m" ] && return 0
  done
  return 1
}

# Sets REPLY instead of printing: callers run per-directory in hot
# loops, and a $(…) subshell fork per dir dominates the runtime there.
detect_project_type() {
  local dir="$1"
  REPLY=""
  is_remote_path "$dir" && return 0   # never probed (see is_remote_path)
  [ -f "$dir/Cargo.toml" ]      && { REPLY="Rust";    return; }
  [ -f "$dir/go.mod" ]          && { REPLY="Go";      return; }
  [ -f "$dir/package.json" ]    && { REPLY="Node.js"; return; }
  [ -f "$dir/pyproject.toml" ]  && { REPLY="Python";  return; }
  [ -f "$dir/CMakeLists.txt" ]  && { REPLY="C/C++";   return; }
  [ -f "$dir/build.gradle" ]    && { REPLY="Java";    return; }
  [ -f "$dir/pom.xml" ]         && { REPLY="Java";    return; }
  [ -f "$dir/mix.exs" ]         && { REPLY="Elixir";  return; }
  [ -f "$dir/flake.nix" ]       && { REPLY="Nix";     return; }
  [ -f "$dir/Makefile" ]        && { REPLY="Make";    return; }
  [ -d "$dir/.git" ]            && { REPLY="Git";     return; }
  return 0
}

RECENT_DIRS_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/interdimux/recent_dirs"

# Is $1 valid UTF-8?  Byte-wise, so the answer does not depend on the locale:
# the regex runs under LC_ALL=C, where a bracket range is a range of BYTES.  The
# same definition Rust's str::from_utf8 uses (no overlongs, no surrogates,
# nothing past U+10FFFF).  Pure ASCII -- nearly every path -- never reaches it.
_UTF8_SEQ=$'^([\x01-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf][\x80-\xbf]|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf]|[\xf1-\xf3][\x80-\xbf][\x80-\xbf][\x80-\xbf]|\xf4[\x80-\x8f][\x80-\xbf][\x80-\xbf])*$'
is_utf8() {
  case "$1" in *[![:ascii:]]*) ;; *) return 0 ;; esac
  local LC_ALL=C
  [[ "$1" =~ $_UTF8_SEQ ]]
}

# The character type the bash renderer and the dashboard's count run under,
# in REPLY: a UTF-8 locale name when bash would otherwise count BYTES and
# nothing in the environment chose that -- no LC_ALL, no LC_CTYPE, only a
# LANG that is C, missing or not installed, which is what a popup gets from a
# tmux server started without one.  "" when none is needed, or none works.
# The caller makes it `local LC_CTYPE`: not exported (none was), so the ps,
# sort and fzf it starts keep the environment's, and only bash's own ${#},
# ${s:0:n} and pattern matching change.  Under it the bash rows are the Rust
# core's -- widths, the 256-character title cut, the @interdimux-title-max
# cut, which counted bytes and could split a character (review R14).  An
# LC_ALL or LC_CTYPE the user set is left alone.  Tried once per process,
# fork-free: an assignment to LC_CTYPE is a setlocale(3) in bash.
_UTF8_CT=unset
utf8_ctype_r() {
  if [ "$_UTF8_CT" = unset ]; then
    _UTF8_CT=""
    local probe=$'\xe2\x94\x82' l
    if [ "${#probe}" != 1 ] && [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ]; then
      for l in C.UTF-8 C.utf8 en_US.UTF-8 UTF-8; do
        { LC_CTYPE="$l"; } 2>/dev/null
        if [ "${#probe}" = 1 ]; then _UTF8_CT="$l"; break; fi
      done
      unset LC_CTYPE
    fi
  fi
  REPLY="$_UTF8_CT"
}

# A directory whose name is not valid UTF-8 is skipped (is_utf8), in both
# renderers.  Listing it is worse than useless: fzf hands a selection back with
# every invalid byte replaced by U+FFFD, so the row names a directory that does
# not exist and can never be opened.  The Rust core skips the same lines.
#
# One on a filesystem whose stat can block is offered WITHOUT the existence
# check (is_remote_path) -- connect_dir reports it if it is gone.
load_recent_dirs() {
  local d count=0
  local -A _recent_seen=()
  if [ -f "$RECENT_DIRS_FILE" ]; then
    while IFS= read -r d; do
      is_utf8 "$d" || continue
      is_remote_path "$d" || [ -d "$d" ] || continue
      [[ ${_recent_seen[$d]+x} ]] && continue
      _recent_seen["$d"]=1
      echo "$d"
      count=$((count + 1))
      [ "$count" -ge "$RECENT_LIMIT" ] && break
    done < "$RECENT_DIRS_FILE"
  fi

  # Merge frecent dirs from zoxide when available
  if [ "$USE_ZOXIDE" = "on" ] && command -v zoxide >/dev/null 2>&1; then
    local zcount=0
    while IFS= read -r d; do
      is_utf8 "$d" || continue
      is_remote_path "$d" || [ -d "$d" ] || continue
      [[ ${_recent_seen[$d]+x} ]] && continue
      _recent_seen["$d"]=1
      echo "$d"
      zcount=$((zcount + 1))
      [ "$zcount" -ge "$RECENT_LIMIT" ] && break
    # --all: without it zoxide stats EVERY entry in its database to hide the
    # missing ones, so one entry on a stalled mount hangs zoxide itself.  The
    # existence check is the loop's own now; a zoxide too old for the flag gets
    # the plain query.
    done < <(zoxide query --list --all 2>/dev/null || zoxide query --list 2>/dev/null || true)
  fi
}

# Best-effort by design: remembering a directory is a convenience, and a
# read-only or full $XDG_DATA_HOME must not cost the user the switch they asked
# for.  Every step is silenced and bails out rather than propagating, because
# this runs inside the navigator under `set -e` and its stderr goes straight
# onto the popup, over the list.  (Observed with a 0500 data dir: mkdir and
# mktemp each printed "Permission denied" across the rendered rows, then the
# empty $tmp turned `echo > ""` into a third error.)
record_recent_dir() {
  local dir="$1"
  local dir_parent="${RECENT_DIRS_FILE%/*}"   # not `dirname`: this is a fork on every switch
  [ -d "$dir_parent" ] || mkdir -p "$dir_parent" 2>/dev/null || return 0

  # Rebuild the file: new dir first, then surviving entries (pruning
  # duplicates and dirs that no longer exist), atomically replaced.
  local tmp d count=1
  tmp=$(mktemp "$dir_parent/.recent_dirs.XXXXXX" 2>/dev/null) || return 0
  [ -n "$tmp" ] || return 0
  if ! echo "$dir" > "$tmp" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 0; fi
  if [ -f "$RECENT_DIRS_FILE" ]; then
    while IFS= read -r d; do
      [ "$d" = "$dir" ] && continue
      is_remote_path "$d" || [ -d "$d" ] || continue   # a stalled mount must not delay the switch
      echo "$d" >> "$tmp"
      count=$((count + 1))
      [ "$count" -ge 50 ] && break
    done < "$RECENT_DIRS_FILE"
  fi
  mv -f "$tmp" "$RECENT_DIRS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

resolve_finder() {
  if command -v fd >/dev/null 2>&1; then
    echo "fd"
  elif command -v fdfind >/dev/null 2>&1; then
    echo "fdfind"
  elif command -v find >/dev/null 2>&1; then
    echo "find"
  else
    echo ""
  fi
}

# When scanning all of $HOME (the fallback when no project dirs are
# configured), prune ~/Library: app caches and Chrome profiles are
# noise, and CloudStorage mounts there can stall traversal for seconds.
_scan_prune() {
  FD_EXCL=()
  FIND_PRUNE="//none"
  if [ "$1" = "$HOME" ]; then
    FD_EXCL=(--exclude /Library)
    FIND_PRUNE="$HOME/Library"
  fi
}

scan_dirs() {
  local root="$1" depth="$2" finder="$3"
  [ -d "$root" ] || return
  _scan_prune "$root"
  # Trailing slashes stripped: fd emits "dir/" while find emits "dir",
  # which breaks dedup between tiers and finder backends.
  case "$finder" in
    fd|fdfind)
      "$finder" --type d --max-depth "$depth" --absolute-path ${FD_EXCL[@]+"${FD_EXCL[@]}"} . "$root" 2>/dev/null | sed 's:/\{1,\}$::' || true
      ;;
    find)
      find "$root" -maxdepth "$depth" \( -path '*/.*' -o -path "$FIND_PRUNE" \) -prune -o -type d -print 2>/dev/null | sed 's:/\{1,\}$::' || true
      ;;
  esac
}

# Find dirs whose *name* contains the query, case-insensitively, using
# the finder's native matching — much deeper reach than scanning
# everything and filtering in bash.
match_dirs() {
  local root="$1" query="$2" depth="$3" finder="$4"
  [ -d "$root" ] || return
  _scan_prune "$root"
  case "$finder" in
    fd|fdfind)
      "$finder" --type d --fixed-strings -i --max-depth "$depth" --absolute-path ${FD_EXCL[@]+"${FD_EXCL[@]}"} -- "$query" "$root" 2>/dev/null | sed 's:/\{1,\}$::' || true
      ;;
    find)
      find "$root" -maxdepth "$depth" \( -path '*/.*' -o -path "$FIND_PRUNE" \) -prune -o -type d -iname "*$query*" -print 2>/dev/null | sed 's:/\{1,\}$::' || true
      ;;
  esac
}

resolve_search_paths() {
  local project_dirs="${INTERDIMUX_PROJECT_DIRS:-$(tmux show-option -gqv @interdimux-project-dirs 2>/dev/null || true)}"
  if [ -n "${project_dirs:-}" ]; then
    IFS=':' read -ra _paths <<< "$project_dirs"
    for p in "${_paths[@]}"; do
      # Safe tilde expansion without eval
      echo "${p/#\~/$HOME}"
    done
  else
    for d in "$HOME/projects" "$HOME/code" "$HOME/src" "$HOME/repos" "$HOME/work" "$HOME/dev"; do
      [ -d "$d" ] && echo "$d"
    done
  fi
}

# Shared helper for --dirs-list deep/scan modes: classify a dir as project or other
collect_dir() {
  local d="$1"
  if is_project_root "$d"; then
    _projects+=("$d")
  else
    _others+=("$d")
  fi
}

# Which session is a directory's -- the ONE answer, shared by everything that
# names or opens a directory's session: resolve_session_name (so connect_dir,
# ctrl-o's Enter and a D: row's Enter), --session-name-for, the find-or-create
# header, and the ctrl-o picker's "→ session" badge.  They used to ask three
# different questions:
#
#   * the badge keyed on #{session_path} whatever the session was called, while
#     Enter only ever looked at the session NAMED after the directory.  So `tmux
#     new -s foo` in ~/repo was badged "→ foo", and Enter created a second
#     session, `repo`, for the same directory.
#   * the name lookups went through `has-session -t "=NAME"` and "=NAME:", which
#     tmux reads as a session ID when NAME starts with '$'.  A directory called
#     "$work" never saw the existing "$work" session as taken, and connect_dir
#     (which matches names exactly) then switched into that session -- another
#     project's -- without a word.
#
# Now every one of them reads the same table through dir_session, which does
# its own exact string matching, and never asks tmux to parse a name.
#
# And it matches DIRECTORIES, not spellings (canon_dir, on both sides).  tmux
# keeps #{session_path} exactly as it was given: `-c ~/repo/` tab-completed
# keeps its slash, and a `tmux new -s bar` typed in a shell whose $PWD runs
# through a symlink keeps the logical path.  Enter resolves the row it opens
# with `pwd -P`, while the badge looked the row up as written -- so the badge
# on a zoxide row (logical, by default) promised `bar`, and Enter missed bar
# at the physical path and created a second session for the same directory.

# The table: each session's ID, name, start directory (#{session_path}, what
# `new-session -c` recorded; a `cd` never changes it) and its active pane's cwd,
# from ONE list-sessions.  SESS_AT maps a start directory to the session started
# there -- the one named after that directory when several were, else the first
# in tmux's (name) order -- and SESS_BYNAME a name to its row.
#
# A path holding a US or a newline would break the line apart; tmux blanks it
# instead (#{m/r:}), and a blank path matches no directory.  tmux refuses control
# characters in names, so neither can occur in one: a line is at most four
# fields.  The start directory is kept in its canon_dir form, the one
# dir_session looks a directory up by; the pane's cwd already is one (tmux reads
# it from the kernel).
#
# Captured once and split in-process -- lines, then each line's fields, by word
# splitting under set -f -- not `while read ... <<< "$(tmux ...)"`: a here-string
# that small is a pipe, and read takes a pipe one byte per syscall, two paths a
# line.  It sat before ctrl-o's first row (review B07).  Word splitting on US
# gives the fields `read` gave: a missing or trailing-empty one is unset, which
# reads as empty.
SESS_ID=() SESS_NAME=() SESS_SPATH=() SESS_CWD=()
declare -A SESS_AT=() SESS_BYNAME=()
load_session_table() {
  local id name spath cwd i=0 nl=$'\n' j l out _noglob=0
  local -a _sl=() _sf=()
  SESS_ID=() SESS_NAME=() SESS_SPATH=() SESS_CWD=() SESS_AT=() SESS_BYNAME=()
  out=$(tmux list-sessions -F "#{session_id}${US}#{session_name}${US}#{?#{m/r:[${US}${nl}],#{session_path}},,#{session_path}}${US}#{?#{m/r:[${US}${nl}],#{pane_current_path}},,#{pane_current_path}}" 2>/dev/null)
  case $- in *f*) _noglob=1 ;; esac
  set -f
  local IFS=$'\n'
  _sl=($out)
  IFS=$US   # nothing below splits but the one line
  for l in ${_sl[@]+"${_sl[@]}"}; do
    _sf=($l)
    id=${_sf[0]-} name=${_sf[1]-} spath=${_sf[2]-} cwd=${_sf[3]-}
    [ -n "$id" ] && [ -n "$name" ] || continue
    if [ -n "$spath" ]; then canon_dir "$spath"; spath="$REPLY"; fi
    SESS_ID[i]="$id" SESS_NAME[i]="$name" SESS_SPATH[i]="$spath" SESS_CWD[i]="$cwd"
    SESS_BYNAME["$name"]=$i
    if [ -n "$spath" ]; then
      j="${SESS_AT[$spath]-}"
      if [ -z "$j" ]; then
        SESS_AT["$spath"]=$i
      else
        dir_base_name "$spath"
        [ "${SESS_NAME[j]}" != "$REPLY" ] && [ "$name" = "$REPLY" ] && SESS_AT["$spath"]=$i
      fi
    fi
    i=$((i + 1))
  done
  [ "$_noglob" = 1 ] || set +f
  return 0
}

# canon_dir DIR -- REPLY is the directory DIR names, spelled one way: what
# `pwd -P` prints there, so every spelling of one directory -- a trailing or
# doubled '/', a path through a symlink -- comes out the same.  Both sides of
# "does this directory have a session" go through it: the start directories
# (load_session_table), the directory asked about (dir_session), and the
# navigator's directory rows in both renderers (emit_dir_rows, and canon_dir in
# rust/src/dirs.rs, which must stay in step).
#
# Without a fork, and without touching what cannot be touched safely:
#   * the builtin `cd -P`, then straight back.  ~40 us, where a $(cd; pwd -P)
#     is a fork per row of the ctrl-o picker.  Nothing here has a relative path
#     in flight, and the way back is the logical $PWD it came from.
#   * a path on a filesystem whose stat can block (is_remote_path) keeps its
#     spelling, only tidied: resolving it could hang the list on a stalled
#     mount, as every other probe of such a path could.  So a symlink INSIDE
#     such a mount is the one spelling still told apart from its target.
#   * so does a path that is not there, or not absolute: tmux keeps `-c .`
#     as ".", relative to a client long gone, and it names nothing now.
canon_dir() {
  local p="$1" here
  while [[ $p == *//* ]]; do p="${p//\/\///}"; done
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  REPLY="$p"
  case "$p" in /*) ;; *) return 0 ;; esac
  is_remote_path "$p" && return 0
  here="$PWD"
  builtin cd -P -- "$p" 2>/dev/null || return 0
  REPLY="$PWD"
  builtin cd -- "$here" 2>/dev/null || :
  return 0
}

# The session name a directory gets by default, in REPLY: its last component,
# with '.' and ':' (which tmux targets split at) made '-'.  In-process, because
# the ctrl-o picker asks this for every row; it is what `basename | tr '.:' '-'`
# printed, trailing slashes and trailing newlines dropped the same way.
dir_base_name() {
  local p="$1" nl=$'\n'
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  [ "$p" = / ] || p="${p##*/}"
  while [ "${p%"$nl"}" != "$p" ]; do p="${p%"$nl"}"; done
  REPLY="${p//[.:]/-}"
}

# The directory above $1, in REPLY -- dirname(1) for the paths used here.
path_parent() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  case "$p" in
    */*) p="${p%/*}"
         while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
         [ -n "$p" ] || p=/ ;;
    *) p=. ;;
  esac
  REPLY="$p"
}

# Does the session in table row $1 belong to directory $2, although it was not
# started there?  Only ever asked about a session whose NAME is the one the
# directory would get.
#
# The active pane's cwd is the second chance: AT the directory, or BELOW it for
# a session started on the same branch of the tree -- above it (`tmux new -s
# api` from ~, then `cd ~/work/api/src`) or inside it.  The branch condition
# keeps a same-named session from an unrelated directory, whose pane merely
# wandered in, from being mistaken for this one.
#
# It used to be the active pane's cwd alone, compared for equality, so a plain
# `cd src` inside the project -- or a second window opened in /tmp -- made the
# project's own session "a different directory": Enter on the project created
# `<parent>-<name>`, a second session for the same directory.  SESSION_DIRS
# (the navigator's directory rows) keys on the same #{session_path} for the same
# reason.
sess_row_at_dir() {
  local spath="${SESS_SPATH[$1]}" cwd="${SESS_CWD[$1]}"
  [ -n "$2" ] || return 1
  [ "$spath" = "$2" ] || [ "$cwd" = "$2" ] && return 0
  case "$cwd" in "$2"/*) ;; *) return 1 ;; esac
  [ -n "$spath" ] || return 1       # blanked: unknown, so no branch to be on
  [ "$spath" = / ] && return 0
  case "$2" in "$spath"/*) return 0 ;; esac
  case "$spath" in "$2"/*) return 0 ;; esac
  return 1
}

# dir_session DIR -- over the table load_session_table filled.  REPLY is the
# name of DIR's session; DIR_SID its ID when it exists already (Enter switches
# to it), empty when Enter would create it.
#
#   1. a session STARTED in DIR, whatever its name (the one named after DIR
#      when several were): a session's identity is where it began.
#   2. else the session named after DIR, if its pane is at or below DIR on the
#      same branch (sess_row_at_dir).
#   3. a same-named session from somewhere else is not reused: `<parent>-<name>`,
#      then `<name>-2`, `-3`... -- the first that is free or is DIR's.
#
# DIR is taken as canon_dir spells it, as the table's start directories are, so
# every spelling of a directory gets the same answer -- and the name is the one
# its physical path gives, which is where connect_dir creates it.
dir_session() {
  local dir name base i n
  REPLY="" DIR_SID=""
  [ -n "$1" ] || return 0
  canon_dir "$1"; dir="$REPLY"; REPLY=""
  i="${SESS_AT[$dir]-}"
  if [ -n "$i" ]; then
    REPLY="${SESS_NAME[i]}" DIR_SID="${SESS_ID[i]}"
    return 0
  fi
  dir_base_name "$dir"; name="$REPLY"
  [ -n "$name" ] || return 0
  i="${SESS_BYNAME[$name]-}"
  if [ -n "$i" ] && ! sess_row_at_dir "$i" "$dir"; then
    base="$name"
    path_parent "$dir"; dir_base_name "$REPLY"
    name="$REPLY-$base" n=2
    while i="${SESS_BYNAME[$name]-}"; [ -n "$i" ]; do
      sess_row_at_dir "$i" "$dir" && break
      name="$base-$n" n=$((n + 1))
    done
  fi
  REPLY="$name"
  [ -z "$i" ] || DIR_SID="${SESS_ID[i]}"
  return 0
}

# Derive a session name for a directory (see dir_session), on stdout.
resolve_session_name() {
  load_session_table
  dir_session "$1"
  printf '%s' "$REPLY"
}

# ---------------------------------------------------------------------------
# Session hydration — run a per-project startup command in a new session
# ---------------------------------------------------------------------------
#
# Resolution order, first match wins:
#   1. ~/.config/interdimux/startup.conf   "<glob><TAB or whitespace><command>"
#   2. a .interdimux-startup file in the directory itself (contents = command)
#   3. @interdimux-startup-command          (global fallback)
#
# Delivery is `send-keys`, deliberately, and not the pane's initial command.
# sesh shipped exec-based delivery in v2.26.0 and reverted it wholesale in
# v2.26.2: baking the command into the pane loses the prompt echo and the shell
# history entry, reparents the pane into a fresh shell when the command exits,
# and double-initialises the shell (breaking gitstatus/p10k).  send-keys keeps
# the command an ordinary thing the user typed.

# ---------------------------------------------------------------------------
# Typing a line into a pane
# ---------------------------------------------------------------------------
#
# Every place that types the user's text into a pane -- ctrl-t's send, startup
# commands, and both scheduled paths -- goes through send_line (directly, or via
# send_input / sh_send_input), because a bare `send-keys -- "$text" Enter` got
# three things wrong (all measured on tmux 3.7b):
#
#   * tmux's ARGV parser reads an argument ending in ';' as a command separator
#     and turns a trailing '\;' into ';'.  `find . -exec rm {} \;` arrived as
#     `... {} ;` (find: missing argument to -exec) while the dialog said
#     "sent"; `echo x;` failed outright ("unknown command: Enter"); and in the
#     scheduled paths, where the text was the last word, the ';' was silently
#     dropped.  One backslash before a trailing ';' undoes exactly what tmux
#     does to it: 'x;' is passed as 'x\;' and arrives as 'x;', and 'x\;' is
#     passed as 'x\\;' and arrives as 'x\;'.
#   * without -l every argument is first looked up as a KEY NAME, so a command
#     that is just `Enter` or `Home` was pressed rather than typed.  (Pressing
#     a key is kept, on purpose and in a narrower form: see send_input.)
#   * a pane in copy-mode reads keys as copy-mode bindings: the command never
#     ran, vi's `D` in "echo COPYMODE" copied into a NEW paste buffer on its way
#     out of the mode, and the dialog said only "1 failed".  `copy-mode -q`
#     leaves copy-mode and any other mode (a no-op for a pane in none), so the
#     command runs as if you had pressed q and typed it -- which is what sending
#     to that pane asked for, and what a scheduled command firing into a pane
#     you happen to have scrolled back needs too.  Refusing instead would turn
#     a W:/S: fan-out into a partial broadcast, and the mode was being left
#     anyway, minus the command.
#
# Enter is a send-keys of its own, so it stays a key (-l would type "Enter").
# The commands go in ONE tmux invocation, as a `\;` list: no extra fork per
# pane, and tmux stops at the first one that fails, so a vanished pane still
# reports failure.

# The argv word that reaches tmux as TEXT.  Sets REPLY.
tmux_text_arg() {
  case "$1" in
    *';') REPLY="${1%;}\\;" ;;
    *)    REPLY="$1" ;;
  esac
}

# send_line TARGET TEXT -- type TEXT into TARGET and press Enter.  Returns
# tmux's status.  -- so a command starting with '-' is not read as a flag.
send_line() {
  local target="$1"
  tmux_text_arg "$2"
  tmux copy-mode -q -t "$target" \; \
       send-keys -t "$target" -l -- "$REPLY" \; \
       send-keys -t "$target" Enter
}

# ctrl-t's send is titled "Send keys", and the one key worth sending on its own
# is C-c: interrupting what runs in a pane -- or, through a W:/S: fan-out, in
# every pane of a window or session.  So the interactive send and the scheduled
# sends (not startup commands, which are a list of commands to type) PRESS a
# text that is, as a whole, exactly one control or navigation key name in
# tmux's spelling -- C-x, M-x, C-M-x, ^x, Escape, the arrows, PPage/NPage,
# BTab, F1-F12 -- with no Enter after it.  Anything else, including `Enter`,
# `Home`, `c-c` and `C-c C-c`, is typed and then Enter is pressed: no command
# is spelled like one of these keys, while the keys a command might be (Enter,
# Home, End, Tab, Space) are left out.  Case-sensitive, like the rest of it.
send_key_name() {
  local ch cp
  case "$1" in
    Escape|Up|Down|Left|Right|PPage|NPage|BTab|F[1-9]|F1[0-2]) return 0 ;;
    C-M-?|M-C-?|C-?|M-?|^?) ch="${1: -1}" ;;
    *) return 1 ;;
  esac
  # A modifier takes one printable ASCII character.  tmux has no name for,
  # say, C-é, and would type it as text -- without the Enter.
  printf -v cp '%d' "'$ch" 2>/dev/null || return 1
  (( cp > 32 && cp < 127 ))
}

# send_input TARGET TEXT -- ctrl-t's send: press TEXT if it is a key name (see
# send_key_name), otherwise send_line it.  A pane in copy-mode leaves it first
# either way, so a C-c reaches the program rather than copy-mode's bindings.
send_input() {
  local target="$1"
  if send_key_name "$2"; then
    tmux_text_arg "$2"            # C-; would otherwise lose its ';' to tmux
    tmux copy-mode -q -t "$target" \; send-keys -t "$target" -- "$REPLY"
  else
    send_line "$target" "$2"
  fi
}

# sh_send_input TMUX TARGET TEXT -- send_input as a /bin/sh command line, for
# the paths that run later under a POSIX shell (the at job body and the
# sub-minute run-shell), where no bash function exists.  TMUX and TARGET are
# already sh words (e.g. 'tmux -S "$sock"' and '"$pane"'); TEXT is raw and is
# quoted here, with shq and never %q.  Sets REPLY.
sh_send_input() {
  local tm="$1" tg="$2"
  if send_key_name "$3"; then
    tmux_text_arg "$3"; shq "$REPLY"
    REPLY="$tm copy-mode -q -t $tg \\; send-keys -t $tg -- $REPLY"
    return 0
  fi
  tmux_text_arg "$3"; shq "$REPLY"
  REPLY="$tm copy-mode -q -t $tg \\; send-keys -t $tg -l -- $REPLY \\; send-keys -t $tg Enter"
}

# The note under the Send keys and Schedule fields: the key rule above is not
# something anyone would guess from a text field.
SEND_NOTE="${DIM}typed + Enter · a lone key name (C-c, Escape, Up) is pressed${RST}"

# The startup command for DIR, or empty.  Sets REPLY.
resolve_startup_command() {
  local dir="$1" conf="${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/startup.conf"
  REPLY=""

  # 1. glob table.  Patterns are matched against the absolute path; the first
  #    matching line wins, so put specific patterns above general ones.  A case
  #    glob's `*` also matches '/', so `~/code/*-cli` matches ~/code/a/b-cli.
  if [ -f "$conf" ]; then
    local line pat cmd rest home_p="" home_p_done=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"   # an indented line still counts
      case "$line" in ''|'#'*) continue ;; esac
      # A TAB, when there is one, is THE separator, so a pattern can contain a
      # space ("~/My Projects/*").  Otherwise the first run of whitespace.
      if [[ "$line" == *$'\t'* ]]; then
        pat="${line%%$'\t'*}"
        pat="${pat%"${pat##*[![:space:]]}"}"
        cmd="${line#*$'\t'}"
      else
        pat="${line%%[[:space:]]*}"
        cmd="${line#"$pat"}"
      fi
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      [ -n "$pat" ] && [ -n "$cmd" ] || continue
      case "$pat" in
        \~|\~/*)
          # bash never tilde-expands a variable's value, so `~/work/api*` --
          # the only form the README showed -- matched nothing.  Expand a
          # leading ~ (never ~user) by hand: the home part QUOTED so a glob
          # character in it is literal, the rest left a pattern.  $dir is a
          # physical path (pwd -P), so when $HOME is reached through a
          # symlink, also try the physical home.
          rest="${pat#\~}"
          # shellcheck disable=SC2254  # the rest is a glob by design
          case "$dir" in "${HOME%/}"$rest) REPLY="$cmd"; return 0 ;; esac
          if [ "$home_p_done" = 0 ]; then
            home_p_done=1
            home_p=$(cd "$HOME" 2>/dev/null && pwd -P) || home_p=""
            # an if, not `[ ] && home_p=`: that list's failure is the if's
            # status, and connect_dir runs under the navigator's set -e
            if [ "$home_p" = "$HOME" ]; then home_p=""; fi
          fi
          if [ -n "$home_p" ]; then
            # shellcheck disable=SC2254
            case "$dir" in "${home_p%/}"$rest) REPLY="$cmd"; return 0 ;; esac
          fi
          ;;
        *)
          # shellcheck disable=SC2254  # the pattern is a glob by design
          case "$dir" in $pat) REPLY="$cmd"; return 0 ;; esac
          ;;
      esac
    done < "$conf"
  fi

  # 2. per-project file (a .tmux-sessionizer-style drop-in, but read as text
  #    rather than executed, so it cannot silently run with the wrong cwd)
  if [ -f "$dir/.interdimux-startup" ]; then
    local content
    content=$(< "$dir/.interdimux-startup") || content=""
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    [ -n "$content" ] && { REPLY="$content"; return 0; }
  fi

  # 3. global default
  [ -n "$STARTUP_COMMAND" ] && REPLY="$STARTUP_COMMAND"
  return 0
}

# Block until a freshly created pane's shell is actually reading input.
#
# Measured caveat, so nobody over-trusts this: the pty line discipline already
# buffers keystrokes, so sending into a shell with a 1.2 s rc still ran the
# command correctly.  What the wait actually buys is (a) no raw pre-prompt echo
# of the command before the shell draws its prompt, and (b) safety for rc files
# that consume stdin themselves, which buffering does not survive.  It is cheap
# insurance and a cosmetic fix, not a correctness fix for the common case.
#
# A shell mid-init usually has a child (pyenv/nvm/compinit), so "no children" is
# a good readiness signal.  Bounded at ~2 s; degrades to a short sleep where
# /proc is unavailable.
wait_pane_ready() {
  local target="$1" tries="${2:-40}" pid i children
  if [ "$PROC_CMDLINE_OK" != 1 ]; then sleep 0.3; return 0; fi
  pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 0
  [ -n "$pid" ] || return 0
  for (( i = 0; i < tries; i++ )); do
    children=""
    { read -r children < "/proc/$pid/task/$pid/children"; } 2>/dev/null || :
    [ -z "${children// /}" ] && return 0
    sleep 0.05
  done
  return 0
}

# Send the resolved startup command to a newly created session's first pane.
hydrate_session() {
  local name="$1" dir="$2"
  [ "$HYDRATE" = "on" ] || return 0
  resolve_startup_command "$dir"
  local cmd="$REPLY"
  [ -n "$cmd" ] || return 0

  local target="=$name:"
  wait_pane_ready "$target"
  # One send per line, so a multi-line .interdimux-startup behaves like typing
  # each command in turn.  A CR from a CRLF file (startup.conf or the project
  # file) would be typed as a second Enter, so it goes.
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    send_line "$target" "$line" 2>/dev/null || true
  done <<< "$cmd"
  return 0
}

# $1 escaped, in REPLY, for a tmux argument that is FORMAT-EXPANDED and then
# kept as it comes out: new-session's -s and -c, rename-session and
# rename-window's new name.  Without it "proj#Sync" is stored as
# "proj<current session>ync".
#
# '##' is tmux's escape for '#' -- except in front of '['.  The expander copies
# a run of '#' that ends in '[' through untouched, whatever its length, because
# it may be a style for whatever draws the string later ("#[fg=red]").  So
# doubling EVERY '#' was an escape that changed the name it escaped: a directory
# "p#[q" became a session "p##[q" whose shell started in $HOME (no such -c
# directory), and the next Enter looked for "p#[q", found nothing, and failed on
# a duplicate.  The rule here -- double a run of '#' unless a '[' follows it --
# stores exactly what was typed, checked against tmux's stored names and paths
# for a few hundred random strings of '#', '[', ']', '{', '}', ',' and letters.
#
# Not for display-message: its text is expanded AND then drawn, and the drawing
# step reads "##[" as a literal "#[" -- there plain doubling is the escape
# (imux_msg).
esc_fmt() {
  local s="$1" out="" pre run
  while [[ $s == *'#'* ]]; do
    pre="${s%%'#'*}"; s="${s:${#pre}}"
    run="${s%%[!#]*}"; s="${s:${#run}}"
    out+="$pre$run"
    [[ $s == '['* ]] || out+="$run"
  done
  REPLY="$out$s"
}

# connect_dir DIR [SESSION_NAME]
#
# The single "open a directory as a session" path: switch to the session for
# DIR, creating (and hydrating) it first if it does not exist yet.  Both the
# dir picker's accept and the navigator's find-or-create used to carry their own
# slightly different copy of this; keeping one copy is what lets startup
# commands run no matter which route created the session.
#
# DIR must already be an absolute, physical path.  SESSION_NAME is derived from
# DIR when omitted (find-or-create passes its own, derived from the query).
# Runs under `set -e` in the navigator, so every fallible step is defused.
#
# Everything after the name is done by session ID, never by "=name":
#
#   * new-session FORMAT-EXPANDS both -s and -c, while a -t target is taken
#     literally.  A directory called "proj#Sync" was created as a session named
#     "proj<current session>ync" whose shell started in $HOME (the expanded -c
#     did not exist), and the switch-client that followed looked for the name as
#     typed, found nothing, and silently left the user where they were -- with a
#     junk session behind them and "duplicate session" on the next Enter.
#     Only the two expanded arguments are escaped, and by esc_fmt.
#   * the lookup goes through session_id_of, the one exact-name match: "=$1"
#     means session ID 1 to tmux whatever the '=' says, and "=c:d" cannot name
#     anything at all.
#
# The ID also goes to hydrate_session in place of the name: it builds "=$ID:",
# and tmux resolves a '$' session part as an ID before any name.
connect_dir() {
  local dir="$1" name="${2:-}" sid ename edir
  [ -n "$name" ] || name=$(resolve_session_name "$dir")
  [ -n "$name" ] || return 1

  session_id_of "$name"; sid="$REPLY"
  if [ -z "$sid" ]; then
    esc_fmt "$name"; ename="$REPLY"
    esc_fmt "$dir"; edir="$REPLY"
    sid=$(tmux new-session -d -P -F '#{session_id}' \
            -s "$ename" -c "$edir" 2>/dev/null) || return 1
    [ -n "$sid" ] || return 1
    hydrate_session "$sid" "$dir"
  fi
  tmux switch-client ${TMUX_C[@]+"${TMUX_C[@]}"} -t "$sid" 2>/dev/null || true
  REPLY="$name"
  return 0
}

# Remember a directory across the sources that rank it: interdimux's own recent
# list, and zoxide's frecency (so picking a dir here teaches `z` too).
record_dir_use() {
  local dir="$1"
  [ -n "$dir" ] && [ "$dir" != "$HOME" ] || return 0
  record_recent_dir "$dir" || true
  if [ "$USE_ZOXIDE" = "on" ] && command -v zoxide >/dev/null 2>&1; then
    zoxide add "$dir" 2>/dev/null || true
  fi
  return 0
}

# Sort and emit arrays of dirs by tier (projects first, then others)
emit_sorted_tiers() {
  if [ "${#_projects[@]}" -gt 0 ]; then
    while IFS= read -r d; do
      emit_dir "$d" project ""
    done < <(printf '%s\n' "${_projects[@]}" | sort -u)
  fi
  if [ "${#_others[@]}" -gt 0 ]; then
    while IFS= read -r d; do
      emit_dir "$d" dir ""
    done < <(printf '%s\n' "${_others[@]}" | sort -u)
  fi
}

# ---------------------------------------------------------------------------
# The pressing client
# ---------------------------------------------------------------------------
#
# INTERDIMUX_CLIENT is the #{client_name} of the client whose keypress started
# us.  Every binding captures it at keypress (--bind-keys), and --launch, the
# dashboard and the popup's -e flags carry it on from there.
#
# Without it every client-affecting command lets tmux pick "the current
# client", which for a command run from a popup or run-shell is the attached
# client with the most recent activity on the session holding $TMUX_PANE.  Keys
# typed into a popup or a menu never update that timestamp, so once the picker
# was open a single keystroke on ANOTHER terminal attached to the same session
# made that terminal "current": Enter switched it instead of yours, and the kill
# dialog's border repaint opened a blocking shell popup on it.
#
#   TMUX_C  "-c <client>" for switch-client, display-popup/-menu/-message
#   CUR_T   "-t <target>" naming where the pressing client is standing
#
# Unset -- a direct invocation, a hand-written binding -- keeps the old
# behaviour exactly.  Set but since detached, the -c calls fail and do nothing,
# which is the right outcome: the client that asked is gone, and acting on
# whichever one tmux would guess instead is the very bug.  "=<client>:" is a
# session target that tmux resolves through the client (exact name first, then
# the client lookup, before any prefix match), i.e. that client's session and
# the window it is showing.
#
# The value is validated because the dashboard bakes it into command strings
# that both /bin/sh and tmux's parser re-read; a tty path or tmux's own
# "client-<pid>" never contain anything outside this set.
TMUX_C=() CUR_T=()
case "${INTERDIMUX_CLIENT:-}" in
  ''|*[!A-Za-z0-9/._-]*) INTERDIMUX_CLIENT="" ;;
  *) TMUX_C=(-c "$INTERDIMUX_CLIENT") ;;
esac
if [ -n "$INTERDIMUX_CLIENT" ]; then
  CUR_T=(-t "=$INTERDIMUX_CLIENT:")
elif [ -n "${TMUX_PANE:-}" ]; then
  CUR_T=(-t "$TMUX_PANE")
fi

# A status-line message on the pressing client.  display-message FORMAT-EXPANDS
# its text, so '#' is doubled: a session called "a#Sb" is reported as exactly
# that, not with the current session's name spliced into it.  Every '#', even
# before a '[' (unlike esc_fmt): the expander keeps "##[" as it is, and the
# status line then draws it as a literal "#[" -- where a bare "#[b'" would be
# swallowed as a style.
#
# Every "interdimux: ..." status line goes through here.  A bare display-message
# lets tmux pick the client, and from a popup or run-shell it picks the one with
# the latest keypress -- another terminal on the same session, once a key was
# typed there while this one's picker or menu was open.
imux_msg() {
  local m="interdimux: $1"
  tmux display-message ${TMUX_C[@]+"${TMUX_C[@]}"} "${m//'#'/##}" 2>/dev/null || :
}

# The ID ($N) of the session named exactly NAME, in REPLY; empty when there is
# none.
#
# tmux's own name lookup cannot do this for every name.  It tests a leading '$'
# as a session ID BEFORE it tries names, and the '=' exact-match prefix does not
# stop it: "=$1:" is session ID 1, so a session NAMED "$1" had another session
# killed in its place after the dialog confirmed its name, and one named "$work"
# could not be reached at all.  A target is also split at its first ':', so no
# spelling of "=c:d" names a session called "c:d" (legal since tmux 3.7).  A
# plain string comparison over list-sessions has neither problem.  tmux escapes
# control characters in names, so neither US nor a newline can occur in one.
session_id_of() {
  local want="$1" id name
  REPLY=""
  while IFS="$US" read -r id name; do
    if [ "$name" = "$want" ]; then REPLY="$id"; return 0; fi
  done <<< "$(tmux list-sessions -F "#{session_id}${US}#{session_name}" 2>/dev/null)"
  return 0
}

# ---------------------------------------------------------------------------
# Spec parsing
# ---------------------------------------------------------------------------
#
# Spec format uses ":" as separator:
#   S:session_name
#   W:session_name:window_index
#   P:session_name:window_index:pane_index
#
# Since session names may contain ":", we parse indices from the right
# (indices are always plain numbers).

SPEC_TYPE="" SPEC_SESSION="" SPEC_WIDX="" SPEC_PIDX="" SPEC_DIR=""

parse_spec() {
  local spec="$1"
  SPEC_TYPE="${spec%%:*}"
  local rest="${spec#*:}"
  SPEC_DIR=""
  case "$SPEC_TYPE" in
    S)
      SPEC_SESSION="$rest"
      SPEC_WIDX=""
      SPEC_PIDX=""
      ;;
    D)
      # A directory row: the remainder is an absolute path, which may itself
      # contain ':' — take it whole rather than parsing from the right.
      SPEC_DIR="$rest"
      SPEC_SESSION=""
      SPEC_WIDX=""
      SPEC_PIDX=""
      ;;
    W)
      SPEC_WIDX="${rest##*:}"
      SPEC_SESSION="${rest%:*}"
      SPEC_PIDX=""
      ;;
    P)
      SPEC_PIDX="${rest##*:}"
      rest="${rest%:*}"
      SPEC_WIDX="${rest##*:}"
      SPEC_SESSION="${rest%:*}"
      ;;
  esac
}

# A target no session can match: '$' makes tmux read the rest as a session ID,
# and a non-number is never one.  Used when a spec names nothing, so the command
# FAILS rather than falling back to some default target.
NO_SUCH_TARGET='$missing'

# The tmux target for the parsed spec -- one that can only ever mean that
# session, window or pane, or nothing at all.
#
#   S  =NAME:            the trailing ':' matters: a bare "=e.f" is split at
#                        the '.', while "=e.f:" names the session e.f
#   W  =NAME:=WIDX       '=' before the index too.  Without it an index that no
#   P  =NAME:=WIDX.PIDX  longer exists is retried as a window NAME, prefix and
#                        glob included: "=st:3" found the window called "3rd"
#                        and ctrl-x killed it
#
# Names that no '=' form can reach -- a leading '$' (read as a session ID) or a
# ':' (split there) -- become "$ID" through session_id_of, and a name that
# matches nothing becomes NO_SUCH_TARGET.  Only those names pay for the extra
# list-sessions, so the preview's hot path forks nothing new.
spec_target() {
  local s
  case "$SPEC_TYPE" in
    D) printf '%s' "$SPEC_DIR"; return 0 ;;
    S|W|P) ;;
    *) printf '%s' "$NO_SUCH_TARGET"; return 0 ;;
  esac
  case "$SPEC_SESSION" in
    ''|'$'*|*:*) session_id_of "$SPEC_SESSION"; s="${REPLY:-$NO_SUCH_TARGET}" ;;
    *)           s="=$SPEC_SESSION" ;;
  esac
  # An index that is not a number came from a malformed spec, never from a row.
  case "$SPEC_TYPE" in
    W|P) case "$SPEC_WIDX" in ''|*[!0-9]*) s="$NO_SUCH_TARGET" ;; esac ;;
  esac
  case "$SPEC_TYPE" in
    P) case "$SPEC_PIDX" in ''|*[!0-9]*) s="$NO_SUCH_TARGET" ;; esac ;;
  esac
  case "$SPEC_TYPE" in
    S) printf '%s:' "$s" ;;
    W) printf '%s:=%s' "$s" "$SPEC_WIDX" ;;
    P) printf '%s:=%s.%s' "$s" "$SPEC_WIDX" "$SPEC_PIDX" ;;
  esac
}

# spec_at TARGET [FORMAT] -- is the W/P row parse_spec read still THAT window
# (pane)?  TARGET is spec_target's for it.  Status 1 when it is gone, or when
# TARGET now finds some other window: "=st:=3" still falls back to a window
# NAMED exactly "3" once index 3 has closed, so the preview showed that window's
# screen under the row for st:3, and Enter switched to it -- only --action, which
# compares the indices it gets back, said the row was gone.  When it is there,
# SPEC_AT is an exact target for it by ID ("$S:@W", "$S:@W.%P": in the row's
# session, whatever its name spells), and REPLY is FORMAT as tmux expanded it
# there -- put free text last in it.
#
# ONE round-trip, the same one --action's guard makes: has-session is the check
# that can fail (display-message resolves its target with CANFAIL, and answers a
# stale index with the session's current window), and a failed command ends the
# list, so a gone target prints nothing at all.
SPEC_AT=""
spec_at() {
  local info sid wid pid widx pidx
  SPEC_AT="" REPLY=""
  info=$(tmux has-session -t "$1" \; display-message -p -t "$1" \
    "#{session_id}${US}#{window_id}${US}#{pane_id}${US}#{window_index}${US}#{pane_index}${US}${2:-}" 2>/dev/null)
  IFS="$US" read -r sid wid pid widx pidx REPLY <<< "$info"
  [ -n "$wid" ] && [ "$widx" = "$SPEC_WIDX" ] || { REPLY=""; return 1; }
  case "$SPEC_TYPE" in
    W) SPEC_AT="$sid:$wid" ;;
    P) [ -n "$pid" ] && [ "$pidx" = "$SPEC_PIDX" ] || { REPLY=""; return 1; }
       SPEC_AT="$sid:$wid.$pid" ;;
    *) REPLY=""; return 1 ;;
  esac
  return 0
}

# Human-readable spec label for prompts
spec_label() {
  case "$SPEC_TYPE" in
    S) printf '%s' "session '$SPEC_SESSION'" ;;
    W) printf '%s' "window '$SPEC_SESSION:$SPEC_WIDX'" ;;
    P) printf '%s' "pane '$SPEC_SESSION:$SPEC_WIDX.$SPEC_PIDX'" ;;
    D) printf '%s' "directory '$SPEC_DIR'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Process lookup (for full-command resolution)
# ---------------------------------------------------------------------------
#
# Two backends.  On Linux we read /proc directly, one lookup per pane: no
# fork at all, and the cost scales with the number of panes rather than with
# the number of processes on the host.  `ps -eo` had to be forked AND its
# entire output walked before the first row could be emitted — 53-76 ms on a
# busy box, the single largest item ahead of first paint.
#
# Everywhere else (macOS/BSD) keep the ps table.  /proc/<pid>/task/<pid>/children
# needs CONFIG_PROC_CHILDREN (Linux >= 4.2), so probe rather than assume.
# INTERDIMUX_FORCE_PS=1 pins the ps backend — an escape hatch if a kernel ever
# disagrees, and how tests/test_full_command.sh proves the two agree.
PROC_CMDLINE_OK=0
if [ "${INTERDIMUX_FORCE_PS:-}" != 1 ] && [ -r "/proc/$$/task/$$/children" ]; then
  PROC_CMDLINE_OK=1
fi

declare -A PS_CHILDREN=()
declare -A PS_ARGS=()
declare -A PS_PGID=()
declare -A PS_TPGID=()

build_process_table() {
  [ "$PROC_CMDLINE_OK" = 1 ] && return 0   # /proc backend needs no table
  local pid ppid pgid tpgid args
  # pgid/tpgid ride along for pick_child: which child is the FOREGROUND job.
  # Every ps this runs on (procps, macOS, the BSDs) has both keywords, and args
  # stays last so it keeps its embedded spaces.
  while read -r pid ppid pgid tpgid args; do
    PS_ARGS[$pid]="$args"
    PS_PGID[$pid]="$pgid"
    PS_TPGID[$pid]="$tpgid"
    PS_CHILDREN[$ppid]+="$pid "
  done < <(ps -eo pid=,ppid=,pgid=,tpgid=,args= 2>/dev/null)
  return 0
}

# Render raw argv the way `ps args=` does, so both backends produce identical
# rows: NUL and newline become a space, every other non-printable byte becomes
# '?'.  This is not cosmetic.  ps was implicitly protecting the row contract —
# a raw newline in argv would split the row in two, detaching its trailing SPEC
# field, and a raw \x1f would reach an fzf-visible field.  The scan is guarded,
# so the common (clean) case costs one pattern test per class below.
#
# U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR become '?' as well, by
# name.  glibc's [[:cntrl:]] holds them, but that is the locale's say: the Rust
# core's rule was Cc only, so a cwd or a branch holding one rendered differently
# in the two renderers, and on a libc whose class leaves them out bash would
# pass them through too.  Both renderers now list them explicitly (rust/src/
# proc.rs sanitize), as bytes, so the test is the same in any locale.  So are
# the C1 controls (U+0080-009F, _C1): in a C locale [[:cntrl:]] is bytes and
# never sees one (review R14).
_LSEP=$'\xe2\x80\xa8' _PSEP=$'\xe2\x80\xa9' _C1=$'\xc2'[$'\x80'-$'\x9f']
sanitize_args() {
  REPLY="$1"
  case "$REPLY" in
    *[[:cntrl:]]*|*"$_LSEP"*|*"$_PSEP"*|*$_C1*) ;;
    *) return 0 ;;
  esac
  REPLY="${REPLY//$'\n'/ }"
  REPLY="${REPLY//"$_LSEP"/?}"
  REPLY="${REPLY//"$_PSEP"/?}"
  case "$REPLY" in *[[:cntrl:]]*|*$_C1*) ;; *) return 0 ;; esac
  _sanitize_cntrl
  return 0
}
# Every control left in REPLY made '?', in two substitutions over the BYTES: a
# C0 control or DEL is one byte, a C1 control (U+0080-009F) is \xc2 and one of
# \x80-\x9f -- \xc2 only ever leads a sequence, so that pair is always one
# character.  The class the Rust core names (char::is_control), in every
# locale.  It was a loop of ${REPLY:i:1}, which costs O(i) per character in a
# UTF-8 locale: a title of 8,000 characters with one U+0085 in it (tmux keeps
# C1 controls in titles) took 8 s (review R13).  A function, for the local
# LC_ALL.
_sanitize_cntrl() {
  local LC_ALL=C
  REPLY="${REPLY//[[:cntrl:]]/?}"
  REPLY="${REPLY//$_C1/?}"
}

# Space-joined argv of a pid, ps-style.  REPLY is empty when the process is
# gone — callers then fall back to tmux's own #{pane_current_command}, exactly
# as they already did when a pid raced out of the ps snapshot.
read_cmdline() {
  REPLY=""
  local pid="$1" a args=""
  [ -n "$pid" ] || return 0     # an empty pid would read /proc/cmdline: the KERNEL boot line
  # `read -r -d ''` rather than `mapfile -d ''`, which needs bash >= 4.4.
  # 2>/dev/null must come BEFORE the input redirect: bash applies redirections
  # left to right, so the other order still prints "No such file or directory"
  # when the pid races away mid-gather.
  while IFS= read -r -d '' a; do
    args+="$a "
  done 2>/dev/null < "/proc/$pid/cmdline"
  [ -n "$args" ] || return 0
  sanitize_args "${args% }"
  return 0
}

# The shells, by argv0 basename, each also with a login shell's leading '-'.
# A name is tested as
#
#   [[ "$SHELL_NAMES" == *" ${name#-} "* ]]
#
# -- a glob over this string.  Not a `[[ =~ ]]`: bash compiles a regex afresh on
# every test, and the bash renderer asks this of every row it draws (review
# #28).  Not a function either: in bash the call costs more than the test.  A
# name holds no blank, being argv0 cut at the first space.  rust/src/proc.rs
# is_shell is the same list.
SHELL_NAMES=' sh bash zsh fish dash ash ksh tcsh csh login '

# Is every word of $1 an option?  $1 is what follows argv0: empty, or starting
# with a blank.  The words are never split out -- unquoted they would glob --
# so a word that is not an option is a blank followed by anything but a blank
# or '-'.
#
# A shell and nothing but its options is an idle shell's argv: `-zsh`,
# `/bin/bash`, `bash --norc -i`, not `bash build.sh` or `sh -c …`.
# format_command dims such a row, and full_command looks through such a shell
# while something else is the foreground job.  rust/src/proc.rs is_idle_shell
# is the same rule.
only_options() {
  [[ "$1" != *[$' \t\n'][!$' \t\n'-]* ]]
}

# Process group and the controlling tty's foreground process group of a pid:
# REPLY="<pgrp> <tpgid>", either half empty when unknown.
#
# /proc/<pid>/stat is `pid (comm) state ppid pgrp session tty_nr tpgid ...`,
# read straight into words.  comm may itself hold blanks, ')' and even a
# newline, so it ends at the LAST word with a ')' in it: every field after comm
# is a number or a state letter.  comm is at most 15 bytes (TASK_COMM_LEN), and
# "(" + 15 bytes + ")" splits into at most NINE words -- ` a b c d e f g `
# gives `( a b c d e f g )`, its '(' a word of its own -- so that word is one
# of f[1]..f[9].  (Bounded at f[8], such a name came back unknown, or with its
# ppid and tty read as the ids.)  f[9] is otherwise a number or the state, so
# looking one word further never matches wrongly.  The usual comm (no blank,
# so f[1] is all of it) is one test.
#
# No regex and no whole-line pattern strip.  `${line##*) }` over the ~300-byte
# line is quadratic in its length, and with the regex after it cost ~0.3 ms a
# call, for every shell with two or more children the bash renderer draws
# (review #29).
proc_group_ids() {
  REPLY=""
  local pid="$1" f=() i last=0
  [ -n "$pid" ] || return 0
  if [ "$PROC_CMDLINE_OK" = 1 ]; then
    { IFS=$' \t\n' read -r -d '' -a f < "/proc/$pid/stat"; } 2>/dev/null || :
    if [[ "${f[1]-}" == *')' && "${f[*]:2:7}" != *')'* ]]; then
      last=1
    else
      for (( i = 1; i <= 9 && i < ${#f[@]}; i++ )); do
        case "${f[i]}" in *')'*) last=$i ;; esac
      done
      [ "$last" -gt 0 ] || return 0
    fi
    [ -n "${f[last+6]-}" ] || return 0      # a vanished or short record: unknown
    REPLY="${f[last+3]} ${f[last+6]}"
  else
    REPLY="${PS_PGID[$pid]:-} ${PS_TPGID[$pid]:-}"
  fi
  return 0
}

# Which of a shell's direct children is the command to show.  REPLY = a pid.
#
# The one in the pane tty's FOREGROUND process group — the job the shell is
# waiting on, the same process tmux's own #{pane_current_command} names.  Not
# simply the first child: that is the OLDEST one, so a job backgrounded earlier
# (or stopped with ^Z, or a shell plugin's helper) shadowed whatever ran in the
# foreground after it.  In order:
#   * the job leader itself, when it is one of the shell's children;
#   * else the first child in that group — a pipeline whose leader already
#     exited (`cat f | less`) keeps the dead leader's pid as its group id;
#   * else the first child: the shell is itself in the foreground (at its
#     prompt, jobs only in the background), or the foreground belongs to
#     something that is not the shell's direct child.  Never walk deeper.
# One child needs no lookup at all: every rule above picks it.
pick_child() {
  local pid="$1" children="$2" first c fg
  first="${children%% *}"
  REPLY="$first"
  [[ "${children#"$first"}" == *[0-9]* ]] || return 0
  proc_group_ids "$pid"; fg="${REPLY#* }"
  REPLY="$first"
  case "$fg" in ''|0|-*|"$pid") return 0 ;; esac
  case " $children " in *" $fg "*) REPLY="$fg"; return 0 ;; esac
  for c in $children; do
    proc_group_ids "$c"
    [ "${REPLY%% *}" = "$fg" ] && { REPLY="$c"; return 0; }
  done
  REPLY="$first"
  return 0
}

# Get the user's actual command from a pane pid.
# Strategy: if the pane process is a shell, show one of its direct children
# (the command the user typed — pick_child says which).  Do NOT walk further —
# deeper children are subprocesses of that command (LSPs, formatters,
# watchers, …) and showing those is misleading.
#
# One exception: a child that is itself an interactive shell (`bash`, `zsh -f`:
# a shell and nothing but options, see only_options) and is NOT the tty's
# foreground group is running something -- the user typed `bash`, then a
# command in it.  Look through it the same way, so the row names that command,
# as tmux's #{pane_current_command} does.  Without this the busy nested shell's
# own argv was shown, and format_command drew it as an idle shell (review #24).
# A nested shell that IS the foreground group sits at its own prompt: it is
# the answer.  Only such shells are looked through, at most NESTED_SHELL_MAX
# deep -- never a command's subprocesses, nor a shell running a script.
#
# The shell test MUST come from the pane process's own argv.  tmux's
# #{pane_current_command} names the pane tty's FOREGROUND process group, which
# is the running command, not the shell — so gating on it inverts the test
# exactly when a command is running and every busy pane renders as "-zsh".
NESTED_SHELL_MAX=4
full_command() {
  local pid="$1" args children child fg depth=0 c0

  if [ "$PROC_CMDLINE_OK" = 1 ]; then
    read_cmdline "$pid"; args="$REPLY"
  else
    args="${PS_ARGS[$pid]:-}"
  fi

  local cmd_name="${args%% *}"
  cmd_name="${cmd_name##*/}"

  # If the pane process is a shell, look one level down -- and on through
  # nested interactive shells that are busy
  if [[ "$SHELL_NAMES" == *" ${cmd_name#-} "* ]]; then
    while :; do
      if [ "$PROC_CMDLINE_OK" = 1 ]; then
        children=""
        # The children file has NO trailing newline, so `read` assigns the
        # value and THEN reports EOF.  A `|| children=""` fallback here would
        # wipe what it just read and silently disable child resolution for
        # every pane.
        { read -r children < "/proc/$pid/task/$pid/children"; } 2>/dev/null || :
      else
        children="${PS_CHILDREN[$pid]:-}"
      fi
      [ -n "$children" ] || break
      pick_child "$pid" "$children"; child="$REPLY"
      if [ "$PROC_CMDLINE_OK" = 1 ]; then
        read_cmdline "$child"
      else
        REPLY="${PS_ARGS[$child]:-}"
      fi
      # The pick is the answer unless it is an interactive shell -- the name
      # first: it is rarely a shell at all.
      c0="${REPLY%% *}"; c0="${c0##*/}"
      [[ "$SHELL_NAMES" == *" ${c0#-} "* ]] && [ "$depth" -lt "$NESTED_SHELL_MAX" ] \
        && only_options "${REPLY#"${REPLY%% *}"}" || return 0
      # A nested interactive shell: busy unless it is the foreground group.
      args="$REPLY"
      proc_group_ids "$child"; fg="${REPLY#* }"
      case "$fg" in ''|0|-*|"${REPLY%% *}") REPLY="$args"; return 0 ;; esac
      pid="$child"; depth=$(( depth + 1 ))
    done
  fi

  # Not a shell, or a shell with no children — use as-is
  REPLY="$args"
  return 0
}

# Resolve the command string to display for a pane.  Sets REPLY.
resolve_command() {
  # tabs sanitized out: the command lands in a tab-delimited row field
  local short_cmd="${1//$'\t'/ }" pid="$2"
  if [ "$SHOW_FULL_COMMAND" = "on" ]; then
    local fcmd
    full_command "$pid"; fcmd="$REPLY"
    fcmd="${fcmd//$'\t'/ }"
    fcmd="${fcmd#"${fcmd%%[![:space:]]*}"}"
    fcmd="${fcmd%"${fcmd##*[![:space:]]}"}"
    [ -n "$fcmd" ] && { REPLY="$fcmd"; return; }
  fi
  REPLY="$short_cmd"
}

# ---------------------------------------------------------------------------
# Git branch (pure bash — no subprocess per pane)
# ---------------------------------------------------------------------------

declare -A GIT_BRANCH_CACHE=()

get_git_branch() {
  local dir="$1"
  REPLY=""
  [ "$SHOW_GIT_BRANCH" != "on" ] && return
  [ -z "$dir" ] && return

  local _cache_key="$dir"
  if [[ ${GIT_BRANCH_CACHE[$_cache_key]+x} ]]; then
    REPLY="${GIT_BRANCH_CACHE[$_cache_key]}"
    return
  fi

  # Up to and INCLUDING "/", as git's own discovery walks (and rust/src/git.rs):
  # a repository at the root is a repository.  $b is the directory with its
  # trailing slash dropped, so the root's marker is "/.git", not "//.git".
  local d="$dir" b _chk=1
  while [ -n "$d" ]; do
    # Never probe a filesystem whose stat can block (is_remote_path): the walk
    # stops there, badge-less, rather than stall the first paint.  Once a level
    # is below no blocking mount point at all, nothing above it is either, and
    # the rest of the walk is not asked again.  (Not "ask once, at the start":
    # a local mount inside an NFS tree is not blocking, but its parent is.)
    if [ "$_chk" = 1 ]; then
      is_remote_path "$d" && break
      [ "$_MOUNT_UNDER" = 1 ] || _chk=0
    fi
    b="${d%/}"
    local head_file=""
    # A .git DIRECTORY counts only with a HEAD in it, as git's own discovery
    # has it: an empty one (a half-made clone, a stray `mkdir .git` inside a
    # repo) is skipped and the walk goes on to the enclosing repository.
    if [ -d "$b/.git" ]; then
      [ -f "$b/.git/HEAD" ] && head_file="$b/.git/HEAD"
    elif [ -f "$b/.git" ]; then
      # Worktrees/submodules: .git is a file containing "gitdir: <path>".
      # `read` reports EOF on a last line with no newline AFTER assigning it --
      # the trap live_preview_state documents -- so the status is ignored and
      # the VALUE decides.  `|| continue` here threw away a newline-less
      # gitdir file that the Rust core (and git) read.  A CRLF file keeps its
      # CR through `read`; git and the Rust core strip it.
      local gitdir_line=""
      { read -r gitdir_line < "$b/.git"; } 2>/dev/null || :
      gitdir_line="${gitdir_line%$'\r'}"
      if [ -n "$gitdir_line" ]; then
        local gitdir="${gitdir_line#gitdir: }"
        # Resolve relative paths
        case "$gitdir" in
          /*) ;;
          *)  gitdir="$b/$gitdir" ;;
        esac
        is_remote_path "$gitdir" && break   # a worktree whose repository is on one
        [ -f "$gitdir/HEAD" ] && head_file="$gitdir/HEAD"
      fi
    fi

    if [ -n "$head_file" ]; then
      # The same EOF trap: a HEAD written without a trailing newline (by a
      # tool, or by hand) is a valid HEAD to git, and `read || break` dropped it.
      local head_content=""
      { read -r head_content < "$head_file"; } 2>/dev/null || :
      head_content="${head_content%$'\r'}"
      [ -n "$head_content" ] || break
      local branch=""
      case "$head_content" in
        "ref: refs/heads/"*) branch="${head_content#ref: refs/heads/}" ;;
        *) branch="@${head_content:0:7}" ;;
      esac
      GIT_BRANCH_CACHE["$_cache_key"]="$branch"
      REPLY="$branch"
      return
    fi
    [ "$d" = "/" ] && break
    case "$b" in */*) ;; *) break ;; esac   # relative: nothing above it to walk to
    d="${b%/*}"
    [ -n "$d" ] || d="/"
  done

  GIT_BRANCH_CACHE["$_cache_key"]=""
}

# ---------------------------------------------------------------------------
# Smart command formatting (SSH host, editor context)
# ---------------------------------------------------------------------------

# Every classification below is a `case` glob, never a `[[ =~ ]]`: bash
# compiles a regex afresh on every test, about 20-25 us each, and the bash
# renderer formats every window row and every pane row (review #28).  The Rust
# core's format.rs holds the same tables.
#
#   editors                       vim nvim vi nano emacs code hx helix micro
#                                 kate gedit subl
#   ssh flags taking a value      -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p
#                                 -Q -R -S -W -w
#   editor flags taking a value   -u -U -s -S -p -c --cmd --listen
#   interpreters (whose first     python and lua, each with an optional
#   argument, when it is a path,  version of digits and dots; node nodejs ruby
#   is the script they run)       perl php; and the shells (SHELL_NAMES)
format_command() {
  local cmd_str="$1"
  REPLY=""                       # reset: callers read REPLY after a bare call
  [ -z "$cmd_str" ] && return
  local cmd_name="${cmd_str%% *}"
  local cmd_base="${cmd_name##*/}"
  local rest="${cmd_str#"$cmd_name"}"

  # Disable globbing for word-splitting of arguments
  local old_set="$-"
  set -f

  # SSH: highlight user@host
  case "$cmd_base" in
    ssh|mosh)
      local host="" skip_next=""
      local args="${cmd_str#* }"
      [ "$args" = "$cmd_str" ] && args=""
      local word
      for word in $args; do
        if [ -n "$skip_next" ]; then
          skip_next=""
          continue
        fi
        case "$word" in
          -[bcDEeFIiJLlmOopQRSWw]) skip_next=1 ;;
          -*) ;;
          *)  host="$word" ;;
        esac
      done
      if [ -n "$host" ]; then
        [[ "$old_set" != *f* ]] && set +f
        printf -v REPLY '%s%s %s%s%s' "$DIM_CMD" "$cmd_base" "$DIM_SSH" "$host" "$RST"
        return
      fi
      ;;
  esac

  # Editors: highlight the file being edited
  local is_ed=0
  case "$cmd_base" in vim|nvim|vi|nano|emacs|code|hx|helix|micro|kate|gedit|subl) is_ed=1 ;; esac
  if [ "$is_ed" = 1 ]; then
    local file="" skip_next=""
    local args="${cmd_str#* }"
    [ "$args" = "$cmd_str" ] && args=""
    local word
    for word in $args; do
      if [ -n "$skip_next" ]; then
        skip_next=""
        continue
      fi
      case "$word" in
        -[uUsSpc]|--cmd|--listen) skip_next=1 ;;
        -*) ;;
        +*) ;;  # vim +line / +/pattern
        *)  file="$word" ;;
      esac
    done
    if [ -n "$file" ]; then
      local fname="${file##*/}"
      [[ "$old_set" != *f* ]] && set +f
      printf -v REPLY '%s%s %s%s%s' "$DIM_CMD" "$cmd_base" "$DIM_EDIT" "$fname" "$RST"
      return
    fi
  fi

  [[ "$old_set" != *f* ]] && set +f

  # Asked once, answered for both rules below.
  local is_sh=0
  [[ "$SHELL_NAMES" == *" ${cmd_base#-} "* ]] && is_sh=1

  # An idle shell — the shell and nothing but its options: `-zsh`, `/bin/bash`,
  # `bash --norc -i`.  Its bare name, in the tree colour, so the rows doing real
  # work are the ones in the accent (IDEAS #10).  A shell running something
  # (`bash build.sh`, `sh -c …`) is real work and falls through.
  if [ "$is_sh" = 1 ] && only_options "$rest"; then
    printf -v REPLY '%s%s%s' "$DIM_TREE" "${cmd_base#-}" "$RST"
    return
  fi

  # Everything else, with argv0 by its basename: `/usr/bin/python3 -c …` spent
  # nine of the column's cells on `/usr/bin/`.  An argv0 that ends in '/' has
  # no basename and keeps the whole word.  An interpreter running a script by
  # path shows the script's basename too — a `#!/usr/bin/python3` script reads
  # `python3 tool.py`, not `/usr/bin/python3 /home/…/bin/tool.py`.  Only the
  # word straight after argv0 is considered, never an option.
  local is_int="$is_sh"
  case "$cmd_base" in
    # a version is digits and dots only: python3.12 is one, pythonw is not.
    # The digits are listed, not ranged: a range follows the locale's collation.
    python*) [[ "${cmd_base#python}" == *[!0123456789.]* ]] || is_int=1 ;;
    lua*)    [[ "${cmd_base#lua}" == *[!0123456789.]* ]] || is_int=1 ;;
    node|nodejs|ruby|perl|php) is_int=1 ;;
  esac
  if [ "$is_int" = 1 ]; then
    local r1="${rest# }" w1
    w1="${r1%% *}"
    if [[ "$w1" != -* && "$w1" == */* ]] && [ -n "${w1##*/}" ]; then
      rest=" ${w1##*/}${r1#"$w1"}"
    fi
  fi
  printf -v REPLY '%s%s%s%s' "$DIM_CMD" "${cmd_base:-$cmd_name}" "$rest" "$RST"
}

# ---------------------------------------------------------------------------
# Agents: what an AI coding agent's pane tells tmux, shown in the command field
# ---------------------------------------------------------------------------
#
# tmux's own choose-tree (prefix+w) adds `: "#{pane_title}"` to a pane's row
# whenever a program has set a title, which is why it can say what a Claude or
# Codex pane is working on and this list could not.  Three signals, all read in
# the one batched query or from a file, none of them costing a fork:
#
#   * the pane title (OSC 0/2).  Claude Code sets `✳ <session title>`; under
#     tmux the glyph is ALWAYS ✳, so it says nothing about state.  Codex sets
#     `<spinner> <thread> | <project>` while working and `[ ! ] Action
#     Required | …` while it waits for an approval.
#   * Claude Code's own session registry, ~/.claude/sessions/<pid>.json: its
#     status (busy / waiting + what for / idle) and the tmux pane it runs in.
#     See claude_registry_r.
#   * the command: npm and pip installs run as `node …/bin/codex` or
#     `python …/bin/aider`, which the row names by the agent (agent_of).
#
# The result stays inside field 3, the command, as plain words:
#
#   claude working 2m Project review and suggestions
#
# so `approve` or a word of the title finds the row under the default search
# scope, and nothing about the columns changes.  rust/src/agent.rs is the same
# code; tests/test_agents.sh and the agents corpus hold the two to it.

# Recognised by argv0's basename.  AGENT_SCRIPTS are the ones npm or pip
# install as a script an interpreter runs, recognised by the script's basename.
# @interdimux-agents adds names to both lists; `off` empties them.  That stops
# only the NAMING (`codex` for `node .../codex`, the arguments dropped): title
# rules are picked by the command's name, Claude's registry by pane, and
# whether a state shows is @interdimux-agent-state's.  So under `off` a native
# `codex` still gets its state from its title, after its whole command line
# (the layout of any row that is not an agent's), while `node .../codex` is
# node to the rules and gets none.  The rows of old need all three off.
AGENT_KNOWN=' claude codex gemini qwen opencode amp goose crush kiro-cli kiro-cli-chat aider copilot cursor-agent '
AGENT_SCRIPTS=' codex gemini qwen copilot crush aider '
if [ "$AGENT_NAMES" = off ]; then
  AGENT_KNOWN="" AGENT_SCRIPTS=""
else
  set -f
  for _an in $AGENT_NAMES; do
    case "$_an" in *[!A-Za-z0-9._-]*) continue ;; esac
    AGENT_KNOWN+="$_an " AGENT_SCRIPTS+="$_an "
  done
  set +f
  unset _an
fi
# Anything to do at all?  The default is yes; everything off is today's rows.
AGENT_ON=0
[ "$SHOW_TITLE" != off ] || [ "$AGENT_STATE" = on ] || [ -n "$AGENT_KNOWN" ] && AGENT_ON=1

# The agents view: the navigator the dashboard's Agents entry opens
# (`--launch agents` sets INTERDIMUX_VIEW=agents for it, and its reloads
# inherit it).  Its rows are the navigator's, plus a MARK in the gutter where
# `*` marks the current target: `!` on the row of a pane whose state is
# `approve`, `?` on one in `input` -- one row per pane (the pane row where a
# window has them, else the window row; the first session that shows it), so
# the rows marked are the panes the entry counted.  The view opens with
# AGENTS_QUERY typed, which matches exactly those rows: `^` anchors a term to
# the start of a searched field, the gutter starts field 1, and nothing but
# the renderer writes there.  (Field 3, the other one searched, starts with a
# command name, which would have to begin with `!` or `?`.)
#
# It used to open on `'approve' | 'input'`, which matched the words anywhere in
# the name and command fields: a description (`Approve button styling`, `Fix
# input validation`), an argument (`vim input.go`), a window called
# `input-form`.  fzf's count ran past the entry's, and raw mode's cursor went
# to the best such match -- a working agent, where Enter then switched (review
# R03).  fzf cannot search a field it does not show, so the mark has to be
# drawn; and a highlighted mark, not the state word, leaves `approve` its
# danger colour and `input` its amber in this view (review R28).  Both
# renderers draw it (rust/src/main.rs), from the env var bash hands on.
VIEW=""
[ "${INTERDIMUX_VIEW:-}" = agents ] && VIEW=agents
AGENTS_QUERY='^! | ^?'

# Is argv ($1, the resolved command) an agent?  Sets AG_NAME (empty if not) and
# AG_REST, the arguments after what names it (a leading blank, or empty).
agent_of() {
  AG_NAME="" AG_REST=""
  [ -n "$AGENT_KNOWN" ] || return 0
  local s="$1" a0 b r1 w1 wb
  a0="${s%% *}"; b="${a0##*/}"
  if [ -n "$b" ] && [[ "$AGENT_KNOWN" == *" $b "* ]]; then
    AG_NAME="$b" AG_REST="${s#"$a0"}"
    return 0
  fi
  # Claude's native build runs from ~/.local/share/claude/versions/<version>.
  case "$a0" in */claude/versions/*) AG_NAME=claude AG_REST="${s#"$a0"}"; return 0 ;; esac
  case "$b" in
    node|nodejs) ;;
    python*) [[ "${b#python}" == *[!0123456789.]* ]] && return 0 ;;
    *) return 0 ;;
  esac
  r1="${s#"$a0"}"; r1="${r1# }"; w1="${r1%% *}"; wb="${w1##*/}"
  [[ -z "$wb" || "$w1" == -* ]] && return 0
  # A package's own file, run by path (`node …/@openai/codex/bin/codex.js`).
  case "$wb" in *.js|*.mjs|*.cjs) wb="${wb%.*}" ;; esac
  if [[ "$AGENT_SCRIPTS" == *" $wb "* ]]; then
    AG_NAME="$wb" AG_REST="${r1#"$w1"}"
    return 0
  fi
  case "$wb" in npx|npx-cli) npx_agent "${r1#"$w1"}" ;; esac
  return 0
}

# `npx [options] <package>[@version] [args]` -- gemini's own quick start is
# `npx @google/gemini-cli`.  npm runs the package's bin as a GRANDCHILD and
# npx stays the pane's foreground process, so the row's argv is npx's: the
# package names the agent.  `-p <package> <command>` names it by either.
# Sets AG_NAME / AG_REST (the arguments after the package) for a known one.
NPX_AGENTS=' @google/gemini-cli=gemini @openai/codex=codex @anthropic-ai/claude-code=claude @qwen-code/qwen-code=qwen @github/copilot=copilot '
npx_agent() {
  local rest="$1" w pkg="" skip=0 m
  while :; do
    rest="${rest#"${rest%%[! ]*}"}"
    [ -n "$rest" ] || return 0
    w="${rest%% *}"; rest="${rest#"$w"}"
    if [ "$skip" = 1 ]; then pkg="$w" skip=0; continue; fi
    case "$w" in
      -p|--package) skip=1; continue ;;
      --package=*) pkg="${w#--package=}"; continue ;;
      -c|--call) return 0 ;;
      -*) continue ;;
    esac
    break
  done
  m="${pkg:-$w}"
  case "$m" in ?*@*) m="${m%@*}" ;; esac
  if [[ "$NPX_AGENTS" == *" $m="* ]]; then
    m="${NPX_AGENTS#* "$m"=}"; AG_NAME="${m%% *}" AG_REST="$rest"
  elif [ -n "$pkg" ] && [[ "$AGENT_KNOWN" == *" $w "* ]]; then
    AG_NAME="$w" AG_REST="$rest"
  fi
  return 0
}

# (The rest of the agent layer -- the title rules, the Claude registry,
# cmd_field -- is further down, above --action: see "The agent layer sits
# here".  These names stay up here because callbacks use them: --preview names
# an agent's pane with agent_of, and resolve_create_target reads VIEW.)

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

# Pad (or truncate with …) a string to a target display width using
# character count
dpad() {
  local str="$1" width="$2"
  if [ "${#str}" -gt "$width" ] && [ "$width" -gt 1 ]; then
    str="${str:0:width-1}…"
  fi
  printf '%s' "$str"
  local pad=$(( width - ${#str} ))
  [ "$pad" -gt 0 ] && printf '%*s' "$pad" ""
}

# Row-field builder: accumulate colored chunks while tracking the plain
# (uncolored) character count, so padding stays correct around ANSI codes.
FLD="" FLD_LEN=0
fld_reset() { FLD="" FLD_LEN=0; }
fld_add() { FLD+="$1"; FLD_LEN=$(( FLD_LEN + $2 )); }
fld_pad() {
  local pad=$(( $1 - FLD_LEN )) _sp
  if [ "$pad" -gt 0 ]; then
    printf -v _sp '%*s' "$pad" ''
    FLD+="$_sp"
  fi
  FLD_LEN="$1"
}

# Compact age of an epoch timestamp ("now", "5m", "2h", "3d", "1w");
# sets REPLY (empty for missing/zero values).
# The clock, injectable via INTERDIMUX_NOW.  Without a seam, any test that
# compares two renders is at the mercy of a second boundary falling between
# them: the batching test runs `--list` twice and diffs the output, and under
# load one run said "2s" where the other said "3s".  Same seam as
# INTERDIMUX_NO_BATCH and INTERDIMUX_TTY_IN.
case "${INTERDIMUX_NOW:-}" in
  ''|*[!0-9]*) printf -v NOW_EPOCH '%(%s)T' -1 ;;  # fork-free (bash >= 4.2)
  *)           NOW_EPOCH="$INTERDIMUX_NOW" ;;
esac
age_of() {
  REPLY=""
  local t="${1:-0}" d
  [[ "$t" =~ ^[0-9]+$ ]] || return 0
  [ "$t" -eq 0 ] && return 0
  d=$(( NOW_EPOCH - t ))
  if   [ "$d" -lt 0 ];      then return 0
  elif [ "$d" -lt 90 ];     then REPLY="now"
  elif [ "$d" -lt 3600 ];   then REPLY="$(( d / 60 ))m"
  elif [ "$d" -lt 86400 ];  then REPLY="$(( d / 3600 ))h"
  elif [ "$d" -lt 604800 ]; then REPLY="$(( d / 86400 ))d"
  else                           REPLY="$(( d / 604800 ))w"
  fi
}

# Terminal width of the popup tty (falls back to 80 without a tty,
# e.g. in tests/CI)
# REPLY-setting form, for callers on a path that counts its forks.  $(term_cols)
# is a subshell AND an `stty` exec — measured at ~3 ms — and the navigator now
# asks TWICE before it can draw a first frame: once to size the hint bar, once
# for the INTERDIMUX_COLS it hands the renderer.  Memoised so that is one exec,
# the same number the launch path paid before the bar existed.
#
# Safe within a process: the only long-lived one is the navigator, and every
# event that can change the width (resize, ^/) ends in a reload, which is a
# fresh child that measures again.
_term_cols_cached=""
term_cols_r() {
  if [[ "${FZF_COLUMNS:-}" =~ ^[1-9][0-9]*$ ]]; then
    REPLY="$FZF_COLUMNS"
    return 0
  fi
  if [ -n "$_term_cols_cached" ]; then REPLY="$_term_cols_cached"; return 0; fi
  local dims
  REPLY=80
  if dims=$({ stty size </dev/tty; } 2>/dev/null); then
    REPLY="${dims#* }"
  fi
  [[ "$REPLY" =~ ^[0-9]+$ ]] || REPLY=80
  _term_cols_cached="$REPLY"
  return 0
}

term_cols() {
  # The printing form, kept for the callers that interpolate it.  It goes
  # through term_cols_r so both share the one measurement.
  # fzf exports FZF_COLUMNS to the children it spawns (reload, preview,
  # execute), so every ctrl-r reload can skip the stty fork.  It reads 0
  # during fzf's own `start` event, hence the numeric guard rather than a
  # bare emptiness test.  The initial launch-time gather has no fzf parent
  # and still falls back to stty.
  term_cols_r
  printf '%s' "$REPLY"
}

# The pressing client's width or height in cells, or 0 when it cannot be read.
# Sets REPLY.
#
# Targeted first, so the answer is the pressing client's when several are
# attached; untargeted second, because a TMUX_PANE inherited from a DIFFERENT
# server does not resolve here and would otherwise read as "unknown".
client_dim() {
  local fmt="$1" v
  v=$(tmux display-message -p ${TMUX_C[@]+"${TMUX_C[@]}"} ${CUR_T[@]+"${CUR_T[@]}"} "$fmt" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v=$(tmux display-message -p "$fmt" 2>/dev/null) ;; esac
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  REPLY="$v"
}

# Both, in one round-trip: REPLY="<height> <width>", each 0 when unknown.  The
# same targeted-then-untargeted lookup as client_dim.
client_dims() {
  local fmt='#{client_height} #{client_width}' v
  v=$(tmux display-message -p ${TMUX_C[@]+"${TMUX_C[@]}"} ${CUR_T[@]+"${CUR_T[@]}"} "$fmt" 2>/dev/null)
  [[ "$v" =~ ^[0-9]+\ [0-9]+$ ]] || v=$(tmux display-message -p "$fmt" 2>/dev/null)
  [[ "$v" =~ ^[0-9]+\ [0-9]+$ ]] || v="0 0"
  REPLY="$v"
}

# How many rows the dashboard's native menu needs: its items plus two borders.
# display-menu SILENTLY draws nothing and exits 0 when it does not fit — no
# message, no error, prefix+g simply becomes a dead key — so the number has to
# be kept in step with the menu by hand.  tests/test_dashboard.sh parses the menu
# and fails if this disagrees with it, and --doctor reports which of the two
# dashboards the current client is going to get.
MENU_ROWS=18

# Column widths for the navigator tree.  Sized to the ACTUAL content
# (longest session name / window name / path) so the important window
# names are never starved by a long, redundant session prefix, then
# squeezed to fit the popup width — the display-only columns (path, git
# badge) give way first, the session prefix and window name, which fzf
# matches, last (see compute_widths).  Measurement is fork-free (pure
# parameter ops over the strings tmux already handed us, and the git
# reader's own cached file reads), so this adds no processes to the hot path.
#
#   IDENT_W = IDENT_OV + PFX_W + WIN_W
#   ctx     = "│ " + PATH_W + FLAG_W + (" " + BADGE_W, when BADGE_W > 0)
#
# where IDENT_OV covers the marker + tree-glyph columns, PFX_W is the
# session-name prefix carried on child rows, WIN_W is the window-name
# budget, and FLAG_W is the Z/!/# slot (0 when no window has a flag).
IDENT_W=24 PATH_W=24 BADGE_W=16 PFX_W=14 WIN_W=12 FLAG_W=0
# Width a session header row's identity field is padded to when the group rule
# is drawn: IDENT_W + the TAB + the context column, so the session meta lands in
# the same column as the command on child rows.
SESS_RULE_W=0
IDENT_OV=6            # marker(1) + " ├─ "(4) + the space after the prefix(1)
CMD_MIN=12            # columns kept for the flowing (unpadded) command field
WIDTH_GUTTER=8        # fzf pointer/marker/scrollbar overhead
PFX_FLOOR=6  PFX_CEIL=16
WIN_FLOOR=8  WIN_CEIL=40
PATH_FLOOR=12 PATH_CEIL=44
PATH_KEEP=24          # how far the path may shrink to keep the git badge
MAX_SESS=0 MAX_WIN=0 MAX_PATH=0 MAX_FLAGS=0

# Longest session name, window identity ("index:name") and displayed
# (~-substituted) path across every target, and the most Z/!/# flags on any
# one window.  Fork-free and file-free; reads the raw tmux dumps
# gather_targets already fetched (visible via dynamic scope) and sets the
# MAX_* globals.  Whether any row has a git branch is NOT measured here: it
# costs file reads, and compute_widths asks it only where the answer counts
# (_probe_has_branch).  Every (( … )) test sits on the LEFT of && (set-e-exempt);
# the explicit `return 0` keeps the function's own status 0 — the trailing
# loop would otherwise propagate a false (( … )) and abort a set -e caller
# of the bare call in gather_targets.
#
# Each section is split into lines, and each line into fields, by word
# splitting under set -f -- as gather_targets groups them -- not by a `while
# read` over a here-string.  `read` takes a here-string ONE BYTE per read(2)
# (it is a pipe), so these three loops cost ~30 ms of a 100-pane list, and
# every character a pane line gained cost more (review R09).  The fields are
# the ones `read` gave: a line of the grouped sections has exactly these.
measure_widths() {
  MAX_SESS=0 MAX_WIN=0 MAX_PATH=0 MAX_FLAGS=0
  local l wflags il dp nf
  local -a ls=() f=()
  set -f
  IFS=$'\n'; ls=($sessions_raw); unset IFS
  for l in ${ls[@]+"${ls[@]}"}; do
    l="${l%%"$US"*}"   # the session name
    (( ${#l} > MAX_SESS )) && MAX_SESS=${#l}
  done
  IFS=$'\n'; ls=($all_windows_raw); unset IFS
  for l in ${ls[@]+"${ls[@]}"}; do
    IFS="$US"; f=($l$US); unset IFS   # the appended US: see gather_targets
    [ -n "${f[0]-}" ] || continue
    il=$(( ${#f[1]} + 1 + ${#f[2]} ))   # index:name
    (( il > MAX_WIN )) && MAX_WIN=$il
    dp="${f[5]-}"; dp="${dp/#$HOME/\~}"
    (( ${#dp} > MAX_PATH )) && MAX_PATH=${#dp}
    # Same three positions build_ctx_field reads.  nf=$(( … )), never
    # (( nf++ )): a post-increment from 0 is a false (( … )), and as the last
    # command of an && list it would abort a set -e caller.
    wflags="${f[8]-}" nf=0
    [ "${wflags:0:1}" = "1" ] && nf=$(( nf + 1 ))
    [ "${wflags:1:1}" = "1" ] && nf=$(( nf + 1 ))
    [ "${wflags:2:1}" = "1" ] && nf=$(( nf + 1 ))
    (( nf > MAX_FLAGS )) && MAX_FLAGS=$nf
  done
  IFS=$'\n'; ls=($all_panes_raw); unset IFS
  for l in ${ls[@]+"${ls[@]}"}; do
    IFS="$US"; f=($l$US); unset IFS
    [ -n "${f[0]-}" ] || continue
    dp="${f[5]-}"; dp="${dp/#$HOME/\~}"
    (( ${#dp} > MAX_PATH )) && MAX_PATH=${#dp}
  done
  set +f
  return 0
}

# Does any window or pane row have a git branch to show?  The one question the
# squeeze asks that reads files: each cwd is walked up to / (get_git_branch)
# until one has a branch, so on a tree with none it is every directory of every
# path -- plus the mount table, on the first walk step (is_remote_path).  It was
# asked up front in measure_widths, at every width; but it decides only whether
# the path gives up cells to keep the badge, and at most widths the badge fits,
# or goes, whatever the answer (at 80 columns it never matters).  So
# compute_widths asks it there and nowhere else, and it stops at the first
# branch.  Windows before panes, as it always was.  The lookups fill
# get_git_branch's cache, so build_ctx_field's for the same paths cost nothing.
# Reads gather_targets' dumps through dynamic scope.
# Split as measure_widths splits, not read: the cwd is field 6 of both.
_probe_has_branch() {
  local l
  local -a ls=() f=()
  set -f; IFS=$'\n'; ls=($all_windows_raw $all_panes_raw); unset IFS; set +f
  for l in ${ls[@]+"${ls[@]}"}; do
    set -f; IFS="$US"; f=($l$US); unset IFS; set +f
    [ -n "${f[0]-}" ] || continue
    get_git_branch "${f[5]-}"
    [ -n "$REPLY" ] && return 0
  done
  return 1
}


# The live preview state ("on"/"off").  ctrl-/ writes the new value to
# $INTERDIMUX_PREVIEW_STATE so a reload child can size its columns for the
# geometry the user is actually looking at.
# REPLY-setting form; same reason as term_cols_r.
live_preview_state_r() {
  REPLY="$SHOW_PREVIEW"
  if [ -n "${INTERDIMUX_PREVIEW_STATE:-}" ] && [ -s "${INTERDIMUX_PREVIEW_STATE}" ]; then
    { read -r REPLY < "$INTERDIMUX_PREVIEW_STATE"; } 2>/dev/null || :
  fi
  return 0
}

live_preview_state() {
  local st="$SHOW_PREVIEW"
  if [ -n "${INTERDIMUX_PREVIEW_STATE:-}" ] && [ -s "${INTERDIMUX_PREVIEW_STATE}" ]; then
    # `|| st=...` here would be a bug: the file has no trailing newline, so
    # read assigns the value and THEN reports EOF, and the fallback would wipe
    # what it just read.  Same trap as the /proc children file.
    { read -r st < "$INTERDIMUX_PREVIEW_STATE"; } 2>/dev/null || :
  fi
  printf '%s' "$st"
}

# Turn the measured maxima into column widths that fit the popup width.
compute_widths() {
  local avail
  avail=$(term_cols)
  # The live preview state, not the configured one: ctrl-/ toggles the preview
  # after launch, and FZF_COLUMNS does not move when it does (verified), so
  # without this the rows stay sized for the old geometry and fzf just clips them
  # with an ellipsis.  That is IDEAS #26.
  #
  # FZF_COLUMNS is fzf's WINDOW inner width, which equals the terminal width only
  # because nothing here sets --margin, --border or --height; man fzf defines it
  # as "excluding padding and margin", and adding any of those would silently
  # make this arithmetic wrong.
  local _pv="$SHOW_PREVIEW"
  if [ -n "${INTERDIMUX_PREVIEW_STATE:-}" ] && [ -s "${INTERDIMUX_PREVIEW_STATE}" ]; then
    { read -r _pv < "$INTERDIMUX_PREVIEW_STATE"; } 2>/dev/null || :
  fi
  [ "$_pv" = "on" ] && avail=$(( avail / 2 ))
  avail=$(( avail - WIDTH_GUTTER ))

  # Content-sized, each clamped to a sane [floor, ceiling].
  PFX_W=$MAX_SESS
  (( PFX_W < PFX_FLOOR )) && PFX_W=$PFX_FLOOR
  (( PFX_W > PFX_CEIL ))  && PFX_W=$PFX_CEIL
  WIN_W=$MAX_WIN
  (( WIN_W < WIN_FLOOR )) && WIN_W=$WIN_FLOOR
  (( WIN_W > WIN_CEIL ))  && WIN_W=$WIN_CEIL
  PATH_W=$MAX_PATH
  (( PATH_W < PATH_FLOOR )) && PATH_W=$PATH_FLOOR
  (( PATH_W > PATH_CEIL ))  && PATH_W=$PATH_CEIL

  FLAG_W=0
  (( MAX_FLAGS > 0 )) && FLAG_W=$(( 1 + (MAX_FLAGS > 3 ? 3 : MAX_FLAGS) ))

  if   (( avail >= 72 )); then BADGE_W=16
  elif (( avail >= 52 )); then BADGE_W=14
  elif (( avail >= 40 )); then BADGE_W=10
  else                         BADGE_W=0
  fi

  IDENT_W=$(( IDENT_OV + PFX_W + WIN_W ))

  # Squeeze to fit.  The order is the point: what you TYPE outlasts what
  # you only READ.  fzf matches the identity column as displayed, so a
  # session prefix cut to "my-pr…" makes `my-project shell` match nothing;
  # the path and the branch are display-only.  So:
  #
  #   1. the path gives up cells down to PATH_KEEP to keep the git badge —
  #      all or nothing: if that is not enough, the badge goes (snapped
  #      straight to 0 — never left at 1..3, which would make
  #      build_ctx_field's ${gbranch:0:BADGE_W-3} slice degenerate) and the
  #      path keeps its cells.  Only while some row actually HAS a branch; a
  #      badge column that would be blank on every tree row goes first.
  #      That is asked last, and only when the cells would be enough: it is
  #      the one test here that reads files (_probe_has_branch).
  #   2. the path, down to PATH_FLOOR
  #   3. the session prefix, down to PFX_FLOOR
  #   4. the window name, down to WIN_FLOOR
  #
  # The Z/!/# flags are never squeezed: their own slot, at most 4 cells.
  # Any deficit left after the floors lands on the flowing COMMAND column,
  # which fzf clips anyway.  rust/src/widths.rs is the same ladder.
  local over give
  _squeeze_over; over=$REPLY
  if (( BADGE_W > 0 && over > 0 )); then
    if (( PATH_W - PATH_KEEP >= over )) && _probe_has_branch; then
      PATH_W=$(( PATH_W - over ))
    else
      BADGE_W=0
    fi
  fi
  _squeeze_over; give=$(( PATH_W - PATH_FLOOR ))
  (( REPLY < give )) && give=$REPLY
  PATH_W=$(( PATH_W - give ))
  _squeeze_over; give=$(( PFX_W - PFX_FLOOR ))
  (( REPLY < give )) && give=$REPLY
  PFX_W=$(( PFX_W - give )) IDENT_W=$(( IDENT_W - give ))
  _squeeze_over; give=$(( WIN_W - WIN_FLOOR ))
  (( REPLY < give )) && give=$REPLY
  WIN_W=$(( WIN_W - give )) IDENT_W=$(( IDENT_W - give ))

  # The rule only draws when the squeeze actually FIT — see
  # rust/src/widths.rs, which this mirrors.
  _squeeze_over
  if (( REPLY == 0 )); then
    SESS_RULE_W=$(( IDENT_W + 1 + CTX_W ))
  else
    SESS_RULE_W=0
  fi
}

# How many cells a row is over the popup at the current widths (0 when it
# fits), in REPLY; the context column's width in CTX_W.  Reads compute_widths'
# `avail` through dynamic scope.
_squeeze_over() {
  CTX_W=$(( PATH_W + 2 + FLAG_W ))
  (( BADGE_W > 0 )) && CTX_W=$(( CTX_W + 1 + BADGE_W ))
  REPLY=$(( IDENT_W + CTX_W + 2 + CMD_MIN - avail ))
  (( REPLY < 0 )) && REPLY=0
  return 0
}

# Trim a path to fit within max_width display columns.  Sets REPLY (no
# subprocess) — called once per window and per pane in the gather hot loop.
trim_path() {
  local path="$1" max_width="$2"

  [ "${#path}" -le "$max_width" ] && { REPLY="$path"; return; }

  local prefix=""
  # shellcheck disable=SC2088  # literal "~/" match is intentional
  case "$path" in
    "~/"*) prefix="~/"; path="${path#\~/}" ;;
    "/"*)  prefix="/";  path="${path#/}" ;;
  esac

  local ellipsis="…/"
  local budget=$(( max_width - ${#prefix} - ${#ellipsis} ))

  local result="" remainder="$path"
  while [ -n "$remainder" ]; do
    local component="${remainder##*/}"
    if [ "$component" = "$remainder" ]; then
      if [ -z "$result" ]; then
        result="$component"
      else
        local candidate="$component/$result"
        [ "${#candidate}" -le "$budget" ] && result="$candidate"
      fi
      break
    fi

    remainder="${remainder%/*}"
    if [ -z "$result" ]; then
      result="$component"
    else
      local candidate="$component/$result"
      if [ "${#candidate}" -le "$budget" ]; then
        result="$candidate"
      else
        break
      fi
    fi
  done

  # A single component can exceed the budget on its own — truncate it
  # so the row's columns don't shift.
  if [ "${#result}" -gt "$budget" ] && [ "$budget" -gt 1 ]; then
    result="${result:0:budget-1}…"
  fi

  REPLY="${prefix}${ellipsis}${result}"
}

# ---------------------------------------------------------------------------
# Gather targets (tree layout)
# ---------------------------------------------------------------------------
#
# Output format (tab-delimited, constant 4 fields):
#   IDENTITY <TAB> CONTEXT <TAB> COMMAND <TAB> SPEC
#
# The SPEC sits in the LAST field so that fzf's --nth indexes are the
# same whether they are computed against the original or the
# --with-nth-transformed line (semantics differ across fzf versions).
# Match scope is restricted to IDENTITY + COMMAND; CONTEXT carries the
# path, git badge, flags, and session metadata, which are display-only.
#
# SPEC uses printable ":" delimiter (parsed right-to-left):
#   S:session_name
#   W:session_name:window_index
#   P:session_name:window_index:pane_index

# Path, then the Z/!/# flag slot, then the git badge, padded into the
# CONTEXT column.  The flags are a column of their own (FLAG_W cells, sized
# to the most flags any window carries): they used to trail the branch
# inside the badge, so their x moved with the branch's length and the
# squeeze that dropped the badge dropped them too.
# Args: path zoomed bell activity
build_ctx_field() {
  local path="$1" zoomed="$2" bell="$3" activity="$4"
  local disp gbranch fl fn
  fld_reset
  disp="${path/#$HOME/\~}"
  # Sanitised, not just de-tabbed: a cwd is arbitrary bytes.  An ESC reached
  # the popup as a live escape sequence, and ${#disp} counted the bytes the
  # terminal then swallowed, so the padding came out short and the command
  # column shifted; a CR redrew the row over itself.  The Rust core's rules
  # (render.rs ctx_field -> proc::sanitize): newline to a space, every other
  # control byte -- TAB, the field delimiter, included -- to '?'.  Guarded, so
  # a clean path costs one pattern test.
  sanitize_args "$disp"; disp="$REPLY"
  trim_path "$disp" "$PATH_W"; disp="$REPLY"
  fld_add "${SEP} " 2
  fld_add "${DIM_PATH}${disp}${RST}" "${#disp}"
  fld_pad $(( PATH_W + 2 ))
  if [ "$FLAG_W" -gt 0 ]; then
    # Packed ("Z!#"), in a fixed order, so each flag reads as a column.
    fl="" fn=0
    [ "$zoomed" = "1" ]   && { fl+="${BOLD_AMBER}Z${RST}"; fn=$(( fn + 1 )); }
    [ "$bell" = "1" ]     && { fl+="${BOLD_RED}!${RST}";   fn=$(( fn + 1 )); }
    [ "$activity" = "1" ] && { fl+="${DIM_SSH}#${RST}";    fn=$(( fn + 1 )); }
    [ "$fn" -gt 0 ] && fld_add " $fl" $(( fn + 1 ))
    fld_pad $(( PATH_W + 2 + FLAG_W ))
  fi
  if [ "$BADGE_W" -gt 0 ]; then
    get_git_branch "$path"; gbranch="$REPLY"
    # .git/HEAD is a file anyone can write: a TAB in the ref name made a
    # FIVE-field row, breaking the contract --delimiter/--with-nth/--nth all
    # rest on.  Same rules as the path above.
    sanitize_args "$gbranch"; gbranch="$REPLY"
    if [ -n "$gbranch" ]; then
      # " ‹" + branch + "›" in BADGE_W + 1 cells: the same budget on every
      # row, whatever flags the row carries.
      [ "${#gbranch}" -gt $(( BADGE_W - 2 )) ] && gbranch="${gbranch:0:BADGE_W-3}…"
      fld_add " ${DIM_GIT}‹${gbranch}›${RST}" $(( ${#gbranch} + 3 ))
    fi
    fld_pad $(( PATH_W + 2 + FLAG_W + 1 + BADGE_W ))
  fi
}

# Directory rows (IDEAS #14, the "one-list" model).
#
# Emitted AFTER every tmux row, which matters twice over: fzf appends streamed
# rows as they arrive, so the tmux tree still paints at the same moment it
# always did; and the column widths are already fixed by then, so a long
# directory path can never widen the tree's columns.
#
# Sources are only the cheap ones — the recent list and zoxide (~3-5 ms
# combined).  Filesystem scanning stays behind ctrl-o, where the user has asked
# for it.  SESSION_DIRS holds each session's start directory (#{session_path})
# and the cwd of its active window, so a directory that already has a session
# is not offered again -- not even after a `cd` inside that session.
emit_dir_rows() {
  [ "$SHOW_DIRS" = "on" ] || return 0
  [[ "$DIRS_LIMIT" =~ ^[0-9]+$ ]] || return 0
  [ "$DIRS_LIMIT" -gt 0 ] || return 0

  local d disp base ident ctx type_badge n=0
  # ...and under whatever spelling: each of them as canon_dir has it, so a
  # session started at `~/repo/`, or through a symlink, hides the row for its
  # directory however the recent list or zoxide spells it -- as it must, since
  # Enter on that row resolves it and switches to the session (dir_session).
  # The Rust core's canon_dir (rust/src/dirs.rs) does the same.
  local _k
  local -A _taken=()
  for _k in ${SESSION_DIRS[@]+"${!SESSION_DIRS[@]}"}; do canon_dir "$_k"; _taken["$REPLY"]=1; done
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # A tab would break the 4-field row contract; a session already covers it
    case "$d" in *$'\t'*) continue ;; esac
    [[ ${SESSION_DIRS[$d]+x} ]] && continue

    canon_dir "$d"; [ -n "${_taken[$REPLY]-}" ] && continue
    base="${d##*/}"
    [ -n "$base" ] || base="$d"
    # Sanitised as the context column is, and before the cut: an ESC in the name
    # was drawn live in the identity column.  (No TAB gets here: see above.)
    sanitize_args "$base"; base="$REPLY"
    [ "${#base}" -gt $(( IDENT_W - 4 )) ] && base="${base:0:IDENT_W-5}…"

    fld_reset
    fld_add " " 1
    fld_add " ${DIM_TREE}+${RST} " 3
    fld_add "${DIM}${base}${RST}" "${#base}"
    fld_pad "$IDENT_W"
    ident="$FLD"

    build_ctx_field "$d" "" "" ""
    ctx="$FLD"

    detect_project_type "$d"
    type_badge=""
    [ -n "$REPLY" ] && type_badge="${DIM}${REPLY}${RST}"

    printf '%s\t%s\t%s\tD:%s\n' "$ident" "$ctx" "$type_badge" "$d"

    n=$((n + 1))
    [ "$n" -ge "$DIRS_LIMIT" ] && break
  done < <(load_recent_dirs)
  return 0
}

# Is interdimux.tmux's background build of the checkout $1 running right now?
# Its lock names the job's PID, but a live PID is not enough: a job killed
# before its EXIT trap could run (SIGKILL, the OOM killer, a power cut) leaves
# the lock in rust/target, which outlives it and a reboot, and that PID is soon
# some other process's.  Then --doctor said "building it right now" for as long
# as that process lived, and imux_refused kept quiet about a binary nothing was
# replacing.  So the PID must also be such a job.  interdimux.tmux's own
# imux_build_running is the same test.
imux_autobuild_running() { # $1 = the checkout
  local owner args
  owner=$(readlink "$1/rust/target/.interdimux-autobuild.lock" 2>/dev/null) || return 1
  [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null || return 1
  read_cmdline "$owner"; args="$REPLY"
  [ -n "$args" ] || args=$(ps -ww -o args= -p "$owner" 2>/dev/null) || args=""
  [[ "$args" == *interdimux.tmux*--autobuild* ]]
}

# The Rust core refused IMUX_PROTO (exit 2): it was built from other sources
# than this script.  The list has already fallen back to the bash renderer --
# correct, only slower -- so this is about telling the user, and ONCE: the list
# is fetched on every open and every reload, and a message per fetch would
# bury the status line and errors.log alike.  Said on the status line and in
# errors.log, which --doctor reports, naming the binary and how to rebuild it.
#
# The stamp in the state directory names the binary it was said for, and a
# rebuild makes the binary newer than the stamp, so a rebuild that is still the
# wrong version is reported again.  Nothing is said while interdimux.tmux's
# background build is replacing this very binary: that job announces its own
# result, and the next open uses what it built.  All of it is off the fast path
# -- only a refused binary gets here -- and nothing in it can fail the list.
imux_refused() {
  local dir="${SCHED_LOGDIR:-${XDG_STATE_HOME:-$HOME/.local/state}/interdimux}"
  local repo="${SCRIPT_PATH%/scripts/*}" stamp seen_bin="" how msg
  stamp="$dir/imux-refused"
  if [ -f "$stamp" ] && ! [ "$IMUX_BIN" -nt "$stamp" ]; then
    { IFS= read -r seen_bin < "$stamp"; } 2>/dev/null || :
    [ "$seen_bin" = "$IMUX_BIN" ] && return 0
  fi
  if [ "$IMUX_BIN" = "$repo/rust/target/release/imux" ]; then
    imux_autobuild_running "$repo" && return 0
    how="rebuild it: (cd '$repo/rust' && cargo build --release)"
  else
    how="rebuild it, or point INTERDIMUX_BIN at a build of this version"
  fi
  msg="the Rust core at $IMUX_BIN is from another version of interdimux (it does not speak $IMUX_PROTO), so the list uses the slower bash renderer; $how"
  imux_msg "$msg"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '== %(%Y-%m-%d %H:%M:%S)T rust core refused %s\ninterdimux: %s\n' -1 "$IMUX_PROTO" "$msg" \
    >> "$dir/errors.log" 2>/dev/null || :
  printf '%s\n' "$IMUX_BIN" > "$stamp" 2>/dev/null || :
  return 0
}

gather_targets() {
  local current_session current_window current_pane cur_raw
  local sessions_raw all_windows_raw all_panes_raw
  local _hline

  # The process table for full-command resolution is built LAZILY, only on the
  # bash-renderer fallback path below (see before measure_widths).  The Rust core
  # resolves commands itself now — from /proc on Linux, from its own ps snapshot
  # everywhere else — so when the binary is present bash never forks ps at all.

  # tmux gives each line of a list-* a 100 ms wall-clock budget and, when the
  # server is descheduled for that long in the middle of one, returns the line
  # CUT at the next '#{' (format.c, FORMAT_TIME_LIMIT) -- `s^_0^_zsh^_1^_zsh^_`,
  # with no error.  Rare (it takes a starved server), transient (the next reload
  # is whole), and both renderers keep such a line rather than drop the row; see
  # the window and pane grouping below.  For the SESSION line that means the name
  # has to come FIRST: behind the timestamp, a cut line had no name at all, and
  # the session vanished along with every window and pane under it (shifting
  # --jump N onto the wrong session).
  local _sfmt _wfmt _pfmt _curfmt
  #
  # #{session_path} goes LAST, so a US inside it stays inside it (both renderers
  # split the line into at most five fields).  A newline or RS in it is
  # rewritten to '?' by tmux itself: the first would split the line and hand the
  # fragment after it the session-name position, the second would break the
  # section framing.  Such a path could never equal a directory row's path
  # anyway -- the recent list and zoxide are line-based.
  local _nl=$'\n' _rs=$'\x1e'
  _sfmt="#{session_name}${US}#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_windows}${US}#{?session_attached,attached,}${US}#{s/[${_nl}${_rs}]/?/:session_path}"
  _wfmt="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_panes}${US}#{pane_pid}${US}#{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag}"
  # The pane id, its title and the options agent plugins publish ride at the
  # END of a pane line (gather3), so a line cut in them keeps its row.  tmux
  # escapes every control character in a title, so it cannot carry a US, RS
  # or newline of its own.  An option can, so each value has them rewritten
  # (and is capped); the values are POSITIONAL, one per name in STATE_OPTS,
  # each ended by GS -- an unset option is an empty value.  Measured on 97
  # panes (tmux 3.7b, median of 40): a conditional per option
  # (`#{?@x,x=...,}`) cost 0.7 ms per option, this 0.35 ms, and a separate
  # `list-panes -f` over the options three times the base query.  The field
  # goes last, so nothing in it can move another.  A window row takes all
  # three from its active pane's line, so the window format is unchanged.  The
  # host names are what a pane's title is when no program set one (see
  # cmd_field).
  local _optfmt=""
  if [ "$AGENT_ON" = 1 ]; then
    title_ruleset
    state_optfmt_r; _optfmt="$REPLY"
  fi
  _pfmt="#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{pane_pid}${US}#{window_panes}${US}#{pane_id}${US}#{pane_title}${US}${_optfmt}"
  _curfmt="#S${US}#I${US}#P${US}#{host}${US}#{host_short}"

  # One tmux invocation instead of four.  A tmux client accepts a `;`-separated
  # command list, and each round-trip costs ~5-6 ms of connect/teardown on top
  # of the query itself — all of it ahead of the first emitted row.
  #
  # Sections are separated by RS (\x1e).  Note the ORDER: the only command here
  # that can fail is the current-target lookup (a stale $TMUX_PANE), and tmux
  # aborts the remainder of a command list on failure — so it goes LAST, where
  # it cannot swallow the bulk data.
  local _batched=0 _all RS=$'\x1e' _dump_reg=""
  local -a _parts=()
  if [ -n "${INTERDIMUX_DUMP_IN:-}" ]; then
    # Test seam: the four sections from a FILE instead of from tmux, framed
    # exactly as the batched query below returns them, plus optionally a fifth,
    # the Claude registry -- the framing `imux gather3` reads on stdin.  It is what lets the golden corpus
    # (rust/tests/corpus/*.dump) reach THIS renderer, the one every install
    # without cargo runs, with no server and no timing:
    # tests/test_corpus_parity.sh.  Same family as INTERDIMUX_NO_BATCH and
    # INTERDIMUX_NOW.
    #
    # A dump IS the batch, so it serves both fetch paths and neither one
    # queries tmux: a seam that fell through to a live server whenever the
    # file was unreadable or mis-framed would render some other list and pass.
    # So a bad dump renders nothing, loudly -- the Rust core exits 3 on the
    # same framing.  The trailing RS keeps an EMPTY last section a section:
    # word splitting drops a trailing empty field, and the corpus has an
    # empty server.
    if ! { _all=$(<"$INTERDIMUX_DUMP_IN"); } 2>/dev/null; then
      printf 'interdimux: INTERDIMUX_DUMP_IN: cannot read %s\n' "$INTERDIMUX_DUMP_IN" >&2
      return 1
    fi
    set -f; IFS="$RS"; _parts=($_all$RS); set +f; unset IFS
    # A fifth section is the Claude registry (CLAUDE_REG) that bash appends
    # before the handoff; a dump without one has none, and a dump never reads
    # the real ~/.claude.
    if [ "${#_parts[@]}" -ne 4 ] && [ "${#_parts[@]}" -ne 5 ]; then
      printf 'interdimux: INTERDIMUX_DUMP_IN: expected 4 or 5 sections, got %d\n' "${#_parts[@]}" >&2
      return 1
    fi
    _dump_reg="${_parts[4]-}"; _dump_reg="${_dump_reg#$'\n'}"; _dump_reg="${_dump_reg%$'\n'}"
    _batched=1
  elif [ -z "${INTERDIMUX_NO_BATCH:-}" ]; then
    _all=$(tmux \
      list-sessions -F "$_sfmt" \; \
      display-message -p "$RS" \; \
      list-windows -a -F "$_wfmt" \; \
      display-message -p "$RS" \; \
      list-panes -a -F "$_pfmt" \; \
      display-message -p "$RS" \; \
      display-message -p ${CUR_T[@]+"${CUR_T[@]}"} "$_curfmt" 2>/dev/null)
    # Split on RS by word-splitting, NOT by ${var#*pat}: the latter is
    # quadratic in the offset and costs hundreds of ms on a large dump.
    if [ -n "$_all" ]; then
      set -f; IFS="$RS"; _parts=($_all); set +f; unset IFS
    fi
    # Exactly four sections, or something inside a field carried an RS of its
    # own — a pane's cwd legitimately can (tmux only rejects RS in session and
    # window NAMES).  An extra field shifts every subsequent section, which
    # silently truncates a path AND drops the current-row marker, so fall back
    # to separate queries rather than render something subtly wrong.
    [ "${#_parts[@]}" -eq 4 ] && _batched=1
  fi

  if [ "$_batched" = 1 ]; then
    # display-message appends a newline before each RS, and each section after
    # the first therefore starts with one.
    sessions_raw="${_parts[0]%$'\n'}"
    all_windows_raw="${_parts[1]#$'\n'}"; all_windows_raw="${all_windows_raw%$'\n'}"
    all_panes_raw="${_parts[2]#$'\n'}";   all_panes_raw="${all_panes_raw%$'\n'}"
    cur_raw="${_parts[3]#$'\n'}"
  else
    # Current target: anchor to the pressing client, else to $TMUX_PANE (see
    # CUR_T) — a bare display-message in a clientless context silently
    # resolves to the most recently attached session.
    cur_raw=$(tmux display-message -p ${CUR_T[@]+"${CUR_T[@]}"} "$_curfmt")
    sessions_raw=$(tmux list-sessions -F "$_sfmt")
    all_windows_raw=$(tmux list-windows -a -F "$_wfmt")
    all_panes_raw=$(tmux list-panes -a -F "$_pfmt")
  fi
  IFS="$US" read -r current_session current_window current_pane CUR_HOST CUR_HOST_SHORT <<< "$cur_raw"

  # Claude's session registry, once per list, for both renderers (the Rust core
  # reads it as a fifth section).  A dump brings its own.
  if [ -n "${INTERDIMUX_DUMP_IN:-}" ]; then
    CLAUDE_REG="$_dump_reg"
  else
    claude_registry_r
  fi

  # @interdimux-hide 'scratch floax-*' — glob patterns, matched against session
  # names.  MRU ranks by recency, so a scratch popup you opened ten seconds ago
  # outranks the project you have been in all day; this is how you get it out of
  # the way without renaming anything.
  #
  # Filtered HERE, on the raw sections, so both renderers see the same list and
  # neither needs to know about the option.  Guarded on emptiness, so the
  # default config pays nothing at all.
  #
  # The CURRENT session is never hidden: the row marker, the header and MRU's
  # move-to-end all key off it, and a picker that cannot show you where you are
  # standing is worse than one that shows a scratch session.
  #
  # Hidden is not unreachable — typing an exact name still lands there. Nothing
  # matches, so find-or-create runs, and connect_dir switches to the existing
  # session rather than making a new one.
  if [ -n "${HIDE_PATTERNS:-}" ]; then
    # `for _hp in $HIDE_PATTERNS` needs the word splitting and would also get
    # PATHNAME EXPANSION, which is not a stylistic quibble: a pattern of
    # `floax-*` was expanded against the CWD before it was ever compared to a
    # session name, so in a directory containing `floax-notes` the tool tried to
    # hide a session called `floax-notes` and hid nothing at all — and in a
    # directory containing no match, bash left the word alone and it happened to
    # work.  The behaviour therefore depended on where the popup was opened from.
    # set -f for the whole block; the same idiom is used around the RS split in
    # gather_targets.
    #
    # The lines by word splitting, not `while read` over a here-string: `read`
    # takes that a byte per read(2), and a pane line carries its title and its
    # published options (review R09).
    set -f
    local _hp _hname _hkeep _hout=""
    local -a _hls=()
    IFS=$'\n'; _hls=($sessions_raw); unset IFS
    for _hline in ${_hls[@]+"${_hls[@]}"}; do
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254  # the pattern is a glob by design
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done
    sessions_raw="${_hout%$'\n'}"

    # windows and panes carry the session name in field 1 too
    _hout=""
    IFS=$'\n'; _hls=($all_windows_raw); unset IFS
    for _hline in ${_hls[@]+"${_hls[@]}"}; do
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done
    all_windows_raw="${_hout%$'\n'}"

    _hout=""
    IFS=$'\n'; _hls=($all_panes_raw); unset IFS
    for _hline in ${_hls[@]+"${_hls[@]}"}; do
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done
    all_panes_raw="${_hout%$'\n'}"
    set +f
  fi

  # Hand the whole render to the Rust core when it is present.  This is the part
  # that was ~181 ms of in-process bash (measure_widths + grouping + emit); the
  # binary does it in ~2 ms.  bash keeps the tmux plumbing so the socket handling
  # lives in exactly one place, and keeps its own renderer below as the fallback
  # for anyone without the binary.
  #
  # The binary resolves full commands from /proc on Linux and from its own single
  # `ps -eo` snapshot on macOS/BSD (or when INTERDIMUX_FORCE_PS=1), so it renders
  # correctly EVERYWHERE — it is preferred whenever it is present.  A binary that
  # fails or prints nothing falls through to the bash renderer below (the empty
  # `_imux_out` guard), so preferring it can never turn into an empty picker.
  if [ -n "$IMUX_BIN" ]; then
    # Pass every option EXPLICITLY rather than letting the binary re-derive
    # defaults from the environment.  bash is the single owner of config
    # resolution (env -> tmux option -> built-in default, see get_opt), and a
    # binary that re-implemented those defaults would silently disagree with the
    # fallback renderer whenever an option was left unset.
    #
    # The assignments live INSIDE the substitution on purpose: written as a
    # `VAR=v \ _imux_out=$(...)` prefix chain, bash parses the lot as a list of
    # assignments with NO command, so the binary would run without any of them.
    #
    # Its stderr is dropped.  Every failure falls back to the bash renderer
    # below, which draws the right list, and the one failure worth telling the
    # user about is reported by imux_refused, once.  Left to reach the
    # navigator's stderr, a binary older than IMUX_PROTO printed its usage line
    # on every open and every reload, and each one became another entry in
    # errors.log and another status-line message.
    local _imux_rc=0
    _imux_out=$(
      INTERDIMUX_COLS="$(term_cols)" \
      INTERDIMUX_NOW="$NOW_EPOCH" \
      INTERDIMUX_SHOW_FULL_COMMAND="$SHOW_FULL_COMMAND" \
      INTERDIMUX_SHOW_GIT_BRANCH="$SHOW_GIT_BRANCH" \
      INTERDIMUX_SHOW_PREVIEW="$(live_preview_state)" \
      INTERDIMUX_ORDER="$ORDER" \
      INTERDIMUX_SHOW_DIRS="$SHOW_DIRS" \
      INTERDIMUX_SESSION_RULE="$SESSION_RULE" \
      INTERDIMUX_DIRS_LIMIT="$DIRS_LIMIT" \
      INTERDIMUX_RECENT_LIMIT="$RECENT_LIMIT" \
      INTERDIMUX_USE_ZOXIDE="$USE_ZOXIDE" \
      INTERDIMUX_COLOR_ACCENT="$COLOR_ACCENT" \
      INTERDIMUX_COLOR_PATH="$COLOR_PATH" \
      INTERDIMUX_COLOR_GIT="$COLOR_GIT" \
      INTERDIMUX_COLOR_SSH="$COLOR_SSH" \
      INTERDIMUX_COLOR_EDITOR="$COLOR_EDITOR" \
      INTERDIMUX_COLOR_DANGER="$COLOR_DANGER" \
      INTERDIMUX_COLOR_TREE="$COLOR_TREE" \
      INTERDIMUX_COLOR_SEPARATOR="$COLOR_SEPARATOR" \
      INTERDIMUX_SHOW_TITLE="$SHOW_TITLE" \
      INTERDIMUX_TITLE_MAX="$TITLE_MAX" \
      INTERDIMUX_AGENTS="$AGENT_NAMES" \
      INTERDIMUX_AGENT_ARGS="$AGENT_ARGS" \
      INTERDIMUX_AGENT_STATE="$AGENT_STATE" \
      INTERDIMUX_TITLE_RULESET="$TITLE_RULESET" \
      INTERDIMUX_STATE_OPTS="$STATE_OPTS" \
      INTERDIMUX_VIEW="$VIEW" \
      "$IMUX_BIN" "$IMUX_PROTO" 2>/dev/null <<IMUX_SECTIONS
${sessions_raw}
$RS
${all_windows_raw}
$RS
${all_panes_raw}
$RS
${cur_raw}
$RS
${CLAUDE_REG}
IMUX_SECTIONS
    ) || { _imux_rc=$?; _imux_out=""; }
    # Exit 2 is a subcommand the binary does not know: it was built from other
    # sources than this script, and speaks another version of the protocol.
    if [ "$_imux_rc" = 2 ]; then imux_refused; fi
    # A failed or empty render must fall through to the bash renderer, never be
    # mistaken for "there is nothing to show".  Capturing costs ~2ms (the binary
    # renders the whole list in about that) and buys a safe failure mode.
    #
    # So must one that is not a row list at all.  INTERDIMUX_BIN accepts any
    # executable, and whatever a wrong one printed on exit 0 — `/bin/echo` prints
    # "gather" — used to become the entire picker.  The first row has to end in a
    # tab-separated S:/W:/P:/D: spec, the shape every row of both renderers has:
    # no fork, and nothing the real binary has to learn.
    _imux_row1="${_imux_out%%$'\n'*}"
    if [[ "$_imux_row1" == *$'\t'* && "${_imux_row1##*$'\t'}" == [SWPD]:* ]]; then
      printf '%s\n' "$_imux_out"
      return 0
    fi
  fi

  # We only reach here when the Rust core is absent or fell through — i.e. the
  # bash renderer will do the work, and IT needs the ps process table (the binary
  # built its own).  On Linux this is a no-op (the /proc backend needs no table);
  # elsewhere it is the one ps fork, paid only when there is no working binary.
  #
  # And it counts characters, as the Rust core does, even where the popup's
  # locale is C (utf8_ctype_r).
  utf8_ctype_r
  [ -z "$REPLY" ] || local LC_CTYPE="$REPLY"
  [ "$SHOW_FULL_COMMAND" = "on" ] && build_process_table

  # MRU ordering: most recently attended sessions first (last-attached,
  # falling back to activity for never-attached sessions); the current
  # session moves to the END so the top row is the previous session —
  # Enter with an empty query toggles back to it.  --cycle makes the
  # current session's windows one ↑ away.
  if [ "$ORDER" = "mru" ]; then
    local sorted current_line="" other_lines="" line sn_check
    # -s is not optional.  Two sessions share a timestamp routinely — the field
    # has one-second resolution — and without -s GNU sort breaks the tie with its
    # "last-resort comparison", which compares the WHOLE LINE under the user's
    # collation.  The Rust core uses a stable sort, so it keeps tmux's order for
    # ties; bash re-ordered them by locale, and the two renderers listed sessions
    # differently for the same server.
    #
    # (`-k2,2nr` itself is only incidentally locale-safe: `sort -n` DOES read the
    # locale's thousands separator, so `1,785` sorts differently under en_US than
    # under C.  It cannot bite here because the key is bare epoch digits — but it
    # would the moment that field grew a separator or a fraction.)
    #
    # Reproduced: glibc's en_US collation ignores punctuation at the first level,
    # so `has space` and `has"quote` compare as `hasspace` vs `hasquote` and swap.
    # Under C.UTF-8 they do not, which is why 20 of 30 parity cases failed on a
    # normal desktop and every one of them passed here.  -s disables the
    # last-resort comparison outright, so the order is stable AND locale-free.
    #
    # The key is field 2 since the name moved to the front (see _sfmt).  A line
    # tmux cut before its timestamp has an empty key, which sorts as 0 -- last,
    # for this one paint -- exactly as the Rust core's unwrap_or(0) does.
    sorted=$(printf '%s\n' "$sessions_raw" | sort -s -t"$US" -k2,2nr)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      sn_check="${line%%"$US"*}"
      if [ "$sn_check" = "$current_session" ]; then
        current_line="$line"
      else
        other_lines+="${line}"$'\n'
      fi
    done <<< "$sorted"
    sessions_raw="${other_lines}${current_line}"
    sessions_raw="${sessions_raw%$'\n'}"
  fi

  # Each session's start directory and its active window's cwd -- emit_dir_rows
  # uses them to skip directories that already have a session.
  declare -A SESSION_DIRS=()

  # Build lookup: windows grouped by session name
  #
  # A line tmux cut short (see _sfmt) still names its window, so it is KEPT --
  # dropping it lost the window and every pane under it -- but only while what
  # is left is plausibly a window: session, a numeric index, and window_active
  # as 0 or 1, or ABSENT when the cut came before it.  What tells a cut line
  # from the other short line there is, the second half of a line split by a
  # newline in a pane's cwd (`<path tail>^_<panes>^_<pid>^_<flags>`, whose 4th
  # field is the 3-digit flags), is the mark every cut line carries: tmux stops
  # at a '#{', after the separator in front of it, so a cut line ENDS in US and
  # a fragment never does.  Filtered HERE rather than in the render loop, which
  # needs the final count up front to draw the last branch as └─.  The same
  # rules as rust/src/main.rs (short_active); a full line (flags present) is
  # not second-guessed.
  #
  # So the loop needs each raw LINE, not only its fields: `read` drops a
  # trailing separator.  The section is split into lines once and each line
  # into fields by word splitting -- no here-string per line, and cheaper than
  # the `read` loop it replaces (which read its input a byte at a time).  set -f,
  # or a cwd like `/tmp/*` would be glob-expanded into the fields; IFS goes back
  # to the default before anything else in the body runs.
  declare -A windows_by_session=()
  local _w1 _w2 _w3 _w4 _w5 _w6 _w7 _w8 _w9 _kept="" _gl _gf
  local -a _glines=()
  set -f
  IFS=$'\n'; _glines=($all_windows_raw); unset IFS
  for _gl in ${_glines[@]+"${_glines[@]}"}; do
    # The US appended is the one a split drops: word splitting ends the last
    # field at a terminating separator instead of giving the EMPTY field after
    # it, as Rust's split(US) does.  With one more US, a line tmux cut (it ends
    # in US) keeps that empty last field -- and so is counted exactly as the
    # Rust core counts it.
    IFS="$US"; _gf=($_gl$US); unset IFS
    # MORE than nine fields: a US inside pane_current_path (a directory may be
    # named anything but '/' and NUL).  Every field after the path was then the
    # one to its left -- the pane count read "part2", the flags "1<US>000", and
    # the PID the pane count, so the row showed PID 1's command (`init`) with a
    # bell it did not have and stderr got "integer expression expected".  There
    # is no telling which US is the path's, so the row is dropped, as the Rust
    # core drops it (main.rs, `f.len() > 9`); its session header still renders.
    # Cut as well, before its flags, such a line used to count as nine and pass
    # as whole, and the same shift drew PID 1's command again.
    [ "${#_gf[@]}" -gt 9 ] && continue
    _w1=${_gf[0]-} _w2=${_gf[1]-} _w3=${_gf[2]-} _w4=${_gf[3]-} _w5=${_gf[4]-}
    _w6=${_gf[5]-} _w7=${_gf[6]-} _w8=${_gf[7]-} _w9=${_gf[8]-}
    [ -n "$_w1" ] || continue
    if [ -z "$_w9" ]; then
      case "$_w2" in ''|*[!0-9]*) continue ;; esac
      case "$_w4" in
        0|1) ;;
        '') [[ "$_gl" == *"$US" ]] || continue ;;   # cut before #{window_active}
        *) continue ;;
      esac
    fi
    line="$_w1$US$_w2$US$_w3$US$_w4$US$_w5$US$_w6$US$_w7$US$_w8$US$_w9"
    _kept+="$line"$'\n'
    if [[ ${windows_by_session[$_w1]+x} ]]; then
      windows_by_session["$_w1"]+=$'\n'"$line"
    else
      windows_by_session["$_w1"]="$line"
    fi
  done
  set +f
  all_windows_raw="${_kept%$'\n'}"   # what measure_widths sizes: only what renders

  # Build lookup: panes grouped by "session\x1fwindow_index".  A cut pane line
  # is kept on the same terms as a window line: numeric window AND pane index,
  # pane_active 0 or 1, or absent on a line that ends in US.  Here the mark is
  # the ONLY difference: a newline in a cwd leaves `<tail>^_<pid>^_<panes>`,
  # three fields with nothing in the fourth, exactly like `s^_0^_1^_`, a line
  # cut before #{pane_active}.
  #
  # A line cut in the pane id or the title after #{window_panes} is kept like
  # any cut line, with what is missing empty.  A pane id that is there and is
  # not %N is not a pane line at all.  Each window's ACTIVE pane lends
  # its id and title to the window row (active_pane).
  #
  # The id, the title and the options do NOT ride on in the lines this builds:
  # measure_widths and the pane loop below read those lines with `read`, which
  # takes a here-string a byte per read(2), and a title is the longest thing on
  # a pane line.  Each line ends in its number instead, and pane_agent[number]
  # holds the three (review R09).
  declare -A panes_by_window=() active_pane=() pane_agent=()
  local sn _p3 _p4 _p5 _p6 _p7 _p8 _p9 _p10 _p11 _pn=0
  _kept=""
  set -f
  IFS=$'\n'; _glines=($all_panes_raw); unset IFS
  for _gl in ${_glines[@]+"${_glines[@]}"}; do
    IFS="$US"; _gf=($_gl$US); unset IFS   # the appended US: see above
    [ "${#_gf[@]}" -gt 11 ] && continue   # a US in its cwd: see above
    sn=${_gf[0]-} widx=${_gf[1]-} _p3=${_gf[2]-} _p4=${_gf[3]-}
    _p5=${_gf[4]-} _p6=${_gf[5]-} _p7=${_gf[6]-} _p8=${_gf[7]-}
    _p9=${_gf[8]-} _p10=${_gf[9]-} _p11=${_gf[10]-}
    [ -n "$sn" ] || continue
    case "$_p9" in ''|%[0-9]*) ;; *) continue ;; esac
    case "$_p9" in %*[!0-9]*) continue ;; esac
    # Whole means all eleven fields: a line cut anywhere, even in the tail, is
    # never trusted for its pid -- nine fields ending in US is also what a US
    # inside the cwd of a line cut before #{window_panes} looks like, and that
    # line's "pid" is whatever followed the stray separator.
    if [ "${#_gf[@]}" -ne 11 ]; then _p8=""; fi
    if [ -z "$_p8" ]; then
      case "$widx" in ''|*[!0-9]*) continue ;; esac
      case "$_p3" in ''|*[!0-9]*) continue ;; esac
      case "$_p4" in
        0|1) ;;
        '') [[ "$_gl" == *"$US" ]] || continue ;;   # cut before #{pane_active}
        *) continue ;;
      esac
    fi
    _pn=$(( _pn + 1 ))
    local key="${sn}${US}${widx}" rest="$_p3$US$_p4$US$_p5$US$_p6$US$_p7$US$_p8$US$_pn"
    _kept+="$key$US$rest"$'\n'
    pane_agent[$_pn]="$_p9$US$_p10$US$_p11"   # id, title, options
    [ "$_p4" = 1 ] && active_pane["$key"]="${pane_agent[$_pn]}"
    if [[ ${panes_by_window[$key]+x} ]]; then
      panes_by_window["$key"]+=$'\n'"$rest"
    else
      panes_by_window["$key"]="$rest"
    fi
  done
  set +f
  all_panes_raw="${_kept%$'\n'}"

  # The registry by pane id: "<sid>US<word>US<since>".
  declare -A CLAUDE_BY_PANE=()
  if [ -n "$CLAUDE_REG" ]; then
    while IFS= read -r _hline; do
      [[ "$_hline" == %*"$US"* ]] && CLAUDE_BY_PANE["${_hline%%"$US"*}"]="${_hline#*"$US"}"
    done <<< "$CLAUDE_REG"
  fi

  # Size the columns to the content we just fetched (fork-free) -- AFTER the
  # grouping above, so a line it refused cannot widen a column, exactly as the
  # Rust core measures only the rows it parsed.
  measure_widths
  compute_widths

  local sla sname swins sattach spath marker meta age sdisp rule_n rule_run rule_ok
  local session_windows win_count wi branch_glyph cont idname maxid ident ctx
  local wmarker raw_cmd cmd_formatted wflags
  local pane_data pane_count pi pglyph pmarker pprefix pdisp pover pid_disp pmax ppane ptitle popts _wopt _pline
  local -a _hf=()
  local -A AMARKED=()   # the agents view: panes already marked (agent_mark_r)

  while IFS="$US" read -r sname sla swins sattach spath; do
    [ -z "$sname" ] && continue
    [ -n "$spath" ] && SESSION_DIRS["$spath"]=1
    marker=" "
    [ "$sname" = "$current_session" ] && marker="${MARKER_COLOR}*${RST}"

    # Session row: identity | meta | (empty command) | spec.  Tabs in
    # names would break the field contract — display them as spaces.
    # The name is capped so the row never exceeds the identity column
    # (4 = marker + space + ▸ + space).
    sdisp="${sname//$'\t'/ }"
    # Before truncation: the ellipsis this may append is itself non-ASCII, but
    # it is one char and one cell, so it measures fine.  Testing after would have
    # dropped the rule from every long name — which the parity suite caught.
    rule_ok=1
    [[ "$sdisp" == *[![:ascii:]]* ]] && rule_ok=0
    [ "${#sdisp}" -gt $(( IDENT_W - 4 )) ] && sdisp="${sdisp:0:IDENT_W-5}…"
    fld_reset
    fld_add "$marker" 1
    fld_add " ${DIM_TREE}▸${RST} " 3
    fld_add "${BOLD}${sdisp}${RST}" "${#sdisp}"
    # The group rule: the padding that would follow the name becomes a run of
    # '─' out to SESS_RULE_W, so the flat list reads as groups at the cost of no
    # extra rows.  Entirely inside field 1 — see rust/src/render.rs for why it
    # cannot be split across the tab into field 2.
    #
    # The SPACE before the run used to be load-bearing for RANKING as well as
    # for reading: --tiebreak=chunk scored by the whitespace chunk a match landed
    # in, so gluing the rule to the name made that chunk 50-odd cells instead of
    # 4 and dropped the exact-name `proj` session row from rank 1 to rank 11,
    # below its own windows.  The navigator's tiebreak is `index` now (see the
    # fzf_opts block), and re-measuring says the chunk length no longer decides
    # anything: glued or not, the session row still ranks first.  What is left is
    # the rendering reason — the name and the rule have to read as two things
    # rather than as one long word — which the golden corpus pins.
    #
    # ASCII only, and only here: bash measures with ${#var}, which counts
    # CHARACTERS, so a wide glyph makes FLD_LEN too small and the run too long —
    # and where the pre-existing char/cell confusion merely SHIFTS the other
    # columns, an over-long rule pushes the session meta off the right edge and
    # fzf clips it away entirely.  Conservative (an accented Latin-1 name would
    # measure fine) because there is no width table in bash to be less so.  The
    # Rust core measures cells and has no such limit; a wide-glyph name already
    # renders differently between the two, which is the bug this defers to.
    rule_n=$(( SESS_RULE_W - FLD_LEN - 3 ))
    if [ "$SESSION_RULE" = "on" ] && [ "$rule_n" -ge 3 ] && [ "$rule_ok" = 1 ]; then
      printf -v rule_run '%*s' "$rule_n" ''
      fld_add " ${DIM_TREE}${rule_run// /─}${RST}  " $(( rule_n + 3 ))
    else
      fld_pad "$IDENT_W"
    fi
    ident="$FLD"

    age_of "$sla"; age="$REPLY"
    meta="${DIM}${swins} win${RST}"
    [ -n "$sattach" ] && meta+=" ${DIM_EDIT}●${RST}"
    [ -n "$age" ] && meta+=" ${DIM}${age}${RST}"

    printf '%s\t%s\t\tS:%s\n' "$ident" "$meta" "$sname"

    session_windows="${windows_by_session[$sname]:-}"
    [ -z "$session_windows" ] && continue

    # Pure-bash line count (no fork/pipe): entries are '\n'-joined, no trailer,
    # so the window count is (number of embedded newlines) + 1.
    win_count="${session_windows//[!$'\n']/}"
    win_count=$(( ${#win_count} + 1 ))

    # Session-name prefix on child rows keeps filtered rows identifiable
    # and makes compound queries ("proj edit") work.  It is truncated to
    # PFX_W — the redundant-prefix budget carved out of the identity
    # column — so the window name (WIN_W) is never starved by a long
    # session name.  The full name still shows on the session header row.
    [ "${#sdisp}" -gt "$PFX_W" ] && sdisp="${sdisp:0:PFX_W-1}…"

    wi=0
    while IFS="$US" read -r _sn widx wname _wact wcmd wpath wpanes wpid wflags; do
      # A line tmux cut short (no flags -- see the grouping above) lost its
      # pane count and pid.  The pid is NEVER read from such a line: it is the
      # one field that reaches /proc, and a newline-split fragment can put any
      # number there.  One pane and no pid, for this one paint.
      if [ -z "$wflags" ]; then
        wpanes=1 wpid=0
      fi
      case "$wpanes" in ''|*[!0-9]*) wpanes=1 ;; esac
      wi=$((wi + 1))
      branch_glyph='├─'
      cont='│'
      if [ "$wi" -eq "$win_count" ]; then
        branch_glyph='└─'
        cont=' '
      fi

      wmarker=" "
      [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && wmarker="${MARKER_COLOR}*${RST}"

      idname="${widx}:${wname//$'\t'/ }"
      fld_reset
      fld_add "$wmarker" 1
      fld_add " ${DIM_TREE}${branch_glyph}${RST} " 4
      fld_add "${DIM}${sdisp}${RST} " $(( ${#sdisp} + 1 ))
      maxid=$(( IDENT_W - FLD_LEN ))
      if [ "$maxid" -gt 2 ] && [ "${#idname}" -gt "$maxid" ]; then
        idname="${idname:0:maxid-1}…"
      fi
      fld_add "$idname" "${#idname}"
      fld_pad "$IDENT_W"
      ident="$FLD"

      [ "$_wact" = "1" ] && [ -n "$wpath" ] && SESSION_DIRS["$wpath"]=1

      build_ctx_field "$wpath" "${wflags:0:1}" "${wflags:1:1}" "${wflags:2:1}"
      ctx="$FLD"

      resolve_command "$wcmd" "$wpid"; raw_cmd="$REPLY"
      _hline="${active_pane[${sname}${US}${widx}]-}"
      # id US title US options, split by word splitting like the lines they
      # came from: ${x#*"$US"} and ${x%%"$US"*} are quadratic in where the US
      # is, and the title before it is as long as a program makes it -- a
      # 40,000-character one cost the list 1.6 s, a 1 MB one 90 s.
      set -f; IFS="$US"; _hf=($_hline$US); unset IFS; set +f
      cmd_field "$raw_cmd" "$wpid" "${_hf[0]-}" "${_hf[1]-}" "${_hf[2]-}"; cmd_formatted="$REPLY"
      # The agents view marks the window row only where no pane rows follow
      # to carry the mark themselves (see VIEW).
      if [ -n "$VIEW" ] && [ -n "$AS_STATE" ] \
         && { [ "$wpanes" -le 1 ] || [ -z "${panes_by_window[${sname}${US}${widx}]:-}" ]; }; then
        agent_mark_r "$AS_STATE" "${_hf[0]-}"
        [ -n "$REPLY" ] && ident="$REPLY${ident#"$wmarker"}"
      fi

      printf '%s\t%s\t%s\tW:%s:%s\n' \
        "$ident" "$ctx" "$cmd_formatted" "$sname" "$widx"

      # Panes (only for multi-pane windows)
      if [ "$wpanes" -gt 1 ]; then
        pane_data="${panes_by_window[${sname}${US}${widx}]:-}"
        [ -z "$pane_data" ] && continue

        pane_count="${pane_data//[!$'\n']/}"
        pane_count=$(( ${#pane_count} + 1 ))
        pi=0

        while IFS="$US" read -r pidx _pact pcmd ppath ppid _wp2 _pline; do
          [ -n "$_wp2" ] || ppid=0   # cut short: never read its pid (see above)
          # id US title US options, word-split as the window row splits them:
          # ${x%%"$US"*} past the title is quadratic in the title's length
          _hline="${pane_agent[${_pline:-0}]-}"
          set -f; IFS="$US"; _hf=($_hline$US); unset IFS; set +f
          ppane="${_hf[0]-}" ptitle="${_hf[1]-}" popts="${_hf[2]-}"
          pi=$((pi + 1))
          pglyph='├╴'
          [ "$pi" -eq "$pane_count" ] && pglyph='└╴'

          pmarker=" "
          [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && [ "$pidx" = "$current_pane" ] && pmarker="${MARKER_COLOR}*${RST}"

          # Identity budget: 7 glyph columns + "sdisp widx." + pidx.
          # Multi-digit indexes can push past IDENT_W — shorten the
          # (dim) session prefix, never the pane id itself.
          pdisp="$sdisp"
          pover=$(( 9 + ${#pdisp} + ${#widx} + ${#pidx} - IDENT_W ))
          if [ "$pover" -gt 0 ]; then
            if [ "${#pdisp}" -gt $(( pover + 1 )) ]; then
              pdisp="${pdisp:0:${#pdisp}-pover-1}…"
            else
              # Too short to absorb the overflow (a short session name, wide
              # indexes): drop it.  Left in, the row ran past every other one,
              # since fld_pad can only pad.  rust/src/render.rs pane_ident.
              pdisp=""
            fi
          fi
          if [ -n "$pdisp" ]; then pprefix="${pdisp} ${widx}."; else pprefix="${widx}."; fi
          # Still over with the prefix gone: the bare indexes can outrun the
          # column's floor too (a window index near INT_MAX and a pane index near
          # 65535, in a narrow popup).  A shortened id beats a shifted column --
          # the SPEC still carries both indexes exactly.  Same ladder as the Rust
          # core; ASCII digits, so characters are cells here.
          pid_disp="$pidx"
          if (( 7 + ${#pprefix} + ${#pid_disp} > IDENT_W )); then
            pmax=$(( IDENT_W - 7 - ${#pprefix} )); (( pmax < 0 )) && pmax=0
            if (( ${#pid_disp} > pmax )); then
              if (( pmax == 0 )); then pid_disp=""; else pid_disp="${pid_disp:0:pmax-1}…"; fi
            fi
            if (( 7 + ${#pprefix} + ${#pid_disp} > IDENT_W )); then
              pmax=$(( IDENT_W - 7 )); (( pmax < 0 )) && pmax=0
              if (( ${#pprefix} > pmax )); then
                if (( pmax == 0 )); then pprefix=""; else pprefix="${pprefix:0:pmax-1}…"; fi
              fi
              pid_disp=""
            fi
          fi
          fld_reset
          fld_add "$pmarker" 1
          fld_add " ${DIM_TREE}${cont} ${pglyph}${RST} " 6
          fld_add "${DIM}${pprefix}${RST}${pid_disp}" $(( ${#pprefix} + ${#pid_disp} ))
          fld_pad "$IDENT_W"
          ident="$FLD"

          build_ctx_field "$ppath" "" "" ""
          ctx="$FLD"

          resolve_command "$pcmd" "$ppid"; raw_cmd="$REPLY"
          cmd_field "$raw_cmd" "$ppid" "$ppane" "$ptitle" "$popts"; cmd_formatted="$REPLY"
          if [ -n "$VIEW" ] && [ -n "$AS_STATE" ]; then
            agent_mark_r "$AS_STATE" "$ppane"
            [ -n "$REPLY" ] && ident="$REPLY${ident#"$pmarker"}"
          fi

          printf '%s\t%s\t%s\tP:%s:%s:%s\n' \
            "$ident" "$ctx" "$cmd_formatted" "$sname" "$widx" "$pidx"
        done <<< "$pane_data"
      fi
    done <<< "$session_windows"
  done <<< "$sessions_raw"

  emit_dir_rows
}

# ---------------------------------------------------------------------------
# Preview command (called by fzf --preview)
# ---------------------------------------------------------------------------

# Rule line sized to the preview pane
preview_rule() {
  local w="${FZF_PREVIEW_COLUMNS:-60}" label="${1:-}" bar
  [[ "$w" =~ ^[0-9]+$ ]] || w=60
  [ "$w" -gt 2 ] && w=$(( w - 2 ))
  printf -v bar '%*s' "$w" ''
  bar="${bar// /─}"
  if [ -n "$label" ]; then
    local rest=$(( w - ${#label} - 4 ))
    [ "$rest" -lt 0 ] && rest=0
    printf "${DIM_TREE}── ${DIM_PATH}%s ${DIM_TREE}%s${RST}\n" \
      "$label" "${bar:0:rest}"
  else
    printf "${DIM_TREE}%s${RST}\n" "$bar"
  fi
}

# Text $1, dim, cut into lines as wide as the preview's rule (the preview
# window does not wrap): an agent's command line under the header.
preview_wrapped() {
  local w="${FZF_PREVIEW_COLUMNS:-60}" t="$1"
  [[ "$w" =~ ^[0-9]+$ ]] || w=60
  [ "$w" -gt 2 ] && w=$(( w - 2 ))
  [ "$w" -ge 1 ] || w=60
  while [ -n "$t" ]; do
    printf "${DIM}%s${RST}\n" "${t:0:w}"
    t="${t:w}"
  done
}

# Print captured pane content with trailing blank lines removed
print_capture() {
  local content="$1" last
  while [ -n "$content" ]; do
    last="${content##*$'\n'}"
    case "$last" in
      *[![:space:]]*) break ;;
    esac
    [ "$last" = "$content" ] && { content=""; break; }
    content="${content%$'\n'*}"
  done
  [ -n "$content" ] && printf '%s\n' "$content"
}

if [ "${1:-}" = "--preview" ]; then
  set +e
  spec="$2"
  spec="${spec%%	*}"
  parse_spec "$spec"

  # Directory rows preview the directory itself, not a tmux target.
  if [ "$SPEC_TYPE" = "D" ]; then
    exec bash "$SCRIPT_PATH" --dirs-preview "$SPEC_DIR"
  fi

  target=$(spec_target)

  case "$SPEC_TYPE" in
    S)
      # $target is spec_target's session form ("=name:", or "$ID:" for a name
      # no '=' form can reach), which resolves to the session's active pane.
      info=$(tmux display-message -p -t "$target" \
        "#{session_windows}${US}#{?session_attached,attached,detached}" 2>/dev/null)
      IFS="$US" read -r s_wins s_att <<< "$info"
      printf "${BOLD_AMBER}▸ %s${RST}  ${DIM}%s win · %s${RST}\n" \
        "$SPEC_SESSION" "${s_wins:-?}" "${s_att:-}"
      preview_rule
      tmux list-windows -t "$target" \
        -F "#{window_index}:#{window_name}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_active}${US}#{window_panes}" 2>/dev/null | \
      while IFS="$US" read -r wid wcmd wpath wact wpanes; do
        # a line tmux cut short (see gather_targets) has no pane count
        case "$wpanes" in ''|*[!0-9]*) wpanes=1 ;; esac
        marker=" "
        [ "$wact" = "1" ] && marker="${MARKER_COLOR}*${RST}"
        wpath="${wpath/#$HOME/\~}"
        printf ' %s %s%s%s %s%s%s %s%s%s' \
          "$marker" "$BOLD" "$(dpad "$wid" 16)" "$RST" \
          "$DIM_CMD" "$(dpad "$wcmd" 14)" "$RST" \
          "$DIM_PATH" "$wpath" "$RST"
        [ "$wpanes" -gt 1 ] && printf '  \033[2m(%s panes)\033[0m' "$wpanes"
        printf '\n'
      done
      echo ""
      preview_rule "active pane"
      print_capture "$(tmux capture-pane -t "$target" -p -e -S -30 2>/dev/null)" || echo "(no active pane)"
      ;;
    *)
      # Checked by index as well (spec_at): a stale row must not preview the
      # window that merely took its number as a NAME.  Captured by the IDs the
      # check found, so tmux resolves the row once.
      p_pid="" p_cmd="" p_path="" p_look="" p_args=""
      if spec_at "$target" "#{pane_pid}${US}#{pane_current_command}${US}#{pane_current_path}"; then
        IFS="$US" read -r p_pid p_cmd p_path <<< "$REPLY"
        target="$SPEC_AT"
      else
        target="$NO_SUCH_TARGET"
      fi
      # An agent's row is headed by the agent and, once it shows a state or a
      # description, drops its arguments (cmd_field).  The header names it the
      # same way (`codex`, not tmux's `node`), and the line under it is its
      # command line with them (`codex resume <id>`).  Only an interpreter or
      # an agent's own name can be an agent, so no other pane pays for the
      # lookup (a /proc read; one ps without /proc).
      if [ -n "$AGENT_KNOWN" ] && [ -n "$p_pid" ]; then
        case "$p_cmd" in
          node|nodejs|python*) p_look=1 ;;
          *) [[ "$AGENT_KNOWN" == *" $p_cmd "* ]] && p_look=1 ;;
        esac
        if [ -n "$p_look" ]; then
          [ "$SHOW_FULL_COMMAND" = on ] && build_process_table
          resolve_command "$p_cmd" "$p_pid"
          agent_of "$REPLY"
          if [ -n "$AG_NAME" ]; then
            p_cmd="$AG_NAME"
            [ -n "$AG_REST" ] && p_args="$AG_NAME$AG_REST"
          fi
        fi
      fi
      p_path="${p_path/#$HOME/\~}"
      if [ "$SPEC_TYPE" = "W" ]; then
        printf "${BOLD_AMBER}%s:%s${RST}" "$SPEC_SESSION" "$SPEC_WIDX"
      else
        printf "${BOLD_AMBER}%s:%s.%s${RST}" "$SPEC_SESSION" "$SPEC_WIDX" "$SPEC_PIDX"
      fi
      printf "  ${DIM_CMD}%s${RST} ${DIM}·${RST} ${DIM_PATH}%s${RST}\n" \
        "${p_cmd:-?}" "${p_path:-?}"
      [ -n "$p_args" ] && preview_wrapped "$p_args"
      preview_rule
      print_capture "$(tmux capture-pane -t "$target" -p -e -S -50 2>/dev/null)" || echo "(cannot capture pane)"
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Directory preview (called by fzf --preview for dir picker)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dirs-preview" ]; then
  set +e
  dir="$2"
  [ -d "$dir" ] || { echo "(directory not found)"; exit 0; }

  display_path="${dir/#$HOME/\~}"
  printf "${BOLD_AMBER}%s${RST}\n" "$(basename "$dir")"
  printf '\033[2m%s\033[0m\n\n' "$display_path"

  detect_project_type "$dir"
  [ -n "$REPLY" ] && printf "  ${GREEN}Type:${RST} %s\n" "$REPLY"

  if [ -d "$dir/.git" ]; then
    head_file="$dir/.git/HEAD"
    if [ -f "$head_file" ]; then
      read -r head_content < "$head_file" 2>/dev/null || head_content=""
      case "$head_content" in
        "ref: refs/heads/"*) printf "  ${DIM_GIT}Branch:${RST} %s\n" "${head_content#ref: refs/heads/}" ;;
        ?*) printf "  ${DIM_GIT}Branch:${RST} @%s\n" "${head_content:0:7}" ;;
      esac
    fi

    # Bound the two git forks.  `head -200` bounds the OUTPUT, not the work:
    # `git status` still walks the whole tree before emitting anything, and this
    # runs on every cursor move in the picker.  Measured on a 30,000-file repo
    # with a warm page cache: 60-70 ms — tolerable, but it scales with the tree
    # and a cold cache or a network filesystem has no ceiling at all.  A repo
    # with submodules is worse still, since the scan recurses into each one.
    #
    # `timeout` is coreutils and not guaranteed present; without it the calls
    # stay unbounded, which is exactly today's behaviour.
    _git_to=""
    command -v timeout >/dev/null 2>&1 && _git_to="timeout 1"

    last_commit=$($_git_to git -C "$dir" --no-optional-locks log -1 --oneline 2>/dev/null || true)
    [ -n "$last_commit" ] && printf "  ${DIM_PATH}Commit:${RST} %s\n" "$last_commit"

    changed=$($_git_to git -C "$dir" --no-optional-locks status --porcelain --ignore-submodules 2>/dev/null | head -200 | wc -l | tr -d ' ')
    [ "$changed" -eq 200 ] && changed="200+"
    [ "$changed" != "0" ] && printf "  ${DIM_CMD}Changes:${RST} %s files\n" "$changed"
  fi

  for readme in README.md README.rst README.txt README; do
    if [ -f "$dir/$readme" ]; then
      while IFS= read -r line; do
        case "$line" in
          ""|\#*|=*|-*) continue ;;
          *) printf '\n  \033[2m%s\033[0m\n' "$line"; break ;;
        esac
      done < "$dir/$readme"
      break
    fi
  done

  echo ""
  preview_rule "contents"
  ls -1p "$dir" 2>/dev/null | head -20

  exit 0
fi

# ---------------------------------------------------------------------------
# Directory list generation (called by fzf reload for dir picker)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dirs-list" ]; then
  set +e
  shift
  mode="default"
  query=""

  while [ $# -gt 0 ]; do
    case "$1" in
      # shift defensively: "shift 2" with one argument left shifts
      # nothing (and this loop runs under set +e), which would spin
      # forever on a trailing --deep/--scan
      --deep) mode="deep"; query="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --scan) mode="scan"; query="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) shift ;;
    esac
  done

  finder=$(resolve_finder)
  [ -z "$finder" ] && { echo "interdimux: no directory finder available" >&2; exit 1; }

  mapfile -t search_paths < <(resolve_search_paths)
  [ ${#search_paths[@]} -eq 0 ] && search_paths=("$HOME")

  declare -A seen=()

  # Which directories already have a session, and which one (IDEAS #7).
  #
  # Enter on such a row switches rather than creates -- connect_dir finds the
  # session first -- but the picker gave no sign of that, so "new session" on a
  # directory you already had open looked like it had done nothing.  Naming the
  # session is the useful half: it tells you where you are about to land.
  #
  # So the badge is dir_session's answer, from the same table and the same code
  # Enter goes through (resolve_session_name): a row is badged exactly when Enter
  # would switch, and with the session it would switch to.  It used to be a map
  # of its own, keyed on each session's start directory AND on its active
  # window's cwd, whatever the session was called -- so ~/repo said "→ foo" for
  # a `tmux new -s foo` started there (or one merely passing through), and Enter
  # created a second session, `repo`.  One list-sessions for the whole list;
  # the per-row lookup is in-process.
  load_session_table

  # Path column width derived from the popup (list pane is ~60% with the
  # 40% preview open)
  DIRS_PATH_W=$(( $(term_cols) * 55 / 100 - 10 ))
  [ "$DIRS_PATH_W" -lt 28 ] && DIRS_PATH_W=28
  [ "$DIRS_PATH_W" -gt 64 ] && DIRS_PATH_W=64

  # Output format (tab-delimited, 3 fields): DISPLAY <TAB> BADGE <TAB> PATH
  # The path spec sits last (same reasoning as gather_targets); the badge
  # column is excluded from fzf match scope.
  emit_dir() {
    local dir="$1" tier="$2"
    # A tab in the path can't be represented in the tab-delimited row
    # (the selection would resolve to the post-tab fragment) — skip it
    case "$dir" in *$'\t'*) return ;; esac
    [[ ${seen[$dir]+x} ]] && return
    seen["$dir"]=1
    # The display copy only: $dir itself, raw, is the spec Enter opens.
    # Sanitised the way the navigator's rows are (build_ctx_field): an ESC in a
    # directory's name reached the picker as a live escape sequence that hid
    # the name and recoloured the row, and dpad counted the bytes the terminal
    # swallowed, so the badge column moved left.
    local display_path="${dir/#$HOME/\~}"
    sanitize_args "$display_path"; display_path="$REPLY"
    trim_path "$display_path" "$DIRS_PATH_W"; display_path="$REPLY"

    # Already open?  Say so, and say WHERE -- the badge column is outside fzf's
    # match scope, so the session name is display-only and cannot skew results.
    dir_session "$dir"
    if [ -n "$DIR_SID" ]; then
      printf '  %s▸%s  %s\t%s→%s %s%s%s\t%s\n' \
        "$BOLD_AMBER" "$RST" "$(dpad "$display_path" "$DIRS_PATH_W")" \
        "$DIM" "$RST" "$ACCENT_ESC" "$REPLY" "$RST" "$dir"
      return
    fi

    # The type badge is on the ★ tier too.  These are the directories you use
    # most, and they were the only ones without it -- a ◆ row showed "Rust" and
    # the same directory, once it became recent, showed nothing.  detect_project_type
    # is a handful of `[ -f ]` tests and this is the ctrl-o picker, not the hot path.
    local type_badge=""
    case "$tier" in
      recent|project)
        detect_project_type "$dir"
        [ -n "$REPLY" ] && type_badge="${DIM}${REPLY}${RST}"
        ;;
    esac

    case "$tier" in
      recent)
        printf '  %s★%s  %s\t%s\t%s\n' \
          "$BOLD_AMBER" "$RST" "$(dpad "$display_path" "$DIRS_PATH_W")" "$type_badge" "$dir"
        ;;
      project)
        printf "  ${GREEN}◆${RST}  %s\t%s\t%s\n" \
          "$(dpad "$display_path" "$DIRS_PATH_W")" "$type_badge" "$dir"
        ;;
      dir)
        printf '  %s·%s  %s\t\t%s\n' \
          "$DIM" "$RST" "$(dpad "$display_path" "$DIRS_PATH_W")" "$dir"
        ;;
    esac
  }

  # Classified HERE, in the parent: the `< <(load_recent_dirs)` below runs in a
  # subshell, which would parse the mount table for itself and then this
  # process again for detect_project_type (a no-op when ctrl-o's picker has
  # handed it down -- see mounts_export).
  [ "$_MOUNTS_READ" = 1 ] || _mounts_read

  case "$mode" in
    default)
      while IFS= read -r d; do
        [ -n "$d" ] && emit_dir "$d" recent ""
      done < <(load_recent_dirs)

      _projects=()
      _others=()
      for sp in "${search_paths[@]}"; do
        [ -d "$sp" ] || continue
        while IFS= read -r d; do
          [ -z "$d" ] || [ "$d" = "$sp" ] && continue
          collect_dir "$d"
        done < <(scan_dirs "$sp" 1 "$finder")
      done
      emit_sorted_tiers
      ;;

    deep)
      # Deep scan: increase depth on directories matching the query.
      # If query is empty, scan all search paths at depth 2.
      # All query matching is case-insensitive (like fzf's own filtering).
      expanded="${query/#\~/$HOME}"
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ -z "$query" ] || [[ "${d,,}" == *"${expanded,,}"* ]]; then
          emit_dir "$d" recent ""
        fi
      done < <(load_recent_dirs)

      _projects=()
      _others=()

      if [ -z "$query" ]; then
        for sp in "${search_paths[@]}"; do
          [ -d "$sp" ] || continue
          while IFS= read -r d; do
            [ -z "$d" ] || [ "$d" = "$sp" ] && continue
            collect_dir "$d"
          done < <(scan_dirs "$sp" 2 "$finder")
        done
      else
        # Try the query as a literal path first: if relative, resolve
        # against $HOME and each search path.  Any existing directory is
        # scanned directly at depth 3.
        query_roots=()
        if [[ "$expanded" == /* ]]; then
          query_roots+=("$expanded")
        else
          query_roots+=("$HOME/$expanded")
          for sp in "${search_paths[@]}"; do
            query_roots+=("$sp/$expanded")
          done
        fi
        for qr in "${query_roots[@]}"; do
          if [ -d "$qr" ]; then
            collect_dir "$qr"
            while IFS= read -r d; do
              [ -z "$d" ] || [ "$d" = "$qr" ] && continue
              collect_dir "$d"
            done < <(scan_dirs "$qr" "$SCAN_DEPTH" "$finder")
            continue
          fi
          # Partially typed path: walk up to the deepest existing
          # ancestor, then scan it for dirs completing the typed prefix.
          anc="$qr"
          stripped=0
          while [ "$anc" != "/" ] && [ ! -d "$anc" ]; do
            anc="${anc%/*}"
            [ -z "$anc" ] && anc="/"
            stripped=$((stripped + 1))
          done
          [ "$anc" = "/" ] && continue
          [ "$stripped" -gt "$SCAN_DEPTH" ] && continue
          while IFS= read -r d; do
            [ -z "$d" ] && continue
            if [[ "${d,,}" == "${qr,,}"* ]]; then
              collect_dir "$d"
              while IFS= read -r sub; do
                [ -z "$sub" ] && continue
                collect_dir "$sub"
              done < <(scan_dirs "$d" "$SCAN_DEPTH" "$finder")
            fi
          done < <(scan_dirs "$anc" "$stripped" "$finder")
        done

        if [[ "$query" != */* ]]; then
          # Name fragment (no slash): let the finder search for matching
          # dir names natively — reaches deep at low cost.
          for sp in "${search_paths[@]}"; do
            [ -d "$sp" ] || continue
            mapfile -t _matches < <(match_dirs "$sp" "$query" $((SCAN_DEPTH * 2)) "$finder" | sort)
            _scanned_root=""
            for d in ${_matches[@]+"${_matches[@]}"}; do
              [ -z "$d" ] || [ "$d" = "$sp" ] && continue
              collect_dir "$d"
              # A match inside an already-scanned match is covered
              [ -n "$_scanned_root" ] && [[ "$d" == "$_scanned_root"/* ]] && continue
              _scanned_root="$d"
              while IFS= read -r sub; do
                [ -z "$sub" ] && continue
                collect_dir "$sub"
              done < <(scan_dirs "$d" "$SCAN_DEPTH" "$finder")
            done
          done
        else
          # Multi-component query: match it as a path substring against a
          # scan deep enough for it to appear, capped to keep the scan
          # cheap.  (Real paths are handled by the query_roots pass above.)
          slashes="${query//[^\/]/}"
          match_depth=$((1 + ${#slashes}))
          [ "$match_depth" -lt 2 ] && match_depth=2
          [ "$match_depth" -gt "$SCAN_DEPTH" ] && match_depth="$SCAN_DEPTH"
          for sp in "${search_paths[@]}"; do
            [ -d "$sp" ] || continue
            while IFS= read -r d; do
              [ -z "$d" ] || [ "$d" = "$sp" ] && continue
              if [[ "${d,,}" == *"${query,,}"* ]]; then
                collect_dir "$d"
                while IFS= read -r sub; do
                  [ -z "$sub" ] && continue
                  collect_dir "$sub"
                done < <(scan_dirs "$d" "$SCAN_DEPTH" "$finder")
              fi
            done < <(scan_dirs "$sp" "$match_depth" "$finder")
          done
        fi
      fi

      emit_sorted_tiers
      ;;

    scan)
      scan_root=""

      if [ -n "$query" ] && [ -d "$query" ]; then
        scan_root="$query"
      elif [ -n "$query" ]; then
        expanded="${query/#\~/$HOME}"
        if [ -d "$expanded" ]; then
          scan_root="$expanded"
        else
          parent="$(dirname "$expanded")"
          [ -d "$parent" ] && scan_root="$parent"
        fi
      fi

      if [ -n "$scan_root" ]; then
        _projects=()
        _others=()
        collect_dir "$scan_root"
        while IFS= read -r d; do
          [ -z "$d" ] || [ "$d" = "$scan_root" ] && continue
          collect_dir "$d"
        done < <(scan_dirs "$scan_root" 2 "$finder")
        emit_sorted_tiers
      fi
      ;;
  esac

  exit 0
fi

# ---------------------------------------------------------------------------
# Session name resolution (exposed for tests)
# ---------------------------------------------------------------------------

# Open a directory as a session (create + hydrate + switch, or just switch).
# Exposed so it is bindable directly — `bind-key o run-shell -b "bash … \
# --connect-dir ~/code/api"` — and so tests can exercise hydration without
# driving a picker.

# Find-or-create: turn a query that matched nothing into a session.
# The query is resolved as a path first, then through zoxide, then falls back to
# $HOME.  Factored out of the navigator's accept path so raw mode can invoke it
# from inside fzf (see the `zero`/enter transform below), where there is no exit
# code to signal "nothing matched".

# A query with fzf's search syntax taken out: the words a session is named
# from.  Sets REPLY (empty when nothing is left).
#
# fzf reads a query as space-separated terms, each of which may carry
# operators: a leading ' (exact), ^ (prefix) or ! (not), a trailing $ (suffix),
# and 'word' (exact on word boundaries).  None of that is part of a name, but
# the create took the query literally (review UX-54).  fzf's own exact syntax
# is the instinctive escape from a scattered match -- `'docs` does reach zero
# matches -- and Enter then made a session called `'docs`.  So every term loses
# its operators, and the empty terms that leaves (runs of spaces, a lone `'`)
# are dropped, the way fzf drops them: `docs ` names `docs`, not `docs-`, and
# a query of blanks names nothing.  resolve_create_target calls this, so the
# bar that announces a name and the create that makes it cannot disagree.
#
# Two more pieces of fzf's syntax (review R05).  A term that is exactly `|` is
# fzf's OR, and a query with one is a filter -- `foo | bar` made `foo-|-bar`,
# and any edit of the agents view's query (a trailing space, one more word)
# offered and made junk like `approve-|-input-qqq` in ~ -- so it names
# nothing, and QW_OR=1 says why.  And `\ ` is a space INSIDE a term, not
# between two: `my\ proj` is one term, and names `my-proj` (not `my\-proj`);
# `~/my\ dir` is that directory.  (`foo |bar` is a literal term to fzf too.)
QW_OR=0 QW_WHY=""
query_words_r() {
  local rest="$1" t="" lead out="" c
  local -a terms=()
  QW_OR=0
  while [ -n "$rest" ]; do
    case "$rest" in
      '\ '*) t+=" "; rest="${rest:2}" ;;
      ' '*)  terms+=("$t"); t=""; rest="${rest:1}" ;;
      *)     c="${rest%%[\\ ]*}"; [ -n "$c" ] || c="${rest:0:1}"
             t+="$c"; rest="${rest:${#c}}" ;;
    esac
  done
  terms+=("$t")
  for t in "${terms[@]}"; do
    if [ "$t" = "|" ]; then QW_OR=1; REPLY=""; return 0; fi
    lead="${t%%[!\'^!]*}"          # the leading run of ' ^ !
    t="${t#"$lead"}"
    t="${t%\$}"
    case "$lead" in *\'*) t="${t%\'}" ;; esac
    [ -n "$t" ] && out+="${out:+ }$t"
  done
  REPLY="$out"
}

# What a query WOULD become.  Sets CREATE_DIR / CREATE_NAME / CREATE_SRC;
# returns 1 when the query cannot produce a session at all, with QW_WHY saying
# why when there is more to say than "nothing left of it": `or` (a `|` term,
# see query_words_r) or `mark` (the agents view's query, see VIEW).
#
# $2 = `name`: only CREATE_NAME is wanted (the bar's alt-enter entry, and
# --create-key, which asks whether there is one).  The name of a query that is
# not a directory is the query itself, whatever zoxide says, so the zoxide
# lookup -- a subshell and two execs, on every keystroke of a typed query
# (review R21) -- is skipped, and CREATE_DIR / CREATE_SRC are left empty.
#
# One resolver for both the header and the accept, because they used to derive
# the name independently and disagreed: describe_create did a plain
# `basename | tr`, while the accept went through resolve_session_name, which
# DISAMBIGUATES against existing sessions.  With a session "api" already open at
# ~/work/api, typing ~/other/api showed "create api" and created "other-api".
# The header is the only thing telling the user what Enter does, so it has to be
# derived from the same code that does it.
resolve_create_target() {
  local query expanded mode="${2:-}"
  CREATE_DIR=""; CREATE_NAME=""; CREATE_SRC=""; QW_WHY=""
  # The agents view's query is a filter, never a name: while one of its mark
  # terms is in the query, whatever else was typed, it names nothing -- for
  # every caller, the bar's create-key entry and alt-enter too, not only Enter.
  # (Its `|` alone covers most edits; this covers the rest.)
  if [ -n "$VIEW" ]; then
    # Anywhere, not only as a term of its own: with both blanks around the
    # `|` deleted, `^!|^?` is ONE fzf term that still matches the marks, and
    # it named a session `|^?` (the G2 checker).
    case "$1" in *'^!'*|*'^?'*) QW_WHY=mark; return 1 ;; esac
  fi
  query_words_r "$1"; query="$REPLY"
  [ "$QW_OR" = 1 ] && QW_WHY=or
  [ -n "$query" ] || return 1
  expanded="${query/#\~/$HOME}"
  if [ -d "$expanded" ] && CREATE_DIR=$(cd "$expanded" 2>/dev/null && pwd -P); then
    CREATE_SRC="path"
    # the PHYSICAL path, so a symlinked query names the session after where it
    # actually lands -- describe_create used the unresolved one
    CREATE_NAME=$(resolve_session_name "$CREATE_DIR")
  elif [ "$mode" = name ]; then
    CREATE_DIR=""
    CREATE_NAME="${query//[.: \/]/-}"
  else
    CREATE_DIR=""
    if [ "$USE_ZOXIDE" = "on" ] && command -v zoxide >/dev/null 2>&1; then
      CREATE_DIR=$(zoxide query -- "$query" 2>/dev/null | head -1) || true
    fi
    if [ -d "$CREATE_DIR" ]; then CREATE_SRC="zoxide"; else CREATE_DIR="$HOME"; CREATE_SRC="home"; fi
    # What `tr '.: /' '----'` did, without its two forks: the bar's create-key
    # entry runs this on every keystroke of a typed query.
    CREATE_NAME="${query//[.: \/]/-}"
  fi
  [ -n "$CREATE_NAME" ] || return 1
  return 0
}

# Sets REPLY to the session name; prints nothing.
#
# A query that names nothing -- blanks, only fzf syntax, an OR, the agents
# view's query when no agent waits any more -- creates nothing, quietly
# (REPLY stays empty): it is a filter, and the bar has said so
# (describe_create).  Returns 1 only when a create was tried and failed.
create_from_query() {
  local query="$1"
  REPLY=""
  resolve_create_target "$query" || return 0
  # session_id_of, not has-session "=name": the same exact match connect_dir
  # uses, so a query like "$0" is not mistaken for session ID 0.
  session_id_of "$CREATE_NAME"
  if [ -z "$REPLY" ]; then
    record_dir_use "$CREATE_DIR"
  fi
  connect_dir "$CREATE_DIR" "$CREATE_NAME" || return 1
  REPLY="$CREATE_NAME"
  return 0
}

# "switch to", not "create", when the name already exists -- that is what
# connect_dir does, and promising a new session it will not make is the same
# class of lie as naming the wrong one.  After resolve_create_target; sets REPLY.
create_verb_r() {
  session_id_of "$CREATE_NAME"
  if [ -n "$REPLY" ]; then REPLY="switch to"; else REPLY="create"; fi
}

# The create key's entry in the hint bar while a query is typed and rows match
# (review UX-54): alt-enter creates from the query whatever the match count, and
# a scattered match holding the cursor is exactly when the user needs to be told
# so.  Same resolver and verb as describe_create, so it names what alt-enter
# will make, styled like every other entry in the bar.  Sets REPLY (empty when
# the query names nothing) and REPLY_W, its width in cells -- dlg_width, since
# the name is whatever was typed, wide characters included.
create_key_hint_r() {
  local h
  REPLY="" REPLY_W=0
  resolve_create_target "$1" name || return 0
  create_verb_r
  hint_r 'M-⏎' "$REPLY $CREATE_NAME"; h="$REPLY"
  dlg_width "$h"; REPLY_W="$REPLY"
  REPLY="$h"
  return 0
}

# What find-or-create WOULD do for a query, as a human-readable string.  Used by
# the zero-match header so the feature stops being invisible (IDEAS #1) and a
# typo cannot silently create junk.
describe_create() {
  local query="$1" verb
  REPLY=""
  # A query that names nothing gets no announcement, only the reason when
  # there is one worth giving: Enter does nothing here, and says so.
  if ! resolve_create_target "$query"; then
    if [ "$QW_WHY" = mark ] && [ "$query" = "$AGENTS_QUERY" ]; then
      hint_r '∅' 'no agent is waiting on you' esc quit
    elif [ "$QW_WHY" = mark ]; then
      hint_r '∅' 'no waiting agent matches' esc quit
    elif [ "$QW_WHY" = or ]; then
      hint_r '∅' 'a query with | is a filter, not a name' esc quit
    fi
    return 0
  fi
  create_verb_r; verb="$REPLY"
  printf -v REPLY '%s%s%s%s %s%s %sin %s%s %s(%s)%s' \
    "$ACCENT_ESC" "$verb" "$RST" "$DIM" "$RST$ACCENT_ESC$CREATE_NAME" "$RST" \
    "$DIM" "$RST$DIM${CREATE_DIR/#$HOME/\~}" "$RST" "$DIM" "$CREATE_SRC" "$RST"
  return 0
}

# ---------------------------------------------------------------------------
# Scheduled keys — send a command to a pane at a future time
# ---------------------------------------------------------------------------
#
#   interdimux.sh --send-at "17:30"        <target> <command...>
#   interdimux.sh --send-in 90             <target> <command...>
#   interdimux.sh --sched-list
#   interdimux.sh --sched-cancel <id>
#
# <target> is any tmux target ("%3", "mysess:1.0", "=name:") or "." for the
# current pane.  It is resolved to a pane id NOW, so the job survives the pane
# being renamed or moved.
#
# THE DANGEROUS PART, and why every job carries a guard: **pane ids are recycled
# across a tmux server restart.**  Verified — schedule for session alpha's %0,
# restart the server, and %0 is now some other session's pane; the keys land
# there.  For a scheduled `make deploy` or `rm -rf build/` that is data loss, not
# a cosmetic bug.  Each job therefore records the server pid at submit time and
# refuses to fire if it no longer matches.
#
# Backends: `at` for >= 1 minute (it has a hard one-minute floor and silently
# truncates seconds), and tmux's own `run-shell -b -d` below that.

SCHED_LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/interdimux"
SCHED_LOG="$SCHED_LOGDIR/scheduled.log"
SCHED_QUEUE=i   # a dedicated at queue: bare `atq` lists EVERY queue and would
                # mix in the user's own jobs.  Never uppercase — that switches
                # to batch semantics that wait for a low load average.

# `-M` ("never mail") is a GNU at extension; BSD at (macOS) has no such flag and
# aborts option parsing with "illegal option -- M" before it reads the job — so
# every submit failed on macOS with exactly that message.  We still want it where
# it exists: the job body redirects all output to a log, so with no -m either at
# defaults to "mail only if there was output" = no mail, but -M also silences the
# one edge case the redirect can't (atd failing to open the log at all).  Probe
# once, with no timespec so neither variant can submit a job while we ask, and
# cache the answer.  The pattern matches BSD's "illegal option -- M" and glibc's
# "invalid option -- 'M'" alike; GNU at ACCEPTS -M, so its no-timespec error is
# about the time, never the option, and the probe correctly yields "-M".
at_mail_flag() {
  if [ -z "${_AT_MFLAG+x}" ]; then
    # Capture the message, don't pipe it: `at -M` EXITS NON-ZERO here on both
    # variants (BSD rejects the option, GNU errors on the missing timespec), and
    # under this script's `set -o pipefail` a `... | grep` would inherit at's
    # failure and answer "GNU" on every host.  Only the text tells them apart:
    # BSD prints "illegal option -- M", glibc "invalid option -- 'M'"; GNU at
    # accepts -M, so its error names the time, never the option.
    local _probe
    _probe=$(LC_ALL=C at -M </dev/null 2>&1)
    case "$_probe" in
      *'ption -- '*M*) _AT_MFLAG="" ;;   # BSD/macOS at: -M rejected, rely on the log redirect
      *)               _AT_MFLAG="-M" ;; # GNU at: -M accepted
    esac
  fi
  printf '%s' "$_AT_MFLAG"
}

# The state of the daemon that RUNS queued `at` jobs, echoed as up|down|unknown.
# Without an active runner `at` still ACCEPTS and queues jobs — submission
# succeeds — but nothing ever fires them: the silent scheduled-deploy-that-never-
# happens.  The runner, and how you ask after it, differ by OS:
#   Linux (atd):  a persistent process, so `pgrep -x atd` is the tell.
#   macOS (atrun): launchd spawns /usr/libexec/atrun on a 30s StartInterval and
#     it exits between ticks, so it is NOT a persistent process — pgrep is blind
#     to it, and `launchctl list com.apple.atrun` returns 113 for a SYSTEM-domain
#     job unless you are root (the check that wrongly read "disabled" even once it
#     was enabled).  `launchctl print system/<label>` reads the system domain
#     WITHOUT root and exits 0 only when the job is bootstrapped = will run on its
#     interval; 113 when it is not.  Verified against a real firing.  Key on the
#     EXIT CODE, never on "state = running" — atrun is "not running" at most
#     instants by design.  macOS ships atrun disabled by default.  (Bootstrapped
#     is not quite "enabled": a job you `launchctl disable` while still loaded can
#     print 0 yet not run.  That is a deliberate, self-inflicted state; the common
#     enabled/disabled cases both map correctly, so we accept the tiny blind spot
#     rather than pay a second launchctl round-trip on every schedule.)
#   BSD / no pgrep:  the runner is cron's own atrun and there is no atd process to
#     find, or we simply cannot look — report "unknown" and never cry wolf, rather
#     than assert a false "down" the way a bare pgrep check would.
# INTERDIMUX_AT_DAEMON overrides the probe (up|down|unknown) so tests can drive
# every branch without a machine-global daemon toggle.
at_daemon_state() {
  case "${INTERDIMUX_AT_DAEMON:-}" in
    up|on|1|yes)   printf up;      return ;;
    down|off|0|no) printf down;    return ;;
    unknown)       printf unknown; return ;;
  esac
  case "$(uname -s)" in
    Darwin)
      if launchctl print system/com.apple.atrun >/dev/null 2>&1; then printf up; else printf down; fi ;;
    Linux)
      command -v pgrep >/dev/null 2>&1 || { printf unknown; return; }
      if pgrep -x atd >/dev/null 2>&1; then printf up; else printf down; fi ;;
    *) printf unknown ;;
  esac
}

# The one-time command that enables at's job-runner.  Only ever shown for a
# CONFIRMED-down runner, which is macOS or Linux — BSD/unknown never reaches here.
# macOS `load -w` is nominally deprecated but still works (verified — a job fired
# afterwards).
at_enable_hint() {
  case "$(uname -s)" in
    Darwin) printf '%s' 'sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.atrun.plist' ;;
    Linux)  printf '%s' 'sudo systemctl enable --now atd' ;;
    *)      printf '%s' "ensure your system's at job-runner (atd, or cron's atrun) is enabled" ;;
  esac
}

# Resolve a user-supplied target to a stable pane id, plus the socket and the
# server pid the job will be validated against.  Sets SCHED_PANE/SOCK/SRVPID.
sched_resolve() {
  local target="$1"
  [ "$target" = "." ] && target="${TMUX_PANE:-}"
  local info
  info=$(tmux display-message -p ${target:+-t "$target"} \
        '#{pane_id}'"$US"'#{socket_path}'"$US"'#{pid}'"$US"'#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || return 1
  IFS="$US" read -r SCHED_PANE SCHED_SOCK SCHED_SRVPID SCHED_LABEL <<< "$info"
  [ -n "$SCHED_PANE" ] || return 1
  return 0
}

# The script an at job runs.  Everything it needs is baked in: at snapshots the
# submitting environment, so an inherited $TMUX would be a STALE pointer to a
# possibly-dead server — the socket is passed explicitly and the inherited value
# ignored.
sched_job_body() {
  local pane="$1" sock="$2" srvpid="$3" label="$4" keys="$5"
  # POSIX quoting, not %q: atd replays this body under /bin/sh.  See shq().
  local q_logdir q_log q_sock q_want q_pane q_send
  shq "$SCHED_LOGDIR"; q_logdir="$REPLY"
  shq "$SCHED_LOG";    q_log="$REPLY"
  shq "$sock";         q_sock="$REPLY"
  shq "$srvpid";       q_want="$REPLY"
  shq "$pane";         q_pane="$REPLY"
  # the whole send, as send_input does it (see there): a lone key name is
  # pressed, any other text survives tmux's argv parser with a trailing ';'
  # intact, and a pane left in copy-mode still runs the command
  sh_send_input 'tmux -S "$sock"' '"$pane"' "$keys"; q_send="$REPLY"
  # One field per line, each "rest of line".  The single-line form packed all
  # three into "pane=… target=… desc=…", which stops being parseable the moment
  # a session name contains a space or the literal "desc=" — and tmux allows
  # both.  The marker line keeps its trailing text so `grep '^# imux:v1 '` still
  # identifies one of our jobs.
  local q_desc
  q_desc=$(printf '%s' "$keys" | tr '\n' ' ')
  printf '%s\n' \
    "# imux:v1 interdimux scheduled keys" \
    "# imux-pane: ${pane}" \
    "# imux-target: ${label}" \
    "# imux-desc: ${q_desc}" \
    "# atd tries to MAIL a job's output.  With no MTA installed that output is" \
    "# destroyed and leaves only 'Exec failed for mail command' in the journal --" \
    "# which reads exactly like 'my job never ran'.  Log instead of discarding." \
    "mkdir -p ${q_logdir} 2>/dev/null" \
    "exec >>${q_log} 2>&1" \
    "echo \"== \$(date '+%Y-%m-%d %H:%M:%S') firing for ${label} (${pane})\"" \
    "sock=${q_sock}" \
    "want=${q_want}" \
    "pane=${q_pane}" \
    "got=\$(tmux -S \"\$sock\" display-message -p '#{pid}' 2>/dev/null) || exit 0" \
    "if [ \"\$got\" != \"\$want\" ]; then" \
    "  # the server restarted: pane ids have been recycled and \$pane may now" \
    "  # belong to a completely different session.  Refuse rather than misfire." \
    "  tmux -S \"\$sock\" display-message 'interdimux: scheduled keys skipped (tmux restarted)' 2>/dev/null" \
    "  exit 0" \
    "fi" \
    "${q_send} 2>/dev/null"
}

# One line per queued interdimux job:  id US when US target US pane US desc
#
# --sched-list (human columns), the Jobs picker, and the cancel dialog all read
# this, so the `at -c` parsing lives in exactly one place.
#
# Two things this gets right that the inline version did not:
#   * atq's default time column starts with the DAY NAME, so `sort -k2` ordered
#     jobs Fri < Mon < Sat rather than chronologically.  GNU -o gives a sortable
#     "YYYY-MM-DD HH:MM" stamp.  BSD at (macOS) has no -o and prints a ctime-style
#     "<dow> <mon> <dd> HH:MM:SS <YYYY>" in job-id order, so reformat it to that
#     same sortable stamp with `date -j -f` and sort by it — the Jobs list stays
#     chronological on macOS too, and its when-column stays narrow instead of
#     carrying a day name and seconds.
#   * the header fields are read positionally from their own lines, so a session
#     name containing a space or "desc=" cannot shift them.
sched_rows() {
  local rows id when ln pane target desc seen
  if rows=$(atq -q "$SCHED_QUEUE" -o '%Y-%m-%d %H:%M' 2>/dev/null); then
    rows=$(printf '%s\n' "$rows" | sort -k2)
  else
    rows=$(atq -q "$SCHED_QUEUE" 2>/dev/null | while IFS=$'\t' read -r id when; do
      [ -n "$id" ] || continue
      # BSD `date -j -f` parses the ctime string; keep the original on the off
      # chance a future BSD atq changes format, so a row is never dropped.
      when=$(date -j -f '%a %b %d %T %Y' "$when" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$when")
      printf '%s\t%s\n' "$id" "$when"
    done | sort -k2)
  fi
  while IFS=$'\t' read -r id when; do
    [ -n "$id" ] || continue
    when="${when%" $SCHED_QUEUE "*}"     # drop the trailing "<queue> <user>"
    pane="" target="" desc="" seen=0
    while IFS= read -r ln; do
      # at -c replays the whole submitting environment first, and one of those
      # values could contain a line that looks like a header field.  Only trust
      # what follows our own marker, and stop at the first line that is not one.
      if [ "$seen" = 0 ]; then
        case "$ln" in '# imux:v1 '*) seen=1 ;; esac
        continue
      fi
      case "$ln" in
        '# imux-pane: '*)   pane="${ln#\# imux-pane: }" ;;
        '# imux-target: '*) target="${ln#\# imux-target: }" ;;
        '# imux-desc: '*)   desc="${ln#\# imux-desc: }" ;;
        *) break ;;
      esac
    done < <(at -c "$id" 2>/dev/null)
    printf '%s\n' "$id$US$when$US${target:-?}$US${pane:-?}$US${desc:-?}"
  done < <(printf '%s\n' "$rows")
}

if [ "${1:-}" = "--send-at" ] || [ "${1:-}" = "--send-in" ]; then
  set +e
  _mode="$1"; _when="${2:-}"; _target="${3:-}"; shift 3 2>/dev/null || true
  _keys="$*"
  if [ -z "$_when" ] || [ -z "$_target" ] || [ -z "$_keys" ]; then
    echo "interdimux: usage: $_mode <when> <target> <command...>" >&2
    exit 2
  fi
  if ! sched_resolve "$_target"; then
    echo "interdimux: no such target: $_target" >&2
    exit 1
  fi

  # Sub-minute delays: at cannot express them (it truncates the seconds field),
  # but tmux can.  Caveat, verified: a pending run-shell -d does NOT keep the
  # server alive — if the last session closes, the job is lost silently.
  if [ "$_mode" = "--send-in" ] && [[ "$_when" =~ ^[0-9]+$ ]] && [ "$_when" -lt 60 ]; then
    # POSIX quoting: tmux hands this to /bin/sh, which is dash here.  See shq().
    # sh_send_input quotes the keys itself, after protecting a trailing ';', and
    # decides from the text AS TYPED whether it is a key to press (C-#, say).
    shq "$SCHED_SOCK"; _q_sock="$REPLY"
    shq "$SCHED_PANE"; _q_pane="$REPLY"
    sh_send_input "tmux -S $_q_sock" "$_q_pane" "$_keys"
    # run-shell FORMAT-EXPANDS its argument before /bin/sh ever sees it, so a
    # '#H' or '#{...}' in the user's command is substituted by tmux — verified:
    # "echo host-is-#H" arrived as "echo host-is-krootabulon".  Worse, the
    # substituted text is not re-quoted, so a pane title could inject shell.
    # '##' is tmux's escape for a literal '#'; applied to the whole command, so
    # a '#' in the socket path is not expanded either.
    tmux run-shell -b -d "$_when" "${REPLY//\#/##}" \
      2>/dev/null \
      && echo "interdimux: in ${_when}s -> $SCHED_LABEL ($SCHED_PANE)  [tmux timer; lost if the server exits]" \
      || { echo "interdimux: could not schedule" >&2; exit 1; }
    exit 0
  fi

  command -v at >/dev/null 2>&1 || { echo "interdimux: 'at' is not installed" >&2; exit 1; }
  case "$_mode" in
    --send-in) _spec="now + $_when minutes"; [[ "$_when" =~ ^[0-9]+$ ]] && _spec="now + $(( (_when + 59) / 60 )) minutes" ;;
    *)         _spec="$_when" ;;
  esac
  # Submit from / : at bakes the submitting directory into the job and aborts
  # with "Execution directory inaccessible" if it is gone by firing time.
  # $_mflag is "-M" only where at accepts it (GNU); empty on BSD/macOS, so it
  # word-splits away and never reaches at as a bogus argument.
  _mflag=$(at_mail_flag)
  # 2>/dev/null on the WRITER, and it is load-bearing.  at parses its time from
  # argv and exits before ever reading stdin, so a bad spec closes this pipe
  # under the body.  Where SIGPIPE is at its default the writer dies silently;
  # where SIGPIPE is IGNORED (a systemd unit -- IgnoreSIGPIPE defaults to true --
  # or a GitHub Actions step) it does not die, and bash prints "printf: write
  # error: Broken pipe" once per failed write: measured 49,917 lines.  Those go
  # to OUR stderr, not into $_out, and they arrive while the pipeline is still
  # running -- ahead of the `printf '%s\n' "$_out" >&2` below.  The caller picks
  # the first non-"interdimux:" line as the message to show, so without this the
  # schedule dialog reports a truncated path instead of at's "syntax error.
  # Last token seen: ...".  The body is pure printf; it has no other stderr.
  _out=$(cd / && sched_job_body "$SCHED_PANE" "$SCHED_SOCK" "$SCHED_SRVPID" "$SCHED_LABEL" "$_keys" 2>/dev/null \
         | at $_mflag -q "$SCHED_QUEUE" $_spec 2>&1)
  if [ $? -ne 0 ]; then
    printf '%s\n' "$_out" >&2
    echo "interdimux: at rejected the time spec '$_spec'" >&2
    exit 1
  fi
  printf 'interdimux: %s -> %s (%s)\n' \
    "$(printf '%s' "$_out" | sed -n 's/^job \([0-9]*\) at \(.*\)$/job \1 at \2/p' | head -1)" \
    "$SCHED_LABEL" "$SCHED_PANE"
  # The job is QUEUED, not guaranteed to fire: with at's job-runner inactive
  # (atd on Linux; atrun on macOS, which ships disabled) it sits in the queue
  # forever.  Warn, never fail — the success line above stays on stdout so the
  # dashboard and tests still parse it, and a queued job is a real job; refusing
  # a submit on a check we cannot make authoritative on every host would be worse
  # than the heads-up.
  if [ "$(at_daemon_state)" = down ]; then
    echo "interdimux: heads-up — at's job-runner is not active, so this will queue but not fire." >&2
    echo "  enable it: $(at_enable_hint)" >&2
  fi
  exit 0
fi

if [ "${1:-}" = "--sched-list" ]; then
  set +e
  command -v atq >/dev/null 2>&1 || { echo "interdimux: 'at' is not installed" >&2; exit 1; }
  _n=0
  while IFS="$US" read -r _id _when _tgt _pane _desc; do
    [ -n "$_id" ] || continue
    _n=$((_n + 1))
    printf '%-6s %-18s %-22s %-6s %s\n' "$_id" "$_when" "$_tgt" "$_pane" "$_desc"
  done < <(sched_rows)
  [ "$_n" -eq 0 ] && echo "interdimux: no scheduled keys"
  exit 0
fi

if [ "${1:-}" = "--sched-cancel" ]; then
  set +e
  _id="${2:-}"
  [ -n "$_id" ] || { echo "interdimux: usage: --sched-cancel <id>" >&2; exit 2; }
  # Only ever cancel jobs from our own queue, so a mistyped id cannot delete
  # one of the user's unrelated at jobs.
  if ! atq -q "$SCHED_QUEUE" 2>/dev/null | awk '{print $1}' | grep -qx "$_id"; then
    echo "interdimux: no scheduled job $_id (see --sched-list)" >&2
    exit 1
  fi
  atrm "$_id" 2>/dev/null && echo "interdimux: cancelled job $_id"
  exit 0
fi

if [ "${1:-}" = "--create-from-query" ]; then
  set +e
  create_from_query "${2:-}" || {
    imux_msg "could not create a session from '${2:-}'"
    exit 1
  }
  exit 0
fi

if [ "${1:-}" = "--describe-create" ]; then
  set +e
  describe_create "${2:-}"
  printf '%s\n' "$REPLY"
  exit 0
fi

# The navigator's alt-enter (review UX-54), as the fzf action it runs: create
# from the query in FZF_QUERY whatever it matches, or nothing at all when the
# query names no session.  The bind already skips an empty query without a
# process; this is for one that is only fzf syntax or blanks (`'`, `!`, `  `),
# which the bar gives no create entry either, so the key does what the bar
# says: nothing, with the navigator still open.  The action reads the query
# from the environment again when it runs, never from this text, for the
# quoting reason the raw-mode Enter gives.
if [ "${1:-}" = "--create-key" ]; then
  set +e
  resolve_create_target "${FZF_QUERY:-}" name \
    && printf '%s\n' "execute(bash '$SQ_SCRIPT' --create-from-query \"\$FZF_QUERY\")+abort"
  exit 0
fi

if [ "${1:-}" = "--connect-dir" ]; then
  set +e
  cd_dir="${2:-}"
  [ -n "$cd_dir" ] || { echo "interdimux: --connect-dir needs a directory" >&2; exit 1; }
  [ -d "$cd_dir" ] || { echo "interdimux: no such directory: $cd_dir" >&2; exit 1; }
  # Physical path, so it matches the finder output the dir picker produces
  cd_dir=$(cd "$cd_dir" 2>/dev/null && pwd -P) || exit 1
  record_dir_use "$cd_dir"
  connect_dir "$cd_dir" || exit 1
  exit 0
fi

if [ "${1:-}" = "--session-name-for" ]; then
  set +e
  resolve_session_name "$2"
  echo
  exit 0
fi

# ---------------------------------------------------------------------------
# Dialogs (drawn on the popup tty while fzf is suspended by execute)
# ---------------------------------------------------------------------------

DLG_ROWS=24 DLG_COLS=80
DLG_TOP=0 DLG_LEFT=0 DLG_W=0 DLG_H=0

# The user's configured popup border (option defaults if unset)
popup_user_lines() {
  local l
  l=$(tmux show-option -gv popup-border-lines 2>/dev/null) || l=""
  printf '%s' "${l:-single}"
}
popup_user_style() {
  local s
  s=$(tmux show-option -gv popup-border-style 2>/dev/null) || s=""
  printf '%s' "${s:-default}"
}

# The user's border style with the frame colour swapped to the danger
# red (later attributes win in tmux styles, so bg/attrs are preserved).
#
# danger_style [LINES] -- LINES is popup-border-lines, read when not given.
#
# With "padded" the frame is made of SPACES, so a red foreground on it is
# invisible: the only thing left carrying the danger cue was the title text,
# which tmux draws in the border style.  There the danger colour becomes the
# BACKGROUND, and the text takes the frame's own background colour (or the
# terminal's default) -- setting bg alone would leave the title red on red, and
# `reverse` is no help: tmux keeps only the colours of a popup border style and
# zeroes its attributes.  ("none" draws no frame and no title, so no border
# style can show anything there.)
danger_style() {
  # `ulines`, not `lines`: shellcheck tracks a name across the whole file, and
  # the arrays called `lines` further up made this string one a warning.
  local base ulines="${1:-}" tok ink=default
  local -a toks=()
  [ -n "$ulines" ] || ulines=$(popup_user_lines)
  base=$(popup_user_style)
  if [ "$ulines" = padded ]; then
    IFS=', ' read -r -a toks <<< "$base"
    for tok in ${toks[@]+"${toks[@]}"}; do
      case "$tok" in bg=*) ink="${tok#bg=}" ;; esac
    done
    [ -n "$ink" ] || ink=default
    case "$base" in
      default) printf 'bg=%s,fg=%s' "$POPUP_BORDER_DANGER" "$ink" ;;
      *)       printf '%s,bg=%s,fg=%s' "$base" "$POPUP_BORDER_DANGER" "$ink" ;;
    esac
    return 0
  fi
  case "$base" in
    default) printf 'fg=%s' "$POPUP_BORDER_DANGER" ;;
    *)       printf '%s,fg=%s' "$base" "$POPUP_BORDER_DANGER" ;;
  esac
}

# Repaint the live popup frame: "danger" for destructive prompts, "user"
# to restore the configured border.  tmux >= 3.6 modifies the running
# popup; 3.3–3.5 silently ignore the call; older tmux rejects the flags,
# so gate on 3.3.  Lines and title must be re-sent on every repaint: a
# partial display-popup on >= 3.6 replaces omitted properties with
# defaults (-T absent means title "", not "keep") — INTERDIMUX_TITLE is
# forwarded into the popup by --launch.
popup_accent() {
  tmux_ge 303 || return 0
  local style lines
  lines=$(popup_user_lines)
  if [ "$1" = "danger" ]; then style=$(danger_style "$lines"); else style=$(popup_user_style); fi
  local -a t=()
  # -T is a FORMAT, and the title now carries the session name, so any '#' in it
  # would be re-expanded on every repaint.  In practice tmux already expands a
  # name at create/rename time -- "has#hash" is stored as "has<hostname>ash" --
  # so only benign sequences ('#x', '#1') can reach here and nothing observable
  # breaks today.  Doubling is free, and this stops being true the moment tmux
  # gains a format character.  The style prefix is left alone: its '#[' is meant
  # as a format.
  [ -n "${INTERDIMUX_TITLE:-}" ] && t=(-T "${POPUP_TITLE_STYLE}${INTERDIMUX_TITLE//'#'/##}")
  # -c: the popup to repaint is the PRESSING client's.  Without it tmux picks
  # the most recently active client, and on any other client -- one with no
  # popup open -- a display-popup without -E OPENS a shell popup and blocks.
  tmux display-popup ${TMUX_C[@]+"${TMUX_C[@]}"} -b "$lines" -S "$style" ${t[@]+"${t[@]}"} 2>/dev/null || true
}

# Display cells for a string, ignoring SGR escapes.  Sets REPLY.
#
# Bash measures CHARACTERS (${#s}), and the dialogs sized themselves with that:
# a session named with 26 CJK characters produced a title 87 cells wide inside a
# 66-cell box, obliterating the right border (measured with tmux's own
# #{cursor_x}).  The list has had a proper measurement since the Rust core; the
# dialogs had not.
#
# Deliberately CONSERVATIVE rather than exact, because the two errors are not
# symmetric: over-counting makes the box a little wide, under-counting lets text
# run off it.  Per character —
#
#   wide ranges (CJK, Hangul, emoji, fullwidth)   2   exact
#   U+FE0F emoji presentation                     1   exact for base+VS16 = 2
#   combining marks (Latin, symbol, kana), ZWJ,   0
#     U+FE00-FE0E, medial and final Hangul
#     jamo, the Hangul filler U+3164
#   everything else                               1
#
# so ❤️ and 日本 come out exact, while a ZWJ sequence like 👨‍💻 counts 4 instead of
# 2 — wide, never narrow.  A regional indicator is 1: tmux draws one alone in
# one cell and a pair (a flag) in two, so a flag is exact too.  Exact cluster
# handling lives in the Rust core, where it is on the path that needs it, and
# the input field's per-character rules in _dlg_cw.
#
# "Wide" and "0" are what tmux draws (measured on 3.7b, every code point of
# U+1100-11FF, U+2000-30FF, U+FE00-FE0F and U+1F000-1FAFF, against
# #{cursor_x}).  The medial and final jamo -- U+1160-11FF, and the assigned
# parts of U+D7B0-D7FF (the unassigned D7C7-D7CA and D7FC-D7FF draw one) --
# are 0 on any cell: tmux joins them to the cell before, the way it joins a
# mark, and one it cannot join is dropped.  That is how macOS stores a Korean
# name (NFD, 한 as U+1112 U+1161 U+11AB), one wide cell a syllable; counted one
# each, the field's cursor drifted two cells right per syllable.  Below
# U+2E80 that is a scattering of emoji -- ✅ ❌ ⭐ ⚡ ☕ ⌛ ⏰ and ~60 more -- which
# counted 1 for the 2 tmux draws, so three of them typed into Send keys left
# the cursor three cells short, and a long command with a few in it ran
# through the border.  U+1F000-1FAFF stays wide throughout, bar the regional
# indicators: its text-style symbols (🖥 🛠) are drawn narrow, but they come
# with a U+FE0F nearly always, and a range with holes would under-count every
# emoji a newer Unicode adds.
#
# `printf %d "'<char>"` yields the codepoint with no fork; the dialogs are short
# strings on the action path, so per-character work is affordable here.
dlg_width() {
  # `len` is assigned separately for the same reason dlg_fit does it: bash
  # expands every word of a `local` command before performing any of its
  # assignments, so ${#s} on this line would read the OUTER s.
  local s="$1" i=0 n=0 ch cp j len
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    ch="${s:i:1}"
    if [ "$ch" = $'\033' ]; then
      j=$(( i + 1 ))
      while [ "$j" -lt "$len" ] && [[ "${s:j:1}" != [a-zA-Z] ]]; do j=$(( j + 1 )); done
      i=$(( j + 1 ))
      continue
    fi
    printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
    if (( cp < 0x300 )); then
      n=$(( n + 1 ))
    elif (( (cp >= 0x300 && cp <= 0x36f) || cp == 0x200d || (cp >= 0xfe00 && cp <= 0xfe0e) \
         || (cp >= 0x20d0 && cp <= 0x20f0) || (cp >= 0x302a && cp <= 0x302d) \
         || cp == 0x3099 || cp == 0x309a || (cp >= 0x1160 && cp <= 0x11ff) \
         || (cp >= 0xd7b0 && cp <= 0xd7c6) || (cp >= 0xd7cb && cp <= 0xd7fb) || cp == 0x3164 )); then
      :
    elif (( (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) \
         || (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) \
         || (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) \
         || (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff) \
         || (cp >= 0x1f000 && cp <= 0x1f1e5) || (cp >= 0x1f200 && cp <= 0x1f2ff) \
         || (cp >= 0x20000 && cp <= 0x3fffd) )); then
      n=$(( n + 2 ))
    elif (( cp >= 0x231a && cp <= 0x2b55 && ( cp <= 0x231b || cp == 0x2329 || cp == 0x232a \
         || (cp >= 0x23e9 && cp <= 0x23ec) || cp == 0x23f0 || cp == 0x23f3 || cp == 0x25fd \
         || cp == 0x25fe || cp == 0x2614 || cp == 0x2615 || cp == 0x261d \
         || (cp >= 0x2648 && cp <= 0x2653) || cp == 0x267f || cp == 0x2693 || cp == 0x26a1 \
         || cp == 0x26aa || cp == 0x26ab || cp == 0x26bd || cp == 0x26be || cp == 0x26c4 \
         || cp == 0x26c5 || cp == 0x26ce || cp == 0x26d4 || cp == 0x26ea || cp == 0x26f2 \
         || cp == 0x26f3 || cp == 0x26f5 || cp == 0x26f9 || cp == 0x26fa || cp == 0x26fd \
         || cp == 0x2705 || (cp >= 0x270a && cp <= 0x270d) || cp == 0x2728 || cp == 0x274c \
         || cp == 0x274e || (cp >= 0x2753 && cp <= 0x2755) || cp == 0x2757 \
         || (cp >= 0x2795 && cp <= 0x2797) || cp == 0x27b0 || cp == 0x27bf || cp == 0x2b1b \
         || cp == 0x2b1c || cp == 0x2b50 || cp == 0x2b55 ) )); then
      n=$(( n + 2 ))
    else
      n=$(( n + 1 ))
    fi
    i=$(( i + 1 ))
  done
  REPLY="$n"
}

# Truncate a PRE-COLOURED string to a visible column budget, keeping its escape
# sequences intact.  ${#s} counts the escapes, so measuring with it lets a
# coloured string overrun the frame while a plain one of the same visible length
# fits.  Observed: the rename dialog's "✗ a name cannot contain ':' (tmux splits
# targets there)" ran straight through the right border and off the box.
#
# Sets REPLY.  Character-at-a-time is fine here: these are single dialog lines,
# not the list.
dlg_fit() {
  local s="$1" max="$2" out="" n=0 i=0 ch j len w
  # NOT `local s="$1" … len=${#s}`: bash expands every word of a `local` command
  # before performing any of its assignments, so ${#s} reads the OUTER s — unset
  # here, which under `set -u` killed the dialog outright.
  len=${#s}
  [ "$max" -lt 2 ] && max=2

  # Nothing to do is the common case, and it has to be checked FIRST: the loop
  # below reserves a column for the ellipsis, so without this a string exactly
  # `max` cells wide lost its last character to a "…" that bought nothing.
  dlg_width "$s"
  if [ "$REPLY" -le "$max" ]; then REPLY="$s"; return 0; fi

  while [ "$i" -lt "$len" ]; do
    ch="${s:i:1}"
    if [ "$ch" = $'\033' ]; then
      # copy the whole CSI/OSC-style sequence: it costs no columns
      j=$(( i + 1 ))
      while [ "$j" -lt "$len" ] && [[ "${s:j:1}" != [a-zA-Z] ]]; do j=$(( j + 1 )); done
      out+="${s:i:j-i+1}"
      i=$(( j + 1 ))
      continue
    fi
    dlg_width "$ch"; w="$REPLY"
    if [ $(( n + w )) -gt $(( max - 1 )) ]; then out+="…"; break; fi
    out+="$ch"; n=$(( n + w )); i=$(( i + 1 ))
  done
  REPLY="${out}${RST}"
}

# dialog_open ACCENT TITLE [BODY...] — clear the screen and draw a
# centered rounded box.  Body rows are pre-colored strings whose plain
# length must fit; the row below the body is reserved for hint/status.
dialog_open() {
  local accent="$1" title="$2"
  shift 2
  local dims line w
  DLG_ROWS=24 DLG_COLS=80
  if [ -c "$tty_in" ] && dims=$({ stty size <"$tty_in"; } 2>/dev/null); then
    DLG_ROWS="${dims%% *}" DLG_COLS="${dims#* }"
  fi
  # CELLS, not characters: ${#title} counted a CJK name at half its drawn width,
  # so the box was sized for 66 cells and the title drew 87.
  dlg_width "$title"; w=$(( REPLY + 10 ))
  for line in "$@"; do
    dlg_width "$line"
    [ $(( REPLY + 8 )) -gt "$w" ] && w=$(( REPLY + 8 ))
  done
  [ "$w" -lt 44 ] && w=44
  [ "$w" -gt $(( DLG_COLS - 2 )) ] && w=$(( DLG_COLS - 2 ))
  DLG_W="$w"
  DLG_H=$(( $# + 5 ))   # top border, blank, body…, blank, hint, bottom border

  # A box taller than the popup does not just look wrong: DLG_TOP clamps to 1,
  # the bottom border is then drawn past the last row, the terminal scrolls, and
  # the scroll takes the top border and title with it -- leaving a half-drawn
  # frame over the list.  Drop body rows instead; the hint row is what carries
  # the error text and it is the one that must survive.
  local -a body=("$@")
  if [ "$DLG_H" -gt $(( DLG_ROWS - 1 )) ]; then
    local keep=$(( DLG_ROWS - 6 ))
    [ "$keep" -lt 0 ] && keep=0
    body=("${body[@]:0:keep}")
    DLG_H=$(( ${#body[@]} + 5 ))
    [ "$DLG_H" -gt "$DLG_ROWS" ] && DLG_H="$DLG_ROWS"
  fi
  set -- ${body[@]+"${body[@]}"}

  DLG_TOP=$(( (DLG_ROWS - DLG_H) / 2 ))
  [ "$DLG_TOP" -lt 1 ] && DLG_TOP=1
  DLG_LEFT=$(( (DLG_COLS - DLG_W) / 2 ))
  [ "$DLG_LEFT" -lt 1 ] && DLG_LEFT=1
  # ...and truncate the title in cells too, keeping any escapes it carries
  dlg_width "$title"
  if [ "$REPLY" -gt $(( DLG_W - 6 )) ]; then
    dlg_fit "$title" $(( DLG_W - 6 )); title="$REPLY"
  fi

  local hbar sp i r
  printf -v hbar '%*s' $(( DLG_W - 2 )) ''
  hbar="${hbar// /─}"
  printf -v sp '%*s' $(( DLG_W - 2 )) ''

  {
    printf '\033[2J\033[H\033[?25l'
    printf '\033[%d;%dH%s╭%s╮%s' "$DLG_TOP" "$DLG_LEFT" "$accent" "$hbar" "$RST"
    for (( i = 1; i < DLG_H - 1; i++ )); do
      printf '\033[%d;%dH%s│%s%s%s│%s' \
        $(( DLG_TOP + i )) "$DLG_LEFT" "$accent" "$RST" "$sp" "$accent" "$RST"
    done
    printf '\033[%d;%dH%s╰%s╯%s' $(( DLG_TOP + DLG_H - 1 )) "$DLG_LEFT" "$accent" "$hbar" "$RST"
    printf '\033[%d;%dH%s %s %s' "$DLG_TOP" $(( DLG_LEFT + 2 )) "${accent}${BOLD}" "$title" "$RST"
    r=$(( DLG_TOP + 2 ))
    for line in "$@"; do
      dlg_fit "$line" $(( DLG_W - 8 ))
      printf '\033[%d;%dH%s' "$r" $(( DLG_LEFT + 4 )) "$REPLY"
      r=$(( r + 1 ))
    done
  } >>"$tty_out"
}

# Write a hint/status line on the reserved row inside the box
dialog_status() {
  local text="$1" sp
  local r=$(( DLG_TOP + DLG_H - 2 ))
  printf -v sp '%*s' $(( DLG_W - 8 )) ''
  dlg_fit "$text" $(( DLG_W - 8 ))
  printf '\033[%d;%dH%s\033[%d;%dH%s' \
    "$r" $(( DLG_LEFT + 4 )) "$sp" \
    "$r" $(( DLG_LEFT + 4 )) "$REPLY" >>"$tty_out"
}

dialog_close() {
  # >> not >, for the same reason _action_cleanup uses it: INTERDIMUX_TTY_OUT can
  # be a regular file (that is how the dialogs are tested) and > TRUNCATES it, so
  # closing a dialog silently erased every frame the flow had drawn.  Identical
  # on a real tty.
  printf '\033[?25h' >>"$tty_out"
}

# ONE input fd for the whole process, opened on first use.
#
# `read < "$tty_in"` per call is correct for a tty — each open continues the
# terminal's key queue — but it REWINDS a regular file to offset 0, so a flow
# with two prompts read its first answer forever.  input_dialog already knew
# this and held one fd for the duration of a single call; a flow like Schedule
# asks twice, so the fd has to outlive the call.  Left open until exit.
#
# Sets REPLY to the fd number.  Returns non-zero if the source cannot be opened,
# which the callers treat as "no input" rather than blocking.
_tty_fd=""
tty_fd() {
  if [ -z "$_tty_fd" ]; then
    exec {_tty_fd}<"$tty_in" 2>/dev/null || { _tty_fd=""; return 1; }
  fi
  REPLY="$_tty_fd"
}

# Drain pending input (only on a real tty — a test fixture file would
# be consumed by the read loop)
drain_input() {
  [ -c "$tty_in" ] || return 0
  tty_fd || return 0
  local fd="$REPLY"
  while IFS= read -rsn1 -t 0.01 -u "$fd" _; do :; done
}

# confirm_dialog ACCENT TITLE [BODY...] → 0 when confirmed with y/Y
confirm_dialog() {
  local accent="$1" title="$2"
  shift 2
  dialog_open "$accent" "$title" "$@"
  dialog_status "$(hint y confirm n/esc cancel)"
  drain_input
  local key="" fd
  tty_fd || return 1        # nothing to read from → treat as "not confirmed"
  fd="$REPLY"
  # -u BEFORE the variable name: bash stops parsing options at the first
  # non-option word, so `read -rsn1 key -u "$fd"` reads STDIN and treats -u and
  # the fd number as two more variable names.  It fails silently — the key comes
  # back empty, which here reads as "the user did not confirm".
  IFS= read -rsn1 -u "$fd" key 2>/dev/null
  if [ "$key" = $'\x1b' ]; then
    drain_input   # swallow escape-sequence tails (arrow keys, etc.)
    return 1
  fi
  [[ "$key" =~ ^[yY]$ ]]
}

# Cells covered by a WIDTH STRING — one digit per character, each 0, 1 or 2
# (input_dialog keeps one alongside its buffer).  Two substitutions instead of a
# loop, because this runs on every keystroke: cells = characters - zeros + twos.
# Sets REPLY.
_dlg_cells() {
  local zeros="${1//[12]/}" twos="${1//[01]/}"
  REPLY=$(( ${#1} - ${#zeros} + ${#twos} ))
}

# The width input_dialog's field keeps for CH, with PREV and NEXT the characters
# either side of it ('' at an end of the buffer).  Sets REPLY.
#
# The field puts the cursor after any character, so where dlg_width may err
# wide this has to be exact for the sequences people type.  tmux draws some
# characters INTO the cell before them rather than into one of their own
# (screen_write_combine and utf8_should_combine, tmux 3.7b; each rule below
# measured there against #{cursor_x}):
#
#   U+FE0F after a one-cell character   widens that cell to two     ⚙ 1, ⚙️ 2
#   a non-ASCII character after a ZWJ   joins the ZWJ's cell        👨‍👩‍👧 2
#   a skin tone after a modifier base   joins the base's cell       👍🏽 2
#     -- tmux's own list of bases (_dlg_tone_base); 🎅🏽 and ✋🏽 stay 4
#
# Such a character is 0 here, and the cell U+FE0F adds goes on the character it
# widens, so a 0 always means "drawn into the cell before": the view must never
# start on one, where it would join the prompt's cell.  Measured one character
# at a time, 👍🏽 came to 4, 👨‍👩‍👧 to 6, and ⚙️ to 1+1, so a view could open on
# its U+FE0F.  (A regional indicator is 1 either way -- see dlg_width, which
# also has the medial and final Hangul jamo at 0.)
#
# One rule of that tmux function is left out on purpose: it also joins a
# modifier BASE to a skin tone standing alone before it -- 🏽👍 is two cells,
# counted four here.  Whether a tone stands alone depends on every character
# before it (🏽👍🏽👍 is 2+2 in tmux, 🏽👍🏽 is 2+2 too), so no fixed-size
# re-measure keeps it right, and leaving it out only ever errs WIDE: at every
# point of such a run the count here is at least tmux's, so the cursor may sit
# right of the text but the text never reaches the border.
_DLG_VS16=$'\xef\xb8\x8f'                 # U+FE0F, as bytes: no locale needed
_dlg_cw() {
  local cp pp
  printf -v cp '%d' "'$2" 2>/dev/null || cp=63
  if (( cp >= 0x20 && cp < 0x7f )); then
    REPLY=1                          # tmux never draws ASCII into another cell
  elif (( cp == 0xfe0f )); then
    REPLY=0; return 0
  else
    if [ -n "$1" ]; then
      printf -v pp '%d' "'$1" 2>/dev/null || pp=0
      if (( pp == 0x200d )) || { (( cp >= 0x1f3fb && cp <= 0x1f3ff )) && _dlg_tone_base "$pp"; }; then
        REPLY=0; return 0
      fi
    fi
    dlg_width "$2"
  fi
  if (( REPLY == 1 )) && [ "$3" = "$_DLG_VS16" ]; then REPLY=2; fi
  return 0
}

# True for a code point a skin tone joins: tmux's list (utf8_should_combine in
# utf8-combined.c), which is not all of Unicode's Emoji_Modifier_Base.
_dlg_tone_base() {
  local c=$1
  (( (c >= 0x1f44b && c <= 0x1f450) || (c >= 0x1f466 && c <= 0x1f469) || c == 0x1f46e \
     || (c >= 0x1f470 && c <= 0x1f478) || c == 0x1f47c || (c >= 0x1f481 && c <= 0x1f483) \
     || (c >= 0x1f485 && c <= 0x1f487) || c == 0x1f4aa || c == 0x1f575 || c == 0x1f57a \
     || c == 0x1f590 || c == 0x1f595 || c == 0x1f596 || (c >= 0x1f645 && c <= 0x1f647) \
     || (c >= 0x1f64b && c <= 0x1f64f) || (c >= 0x1f6b4 && c <= 0x1f6b6) || c == 0x1f926 \
     || (c >= 0x1f937 && c <= 0x1f939) || c == 0x1f93d || c == 0x1f93e || c == 0x1f9b5 \
     || c == 0x1f9b6 || c == 0x1f9b8 || c == 0x1f9b9 || (c >= 0x1f9cd && c <= 0x1f9cf) \
     || (c >= 0x1f9d1 && c <= 0x1f9df) ))
}

# Measure character J of input_dialog's buffer again, from its neighbours as
# they are now, into cw.  buf and cw are input_dialog's locals.  An edit changes
# the neighbours on both sides of where it happened, so every edit re-measures
# those two characters: deleting 👍 from 👍🏽 leaves a skin tone that stands
# alone, two cells wide, and deleting the U+FE0F of ⚙️ takes ⚙ back to one.
_dlg_remeasure() {
  local j=$1
  (( j >= 0 && j < ${#buf} )) || return 0
  if (( j > 0 )); then
    _dlg_cw "${buf:j-1:1}" "${buf:j:1}" "${buf:j+1:1}"
  else
    _dlg_cw "" "${buf:0:1}" "${buf:1:1}"
  fi
  cw="${cw:0:j}$REPLY${cw:j+1}"
}

# input_dialog ACCENT TITLE PROMPT INITIAL [NOTE] — a single-line text editor
# drawn inside the dialog box.  Sets REPLY (empty = cancelled).
#
# NOTE, when given, is drawn as a second body row under the field.  It goes
# there rather than in the status line because dialog_open sizes the box to fit
# its body rows, so a format hint widens the frame — while dialog_status is
# clamped to whatever width the box already has and would ellipsise it.
#
# Hand-rolled instead of `read -e`: readline owns the whole physical terminal
# line (column 0 → terminal width) and knows nothing about the box, so it
# erased the right border on backspace and snapped the cursor to column 0 once
# the field emptied.  This editor only ever repaints the field region between
# the prompt and the right border, so the frame can't be corrupted, and it
# scrolls horizontally rather than wrapping through the border on long input.
#
# The field is laid out in CELLS, not characters.  field_w always was a cell
# count, but the slice, the padding, the scroll and the cursor came from ${#buf}
# and ${buf:scroll:field_w}, so every CJK or emoji character drew two cells for
# the one it was counted as.  Three were enough to push the padding through the
# right border; a long CJK session name in Rename wrapped onto the row below;
# and the cursor sat in the middle of the text from the first wide character
# on.  The buffer, and so the value applied on Enter, was always right — only
# the picture was wrong.  dialog_open had the same bug in the title.
# Runs under the --action handler's `set +e`, so bare (( … )) tests are safe.
input_dialog() {
  local accent="$1" title="$2" prompt="$3" initial="$4"
  local note="${5:-}"
  if [ -n "$note" ]; then
    dialog_open "$accent" "$title" "" "$note"
  else
    dialog_open "$accent" "$title" ""
  fi
  dialog_status "${DIM}enter apply · esc cancel${RST}"

  local irow=$(( DLG_TOP + 2 ))
  local col_prompt=$(( DLG_LEFT + 4 ))
  dlg_width "$prompt"
  local field_start=$(( col_prompt + REPLY ))
  local field_end=$(( DLG_LEFT + DLG_W - 3 ))   # one-column gutter before the border
  local field_w=$(( field_end - field_start + 1 ))
  [ "$field_w" -lt 1 ] && field_w=1

  # The prompt is static — draw it once; the loop only repaints the field.
  printf '\033[%d;%dH%s%s%s\033[?25h' \
    "$irow" "$col_prompt" "$accent" "$prompt" "$RST" >>"$tty_out"

  # cw is buf's shadow: ONE DIGIT PER CHARACTER, that character's width in
  # cells (0, 1 or 2, from _dlg_cw).  Every edit below applies the same slice
  # to both strings, so ${cw:i:1} is always the width of ${buf:i:1}.  Each
  # character is measured as it enters the buffer, and again only when an
  # edit changes a neighbour (_dlg_remeasure): re-measuring the whole buffer on
  # every repaint made a paste quadratic, because every pasted character is
  # its own keystroke and repaint, and dlg_width costs tens of microseconds a
  # character.
  local buf="$initial" pos=${#initial} scroll=0 cw="" i pc="" cc nc
  cc="${buf:0:1}"
  for (( i = 0; i < pos; i++ )); do
    nc="${buf:i+1:1}"
    _dlg_cw "$pc" "$cc" "$nc"; cw+="$REPLY"
    pc="$cc" cc="$nc"
  done
  drain_input

  # Read the input source through the process-wide fd (see tty_fd): re-opening
  # `<"$tty_in"` rewinds a regular file to offset 0, which is an infinite loop
  # within one call and a repeated first answer across two.
  local ifd
  if tty_fd; then ifd="$REPLY"; else REPLY=""; return 0; fi
  # On a real terminal, edit in raw/no-echo mode for the duration so fast keys
  # arriving between reads aren't echoed over the box, and Ctrl-C cancels
  # cleanly (delivered as a byte, not SIGINT).  Skipped for non-ttys.
  local saved_stty=""
  if [ -c "$tty_in" ]; then
    saved_stty=$(stty -g <"$tty_in" 2>/dev/null) || saved_stty=""
    # published so the --action INT/EXIT trap can restore the terminal even if
    # we are killed between here and the restore below
    _saved_stty_global="$saved_stty"
    [ -n "$saved_stty" ] && stty -echo -icanon -isig min 1 time 0 <"$tty_in" 2>/dev/null
  fi

  # Published so a caller that LOOPS on this dialog can tell "the user pressed
  # Enter" from "the input source is exhausted".  Without it, the Schedule
  # retry loop re-submitted the same rejected time forever on a closed stdin —
  # EOF is accepted below as "take what we have", which is right for one prompt
  # and non-terminating for a loop.
  _input_eof=0
  local c c2 c3 vis len off cur k w blank
  printf -v blank '%*s' "$field_w" ''
  while true; do
    len=${#buf}
    if (( pos <= scroll )); then
      # The cursor moved left of the view: start the view at the cursor -- or,
      # when that character is drawn into the cell before it (width 0: a
      # combining mark, say), at the character that cell belongs to.  Started
      # on the mark, the view drew it onto the prompt's blank, so every step
      # Left through decomposed text stacked one more accent there.  The
      # cursor AT the view's start needs it too: Delete of the view's first
      # character, or Backspace between it and its mark, leaves the view on
      # that mark with the cursor unmoved.
      scroll=$pos
      while (( scroll > 0 )) && [ "${cw:scroll:1}" = 0 ]; do scroll=$(( scroll - 1 )); done
    fi
    # The cursor needs the cells of the character under it — or the one blank
    # cell after the text — inside the field too.
    cur=1
    if (( pos < len )); then cur=${cw:pos:1}; (( cur < 1 )) && cur=1; fi
    _dlg_cells "${cw:scroll:pos-scroll}"; off=$REPLY
    if (( off + cur > field_w )); then
      # The cursor ran off the right edge: start at the leftmost character from
      # which it fits.  Stepping the start forward from where it was finds
      # exactly that one -- the cells from the start to the cursor only shrink
      # as the start moves right, and every start left of the old one failed
      # already -- and typing at the end, it is one step or two.  A paste is
      # one keystroke per character, and the walk back across the whole field
      # this used to do on each made a paste 3-6x slower.  A big jump (End on
      # a long line) walks back from the cursor instead: one field's width,
      # not the length of the jump.
      if (( off + cur - field_w < field_w )); then
        while (( off + cur > field_w && scroll < pos )); do
          off=$(( off - ${cw:scroll:1} )) scroll=$(( scroll + 1 ))
        done
      else
        scroll=$pos off=0
        while (( scroll > 0 )); do
          w=${cw:scroll-1:1}
          (( off + w + cur > field_w )) && break
          scroll=$(( scroll - 1 )) off=$(( off + w ))
        done
      fi
    fi
    # Nor can a character drawn into the cell before it open the field on the
    # right: drawn first, it would join the prompt's cell, outside the field.
    while (( scroll < pos )) && [ "${cw:scroll:1}" = 0 ]; do scroll=$(( scroll + 1 )); done
    # The visible text is the longest run from `scroll` that fits.  A wide
    # character that would straddle the edge is left out rather than drawn over
    # the gutter; the cell it would have started in stays blank.  At the end of
    # the text, the run is the one `off` already measured.
    if (( pos == len )); then REPLY=$off; else _dlg_cells "${cw:scroll}"; fi
    if (( REPLY <= field_w )); then
      vis="${buf:scroll}"
    else
      k=$scroll i=0
      while (( k < len )); do
        w=${cw:k:1}
        (( i + w > field_w )) && break
        i=$(( i + w )) k=$(( k + 1 ))
      done
      vis="${buf:scroll:k-scroll}"
    fi
    # At the buffer's start there is no base to walk back to: a mark or a
    # U+FE0F that an edit left first (Home, Delete on a decomposed É, or on
    # ⚙️) would join the prompt's blank -- a U+FE0F widening it to two cells
    # and pushing the whole field right.  Such characters are left out of the
    # picture; they have no cells, so `off` stands.
    if (( scroll == 0 )) && [ "${cw:0:1}" = 0 ]; then
      k=0
      while (( k < ${#vis} )) && [ "${cw:k:1}" = 0 ]; do k=$(( k + 1 )); done
      vis="${vis:k}"
    fi
    # Blank the field, draw the text, place the cursor.  Blanking first instead
    # of padding after means a glyph dlg_width over-counts (a ZWJ sequence)
    # cannot leave stale cells at the end of the field.  The prompt is drawn
    # again AFTER the text: a character tmux draws into the cell before it that
    # the widths above do not know about (a Thai, Hebrew, Arabic or Devanagari
    # mark, which dlg_width counts as a cell) can still open the view, and
    # joins the prompt's blank -- rewritten, that cell drops it in the same
    # frame instead of stacking one more on each.  Nothing else is written
    # outside [field_start, field_end], so the borders are never touched.
    printf '\033[%d;%dH%s\033[%d;%dH%s\033[%d;%dH%s%s%s\033[%d;%dH' \
      "$irow" "$field_start" "$blank" \
      "$irow" "$field_start" "$vis" \
      "$irow" "$col_prompt" "$accent" "$prompt" "$RST" \
      "$irow" $(( field_start + off )) >>"$tty_out"

    IFS= read -rsN1 -u "$ifd" c || { _input_eof=1; c=$'\n'; }   # EOF → accept what we have
    case "$c" in
      $'\n'|$'\r') break ;;                                  # accept
      $'\x1b')                                               # ESC: a sequence, or lone → cancel
        if IFS= read -rsN1 -t 0.05 -u "$ifd" c2 && [[ "$c2" == '[' || "$c2" == 'O' ]]; then
          IFS= read -rsN1 -t 0.05 -u "$ifd" c3
          case "$c3" in
            D) (( pos > 0 ))   && pos=$(( pos - 1 )) ;;      # left
            C) (( pos < len )) && pos=$(( pos + 1 )) ;;      # right
            H) pos=0 ;;
            F) pos=$len ;;
            [0-9])
              IFS= read -rsN1 -t 0.05 -u "$ifd" _           # swallow the trailing '~'
              case "$c3" in
                1|7) pos=0 ;;
                4|8) pos=$len ;;
                3) (( pos < len )) && {                     # delete
                     buf="${buf:0:pos}${buf:pos+1}" cw="${cw:0:pos}${cw:pos+1}"
                     _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"; } ;;
              esac ;;
          esac
        else
          buf=""; break                                      # lone ESC → cancel
        fi ;;
      $'\x7f'|$'\x08') (( pos > 0 )) && {
                         buf="${buf:0:pos-1}${buf:pos}" cw="${cw:0:pos-1}${cw:pos}"; pos=$(( pos - 1 ))
                         _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"; } ;;
      $'\x03') buf=""; break ;;                              # Ctrl-C → cancel
      $'\x01') pos=0 ;;                                       # Ctrl-A → start
      $'\x05') pos=$len ;;                                    # Ctrl-E → end
      $'\x15') buf="${buf:pos}" cw="${cw:pos}"; pos=0; _dlg_remeasure 0 ;;        # Ctrl-U → delete to start
      $'\x0b') buf="${buf:0:pos}" cw="${cw:0:pos}"; _dlg_remeasure $(( pos - 1 )) ;; # Ctrl-K → delete to end
      $'\x17')                                                # Ctrl-W → delete word before cursor
        local l="${buf:0:pos}" r="${buf:pos}"
        while [ -n "$l" ] && [ "${l: -1}" = ' ' ]; do l="${l%?}"; done
        while [ -n "$l" ] && [ "${l: -1}" != ' ' ]; do l="${l%?}"; done
        buf="$l$r" cw="${cw:0:${#l}}${cw:pos}"; pos=${#l}
        _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos" ;;
      *)
        if [[ -n "$c" && "$c" != [[:cntrl:]] ]]; then
          printf -v k '%d' "'$c" 2>/dev/null || k=0
          if (( pos == len && k >= 0x20 && k < 0x7f )); then
            # ASCII at the end -- typing, and every character of a paste:
            # nothing either side changes width, so append, and slice nothing
            buf+="$c" cw+="1"   # cw is a string of per-character widths
          else
            buf="${buf:0:pos}$c${buf:pos}" cw="${cw:0:pos}0${cw:pos}"
            _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"; _dlg_remeasure $(( pos + 1 ))
          fi
          pos=$(( pos + 1 ))
        fi ;;
    esac
  done

  [ -n "$saved_stty" ] && stty "$saved_stty" <"$tty_in" 2>/dev/null
  _saved_stty_global=""
  # NOT closed: the fd is shared with every other dialog in this process.
  REPLY="$buf"
}

# Brief informational dialog
# info_flash ACCENT TITLE [BODY...] — every body line is forwarded, because
# dialog_open already lays out as many as it is given and `"${3:-}"` silently
# dropped the rest.
info_flash() {
  local _if_accent="$1" _if_title="$2"
  shift 2
  dialog_open "$_if_accent" "$_if_title" ${@+"$@"}
  sleep 0.9
  dialog_close
}

# ---------------------------------------------------------------------------
# Dynamic hint bar (called by fzf focus:transform-footer)
# ---------------------------------------------------------------------------
#
# The fallback path only: the navigator normally answers this with an inline
# POSIX snippet over pre-packed env vars, because a focus bind fires on every
# cursor move and re-exec'ing this script there cost ~17 ms a move.  This
# handler is what runs on fzf too old for --with-shell, or when the user
# supplied their own --with-shell in @interdimux-fzf-opts.
#
# It is the more CORRECT of the two by construction — being a real child it sees
# the live FZF_COLUMNS and FZF_PREVIEW_COLUMNS, so it re-tiers on anything.  The
# inline snippet reads the same two variables to stay level with it.

if [ "${1:-}" = "--footer-for" ]; then
  # Zero matches: Enter creates a session, so the bar announces that instead of
  # a row's hints -- exactly what the navigator's inline dispatcher prints there
  # (it runs --describe-create), so the two paths cannot disagree.  fzf exports
  # the count and the query from 0.46; below that this cannot know, and the bar
  # stays the generic one.
  if [ "${FZF_MATCH_COUNT:-}" = 0 ]; then
    set +e
    describe_create "${FZF_QUERY:-}"
    printf '%s\n' "$REPLY"
    exit 0
  fi
  spec="${2:-}"
  spec="${spec%%	*}"
  hint_set "${spec%%:*}"
  # A typed query with rows matching: alt-enter would create from it, and the
  # bar says what, after the row's own hints (review UX-54).  Those get the
  # width that is left, dropping entries by their usual priority; the create
  # entry goes only when it does not fit on its own.  From fzf 0.63, where the
  # navigator runs this in the background on every keystroke (see _hint_bind);
  # below that nothing asks on each keystroke, so the name would go stale.
  if [ -n "${FZF_QUERY:-}" ] && fzf_ge 63; then
    set +e
    create_key_hint_r "$FZF_QUERY"
    _ck="$REPLY" _ckw="$REPLY_W"
    hint_cols; _w="$REPLY"
    if [ -n "$_ck" ] && [ "$_ckw" -le "$_w" ]; then
      hint_tiers ${HINT_SET[@]+"${HINT_SET[@]}"}
      hint_pick $(( _w - _ckw - 2 )) "$REPLY"
      if [ -n "$REPLY" ]; then REPLY+="  $_ck"; else REPLY="$_ck"; fi
      printf '%s\n' "$REPLY"
      exit 0
    fi
  fi
  hint_bar_r ${HINT_SET[@]+"${HINT_SET[@]}"}
  # Nothing, not a bare newline: an EMPTY transform removes the footer section
  # and the list reflows into the row, where "\n" leaves a blank bar drawn.
  [ -n "$REPLY" ] && printf '%s\n' "$REPLY"
  exit 0
fi

# The packed width ladder for one row type ("W:line|W:line|…|0:") — what the
# navigator exports for its inline snippet.  This exists so the tests can drive
# that snippet with exactly the environment the navigator would hand it, rather
# than a hand-copied duplicate; a duplicate is precisely what stopped matching
# the last time this pair drifted.
if [ "${1:-}" = "--hint-ladder" ]; then
  hint_set "${2:-}"
  hint_tiers ${HINT_SET[@]+"${HINT_SET[@]}"}
  printf '%s' "$REPLY"
  exit 0
fi

# ---------------------------------------------------------------------------
# Match-scope prompt (called by fzf change-nth:transform-prompt, >= 0.58)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--scope-prompt" ]; then
  # Every state the ctrl-] cycle can reach must have a label.  The fifth,
  # "1,3" (identity + command, skipping the path), had none and fell through to
  # a bare "❯ " -- indistinguishable from the unset state, so the one scope that
  # is not self-evident was also the one the prompt would not name.
  case "${FZF_NTH:-}" in
    1)     echo 'name ❯ ' ;;
    2)     echo 'path ❯ ' ;;
    3)     echo 'cmd ❯ ' ;;
    1,2,3) echo 'all ❯ ' ;;
    1,3)   echo 'name+cmd ❯ ' ;;
    *)     echo '❯ ' ;;
  esac
  exit 0
fi

# The agent layer sits here -- below every callback fzf runs while you type or
# move (--preview, --describe-create, --session-name-for, and --footer-for,
# --hint-ladder and --scope-prompt just above), and above the first mode that
# draws rows (--action's swap picker, --list) -- because bash parses a script
# as it runs it.  A callback that exits before this line never parses the ~850
# lines below, which cost every one of them ~2 ms (review R15).  So no mode
# dispatched above this line may run anything that uses it (gather_targets is
# defined above but only ever run below), and a new callback belongs above it.
# The agent NAMES (the tables, agent_of, VIEW) are further up: the preview and
# the create resolver use them.  tests/test_render_cost.sh checks the
# callbacks with bash's own trace (the witness: DEFAULT_TITLE_RULES below).

# Rules: how what an app or a plugin tells tmux becomes a state word and a
# description on the row.  One rule per line, two kinds:
#
#   APPS     STATE  DESC  PATTERN     a pane TITLE rule
#   @OPTIONS STATE  DESC  PATTERN     a pane OPTION rule
#
# APPS     comma-separated command names the rule is for (the agent's name for
#          an agent row, argv0's basename otherwise), or * for any.  An empty
#          name in the list names nothing.
# @OPTIONS comma-separated tmux user options (with their @), read for every
#          pane in the one batched query.  Other agent plugins publish state
#          this way (tmux-agent-sidebar's @pane_status, tmux-agent-icons'
#          @claude_state, ...), and so can your own hooks: `tmux set -p -t
#          "$TMUX_PANE" @agent_state approve` needs no rule at all.
# STATE    the state word it asserts (approve input working idle done error),
#          or - for none.  Any other word is taken for - (tr_parse).
# DESC     - for none, = for the whole title (or value), anything else a
#          template in which $1..$9 are PATTERN's captures.
# PATTERN  the rest of the line: literal text, anchored at both ends, in which
#          each * captures (greedily, left to right).  A leading %spin matches
#          one braille spinner glyph (U+2800-28FF).
#
# A title rule is picked by the app, so a glyph means what THAT app means by
# it (✳ is Claude's constant mark but Qwen's "approve?").  The first title
# rule that matches decides; among option rules the first to give a state
# gives it, and the first to give a description gives that.  The state comes
# from Claude's own registry first, then the options, then the title.
#
# Lines of @interdimux-title-rules (a file, default
# ~/.config/interdimux/titles) come before these, so they override them.  A
# title no rule knows shows only under @interdimux-show-title all -- on an
# agent's row too: a shell that sets no title leaves the last program's title
# in the pane, and an agent that sets none (aider) would show that as its
# task.  So every agent whose own title should show has a rule here that
# matches it, even a bare `=  *`.  rust/src/titles.rs applies the same text:
# bash hands it over whole.
DEFAULT_TITLE_RULES='
# --- agents: titles ------------------------------------------------------
# Claude Code: `✳ <title>`; ◐/◑ or a spinner while busy outside a multiplexer
claude          -        -   ✳ Claude Code
claude          -        -   Claude Code
claude          working  $1  ◐ *
claude          working  $1  ◑ *
claude          working  $1  %spin *
claude          -        $1  ✳ *
# Codex: `<spinner> <thread> | <project>`; `[ ! ] Action Required | ...`
# blinking to `[ . ]` while an approval waits.  No spinner is not idle: the
# activity item can be switched off.
codex           approve  $1  [ ! ] Action Required | * | *
codex           approve  $1  [ . ] Action Required | * | *
codex           approve  -   [ ! ] Action Required*
codex           approve  -   [ . ] Action Required*
codex           approve  $1  ● [ ! ] Action Required | * | *
codex           approve  $1  ● [ . ] Action Required | * | *
codex           approve  -   ● [ ! ] Action Required*
codex           approve  -   ● [ . ] Action Required*
codex           working  $1  %spin * | *
codex           working  -   %spin *
codex           -        $1  * | *
codex           -        -   *
# gemini-cli (windowTitle.ts): a glyph, TWO spaces, a word, then (folder),
# padded to 80 columns; a thought, when shown, then (folder) if it fits
gemini          approve  -   ✋*
gemini          working  -   ✦  Working…*
gemini          working  $1  ✦  * (*)
gemini          working  $1  ✦ *
gemini          working  -   ⏲*
gemini          idle     -   ◇*
gemini          -        -   Gemini CLI*
# Qwen Code: ◐ working, ✳ waiting for approval (with a U+FE0E after either)
qwen            working  $1  ◐*
qwen            approve  $1  ✳*
qwen            -        -   Qwen - *
# Amp: `<spinner> <thread> - amp - <cwd>`
amp             approve  -   ◆ *
amp             working  $1  %spin * - amp - *
amp             idle     $1  * - amp - *
# opencode, Cursor, goose, crush, GitHub Copilot
opencode        -        $1  OC | *
opencode        -        -   OpenCode
# Cursor: its chat name, which has no mark of its own
cursor-agent    -        -   Cursor Agent
cursor-agent    -        =   *
goose           -        -   🪿*
crush           -        -   crush *
copilot         -        $1  * - GitHub Copilot
copilot         -        -   GitHub Copilot

# --- agents: state other plugins (or your hooks) publish as options ------
# the interdimux contract: set @agent_state to one of the words, @agent_desc to text
@agent_state          working  -  working
@agent_state          approve  -  approve
@agent_state          input    -  input
@agent_state          idle     -  idle
@agent_state          done     -  done
@agent_state          error    -  error
@agent_desc           -        =  *
# tmux-agent-sidebar
@pane_status          working  -  running
@pane_status          working  -  background
@pane_status          idle     -  idle
@pane_status          error    -  error
@pane_wait_reason     approve  -  permission_prompt
@pane_wait_reason     approve  -  elicitation_dialog
@pane_wait_reason     approve  -  permission_denied
@pane_status          input    -  waiting
# tmux-agent-icons
@claude_state,@codex_state,@opencode_state  working  -  working
@claude_state,@codex_state,@opencode_state  approve  -  waiting
@claude_state,@codex_state,@opencode_state  idle     -  idle
# tmux-claude-status
@claude_pane_status   working  -  running
@claude_pane_status   working  -  shells
@claude_pane_status   approve  -  question
@claude_pane_status   approve  -  plan
@claude_pane_status   done     -  done
@claude_pane_status   error    -  error
@claude_pane_status   idle     -  loop
# workmux (its default icons only)
@workmux_pane_status  working  -  🤖
@workmux_pane_status  approve  -  💬
@workmux_pane_status  done     -  ✅
# dmux: "look at me"
@dmux_attention       done     -  1
# Only PANE options are read by default.  tmux resolves a window option for
# every pane of the window, so a window-scoped state (@ccm_prev_state of
# tmux-ccm, @agent_status_state of tmux-agent-status, @workmux_status of
# workmux, @codex_attention of codex-tmux-notify) would show on the panes
# next to the agent too, and each option read costs every list ~0.35 ms per
# 100 panes.  The README has their rules, to add to your own file.

# --- apps that are a terminal somewhere else -----------------------------
# A shell on another host or in a container titles the pane with where it is,
# and nothing else on the row can say so: the directory is where the client
# was started, the command is `ssh web1` or `docker exec -it 3f2a bash`.  Only
# the shapes such titles have are read, so what an earlier program left in the
# title (a shell that sets none leaves it there) shows only if it has one, and
# a prompt of THIS host never shows (cmd_field drops it).
#
# mosh-client (the mosh script execs it) puts [mosh] before whatever the remote
# sets, and pops its own title on exit
mosh-client  -  $1  [mosh] *
# a prompt.  user@host: ~/path from the Debian and Ubuntu bashrc (TERM xterm*),
# user@host:~/path from Fedora /etc/bashrc (xterm*), Arch /etc/bash.bashrc
# (xterm*, tmux*) and oh-my-zsh (any TERM).  docker -t gives the container
# TERM=xterm but no USER, which Fedora and Arch print: @3f2a9c1b:/app.  screen
# passes its window title on.
ssh,autossh,et,docker,docker-compose,podman,nerdctl,kubectl,oc,lxc,incus,machinectl,toolbox,multipass,screen  -  =  *@*:*
# fish over ssh (fish_title, when SSH_TTY is set): [host] ~/p/dir, and
# [host] make ~/p/dir while a command runs
ssh,autossh,et  -  =  [*] *
# tmux there, with set-titles on and the default set-titles-string
# (#S:#I:#W - "#T"): session:index:window - "its pane title"
ssh,autossh,et,docker,docker-compose,podman,nerdctl,kubectl,oc,lxc,incus,machinectl,toolbox,multipass  -  =  *:*:* - "*"*
# a client of another tmux server here (tmux -L other attach), with set-titles
# on: its session:index:window.  The pane title after it is usually a prompt
# of this host, which would hide the whole title.
tmux  -  $1  * - "*"*
'

# How much of a pane title the rules read: its first TITLE_CAP characters
# (agent_state_r cuts it; rust/src/titles.rs `head` is the same cut).  Nothing
# else bounds a title.  The program in the pane chooses it, over ssh or from a
# container too, tmux keeps an OSC 2 title of 1 MB whole, and every row and
# the dashboard's count clean and match it.  256 because a row shows at most
# 200 characters of a description (@interdimux-title-max), and every built-in
# rule shows the title from its start (=) or its first capture ($1, after a
# prefix of at most 26 characters).  The cut is not free: a rule with literal
# text AFTER its capture (codex's ` | <project>`, amp's ` - amp - <cwd>`) no
# longer matches a title whose capture runs past ~230 characters, so such a
# row loses its state and description -- in both renderers alike, and agents'
# titles are far shorter.  And under an explicit LC_ALL=C or LC_CTYPE=C bash
# counts the 256 in BYTES (utf8_ctype_r respects a locale the user chose), so
# there a long multibyte title is cut sooner than Rust cuts it.  tmux's own
# #{=256:pane_title} was not the
# cut: it counts cells, so a title of zero-width characters (combining marks,
# U+200B, U+0085) passes it whole, and it rewrites what it keeps -- `###`
# comes back as `####`, and an unclosed `#[` drops the rest (tmux 3.7b,
# format_trim_left).  Review R01.
TITLE_CAP=256

# A title's text before any rule sees it, in REPLY: control characters made
# safe as in a command (tmux already escapes them: a C0 never reaches a
# title), bidi controls dropped (a U+202E would reverse the rest of the row),
# blanks trimmed (gemini pads its title to 80 columns).
_BIDI_CHARS=( $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae'
              $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9'
              $'\xe2\x80\x8e' $'\xe2\x80\x8f' )
title_text_r() {
  local t _b
  sanitize_args "$1"; t="$REPLY"
  case "$t" in
    *$'\xe2\x80'*|*$'\xe2\x81'*) for _b in "${_BIDI_CHARS[@]}"; do t="${t//"$_b"/}"; done ;;
  esac
  trim_blanks_r "$t"
}

# $1 without its leading and trailing blanks, in REPLY.  Each run is measured
# with an anchored regex and cut by its length: the ${t#"${t%%[! ]*}"} and
# ${t%"${t##*[! ]}"} idiom is quadratic in the run (16,000 trailing blanks
# cost 2.2 s, review R13), and ONE regex over the whole text, ^ *(.*[^ ]) *$,
# does not match at all once the text holds a byte that is not UTF-8.
trim_blanks_r() {
  REPLY="$1"
  case "$REPLY" in ' '*) [[ "$REPLY" =~ ^\ + ]] && REPLY="${REPLY:${#BASH_REMATCH[0]}}" ;; esac
  case "$REPLY" in *' ') [[ "$REPLY" =~ \ +$ ]] && REPLY="${REPLY:0:${#REPLY}-${#BASH_REMATCH[0]}}" ;; esac
  return 0
}

# A description as the row shows it: one leading status glyph dropped, with
# the variation selector and blanks around it.  The glyphs agents lead with:
# braille spinners (U+2800-28FF), ✳ (U+2733), ◐◑◒◓ (U+25D0-25D3).
#
# Matched as BYTES, the same code points the Rust core compares: a spinner is
# \xe2, one of \xa0-\xa3, then a continuation byte.  ${t:0:1} and printf's
# code point read the first BYTE in a C locale (what a popup gets from a tmux
# server started with no LANG), so codex and claude lost `working`, amp said
# `idle` while it worked, and the glyphs stayed in the text (review R14).  A
# pattern of partial characters matches byte by byte in any locale, bash 3.2
# to 5.2 alike.
_SPIN=$'\xe2'[$'\xa0'-$'\xa3'][$'\x80'-$'\xbf']
_HALF=$'\xe2\x97'[$'\x90'-$'\x93']                 # ◐◑◒◓
_STAR=$'\xe2\x9c\xb3'                               # ✳
_VS=$'\xef\xb8'[$'\x8e'$'\x8f']                     # U+FE0E, U+FE0F
title_glyph_r() {
  local t
  trim_blanks_r "$1"; t="$REPLY"
  case "$t" in $_VS*) trim_blanks_r "${t#$_VS}"; t="$REPLY" ;; esac
  case "$t" in
    $_SPIN*) t="${t#$_SPIN}" ;;
    $_STAR*) t="${t#$_STAR}" ;;
    $_HALF*) t="${t#$_HALF}" ;;
    *) REPLY="$t"; return 0 ;;
  esac
  t="${t#$_VS}"
  trim_blanks_r "$t"
}

# One rule line split into its four fields (RULE_A RULE_S RULE_D RULE_P), the
# way the Rust core splits it: tabs and CRs are blanks, blanks separate the
# first three, and the pattern is the rest, trimmed.  Returns 1 for a
# comment, a blank line or a line with no pattern.
rule_fields() {
  # One regex, not ${l%%[! ]*} trims: those are quadratic in the line's length
  # in bash, and made loading the default rules cost ~18 ms.
  local l="${1//[$'\t\r']/ }" re='^ *([^ ]+) +([^ ]+) +([^ ]+) +(.*[^ ]) *$'
  [[ "$l" =~ $re ]] || return 1
  RULE_A="${BASH_REMATCH[1]}" RULE_S="${BASH_REMATCH[2]}" RULE_D="${BASH_REMATCH[3]}" RULE_P="${BASH_REMATCH[4]}"
  [[ "$RULE_A" != '#'* ]]
}

# The option names the default rules read, spelled out: deriving them from
# DEFAULT_TITLE_RULES costs ~5 ms of bash on every list, and they only change
# when the rules do.  tests/test_title_rules.sh checks this against the rules.
DEFAULT_STATE_OPTS=' agent_state agent_desc pane_status pane_wait_reason claude_state codex_state opencode_state claude_pane_status workmux_pane_status dmux_attention '

# The rule set this list uses, in TITLE_RULESET: the user's file, then the
# defaults.  Read once per list (no fork) and handed to the Rust core whole.
# STATE_OPTS: the option names the option rules read -- the defaults', and any
# the user's file adds (valid tmux option names only: they are spliced into
# the list-panes format).
#
# A line of the file that is not valid UTF-8 (is_utf8) is dropped here, and
# only that line: a Latin-1 comment in an otherwise good file is common, and
# the Rust core cannot hold such a byte at all -- handed the whole text, it
# read an EMPTY rule set, every built-in rule gone with it, while bash went on
# (review R02).  rust/src/agent.rs drops the same lines, should one ever reach
# it some other way; --doctor names them.  A NUL (a UTF-16 file) ends the
# text: bash cannot hold one, so what follows it is never read.
TITLE_RULESET="" STATE_OPTS="" CUR_HOST="" CUR_HOST_SHORT="" TITLE_RULES_USER=""
title_ruleset() {
  local f="${TITLE_RULES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/titles}" txt="" l o kept=""
  local -a lines=()
  STATE_OPTS="$DEFAULT_STATE_OPTS"
  if [ -f "$f" ] && [ -r "$f" ]; then
    { IFS= read -r -d '' txt < "$f"; } 2>/dev/null || :
  fi
  if ! is_utf8 "$txt"; then
    set -f; IFS=$'\n'; lines=($txt); unset IFS; set +f
    for l in ${lines[@]+"${lines[@]}"}; do is_utf8 "$l" && kept+="$l"$'\n'; done
    txt="$kept"
  fi
  TITLE_RULES_USER="$txt"   # the user's part alone (aw_can_r)
  TITLE_RULESET="$txt"$'\n'"$DEFAULT_TITLE_RULES"
  [[ "$txt" == *@* ]] || return 0
  set -f; IFS=$'\n'; lines=($txt); unset IFS; set +f
  for l in ${lines[@]+"${lines[@]}"}; do
    [[ "$l" == *@* ]] || continue
    rule_fields "$l" || continue
    [[ "$RULE_A" == @* ]] || continue
    set -f; IFS=,
    for o in $RULE_A; do
      o="${o#@}"
      case "$o" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
      [[ "$STATE_OPTS" == *" $o "* ]] || STATE_OPTS+="$o "
    done
    unset IFS; set +f
  done
}

# The list-panes format that reads the published options, in REPLY: one value
# per name in STATE_OPTS, in order, each ended by GS, with a GS, RS, US or
# newline of its own rewritten to '?' and capped at 128 (an option can hold
# anything).  Shared by the navigator's batched query and the dashboard's count.
state_optfmt_r() {
  local on nl=$'\n' rs=$'\x1e'
  REPLY=""
  for on in $STATE_OPTS; do
    REPLY+="#{=128;s/[${GS}${rs}${US}${nl}]/?/:@$on}$GS"
  done
}

# TITLE_RULESET indexed, for the bash renderer only, on the first row that
# needs it: each rule line by the apps it names (TR_BY_APP, TR_STAR for `*`,
# TR_OPT_BY for the option rules, by option), so a row visits only its own
# app's rules, and only the rules of the options its pane has set --
# scanning all of them cost ~0.7 ms a row.  A rule is PARSED (tr_parse) only
# when a row first reaches it: splitting and compiling all the defaults (some
# 70) cost ~18 ms, and a list of shells and editors needs none of them.
#
# Parsing turns PATTERN into an anchored ERE: literals escaped, * -> (.*).
# POSIX takes the leftmost subexpression longest first, which is the greedy
# left-to-right capture rust/src/titles.rs implements.
TR_LOADED=0 TR_STAR="" TR_OPTIDX=""
declare -a TR_LINE=() TR_APPS=() TR_STATE=() TR_DESC=() TR_RE=() TR_SPIN=() TR_OK=()
declare -A TR_BY_APP=() TR_IDX=() TR_OPT_BY=()
_ERE_SPECIAL=( '\' '.' '[' ']' '(' ')' '{' '}' '+' '?' '|' '^' '$' )
load_title_rules() {
  TR_LOADED=1
  local l a n=0
  local -a lines=() apps=()
  set -f; IFS=$'\n'; lines=($TITLE_RULESET); unset IFS; set +f
  for l in ${lines[@]+"${lines[@]}"}; do
    # Guarded: the substitution costs even when there is nothing to replace
    # (a multibyte scan of every line), and the shipped rules hold no tab:
    # ~40% of this function, measured for prefix+g's count (review R08).
    case "$l" in *[$'\t\r']*) l="${l//[$'\t\r']/ }" ;; esac
    case "$l" in ' '*) l="${l#"${l%%[! ]*}"}" ;; esac
    [ -n "$l" ] || continue
    case "$l" in '#'*) continue ;; esac
    a="${l%% *}"
    TR_LINE[n]="$l" TR_APPS[n]="$a"
    case "$a" in
      @*)
        TR_OPTIDX+="$n "
        set -f; IFS=,; apps=($a); unset IFS; set +f
        for a in ${apps[@]+"${apps[@]}"}; do a="${a#@}"; [ -n "$a" ] && TR_OPT_BY["$a"]+="$n "; done ;;
      '*') TR_STAR+="$n " ;;
      *,*)
        set -f; IFS=,; apps=($a); unset IFS; set +f
        for a in ${apps[@]+"${apps[@]}"}; do [ -n "$a" ] && TR_BY_APP["$a"]+="$n "; done ;;
      *) TR_BY_APP["$a"]+="$n " ;;
    esac
    n=$(( n + 1 ))
  done
}

# Parse rule $1 (once): its fields and its ERE.  TR_OK[$1]=0 for a line that is
# not a rule after all (no pattern), which every lookup then skips.  A STATE
# that is not one of the words is `-`: the rule still matches, and still
# gives its DESC, but no state (--doctor names such a line).
tr_parse() {
  local re c
  if ! rule_fields "${TR_LINE[$1]}"; then TR_OK[$1]=0; return 0; fi
  case "$RULE_S" in approve|input|working|idle|done|error) ;; *) RULE_S=- ;; esac
  TR_STATE[$1]="$RULE_S" TR_DESC[$1]="$RULE_D" re="$RULE_P" c=0
  if [[ "$re" == %spin* ]]; then c=1; re="${re#%spin}"; fi
  TR_SPIN[$1]="$c"
  for c in "${_ERE_SPECIAL[@]}"; do re="${re//"$c"/\\$c}"; done
  re="${re//\*/(.*)}"
  TR_RE[$1]="^$re\$" TR_OK[$1]=1
}

# The title rules for app $1, in rule order, in REPLY ("" when none): its own
# and the `*` ones, merged.  Cached per app.
title_idx_r() {
  [ "$TR_LOADED" = 1 ] || load_title_rules
  if [ -z "$1" ]; then REPLY="$TR_STAR"; return 0; fi   # no name: `*` rules only
  if [[ ${TR_IDX[$1]+x} ]]; then REPLY="${TR_IDX[$1]}"; return 0; fi
  local own="${TR_BY_APP[$1]-}" out="" i j
  local -a x=() y=()
  if [ -z "$TR_STAR" ]; then
    out="$own"
  elif [ -z "$own" ]; then
    out="$TR_STAR"
  else
    x=($own) y=($TR_STAR) i=0 j=0
    while (( i < ${#x[@]} || j < ${#y[@]} )); do
      if (( j >= ${#y[@]} || ( i < ${#x[@]} && x[i] < y[j] ) )); then
        out+="${x[i]} "; i=$(( i + 1 ))
      else
        out+="${y[j]} "; j=$(( j + 1 ))
      fi
    done
  fi
  TR_IDX["$1"]="$out"
  REPLY="$out"
}

# Rule i's DESC for the captures in BASH_REMATCH and the whole text $2.
_rule_desc() {
  local tpl="${TR_DESC[$1]}" n
  REPLY=""
  case "$tpl" in
    -) ;;
    =) REPLY="$2" ;;
    *)
      while [ -n "$tpl" ]; do
        case "$tpl" in
          '$'[123456789]*) n="${tpl:1:1}"; REPLY+="${BASH_REMATCH[n]-}"; tpl="${tpl:2}" ;;
          *) REPLY+="${tpl:0:1}"; tpl="${tpl:1}" ;;
        esac
      done ;;
  esac
}

# The first title rule for app $1 whose pattern matches title text $2.
# TR_HIT=1 and TR_S (a state word or empty) and TR_D (the description) when
# one does.
title_rule_r() {
  TR_HIT=0 TR_S="" TR_D=""
  local name="$1" t="$2" s i
  title_idx_r "$name"
  for i in $REPLY; do
    [ -n "${TR_OK[i]-}" ] || tr_parse "$i"
    [ "${TR_OK[i]}" = 1 ] || continue
    s="$t"
    if [ "${TR_SPIN[i]}" = 1 ]; then   # a spinner, as bytes: see title_glyph_r
      case "$s" in $_SPIN*) s="${s#$_SPIN}" ;; *) continue ;; esac
    fi
    [[ "$s" =~ ${TR_RE[i]} ]] || continue
    TR_HIT=1
    [ "${TR_STATE[i]}" = - ] || TR_S="${TR_STATE[i]}"
    _rule_desc "$i" "$t"; TR_D="$REPLY"
    return 0
  done
  return 0
}

# The option rules over a pane's published options $1: one value per name in
# STATE_OPTS, in order, each ended by GS (the list-panes format builds it; an
# empty value is an unset option).  OR_S: the first state an option rule
# gives; OR_D: the first description.
GS=$'\x1d'
option_rule_r() {
  OR_S="" OR_D=""
  [[ "$1" == *[!$GS]* ]] || return 0
  [ "$TR_LOADED" = 1 ] || load_title_rules
  local -A val=()
  local i o v
  local -a vals=() names=() ons=()
  set -f
  IFS="$GS"; vals=($1$GS); unset IFS
  ons=($STATE_OPTS)
  set +f
  # Only the rules that name an option this pane has set, still in rule order
  # (an indexed array's keys come back ascending).  A pane sets one or two of
  # them: walking all the option rules (some 30 by default), parsing each,
  # cost every process that draws such a row -- or counts it, for prefix+g --
  # ~3 ms a pane.
  local -a sel=()
  for (( i = 0; i < ${#ons[@]} && i < ${#vals[@]}; i++ )); do
    if [ -n "${vals[i]}" ]; then
      val["${ons[i]}"]="${vals[i]}"
      for o in ${TR_OPT_BY[${ons[i]}]-}; do sel[o]=1; done
    fi
  done
  for i in "${!sel[@]}"; do
    [ -n "${TR_OK[i]-}" ] || tr_parse "$i"
    [ "${TR_OK[i]}" = 1 ] || continue
    set -f; IFS=,; names=(${TR_APPS[i]}); unset IFS; set +f
    for o in "${names[@]}"; do
      o="${o#@}"
      [ -n "$o" ] && [[ ${val[$o]+x} ]] || continue
      v="${val[$o]}"
      if [ "${TR_SPIN[i]}" = 1 ]; then
        case "$v" in $_SPIN*) v="${v#$_SPIN}" ;; *) continue ;; esac
      fi
      [[ "$v" =~ ${TR_RE[i]} ]] || continue
      [ -z "$OR_S" ] && [ "${TR_STATE[i]}" != - ] && OR_S="${TR_STATE[i]}"
      if [ -z "$OR_D" ]; then _rule_desc "$i" "${val[$o]}"; OR_D="$REPLY"; fi
      break
    done
    [ -n "$OR_S" ] && [ -n "$OR_D" ] && return 0
  done
  return 0
}

# Claude Code's session registry: one line per live, interactive session that
# runs in a tmux pane, `<%pane>US<sid>US<word>US<since>`, in CLAUDE_REG.
#
# Claude keeps ~/.claude/sessions/<pid>.json up to date as the session works:
# `status` busy / idle / waiting (with `waitingFor`: "permission prompt",
# "input needed", ...) / shell (a background task after the turn ended),
# `statusUpdatedAt` in ms, and `tmux`, the TMUX_PANE it started in.  It is an
# internal file, so it is read defensively, fork-free and once per list:
#
#   * only `<digits>.json`.  The directory also holds `<pid>.<hash>.key`
#     files, which are never opened;
#   * only a regular file (or a link to one), and only its first 65,536
#     characters: a FIFO there blocked the open(2) until a writer came --
#     every list, reload and prefix+g, in both renderers, hung (review R24).
#     A record is a few hundred bytes; a longer one fails the closing-brace
#     test below;
#   * written by truncating and rewriting, so a read can catch it empty or
#     half written: no closing brace, or a key missing, skips it for this paint;
#   * the pid must still be that process: /proc/<pid>/stat's start time equals
#     the record's procStart, so a reused pid is not believed.  Its session id
#     (field 6) is the pane's shell, and the renderers accept the record for a
#     row only when that equals the row's #{pane_pid} -- which also rejects a
#     %N that belongs to another tmux server.  Without /proc (macOS) it is only
#     `kill -0`, and the sid is left empty: unchecked, so a reused pid or
#     another server's %N is believed there (README says so).  The record's
#     `tmux` field is `session:@window.%pane`, with no socket in it to check.
#     INTERDIMUX_REGISTRY_NO_PROC=1 takes that path on Linux too: a test seam
#     (tests/test_agent_readme.sh), so the fallback runs where CI does.
#
# Never touched: `claude agents --json` (a 226 MB binary and a telemetry
# event per call) and .fleetview-heartbeat (it turns on classifier calls).
# Where it lives: @interdimux-claude-dir, else $CLAUDE_CONFIG_DIR, else
# ~/.claude.  A CLAUDE_CONFIG_DIR set only in a shell's rc is invisible to the
# popup, which starts from the tmux server's environment; hence the option.
CLAUDE_REG=""
claude_registry_r() {
  CLAUDE_REG=""
  [ "$AGENT_STATE" = on ] || return 0
  local dir="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/sessions"
  [ -d "$dir" ] || return 0
  local f stem j pid pst pane st wf upd word sid ng=0
  local -a files=() sf=()
  shopt -q nullglob && ng=1
  shopt -s nullglob
  files=("$dir"/*.json)
  [ "$ng" = 1 ] || shopt -u nullglob
  for f in ${files[@]+"${files[@]}"}; do
    stem="${f##*/}"; stem="${stem%.json}"
    case "$stem" in ''|*[!0-9]*) continue ;; esac
    [ -f "$f" ] || continue
    j=""
    { IFS= read -r -N 65536 j < "$f"; } 2>/dev/null || :
    [[ "$j" == *'}' ]] || continue
    # A glob where nothing is captured, and whether the pid still runs BEFORE
    # the other fields: bash compiles a [[ =~ ]] regex on every match (~30 µs
    # each here), and a record whose Claude has gone -- they stay behind after
    # a crash -- paid for all seven only to be dropped (review R15).  The
    # waiting reason is read only for a record that is waiting.
    [[ "$j" == *'"kind":"interactive"'* ]] || continue
    [[ "$j" =~ \"pid\":([0-9]+) ]] && pid="${BASH_REMATCH[1]}" || continue
    if [ -r /proc/self/stat ]; then
      [ -e "/proc/$pid/stat" ] || continue
    else
      kill -0 "$pid" 2>/dev/null || continue
    fi
    [[ "$j" =~ \"tmux\":\"[^\"]*(%[0-9]+)\" ]] && pane="${BASH_REMATCH[1]}" || continue
    [[ "$j" =~ \"status\":\"([a-z]+)\" ]] && st="${BASH_REMATCH[1]}" || continue
    upd=0; [[ "$j" =~ \"statusUpdatedAt\":([0-9]+) ]] && upd="${BASH_REMATCH[1]}"
    case "$st" in
      busy) word=working ;;
      idle|shell) word=idle ;;
      waiting)
        wf=""; [[ "$j" =~ \"waitingFor\":\"([^\"]*)\" ]] && wf="${BASH_REMATCH[1]}"
        case "$wf" in
          'permission prompt'|'worker request'|'sandbox request') word=approve ;;
          *) word=input ;;
        esac ;;
      *) continue ;;
    esac
    sid=""
    if [ -r /proc/self/stat ] && [ "${INTERDIMUX_REGISTRY_NO_PROC:-}" != 1 ]; then
      pst=""; [[ "$j" =~ \"procStart\":\"?([0-9]+) ]] && pst="${BASH_REMATCH[1]}"
      [ -n "$pst" ] || continue
      sf=()
      { IFS=$' \t\n' read -r -d '' -a sf < "/proc/$pid/stat"; } 2>/dev/null || :
      # comm ends at the LAST word holding a ')' (see proc_group_ids): field N
      # of stat is sf[last + N - 2].  The usual comm (one word) is one test.
      local i last=0
      if [[ "${sf[1]-}" == *')' && "${sf[*]:2:7}" != *')'* ]]; then
        last=1
      else
        for (( i = 1; i <= 9 && i < ${#sf[@]}; i++ )); do
          case "${sf[i]}" in *')'*) last=$i ;; esac
        done
      fi
      [ "$last" -gt 0 ] && [ "${sf[last+20]-}" = "$pst" ] || continue
      sid="${sf[last+4]}"
    fi
    CLAUDE_REG+="$pane$US$sid$US$word$US$(( upd / 1000 ))"$'\n'
  done
  CLAUDE_REG="${CLAUDE_REG%$'\n'}"
  return 0
}

# What a window or pane row knows about its agent, from the three sources in
# order: Claude's registry, the options plugins publish, the title.  The ONE
# place the state is decided -- cmd_field draws it, and the dashboard counts
# it (agents_waiting_r), so the count is always what the rows say.  $1 the
# resolved command, $2 the pane pid, $3 the pane id, $4 its title, $5 the
# values of the options agent plugins publish (see option_rule_r).  Reads
# CLAUDE_BY_PANE.  Sets
#
#   AS_NAME   the app its title rules are picked by: the agent, else argv0
#   AS_STATE  a state word, or empty (and AS_SINCE, the registry's epoch)
#   AS_DESC   the description, before cmd_field trims it for the row
#   AS_KNOWN  1 when a rule knew the description
#   AS_PUBD   1 when the description was published (an option), not a title
#   AS_AGENT  1 when the row is an agent's
#
# and AG_NAME / AG_REST (agent_of).  Returns 1, with all of them empty, for a
# row that can have none of it: no command, or an idle shell.
#
# AS_STATE_ONLY (agents_waiting_r sets it, as a local): only AS_STATE is
# wanted.  A source that gave a state is then final -- the ones after it are
# asked only while the state is empty -- so the rest is skipped, and a title is
# matched only when a rule for its app can say approve or input (AW_CAN).
# The description is not worked out; the state is the same as a row's.
AS_STATE_ONLY=""
agent_state_r() {
  AS_NAME="" AS_STATE="" AS_SINCE="" AS_DESC="" AS_KNOWN=0 AS_PUBD=0 AS_AGENT=0 AG_NAME="" AG_REST=""
  local raw="$1" pid="$2" pane="$3" title="$4" opts="${5-}"
  [ -n "$raw" ] || return 1
  local a0 b name state="" since="" desc="" agent_row=0 known=0 pubd=0 r v w
  a0="${raw%% *}"; b="${a0##*/}"
  # An idle shell is nobody's agent: whatever state or title it had went with
  # the program that set it.
  [[ "$SHELL_NAMES" == *" ${b#-} "* ]] && only_options "${raw#"$a0"}" && return 1
  # agent_of only for what could be an agent: most rows are not, and in bash a
  # function call is the expensive part of a row.
  if [ -n "$AGENT_KNOWN" ]; then
    case "$b" in
      node|nodejs|python*) agent_of "$raw" ;;
      *) if [[ "$AGENT_KNOWN" == *" $b "* || "$a0" == */claude/versions/* ]]; then agent_of "$raw"; fi ;;
    esac
  fi
  [ -n "$AG_NAME" ] && agent_row=1
  name="${AG_NAME:-${b#-}}"
  if [ "$AGENT_STATE" = on ] && [ -n "$pane" ]; then
    v="${CLAUDE_BY_PANE[$pane]-}"
    if [ -n "$v" ]; then
      r="${v%%"$US"*}"; v="${v#*"$US"}"
      if [ -z "$r" ] || [ "$r" = "$pid" ]; then
        state="${v%%"$US"*}" since="${v#*"$US"}" agent_row=1
      fi
    fi
  fi
  if [ -n "$AS_STATE_ONLY" ] && [ -n "$state" ]; then
    AS_NAME="$name" AS_STATE="$state" AS_SINCE="$since" AS_AGENT=1
    return 0
  fi
  # Then what a plugin or a hook published (for any row: the options are the
  # pane's), then the title.
  local odesc=""
  if [[ "$opts" == *[!$GS]* ]]; then
    option_rule_r "$opts"
    if [ "$AGENT_STATE" = on ] && [ -z "$state" ] && [ -n "$OR_S" ]; then
      state="$OR_S" agent_row=1
    fi
    title_text_r "$OR_D"; odesc="$REPLY"
    [ -n "$odesc" ] && agent_row=1
  fi
  if [ -n "$AS_STATE_ONLY" ]; then
    # With a state, or a described option (the title is not read then), the
    # title has nothing left to say about the state.
    if [ -n "$state" ] || [ -n "$odesc" ] || [ -z "$title" ]; then
      AS_NAME="$name" AS_STATE="$state" AS_SINCE="$since" AS_AGENT="$agent_row"
      return 0
    fi
    [ -n "$AW_CAN" ] || aw_can_r
    if [[ "$AW_CAN" != *" $name "* && "$AW_CAN" != *" * "* ]]; then
      AS_NAME="$name" AS_AGENT="$agent_row"
      return 0
    fi
  fi
  if [ -n "$odesc" ]; then
    desc="$odesc" known=1 pubd=1
  elif [ -n "$title" ]; then
    # A title nothing can use -- no rule for the app, and not `all` -- is not
    # even cleaned: most rows are shells and editors.
    [ "$TR_LOADED" = 1 ] || load_title_rules
    if [ -n "$name" ] && [[ ${TR_IDX[$name]+x} ]]; then REPLY="${TR_IDX[$name]}"; else title_idx_r "$name"; fi
    if [ -n "$REPLY" ] || [ "$SHOW_TITLE" = all ]; then
      [ "${#title}" -le "$TITLE_CAP" ] || title="${title:0:TITLE_CAP}"
      title_text_r "$title"; w="$REPLY"
      title_rule_r "$name" "$w"
      if [ "$TR_HIT" = 1 ]; then
        known=1 desc="$TR_D"
        if [ "$AGENT_STATE" = on ] && [ -z "$state" ] && [ -n "$TR_S" ]; then
          state="$TR_S" agent_row=1
        fi
      else
        desc="$w"
      fi
      title_glyph_r "$desc"; desc="$REPLY"
    fi
  fi
  AS_NAME="$name" AS_STATE="$state" AS_SINCE="$since" AS_DESC="$desc" AS_KNOWN="$known" AS_PUBD="$pubd" AS_AGENT="$agent_row"
  return 0
}

# The agents view's gutter mark for a row whose pane ($2, empty when unknown)
# is in state $1, in REPLY: `!` for approve, `?` for input, empty for anything
# else -- or for a pane already marked on an earlier row (a session group or a
# linked window shows it again).  Reads and fills gather_targets' AMARKED.
agent_mark_r() {
  REPLY=""
  case "$1" in
    approve) [ -n "$2" ] && [[ ${AMARKED[$2]+x} ]] && return 0; REPLY="${BOLD_RED}!${RST}" ;;
    input)   [ -n "$2" ] && [[ ${AMARKED[$2]+x} ]] && return 0; REPLY="${BOLD_AMBER}?${RST}" ;;
    *) return 0 ;;
  esac
  [ -n "$2" ] && AMARKED[$2]=1
  return 0
}

# The command field of a window or pane row, in REPLY.  The arguments are
# agent_state_r's; it also reads CUR_HOST/CUR_HOST_SHORT from gather_targets.
#
#   <agent> [<state> [<age>]] [<title>] [<args>]
#
# An agent row is headed by the agent (`codex`, not `node codex`); when it
# shows a state or a title its arguments go, unless @interdimux-agent-args is
# on (they are still in the preview).  Any other row is exactly what
# format_command draws.  Either kind shows its title only when a rule knows it
# (or always, under @interdimux-show-title all).
cmd_field() {
  local raw="$1"
  AS_STATE=""   # the row's state, for the agents view's mark (agent_mark_r)
  format_command "$raw"
  [ "$AGENT_ON" = 1 ] && [ -n "$REPLY" ] || return 0
  local fc="$REPLY" a0 b name state since desc rest r w cw=""
  # The row nothing can be added to, known in a few tests instead of through
  # agent_state_r: no option published for the pane, no registry record for
  # it, not an agent, and no title -- or one that no title rule for the app
  # can read and show-title does not show anyway.  Most rows (shells, editors,
  # servers) are that, and in bash the function calls are most of what a row
  # costs: this is about a third of the way through agent_state_r (review
  # R09).  Each test is one of agent_state_r's own gates, so what it lets by
  # draws exactly what that would: keep the two in step.
  a0="${raw%% *}"; b="${a0##*/}"
  if [[ "${5-}" != *[!$GS]* ]] \
     && { [ -z "${3-}" ] || [ "$AGENT_STATE" != on ] || [ -z "${CLAUDE_BY_PANE[$3]-}" ]; }; then
    case "$b" in node|nodejs|python*) r=1 ;; *) r="" ;; esac   # agent_of reads their script
    if [ -z "$AGENT_KNOWN" ] || [[ -z "$r" && "$AGENT_KNOWN" != *" $b "* && "$a0" != */claude/versions/* ]]; then
      [ -n "${4-}" ] || { REPLY="$fc"; return 0; }
      if [ "$SHOW_TITLE" != all ]; then
        name="${b#-}"
        [ "$TR_LOADED" = 1 ] || load_title_rules
        if [ -n "$name" ] && [[ ${TR_IDX[$name]+x} ]]; then REPLY="${TR_IDX[$name]}"; else title_idx_r "$name"; fi
        [ -n "$REPLY" ] || { REPLY="$fc"; return 0; }
      fi
    fi
  fi
  agent_state_r "$@" || { REPLY="$fc"; return 0; }
  name="$AS_NAME" state="$AS_STATE" since="$AS_SINCE" desc="$AS_DESC"
  a0="${raw%% *}"; b="${a0##*/}"
  case "$SHOW_TITLE" in
    off)   desc="" ;;
    known) [ "$AS_KNOWN" = 1 ] || desc="" ;;
  esac
  if [ -n "$desc" ] && [ "$AS_PUBD" = 1 ]; then
    # Published text (@agent_desc, a plugin's option, an @option rule's DESC)
    # is what its publisher meant to say: it is no stale title and no copy of
    # the command line, so it is shown as it is -- only a bare repeat of the
    # name goes.
    [ "$desc" = "$name" ] && desc=""
    if [ "${#desc}" -gt "$TITLE_MAX" ]; then desc="${desc:0:TITLE_MAX-1}…"; fi
  elif [ -n "$desc" ]; then
    # What only repeats the row: the app's own name, tmux's default title (the
    # host name), a prompt of this host and, from a preexec hook, the command
    # line itself.
    #   * a prompt: `user@host:path` (bash, zsh; `@host.domain`, `[user@host]`
    #     too) -- @host where the name ends there, so `web` does not hide a
    #     container or remote host called `web-7d4b9c`.  fish, when SSH_TTY is
    #     set, heads its prompt AND its command lines with `[host]`, the name
    #     cut to 10 characters (fish_title).
    #   * a command line: its first word, past VAR=x and sudo-like prefixes, is
    #     argv0 -- or, for an interpreter, the script it runs.  A prefix that
    #     is itself argv0 counts: `sudo docker run ...` on a sudo row.  A word
    #     with a ':' before its last '/' is no command path but a prompt
    #     (`deploy@web1:/etc/ssh`, `host:~/ssh`): its last directory is not
    #     argv0 however it is spelled.
    r="$CUR_HOST_SHORT"
    if [ "$desc" = "$name" ] || [ "$desc" = "$CUR_HOST" ] || [ "$desc" = "$r" ] \
       || { [ -n "$r" ] && [[ "$desc" == *"@$r" || "$desc" == *"@$r"[!A-Za-z0-9_-]* \
                              || "$desc" == "[${r:0:10}]" || "$desc" == "[${r:0:10}] "* ]]; }; then
      desc=""
    else
      set -f
      for w in $desc; do
        cw="${w##*/}"; [[ "$w" == *:*/* ]] && cw=""
        [ -n "$cw" ] && [ "$cw" = "${b#-}" ] && break
        case "$w" in *=*|sudo|env|nohup|exec|time|command|builtin|noglob|nice) continue ;; esac
        break
      done
      set +f
      r=""
      case "$b" in
        node|nodejs|ruby|perl|php) r=1 ;;
        python*) [[ "${b#python}" == *[!0123456789.]* ]] || r=1 ;;
        lua*)    [[ "${b#lua}" == *[!0123456789.]* ]] || r=1 ;;
      esac
      [[ "$SHELL_NAMES" == *" ${b#-} "* ]] && r=1
      if [ -n "$r" ]; then r="${raw#"$a0"}"; r="${r# }"; r="${r%% *}"; fi
      if [ -n "$cw" ] && { [ "$cw" = "${b#-}" ] || { [ -n "$r" ] && [ "$cw" = "${r##*/}" ]; }; }; then
        desc=""
      fi
    fi
    if [ "${#desc}" -gt "$TITLE_MAX" ]; then desc="${desc:0:TITLE_MAX-1}…"; fi
  fi
  if [ "$AS_AGENT" = 0 ] && [ -z "$desc" ]; then REPLY="$fc"; return 0; fi
  local extra=""
  if [ -n "$state" ]; then
    case "$state" in
      approve|error) extra+=" ${BOLD_RED}${state}${RST}" ;;
      input)         extra+=" ${BOLD_AMBER}${state}${RST}" ;;
      *)             extra+=" ${DIM_TREE}${state}${RST}" ;;
    esac
    # No age under a minute: `approve now Fix the parser` read as an order
    # (review R28).  Here, not in age_of, which session ages share.
    age_of "$since"
    [ -n "$REPLY" ] && [ "$REPLY" != now ] && extra+=" ${DIM_TREE}${REPLY}${RST}"
  fi
  [ -n "$desc" ] && extra+=" ${DIM_EDIT}${desc}${RST}"
  if [ -z "$AG_NAME" ]; then
    REPLY="$fc$extra"
    return 0
  fi
  rest="$AG_REST"
  [ -n "$extra" ] && [ "$AGENT_ARGS" = off ] && rest=""
  if [ -z "$extra" ]; then
    REPLY="${DIM_CMD}${AG_NAME}${rest}${RST}"
  elif [ -n "$rest" ]; then
    REPLY="${DIM_CMD}${AG_NAME}${RST}${extra}${DIM_CMD}${rest}${RST}"
  else
    REPLY="${DIM_CMD}${AG_NAME}${RST}${extra}"
  fi
}

# The apps a TITLE rule can put in `approve` or `input`, in AW_CAN as
# " app app ... " (with " * " when a `*` rule can: then any app can).  For
# agents_waiting_r, which skips a pane whose title could never make it wait.
# Option rules (@...) are the pane's options, not its title, and do not count
# here.  The default rules' apps are spelled out (DEFAULT_AW_CAN), as
# DEFAULT_STATE_OPTS is: reading them off the ~75 default rules costs about
# what load_title_rules' index does (5-8 ms of bash UTF-8 pattern matching),
# which is the cost this exists to skip.  tests/test_dashboard_count.sh holds
# it to the rules.  Only the user's own rules (TITLE_RULES_USER) are read.
DEFAULT_AW_CAN=' codex gemini qwen amp '
AW_CAN=""
aw_can_r() {
  local l a
  local -a lines=() apps=()
  AW_CAN="$DEFAULT_AW_CAN"
  [ -n "$TITLE_RULES_USER" ] || return 0
  set -f; IFS=$'\n'; lines=($TITLE_RULES_USER); unset IFS; set +f
  for l in ${lines[@]+"${lines[@]}"}; do
    case "$l" in *approve*|*input*) ;; *) continue ;; esac
    rule_fields "$l" || continue
    case "$RULE_S" in approve|input) ;; *) continue ;; esac
    case "$RULE_A" in @*) continue ;; esac
    set -f; IFS=,; apps=($RULE_A); unset IFS; set +f
    for a in ${apps[@]+"${apps[@]}"}; do [ -n "$a" ] && AW_CAN+="$a "; done
  done
}

# How many agents need you -- a pane whose state is `approve` or `input` -- in
# REPLY: the dashboard's Agents entry.  Counted per PANE, so an agent counts
# once however many rows show it: a window row repeats its active pane's, and
# `list-panes -a` prints a pane once for every session that holds its window
# -- a session group (`tmux new -t work`) or a linked window counted one agent
# two or three times (review R06).
#
# The state is agent_state_r's, the function the rows are drawn with, over the
# inputs the navigator's batched query gives them.  Only those, for prefix+g's
# sake: ONE tmux call (a list-panes of id, pid, current command, title and the
# published options), the registry read, and no rendering.  The command is
# resolved as the rows resolve it (resolve_command) only where the state can
# depend on it:
#   * an interpreter (node, nodejs, python*), because the agent is named by
#     the script it runs: `node .../bin/codex` is codex, and codex titles say
#     `approve`;
#   * a pane Claude's registry or a published option speaks for, because that
#     state shows only on a row that is not an idle shell -- and a wrapper
#     script (`sh ./my-agent`, see the README) is a shell to tmux's
#     #{pane_current_command}.
# Anywhere else #{pane_current_command} stands in, by its basename: argv0's
# basename is what names the row, and tmux strips the directory only from an
# argv0 that starts with `/` -- `./codex` and `target/release/codex` came
# through whole, found no rules, and a waiting agent went uncounted (review
# R12).  (The one difference left is a stopped agent in the background of a
# shell at its prompt, whose last title the row reads.)
#
# Most panes are decided before agent_state_r, the expensive part (review R08:
# prefix+g opened 30-47 ms later on a server of ssh panes):
#   * a registry record that applies and says anything but approve or input:
#     the registry is the first source that speaks, so nothing else can make
#     that pane wait;
#   * a pane with neither a record nor an option: only a title RULE can give
#     it a state, so only an app one of whose rules says approve or input is
#     looked at (AW_CAN).  ssh, docker, kubectl and the other remote shells
#     have title rules, none with a state, and Claude's say only `working`:
#     they used to cost a full title parse each, for a count they could never
#     reach.  AW_CAN needs no rule index (DEFAULT_AW_CAN, and the user's own
#     rules), so a list of shells and remote panes never loads the rules.
#
# Sessions @interdimux-hide keeps out of the navigator are left out here too,
# so the entry never promises an agent the navigator will not show.  The
# per-pane dedupe comes after that filter, so a pane linked into a hidden and
# a visible session still counts, from its visible line.
#
# The same call also answers, last, where the pressing client is: AW_CLIENT is
# "<height> <width> <session>" -- the session for the hide rule (the current
# one is never hidden), the size for the dashboard, which would otherwise have
# spent a round-trip of its own on it.  Empty when that lookup failed (a stale
# target: the one command here that can, hence last) or was never made.
AW_CLIENT=""
agents_waiting_r() {
  REPLY=0 AW_CLIENT=""
  [ "$AGENT_ON" = 1 ] && [ "$AGENT_STATE" = on ] || return 0
  utf8_ctype_r   # the rows' character type (see gather_targets)
  [ -z "$REPLY" ] || local LC_CTYPE="$REPLY"
  REPLY=0
  local fmt all rest cur="" line pane pid pcc raw res hp n=0 pt=0 rs=$'\x1e' a0 b v
  local -a f=() lines=()
  local -A CLAUDE_BY_PANE=() aw_seen=()
  local AS_STATE_ONLY=1   # see agent_state_r: the count wants the state alone
  title_ruleset
  state_optfmt_r
  fmt="#{session_name}${US}#{pane_id}${US}#{pane_pid}${US}#{pane_current_command}${US}#{pane_title}${US}$REPLY"
  all=$(tmux list-panes -a -F "$fmt" \; display-message -p "$rs" \; \
          display-message -p ${TMUX_C[@]+"${TMUX_C[@]}"} ${CUR_T[@]+"${CUR_T[@]}"} \
          '#{client_height} #{client_width} #S' 2>/dev/null)
  # Cut at the LAST RS (a command name may hold one), from the end: a
  # ${x#*pat} would be quadratic in its offset.
  rest="${all%"$rs"*}"
  if [ "$rest" != "$all" ]; then
    AW_CLIENT="${all:${#rest}+1}"; AW_CLIENT="${AW_CLIENT#$'\n'}"; all="$rest"
    if [[ "$AW_CLIENT" =~ ^([0-9]*)\ ([0-9]*)\ (.*)$ ]]; then
      cur="${BASH_REMATCH[3]}"   # a session with no client has no size, but has a name
      [ -n "${BASH_REMATCH[1]}" ] && [ -n "${BASH_REMATCH[2]}" ] || AW_CLIENT=""
    else
      AW_CLIENT=""
    fi
  fi
  [ -n "$all" ] || return 0
  claude_registry_r
  if [ -n "$CLAUDE_REG" ]; then
    while IFS= read -r line; do
      [[ "$line" == %*"$US"* ]] && CLAUDE_BY_PANE["${line%%"$US"*}"]="${line#*"$US"}"
    done <<< "$CLAUDE_REG"
  fi
  set -f; IFS=$'\n'; lines=($all); unset IFS; set +f
  for line in ${lines[@]+"${lines[@]}"}; do
    # set -f per line: agent_state_r's option rules turn it back off.
    set -f; IFS="$US"; f=($line$US); unset IFS; set +f   # the appended US: see gather_targets
    pane="${f[1]-}"
    case "$pane" in %[0-9]*) ;; *) continue ;; esac
    case "$pane" in %*[!0-9]*) continue ;; esac
    if [ -n "${HIDE_PATTERNS:-}" ] && [ "${f[0]}" != "$cur" ]; then
      set -f
      for hp in $HIDE_PATTERNS; do
        # shellcheck disable=SC2254  # the pattern is a glob by design
        case "${f[0]}" in $hp) set +f; continue 2 ;; esac
      done
      set +f
    fi
    # One pane, one count, however many sessions show it.
    [[ ${aw_seen[$pane]+x} ]] && continue
    aw_seen[$pane]=1
    # A line tmux cut short (see gather_targets) keeps its row, but its pid is
    # never read.
    pid="${f[2]-}"; [ "${#f[@]}" -eq 6 ] || pid=""
    pcc="${f[3]-}" raw="${f[3]-}" res=0
    a0="${pcc%% *}"; b="${a0##*/}"
    # A record that applies (agent_state_r's test) and says anything but
    # approve or input decides it: the registry speaks first.
    v="${CLAUDE_BY_PANE[$pane]-}"
    if [ -n "$v" ] && { [ -z "${v%%"$US"*}" ] || [ "${v%%"$US"*}" = "$pid" ]; }; then
      v="${v#*"$US"}"
      case "${v%%"$US"*}" in approve|input) ;; *) continue ;; esac
    fi
    case "$b" in
      ''|node|nodejs|python*) res=1 ;;
      *) if [ -n "${CLAUDE_BY_PANE[$pane]-}" ] || [[ "${f[5]-}" == *[!$GS]* ]]; then res=1; fi ;;
    esac
    if [ "$res" = 1 ]; then
      [ "$pt" = 1 ] || { [ "$SHOW_FULL_COMMAND" = on ] && build_process_table; pt=1; }
      resolve_command "$pcc" "$pid"; raw="$REPLY"
    else
      # Neither a record nor an option: only the title can give it a state, and
      # only through a title rule for its app that says approve or input.  Most
      # panes (shells, editors, remote shells) have none, and are passed over
      # here, before the call -- a bash function call is most of what a pane
      # costs.  The app is named as agent_state_r names it: argv0's basename.
      [ -n "${f[4]-}" ] || continue
      [ -n "$AW_CAN" ] || aw_can_r
      [[ "$AW_CAN" == *" ${b#-} "* || "$AW_CAN" == *" * "* ]] || continue
    fi
    agent_state_r "$raw" "$pid" "$pane" "${f[4]-}" "${f[5]-}" || continue
    case "$AS_STATE" in approve|input) n=$(( n + 1 )) ;; esac
  done
  REPLY="$n"
}

# ---------------------------------------------------------------------------
# Actions (called by fzf keybindings via execute)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--action" ]; then
  set +e
  action="$2"
  spec="${3:-}"
  spec="${spec%%	*}"
  [ -z "$spec" ] && exit 0
  parse_spec "$spec"
  target=$(spec_target)
  label=$(spec_label)

  # /dev/tty for interactive I/O; overridable for testing.  Both must be set
  # BEFORE the directory-row branch below: it calls info_flash -> dialog_open,
  # which reads $tty_in, and under set -u an unbound variable kills the process
  # outright — `set +e` does not protect against that.
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"

  # Every action below operates on a live tmux target; a directory row has none.
  if [ "$SPEC_TYPE" = "D" ]; then
    case "$action" in
      zoom) imux_msg "$label is not a tmux target" ;;
      *)    info_flash "$BOLD_AMBER" "Not applicable" "That row is a directory, not a session." ;;
    esac
    exit 0
  fi

  # A dialog hides the cursor and, in kill mode, recolours the popup border red.
  # Ctrl-C used to abandon both: the user was returned to the list with an
  # invisible cursor behind a permanently red frame, and the only way out was to
  # close the popup.  Restore unconditionally, on interrupt AND on any exit path
  # (IDEAS #22).  input_dialog also puts the terminal in raw mode, so the saved
  # stty settings are restored here too if it did not get the chance.
  _action_cleanup() {
    [ -n "${_saved_stty_global:-}" ] && stty "$_saved_stty_global" <"$tty_in" 2>/dev/null
    # >> not >: on a real tty either works, but INTERDIMUX_TTY_OUT can be a
    # regular file (that is how the dialogs are tested), and > TRUNCATES it —
    # silently destroying everything the dialog drew.
    printf '\033[?25h' >>"$tty_out" 2>/dev/null
    # Only touch the border when we are actually INSIDE a popup.  popup_accent
    # issues `display-popup` with no -E: in a popup that repaints it, but with a
    # client attached and no popup open tmux OPENS one running the default
    # shell, and blocks until someone dismisses it.  INTERDIMUX_TITLE is set
    # only by the popup launcher, so it is the marker for "we are in one".
    if [ -n "${INTERDIMUX_TITLE:-}" ]; then
      if [ "${INTERDIMUX_MODE:-switch}" = "kill" ]; then
        popup_accent danger
      else
        popup_accent user
      fi
    fi
  }
  trap '_action_cleanup; exit 130' INT TERM
  trap '_action_cleanup' EXIT

  # The row you are acting on may be gone.  The list is a snapshot: open the
  # picker, get distracted, and by the time you press ctrl-x that window may
  # have been closed from another client.  Every action used to open its dialog
  # regardless -- "Kill session 'victim'?" for a session that no longer exists --
  # and only failed after you confirmed, which is a confusing two-step for what
  # is really one fact.  Checked once here rather than in six places, and only
  # on the action path, never on the hot one.
  #
  # Deliberately NOT a guard against index reuse: if a different window has
  # since taken that index this check passes, because tmux cannot tell us it is
  # a different window from a "session:index" target alone. Fixing that needs
  # the SPEC to carry @id/%id, which is a wider change than this.
  #
  # ONE round-trip answers both "is it still there?" and everything the dialogs
  # below want to say about it.  has-session is the check, because it is the only
  # one that can fail: display-message resolves its target with CMD_FIND_CANFAIL,
  # so for a live session whose window is gone it printed the session's CURRENT
  # window instead of failing -- as the check, it passed every stale W/P row.  A
  # command that fails aborts the rest of a tmux command list, so a gone target
  # prints nothing at all.  The indices are compared as well: spec_target's exact
  # "=idx" form still falls back to a window NAMED exactly "3" once index 3 is
  # gone.  Free-text fields go last, where a stray separator cannot shift the
  # fields after them.
  _t_info=$(tmux has-session -t "$target" \; display-message -p -t "$target" \
    "#{session_id}${US}#{window_id}${US}#{pane_id}${US}#{window_index}${US}#{pane_index}${US}#{session_windows}${US}#{window_panes}${US}#{session_group}${US}#{session_name}${US}#{window_name}${US}#{pane_current_command}" \
    2>/dev/null)
  IFS="$US" read -r T_SID T_WID T_PID T_WIDX T_PIDX T_SWINS T_WPANES T_SGRP T_SNAME T_WNAME T_PCMD <<< "$_t_info"
  case "$SPEC_TYPE" in
    S) [ -n "$T_SID" ] ;;
    W) [ -n "$T_WID" ] && [ "$T_WIDX" = "$SPEC_WIDX" ] ;;
    P) [ -n "$T_PID" ] && [ "$T_WIDX" = "$SPEC_WIDX" ] && [ "$T_PIDX" = "$SPEC_PIDX" ] ;;
  esac || {
    if [ "$action" = zoom ]; then
      # zoom has no dialog of its own; it reports through the status line
      imux_msg "$label is gone — press ^r to reload"
    else
      info_flash "$BOLD_AMBER" "Gone" "$label no longer exists." "The list is stale — press ^r to reload."
    fi
    exit 0
  }

  # From here on, act on what the check just found, by tmux ID.  A name or an
  # index can change hands while a dialog waits for an answer (a rename, a closed
  # window with renumber-windows on); an ID never names anything else, so the
  # thing that gets killed is the thing the dialog named -- or nothing.
  case "$SPEC_TYPE" in
    S) target="$T_SID" ;;
    W) target="$T_WID" ;;
    P) target="$T_PID" ;;
  esac

  # The list shows a window by its NAME ("2:build") and a pane by what runs in
  # it, so the dialogs say that too -- "Kill window 'demo:2'?" made you map a
  # number back to the row you had just read, in the one place where getting it
  # wrong is final.  Names are user-controlled: control characters are made
  # visible, as they are for the list.
  _t_what=""
  case "$SPEC_TYPE" in
    W) _t_what="$T_WNAME" ;;
    P) _t_what="$T_PCMD" ;;
  esac
  if [ -n "$_t_what" ]; then
    sanitize_args "$_t_what"
    label="$label $REPLY"
  fi

  # Destroying a session detaches its clients (default detach-on-destroy),
  # ejecting the user from tmux even when other sessions exist -- so hop them to
  # the most recently used session that survives first, and the stay-open kill
  # workflow carries on.  SID is the session going away; GROUP, when given,
  # takes every session of that group with it (grouped sessions share their
  # windows, so the last window's death empties all of them).  With nowhere to
  # go the clients stay, and tmux's detach is the honest outcome.
  hop_clients_off() {
    local sid="$1" grp="${2:-}" fb="" id g c csid cgrp
    while IFS="$US" read -r _ id g; do
      [ -n "$id" ] || continue
      [ "$id" = "$sid" ] && continue
      [ -n "$grp" ] && [ "$g" = "$grp" ] && continue
      fb="$id"; break
    done <<< "$(tmux list-sessions -F "#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_id}${US}#{session_group}" 2>/dev/null \
                | sort -s -t "$US" -k1,1nr)"
    [ -n "$fb" ] || return 0
    while IFS="$US" read -r c csid cgrp; do
      [ -n "$c" ] || continue
      if [ "$csid" = "$sid" ] || { [ -n "$grp" ] && [ "$cgrp" = "$grp" ]; }; then
        tmux switch-client -c "$c" -t "$fb" 2>/dev/null
      fi
    done <<< "$(tmux list-clients -F "#{client_name}${US}#{session_id}${US}#{session_group}" 2>/dev/null)"
    return 0
  }

  case "$action" in
    kill)
      popup_accent danger
      # The last window of a session -- or the last pane of its last window --
      # takes the session with it, and every client on it with the session.
      # Say so while there is still a choice, and hop the clients off first,
      # exactly as for a session kill: the README's "no surprise detach" was
      # only ever kept for session rows, and ctrl-x on the only window of the
      # session you were in dropped you out of tmux mid-dialog.
      _k_last=0
      case "$SPEC_TYPE" in
        W) [ "$T_SWINS" = 1 ] && _k_last=1 ;;
        P) [ "$T_SWINS" = 1 ] && [ "$T_WPANES" = 1 ] && _k_last=1 ;;
      esac
      _k_body=("This cannot be undone.")
      if [ "$_k_last" = 1 ]; then
        sanitize_args "$T_SNAME"
        _k_what=window; [ "$SPEC_TYPE" = P ] && _k_what=pane
        _k_body=("It is the last $_k_what of '$REPLY', so the session closes too." "${_k_body[@]}")
      fi
      if confirm_dialog "$BOLD_RED" "Kill ${label}?" "${_k_body[@]}"; then
        case "$SPEC_TYPE" in
          S)
            hop_clients_off "$T_SID"
            tmux kill-session -t "$target" 2>/dev/null
            ;;
          W|P)
            # Asked again now, not trusted from before the dialog: a window
            # opened or closed while it waited changes the answer, and a hop
            # that was not needed moves the user for nothing.
            _k_now=$(tmux display-message -p -t "$target" "#{session_windows}${US}#{window_panes}" 2>/dev/null)
            IFS="$US" read -r _k_sw _k_wp <<< "$_k_now"
            if [ "$_k_sw" = 1 ] && { [ "$SPEC_TYPE" = W ] || [ "$_k_wp" = 1 ]; }; then
              hop_clients_off "$T_SID" "$T_SGRP"
            fi
            if [ "$SPEC_TYPE" = W ]; then
              tmux kill-window -t "$target" 2>/dev/null
            else
              tmux kill-pane   -t "$target" 2>/dev/null
            fi
            ;;
        esac
        if [ $? -eq 0 ]; then
          dialog_status "${GREEN}✓ killed${RST}"
        else
          dialog_status "${RED}✗ failed to kill ${label}${RST}"
        fi
        sleep 0.35
      fi
      # Kill mode keeps its standing danger frame; other modes restore
      # the user's configured border
      if [ "${INTERDIMUX_MODE:-switch}" = "kill" ]; then
        popup_accent danger
      else
        popup_accent user
      fi
      dialog_close
      ;;

    rename)
      if [ "$SPEC_TYPE" = "P" ]; then
        info_flash "$BOLD_AMBER" "Rename" "Panes cannot be renamed."
        exit 0
      fi
      # The guard's round-trip already fetched both names.
      case "$SPEC_TYPE" in
        S) current_name="$T_SNAME" ;;
        W) current_name="$T_WNAME" ;;
      esac
      input_dialog "$BOLD_AMBER" "Rename ${label}" "❯ " "$current_name"
      new_name="$REPLY"
      # The picker itself reaches any session name -- spec_target resolves the
      # ones tmux's targets cannot spell to an ID -- but two kinds of name are
      # still refused here, because nothing ELSE can reach them by name: tmux
      # splits a target at its first ':' (so `tmux attach -t my:app` cannot find
      # "my:app"), and reads a leading '$' as a session ID ("$1" is session 1,
      # whatever it is called).  tmux accepts both renames, so saying no is the
      # dialog's job.  '.' is fine: "=my.app:" names the session.
      _bad_name=""
      case "$new_name" in
        *:*) _bad_name="a name cannot contain ':' (tmux splits targets there)" ;;
      esac
      case "$SPEC_TYPE:$new_name" in
        'S:$'*) _bad_name="a session name cannot start with '\$' (tmux reads it as an ID)" ;;
      esac
      if [ -n "$_bad_name" ]; then
        dialog_status "${RED}✗ ${_bad_name}${RST}"
        sleep 1.2
        dialog_close
        exit 0
      fi
      if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
        # Capture tmux's own message instead of discarding it: "duplicate
        # session: two" tells the user what to do, where "failed to rename"
        # leaves them guessing (IDEAS #23).
        #
        # The new name is FORMAT-EXPANDED by tmux, the target is not: "proj#Sx"
        # was stored as "proj<this session>x" while the dialog said "renamed to
        # proj#Sx".  esc_fmt is the escape, and the status line reads the name
        # back from tmux (by ID, which a rename does not change) rather than
        # echoing what was typed.
        _err=""
        esc_fmt "$new_name"
        case "$SPEC_TYPE" in
          S) _err=$(tmux rename-session -t "$target" -- "$REPLY" 2>&1) ;;
          W) _err=$(tmux rename-window  -t "$target" -- "$REPLY" 2>&1) ;;
        esac
        if [ $? -eq 0 ]; then
          case "$SPEC_TYPE" in
            S) _got=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null) ;;
            W) _got=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) ;;
          esac
          sanitize_args "${_got:-$new_name}"
          dialog_status "${GREEN}✓ renamed to ${REPLY}${RST}"
        else
          _err="${_err//$'\n'/ }"
          [ "${#_err}" -gt $(( DLG_W - 12 )) ] && _err="${_err:0:DLG_W-13}…"
          dialog_status "${RED}✗ ${_err:-failed to rename}${RST}"
          sleep 0.9
        fi
        sleep 0.35
      fi
      dialog_close
      ;;

    zoom)
      # Bound via execute-silent (no terminal handover) — errors go to
      # the tmux status line instead of a dialog.
      if [ "$SPEC_TYPE" != "P" ]; then
        imux_msg "only panes can be zoomed"
        exit 0
      fi
      tmux resize-pane -Z -t "$target" 2>/dev/null || imux_msg "failed to toggle zoom"
      ;;

    detach)
      if [ "$SPEC_TYPE" != "S" ]; then
        info_flash "$BOLD_AMBER" "Detach" "Only sessions can be detached."
        exit 0
      fi
      if confirm_dialog "$BOLD_AMBER" "Detach clients from ${label}?"; then
        if tmux detach-client -s "$target" 2>/dev/null; then
          dialog_status "${GREEN}✓ detached${RST}"
        else
          dialog_status "${RED}✗ failed to detach${RST}"
        fi
        sleep 0.35
      fi
      dialog_close
      ;;

    send)
      input_dialog "$BOLD_AMBER" "Send keys to ${label}" "❯ " "" "$SEND_NOTE"
      send_cmd="$REPLY"
      if [ -n "$send_cmd" ]; then
        # Build list of pane targets to send to
        send_targets=()
        case "$SPEC_TYPE" in
          P)
            send_targets+=("$target")
            ;;
          W)
            # All panes in this window
            while read -r pidx; do
              send_targets+=("$pidx")
            done < <(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null)
            ;;
          S)
            # All panes in all windows of this session
            while read -r pidx; do
              send_targets+=("$pidx")
            done < <(tmux list-panes -s -t "$target" -F '#{pane_id}' 2>/dev/null)
            ;;
        esac

        sent=0 failed=0
        for t in "${send_targets[@]}"; do
          # send_input: a lone key name pressed, any other text typed
          # literally with a trailing ';' intact, and a pane in copy-mode
          # taken out of it first so the command actually runs
          if send_input "$t" "$send_cmd" 2>/dev/null; then
            sent=$((sent + 1))
          else
            failed=$((failed + 1))
          fi
        done

        if [ "$failed" -eq 0 ]; then
          dialog_status "${GREEN}✓ sent to ${sent} pane(s)${RST}"
        else
          dialog_status "${RED}✗ sent to ${sent} pane(s), ${failed} failed${RST}"
        fi
        sleep 0.35
      fi
      dialog_close
      ;;

    schedule)
      if ! command -v at >/dev/null 2>&1; then
        info_flash "$BOLD_AMBER" "Schedule" "'at' is not installed." \
          "Without it only sub-minute delays work." "Install it, then enable its job-runner."
        exit 0
      fi

      # A scheduled command fires into ONE pane, and the job body carries one
      # pane id.  Fanning it out the way ctrl-t's send does is almost never what
      # you meant for something that runs unattended an hour later, so a window
      # or session row resolves to its ACTIVE pane — and the dialog names the
      # pane it chose, so the narrowing is never silent.
      # $target is the session/window/pane ID the guard resolved, which
      # sched_resolve narrows to its active pane.
      sched_pick="$target"
      if ! sched_resolve "$sched_pick"; then
        info_flash "$BOLD_AMBER" "Schedule" "Could not resolve a pane for ${label}."
        exit 0
      fi

      sched_when="" sched_cmd="" sched_out="" sched_rc=0
      sched_note="${DIM}5m · 90m · 2h · 17:30 · 1:10am · noon tomorrow${RST}"
      while true; do
        input_dialog "$BOLD_AMBER" "Schedule → ${SCHED_LABEL}" "when ❯ " "$sched_when" "$sched_note"
        sched_when="$REPLY"
        [ -n "$sched_when" ] || { dialog_close; exit 0; }

        # Asked once and kept across a retry: a rejected time must not cost the
        # user the command they already typed.
        if [ -z "$sched_cmd" ]; then
          input_dialog "$BOLD_AMBER" "Schedule ${sched_when} → ${SCHED_LABEL}" "❯ " "" \
            "$SEND_NOTE"
          sched_cmd="$REPLY"
          [ -n "$sched_cmd" ] || { dialog_close; exit 0; }
        fi

        # Relative shorthand.  `at` rejects a bare 1-3 digit number outright
        # ("Garbled time" — probed on this host) and needs four digits for HHMM,
        # so reading 1-3 digits as MINUTES extends its grammar without shadowing
        # anything it accepts: 1730 still means 17:30.  10# because a leading
        # zero would otherwise be parsed as octal, and 09 is not a number.
        sched_secs=""
        if [[ "$sched_when" =~ ^([0-9]+)([smhd])$ ]]; then
          case "${BASH_REMATCH[2]}" in
            s) sched_secs=$(( 10#${BASH_REMATCH[1]} )) ;;
            m) sched_secs=$(( 10#${BASH_REMATCH[1]} * 60 )) ;;
            h) sched_secs=$(( 10#${BASH_REMATCH[1]} * 3600 )) ;;
            d) sched_secs=$(( 10#${BASH_REMATCH[1]} * 86400 )) ;;
          esac
        elif [[ "$sched_when" =~ ^[0-9]{1,3}$ ]]; then
          sched_secs=$(( 10#$sched_when * 60 ))
        fi

        # Submit through our own CLI rather than re-implementing the job body:
        # the server-pid guard, the explicit socket, and the POSIX quoting for
        # atd's /bin/sh all live there and must not be forked into two copies.
        if [ -n "$sched_secs" ]; then
          sched_out=$(bash "$SCRIPT_PATH" --send-in "$sched_secs" "$SCHED_PANE" "$sched_cmd" 2>&1)
        else
          sched_out=$(bash "$SCRIPT_PATH" --send-at "$sched_when" "$SCHED_PANE" "$sched_cmd" 2>&1)
        fi
        sched_rc=$?
        [ "$sched_rc" -eq 0 ] && break

        # Nothing left to read: retrying would resubmit the same rejected spec
        # forever, because input_dialog accepts at EOF rather than cancelling.
        if [ "${_input_eof:-0}" = 1 ]; then
          dialog_status "${RED}✗ ${sched_when} was refused${RST}"
          dialog_close
          exit 0
        fi

        # at's own complaint is the useful one ("Problem in hours
        # specification…"); our "at rejected the time spec" line only repeats
        # what the user just typed.  Re-open the field that was wrong, keeping
        # its value so a one-character typo is a one-character fix.
        sched_msg=$(printf '%s\n' "$sched_out" | grep -v '^interdimux:' | head -1)
        [ -n "$sched_msg" ] || sched_msg=$(printf '%s\n' "$sched_out" | head -1)
        sched_note="${RED}✗ ${sched_msg}${RST}"
      done

      # "interdimux: job 5 at Mon Jul 28 01:10:00 2026 -> sess:0.0 (%3)"
      sched_job="" sched_at=""
      _sched_re='^interdimux: job ([0-9]+) at (.*) -> '
      if [[ "$sched_out" =~ $_sched_re ]]; then
        sched_job="${BASH_REMATCH[1]}"; sched_at="${BASH_REMATCH[2]}"
      fi

      dlg_fit "$sched_cmd" 60; sched_cmd_disp="$REPLY"
      if [ -n "$sched_job" ]; then
        # Showing the RESOLVED time is the whole point of this screen: "1:10am"
        # is tomorrow, and "13:00" typed at 13:31 is also tomorrow.  Undo is
        # offered here rather than making the user go find the Jobs view, which
        # is where they would only look if they already suspected a mistake.
        sched_dlg=(
          "${GREEN}✓${RST} ${BOLD}${sched_at}${RST}"
          "${DIM}→${RST} ${SCHED_LABEL} ${DIM}(${SCHED_PANE})${RST}"
          "${DIM}\$${RST} ${sched_cmd_disp}"
        )
        # The job is queued; it only RUNS if at's job-runner is active (atd, or
        # atrun on macOS — which ships disabled).  A bare green ✓ would be a lie
        # on such a host, so surface the one thing between "scheduled" and "ran".
        # Only when the runner is CONFIRMED down — never on an "unknown" probe.
        if [ "$(at_daemon_state)" = down ]; then
          sched_dlg+=( "${RED}won't fire — at's job-runner is off (see --doctor)${RST}" )
        fi
        dialog_open "$BOLD_AMBER" "Scheduled" "${sched_dlg[@]}"
        dialog_status "$(hint u undo 'any key' close)"
        drain_input
        sched_key=""
        tty_fd && IFS= read -rsn1 -u "$REPLY" sched_key 2>/dev/null
        if [[ "$sched_key" =~ ^[uU]$ ]]; then
          if bash "$SCRIPT_PATH" --sched-cancel "$sched_job" >/dev/null 2>&1; then
            dialog_status "${GREEN}✓ cancelled job ${sched_job}${RST}"
          else
            dialog_status "${RED}✗ could not cancel job ${sched_job}${RST}"
          fi
          sleep 0.5
        fi
      else
        # The sub-minute path runs on a tmux timer, which has no job id to
        # cancel and dies with the server.  Say so rather than imply a queue.
        info_flash "$BOLD_AMBER" "Scheduled" \
          "${GREEN}✓${RST} in ${sched_when} ${DIM}→${RST} ${SCHED_LABEL} ${DIM}(${SCHED_PANE})${RST}" \
          "${DIM}\$${RST} ${sched_cmd_disp}" \
          "${DIM}tmux timer — cannot be cancelled, lost if the server exits${RST}"
      fi
      dialog_close
      ;;

    swap)
      case "$SPEC_TYPE" in
        W|P) ;;
        *)
          info_flash "$BOLD_AMBER" "Swap" "Only windows and panes can be swapped."
          exit 0
          ;;
      esac

      # Call gather_targets directly (subprocess would hit set -euo issues)
      swap_list=$(gather_targets)
      case "$SPEC_TYPE" in
        W) swap_list=$(printf '%s\n' "$swap_list" | grep $'\tW:' || true) ;;
        P) swap_list=$(printf '%s\n' "$swap_list" | grep $'\tP:' || true) ;;
      esac
      [ -z "$swap_list" ] && { info_flash "$BOLD_AMBER" "Swap" "No valid swap targets."; exit 0; }

      # Name the SOURCE in the prompt.  The destination list looks exactly like
      # the navigator's, so a picker headed only "swap with ❯" gave no way to
      # tell which of the two ends you had already chosen -- and swapping the
      # wrong pair is not obviously wrong until you look for the window you
      # meant to move.  parse_spec already ran on "$spec" for the type check
      # above, so the label is free.
      # $label is the guard's: it names the window or what runs in the pane,
      # the same words the dialogs use.
      _swap_src="$label"
      # A session name can contain a newline, which a prompt cannot.
      _swap_src="${_swap_src//$'\n'/ }"

      printf '\033[2J\033[H' >>"$tty_out"
      HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
      _swap_freeze=(--no-hscroll)
      fzf_ge 67 && _swap_freeze=(--freeze-left=1)
      hint_flag enter 'swap destination' 2 esc cancel 1
      dest=$(printf '%s\n' "$swap_list" | fzf \
        "${FZF_THEME[@]}" \
        "${_swap_freeze[@]}" \
        --delimiter=$'\t' \
        --with-nth=1..3 \
        --nth=1,3 \
        --prompt="swap $_swap_src with ❯ " \
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
      ) || exit 0

      dest_spec="${dest##*	}"
      parse_spec "$dest_spec"
      dest_target=$(spec_target)
      # The destination was listed when this picker opened, and may have
      # closed since: checked by index, as the source was, and swapped by ID.
      # A stale "=s:=3" finds a window NAMED "3" -- and swapped with it.
      if ! spec_at "$dest_target"; then
        imux_msg "$(spec_label) no longer exists, so nothing was swapped"
        exit 0
      fi
      dest_target="$SPEC_AT"

      # The source is the ID the guard resolved before the picker opened.
      parse_spec "$spec"
      src_target="$target"

      case "$SPEC_TYPE" in
        W) tmux swap-window -s "$src_target" -t "$dest_target" 2>/dev/null ;;
        P) tmux swap-pane   -s "$src_target" -t "$dest_target" 2>/dev/null ;;
      esac

      if [ $? -ne 0 ]; then
        imux_msg "swap failed"
      fi
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Directory picker header (called by fzf transform-header)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dirs-hints" ]; then
  # 40, not the navigator's 50: this picker's preview is unconditional and 40%
  # wide, and it is reached through an `execute` child that has inherited the
  # navigator's FZF_PREVIEW_COLUMNS, so nothing here can be auto-detected.
  HINT_PREVIEW_PCT=40
  case "${2:-default}" in
    # The deep/browse forms lead with a STATUS (the text being searched), not a
    # hint, so they are left to truncate the way any status does — the escape
    # hatch they would otherwise lose (^r) is on the prompt as well.
    deep)   printf '%s%s\n' "$(hint '🔎 deep search' "${3:-}")" "   $(hint ^r reset esc cancel)" ;;
    browse) printf '%s%s\n' "$(hint '⤷ browsing' "${3:-}")" "   $(hint ^r reset esc cancel)" ;;
    *)      hint_bar_r enter create 2 ^f 'deep search' 5 ^g 'browse into' 4 ^r reset 3 esc cancel 1
            [ -n "$REPLY" ] && printf '%s\n' "$REPLY" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# New session from directory (ctrl-o)
# ---------------------------------------------------------------------------
#
# Exits 0 after creating/switching, non-zero when cancelled (the
# navigator's ctrl-o binding uses this to decide whether to reopen).

if [ "${1:-}" = "--dirs" ]; then
  set +e

  # Optional live deep search: re-scan as the query changes.  The
  # scanner is the matcher then — fzf's own filtering is disabled, since
  # it would re-filter against the trimmed *display* path and hide rows
  # whose matching text was elided into "…/".
  dirs_extra=()
  ctrl_f_extra=""
  if [ "$DIRS_LIVE" = "on" ]; then
    dirs_extra+=(--disabled)
    dirs_extra+=(--bind="change:reload:sleep 0.1; bash '$SCRIPT_PATH' --dirs-list --deep {q}")
  else
    # Same display-path pitfall on ctrl-f: clear the query once the deep
    # results load, so none of them are pre-hidden by the text that
    # produced them (the header keeps showing what was searched)
    ctrl_f_extra="+clear-query"
  fi
  fzf_ge 61 && dirs_extra+=(--ghost='directory name or path')

  # Empty state (IDEAS #28).  A fruitless deep search leaves a blank panel with
  # no visible way out: the list is gone and nothing says that ^r puts the
  # default view back.
  #
  # The PROMPT carries it, not the header: ^f and ^g already own the header via
  # transform-header, and a `result` bind restoring a default would clobber the
  # "deep search"/"browse" header they had just set.  The prompt is unowned, and
  # it is where the eye already is while typing.
  #
  # ONE bind on `result`, dispatching on the count -- not a `zero` bind plus a
  # `result` bind.  Both events fire when the list empties, and `result` runs
  # last: the pair rendered the message and then immediately overwrote it, so
  # nothing was visible at all (verified in a real pty before this was changed).
  #
  # FZF_MATCH_COUNT needs fzf >= 0.51, the same floor as the inline callbacks.
  if fzf_ge 51; then
    dirs_extra+=(--bind="result:transform-prompt:[ \"\${FZF_MATCH_COUNT:-1}\" -eq 0 ] && printf '%s' '∅ nothing matched · ^r resets ❯ ' || printf '%s' 'new session ❯ '")
  fi

  # The default header is static and this process already has the builder —
  # re-exec'ing the whole script for it cost ~18 ms of dead time before the
  # picker could open.  (The ctrl-f/ctrl-g binds still call --dirs-hints:
  # theirs are per-mode and carry the live query.)
  HINT_PREVIEW_PCT=40
  hint_flag enter create 2 ^f 'deep search' 5 ^g 'browse into' 4 ^r reset 3 esc cancel 1

  # Every --dirs-list reload and every --dirs-preview cursor move asks
  # is_remote_path: classify the mount table once, here, for all of them.
  mounts_export

  # pipefail off for THIS pipeline only, exactly as the navigator's
  # `gather_targets | fzf` needs it.  --dirs-list is a slow STREAMING producer --
  # a filesystem scan, measured at 76 ms with the default config and 4.85 s
  # against a 1500-directory tree -- so accepting a row before the scan finishes
  # closes the pipe under it and it dies with SIGPIPE.  Verified:
  # `--dirs-list | head -1` leaves PIPESTATUS "141 0".  With pipefail on, the
  # substitution reports that 141 rather than fzf's 0, `|| exit 1` reads it as a
  # cancel, and the directory the user just picked is silently never opened.
  #
  # PIPESTATUS is no help here: inside a command substitution it describes the
  # substitution, not the inner pipeline, and ${PIPESTATUS[1]} is fatal under
  # `set -u`.
  #
  # Restoring AFTER the `|| exit 1` is deliberate: the cancel path leaves the
  # process, and the enclosing --dirs block already runs under `set +e`.
  set +o pipefail
  selected=$(bash "$SCRIPT_PATH" --dirs-list | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=1..2 \
    --nth=1 \
    --prompt='new session ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
    --preview="bash '$SCRIPT_PATH' --dirs-preview {-1}" \
    --preview-window="right,40%,border-left,nowrap" \
    --bind="ctrl-f:reload(bash '$SCRIPT_PATH' --dirs-list --deep {q})+transform-$HINT_BAR(bash '$SCRIPT_PATH' --dirs-hints deep {q})${ctrl_f_extra}" \
    --bind="ctrl-g:reload(bash '$SCRIPT_PATH' --dirs-list --scan {-1})+transform-$HINT_BAR(bash '$SCRIPT_PATH' --dirs-hints browse {-1})" \
    --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --dirs-list)+transform-$HINT_BAR(bash '$SCRIPT_PATH' --dirs-hints)" \
    ${dirs_extra[@]+"${dirs_extra[@]}"} \
  ) || exit 1
  set -o pipefail

  dir_path="${selected##*	}"
  dir_path="${dir_path%/}"
  [ -z "$dir_path" ] && exit 1
  # Physical path, so comparisons match finder output (which resolves symlinks)
  dir_path=$(cd "$dir_path" 2>/dev/null && pwd -P || echo "$dir_path")

  record_dir_use "$dir_path"
  connect_dir "$dir_path"
  exit 0
fi

# ---------------------------------------------------------------------------
# List-only mode (used by fzf reload binding)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--list" ]; then
  set +e
  gather_targets
  exit 0
fi

# --jump N — switch to the Nth session in the picker's own order, no popup.
#
# With the default MRU ordering the current session is parked last, so N=1 is
# the previous session, N=2 the one before that, and so on: a fixed number is a
# fixed destination for as long as you do not visit anything else.  That is the
# whole point — muscle memory needs the target not to move, which a fuzzy query
# cannot promise.
#
# The order comes from gather_targets rather than a second sort here, so "the
# Nth session" means exactly the Nth session the picker would show, under
# @interdimux-order 'mru' or 'index' alike.  Duplicating the sort would let the
# two drift, and a jump that lands somewhere other than the row you counted is
# worse than no jump at all.
#
# Bindable on its own for a two-keystroke hop with no popup:
#   bind-key -n M-2 run-shell -b "bash …/interdimux.sh --jump 2"
# and bound to alt-1..alt-5 inside the navigator.
if [ "${1:-}" = "--jump" ]; then
  set +e
  _jn="${2:-}"
  case "$_jn" in
    ''|*[!0-9]*) echo "interdimux: usage: --jump N (1-based)" >&2; exit 2 ;;
  esac
  [ "$_jn" -ge 1 ] || { echo "interdimux: --jump is 1-based" >&2; exit 2; }

  _jt=$(gather_targets 2>/dev/null | awk -F'\t' -v n="$_jn" '
    $4 ~ /^S:/ { c++; if (c == n) { print substr($4, 3); exit } }')
  if [ -z "$_jt" ]; then
    imux_msg "no session #$_jn"
    exit 1
  fi
  # The same target the picker's Enter would use (a "$1" or "c:d" name cannot
  # be spelled "=name"), and the client that pressed the key -- not whichever
  # one tmux thinks was active last.
  parse_spec "S:$_jt"
  tmux switch-client ${TMUX_C[@]+"${TMUX_C[@]}"} -t "$(spec_target)" 2>/dev/null || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Popup launcher — single source of popup chrome (border, title, size)
# ---------------------------------------------------------------------------

# Script path with single quotes escaped, for embedding in tmux command
# strings
# (SQ_SCRIPT is precomputed next to SCRIPT_PATH — see the top of the file.)

# Resolved options forwarded into the popup, so the navigator and every
# fzf-spawned subprocess (header/preview/reload, which run on each
# cursor move) skip the tmux option round-trips.
env_fwd_vars() {
  ENV_FWD=(
    "INTERDIMUX_SHOW_PREVIEW=$SHOW_PREVIEW"
    "INTERDIMUX_SHOW_FULL_COMMAND=$SHOW_FULL_COMMAND"
    "INTERDIMUX_SHOW_GIT_BRANCH=$SHOW_GIT_BRANCH"
    "INTERDIMUX_POPUP_WIDTH=$POPUP_WIDTH"
    "INTERDIMUX_POPUP_HEIGHT=$POPUP_HEIGHT"
    "INTERDIMUX_ORDER=$ORDER"
    "INTERDIMUX_FZF_OPTS=$FZF_USER_OPTS"
    "INTERDIMUX_RECENT_LIMIT=$RECENT_LIMIT"
    "INTERDIMUX_SCAN_DEPTH=$SCAN_DEPTH"
    "INTERDIMUX_USE_ZOXIDE=$USE_ZOXIDE"
    "INTERDIMUX_DIRS_LIVE=$DIRS_LIVE"
    "INTERDIMUX_PROJECT_MARKERS=$EXTRA_MARKERS"
    "INTERDIMUX_STARTUP_COMMAND=$STARTUP_COMMAND"
    "INTERDIMUX_HYDRATE=$HYDRATE"
    "INTERDIMUX_SHOW_DIRS=$SHOW_DIRS"
    "INTERDIMUX_DIRS_LIMIT=$DIRS_LIMIT"
    "INTERDIMUX_RAW=$RAW_MODE"
    "INTERDIMUX_HIDE=$HIDE_PATTERNS"
    "INTERDIMUX_SESSION_RULE=$SESSION_RULE"
    "INTERDIMUX_SCOPE_HIGHLIGHT=$SCOPE_HIGHLIGHT"
    "INTERDIMUX_SHOW_TITLE=$SHOW_TITLE"
    "INTERDIMUX_TITLE_MAX=$TITLE_MAX"
    "INTERDIMUX_AGENTS=$AGENT_NAMES"
    "INTERDIMUX_AGENT_ARGS=$AGENT_ARGS"
    "INTERDIMUX_AGENT_STATE=$AGENT_STATE"
    "INTERDIMUX_CLAUDE_DIR=$CLAUDE_DIR"
    "INTERDIMUX_TITLE_RULES=$TITLE_RULES_FILE"
    "INTERDIMUX_COLOR_ACCENT=$COLOR_ACCENT"
    "INTERDIMUX_COLOR_PATH=$COLOR_PATH"
    "INTERDIMUX_COLOR_GIT=$COLOR_GIT"
    "INTERDIMUX_COLOR_SSH=$COLOR_SSH"
    "INTERDIMUX_COLOR_EDITOR=$COLOR_EDITOR"
    "INTERDIMUX_COLOR_SUCCESS=$COLOR_SUCCESS"
    "INTERDIMUX_COLOR_DANGER=$COLOR_DANGER"
    "INTERDIMUX_COLOR_TREE=$COLOR_TREE"
    "INTERDIMUX_COLOR_SEPARATOR=$COLOR_SEPARATOR"
    "INTERDIMUX_COLOR_QUERY=$COLOR_QUERY"
    "INTERDIMUX_COLOR_MATCH_CURRENT=$COLOR_MATCH_CURRENT"
    "INTERDIMUX_COLOR_CURRENT_BG=$COLOR_CURRENT_BG"
    "INTERDIMUX_COLOR_HEADER=$COLOR_HEADER"
    "INTERDIMUX_COLOR_BORDER=$COLOR_BORDER"
    "INTERDIMUX_COLOR_MENU_SEL_FG=$COLOR_MENU_SEL_FG"
    "INTERDIMUX_FZF_MINOR=$FZF_MINOR"
    "INTERDIMUX_TMUX_VNUM=$TMUX_VNUM"
    # Tells the child that every option above was already resolved, so
    # load_tmux_opts can skip its tmux round-trip even when a value is empty.
    # Every get_opt env var MUST be forwarded above for this to be correct --
    # tests/test_config_fwd.sh enforces that.
    "INTERDIMUX_OPTS_PRIMED=1"
  )
}

# On tmux >= 3.3 the vars ride in as display-popup -e flags — no shell
# parsing at all, so a fish/dash default-shell can't break them.
env_fwd_flags() {
  local kv
  ENV_FWD_FLAGS=()
  env_fwd_vars
  for kv in "${ENV_FWD[@]}"; do ENV_FWD_FLAGS+=(-e "$kv"); done
}

# tmux 3.2 fallback (no -e): an `env` prefix on the popup command — a
# plain command word, so it also survives non-POSIX job shells.
build_env_fwd() {
  local kv out="env"
  env_fwd_vars
  # POSIX quoting, not %q — the popup command is run by a job shell we do not
  # control, and an option value may hold a newline (@interdimux-startup-command
  # is multi-line by design).  See shq().
  for kv in "${ENV_FWD[@]}"; do shq "$kv"; out+=" $REPLY"; done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# --doctor — tell the user what is wrong instead of failing quietly
# ---------------------------------------------------------------------------
#
# Everything here used to be a silent no-op or a mangled popup:
#
#   * a mistyped option name.  `@interdimux-fzf-opt` (no 's') is not an error
#     to tmux -- user options are free-form -- so the setting simply never
#     applied and the user had no way to tell.
#   * an out-of-domain value.  `@interdimux-order 'recent'` fell through to mru,
#     `@interdimux-show-preview 'true'` read as off.
#   * a '#' anywhere in the install path.  The prefix+f binding is built with
#     `run-shell -bC`, which FORMAT-EXPANDS its argument, so a '#' in the path
#     is eaten at keypress and the binding silently opens nothing.
#   * an unwritable state dir, which turns every recent-dir write into stderr
#     noise painted over the popup.
#
# Deliberately NOT part of the startup path: the hot path already validates the
# three numeric options it would otherwise crash on, and nothing else here is
# worth a millisecond on every open.
if [ "${1:-}" = "--doctor" ]; then
  set +e
  _doc_fail=0

  # Buffered rather than streamed, so the SUMMARY can come first.  In a popup the
  # first line is the one you actually read, and "3 problems" up top is the whole
  # point of running this; a count at the bottom of a scrolling report is a count
  # you have to go looking for.  The checks take well under 100 ms, so there is
  # nothing to stream.
  # Appended, not printf'd: a command substitution per check is ~30 forks for a
  # report, and this file does not spend forks it does not have to.
  # Buffering stdout is not enough: a check that writes to STDERR streams
  # straight past the buffer and lands ABOVE the title, so the first line of the
  # Health popup becomes a bash error.  Divert it for the duration of the checks
  # and fold whatever arrives into the report, where it belongs — a check that
  # errors is itself a finding.
  _derr="${TMPDIR:-/tmp}/interdimux-doctor-err.$$"
  if : > "$_derr" 2>/dev/null; then exec 3>&2 2>"$_derr"; else _derr=""; fi

  _doc="" _n_ok=0 _n_warn=0 _n_bad=0
  _ok()   { _doc+=$'  \033[32m✓\033[0m '"$1"$'\n'; _n_ok=$((_n_ok + 1)); }
  _warn() { _doc+=$'  \033[33m⚠\033[0m '"$1"$'\n'; _n_warn=$((_n_warn + 1)); }
  _bad()  { _doc+=$'  \033[31m✗\033[0m '"$1"$'\n'; _n_bad=$((_n_bad + 1)); _doc_fail=1; }
  _note() { _doc+=$'      \033[2m'"$1"$'\033[0m\n'; }
  # A run of '─', fork-free.  Sets REPLY.
  _rule() { local n="$1"; [ "$n" -lt 0 ] && n=0; printf -v REPLY '%*s' "$n" ''; REPLY="${REPLY// /─}"; }
  # A section heading, with a rule out to the report width.
  _sec()  {
    _rule $(( _doc_w - ${#1} - 1 ))
    _doc+=$'\n\033[1m'"$1"$'\033[0m \033[2m'"$REPLY"$'\033[0m\n'
  }

  # Width to lay the report out in.  In a popup this is the popup; fzf keeps a
  # couple of columns for its gutter and scrollbar, hence the margin.  Capped
  # because a rule 150 cells wide is not structure, it is noise.
  # -6, not -4: in the Health popup this is drawn INSIDE fzf, which takes two
  # cells of gutter and keeps the last column for its scrollbar.  At -4 the title
  # row was one cell over on a 44-column popup and fzf ellipsized the summary the
  # whole rewrite exists to put first.
  term_cols_r; _doc_w=$(( REPLY - 6 ))
  [ "$_doc_w" -gt 96 ] && _doc_w=96
  # No floor beyond 1.  A floor is the wrong shape for this: any floor WIDER than
  # the display puts the ellipsis back, which is the one thing the layout has to
  # avoid, and it does so on exactly the narrow popup a floor was meant to help.
  [ "$_doc_w" -lt 1 ] && _doc_w=1

  # Read once here: the scheduling note below wants it, and the key-bindings
  # section further down re-reads it in its own idiom.
  _dk_early=$(tmux show-option -gqv @interdimux-dashboard-key 2>/dev/null); _dk_early="${_dk_early:-g}"

  _sec environment

  # The environment the popups actually run in.  prefix+f's display-popup and
  # every run-shell binding start their command from the tmux SERVER's
  # environment — the global one, overlaid by the session's — not from the shell
  # this was typed into, and the two differ in exactly the cases worth
  # diagnosing: fzf on PATH only through a shell rc, a locale only a login
  # profile exports, an $FZF_DEFAULT_OPTS set after the server started.  Every
  # check of that kind below reads it from here.  Run from the Health popup the
  # two are the same, so either way the answer is the popup's.
  #
  # One dump per scope, not a query per name: each is a tmux round-trip.  Both
  # are parsed once into a map, session scope over global, the way tmux merges
  # them; `-NAME` is tmux's "removed".  (Matching each lookup against the raw
  # dumps instead cost more than every other check here together: a glob over a
  # few KB of environment, per name, per scope.)
  declare -A _senv_v=() _senv_sc=()
  _senv_load() { # $1 = a show-environment dump, $2 = its scope: g or s
    local line name IFS=$'\n'
    local -a lines=()
    set -f; lines=($1); set +f
    for line in ${lines[@]+"${lines[@]}"}; do
      case "$line" in
        -*) name="${line#-}" ;;
        *=*) name="${line%%=*}" ;;
        *) continue ;;
      esac
      # A line of a value that spans lines is not a variable; this skips most.
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      if [ "$line" = "-$name" ]; then unset "_senv_v[$name]"
      else _senv_v["$name"]="${line#*=}"
      fi
      _senv_sc["$name"]="$2"
    done
  }
  _senv_ok=0
  if _senv_dump=$(tmux show-environment -g 2>/dev/null); then
    _senv_ok=1
    _senv_load "$_senv_dump" g
    _senv_dump=$(tmux show-environment ${TMUX_PANE:+-t "$TMUX_PANE"} 2>/dev/null) \
      && _senv_load "$_senv_dump" s
  fi
  # $1 = a variable name.  Sets REPLY to the value a popup would get and returns
  # 0, or returns 1 when a popup would not have it at all.  $2 = exact re-reads
  # the value on its own, because a dump line holds only the first line of a
  # value that spans several — and $FZF_DEFAULT_OPTS often does.  When tmux could
  # not be asked at all, this process's own value stands in.
  _srv_env() {
    local line
    if [ "$_senv_ok" = 0 ]; then
      [ -n "${!1+set}" ] || return 1
      REPLY="${!1}"
      return 0
    fi
    [ -n "${_senv_v[$1]+set}" ] || return 1
    REPLY="${_senv_v[$1]}"
    if [ "${2:-}" = exact ]; then
      if [ "${_senv_sc[$1]}" = s ]; then
        line=$(tmux show-environment ${TMUX_PANE:+-t "$TMUX_PANE"} "$1" 2>/dev/null) && REPLY="${line#*=}"
      else
        line=$(tmux show-environment -g "$1" 2>/dev/null) && REPLY="${line#*=}"
      fi
    fi
    return 0
  }

  # The version every check branches on is TMUX_VNUM (forwarded by the binding,
  # or parsed from `tmux -V` at startup), so that is the one named — spelled the
  # way tmux spells it (3.7b) when the two agree.  Printing a fresh `tmux -V`
  # while branching on something else let this line name one version and judge
  # another.
  _tvs=$(tmux -V 2>/dev/null); _tvs="${_tvs#tmux }"
  _tv_same=0
  [[ "$_tvs" =~ ([0-9]+)\.([0-9]+) ]] \
    && [ $(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} )) = "$TMUX_VNUM" ] \
    && _tv_same=1
  if [ "$_tv_same" = 0 ]; then
    if [ "$TMUX_VNUM" = 999 ]; then _tvs="${_tvs:-of unknown version}"   # unparseable: assumed modern
    else _tvs="$(( TMUX_VNUM / 100 )).$(( TMUX_VNUM % 100 ))"
    fi
  fi
  # 3.6 is a floor, not a preference.  Every row is delimited with a raw US byte
  # inside a `-F` format, and tmux 3.5a and older rewrite that byte as the four
  # characters `\037`: each row then parses as ONE field, and the picker is simply
  # blank — measured 3.4 -> 0 rows, 3.5a -> 0, 3.6 -> all of them (README,
  # docs/CI.md).  Those are the versions stock Ubuntu 24.04 and Debian 13 ship,
  # which makes this the likeliest real failure there is — and it used to get a
  # green tick here.
  if [ "$TMUX_VNUM" -lt 306 ]; then
    _bad "tmux $_tvs is older than 3.6 — it rewrites the row delimiter as \\037, so the picker lists nothing"
    _note "Ubuntu 24.04 ships 3.4 and Debian 13 ships 3.5a: build tmux from source, or use a backport"
  else
    _ok "tmux $_tvs (fast prefix-key binding available)"
  fi

  # fzf and bash as the popups will find them.  Only the tmux server's PATH
  # counts, and nothing on the way sources a shell rc: run-shell runs /bin/sh on
  # it, display-popup a non-interactive default-shell.  So "fzf is on my PATH"
  # in a terminal proves nothing about either — this used to say ✓ from a shell
  # that had fzf while every popup closed the moment it opened, and never looked
  # at bash, whose version is a hard floor too.
  #
  # `command -v` against a PATH that is not ours, without a fork, searched the
  # way a POSIX shell searches it: each element as written.  That is how the
  # popups' `bash` is found (by /bin/sh, or the default-shell).  fzf is found by
  # bash, which searches differently; see the probe below.  Sets REPLY.
  _which_in() {
    local d
    local -a dirs=()
    IFS=: read -r -a dirs <<< "$1"
    for d in ${dirs[@]+"${dirs[@]}"}; do
      [ -n "$d" ] || d=.
      if [ -f "$d/$2" ] && [ -x "$d/$2" ]; then REPLY="$d/$2"; return 0; fi
    done
    return 1
  }
  # _spath_ok, not a test on _spath: an EMPTY PATH is still the one the popups get.
  _spath="" _spath_ok=0 _sfzf="" _sbash=""
  if _srv_env PATH; then
    _spath="$REPLY" _spath_ok=1
    _which_in "$_spath" bash && _sbash="$REPLY"
  fi

  # The locale the popups get, gathered here because the same probe measures it
  # (the check itself is further down, with the others about text).
  _lc_env=(env -u LC_ALL -u LC_CTYPE -u LANG) _lc_name="" _lc_var=""
  for _lv in LANG LC_CTYPE LC_ALL; do     # rising precedence: the last one set wins
    _srv_env "$_lv" || continue
    _lc_env+=("$_lv=$REPLY")
    [ -n "$REPLY" ] && { _lc_name="$REPLY"; _lc_var="$_lv"; }
  done
  # ONE bash started the way a popup starts it — the server's PATH picks it and
  # is its PATH, the server's locale configures it — reports its version, how
  # many characters it counts in two box-drawing ones (2 in UTF-8; 6 when it is
  # counting bytes), and which fzf it would run.
  #
  # That last is bash's OWN command search, because bash is what runs fzf for
  # every picker, and it is not the literal one above: bash tilde-expands a PATH
  # element.  A `~/.local/bin` quoted into PATH by mistake works in every popup,
  # and a literal lookup called fzf missing and exited 1 on a working setup.
  # $HOME is the server's, since that is the one the popup's bash expands.
  # With no bash on that PATH, this process's own stands in.
  _pr_env=("${_lc_env[@]}")
  if [ "$_spath_ok" = 1 ]; then
    _pr_env+=("PATH=$_spath")
    _srv_env HOME && _pr_env+=("HOME=$REPLY")
  fi
  _pv=$("${_pr_env[@]}" "${_sbash:-$BASH}" -c \
          'printf "%s %s %s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${#1}"; printf fzf:; type -P fzf' _ '├─' \
          2>/dev/null </dev/null)
  read -r _sbmaj _sbmin _lc_w _ <<< "${_pv%%$'\n'*}"
  # No "fzf:" line means the probe did not run at all (a bash that cannot start
  # is its own finding, below); the literal search is then the best there is.
  case "$_pv" in
    *$'\n'fzf:*) _sfzf="${_pv##*$'\n'fzf:}" ;;
    *) [ "$_spath_ok" = 1 ] && _which_in "$_spath" fzf && _sfzf="$REPLY" ;;
  esac

  # The fzf every picker runs is that one, so it is the one judged, by its own
  # --version.  Not this shell's, and not $FZF_MINOR either, which is this
  # process's or whatever --bind-keys baked into the binding: judged from here,
  # a distro's 0.38 ahead of the fzf you installed got "✓ fzf 0.74" and exit 0
  # while every popup failed to start, and a shell with no fzf at all got "not
  # on PATH" from a server that had one.  This shell's fzf stands in only when
  # tmux has no PATH to give.  (`hash` is bash's search without the fork a
  # $(type -P) costs; BASH_CMDS then holds what it found.)
  _myfzf=""; hash fzf 2>/dev/null && _myfzf="${BASH_CMDS[fzf]:-}"
  if [ "$_spath_ok" = 1 ]; then _jfzf="$_sfzf"; else _jfzf="$_myfzf"; fi
  _fzv=""
  if [ -n "$_jfzf" ]; then
    # The version with the user's defaults kept out of it: fzf parses those
    # before it looks at --version, so a bad $FZF_DEFAULT_OPTS made this line
    # print no version at all.  Whether fzf accepts them is its own check below.
    _fzv=$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$_jfzf" --version 2>/dev/null </dev/null)
    _fzv="${_fzv%% *}"
    # The minor the tiers compare, derived as the preflight derives FZF_MINOR:
    # a 1.x is past all of them.
    _fzm=""
    if [[ "$_fzv" =~ ^([0-9]+)\.([0-9]+) ]]; then
      _fzm=$(( 10#${BASH_REMATCH[2]} ))
      [ $(( 10#${BASH_REMATCH[1]} )) -gt 0 ] && _fzm=999
    fi
    # Below 0.40 the preflight refuses to start a picker at all (--doctor alone
    # is let past it, to say so here).
    if   [ -z "$_fzm" ];        then _warn "could not ask the fzf the popups run its version ($_jfzf)"
    elif [ "$_fzm" -lt 40 ];    then _bad "fzf $_fzv is older than 0.40 — the picker refuses to start"
    elif [ "$_fzm" -ge 74 ];    then _ok "fzf $_fzv (raw filter mode available)"
    elif [ "$_fzm" -ge 67 ];    then _warn "fzf $_fzv — 0.74 adds raw mode, which stops the tree collapsing as you type"
    elif [ "$_fzm" -ge 66 ];    then _warn "fzf $_fzv — 0.67 adds --freeze-left, which keeps a row's identity while a long command scrolls"
    elif [ "$_fzm" -ge 63 ];    then _warn "fzf $_fzv — 0.66 dims the columns the ^] scope is not searching"
    elif [ "$_fzm" -ge 58 ];    then _warn "fzf $_fzv — 0.63 moves the key hints to a footer, so the top of the list stops twitching"
    else _warn "fzf $_fzv — old, but supported (0.58 adds the ^] match scope)"
    fi
    # Which fzf that was, when this shell would have named another.  A different
    # path is only worth a word as a different version: a distro's old package
    # ahead of the one you installed is the usual shape.
    if [ "$_jfzf" != "$_myfzf" ]; then
      if [ -z "$_myfzf" ]; then
        _note "that is $_jfzf, on the tmux server's PATH — this shell finds none, which the popups do not mind"
      else
        _myfzv=$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$_myfzf" --version 2>/dev/null </dev/null)
        _myfzv="${_myfzv%% *}"
        [ "$_myfzv" != "$_fzv" ] \
          && _note "that is $_jfzf, first on the tmux server's PATH — this shell's is ${_myfzv:-another one}, at $_myfzf"
      fi
    fi
  elif [ "$_spath_ok" = 1 ]; then
    _bad "fzf is not on the tmux server's PATH — every popup closes the moment it opens"
    _note "the server's PATH: $_spath"
    _note "for the running server: tmux set-environment -g PATH \"\$PATH\", from a shell that finds fzf"
  else
    _bad "fzf is not on PATH"
    _note "it must be on the PATH the TMUX SERVER inherited, not just your shell's"
  fi

  if [ "$_spath_ok" = 1 ]; then
    # bash >= 4.3: namerefs (`local -n`, which every option read goes through)
    # are 4.3, `[[ -v arr[k] ]]` and printf's %(...)T are 4.2.  macOS's /bin/bash
    # is 3.2 and dies at the first `declare -A`, before anything can draw — and it
    # is the bash a server PATH without Homebrew's finds.
    if [ -z "$_sbash" ]; then
      _bad "bash is not on the tmux server's PATH — every binding runs it by name"
      _note "the server's PATH: $_spath"
    elif ! [[ "${_sbmaj:-}" =~ ^[0-9]+$ && "${_sbmin:-}" =~ ^[0-9]+$ ]]; then
      _warn "could not ask the bash on the tmux server's PATH its version ($_sbash)"
    elif [ $(( _sbmaj * 100 + _sbmin )) -lt 403 ]; then
      _bad "bash $_sbmaj.$_sbmin on the tmux server's PATH is older than 4.3 — every popup dies before it draws"
      _note "$_sbash: install a newer bash, and put it ahead of that one on the server's PATH"
    else
      _ok "bash $_sbmaj.$_sbmin on the tmux server's PATH"
    fi
  fi

  _repo="${SCRIPT_PATH%/scripts/*}"
  # What to do about a helper that is missing or stale.  The build command only
  # where there is a cargo to run it -- this used to tell a machine with no Rust
  # at all to run cargo.  rustup's own directory counts too: a PATH that only a
  # shell rc extends (~/.cargo/env) is the usual way to have cargo and not find
  # it.  Then what interdimux.tmux's background build is doing, if anything: a
  # build under way, or one that failed, is the answer to "why is it missing".
  _cargo=""
  if command -v cargo >/dev/null 2>&1; then _cargo=cargo
  elif [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]; then _cargo="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
  fi
  _build_hint() { # $1 = build | rebuild
    local first last blog="$SCHED_LOGDIR/build.log"
    if [ ! -f "$_repo/rust/Cargo.toml" ]; then
      _note "this install has no rust/ sources to build: point INTERDIMUX_BIN at a prebuilt imux"
      _note "for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
      return 0
    elif [ -n "$_cargo" ]; then
      _note "$1 it with: (cd '$_repo/rust' && $_cargo build --release)"
    else
      _note "no cargo here: install Rust (https://rustup.rs) and $1 it, or point INTERDIMUX_BIN at a prebuilt imux"
      _note "for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
    fi
    if imux_autobuild_running "$_repo"; then
      _note "the plugin is building it in the background right now: $blog"
    elif [ -s "$blog" ] && IFS= read -r first < "$blog" \
         && case "$first" in "== building $_repo/rust "*) true ;; *) false ;; esac; then
      last=$(tail -n 1 "$blog" 2>/dev/null)
      case "$last" in "== failed"*) _note "the plugin's last build of it failed: $blog" ;; esac
    fi
  }
  # The helper the POPUPS run, picked the way the top of this file picks it, but
  # from the tmux server's environment: that is where INTERDIMUX_BIN belongs
  # (`tmux set-environment -g`, as the notes here advise), and it is the one a
  # popup starts from.  Judged from this process's own, a doctor run from a
  # terminal vetted the in-repo build while every popup ran whatever the
  # server's INTERDIMUX_BIN named.  Run from the Health popup the two agree.
  _pur=on; _srv_env INTERDIMUX_USE_RUST && _pur="${REPLY:-on}"
  _pib="";  _srv_env INTERDIMUX_BIN && _pib="$REPLY"
  _pbin="" _prefused=0
  if [ "$_pur" != off ]; then
    for _c in "$_pib" "$_repo/rust/target/release/imux" "$_repo/bin/imux"; do
      if [ -n "$_c" ] && [ -x "$_c" ]; then _pbin="$_c"; break; fi
    done
  fi
  if [ -n "$_pbin" ]; then
    # Ask it what it is.  The helper is picked by an -x test, which any
    # executable passes, and this used to give a green tick to whatever printed
    # anything at all — `/bin/ls` got "✓ ls (GNU coreutils) 9.4".  The real one
    # answers "imux <version>".  </dev/null: something that reads stdin instead
    # must not hang the report.
    if _v=$("$_pbin" --version 2>/dev/null </dev/null) && [ -n "$_v" ]; then
      case "$_v" in
        'imux '*)
          # ...and whether it speaks THIS script's protocol, the way the list
          # asks: a build from other sources -- the usual state after a `git
          # pull` or a TPM update, neither of which rebuilds rust/ -- answers
          # --version like any other and is then refused on every draw
          # (imux_refused).  It used to get a green tick here, before any list
          # had been drawn and after.  Exit 2 is the refusal; a build that
          # speaks IMUX_PROTO reads the empty stdin and exits 3, at once.
          "$_pbin" "$IMUX_PROTO" </dev/null >/dev/null 2>&1
          if [ "$?" = 2 ]; then
            _prefused=1
            _bad "$_pbin is from another version of interdimux (it does not speak $IMUX_PROTO): the list uses the slower bash renderer"
            if [ "$_pbin" = "$_repo/rust/target/release/imux" ]; then
              _build_hint rebuild
            else
              _note "rebuild it, or point INTERDIMUX_BIN at a build of this version"
              _note "for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
            fi
          else
            _ok "$_v at $_pbin"
          fi ;;
        *) _bad "$_pbin is not the interdimux helper — its --version says: ${_v%%$'\n'*}"
           _note "the list notices, and falls back to the slow bash renderer; point INTERDIMUX_BIN at an imux build" ;;
      esac
    else
      _bad "rust helper at $_pbin is present but does not run"
      _build_hint rebuild
    fi
  elif [ "$_pur" = off ]; then
    _warn "rust helper disabled by INTERDIMUX_USE_RUST=off"
  else
    _warn "rust helper not found — falling back to the minimal bash renderer"
    _build_hint build
  fi
  # The shell this was typed into is the obvious place to look, and the wrong
  # one; say so when it would have picked differently.
  [ "$_pbin" != "${IMUX_BIN:-}" ] \
    && _note "that is the tmux server's pick, which the popups get — this shell's environment picks ${IMUX_BIN:-the bash renderer}"
  # An INTERDIMUX_BIN that is not executable is skipped in favour of the in-repo
  # build, silently — the line above then names a different binary than the one
  # asked for, with nothing to say why.
  if [ -n "$_pib" ] && [ "$_pur" != off ] && [ "$_pbin" != "$_pib" ]; then
    _warn "INTERDIMUX_BIN=$_pib is not an executable file, so it is ignored"
  fi

  # The MRU order is stable only because the sort is: without `-s`, GNU sort
  # breaks a tie in session_last_attached (one-second resolution, so ties are
  # routine) with its last-resort comparison, which orders by the user's
  # COLLATION — and the Rust core, which sorts stably, then disagrees with the
  # bash fallback about the order of the list.  `-s` is the one non-POSIX flag
  # this file relies on (GNU, BSD and busybox all have it), and a sort that
  # rejected it would empty the session list outright, so it is verified rather
  # than assumed.
  if printf 'b\na\n' | sort -s >/dev/null 2>&1; then
    _ok "sort -s is supported (the session order is stable, and locale-free)"
  else
    _bad "this sort rejects -s — the session list would come out empty"
    _note "the MRU sort needs it; it is present in GNU, BSD and busybox sort"
  fi

  # The tree glyphs and every width calculation assume UTF-8.  Without it the
  # box-drawing characters arrive as mojibake and the column arithmetic — which
  # counts CELLS — is measuring something the terminal is not drawing.
  #
  # Measured, not read off the name, and in the popups' environment.  A UTF-8
  # locale that is named but not installed — LANG sent over ssh to a host that
  # never generated it, a minimal container — makes bash fall back to C: ${#…}
  # counts BYTES, every column misaligns, and every bash the navigator starts
  # prints a setlocale warning.  The name looked perfect, so this used to say ✓.
  # The probe near the top of this section counted the characters in a bash
  # started with the popups' locale (_lc_w).
  #
  # "<chars>:<name>".  An empty count means the probe itself could not run, and
  # then the name is all there is to go on.
  case "$_lc_w:$_lc_name" in
    2:*|:*[Uu][Tt][Ff]*8*)
      _ok "character encoding is UTF-8 (${_lc_name:-the system default})" ;;
    *:*[Uu][Tt][Ff]*8*)
      _bad "locale '$_lc_name' is not installed — bash falls back to C and counts bytes, so every column misaligns"
      _note "generate it (locale-gen $_lc_name), or give tmux one that exists: tmux set-environment -g $_lc_var C.UTF-8"
      _note "it is also what bash's 'setlocale: cannot change locale' warning is about" ;;
    *:)
      _warn "no locale is set — the tree glyphs need a UTF-8 one"
      _note "export LANG=C.UTF-8 (or your own) where the tmux SERVER can see it" ;;
    *)
      _warn "locale '$_lc_name' is not UTF-8 — the tree glyphs will be mojibake"
      _note "the column widths count cells, so a non-UTF-8 terminal misaligns them" ;;
  esac
  # The shell this was typed into is the obvious place to look, and the wrong
  # one; say so when it disagrees.
  _lc_self="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [ "$_lc_self" != "$_lc_name" ] \
    && _note "that is the tmux server's locale, which the popups get — this shell's is '${_lc_self:-unset}'"

  # $FZF_DEFAULT_OPTS (and _FILE) is applied to every picker before this tool's
  # own flags and is invisible to the option validator below, which only reads
  # @interdimux-fzf-opts.  The server's copy, again: it is the one the pickers get.
  _fdo="" _fdof=""
  _srv_env FZF_DEFAULT_OPTS exact && _fdo="$REPLY"
  _srv_env FZF_DEFAULT_OPTS_FILE && _fdof="$REPLY"

  # Whether fzf takes them at all is the one thing here that can break a picker.
  # fzf parses its defaults before any flag, so one option it does not know — a
  # typo, a flag from a newer fzf — makes EVERY picker exit before it draws, and
  # --version is enough to find out.  Asked of the fzf the popups run.
  #
  # Nothing else in them can.  build_fzf_theme resets what people usually put
  # there — --tmux/--popup, --height, --border, --margin, --padding, --style,
  # --with-shell, and every colour — on each fzf that parses the flag, and an
  # fzf too old to parse one rejects it here.  This used to warn about those
  # very flags, and to advise moving them to @interdimux-fzf-opts: the one place
  # they DO take effect, since it comes after the resets.  Following it turned a
  # harmless global setting into the nested frame and shrunk list the resets
  # exist to prevent.  (Whether the flags there are sensible is the option
  # check's business, and a deliberate choice's.)
  if { [ -n "$_fdo" ] || [ -n "$_fdof" ]; } && [ -n "$_jfzf" ]; then
    if ! _fe=$(FZF_DEFAULT_OPTS="$_fdo" FZF_DEFAULT_OPTS_FILE="$_fdof" "$_jfzf" --version 2>&1 >/dev/null </dev/null); then
      _bad "fzf rejects its default options — every picker exits before it draws"
      _note "${_fe%%$'\n'*}"
      [ "$_fdo" != "${FZF_DEFAULT_OPTS:-}" ] \
        && _note "that is the tmux server's \$FZF_DEFAULT_OPTS, which the pickers get — this shell's differs"
    else
      if [ -n "$_fdo" ] && [ -n "$_fdof" ]; then
        _ok "\$FZF_DEFAULT_OPTS and \$FZF_DEFAULT_OPTS_FILE are set, and fzf accepts them — the pickers reset their layout and colours"
      elif [ -n "$_fdo" ]; then
        _ok "\$FZF_DEFAULT_OPTS is set, and fzf accepts it — the pickers reset its layout and colours"
      else
        _ok "\$FZF_DEFAULT_OPTS_FILE is set, and fzf accepts it — the pickers reset its layout and colours"
      fi
      _note "--tmux/--popup, --height, --border, --margin, --padding, --style and --with-shell are all overridden;"
      _note "@interdimux-fzf-opts is where a deliberate one goes"
    fi
  fi

  # A binary older than the sources it was built from renders differently from
  # the bash fallback, and the difference is silent — the picker still opens.
  # Only when the binary belongs to THIS checkout.  One installed elsewhere has
  # no relationship to these sources, and a fresh clone — which stamps every
  # source with the checkout time — would otherwise report it stale for ever.
  # -type f as well, or find returns the start directory and it takes one of the
  # three slots below.  The popups' helper, as picked above.
  # Not for one the protocol check above refused: the list does not run it at
  # all, and that line has already said to rebuild it.
  if [ -n "$_pbin" ] && [ "$_prefused" = 0 ] && [ -d "$_repo/rust/src" ] \
     && case "$_pbin" in "$_repo"/*) true ;; *) false ;; esac; then
    _newer=$(find "$_repo/rust/src" "$_repo/rust/Cargo.toml" -type f -newer "$_pbin" 2>/dev/null | head -3)
    if [ -n "$_newer" ]; then
      _warn "the rust helper is older than its sources — it is rendering last build's layout"
      while IFS= read -r _nf; do [ -n "$_nf" ] && _note "newer: ${_nf#"$_repo/"}"; done <<< "$_newer"
      _build_hint rebuild
    fi
  fi

  if command -v at >/dev/null 2>&1; then
    _ok "at is installed (Schedule, --send-at / --send-in beyond a minute)"
    # `at` without its job-runner accepts jobs, queues them, and never fires
    # them — silently.  The only symptom is a command that did not run, hours
    # later, which is exactly the failure this tool must not have.  The runner is
    # atd on Linux and atrun (launchd) on macOS; at_daemon_state knows the
    # difference and reads each without root, and says so honestly when it cannot
    # tell (BSD's cron-atrun, or a host without pgrep) rather than crying wolf.
    _npend=$(atq -q "$SCHED_QUEUE" 2>/dev/null | grep -c . || true)
    case "${_npend:-0}" in
      0) ;;
      1) _note "1 command is scheduled — see it under Jobs on the dashboard" ;;
      *) _note "$_npend commands are scheduled — see them under Jobs on the dashboard" ;;
    esac
    case "$(at_daemon_state)" in
      up)   _ok "at's job-runner is active — scheduled jobs will fire" ;;
      down) _bad "at's job-runner is not active — jobs would queue but never fire"
            _note "enable it: $(at_enable_hint)" ;;
      *)    _note "could not verify at's job-runner from here — ensure it is enabled" ;;
    esac
  else
    _warn "at is not installed — only sub-minute delays work (tmux's own timer)"
    _note "install it, then enable its job-runner, for the dashboard's Schedule entry"
  fi

  # A '#' is handled (SQ_SCRIPT_FMT doubles it, so tmux's format expansion gives
  # the path back).  A single quote is NOT: verified by driving a real key press
  # from such a path, the popup never opened -- tmux's command parser re-escapes
  # the '\'' sequence and the shell then sees a different string.  Report it
  # rather than pretend, because the symptom is a key that does nothing at all.
  case "$SCRIPT_PATH" in
    *"'"*) _bad "the install path contains a single quote: $SCRIPT_PATH"
           _note "the key bindings cannot survive it — move the install somewhere without one" ;;
    *'#'*) _ok "install path contains '#', which is escaped for tmux format expansion" ;;
    *)     _ok "install path is safe to embed in a key binding" ;;
  esac

  # The navigator routes its stderr to a log rather than painting it over the
  # list, so this is the one place a past failure is still visible.
  if [ -s "$SCHED_LOGDIR/errors.log" ]; then
    _last=$(grep -c '^== ' "$SCHED_LOGDIR/errors.log" 2>/dev/null || echo 0)
    _bad "the navigator has logged $_last error(s)"
    _note "most recent: $(grep -A1 '^== ' "$SCHED_LOGDIR/errors.log" | tail -1)"
    _note "full log: $SCHED_LOGDIR/errors.log"
  else
    _ok "no navigator errors logged"
  fi

  for _d in "${XDG_DATA_HOME:-$HOME/.local/share}/interdimux" "$SCHED_LOGDIR"; do
    if mkdir -p "$_d" 2>/dev/null && [ -w "$_d" ]; then
      _ok "writable: $_d"
    else
      _bad "not writable: $_d"
      _note "recent directories and the scheduled-keys log cannot be saved"
    fi
  done

  # Where the navigator keeps its scratch files (the resume flag, the preview
  # state, the stderr it reports): $XDG_RUNTIME_DIR when it is usable, else
  # $TMPDIR — as the popups' environment has them.  A tmp dir that was gone or
  # full used to end the navigator before it drew, with nothing here to say why.
  # It falls back to the state dir now, so this is a warning, unless that one is
  # unwritable too, which the line above reports.  A real file, not `-w`: a full
  # disk passes -w.
  _srt=""
  _srv_env XDG_RUNTIME_DIR && _srt="$REPLY"
  _stmp=/tmp
  _srv_env TMPDIR && [ -n "$REPLY" ] && _stmp="$REPLY"
  if [ -n "$_srt" ] && [ -d "$_srt" ] && [ -w "$_srt" ]; then
    _ok "writable: $_srt (the navigator's scratch files)"
  elif _tf=$(mktemp "$_stmp/interdimux-doctor.XXXXXX" 2>/dev/null); then
    rm -f "$_tf"
    _ok "writable: $_stmp (the navigator's scratch files)"
  else
    _warn "cannot create a file in $_stmp — the navigator keeps its scratch files in $SCHED_LOGDIR instead"
    _note "that is \$TMPDIR as the tmux server has it (or /tmp): tmux show-environment -g TMPDIR"
  fi

  # --- key bindings -----------------------------------------------------------
  _sec 'key bindings'
  _k=$(tmux show-option -gqv @interdimux-key);           _k="${_k:-f}"
  _dk=$(tmux show-option -gqv @interdimux-dashboard-key); _dk="${_dk:-g}"
  # Read the table once and match the key column ourselves: `list-keys -T prefix
  # <key>` prints nothing on tmux 3.7b, so filtering with it silently reports
  # every binding as missing.
  # Here-strings, not `printf … | grep -q`: grep -q exits at its first match,
  # and a printf still writing the rest of the table then dies of SIGPIPE —
  # which pipefail (on for this whole file) turns into "no match".  Under load,
  # or with a big enough table, the report said no bindings were installed.
  _keytable=$(tmux list-keys -T prefix 2>/dev/null)
  if grep -q interdimux <<< "$_keytable"; then
    for _pair in "$_k:navigator" "$_dk:dashboard"; do
      _key="${_pair%%:*}"; _what="${_pair#*:}"
      if awk -v k="$_key" '$2=="-T" && $3=="prefix" && $4==k && /interdimux/ { f = 1 }
                           END { exit !f }' <<< "$_keytable"; then
        _ok "prefix+$_key opens the $_what"
      else
        _bad "prefix+$_key is not bound to the $_what"
        _note "reload the plugin, or run: bash '$SCRIPT_PATH' --bind-keys"
      fi
    done
  else
    _bad "no interdimux key bindings are installed"
    _note "run: bash '$SCRIPT_PATH' --bind-keys"
  fi

  # The dashboard is a native menu when it fits and an fzf popup when it does
  # not, and BOTH have silently drawn nothing in the past when the client was too
  # short: display-menu exits 0 without painting, display-popup refuses a size
  # larger than the client.  Both are guarded now, so this is not a failure — but
  # it is worth saying which one the user is about to get, because they look
  # different and "prefix+g looks wrong" is otherwise unexplainable.
  client_dim '#{client_height}'; _dh="$REPLY"
  client_dim '#{client_width}';  _dwid="$REPLY"
  if [ "$_dh" = 0 ]; then
    _note "no client attached here, so the dashboard's size could not be checked"
  elif ! tmux_ge 304; then
    _note "tmux < 3.4: the dashboard is the fzf popup, not a native menu"
  elif [ "$_dh" -ge "$MENU_ROWS" ]; then
    _ok "the client is ${_dwid}x${_dh} — the dashboard draws as a native menu"
  else
    _warn "the client is only $_dh rows — the dashboard falls back to the fzf popup"
    _note "the native menu needs $MENU_ROWS rows; the popup version scrolls instead"
  fi

  # --- options ----------------------------------------------------------------
  _sec options
  # Names the code understands but that are not in OPT_MAP: they are read
  # directly rather than forwarded to the popup.
  # (No `binary`: the helper's path is read from $INTERDIMUX_BIN only, and an
  # option by that name was once accepted here and green-ticked while nothing
  # read it.  Unknown now, so setting it says so.)
  # (`autobuild` is read by interdimux.tmux, at plugin load.)
  _known=("${OPT_NAMES[@]}" key dashboard-key project-dirs jump-keys autobuild)

  _is_known() { local n; for n in "${_known[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }

  # Longest-common-prefix suggestion.  Crude on purpose: the realistic typo is a
  # dropped or doubled character, not an anagram.
  _suggest() {
    local want="$1" n i best="" bestlen=0 len
    for n in "${_known[@]}"; do
      len=0
      for (( i = 0; i < ${#want} && i < ${#n}; i++ )); do
        [ "${want:i:1}" = "${n:i:1}" ] || break
        len=$((len + 1))
      done
      [ "$len" -gt "$bestlen" ] && { bestlen="$len"; best="$n"; }
    done
    [ "$bestlen" -ge 4 ] && REPLY="$best" || REPLY=""
  }

  # A value's domain, by option name.  Empty always means "unset, use default".
  _check_value() { # $1 = name, $2 = value -> prints a complaint, or nothing
    local n="$1" v="$2" _d
    [ -n "$v" ] || return 0
    case "$n" in
      show-preview|show-full-command|show-git-branch|use-zoxide|dirs-live-search|hydrate|show-dirs|raw|session-rule|scope-highlight|autobuild)
        case "$v" in on|off) ;; *) printf "expected 'on' or 'off'" ;; esac ;;
      order)
        case "$v" in mru|index) ;; *) printf "expected 'mru' or 'index'" ;; esac ;;
      # The agent options, in the terms the script replaces a bad value in
      # (right after the get_opt calls): the default, which for agent-args is
      # off and for agent-state on -- so a `yes` does the opposite of what it
      # says for one of them.
      agent-args)
        case "$v" in on|off) ;; *) printf "expected 'on' or 'off', so it stays off" ;; esac ;;
      agent-state)
        case "$v" in on|off) ;; *) printf "expected 'on' or 'off', so it stays on" ;; esac ;;
      show-title)
        case "$v" in known|all|off) ;; *) printf "expected 'known', 'all' or 'off', so it stays known" ;; esac ;;
      title-max)
        # Decimal whatever the leading zeros, then clamped to 8..200.
        case "$v" in
          *[!0-9]*) printf 'expected a whole number from 8 to 200, so the default, 40, applies' ;;
          *) _d="${v#"${v%%[!0]*}"}"; _d="${_d:-0}"
             if [ "${#_d}" -gt 3 ] || [ "$_d" -gt 200 ]; then printf 'the most is 200, so 200 applies'
             elif [ "$_d" -lt 8 ]; then printf 'the least is 8, so 8 applies'
             fi ;;
        esac ;;
      agents)
        # `off`, or names: a word with anything but letters, digits, '.', '_'
        # and '-' is skipped (AGENT_KNOWN), and says nothing where it is.
        local _w _skip=""
        if [ "$v" != off ]; then
          set -f
          for _w in $v; do
            case "$_w" in *[!A-Za-z0-9._-]*) _skip+="${_skip:+, }'$_w'" ;; esac
          done
          set +f
          [ -z "$_skip" ] || printf 'skipped: %s (a name is letters, digits, dots, underscores and hyphens)' "$_skip"
        fi ;;
      recent-limit|dirs-limit|scan-depth)
        case "$v" in ''|*[!0-9]*) printf 'expected a whole number' ;; esac
        # Decimal, whatever the leading zeros, as the script reads it; and the
        # length first, as there: `[ -gt ]` on a 20-digit number is an error.
        [ "$n" = scan-depth ] && case "$v" in ''|*[!0-9]*) ;; *)
          _d="${v#"${v%%[!0]*}"}"; _d="${_d:-0}"
          { [ "${#_d}" -gt 2 ] || [ "$_d" -gt 10 ]; } && printf 'deeper than 10 will not finish inside a popup' ;; esac ;;
      popup-width|popup-height)
        case "$v" in *%) case "${v%\%}" in ''|*[!0-9]*) printf 'expected NN or NN%%' ;; esac ;;
                     ''|*[!0-9]*) printf 'expected NN or NN%%' ;; esac ;;
      color-*)
        # Exactly: '#' and six hex digits, 0-255, -1, or default.  The length
        # alone let '#zzzzzz' through.  [[:xdigit:]] rather than a range: under
        # bash < 5 a range follows the locale's collation.
        case "$v" in
          default|-1) ;;
          '#'[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]) ;;
          '#'*) printf 'a hex colour must be #rrggbb' ;;
          ''|*[!0-9]*) printf 'expected #rrggbb, a 0-255 index, or default' ;;
          # Length first: `[ "$v" -le 255 ]` on a 26-digit number is not false,
          # it is "integer expression expected" ON STDERR — which used to land
          # above the report's own title.
          ????*) printf 'a colour index must be 0-255' ;;
          *) [ "$v" -le 255 ] || printf 'a colour index must be 0-255' ;;
        esac ;;
      key|dashboard-key)
        # Any key tmux can bind, not one character: --bind-keys hands the value to
        # `tmux bind-key` as it is, and C-f, M-g, F5 and Space all bind fine — a
        # length test called them wrong in the same report that confirmed them
        # bound.  So ask tmux: `list-keys -T prefix <key>` changes nothing and
        # fails with "invalid key: …" on exactly what bind-key would refuse ('ff',
        # 'C-', 'X-f').  By that text, not by its exit status: tmux 3.6 — the
        # floor — ALSO fails, with "unknown key: …", for a perfectly good key that
        # is merely not bound in the prefix table yet (3.7 dropped that).  So a
        # key set after the plugin loaded, the very case this report exists for,
        # was called unknown while the message listed it as an example.
        # A bare ';' is the one it cannot judge — tmux reads it as a command
        # separator, so the query "succeeds" and the binding never happens.
        local _ke
        case "$v" in
          ';') printf "tmux reads a bare ';' as a command separator, so it cannot be bound this way" ;;
          *)   _ke=$(tmux list-keys -T prefix "$v" 2>&1 >/dev/null) \
                 || case "$_ke" in
                      'invalid key'*) printf 'not a key tmux knows (e.g. f, C-f, M-g, F5, Space)' ;;
                    esac ;;
        esac ;;
      fzf-opts)
        # Two ways this option silently does nothing, both checked the way the
        # pickers meet the value.  build_fzf_theme evals it into words and, when
        # that fails, drops the WHOLE set — on purpose, so a stray quote cannot
        # kill every picker — without a word.  And the words reach fzf last, so
        # one it does not know makes every picker exit before it draws.  fzf
        # parses every flag before it honours --version, so that finds it; its
        # own defaults are kept out, so they are not blamed on this.  (The eval
        # is the one the navigator runs on every open, so it risks nothing new.)
        # The parse is tried in a subshell of its own first: this runs inside
        # $(…), and there a syntax error in eval ends the whole subshell instead
        # of failing the command — which printed nothing, i.e. "✓".
        local -a _u=()
        if ! ( eval "_u=($v)" ) 2>/dev/null; then
          printf 'does not parse as shell words (an unbalanced quote?), so none of it applies'
          return 0
        fi
        eval "_u=($v)" 2>/dev/null
        # --tmux/--popup here is not what it is in $FZF_DEFAULT_OPTS, which the
        # theme cancels: these words come last, so nothing overrides them.
        local _w _pop=""
        for _w in ${_u[@]+"${_u[@]}"}; do
          case "$_w" in
            --tmux|--tmux=*|--popup|--popup=*) _pop="${_w%%=*}" ;;
            --no-tmux|--no-popup)              _pop="" ;;
          esac
        done
        if [ -n "$_pop" ]; then
          printf '%s makes fzf open a popup of its own, underneath the one the picker is in, which stays blank' "$_pop"
          return 0
        fi
        # The fzf the popups run, as the environment section found it.
        local _e
        if [ -n "$_jfzf" ] \
           && ! _e=$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$_jfzf" --version ${_u[@]+"${_u[@]}"} 2>&1 >/dev/null </dev/null); then
          printf 'fzf rejects it, so every picker exits before it draws: %s' "${_e%%$'\n'*}"
        fi ;;
      jump-keys)
        # space-separated tmux key specs; the count is what maps to #1, #2, …
        case "$v" in *[!A-Za-z0-9\ ^\-]*) printf 'expected space-separated tmux keys, e.g. "M-1 M-2 M-3"' ;; esac ;;
    esac
  }

  # Every @interdimux-* actually set, global and session scope.  Each line comes
  # tagged with its scope (g/s), so a value can be re-read from the right one.
  _seen=0
  while IFS= read -r _line; do
    _scope="${_line%% *}"; _line="${_line#* }"
    _name="${_line%% *}"; _name="${_name#@interdimux-}"
    _val="${_line#* }"; [ "$_val" = "$_line" ] && _val=""
    # show-options prints a value the way tmux's own parser would need it: in
    # quotes, with \" \$ and \\ escaped, so `--bind "x:y"` comes out as
    # "--bind \"x:y\"".  That is fine to show, but it is not the value the code
    # reads — checked in that form, a perfectly good @interdimux-fzf-opts would be
    # "rejected by fzf".  So a quoted or escaped one is read back raw to be checked.
    _raw="$_val"
    case "$_val" in
      \"*|\'*|*\\*)
        if [ "$_scope" = g ]; then _raw=$(tmux show-option -gqv "@interdimux-$_name" 2>/dev/null)
        else _raw=$(tmux show-option -qv "@interdimux-$_name" 2>/dev/null)
        fi ;;
    esac
    _val="${_val%\"}"; _val="${_val#\"}"
    _seen=$((_seen + 1))
    if ! _is_known "$_name"; then
      _suggest "$_name"
      if [ -n "$REPLY" ]; then
        _bad "unknown option @interdimux-$_name — did you mean @interdimux-$REPLY?"
      else
        _bad "unknown option @interdimux-$_name"
      fi
      [ "$_name" = binary ] \
        && _note "the helper's path comes from \$INTERDIMUX_BIN only — for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
      continue
    fi
    _why=$(_check_value "$_name" "$_raw")
    if [ -n "$_why" ]; then
      _bad "@interdimux-$_name = '$_val' — $_why"
    else
      _ok "@interdimux-$_name = '$_val'"
    fi
  done < <( { tmux show-options -g 2>/dev/null; echo '#session'; tmux show-options 2>/dev/null; } \
            | awk '$0 == "#session" { sc = "s"; next }
                   /^@interdimux-/ && !seen[$0]++ { print (sc == "" ? "g" : sc) " " $0 }' )
  [ "$_seen" = 0 ] && _note 'nothing set — every option is at its default'

  # A hide pattern that matches no session is indistinguishable from a working
  # one: the list simply looks normal.  Naming the dead pattern is the only way a
  # typo ever surfaces.
  # Read from tmux, not from $HIDE_PATTERNS.  In the Health popup the latter is
  # the value forwarded at launch, so this could contradict the option list
  # printed immediately above it — which does read tmux.  Session scope first,
  # then global, matching get_opt.
  _hv=$(tmux show-option -qv @interdimux-hide 2>/dev/null)
  [ -n "$_hv" ] || _hv=$(tmux show-option -gqv @interdimux-hide 2>/dev/null)
  if [ -n "$_hv" ]; then
    _snames=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    _cur_s=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} '#S' 2>/dev/null)
    # set -f for the same reason the hide loops themselves need it: unquoted, the
    # patterns would be pathname-expanded against the cwd first, and this check
    # would then report the FILENAMES it found rather than the patterns the user
    # set — which is how that bug was noticed.
    set -f
    for _hp in $_hv; do
      _hit=0 _hit_cur=0
      while IFS= read -r _sn; do
        [ -n "$_sn" ] || continue
        # shellcheck disable=SC2254  # the pattern is the point
        case "$_sn" in
          $_hp) if [ "$_sn" = "$_cur_s" ]; then _hit_cur=1; else _hit=1; break; fi ;;
        esac
      done <<< "$_snames"
      if [ "$_hit" = 1 ]; then
        _ok "@interdimux-hide pattern '$_hp' matches a session"
      elif [ "$_hit_cur" = 1 ]; then
        # The current session is NEVER hidden — the row marker, the popup title
        # and MRU's move-to-end all key off it — so a pattern whose only match is
        # the session you are standing in does nothing at all, and "matches a
        # session" would be a true sentence about a filter that is not running.
        _warn "@interdimux-hide pattern '$_hp' matches only the session you are in"
        _note "the current session is never hidden, so this pattern is doing nothing here"
      else
        _warn "@interdimux-hide pattern '$_hp' matches no session right now"
        _note "harmless if that session is not running; a typo looks exactly the same"
      fi
    done
    set +f
  fi

  # --- agents -----------------------------------------------------------------
  # Which of the signals a coding agent sends reach tmux, and the one setting
  # that fixes a missing one: until now the way to find out was to miss an
  # approval prompt (review AGENT-14).  Read off the installed binaries (Claude
  # Code 2.1.280-282, Codex 0.155) and reproduced on a private tmux 3.7b:
  #
  #   * a title (OSC 0/2) lands in #{pane_title} unless allow-set-title is off;
  #   * a bare BEL sets #{window_bell_flag}, the row's '!', unless monitor-bell
  #     is off.  bell-action none does not stop the flag (measured), only the
  #     bell tmux would pass on to the terminal;
  #   * a desktop notification (OSC 9/99/777) is wrapped in tmux's DCS
  #     passthrough, which no format sees.  Under allow-passthrough `on` it is
  #     forwarded only for a pane on screen, so a background agent's alert --
  #     the one that matters -- is dropped; under `off` every one is.
  #
  # Advisory, all of it: nothing here stops the picker working, so nothing here
  # is a ✗ or moves the exit status, which a health check reads as "interdimux
  # is broken".  An agent that is not installed is one dim line.  A config that
  # cannot be read, or holds a value this does not know, is "unknown", never
  # wrong: agent configs drift between versions, and drift is not the user's
  # mistake.  Read-only: no agent is started, and the only files opened are the
  # title rules, settings.json, config.toml and sessions/<digits>.json, each by
  # name -- never a credential (~/.codex/auth.json, ~/.claude/.credentials*,
  # the sessions/<pid>.<hash>.key files).
  _sec agents
  # A path with ~ for $HOME, in REPLY: they are long, and the notes quote them.
  _tl() {
    if [ -n "$HOME" ] && [ "$HOME" != / ] && [[ "$1" == "$HOME"/* ]]; then REPLY="~${1#"$HOME"}"
    else REPLY="$1"
    fi
  }
  # "1 pane", "2 panes", in REPLY.
  _nof() { if [ "$1" = 1 ]; then REPLY="1 $2"; else REPLY="$1 ${2}s"; fi; }

  # One round-trip for every tmux option below, as it applies to this pane (a
  # pane, window or session override counts, as it would for an agent here).
  # Flags come back 1/0, allow-passthrough as off/on/all.  default-terminal is
  # the TERM a pane starts with, which is what an agent picks its alerts by.
  _ag=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} \
          '#{allow-set-title}|#{monitor-bell}|#{bell-action}|#{allow-passthrough}|#{focus-events}|#{default-terminal}' 2>/dev/null)
  IFS='|' read -r _ag_title _ag_mbell _ag_bact _ag_pass _ag_focus _ag_term <<< "$_ag"
  case "$_ag_title" in
    1) _ok "tmux takes the titles programs set (allow-set-title on): what an agent says it is doing" ;;
    0) _warn "allow-set-title is off — the titles agents set (what they are working on) never reach tmux"
       _note "set -g allow-set-title on" ;;
    *) _note "allow-set-title could not be read — unknown" ;;
  esac
  case "$_ag_mbell" in
    1) _ok "a bell flags its window with ! (monitor-bell on): the one alert any agent can hand tmux"
       [ "$_ag_bact" = none ] \
         && _note "bell-action is none: the ! still appears, but tmux passes no bell on to your terminal" ;;
    0) _warn "monitor-bell is off — an agent's bell never flags its window, so no row shows it waits on you"
       _note "setw -g monitor-bell on" ;;
    *) _note "monitor-bell could not be read — unknown" ;;
  esac

  # Your title rules, read before the built-in ones.  A line that is not a rule
  # is skipped by both renderers without a word, so say which: rule_fields is
  # their own split.  The text is what title_ruleset reads -- up to a NUL, if
  # the file holds one (UTF-16) -- and a line that is not UTF-8 is one it
  # drops (review R02).
  _trf="${TITLE_RULES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/titles}"
  _tl "$_trf"; _trf_d="$REPLY"
  if [ -f "$_trf" ] && [ -r "$_trf" ]; then
    _nr=0 _ln=0 _trn=() _re_skip='^ *(#|$)' _trt="" _trnul=0
    { IFS= read -r -d '' _trt < "$_trf"; } 2>/dev/null && _trnul=1
    [ "$_trnul" = 1 ] && _trn+=("it holds a NUL byte (is it UTF-16?): nothing after the first one is read")
    while IFS= read -r _l || [ -n "$_l" ]; do
      _ln=$((_ln + 1))
      _l="${_l//[$'\t\r']/ }"
      [[ "$_l" =~ $_re_skip ]] && continue
      if ! is_utf8 "$_l"; then
        _trn+=("line $_ln is not UTF-8, so it is skipped: save the file as UTF-8")
        continue
      fi
      if ! rule_fields "$_l"; then
        _trn+=("line $_ln is not a rule (APPS STATE DESC PATTERN), so it is skipped")
        continue
      fi
      _nr=$((_nr + 1))
      case "$RULE_S" in
        -|approve|input|working|idle|done|error) ;;
        *) _trn+=("line $_ln: its STATE is not one of approve input working idle done error, or -, so the rule gives none") ;;
      esac
      [[ "$RULE_A" == @* ]] || continue
      # The names an option rule reads go into the list's tmux query, so one
      # that is not a plain option name is left out of it: never read.
      _tro=()
      IFS=, read -r -a _tro <<< "$RULE_A"
      for _o in ${_tro[@]+"${_tro[@]}"}; do
        _o="${_o#@}"
        case "$_o" in
          *[!A-Za-z0-9_-]*) _trn+=("line $_ln: @$_o is not an option name tmux can be asked for, so it is never read"); break ;;
        esac
      done
    done 2>/dev/null <<< "$_trt"
    _nof "$_nr" rule
    _ok "your title rules: $_trf_d holds $REPLY, read before the built-in ones"
    for (( _i = 0; _i < ${#_trn[@]} && _i < 5; _i++ )); do _note "${_trn[_i]}"; done
    [ "${#_trn[@]}" -gt 5 ] && _note "… and $(( ${#_trn[@]} - 5 )) more"
  elif [ -e "$_trf" ]; then
    _warn "your title rules at $_trf_d cannot be read — only the built-in ones apply"
  elif [ -n "$TITLE_RULES_FILE" ]; then
    _warn "@interdimux-title-rules names $_trf_d, which does not exist — only the built-in rules apply"
  else
    _note "title rules: none of your own ($_trf_d) — the built-in ones apply"
  fi

  # What agent plugins, or your own hooks, publish as pane options: the names
  # the list reads in its one list-panes (the built-in rules' and any your file
  # adds), each asked only whether it is set -- no value is shown.  The same
  # query gives every pane's pid, which Claude's registry is checked against
  # below.  A pane in two sessions is counted once.
  title_ruleset
  _pon=() _pfmt='#{pane_id} #{pane_pid} '
  for _o in $STATE_OPTS; do _pon+=("$_o"); _pfmt+="#{!=:#{@$_o},}"; done
  declare -A _ppid=() _pwho_n=() _pwho_o=()
  _pwho=() _npub=0
  _ag_who() {
    case "$1" in
      agent_state|agent_desc)                  REPLY='your hooks' ;;
      pane_status|pane_wait_reason)            REPLY=tmux-agent-sidebar ;;
      claude_state|codex_state|opencode_state) REPLY=tmux-agent-icons ;;
      claude_pane_status)                      REPLY=tmux-claude-status ;;
      workmux_pane_status)                     REPLY=workmux ;;
      dmux_attention)                          REPLY=dmux ;;
      *)                                       REPLY='your title rules' ;;
    esac
  }
  while IFS=' ' read -r _pid _ppd _bits; do
    [ -n "$_pid" ] && [ -z "${_ppid[$_pid]+x}" ] || continue
    _ppid[$_pid]="$_ppd"
    [[ "$_bits" == *1* ]] || continue
    _npub=$((_npub + 1))
    declare -A _pw=()
    for (( _i = 0; _i < ${#_pon[@]}; _i++ )); do
      [ "${_bits:_i:1}" = 1 ] || continue
      _ag_who "${_pon[_i]}"
      if [ -z "${_pwho_n[$REPLY]+x}" ]; then _pwho+=("$REPLY"); _pwho_n[$REPLY]=0; _pwho_o[$REPLY]=""; fi
      [[ " ${_pwho_o[$REPLY]} " == *" @${_pon[_i]} "* ]] || _pwho_o[$REPLY]+="${_pwho_o[$REPLY]:+ }@${_pon[_i]}"
      if [ -z "${_pw[$REPLY]+x}" ]; then
        _pw[$REPLY]=1 _n="${_pwho_n[$REPLY]}"
        _pwho_n[$REPLY]=$(( _n + 1 ))
      fi
    done
    unset _pw
  done <<< "$(tmux list-panes -a -F "$_pfmt" 2>/dev/null)"
  if [ "$_npub" -gt 0 ]; then
    _nof "$_npub" pane
    _ok "agent state is published on $REPLY, as options the list reads"
    for _w in ${_pwho[@]+"${_pwho[@]}"}; do
      _nof "${_pwho_n[$_w]}" pane; _o="${_pwho_o[$_w]// /, }"
      case "$_w" in
        'your hooks')       _note "your hooks publish $_o on $REPLY" ;;
        'your title rules') _note "$_o, which your title rules read, is set on $REPLY" ;;
        *)                  _note "$_w publishes $_o on $REPLY" ;;
      esac
    done
    [ "$AGENT_STATE" = on ] \
      || _note "@interdimux-agent-state is off, so no row shows any of it as a state"
  else
    _note "plugin options: no pane publishes an agent's state (@agent_state, @pane_status, …) right now"
  fi

  # An agent's alerts sent as an OSC wrapped for passthrough: where they end up.
  # $1 the agent, $2 the terminal they are meant for, $3 how they come to be
  # sent that way (a note), $4 the setting that makes them a bell instead.
  _ag_passthrough() {
    if [ "$_ag_pass" = all ]; then
      _ok "$1's notifications reach $2 from every pane (allow-passthrough all), but tmux never sees them"
      _note "$3"
      _note "no row gets a ! for them; $4 would give it one"
    else
      _warn "$1's notifications go to $2 through tmux passthrough — tmux never sees them"
      _note "$3"
      case "$_ag_pass" in
        on)  _note "allow-passthrough is on: only a pane on screen gets through — a background agent's alert is dropped" ;;
        off) _note "allow-passthrough is off: tmux drops every one of them" ;;
        *)   _note "allow-passthrough could not be read — whether any get through is unknown" ;;
      esac
      _note "to have tmux flag the window instead: $4"
      _note "or: set -g allow-passthrough all — but then any hidden pane can write to your terminal"
    fi
  }

  # Claude Code, in the directory the list reads it from: @interdimux-claude-dir,
  # else $CLAUDE_CONFIG_DIR as the tmux server has it (the environment popups
  # and new panes start from), else ~/.claude.
  _cdir="$CLAUDE_DIR"
  if [ -z "$_cdir" ]; then
    _cdir="$HOME/.claude"
    _srv_env CLAUDE_CONFIG_DIR && [ -n "$REPLY" ] && _cdir="$REPLY"
  fi
  _tl "$_cdir"; _cdir_d="$REPLY"
  # A CLAUDE_CONFIG_DIR that only this shell has is one the popups never see.
  _ccfg_note=""
  if [ -z "$CLAUDE_DIR" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${CLAUDE_CONFIG_DIR%/}" != "${_cdir%/}" ]; then
    _tl "$CLAUDE_CONFIG_DIR"
    _ccfg_note="this shell's CLAUDE_CONFIG_DIR is $REPLY, which the popups do not see: set -g @interdimux-claude-dir '$REPLY'"
  fi
  _tl "$_cdir/settings.json"; _cset_d="$REPLY"
  _tl "$_cdir/sessions"; _csd_d="$REPLY"
  if [ ! -d "$_cdir" ]; then
    _note "Claude Code: no $_cdir_d — skipped"
    [ -z "$_ccfg_note" ] || _note "$_ccfg_note"
  else
    # settings.json (the user's), read whole without a fork and only ever
    # matched against the few keys below: JSON is not parsed, and no value but
    # those is shown.  Absent is fine (every key at its default); present but
    # unreadable, or not a JSON object, is unknown.
    _cset="$_cdir/settings.json" _cs="" _cs_ok=1
    if [ -e "$_cset" ]; then
      _cs_ok=0
      if [ -f "$_cset" ] && [ -r "$_cset" ]; then
        { IFS= read -r -d '' _cs; } 2>/dev/null < "$_cset"
        [[ "$_cs" =~ ^[[:space:]]*\{ ]] && _cs_ok=1
      fi
    fi

    # CLAUDE_CODE_DISABLE_TERMINAL_TITLE, where Claude gets it: the environment
    # its pane starts with (tmux's), or settings.json's "env".  A boolean to
    # Claude (1, true, yes or on, any case; so "0" is off), and it stops every
    # title write AND the request that names the session.
    _truthy() {
      local v="${1,,}"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      case "$v" in 1|true|yes|on) return 0 ;; esac
      return 1
    }
    _re='"CLAUDE_CODE_DISABLE_TERMINAL_TITLE"[[:space:]]*:[[:space:]]*"?([^",}]*)'
    if _srv_env CLAUDE_CODE_DISABLE_TERMINAL_TITLE && _truthy "$REPLY"; then
      _warn "CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in tmux's environment — Claude sets no title, and names no session"
      if [ "${_senv_sc[CLAUDE_CODE_DISABLE_TERMINAL_TITLE]:-g}" = s ]; then
        _note "tmux set-environment -u CLAUDE_CODE_DISABLE_TERMINAL_TITLE, and drop it where it is exported"
      else
        _note "tmux set-environment -gu CLAUDE_CODE_DISABLE_TERMINAL_TITLE, and drop it where it is exported"
      fi
      _note "the list strips Claude's ✳ itself: the title is worth keeping"
    elif [ "$_cs_ok" = 1 ] && [[ "$_cs" =~ $_re ]] && _truthy "${BASH_REMATCH[1]}"; then
      _warn "CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in $_cset_d — Claude sets no title, and names no session"
      _note "remove it from that file's \"env\"; the list strips Claude's ✳ itself"
    fi

    # The session registry, the list's first source of Claude's state: one
    # sessions/<pid>.json per live interactive session.  Only <digits>.json is
    # opened -- the <pid>.<hash>.key files beside them are secrets.  A record
    # "parses" when it has what the list reads: a whole object, a pid and a
    # status.  Which of them the list believes (the process is still that one,
    # and it runs in a pane here) is claude_registry_r's own answer.
    _csd="$_cdir/sessions"
    if [ -d "$_csd" ] && ! { [ -r "$_csd" ] && [ -x "$_csd" ]; }; then
      # A glob over it would come back empty, i.e. "no session is running".
      _note "Claude Code: its session registry at $_csd_d could not be read — unknown"
    elif [ -d "$_csd" ]; then
      _nrec=0 _nodd=0 _nunr=0
      for _f in "$_csd"/*.json; do
        [[ "${_f##*/}" =~ ^[0-9]+\.json$ ]] || continue
        if ! { [ -f "$_f" ] && [ -r "$_f" ]; }; then _nunr=$((_nunr + 1)); continue; fi
        _j=""
        { IFS= read -r -N 65536 _j; } 2>/dev/null < "$_f"   # as claude_registry_r
        if [[ "$_j" == *'}' && "$_j" =~ \"pid\":[0-9]+ && "$_j" =~ \"status\":\"[a-z]+\" ]]; then
          _nrec=$((_nrec + 1))
        else
          _nodd=$((_nodd + 1))
        fi
      done
      if [ $(( _nrec + _nodd + _nunr )) = 0 ]; then
        _ok "Claude's session registry is at $_csd_d — no session is running now"
      elif [ "$_nrec" = 1 ]; then
        _ok "Claude's session registry is at $_csd_d — 1 record parses"
      else
        _ok "Claude's session registry is at $_csd_d — $_nrec records parse"
      fi
      if [ "$AGENT_STATE" != on ]; then
        _note "@interdimux-agent-state is off, so the list does not read it"
      elif [ "$_nrec" -gt 0 ]; then
        _nshow=0
        CLAUDE_DIR="$_cdir" claude_registry_r
        while IFS="$US" read -r _rp _rsid _ _; do
          [ -n "$_rp" ] && [ -n "${_ppid[$_rp]+x}" ] || continue
          [ -z "$_rsid" ] || [ "$_rsid" = "${_ppid[$_rp]}" ] || continue
          _nshow=$((_nshow + 1))
        done <<< "$CLAUDE_REG"
        case "$_nshow:$_nrec" in
          0:1) _note "it is not a live session in a pane of this tmux server" ;;
          0:*) _note "none of them is a live session in a pane of this tmux server" ;;
          1:*) _note "1 is a live session in a pane here, whose row shows Claude's state" ;;
          *)   _note "$_nshow are live sessions in panes here, whose rows show Claude's state" ;;
        esac
      fi
      case "$_nodd" in
        0) ;;
        1) _note "1 record there lacks what the list reads (a pid, a status) — unknown: the format may have changed" ;;
        *) _note "$_nodd records there lack what the list reads (a pid, a status) — unknown: the format may have changed" ;;
      esac
      case "$_nunr" in
        0) ;;
        1) _note "1 record there could not be read — unknown" ;;
        *) _note "$_nunr records there could not be read — unknown" ;;
      esac
    else
      _note "Claude Code: no session registry at $_csd_d — an older Claude writes none, and its rows then show no state"
    fi
    [ -z "$_ccfg_note" ] || _note "$_ccfg_note"

    # Where Claude's alerts go: preferredNotifChannel, default auto (a project's
    # settings, or a value an older Claude kept in ~/.claude.json, can
    # override it; neither is read here).  auto picks by TERM, which in a pane
    # is tmux's default-terminal: ghostty for xterm-ghostty, kitty for a *kitty*
    # one, and NOTHING for any other (TERM_PROGRAM is tmux's there, which names
    # no channel).  Every channel but the bell is an OSC wrapped for
    # passthrough.  The values are the installed binaries' own list.
    if [ "$_cs_ok" = 0 ]; then
      _note "Claude Code: $_cset_d could not be read — where its notifications go is unknown"
    else
      _cnc="" _re='"preferredNotifChannel"[[:space:]]*:[[:space:]]*"([^"]*)"'
      if [[ "$_cs" =~ $_re ]]; then _cnc="${BASH_REMATCH[1]}"
      elif [[ "$_cs" == *'"preferredNotifChannel"'* ]]; then _cnc='?'
      fi
      _cnc_how="preferredNotifChannel is \"$_cnc\""
      [ -n "$_cnc" ] || _cnc_how="preferredNotifChannel is not set (auto)"
      _cbell="\"preferredNotifChannel\": \"terminal_bell\" in $_cset_d"
      _via="" _osc=""
      case "${_cnc:-auto}" in
        auto)
          case "$_ag_term" in
            xterm-ghostty) _via=Ghostty _osc='OSC 777' ;;
            *kitty*)       _via=kitty   _osc='OSC 99' ;;
            '') _note "Claude Code: the panes' TERM (default-terminal) could not be read — where its notifications go is unknown" ;;
            *)  _warn "Claude sends no notifications here at all"
                _note "$_cnc_how, and auto has no channel for the panes' TERM, $_ag_term"
                _note "to have it ring the bell, which tmux flags: $_cbell" ;;
          esac ;;
        ghostty) _via=Ghostty _osc='OSC 777' ;;
        kitty)   _via=kitty   _osc='OSC 99' ;;
        iterm2)  _via=iTerm2  _osc='OSC 9' ;;
        terminal_bell|iterm2_with_bell)
          _ok "Claude rings the bell when it needs you ($_cnc_how) — tmux flags its window" ;;
        notifications_disabled)
          _note "Claude Code: its notifications are turned off ($_cnc_how)" ;;
        *) _note "Claude Code: preferredNotifChannel in $_cset_d holds a value this check does not know — unknown" ;;
      esac
      if [ -n "$_via" ]; then
        if [ -z "$_cnc" ]; then
          _ag_passthrough Claude "$_via" "$_cnc_how and the panes' TERM is $_ag_term, so Claude sends $_osc wrapped for passthrough" "$_cbell"
        else
          _ag_passthrough Claude "$_via" "$_cnc_how, so Claude sends $_osc wrapped for passthrough" "$_cbell"
        fi
      fi
      [[ "$_cs" =~ \"hooks\"[[:space:]]*: ]] \
        && _note "$_cset_d defines hooks (not inspected here), which may deliver alerts of their own"
    fi
  fi

  # Codex.  Only config.toml, and only three keys of [tui] (a dotted `tui.key =`
  # at the top level counts too): never auth.json.  Names and defaults are
  # codex-rs config/src/types.rs (0.155): notifications (true), notification_
  # method (auto), notification_condition (unfocused).  "unfocused" is why it
  # is silent in tmux: Codex starts out believing it has focus, and without
  # focus-events tmux never tells it otherwise (reproduced).
  _xdir="$HOME/.codex"
  _srv_env CODEX_HOME && [ -n "$REPLY" ] && _xdir="$REPLY"
  _tl "$_xdir"; _xdir_d="$REPLY"
  _tl "$_xdir/config.toml"; _xcfg_d="$REPLY"
  if [ ! -d "$_xdir" ]; then
    _note "Codex: no $_xdir_d — skipped"
  else
    _xcfg="$_xdir/config.toml" _xcond="" _xmeth="" _xnotif="" _x_ok=1
    if [ -e "$_xcfg" ]; then
      _x_ok=0
      if [ -f "$_xcfg" ] && [ -r "$_xcfg" ]; then
        _x_ok=1 _xsec=""
        _re='^(tui\.)?(notification_condition|notification_method|notifications)[[:space:]]*=[[:space:]]*(.*)$'
        while IFS= read -r _l || [ -n "$_l" ]; do
          _l="${_l#"${_l%%[![:space:]]*}"}"
          case "$_l" in
            '['*) _xsec="${_l#[}"; _xsec="${_xsec%%]*}"; _xsec="${_xsec//[[:space:]]/}"; continue ;;
          esac
          [[ "$_l" =~ $_re ]] || continue
          if [ -n "${BASH_REMATCH[1]}" ]; then [ -z "$_xsec" ] || continue
          else [ "$_xsec" = tui ] || continue
          fi
          _v="${BASH_REMATCH[3]%%#*}"; _v="${_v%"${_v##*[![:space:]]}"}"
          _v="${_v#[\"\']}"; _v="${_v%[\"\']}"
          case "${BASH_REMATCH[2]}" in
            notification_condition) _xcond="$_v" ;;
            notification_method)    _xmeth="$_v" ;;
            notifications)          _xnotif="$_v" ;;
          esac
        done 2>/dev/null < "$_xcfg"
      fi
    fi
    # When it notifies at all: $_xwhy says why, empty for never or unknown.
    _xwhy=""
    if [ "$_x_ok" = 0 ]; then
      _note "Codex: $_xcfg_d could not be read — whether it notifies is unknown"
    elif [ "$_xnotif" = false ]; then
      _note "Codex: its notifications are turned off ([tui] notifications = false)"
    elif [ "$_xcond" = always ]; then
      _xwhy='notification_condition "always"'
    elif [ -n "$_xcond" ] && [ "$_xcond" != unfocused ]; then
      _note "Codex: notification_condition in $_xcfg_d holds a value this check does not know — unknown"
    elif [ "$_ag_focus" = 1 ]; then
      _xwhy='focus-events on'
    elif [ "$_ag_focus" = 0 ]; then
      _warn "Codex never notifies inside tmux — focus-events is off, so it never hears that its pane lost focus"
      _note "it notifies only when unfocused (notification_condition, default \"unfocused\")"
      _note "set -g focus-events on — or in $_xcfg_d, under [tui]: notification_condition = \"always\""
    else
      _note "Codex: focus-events could not be read — whether it notifies is unknown"
    fi
    # How: a bell reaches tmux; OSC 9 is wrapped for passthrough, like Claude's.
    # auto picks OSC 9 for Ghostty, iTerm2, kitty, Warp and WezTerm, found as
    # codex-rs terminal-detection finds them under tmux (whose TERM_PROGRAM it
    # skips): these variables in the pane's environment first, then TERM.
    if [ -n "$_xwhy" ]; then
      _xterm=""
      case "${_xmeth:-auto}" in
        bel) ;;
        osc9) _xterm="your terminal" ;;
        auto)
          if _srv_env GHOSTTY_RESOURCES_DIR && [ -n "$REPLY" ]; then _xterm=Ghostty
          elif _srv_env WEZTERM_VERSION; then _xterm=WezTerm
          elif _srv_env ITERM_SESSION_ID || _srv_env ITERM_PROFILE || _srv_env ITERM_PROFILE_NAME; then _xterm=iTerm2
          elif _srv_env TERM_SESSION_ID; then :                     # Apple Terminal: a bell
          elif _srv_env KITTY_WINDOW_ID || [[ "$_ag_term" == *kitty* ]]; then _xterm=kitty
          elif _srv_env ALACRITTY_SOCKET || [ "$_ag_term" = alacritty ] || _srv_env KONSOLE_VERSION \
               || _srv_env GNOME_TERMINAL_SCREEN || _srv_env VTE_VERSION || _srv_env WT_SESSION; then :
          else
            case "$_ag_term" in
              xterm-ghostty)      _xterm=Ghostty ;;
              wezterm|wezterm-mux) _xterm=WezTerm ;;
            esac
          fi ;;
        *) _xterm='?' ;;
      esac
      if [ "$_xterm" = '?' ]; then
        _note "Codex: notification_method in $_xcfg_d holds a value this check does not know — unknown"
      elif [ -z "$_xterm" ]; then
        _ok "Codex rings the bell when it needs you ($_xwhy) — tmux flags its window"
      else
        _xmhow="notification_method is \"$_xmeth\""
        [ -n "$_xmeth" ] || _xmhow="notification_method is not set (auto)"
        _ag_passthrough Codex "$_xterm" "$_xmhow, so Codex sends OSC 9 wrapped for passthrough" \
          "notification_method = \"bel\" under [tui] in $_xcfg_d"
      fi
    fi
  fi

  # Stop diverting before anything is printed, and report what was caught.
  if [ -n "$_derr" ]; then
    exec 2>&3 3>&-
    if [ -s "$_derr" ]; then
      # A warning, not a failure: this catches BOTH a bug in a check here and a
      # legitimate complaint from something a check ran — fzf grumbling about the
      # user's own $FZF_DEFAULT_OPTS_FILE arrives on exactly this channel — and
      # from here the two are indistinguishable.  Either way it belongs in the
      # report rather than above its title.
      _sec 'stderr'
      _warn "something the checks ran wrote to stderr"
      _note "either a bug in --doctor, or a real complaint from a tool it called:"
      while IFS= read -r _el; do [ -n "$_el" ] && _note "$_el"; done < "$_derr"
    fi
    rm -f "$_derr"
  fi

  # --- the report -------------------------------------------------------------
  # Title, then the verdict, then the detail.  The verdict is a sentence rather
  # than three counts: "everything is fine" and "two things need attention" are
  # what you want to know, and the counts are right there beside it.
  _verdict='' _vcol='32'
  if [ "$_n_bad" -gt 0 ]; then
    _vcol='31'
    [ "$_n_bad" = 1 ] && _verdict='1 problem needs attention' \
                      || _verdict="$_n_bad problems need attention"
  elif [ "$_n_warn" -gt 0 ]; then
    _vcol='33'
    [ "$_n_warn" = 1 ] && _verdict='1 thing could be better' \
                       || _verdict="$_n_warn things could be better"
  else
    _verdict='everything checks out'
  fi
  # ASCII separators: the counts are measured with ${#_counts} to right-align
  # them, and ${#} counts BYTES in a non-UTF-8 locale — a '·' there is two, so
  # the title came up short by one cell per separator on exactly the setups the
  # locale check above is warning about.
  _counts="${_n_ok} ok"
  [ "$_n_warn" -gt 0 ] && _counts+=", ${_n_warn} warn"
  [ "$_n_bad" -gt 0 ]  && _counts+=", ${_n_bad} problem"
  [ "$_n_bad" -gt 1 ]  && _counts+="s"

  _rule "$_doc_w"; _hr="$REPLY"
  # Right-align the counts against the title, when there is room for it.
  _title='interdimux doctor'
  _pad=$(( _doc_w - ${#_title} - ${#_counts} ))
  if [ "$_pad" -ge 1 ]; then
    printf -v _gap '%*s' "$_pad" ''
    printf '\033[1m%s\033[0m%s\033[2m%s\033[0m\n' "$_title" "$_gap" "$_counts"
  else
    # Too narrow for both.  Drop the counts rather than run past the edge and be
    # ellipsized: the verdict on the very next line says the same thing in words,
    # so nothing is actually lost.
    printf '\033[1m%s\033[0m\n' "$_title"
  fi
  printf '\033[2m%s\033[0m\n' "$_hr"
  printf '\033[%sm%s\033[0m\n' "$_vcol" "$_verdict"
  printf '%s' "$_doc"
  printf '\033[2m%s\033[0m\n' "$_hr"
  # "then h" would be a lie on a short client: below MENU_ROWS the dashboard is
  # the fzf fallback, where letters filter rather than select.  Name the entry.
  printf '\033[2mrun again from the dashboard: prefix + %s, then Health\033[0m\n' "${_dk:-g}"

  [ "$_doc_fail" = 1 ] && exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# --doctor in a popup (the dashboard's Health entry)
# ---------------------------------------------------------------------------
#
# fzf is the pager, not `less`: it is already a hard dependency, it is already
# themed to match every other panel here, Esc already closes it, and search over
# a health report is worth having rather than something to suppress.  On
# fzf >= 0.74 --raw keeps the non-matching lines on screen, dimmed, so filtering
# narrows the report instead of shredding the sections out of it.
#
# ^r re-runs the checks in place, which is the whole point after fixing one.
if [ "${1:-}" = "--doctor-view" ]; then
  set +e
  _dv_extra=()
  if fzf_ge 74; then
    _dv_extra+=(--raw --gutter-raw=' ' --color="nomatch:${COLOR_TREE}:strip:dim")
  fi
  HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
  hint_flag '^r' recheck 2 esc close 1
  # pipefail off for THIS pipeline, the same guard the other three pickers carry:
  # --doctor exits 1 when it found a problem, and with pipefail on that status
  # would mask fzf's.
  set +o pipefail
  bash "$SCRIPT_PATH" --doctor 2>&1 | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --no-multi \
    --prompt='health ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
    ${_dv_extra[@]+"${_dv_extra[@]}"} \
    --bind="ctrl-r:reload(bash '$SQ_SCRIPT' --doctor)" \
    >/dev/null 2>&1
  set -o pipefail
  exit 0
fi

if [ "${1:-}" = "--launch" ]; then
  set +e
  mode="${2:-switch}"

  # The navigator's title names the session you are in, so there is a "you are
  # here" anchor even once the current row has scrolled out of the list.  The
  # baked prefix+f binding gets this from a tmux format for free; this path is
  # already forking, so one more round-trip costs nothing that matters.
  _cur_sess=$(tmux display-message -p ${CUR_T[@]+"${CUR_T[@]}"} '#S' 2>/dev/null) || _cur_sess=""
  title=' interdimux '
  [ -n "$_cur_sess" ] && title=" interdimux · $_cur_sess "
  case "$mode" in
    kill)   title=' interdimux · kill ' ;;
    rename) title=' interdimux · rename ' ;;
    zoom)   title=' interdimux · zoom ' ;;
    swap)   title=' interdimux · swap ' ;;
    detach) title=' interdimux · detach ' ;;
    send)   title=' interdimux · send keys ' ;;
    dirs)   title=' interdimux · new session ' ;;
    schedule) title=' interdimux · schedule ' ;;
    jobs)     title=' interdimux · scheduled jobs ' ;;
    doctor)   title=' interdimux · health ' ;;
    agents)   title=' interdimux · agents ' ;;
  esac

  # `agents` is the navigator in the agents view (VIEW): the panes that need
  # you marked, and a QUERY typed for the user that matches exactly them,
  # rather than a filtered list: raw mode dims the other rows so the tree
  # keeps its shape, the cursor lands on the first match, and a keystroke
  # widens it.  `^` and `|` are as old as fzf itself: no version split.

  sp="$SQ_SCRIPT"
  chrome=()
  if tmux_ge 303; then
    # Border style/lines are left to the user's popup-border-* options;
    # only destructive modes recolour the frame
    chrome=(-T "${POPUP_TITLE_STYLE}${title}")
    [ "$mode" = "kill" ] && chrome+=(-S "$(danger_style)")
    # Popups don't inherit TMUX_PANE — forward it so current-target detection
    # is exact.  It is the PRESSING pane only because every route here passes
    # it explicitly (the bindings' TMUX_PANE=#{pane_id}, the dashboard's baked
    # items): run-shell itself hands over the server's global TMUX_PANE, which
    # can belong to another server entirely.  The pressing client rides along
    # for the same reason (see TMUX_C).
    [ -n "${TMUX_PANE:-}" ] && chrome+=(-e "TMUX_PANE=$TMUX_PANE")
    [ -n "$INTERDIMUX_CLIENT" ] && chrome+=(-e "INTERDIMUX_CLIENT=$INTERDIMUX_CLIENT")
    env_fwd_flags
    chrome+=("${ENV_FWD_FLAGS[@]}")
    # The title rides along so popup_accent can re-send it (a style-only
    # repaint on >= 3.6 would otherwise erase it)
    chrome+=(-e "INTERDIMUX_TITLE=$title")
    case "$mode" in
      # --dirs exits non-zero on cancel (the navigator's ctrl-o resume
      # contract); as a standalone popup that would bubble up through
      # display-popup to run-shell as a "returned 1" status message —
      # absorb it here
      dirs)   chrome+=(-e "INTERDIMUX_MODE=dirs"); cmd="bash '$sp' --dirs || true" ;;
      # Not a picker over tmux targets — its own list, its own handler.
      jobs)   cmd="bash '$sp' --jobs" ;;
      doctor) cmd="bash '$sp' --doctor-view" ;;
      switch) cmd="bash '$sp'" ;;
      agents) chrome+=(-e "INTERDIMUX_VIEW=agents"); cmd="bash '$sp'" ;;
      *)      chrome+=(-e "INTERDIMUX_MODE=$mode"); cmd="bash '$sp'" ;;
    esac
  else
    env_fwd=$(build_env_fwd)
    case "$mode" in
      dirs)   cmd="$env_fwd bash '$sp' --dirs || true" ;;
      jobs)   cmd="$env_fwd bash '$sp' --jobs" ;;
      doctor) cmd="$env_fwd bash '$sp' --doctor-view" ;;
      switch) cmd="$env_fwd bash '$sp'" ;;
      agents) cmd="$env_fwd INTERDIMUX_VIEW=agents bash '$sp'" ;;
      *)      cmd="$env_fwd INTERDIMUX_MODE=$mode bash '$sp'" ;;
    esac
  fi

  # -c: open on the client that asked.  Left to tmux it lands on the most
  # recently active client, which from a menu or a popup is not reliably this
  # one (keys pressed in an overlay do not count as activity).
  exec tmux display-popup ${TMUX_C[@]+"${TMUX_C[@]}"} -w "$POPUP_WIDTH" -h "$POPUP_HEIGHT" \
    ${chrome[@]+"${chrome[@]}"} -E "$cmd"
fi

# ---------------------------------------------------------------------------
# Scheduled jobs picker
# ---------------------------------------------------------------------------
#
# Scheduling without a way to see and undo what you scheduled is a trap: the
# only other exit is `atrm` on the command line, and by then you have to know
# the queue letter.  Deliberately placed AFTER the dialog helpers — these blocks
# execute during the top-to-bottom pass, so a handler above dlg_fit's definition
# would call a function that does not exist yet.

# Rows for the picker: "<display>\t<pane>\t<id>", the last field being what
# {-1} hands to the cancel binding.
if [ "${1:-}" = "--jobs-list" ]; then
  set +e
  command -v atq >/dev/null 2>&1 || exit 0
  while IFS="$US" read -r _id _when _tgt _pane _desc; do
    [ -n "$_id" ] || continue
    # Pad the FITTED text, not the raw text: %-20s counts escape bytes as
    # columns, and a CJK session name draws at twice the width bash measures.
    dlg_fit "$_when" 18; _c1="$REPLY"; dlg_width "$_c1"
    printf -v _p1 '%*s' $(( 18 - REPLY )) ''
    dlg_fit "$_tgt" 20; _c2="$REPLY"; dlg_width "$_c2"
    printf -v _p2 '%*s' $(( 20 - REPLY )) ''
    printf '%s%s%s%s  %s%s%s%s  %s\t%s\t%s\n' \
      "$ACCENT_ESC" "$_c1" "$_p1" "$RST" \
      "$DIM" "$_c2" "$_p2" "$RST" \
      "$_desc" "$_pane" "$_id"
  done < <(sched_rows)
  exit 0
fi

if [ "${1:-}" = "--job-cancel" ]; then
  set +e
  _jid="${2:-}"
  [ -n "$_jid" ] || exit 0
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"
  trap 'printf "\033[?25h" >>"$tty_out" 2>/dev/null' EXIT

  _when="" _tgt="" _desc=""
  while IFS="$US" read -r _i _w _t _p _d; do
    [ "$_i" = "$_jid" ] && { _when="$_w"; _tgt="$_t"; _desc="$_d"; break; }
  done < <(sched_rows)
  if [ -z "$_when" ]; then
    info_flash "$BOLD_AMBER" "Cancel" "Job $_jid is no longer queued."
    dialog_close
    exit 0
  fi

  if confirm_dialog "$BOLD_AMBER" "Cancel job ${_jid}?" \
       "${DIM}${_when} →${RST} ${_tgt}" "${DIM}\$${RST} ${_desc}"; then
    # Through --sched-cancel so the "never touch a job outside our own queue"
    # guard stays in one place.
    if bash "$SCRIPT_PATH" --sched-cancel "$_jid" >/dev/null 2>&1; then
      dialog_status "${GREEN}✓ cancelled${RST}"
    else
      dialog_status "${RED}✗ could not cancel job ${_jid}${RST}"
    fi
    sleep 0.35
  fi
  dialog_close
  exit 0
fi

if [ "${1:-}" = "--jobs" ]; then
  set +e
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"
  if ! command -v atq >/dev/null 2>&1; then
    info_flash "$BOLD_AMBER" "Scheduled jobs" "'at' is not installed." \
      "Scheduling beyond a minute needs it."
    dialog_close
    exit 0
  fi
  _jl="bash '$SQ_SCRIPT' --jobs-list"
  # Read once, not twice: --jobs-list costs an `at -c` per job, and the
  # emptiness check and the picker want the same rows.
  _jrows=$(bash "$SCRIPT_PATH" --jobs-list)
  if [ -z "$_jrows" ]; then
    info_flash "$BOLD_AMBER" "Scheduled jobs" "Nothing is scheduled." \
      "Schedule one from the dashboard."
    dialog_close
    exit 0
  fi
  _jwait=""
  fzf_ge 74 && _jwait="wait+"
  HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
  hint_flag enter cancel 3 ^r reload 1 esc quit 2
  # Same guard as the other two pickers: under `set -o pipefail` an accept that
  # closes the pipe early makes the producer's SIGPIPE (141) mask fzf's status.
  # Nothing reads that status here, but the invariant is the point — the next
  # picker to be pasted from this one inherits the shape.
  set +o pipefail
  printf '%s\n' "$_jrows" | fzf \
    "${FZF_THEME[@]}" \
    --delimiter=$'\t' \
    --with-nth=1 \
    --no-sort \
    --prompt='jobs ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
    --bind="enter:${_jwait}execute(bash '$SQ_SCRIPT' --job-cancel {-1})+reload($_jl)" \
    --bind="ctrl-r:reload($_jl)" \
    >/dev/null 2>&1
  set -o pipefail
  exit 0
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

# The "who pressed the key" prefix for a `run-shell … --launch X` the dashboard
# builds, in REPLY: "TMUX_PANE=%N INTERDIMUX_CLIENT=<client> ", either part
# omitted when unknown.
#
# run-shell does NOT pass the pressing pane: its job gets the tmux SERVER's
# global environment, whose TMUX_PANE is whatever the process that started the
# server exported -- a pane of another server when it was started from inside
# tmux.  The dashboard's own binding carries the right values, but every item
# it launched dropped them, so a picker opened from prefix+g marked the wrong
# session current (or none), ordered MRU against it, and could open on another
# client.  Menu item commands are not expanded in the pressing client's
# context, so the values are baked in as literals; both are checked against a
# charset that needs no quoting in /bin/sh or tmux's parser.
launch_env_prefix() {
  REPLY=""
  [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] && REPLY+="TMUX_PANE=$TMUX_PANE "
  [ -n "$INTERDIMUX_CLIENT" ] && REPLY+="INTERDIMUX_CLIENT=$INTERDIMUX_CLIENT "
  return 0
}

# Entry point for the prefix+g binding: a native styled menu on
# tmux >= 3.4, otherwise a compact fzf menu in a popup.
if [ "${1:-}" = "--dashboard-launch" ]; then
  set +e
  sp="$SQ_SCRIPT"

  # display-menu SILENTLY draws nothing and exits 0 when the menu is taller than
  # the client.  Verified on 3.7b — no message, no error, prefix+g simply becomes
  # a dead key.  MENU_ROWS (defined next to the other geometry helpers, because
  # --doctor reports against it too) is items + 2 for the borders.
  #
  # The fzf fallback below has no such ceiling: its list scrolls.  So the tmux
  # version is not the only thing that decides which one to draw.
  #
  # The Agents entry's count asks tmux for the panes and, in the same
  # round-trip, for the client's size (AW_CLIENT); only without it is the size
  # a round-trip of its own.  No native menu below 3.4, so no count there: the
  # fzf fallback counts for itself.
  _n_agents=0 AW_CLIENT=""
  if tmux_ge 304 && [ "$AGENT_STATE" = on ]; then agents_waiting_r; _n_agents="$REPLY"; fi
  if [ -n "$AW_CLIENT" ]; then
    _cli_h="${AW_CLIENT%% *}" _cli_w="${AW_CLIENT#* }"; _cli_w="${_cli_w%% *}"
  else
    client_dims; _cli_h="${REPLY% *}" _cli_w="${REPLY#* }"
  fi
  # Unknown height takes the fallback, not the menu: a popup where a menu would
  # have done is cosmetic, and a dead prefix+g is not.
  if tmux_ge 304 && [ "$_cli_h" -ge "$MENU_ROWS" ]; then
    # Menu item commands are re-parsed by tmux's command parser when
    # selected: inside its double-quoted token, \ " $ are escapes and
    # run-shell format-expands #{...} — escape those layers on top of
    # the shell quoting so exotic install paths survive.
    menu_sp="$SQ_SCRIPT_FMT"
    menu_sp="${menu_sp//\\/\\\\}"
    menu_sp="${menu_sp//\"/\\\"}"
    menu_sp="${menu_sp//\$/\\\$}"
    launch_env_prefix
    _mp="${REPLY}bash '$menu_sp' --launch"

    # A menu item whose name begins with '-' is DISABLED: tmux dims it and drops
    # its key column (verified against 3.7b).  Offering Schedule on a box with no
    # `at`, and answering the click with an error dialog, is worse than saying up
    # front that it is unavailable.  The count rides in the Jobs label for the
    # same reason — an empty picker is a wasted keypress.
    #
    # Two forks on the prefix+g path, which is not the hot path (prefix+f is) and
    # already forks bash to get here.
    _m_sched='Schedule' _m_jobs='-Jobs'
    if command -v at >/dev/null 2>&1; then
      _njobs=$(atq -q "$SCHED_QUEUE" 2>/dev/null | grep -c . || true)
      case "$_njobs" in
        ''|0) _m_jobs='-Jobs' ;;
        *)    _m_jobs="Jobs ($_njobs)" ;;
      esac
    else
      _m_sched='-Schedule (needs at)'
      _m_jobs='-Jobs (needs at)'
    fi
    # Agents that wait on you (approve / input), counted above by the rows' own
    # state logic (agents_waiting_r).  Greyed out when there are none, like
    # Jobs -- a filter that finds nothing is a wasted keypress.  The key is `e`:
    # display-menu spends g/G (and j/k, q) on moving about.
    if [ "$AGENT_STATE" != on ]; then
      _m_agents='-Agents (agent-state off)'
    elif [ "$_n_agents" = 0 ]; then
      _m_agents='-Agents'
    elif [ "$_n_agents" = 1 ]; then
      _m_agents='Agents (1 needs you)'
    else
      _m_agents="Agents ($_n_agents need you)"
    fi
    # Item names are FORMATS, so #[...] styles them.  Kill is the only entry here
    # that destroys something; give it the same danger colour as the frame it
    # turns red.
    tmux display-menu -x C -y C ${TMUX_C[@]+"${TMUX_C[@]}"} \
      -T '#[align=centre,bold] interdimux ' \
      -H "bg=${MENU_SEL_BG},fg=${MENU_SEL_FG},bold" \
      'Switch'      s "run-shell -b \"$_mp switch\"" \
      "$_m_agents"  e "run-shell -b \"$_mp agents\"" \
      'New session' n "run-shell -b \"$_mp dirs\"" \
      '' \
      'Rename'      r "run-shell -b \"$_mp rename\"" \
      "#[fg=${POPUP_BORDER_DANGER}]Kill" i "run-shell -b \"$_mp kill\"" \
      'Swap'        w "run-shell -b \"$_mp swap\"" \
      'Zoom'        z "run-shell -b \"$_mp zoom\"" \
      '' \
      'Detach'      d "run-shell -b \"$_mp detach\"" \
      'Send keys'   t "run-shell -b \"$_mp send\"" \
      '' \
      "$_m_sched"   a "run-shell -b \"$_mp schedule\"" \
      "$_m_jobs"    o "run-shell -b \"$_mp jobs\"" \
      '' \
      'Health'      h "run-shell -b \"$_mp doctor\""
  else
    chrome=()
    cmd="$(build_env_fwd) bash '$sp' --dashboard"
    if tmux_ge 303; then
      chrome=(-T "${POPUP_TITLE_STYLE} interdimux ")
      [ -n "${TMUX_PANE:-}" ] && chrome+=(-e "TMUX_PANE=$TMUX_PANE")
      [ -n "$INTERDIMUX_CLIENT" ] && chrome+=(-e "INTERDIMUX_CLIENT=$INTERDIMUX_CLIENT")
      env_fwd_flags
      chrome+=("${ENV_FWD_FLAGS[@]}")
      cmd="bash '$sp' --dashboard"
    fi
    # Entries + 5: two border rows, the prompt, the rule under it, and the hint
    # bar.  MEASURED rather than guessed — the 12 entries show fully at -h 17,
    # and at 16 the last one scrolls away (as 11 did at 15, before Agents) —
    # because the number that was here before was slack nothing could
    # distinguish from any other slack, and the entry added last is the one a
    # too-short popup scrolls away.  tests/test_dashboard.sh derives it
    # from the item list and fails if the two drift, exactly as it does for
    # MENU_ROWS.
    #
    # Clamped to the client, because display-popup does NOT clamp: it fails with
    # "height too large" and draws nothing.  Verified — on a 14-row client `-h 14`
    # succeeds and `-h 15` errors, so the limit is exactly the client's size.  A
    # fixed 64x19 made this the same dead key as an oversized menu, reached by the
    # other path.  fzf's list scrolls, so a short popup is merely cramped.
    _pop_w=64 _pop_h=17
    [ "$_cli_w" -gt 0 ] && [ "$_cli_w" -lt "$_pop_w" ] && _pop_w="$_cli_w"
    [ "$_cli_h" -gt 0 ] && [ "$_cli_h" -lt "$_pop_h" ] && _pop_h="$_cli_h"
    tmux display-popup ${TMUX_C[@]+"${TMUX_C[@]}"} -w "$_pop_w" -h "$_pop_h" ${chrome[@]+"${chrome[@]}"} \
      -E "$cmd"
  fi
  exit 0
fi

# fzf fallback menu (tmux < 3.4)
if [ "${1:-}" = "--dashboard" ]; then
  set +e

  # Agents: no disabled state in an fzf list, so the count goes in the
  # description (the native menu greys the entry out instead).
  if [ "$AGENT_STATE" != on ]; then
    _fb_agents="Agents waiting on you (@interdimux-agent-state is off)"
  else
    agents_waiting_r
    case "$REPLY" in
      0) _fb_agents="No agent needs you now" ;;
      1) _fb_agents="1 agent needs you (approve or input)" ;;
      *) _fb_agents="$REPLY agents need you (approve or input)" ;;
    esac
  fi
  items=$(printf "%s\t  ${BOLD_AMBER}%-14s${RST} ${DIM}%s${RST}\n" \
    "switch" "Switch"       "Navigate & jump to target" \
    "agents" "Agents"       "$_fb_agents" \
    "dirs"   "New session"  "Create session from directory" \
    "rename" "Rename"       "Rename a session or window" \
    "kill"   "Kill"         "Remove sessions, windows, or panes" \
    "zoom"   "Zoom"         "Toggle pane zoom" \
    "swap"   "Swap"         "Swap windows or panes" \
    "detach" "Detach"       "Detach clients from session" \
    "send"   "Send keys"    "Send a command to a pane" \
    "schedule" "Schedule"   "Run a command later, via at" \
    "jobs"   "Jobs"         "See and cancel scheduled commands" \
    "doctor" "Health"       "Check the setup, like :checkhealth")

  HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
  hint_flag enter select 2 esc quit 1
  choice=$(printf '%s\n' "$items" | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --no-info \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='interdimux ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
  ) || exit 0

  action="${choice%%	*}"

  # Launch the selected tool in a new popup via run-shell -b (popups
  # can't nest, so this runs after the dashboard popup closes).  The pane and
  # client this popup was opened for go along: run-shell would hand --launch
  # the server's global TMUX_PANE instead (see launch_env_prefix).
  launch_env_prefix
  tmux run-shell -b "${REPLY}bash '$SQ_SCRIPT_FMT' --launch $action"
  exit 0
fi

# ---------------------------------------------------------------------------
# An argument no mode took
# ---------------------------------------------------------------------------
#
# Every handler above ends in `exit`, so arriving here with an argument means
# none of them recognised it.  It used to fall straight into the navigator: a
# typo'd mode (`--sched-lsit`), --version, anything, opened the picker from a
# terminal, and from a script — no tty — failed inside it, appended a bogus
# "navigator stderr" entry to the error log and turned --doctor red.
#
# The navigator itself takes no arguments.  Every launcher (the prefix+f
# binding, --launch, the dashboard) hands it its mode in INTERDIMUX_MODE, never
# on the command line, so anything at all is refused — a bare word too, since
# `interdimux.sh doctor` is the same mistake as `--doctr`.  Refused HERE, before
# the scratch files and the stderr log below exist, so a bad invocation leaves
# nothing behind.
if [ -n "${1:-}" ]; then
  printf "interdimux: unknown mode '%s' (see --help)\n" "$1" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Main — navigator loop
# ---------------------------------------------------------------------------
#
# Actions run via execute(...)+reload(...) so fzf stays open with its
# query, cursor, and preview state intact (no restart flash).  The only
# restart path is ctrl-o: a cancelled dir picker signals via RESUME_FILE
# so the navigator reopens; a successful create/switch leaves it closed.

INTERDIMUX_MODE="${INTERDIMUX_MODE:-switch}"

# One-bit flag: "the dir picker was cancelled, so reopen the navigator".
#
# mktemp is a fork+exec (~5 ms) on the path to the first paint, so prefer a
# name we can build in-process.  Only somewhere private, though: a predictable
# name in a world- or group-writable /tmp can be pre-created as a symlink, and
# the `: >` below would then truncate whatever it points at.  $XDG_RUNTIME_DIR
# is per-user and 0700, which removes that race; anywhere else, pay for mktemp.
#
# And if that fails too — $TMPDIR pointing somewhere that is gone, a full /tmp —
# the state dir, which is ours and not shared.  This used to be the end of the
# navigator: mktemp failed under `set -e` BEFORE stderr is routed to the log
# below, so its message flashed in a popup that closed on the spot.  When even
# the state dir will not take a file, say so on the status line, which outlives
# the popup; --doctor checks both directories.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
  RESUME_FILE="$XDG_RUNTIME_DIR/interdimux-resume.$$"
elif ! RESUME_FILE=$(mktemp "${TMPDIR:-/tmp}/interdimux-resume.XXXXXX" 2>/dev/null) \
  && ! { mkdir -p "$SCHED_LOGDIR" 2>/dev/null \
         && RESUME_FILE=$(mktemp "$SCHED_LOGDIR/resume.XXXXXX" 2>/dev/null); }; then
  imux_msg "cannot create a scratch file in ${TMPDIR:-/tmp} or $SCHED_LOGDIR (see --doctor)"
  exit 1
fi
PREVIEW_STATE_FILE="${RESUME_FILE}.preview"
printf '%s' "$SHOW_PREVIEW" > "$PREVIEW_STATE_FILE" 2>/dev/null || PREVIEW_STATE_FILE=""
export INTERDIMUX_PREVIEW_STATE="$PREVIEW_STATE_FILE"

# Errors go to the status line and a log, not across the list.
#
# The popup's stderr IS the popup: anything written there is painted over the
# rendered rows and then vanishes with the popup, which is how a read-only
# $XDG_DATA_HOME turned into three "Permission denied" lines smeared across the
# tree, and how every other silent failure this picker has had stayed silent.
# From fzf 0.53 on, fzf draws its interface on /dev/tty rather than stderr, so
# redirecting fd 2 costs the UI nothing.
#
# BEFORE 0.53 it costs the whole UI.  Those releases paint every frame on
# stderr (0.52.1's LightRenderer.flush writes to os.Stderr; 0.53.0's writes to
# the tty it opens), and an execute() child such as ctrl-o's directory picker
# inherits that stderr and draws on it the same way.  Redirected, the popup
# stayed black, Esc still quit, and errors.log filled with the rendered frames.
# There the picker keeps its real stderr and the redirect is simply skipped:
# a stray error line over the list is the price of a picker that draws at all.
#
# Reported, never swallowed: the first line goes to `display-message` (which
# also lands in `tmux show-messages`) and the whole thing is appended to a log
# that --doctor points at.
#
# Only on this path.  Child modes (--list, --preview, --action, --doctor …) keep
# their real stderr: they are called by fzf, by the test suites, and by the user.
ERR_FILE="${RESUME_FILE}.err"
if fzf_ge 53 && : > "$ERR_FILE" 2>/dev/null; then
  exec 2>"$ERR_FILE"
else
  ERR_FILE=""
fi

_report_stderr() {
  [ -n "$ERR_FILE" ] && [ -s "$ERR_FILE" ] || return 0
  local first
  { read -r first < "$ERR_FILE"; } 2>/dev/null || :
  [ -n "$first" ] || return 0
  # A long line would be truncated by the status line anyway, so cut it where
  # it stays readable.  imux_msg escapes the '#'s -- after the cut, which
  # therefore cannot split a "##" pair and leave a lone '#' to start a format.
  [ "${#first}" -gt 160 ] && first="${first:0:157}…"
  imux_msg "$first"
  if mkdir -p "$SCHED_LOGDIR" 2>/dev/null; then
    {
      printf '== %s navigator stderr\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      cat "$ERR_FILE"
    } >> "$SCHED_LOGDIR/errors.log" 2>/dev/null || :
  fi
}

# The query (and match scope) the raw-mode `result` bind last answered, so it
# can tell a new query from a reload of the same one -- see _best_guard below.
# Named off RESUME_FILE for the same reason the preview state is: private, and
# no mktemp fork on the way to the first frame.  Exported rather than spliced
# into the bind, so no path character can reach the snippet's quoting.
QUERY_STATE_FILE="${RESUME_FILE}.query"
export INTERDIMUX_QUERY_STATE="$QUERY_STATE_FILE"

trap '_report_stderr; rm -f "$RESUME_FILE" "$PREVIEW_STATE_FILE" "$QUERY_STATE_FILE" ${ERR_FILE:+"$ERR_FILE"} ${MOUNTS_FILE:+"$MOUNTS_FILE"}' EXIT

# When bash draws the list, every --list reload asks is_remote_path, and so do
# the directory rows' previews and ctrl-o's picker: classify the mount table
# once, here, for all of them (see mounts_export) -- the first list inherits it
# too, so it costs nothing it did not already.  Not with the Rust core, which
# reads the table itself: there this would be a parse on the way to the first
# frame, to save one in an asynchronous preview.  Instead the core writes what
# it read to MOUNTS_FILE (named like the preview state: private, no mktemp) on
# every list, for those same callbacks and for this process's Enter on a
# directory row -- each of which parsed the table again (review B08).
if [ -z "$IMUX_BIN" ] && { [ "$SHOW_GIT_BRANCH" = on ] || [ "$SHOW_DIRS" = on ]; }; then
  mounts_export
elif [ -n "$IMUX_BIN" ]; then
  MOUNTS_FILE="${RESUME_FILE}.mounts"
  rm -f "$MOUNTS_FILE" 2>/dev/null || :
  export INTERDIMUX_MOUNTS_FILE="$MOUNTS_FILE"
fi

LIST_CMD="bash '$SCRIPT_PATH' --list"
ACTION_CMD="bash '$SCRIPT_PATH' --action"

while true; do
  : > "$RESUME_FILE"
  # Re-seed each iteration: the loop restarts fzf using the STATIC $SHOW_PREVIEW
  # to choose --preview-window …hidden, while compute_widths reads the file.
  # ctrl-o -> Esc re-enters the loop, so without this the two go permanently out
  # of phase and rows are sized for a preview that is not shown.
  [ -n "$PREVIEW_STATE_FILE" ] && printf '%s' "$SHOW_PREVIEW" > "$PREVIEW_STATE_FILE" 2>/dev/null

  # Ties go to the LIST'S OWN ORDER, and nothing else does.  gather_targets
  # already emits the sessions in @interdimux-order (MRU by default), each with
  # its windows and panes under it, and the directory suggestions last — and on
  # a tie that order is the answer.  It is the order --jump N counts in too.
  #
  # This is not the default and it is not `chunk`, which is what it used to be.
  # Two rows tie a great deal more often than it looks: fzf scores the MATCH, not
  # the row, so a session and a directory whose names both sit one space into
  # field 1 (` ▸ name` and ` + name`) score identically for every query that
  # reaches both, and the tiebreak is then the entire decision.  `chunk` decides
  # it by the length of the whitespace chunk the match landed in, i.e. by whose
  # name is SHORTER — so an existing session `circle/sui-cctp` lost, every time,
  # to a `Circle` directory that was only being offered as a new session, and
  # Enter created a second session beside the one being aimed at.  (Reported from
  # real use; tests/test_pick_order.sh drives it.)  The same key also demoted a
  # session row below its OWN window rows, since a window row carries the session
  # name truncated to the prefix budget and its chunk is therefore the shorter
  # one — measured, `anno` ranked W:annotations-worker:0 above
  # S:annotations-worker, and with `index` the session row leads again.
  #
  # `index` does NOT mean sessions always win.  Score still comes first, so a
  # directory suggestion that is genuinely the better match — an exact `notes`
  # against a session that only matches it as a scattered subsequence — is still
  # picked first, which is what keeps the one-list model worth having.
  #
  # shellcheck disable=SC2054  # commas are part of a single fzf argument
  fzf_opts=(
    "${FZF_THEME[@]}"
    --delimiter=$'\t'
    --with-nth=1..3
    --nth=1,3
    --tiebreak=index
    --bind='change:first'
    # reload-SYNC, here and on every navigator reload (^/, resize, each
    # action's execute+reload): the old list stays up until the new one is
    # complete, then swaps in whole.  A plain `reload` clears the list and
    # shows rows as they stream in, and the bash renderer (every install
    # without the Rust core) prints row by row: the cursor, which fzf keeps by
    # row NUMBER, landed on row 1 of a half-drawn list and stayed there, so in
    # raw mode ^r, ^/ and a resize threw it to the top after all -- the Rust
    # core's output arrives in one write, which is why only it was fixed.
    # (fzf >= 0.36; the floor is 0.40.)
    --bind="ctrl-r:reload-sync($LIST_CMD)"
  )


  # Row identity by SPEC (field 4) for fzf's cross-reload operations.
  #
  # What it does NOT do, whatever it looks like: keep the CURSOR on the same
  # target across a plain `reload`.  fzf consults --id-nth for the cursor only
  # while tracking is on (--track, or a track-current action); otherwise it
  # keeps the same row NUMBER.  Measured on 0.74.3: rows a b c d, cursor on c,
  # reloaded as a x y b c d -- the cursor lands on y with --id-nth=1, exactly
  # as with no flag, and stays on c only with --id-nth=1 --track.  So after a
  # kill the cursor is on whatever slid into the row, and that row-number rule
  # is what the raw-mode `result` bind below has to leave alone.
  #
  # Deliberately still WITHOUT --track: --track arms trackBlocked, which
  # DISCARDS every keystroke except abort while a reload is in flight
  # (fzf src/terminal.go:6821-6827), and that window is widest right after the
  # popup opens.  The flag costs nothing and never blocks, and a reload-sync
  # carrying a multi-selection across by SPEC would need it (IDEAS #16).
  fzf_ge 71 && fzf_opts+=(--id-nth=4)

  # Keep the row's identity while a long command hscrolls.  The command is the
  # LAST field and is written UNPADDED, and with show-full-command on it is the
  # whole argv, so overflow is routine — and fzf scrolls the entire line to
  # bring a match into view, which replaced the identity column with the
  # ellipsis.  The row you were about to kill stopped saying which pane it was.
  #
  # =1 freezes exactly field 1 of the DISPLAYED line (measured: N counts fields
  # after --with-nth, and N >= the displayed field count silently disables the
  # whole thing, so 3 would be a no-op here).  The frozen prefix is
  # right-trimmed, so padding is dropped at the cut and the ellipsis lands at a
  # different column on each scrolled row — a ragged grid, which is the price
  # for the rows staying identifiable at all.
  #
  # Below 0.67 the flag does not exist and fzf REFUSES TO START on an unknown
  # option, so the gate is mandatory.  --no-hscroll is the only lever left
  # there; it fixes the same misalignment by hiding the match instead, which is
  # the wrong trade for ^] cmd but a better one than an anonymous row.
  if fzf_ge 67; then
    fzf_opts+=(--freeze-left=1)
  else
    fzf_opts+=(--no-hscroll)
  fi


  # fzf 0.74's `wait` defers the remaining actions of a binding until any
  # in-flight search/load completes, and QUEUES them (unlike --track's
  # trackBlocked, which discards).  Every action here runs execute+reload, so
  # without it a fast second keypress acts on a row the reload has already
  # removed — verified upstream that a plain enter:accept mid-refresh returns an
  # already-deleted row.  Empty on older fzf, where the binds are unchanged.
  _wait=""
  fzf_ge 74 && _wait="wait+"
  case "$INTERDIMUX_MODE" in
    kill)
      hint_flag enter kill 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='kill ❯ '
        # The danger cue that needs no border.  The frame turns red (see
        # danger_style), but with popup-border-lines "none" tmux draws no frame
        # and no title, and nothing on screen said this Enter destroys.  After
        # FZF_THEME, so it overrides the accent prompt here only.  An invalid
        # --color is fatal to fzf, but the palette is normalised to values fzf
        # parses (#rrggbb, 0-255, -1), and `prompt:` exists on every fzf.
        --color="prompt:${COLOR_DANGER}"
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute($ACTION_CMD kill {-1})+reload-sync($LIST_CMD)"
      )
      ;;
    rename)
      hint_flag enter rename 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='rename ❯ '
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute($ACTION_CMD rename {-1})+reload-sync($LIST_CMD)"
      )
      ;;
    zoom)
      hint_flag enter 'toggle zoom' 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='zoom ❯ '
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute-silent($ACTION_CMD zoom {-1})+reload-sync($LIST_CMD)+refresh-preview"
      )
      ;;
    swap)
      hint_flag enter swap 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='swap ❯ '
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute($ACTION_CMD swap {-1})+reload-sync($LIST_CMD)"
      )
      ;;
    detach)
      hint_flag enter detach 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='detach ❯ '
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute($ACTION_CMD detach {-1})+reload-sync($LIST_CMD)"
      )
      ;;
    send)
      hint_flag enter 'send keys' 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='send ❯ '
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute($ACTION_CMD send {-1})+reload-sync($LIST_CMD)"
      )
      ;;
    schedule)
      hint_flag enter 'schedule a command' 3 ^r reload 1 esc quit 2
      fzf_opts+=(
        --prompt='schedule ❯ '
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"}
        --bind="enter:${_wait}execute($ACTION_CMD schedule {-1})+reload-sync($LIST_CMD)"
      )
      ;;
    *)
      # The per-row hint bar only ever picks between these five strings, and all
      # five are known right here.  Each is exported as its full LADDER of width
      # tiers ("W:line|W:line|…|0:"), so the focus bind can choose both the row
      # type and the tier inline instead of re-exec'ing this script on every
      # cursor move.
      hint_cols; _hint_w="$REPLY"
      for _t in S W P D X; do
        hint_set "$_t"
        hint_tiers ${HINT_SET[@]+"${HINT_SET[@]}"}
        printf -v "INTERDIMUX_HINTS_$_t" '%s' "$REPLY"
        export "INTERDIMUX_HINTS_$_t"
      done
      # The launch-time bar, fitted here rather than by the snippet: fzf has to
      # be told the string before it can draw a first frame.
      hint_pick "$_hint_w" "$INTERDIMUX_HINTS_X"; _hint_x="$REPLY"

      # On the fallback path nothing else re-fits the bar: the `result` bind that
      # does it inline is gated on INLINE_CALLBACKS, and `focus` does NOT fire on
      # the reload that ^/ triggers — measured, the bar stayed at the launch rung
      # and fzf truncated it, which is the exact failure the ladder exists to
      # remove.  So the two events that change the list width ask for it.
      _refit=""
      [ "$INLINE_CALLBACKS" = 1 ] || \
        _refit="+transform-$HINT_BAR(bash '$SCRIPT_PATH' --footer-for {-1})"

      fzf_opts+=(
        --prompt='❯ '
        --print-query
        --bind="ctrl-o:execute(bash '$SCRIPT_PATH' --dirs || echo resume > '$RESUME_FILE')+abort"
        # Column widths are computed against the space actually available, so
        # toggling the preview or resizing the popup invalidates them: without
        # the reload the rows stay sized for the old geometry (IDEAS #26).
        # A reload used to cost ~195ms, which is why this was deferred; it is
        # ~25ms now.
        --bind="ctrl-/:toggle-preview+execute-silent(f='$PREVIEW_STATE_FILE'; read -r st < \"\$f\" 2>/dev/null; [ \"\$st\" = on ] && printf off > \"\$f\" || printf on > \"\$f\")+reload-sync($LIST_CMD)$_refit"
      )
      # The `resize` event arrived in fzf 0.46 (its CHANGELOG), and fzf REFUSES
      # TO START on an event it does not know ("unsupported key: resize"), so
      # ungated this one bind closed the popup the instant it opened on
      # 0.40-0.45 -- Ubuntu 24.04 ships 0.44.1.  Below 0.46 a resized popup
      # keeps its old column widths until ^r, which is the whole loss.
      fzf_ge 46 && fzf_opts+=(--bind="resize:reload-sync($LIST_CMD)$_refit")
      # alt-enter: create from the query WHATEVER it matches (review UX-54).
      # Enter only creates at zero matches, and in the default name+cmd scope
      # the command column is a pane's whole argv: one `kubectl logs -f
      # deployment/payments-api -n production --since=1h` scatter-matches docs,
      # blog, auth, cli, search -- and an agent row's state words and
      # description add more -- so Enter switched there and find-or-create was
      # unreachable for ordinary names.  Scattered matches hit the identity
      # column too (`blog` matches `prod-db 1:logs`), so no narrower scope
      # would have fixed it; only a key that does not ask fzf can.
      #
      # An empty query runs nothing at all (an empty transform is a no-op); any
      # other asks --create-key, which prints raw mode's create-and-close, or
      # nothing when the query is only fzf syntax.  Needs `transform` (0.45)
      # and FZF_QUERY in the environment (0.46), and parses in fish too.  Not
      # alt-enter in anything fzf binds by default, and a user's own binding of
      # it (FZF_DEFAULT_OPTS, @interdimux-fzf-opts) comes earlier on the
      # command line and gives way here, as it does for ^x and the rest.
      fzf_ge 46 && fzf_opts+=(--bind="alt-enter:transform:[ -n \"\$FZF_QUERY\" ] && bash '$SQ_SCRIPT' --create-key")
      # The agents view opens with its query typed (see VIEW).
      [ -n "$VIEW" ] && fzf_opts+=(--query="$AGENTS_QUERY")
      # An empty bar means nothing fits at this width.  Passing --footer='' still
      # costs a row (measured — the section is drawn, blank), so omit the flag
      # entirely; a transform that emits nothing later removes the section again
      # and the list reflows into the row.
      [ -n "$_hint_x" ] && fzf_opts+=(--"$HINT_BAR"="$_hint_x")

      # Per-row hints, once per cursor move.  A focus bind runs SYNCHRONOUSLY —
      # the fzf man page warns it "can make the interface sluggish" — so on
      # fzf >= 0.63 we use the async bg- variant and bg-cancel to coalesce rapid
      # scrolling.
      #
      # The command itself is an inline snippet over the exported ladders, which
      # costs one ~1ms `sh -c` instead of re-parsing and re-executing this
      # 4900-line script (~17ms) per move.  It picks the row type with a `case`
      # and then walks that type's tiers, widest first, taking the first that
      # fits the LIVE width — which is what keeps the bar right after ^/ (a
      # right-hand preview halves the list) and after a client resize, neither
      # of which is knowable at launch.  Notes on the sharp edges:
      #   * `_{-1}` — with an EMPTY result list fzf expands {-1} to *zero*
      #     words, so a bare `case {-1} in` becomes `case in`: a syntax error
      #     and a blank bar.  The `_` prefix keeps the word present.
      #   * `action:rest-of-string` rather than `action(...)` — the arms contain
      #     `)`, which can terminate fzf's parenthesised argument parser.  This
      #     form has no terminator, so it must come last in the `+` chain.
      #   * NO COMMAS anywhere in the snippet: fzf splits --bind on commas, so
      #     one would silently become a second, malformed binding.
      #   * FZF_COLUMNS is 0 during fzf's own `start`, hence the guard; and it
      #     does NOT shrink when the preview opens, hence FZF_PREVIEW_COLUMNS
      #     (set exactly while the preview is visible) as the halving test.
      # fzf single-quotes the placeholder, so a spec can't inject shell.
      _hint_case='c=${FZF_COLUMNS:-0}; [ "$c" -gt 0 ] || c=200;'
      _hint_case+=' [ -n "${FZF_PREVIEW_COLUMNS:-}" ] && c=$(( c - c / 2 ));'
      _hint_case+=' c=$(( c - 3 ));'
      _hint_case+=' case _{-1} in'
      _hint_case+=' _S:*) t=$INTERDIMUX_HINTS_S;;'
      _hint_case+=' _W:*) t=$INTERDIMUX_HINTS_W;;'
      _hint_case+=' _P:*) t=$INTERDIMUX_HINTS_P;;'
      _hint_case+=' _D:*) t=$INTERDIMUX_HINTS_D;;'
      _hint_case+=' *) t=$INTERDIMUX_HINTS_X;; esac;'
      _hint_case+=' while [ -n "$t" ]; do x=${t%%|*};'
      _hint_case+=' [ "$x" = "$t" ] && t= || t=${t#*|};'
      _hint_case+=' [ "${x%%:*}" -le "$c" ] || continue;'
      _hint_case+=' f=${x#*:}; [ -n "$f" ] && printf "%s\n" "$f"; break;'
      _hint_case+=' done'

      # At ZERO matches the bar is not a row's hints at all: Enter creates a
      # session there, and the bar has to say so (IDEAS #1, the announcement
      # below).  Two binds write the bar -- `focus` here and `result` further
      # down -- and when the list empties BOTH fire, focus last (the current
      # item changes to none).  So both must give the same answer.  They used
      # not to: focus ran the bare row case, whose `*)` arm printed the generic
      # ladder, and on fzf >= 0.63 its bg-cancel also killed the announcement
      # that result had just started.  With raw off, or on any fzf below 0.74,
      # the bar said "enter switch" while Enter created a session.
      #
      # One dispatcher, bound to both: whichever runs last prints the same
      # text, and bg-cancel's ordering stops mattering.  Cost: the create
      # description is a real process, but it only runs at zero matches, where
      # focus fires once on the transition (and, in raw mode, on each move over
      # the dimmed rows -- which is right, since Enter creates from every one).
      #
      # A THIRD state since review UX-54: rows match and a query is typed.
      # alt-enter creates from the query there, and a scattered match in some
      # pane's argv holding the cursor is exactly when Enter would not, so the
      # bar names what alt-enter would make ("M-⏎ create docs").  That name
      # needs the same resolver as the zero-match one, so it is --footer-for's
      # job: a real process on every keystroke of a typed query (a bash start
      # and a tmux query, tens of ms), which is why only fzf >= 0.63 gets it,
      # where bg-transform runs it off the input loop and bg-cancel drops the
      # ones a fast typist has outrun.  Below that the transform is synchronous
      # and would stall each keystroke for it; the key still works there
      # (0.46), and the README names it.
      if fzf_ge 63; then
        _hint_bind="if [ \"\${FZF_MATCH_COUNT:-0}\" -gt 0 ] && [ -z \"\$FZF_QUERY\" ]; then $_hint_case;"
        _hint_bind+=" elif [ \"\${FZF_MATCH_COUNT:-0}\" -gt 0 ]; then bash '$SQ_SCRIPT' --footer-for {-1};"
      else
        _hint_bind="if [ \"\${FZF_MATCH_COUNT:-0}\" -gt 0 ]; then $_hint_case;"
      fi
      _hint_bind+=" else bash '$SQ_SCRIPT' --describe-create {q}; fi"
      # The fallback path's dispatcher is --footer-for, which makes the same
      # zero-match decision itself (FZF_MATCH_COUNT and FZF_QUERY reach it as
      # environment, from fzf 0.46).
      _footer_for="bash '$SCRIPT_PATH' --footer-for {-1}"
      if [ "$INLINE_CALLBACKS" = 1 ] && fzf_ge 63; then
        fzf_opts+=(--bind="focus:bg-cancel+bg-transform-$HINT_BAR:$_hint_bind")
      elif [ "$INLINE_CALLBACKS" = 1 ]; then
        fzf_opts+=(--bind="focus:transform-$HINT_BAR:$_hint_bind")
      elif fzf_ge 63; then
        fzf_opts+=(--bind="focus:bg-cancel+bg-transform-$HINT_BAR($_footer_for)")
      else
        fzf_opts+=(--bind="focus:transform-$HINT_BAR($_footer_for)")
      fi
      if fzf_ge 58; then
        # Same treatment for the match-scope prompt: FZF_NTH already holds the
        # NEW value when the transform runs, so the prompt is a pure lookup.
        if [ "$INLINE_CALLBACKS" = 1 ]; then
          _scope_case='case "${FZF_NTH:-}" in'
          _scope_case+=' 1) printf "name ❯ \n";; 2) printf "path ❯ \n";;'
          _scope_case+=' 3) printf "cmd ❯ \n";; 1,2,3) printf "all ❯ \n";;'
          _scope_case+=' 1,3) printf "name+cmd ❯ \n";;'
          _scope_case+=' *) printf "❯ \n";; esac'
          fzf_opts+=(--bind="ctrl-]:change-nth(1|2|3|1,2,3|1,3)+transform-prompt:$_scope_case")
        else
          fzf_opts+=(--bind="ctrl-]:change-nth(1|2|3|1,2,3|1,3)+transform-prompt(bash '$SCRIPT_PATH' --scope-prompt)")
        fi
      fi
      fzf_ge 61 && fzf_opts+=(--ghost='session · window · pane')
      _raw_on=0

      # Raw mode (fzf >= 0.74): non-matching rows stay on screen, dimmed,
      # instead of vanishing.  This is what fixes the tree collapsing as you
      # type — filtering used to strip parent rows and leave orphaned '├─'
      # glyphs pointing at nothing.  ctrl-n/ctrl-p hop between matches.
      #
      # It changes one thing that must be handled: with rows still displayed,
      # Enter on a query that matches NOTHING returns rc=0 with whatever row the
      # cursor is on, where plain fzf returns rc=1 and the query.  Verified.
      # So find-or-create cannot key off the exit code any more — the enter bind
      # dispatches on $FZF_MATCH_COUNT and performs the create inside fzf.
      if [ "$RAW_MODE" = "on" ] && fzf_ge 74; then
        _raw_on=1
        # A dimmed row is never a target.  With nothing matched every row is
        # dimmed and Enter creates from the query instead; but Up/Down still
        # walk onto a dimmed row while OTHER rows match, and there Enter
        # switched to it, ^x offered to kill it and ^z zoomed it with no
        # dialog at all -- a row the query had just excluded.  fzf exports
        # FZF_RAW in raw mode: 1 on a matching row, 0 on a dimmed one -- and 0
        # with no current row at all (the cursor past the end after a kill,
        # until fzf next draws), which FZF_CURRENT_ITEM tells apart: fzf sets
        # it only for a real row (0.73+), and an inherited one is dropped
        # below.  Past the end the keys do what they always did there (fzf
        # skips a row action whose {-1} has no row to expand to).
        #
        # This is the MIDDLE branch of each key's dispatch: `<zero matches>;
        # <dimmed> || <zero matches> || <act>`.  Three outcomes need either
        # grouping or an if, and neither parses in both POSIX sh and fish (a
        # user's --with-shell); `;` and single tests do, and the tests are
        # disjoint, so exactly one echo runs.
        _dimmed='[ "$FZF_MATCH_COUNT" != 0 ] && [ "$FZF_RAW" = 0 ] && [ -n "$FZF_CURRENT_ITEM" ]'
        hint_r '∅' 'this row does not match' '^n' 'next match'
        _dimmed="$_dimmed && echo 'change-$HINT_BAR:$REPLY' || [ \"\$FZF_MATCH_COUNT\" = 0 ] ||"
        fzf_opts+=(
          --raw
          # :strip:dim, not a bare colour — setting a colour REPLACES fzf's
          # default dim attribute, and because every row is pre-coloured with
          # --ansi the non-matching rows kept nearly all their colour and the
          # dimming barely showed.  strip removes the row's own SGR runs.
          --color="nomatch:${COLOR_TREE}:strip:dim"
          # fzf has a SECOND gutter option that only applies in raw mode;
          # blanking just --gutter left a stray ▖ on every non-current row.
          --gutter-raw=' '
          # "$FZF_QUERY", not {q}: {q} is single-quoted by fzf and lands INSIDE
          # the echo's own single quotes, so the quoting cancels and `zzz shell`
          # reached --create-from-query as two words — it created `zzz` while the
          # bar promised `zzz-shell`.  fzf exports FZF_QUERY to execute's shell,
          # so the query is never re-parsed.
          # Plain string compares, as in _action_bind below, so the dispatch
          # parses in fish too (`${FZF_MATCH_COUNT:-0}` did not).
          --bind="enter:transform:[ \"\$FZF_MATCH_COUNT\" = 0 ] && echo 'execute(bash \"$SQ_SCRIPT\" --create-from-query \"\$FZF_QUERY\")+abort'; $_dimmed echo accept"
        )
      fi

      # `best` on `result`, in raw mode: every row stays displayed, so nothing
      # moves the cursor onto a match and `--bind=change:first` actively pins it
      # to row 1 -- filter, press ctrl-x, and you kill whatever happened to be
      # at the top.  Verified: with --raw, typing "delta" left the cursor on
      # "alpha" under change:first AND under change:best (which fires before
      # the search completes); result:best lands on "delta".
      #
      # But `result` does not only follow a query change.  fzf fires it after
      # EVERY reload too, and ^r, ^/, a resize, ^z and every ^x/^e/^d/^s/^t
      # (execute+reload, confirmed or cancelled) end in one.  An unconditional
      # `best` answered each of those as if the query had just been typed: with
      # an empty query that is row 1, so cancel a ^x on gamma and the next ^x
      # offered to kill whatever sat at the top.  Left alone, fzf keeps the
      # cursor on the same row NUMBER across a reload, which is the same row
      # whenever the list did not change -- and ^r, ^/ and a resize never
      # change it.  (--id-nth does not help here: without --track it keys
      # nothing about the cursor.)
      #
      # So `best` fires when the query or the ^] scope differs from the last one
      # answered, remembered in a file (a `wait` in `change` would need no
      # process, but fzf DROPS every keystroke while a wait blocks).  Also:
      #   * when rows arrive that were never there before and a query is typed
      #     -- the list still loading under a query typed ahead (the directory
      #     rows are printed after the sessions and can land in a second
      #     snapshot).  "Never there" is the largest total seen, so a reload,
      #     which may pass through a partial snapshot, does not qualify;
      #   * when a reload left the cursor on a row that no longer matches -- a
      #     kill slid a dimmed one under it -- the one reload after which the
      #     match set, not the row number, is what the user was on.
      #     FZF_RAW=0 also means "past the end", though: a kill that removes
      #     the LAST rows leaves the cursor one beyond the shorter list (fzf
      #     clamps it only when it next draws), and read as a dimmed row that
      #     sent it to row 1 -- kill your bottom pane, and the next ^x offered
      #     the first session.  fzf exports FZF_CURRENT_ITEM only when the
      #     cursor is ON a row (0.73+; raw needs 0.74), which tells the two
      #     apart.  Past the end with no query every row matches, so fzf's own
      #     clamp lands on the new last row, as it does with raw off; with a
      #     query that row may be dimmed, so `best` still fires.  An inherited
      #     FZF_CURRENT_ITEM (interdimux run from an fzf child) is dropped below.
      # Synchronous by necessity: a cursor move that lands late would undo the
      # user's own.  Degrades to the old unconditional `best` if the file cannot
      # be made.  No commas, no single quotes, no parentheses and no `${x}` that
      # fzf would read as a placeholder: it rides inside transform(...), and on
      # the fallback path inside `sh -c '...'` too.  The file's third line, the
      # last match count, is for the fallback path below.
      _res_pre="" _res_bind=""
      if [ "$_raw_on" = 1 ]; then
        unset FZF_CURRENT_ITEM
        _best_guard='f=$INTERDIMUX_QUERY_STATE; k="$FZF_NTH $FZF_QUERY"; t=${FZF_TOTAL_COUNT:-0}; b=; n=; p=; m=;'
        _best_guard+=' { read -r n; IFS= read -r p; read -r m; } 2>/dev/null < "$f";'
        _best_guard+=' [ "$n" -ge 0 ] 2>/dev/null || n=0;'
        _best_guard+=' [ "$p" = "$k" ] || b=1;'
        _best_guard+=' if [ "$t" -gt "$n" ]; then n=$t; [ -z "$FZF_QUERY" ] || b=1; fi;'
        _best_guard+=' [ "${FZF_RAW:-1}" = 0 ] && [ "${FZF_MATCH_COUNT:-0}" -gt 0 ]'
        _best_guard+=' && { [ -n "$FZF_CURRENT_ITEM" ] || [ -n "$FZF_QUERY" ]; } && b=1;'
        _best_guard+=' { printf "%s\n%s\n%s\n" "$n" "$k" "$FZF_MATCH_COUNT" > "$f"; } 2>/dev/null;'
        if ! : > "$QUERY_STATE_FILE" 2>/dev/null; then
          _res_pre="best+"
        elif [ "$INLINE_CALLBACKS" = 1 ]; then
          _res_pre="transform($_best_guard [ -z \"\$b\" ] || echo best)+"
        else
          # The fallback path (a user --with-shell).  Its bar is written by a
          # re-exec of this whole script (--footer-for, ~20 ms), and `focus`
          # already does that whenever the row changes -- the `result` bind
          # used to do it AGAIN on every keystroke.  It is only needed where
          # focus is blind: at zero matches, where raw mode leaves the cursor
          # on a dimmed row, and on the keystroke that leaves them with the
          # cursor unmoved.  The guard already runs on every result, so it
          # decides that too and prints the bar update with (or instead of)
          # `best`; with matches on both sides of a keystroke it prints
          # nothing and the bar stays as focus left it.  The action text comes
          # in through the environment, so neither its quotes nor its {-1}
          # pass through the guard's own quoting (fzf expands the {-1} when it
          # runs the printed action).
          #
          # And after a RELOAD, a result with the same query as the last one.
          # focus fires only when the cursor's row NUMBER changes, and a reload
          # keeps the number while the row under it may be a different kind:
          # kill the last pane but one of a window and both pane rows go, so a
          # session row slides under the cursor -- which kept the pane's hints
          # (^z zoom ^s swap ^t send).  A swap can do it with the row count
          # unchanged, so the test is "not a keystroke", not "fewer rows".
          # Reloads are the user's own actions (^r, ^/, a resize, each ^x ^e
          # ^z ^s ^d ^t) plus the snapshots of the first load, never typing,
          # so the per-keystroke saving above stands.
          export INTERDIMUX_BAR_ACTION="bg-cancel+bg-transform-$HINT_BAR($_footer_for)"
          _best_guard+=' o=; [ -z "$b" ] || o=best;'
          #
          # And while a query is typed, or on the keystroke that clears one:
          # the bar then names what alt-enter would create (review UX-54), and
          # that name has to follow every keystroke, so typing does pay the
          # re-exec again -- in the background (raw mode means fzf >= 0.74),
          # where it stalls nothing.  ${p#* } is the last query (k is "nth
          # query", and nth has no blank).
          _best_guard+=' if [ "$FZF_MATCH_COUNT" = 0 ] || [ "$m" = 0 ] || [ "$p" = "$k" ]'
          _best_guard+=' || [ -n "$FZF_QUERY" ] || [ -n "${p#* }" ]; then o="$o+$INTERDIMUX_BAR_ACTION"; fi;'
          _best_guard+=' o=${o#+}; [ -z "$o" ] || printf "%s\n" "$o"'
          # The guard is POSIX, and wrapping it in `sh -c` inside the user's
          # shell cost a second shell per keystroke (measured: 5.3 ms under
          # bash, 9.1 ms under zsh, against 2.4 ms for sh alone).  So it runs
          # in the user's shell directly when that shell is a known POSIX-
          # family one, and keeps the wrapper only for anything else (fish
          # cannot parse it).  The shell is the LAST --with-shell fzf is
          # handed: the user's, appended after the theme's own `sh -c`.
          _wsh=""
          for (( _i = 0; _i < ${#FZF_THEME[@]}; _i++ )); do
            case "${FZF_THEME[_i]}" in
              --with-shell=*) _wsh="${FZF_THEME[_i]#--with-shell=}" ;;
              --with-shell)   _wsh="${FZF_THEME[_i+1]:-}" ;;
            esac
          done
          read -r _wsh _ <<< "$_wsh" || :
          case "${_wsh##*/}" in
            sh|ash|dash|bash|ksh|mksh|zsh) _res_bind="transform:$_best_guard" ;;
            *) _res_bind="transform:sh -c '$_best_guard'" ;;
          esac
        fi
      fi

      # Announce find-or-create in the zero-match state (IDEAS #1).  Without it
      # the feature is invisible and a typo silently creates a junk session; now
      # the bar says exactly which session would be created, and where.
      # describe_create needs zoxide and the filesystem, so it cannot be inlined;
      # the dispatchers above run it only at zero matches.  The `focus` bind
      # restores the normal per-row hints as soon as matches come back.
      #
      # This bind is also what re-fits the bar after ^/ and after a resize: both
      # end in a reload, and a reload fires `result`.
      #
      # ONE bind owns the bar on result changes, because two of them fight: a
      # `zero` bind that announces the create, plus a `result` bind that
      # restores the row hints, means the result bind emits nothing at zero
      # matches -- and an empty transform CLEARS the bar, wiping the
      # announcement that `zero` just set.
      #
      # bg- where it exists, so it never blocks typing: `result` fires on every
      # keystroke.  `best` is chained FIRST because fzf's last --bind for an
      # event replaces the earlier one.
      if [ "$INLINE_CALLBACKS" = 1 ]; then
        if fzf_ge 63; then
          fzf_opts+=(--bind="result:${_res_pre}bg-cancel+bg-transform-$HINT_BAR:$_hint_bind")
        else
          fzf_opts+=(--bind="result:${_res_pre}transform-$HINT_BAR:$_hint_bind")
        fi
      elif [ "$_raw_on" = 1 ]; then
        # Fallback path in raw mode (a user --with-shell on fzf >= 0.74).  Rows
        # stay displayed, so the cursor sits on a dimmed row at zero matches and
        # `focus` does not fire there, nor when a keystroke brings the match
        # back under an unmoved cursor: only `result` sees every change.  The
        # guard decides when that needs the bar rewritten (above); without the
        # state file there is no guard, and every result rewrites it.
        if [ -n "$_res_bind" ]; then
          fzf_opts+=(--bind="result:$_res_bind")
        else
          fzf_opts+=(--bind="result:${_res_pre}bg-cancel+bg-transform-$HINT_BAR($_footer_for)")
        fi
      elif fzf_ge 46; then
        # Fallback path, plain filtering: `focus` covers the way into and out
        # of zero matches (the current item becomes none and back), `zero` the
        # keystrokes in between -- without it the bar kept describing the query
        # as it was when the list emptied.  --footer-for needs fzf 0.46's
        # FZF_MATCH_COUNT and FZF_QUERY; below that it cannot tell, and the bar
        # stays the generic one.
        #
        # From 0.63 it is `result`, not `zero` (review UX-54): while a query is
        # typed the bar names what alt-enter would create, and that has to
        # follow every keystroke, matches or not, where `zero` saw only the
        # fruitless ones.  In the background, so it costs no keystroke a
        # stall; below 0.63 it could only be synchronous, and there the bar
        # keeps to the zero-match announcement (see _hint_bind).
        if fzf_ge 63; then
          fzf_opts+=(--bind="result:bg-cancel+bg-transform-$HINT_BAR($_footer_for)")
        else
          fzf_opts+=(--bind="zero:transform-$HINT_BAR($_footer_for)")
        fi
      fi

      # The row actions.  In raw mode a query that matches NOTHING still leaves
      # every row on screen, dimmed, with the cursor on one of them -- and fzf
      # runs an execute against it: ^x offered to kill a session the query had
      # excluded, ^e to rename it, and ^z zoomed it with no dialog at all.
      # (Without raw the list is empty there, and fzf skips an execute whose
      # template names a field when there is no current item.)  Enter already
      # dispatches on FZF_MATCH_COUNT; these do the same, inside fzf, so the
      # dialog never takes over the terminal.  At zero matches the bar says why
      # nothing happened; the next keystroke puts the announcement back.
      #
      # The action text is ECHOED by the transform and then parsed by fzf, so
      # its placeholder is written \{-1}: fzf expands a bare {-1} in the
      # transform's own command -- quoted for a shell, but those quotes would be
      # consumed by the echo -- where the escaped form reaches the emitted
      # execute intact and is expanded, and quoted, when that runs.  No single
      # quotes (hence SQ_SCRIPT in double quotes) and no commas.  The test is a
      # plain string compare so it parses in any shell a user's --with-shell
      # may name, fish included; raw mode means fzf >= 0.74, which always
      # exports the count.
      _action_bind() { # key action exec-kind nomatch-label [trailing actions]
        if [ "$_raw_on" = 1 ]; then
          hint_r '∅' "nothing matches · no row to $4"
          fzf_opts+=(--bind="$1:${_wait}transform:[ \"\$FZF_MATCH_COUNT\" = 0 ] && echo 'change-$HINT_BAR:$REPLY'; $_dimmed echo '$3(bash \"$SQ_SCRIPT\" --action $2 \\{-1})+reload-sync(bash \"$SQ_SCRIPT\" --list)${5:-}'")
        else
          fzf_opts+=(--bind="$1:${_wait}$3($ACTION_CMD $2 {-1})+reload-sync($LIST_CMD)${5:-}")
        fi
      }
      _action_bind ctrl-x kill   execute        kill
      _action_bind ctrl-e rename execute        rename
      _action_bind ctrl-z zoom   execute-silent zoom +refresh-preview
      _action_bind ctrl-s swap   execute        swap
      _action_bind ctrl-d detach execute        detach
      _action_bind ctrl-t send   execute        'send keys to'
      ;;
  esac

  # Always configure the preview command so ctrl-/ (toggle-preview) works;
  # when preview is off it just starts hidden.  fzf's toggle-preview is a
  # no-op when no --preview command is set, which is why a disabled preview
  # could not be toggled back on.
  fzf_opts+=(--preview="bash '$SCRIPT_PATH' --preview {-1}")
  if [ "$SHOW_PREVIEW" = "on" ]; then
    fzf_opts+=(--preview-window="right,50%,border-left,nowrap")
  else
    fzf_opts+=(--preview-window="right,50%,border-left,nowrap,hidden")
  fi

  set +e
  # pipefail is on, so `gather | fzf` reports the RIGHTMOST non-zero status: if
  # the user accepts while rows are still streaming, fzf exits 0 but the
  # producer dies of SIGPIPE and fzf_rc became 141 — neither the switch branch
  # (0) nor find-or-create (1) ran, so the popup just closed and did nothing.
  # Take fzf's own status from PIPESTATUS instead.
  # pipefail off for THIS pipeline only.  With it on, `gather | fzf` reports the
  # rightmost non-zero status: accept while rows are still streaming and fzf
  # exits 0 but the producer dies of SIGPIPE, so the status became 141 —
  # matching neither the switch branch (0) nor find-or-create (1), and the popup
  # just closed having done nothing.  (PIPESTATUS is no help here: inside a
  # command substitution it describes the substitution, not the inner pipeline.)
  set +o pipefail
  out=$(gather_targets | fzf "${fzf_opts[@]}")
  fzf_rc=$?
  set -o pipefail
  set -e

  # ctrl-o cancelled the dir picker — reopen the navigator
  [ -s "$RESUME_FILE" ] && continue

  # Action modes stay open via execute+reload; reaching here means quit
  [ "$INTERDIMUX_MODE" != "switch" ] && exit 0

  # Switch mode emits the query first (--print-query), then the selection
  mapfile -t out_lines <<< "$out"
  query="${out_lines[0]:-}"
  selection="${out_lines[1]:-}"

  if [ "$fzf_rc" -eq 0 ] && [ -n "$selection" ]; then
    spec="${selection##*	}"
    parse_spec "$spec"
    # A directory row has no session yet — Enter means "open it", which is the
    # whole point of listing dirs inline (IDEAS #14).
    if [ "$SPEC_TYPE" = "D" ]; then
      if [ -d "$SPEC_DIR" ]; then
        # Physical, as ctrl-o's accept and --connect-dir resolve theirs (the
        # D: path is the recent list's or zoxide's spelling): the session is
        # then created where every lookup of it expects it, and hydrated by
        # the same startup.conf glob as from anywhere else.
        dir_path=$(cd -- "$SPEC_DIR" 2>/dev/null && pwd -P) || dir_path="$SPEC_DIR"
        record_dir_use "$dir_path"
        connect_dir "$dir_path" || imux_msg "could not open $SPEC_DIR"
      else
        imux_msg "$(spec_label) no longer exists"
      fi
      exit 0
    fi
    # The client that opened the picker, not whichever one tmux would guess
    # (see TMUX_C) -- a key on another terminal while this one was picking used
    # to make THAT terminal the one that switched.
    target=$(spec_target)
    # A window or pane row is checked by index first (spec_at): once its index
    # has closed, the target finds a window NAMED that number, and Enter went
    # there.  Switched to by the IDs the check found.
    case "$SPEC_TYPE" in
      W|P) if spec_at "$target"; then target="$SPEC_AT"; else target=""; fi ;;
    esac
    if [ -z "$target" ] \
       || ! tmux switch-client ${TMUX_C[@]+"${TMUX_C[@]}"} -t "$target" 2>/dev/null; then
      imux_msg "$(spec_label) no longer exists"
    fi
    exit 0
  fi

  # Find-or-create: Enter on a query that matched nothing creates a
  # session named after it (resolved as a path, then via zoxide, then
  # under $HOME)
  if [ "$fzf_rc" -eq 1 ] && [ -n "$query" ]; then
    create_from_query "$query" || true
    exit 0
  fi

  exit 0
done
