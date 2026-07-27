#!/usr/bin/env bash
#
# interdimux — fuzzy tmux navigator
#
# Gathers sessions, windows, and panes into a tree-structured fzf list
# and switches to the selected target.  Supports kill, rename, and
# new-session-from-directory actions via fzf keybindings.

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
# INTERDIMUX_BIN (or @interdimux-binary) to use a binary installed elsewhere.
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
)
OPT_NAMES=()
for _m in "${OPT_MAP[@]}"; do OPT_NAMES+=("${_m%%:*}"); done
unset _m

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
  # The dashboard is not the hot path — it keeps the simple launcher.
  tmux bind-key "$_bk_dash" run-shell -b "TMUX_PANE=#{pane_id} bash '$SQ_SCRIPT_FMT' --dashboard-launch"

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
      tmux bind-key -n "$_bk_k" run-shell -b "TMUX_PANE=#{pane_id} bash '$SQ_SCRIPT_FMT' --jump $_bk_i" 2>/dev/null
    done
    unset _bk_i _bk_k
  fi

  # run-shell -C needs tmux >= 3.4; below it, keep the original binding.
  if [ "$_bk_tvnum" -lt 304 ]; then
    tmux bind-key "$_bk_nav" run-shell -b "TMUX_PANE=#{pane_id} bash '$SQ_SCRIPT_FMT' --launch switch"
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

if ! command -v fzf >/dev/null 2>&1; then
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
    if [ "$fzf_major" -eq 0 ] && [ "$fzf_minor" -lt 40 ]; then
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
# A deep scan is a footgun rather than a preference: `find -maxdepth 40` over
# $HOME does not return within a popup's lifetime.
[ "$SCAN_DEPTH" -gt 10 ] && SCAN_DEPTH=10
case "$ORDER" in mru|index) ;; *) ORDER=mru ;; esac

# ---------------------------------------------------------------------------
# Colours — configurable palette
# ---------------------------------------------------------------------------
#
# Every colour is a tmux option (env INTERDIMUX_COLOR_* → @interdimux-color-*
# → built-in default).  A value is a hex "#rrggbb", a 256-colour index, or
# "-1"/"default" (inherit the terminal).  The built-in defaults reproduce the
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

# Render a configured colour into the escape/style each sink needs.  These set
# REPLY instead of printing: set_palette runs on every script invocation (each
# fzf callback re-execs the script), so a $(…) subshell per colour is pure
# overhead — ~30 forks that cost ~1s under load.
#   sgr_of  "#rrggbb" -> "38;2;r;g;b"   "NNN" -> "38;5;NNN"   -1/empty -> ""
sgr_of() {
  case "$1" in
    '#'??????) REPLY="38;2;$((16#${1:1:2}));$((16#${1:3:2}));$((16#${1:5:2}))" ;;
    ''|-1|default|*[!0-9]*) REPLY="" ;;
    *) REPLY="38;5;$1" ;;
  esac
}
# esc/escb set REPLY to the SGR escape.  The trailing test/assignment always
# yields status 0 so they are safe as bare calls under set -e.
esc()  { sgr_of "$1"; [ -z "$REPLY" ] || REPLY=$'\033['"$REPLY"'m'; }  # coloured
escb() { sgr_of "$1"; REPLY=$'\033[1'"${REPLY:+;$REPLY}"'m'; }         # bold+coloured
# tmux style value (-S/-H): hex and -1 pass through; a bare index needs "colour"
tmux_color() {
  case "$1" in
    '#'*|-1|default|*[!0-9]*) REPLY="$1" ;;
    *) REPLY="colour$1" ;;
  esac
}

# fzf --color chrome, rebuilt from the palette (fzf accepts hex/index/-1 as-is)
build_fzf_colors() {
  FZF_COLORS="--color=hl:${COLOR_PATH},hl+:${COLOR_MATCH_CURRENT}:bold,fg+:${COLOR_QUERY},bg+:${COLOR_CURRENT_BG},prompt:${COLOR_ACCENT},pointer:${COLOR_ACCENT},marker:${COLOR_SUCCESS},spinner:${COLOR_ACCENT},info:${COLOR_TREE},header:${COLOR_HEADER},border:${COLOR_BORDER},separator:${COLOR_BORDER},scrollbar:${COLOR_BORDER},label:${COLOR_PATH},preview-label:${COLOR_PATH},gutter:-1,query:${COLOR_QUERY}"
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

# Header hint builder: accent key + dim label pairs.  hint_r sets REPLY so the
# navigator can build all four per-row-type headers with no subshell at all
# (they are handed to fzf as env vars for the focus bind — see below); hint
# keeps the printing form for the handlers whose whole job is to emit one.
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

# Shared fzf theme — applied to all pickers for consistency.  Built once,
# tiered by fzf version so old installs keep a working (plainer) UI.
FZF_THEME=()
build_fzf_theme() {
  local info=inline
  fzf_ge 42 && info=inline-right
  FZF_THEME=(
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

# Whether the cheap fzf callbacks (per-row header, match-scope prompt) can be
# answered by an inline POSIX snippet instead of re-exec'ing this script.  Both
# only ever pick between strings this process already knows, so the re-exec was
# pure overhead on every cursor move.
#
# Off when: fzf is too old for --with-shell (< 0.51), or the user set their own
# --with-shell in @interdimux-fzf-opts — user opts are appended last and win, so
# the snippet could land in a shell with no POSIX `case` (fish).  Either way the
# --header-for / --scope-prompt handlers below remain as the fallback.
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
if [ -n "$EXTRA_MARKERS" ]; then
  IFS=':' read -ra _extra_markers <<< "$EXTRA_MARKERS"
  PROJECT_MARKERS+=("${_extra_markers[@]}")
fi

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

load_recent_dirs() {
  local d count=0
  local -A _recent_seen=()
  if [ -f "$RECENT_DIRS_FILE" ]; then
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      [[ -v "_recent_seen[$d]" ]] && continue
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
      [ -d "$d" ] || continue
      [[ -v "_recent_seen[$d]" ]] && continue
      _recent_seen["$d"]=1
      echo "$d"
      zcount=$((zcount + 1))
      [ "$zcount" -ge "$RECENT_LIMIT" ] && break
    done < <(zoxide query --list 2>/dev/null || true)
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
      [ -d "$d" ] || continue
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

# Directory of a session's active pane — used to detect whether an
# existing session with a given name belongs to a directory.
session_dir() {
  tmux list-panes -t "=$1" -F '#{pane_current_path}' -f '#{pane_active}' 2>/dev/null | head -1
}

# Derive a session name for a directory.  When a same-named session
# exists for a *different* directory, disambiguate with the parent dir
# name (then numeric suffixes) instead of silently reusing it.
resolve_session_name() {
  local dir_path="$1"
  local session_name base_name parent_name n
  session_name=$(basename "$dir_path" | tr '.:' '-')

  if tmux has-session -t "=$session_name" 2>/dev/null; then
    if [ "$(session_dir "$session_name")" != "$dir_path" ]; then
      base_name="$session_name"
      parent_name=$(basename "$(dirname "$dir_path")" | tr '.:' '-')
      session_name="${parent_name}-${base_name}"
      n=2
      while tmux has-session -t "=$session_name" 2>/dev/null; do
        [ "$(session_dir "$session_name")" = "$dir_path" ] && break
        session_name="${base_name}-${n}"
        n=$((n + 1))
      done
    fi
  fi
  printf '%s' "$session_name"
}

# ---------------------------------------------------------------------------
# Session hydration — run a per-project startup command in a new session
# ---------------------------------------------------------------------------
#
# Resolution order, first match wins:
#   1. ~/.config/interdimux/startup.conf   "<glob><whitespace><command>"
#   2. a .interdimux-startup file in the directory itself (contents = command)
#   3. @interdimux-startup-command          (global fallback)
#
# Delivery is `send-keys`, deliberately, and not the pane's initial command.
# sesh shipped exec-based delivery in v2.26.0 and reverted it wholesale in
# v2.26.2: baking the command into the pane loses the prompt echo and the shell
# history entry, reparents the pane into a fresh shell when the command exits,
# and double-initialises the shell (breaking gitstatus/p10k).  send-keys keeps
# the command an ordinary thing the user typed.

# The startup command for DIR, or empty.  Sets REPLY.
resolve_startup_command() {
  local dir="$1" conf="${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/startup.conf"
  REPLY=""

  # 1. glob table.  Patterns are matched against the absolute path; the first
  #    matching line wins, so put specific patterns above general ones.
  if [ -f "$conf" ]; then
    local line pat cmd
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      pat="${line%%[[:space:]]*}"
      cmd="${line#"$pat"}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      [ -n "$pat" ] && [ -n "$cmd" ] || continue
      # shellcheck disable=SC2254  # the pattern is a glob by design
      case "$dir" in $pat) REPLY="$cmd"; return 0 ;; esac
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
  # One send-keys per line, so a multi-line .interdimux-startup behaves like
  # typing each command in turn.
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    tmux send-keys -t "$target" -- "$line" Enter 2>/dev/null || true
  done <<< "$cmd"
  return 0
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
connect_dir() {
  local dir="$1" name="${2:-}"
  [ -n "$name" ] || name=$(resolve_session_name "$dir")
  [ -n "$name" ] || return 1

  if ! tmux has-session -t "=$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$dir" 2>/dev/null || return 1
    hydrate_session "$name" "$dir"
  fi
  tmux switch-client -t "=$name" 2>/dev/null || true
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

# Build the tmux target string (with = prefix for exact matching)
spec_target() {
  case "$SPEC_TYPE" in
    S) printf '%s' "=$SPEC_SESSION" ;;
    W) printf '%s' "=$SPEC_SESSION:$SPEC_WIDX" ;;
    P) printf '%s' "=$SPEC_SESSION:$SPEC_WIDX.$SPEC_PIDX" ;;
    D) printf '%s' "$SPEC_DIR" ;;
  esac
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

build_process_table() {
  [ "$PROC_CMDLINE_OK" = 1 ] && return 0   # /proc backend needs no table
  local pid ppid args
  while read -r pid ppid args; do
    PS_ARGS[$pid]="$args"
    PS_CHILDREN[$ppid]+="$pid "
  done < <(ps -eo pid=,ppid=,args= 2>/dev/null)
  return 0
}

# Render raw argv the way `ps args=` does, so both backends produce identical
# rows: NUL and newline become a space, every other non-printable byte becomes
# '?'.  This is not cosmetic.  ps was implicitly protecting the row contract —
# a raw newline in argv would split the row in two, detaching its trailing SPEC
# field, and a raw \x1f would reach an fzf-visible field.  The scan is guarded,
# so the common (clean) case costs one pattern test.
sanitize_args() {
  REPLY="$1"
  case "$REPLY" in
    *[[:cntrl:]]*) ;;
    *) return 0 ;;
  esac
  REPLY="${REPLY//$'\n'/ }"
  local out="" i ch
  for (( i = 0; i < ${#REPLY}; i++ )); do
    ch="${REPLY:i:1}"
    case "$ch" in
      [[:cntrl:]]) out+='?' ;;
      *)           out+="$ch" ;;
    esac
  done
  REPLY="$out"
  return 0
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

# Known shells — used to decide whether to descend one level
SHELLS_PATTERN='^-?(ba|z|fi|da|a|k|tc|c)?sh$|^-?login$'

# Get the user's actual command from a pane pid.
# Strategy: if the pane process is a shell, show its direct child (the
# command the user typed).  Do NOT walk further — deeper children are
# subprocesses of that command (LSPs, formatters, watchers, …) and
# showing those is misleading.
#
# The shell test MUST come from the pane process's own argv.  tmux's
# #{pane_current_command} names the pane tty's FOREGROUND process group, which
# is the running command, not the shell — so gating on it inverts the test
# exactly when a command is running and every busy pane renders as "-zsh".
full_command() {
  local pid="$1" args children child

  if [ "$PROC_CMDLINE_OK" = 1 ]; then
    read_cmdline "$pid"; args="$REPLY"
  else
    args="${PS_ARGS[$pid]:-}"
  fi

  local cmd_name="${args%% *}"
  cmd_name="${cmd_name##*/}"

  # If the pane process is a shell, look one level down
  if [[ "$cmd_name" =~ $SHELLS_PATTERN ]]; then
    if [ "$PROC_CMDLINE_OK" = 1 ]; then
      children=""
      # The children file has NO trailing newline, so `read` assigns the value
      # and THEN reports EOF.  A `|| children=""` fallback here would wipe what
      # it just read and silently disable child resolution for every pane.
      { read -r children < "/proc/$pid/task/$pid/children"; } 2>/dev/null || :
    else
      children="${PS_CHILDREN[$pid]:-}"
    fi
    if [ -n "$children" ]; then
      child="${children%% *}"
      if [ "$PROC_CMDLINE_OK" = 1 ]; then
        read_cmdline "$child"
      else
        REPLY="${PS_ARGS[$child]:-}"
      fi
      return 0
    fi
  fi

  # Not a shell (or shell has no children) — use as-is
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
  if [[ -v "GIT_BRANCH_CACHE[$_cache_key]" ]]; then
    REPLY="${GIT_BRANCH_CACHE[$_cache_key]}"
    return
  fi

  local d="$dir"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    local head_file=""
    if [ -d "$d/.git" ]; then
      head_file="$d/.git/HEAD"
    elif [ -f "$d/.git" ]; then
      # Worktrees/submodules: .git is a file containing "gitdir: <path>"
      local gitdir_line
      read -r gitdir_line < "$d/.git" 2>/dev/null || { d="${d%/*}"; continue; }
      local gitdir="${gitdir_line#gitdir: }"
      # Resolve relative paths
      case "$gitdir" in
        /*) ;;
        *)  gitdir="$d/$gitdir" ;;
      esac
      [ -f "$gitdir/HEAD" ] && head_file="$gitdir/HEAD"
    fi

    if [ -n "$head_file" ] && [ -f "$head_file" ]; then
      local head_content
      read -r head_content < "$head_file" 2>/dev/null || break
      local branch=""
      case "$head_content" in
        "ref: refs/heads/"*) branch="${head_content#ref: refs/heads/}" ;;
        *) branch="@${head_content:0:7}" ;;
      esac
      GIT_BRANCH_CACHE["$_cache_key"]="$branch"
      REPLY="$branch"
      return
    fi
    d="${d%/*}"
  done

  GIT_BRANCH_CACHE["$_cache_key"]=""
}

# ---------------------------------------------------------------------------
# Smart command formatting (SSH host, editor context)
# ---------------------------------------------------------------------------

EDITORS_PATTERN='^(n?vim|vi|nano|emacs|code|hx|helix|micro|kate|gedit|subl)$'

# SSH flags that consume the next argument (so we skip both flag and value)
SSH_FLAGS_WITH_VALUE='^-(b|c|D|E|e|F|I|i|J|L|l|m|O|o|p|Q|R|S|W|w)$'

# Editor flags that consume the next argument
EDITOR_FLAGS_WITH_VALUE='^-[uUsSpc]$|^--cmd$|^--listen$'

format_command() {
  local cmd_str="$1"
  REPLY=""                       # reset: callers read REPLY after a bare call
  [ -z "$cmd_str" ] && return
  local cmd_name="${cmd_str%% *}"
  local cmd_base="${cmd_name##*/}"

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
          -*)
            [[ "$word" =~ $SSH_FLAGS_WITH_VALUE ]] && skip_next=1
            ;;
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
  if [[ "$cmd_base" =~ $EDITORS_PATTERN ]]; then
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
        -*)
          [[ "$word" =~ $EDITOR_FLAGS_WITH_VALUE ]] && skip_next=1
          ;;
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
  printf -v REPLY '%s%s%s' "$DIM_CMD" "$cmd_str" "$RST"
}

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
term_cols() {
  # fzf exports FZF_COLUMNS to the children it spawns (reload, preview,
  # execute), so every ctrl-r reload can skip the stty fork.  It reads 0
  # during fzf's own `start` event, hence the numeric guard rather than a
  # bare emptiness test.  The initial launch-time gather has no fzf parent
  # and still falls back to stty.
  if [[ "${FZF_COLUMNS:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$FZF_COLUMNS"
    return 0
  fi
  local dims cols=80
  if dims=$({ stty size </dev/tty; } 2>/dev/null); then
    cols="${dims#* }"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  printf '%s' "$cols"
}

# Column widths for the navigator tree.  Sized to the ACTUAL content
# (longest session name / window name / path) so the important window
# names are never starved by a long, redundant session prefix, then
# squeezed to fit the popup width — the dim session prefix shrinks first,
# the window name is protected last.  Measurement is fork-free (pure
# parameter ops over the strings tmux already handed us), so this adds no
# processes to the hot path.
#
#   IDENT_W = IDENT_OV + PFX_W + WIN_W
#
# where IDENT_OV covers the marker + tree-glyph columns, PFX_W is the
# (redundant) session-name prefix carried on child rows, and WIN_W is the
# protected window-name budget.
IDENT_W=24 PATH_W=24 BADGE_W=16 PFX_W=14 WIN_W=12
IDENT_OV=6            # marker(1) + " ├─ "(4) + the space after the prefix(1)
CMD_MIN=12            # columns kept for the flowing (unpadded) command field
WIDTH_GUTTER=8        # fzf pointer/marker/scrollbar overhead
PFX_FLOOR=6  PFX_CEIL=16
WIN_FLOOR=8  WIN_CEIL=40
PATH_FLOOR=12 PATH_CEIL=44
MAX_SESS=0 MAX_WIN=0 MAX_PATH=0

# Longest session name, window identity ("index:name") and displayed
# (~-substituted) path across every target.  Fork-free; reads the raw
# tmux dumps gather_targets already fetched (visible via dynamic scope)
# and sets the MAX_* globals.  Every (( … )) test sits on the LEFT of &&
# (set-e-exempt); the explicit `return 0` keeps the function's own status
# 0 — the trailing loop would otherwise propagate a false (( … )) and
# abort a set -e caller of the bare call in gather_targets.
measure_widths() {
  MAX_SESS=0 MAX_WIN=0 MAX_PATH=0
  local _sla sname _sw _sa _sn widx wname _wa _wc wpath _rest _pi _pa _pc ppath _pr il dp
  while IFS="$US" read -r _sla sname _sw _sa; do
    [ -z "$sname" ] && continue
    (( ${#sname} > MAX_SESS )) && MAX_SESS=${#sname}
  done <<< "$sessions_raw"
  while IFS="$US" read -r _sn widx wname _wa _wc wpath _rest; do
    [ -z "$_sn" ] && continue
    il=$(( ${#widx} + 1 + ${#wname} ))
    (( il > MAX_WIN )) && MAX_WIN=$il
    dp="${wpath/#$HOME/\~}"
    (( ${#dp} > MAX_PATH )) && MAX_PATH=${#dp}
  done <<< "$all_windows_raw"
  while IFS="$US" read -r _sn widx _pi _pa _pc ppath _pr; do
    [ -z "$_sn" ] && continue
    dp="${ppath/#$HOME/\~}"
    (( ${#dp} > MAX_PATH )) && MAX_PATH=${#dp}
  done <<< "$all_panes_raw"
  return 0
}


# The live preview state ("on"/"off").  ctrl-/ writes the new value to
# $INTERDIMUX_PREVIEW_STATE so a reload child can size its columns for the
# geometry the user is actually looking at.
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
  # after launch, and fzf reports the FULL terminal width in FZF_COLUMNS either
  # way (verified), so without this the rows stay sized for the old geometry and
  # fzf just clips them with an ellipsis.  That is IDEAS #26.
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

  if   (( avail >= 72 )); then BADGE_W=16
  elif (( avail >= 52 )); then BADGE_W=14
  elif (( avail >= 40 )); then BADGE_W=10
  else                         BADGE_W=0
  fi

  IDENT_W=$(( IDENT_OV + PFX_W + WIN_W ))

  # Squeeze to fit.  The dim session prefix is redundant (the full name is
  # on the session header row), so it shrinks first; then the git badge —
  # snapped straight to 0 in one step, never left at 1..3 which would make
  # build_ctx_field's ${gbranch:0:BADGE_W-3} slice degenerate; then the
  # path; the window name is protected and shrinks last.  Any leftover
  # deficit lands on the flowing COMMAND column, which fzf clips anyway.
  local ctx_w need guard=0
  while :; do
    if (( BADGE_W > 0 )); then ctx_w=$(( PATH_W + 3 + BADGE_W ))
    else                       ctx_w=$(( PATH_W + 2 )); fi
    need=$(( IDENT_W + ctx_w + 2 + CMD_MIN ))
    (( need <= avail )) && break
    (( guard++ > 400 )) && break
    if   (( PFX_W  > PFX_FLOOR  )); then PFX_W=$(( PFX_W - 1 ));  IDENT_W=$(( IDENT_W - 1 ))
    elif (( BADGE_W > 0 ));         then BADGE_W=0
    elif (( PATH_W > PATH_FLOOR )); then PATH_W=$(( PATH_W - 1 ))
    elif (( WIN_W  > WIN_FLOOR  )); then WIN_W=$(( WIN_W - 1 ));  IDENT_W=$(( IDENT_W - 1 ))
    else break
    fi
  done
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

# Path + git badge + window flag glyphs, padded into the CONTEXT column.
# Args: path zoomed bell activity
build_ctx_field() {
  local path="$1" zoomed="$2" bell="$3" activity="$4"
  local disp gbranch badge blen
  fld_reset
  disp="${path/#$HOME/\~}"
  disp="${disp//$'\t'/ }"   # tabs are the field delimiter
  trim_path "$disp" "$PATH_W"; disp="$REPLY"
  fld_add "${SEP} " 2
  fld_add "${DIM_PATH}${disp}${RST}" "${#disp}"
  fld_pad $(( PATH_W + 2 ))
  if [ "$BADGE_W" -gt 0 ]; then
    badge="" blen=0
    get_git_branch "$path"; gbranch="$REPLY"
    if [ -n "$gbranch" ]; then
      [ "${#gbranch}" -gt $(( BADGE_W - 2 )) ] && gbranch="${gbranch:0:BADGE_W-3}…"
      badge=" ${DIM_GIT}‹${gbranch}›${RST}"
      blen=$(( ${#gbranch} + 3 ))
    fi
    [ "$zoomed" = "1" ]   && { badge+=" ${BOLD_AMBER}Z${RST}"; blen=$((blen + 2)); }
    [ "$bell" = "1" ]     && { badge+=" ${BOLD_RED}!${RST}";   blen=$((blen + 2)); }
    [ "$activity" = "1" ] && { badge+=" ${DIM_SSH}#${RST}";    blen=$((blen + 2)); }
    fld_add "$badge" "$blen"
    fld_pad $(( PATH_W + 3 + BADGE_W ))
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
# for it.  SESSION_DIRS holds the cwd of each session's active window, so a
# directory that already has a session is not offered again.
emit_dir_rows() {
  [ "$SHOW_DIRS" = "on" ] || return 0
  [[ "$DIRS_LIMIT" =~ ^[0-9]+$ ]] || return 0
  [ "$DIRS_LIMIT" -gt 0 ] || return 0

  local d disp base ident ctx type_badge n=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # A tab would break the 4-field row contract; a session already covers it
    case "$d" in *$'\t'*) continue ;; esac
    [[ -v "SESSION_DIRS[$d]" ]] && continue

    base="${d##*/}"
    [ -n "$base" ] || base="$d"
    base="${base//$'\t'/ }"
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

gather_targets() {
  local current_session current_window current_pane cur_raw
  local sessions_raw all_windows_raw all_panes_raw
  local _hline

  # The process table for full-command resolution is built LAZILY, only on the
  # bash-renderer fallback path below (see before measure_widths).  The Rust core
  # resolves commands itself now — from /proc on Linux, from its own ps snapshot
  # everywhere else — so when the binary is present bash never forks ps at all.

  local _sfmt _wfmt _pfmt _curfmt
  _sfmt="#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_name}${US}#{session_windows}${US}#{?session_attached,attached,}"
  _wfmt="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_panes}${US}#{pane_pid}${US}#{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag}"
  _pfmt="#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{pane_pid}${US}#{window_panes}"
  _curfmt="#S${US}#I${US}#P"

  # One tmux invocation instead of four.  A tmux client accepts a `;`-separated
  # command list, and each round-trip costs ~5-6 ms of connect/teardown on top
  # of the query itself — all of it ahead of the first emitted row.
  #
  # Sections are separated by RS (\x1e).  Note the ORDER: the only command here
  # that can fail is the current-target lookup (a stale $TMUX_PANE), and tmux
  # aborts the remainder of a command list on failure — so it goes LAST, where
  # it cannot swallow the bulk data.
  local _batched=0 _all RS=$'\x1e'
  local -a _parts=()
  if [ -z "${INTERDIMUX_NO_BATCH:-}" ]; then
    _all=$(tmux \
      list-sessions -F "$_sfmt" \; \
      display-message -p "$RS" \; \
      list-windows -a -F "$_wfmt" \; \
      display-message -p "$RS" \; \
      list-panes -a -F "$_pfmt" \; \
      display-message -p "$RS" \; \
      display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} "$_curfmt" 2>/dev/null)
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
    # Current target: anchor to $TMUX_PANE when tmux provides it (popups
    # and run-shell both do) — a bare display-message in a clientless
    # context silently resolves to the most recently attached session.
    cur_raw=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} "$_curfmt")
    sessions_raw=$(tmux list-sessions -F "$_sfmt")
    all_windows_raw=$(tmux list-windows -a -F "$_wfmt")
    all_panes_raw=$(tmux list-panes -a -F "$_pfmt")
  fi
  IFS="$US" read -r current_session current_window current_pane <<< "$cur_raw"

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
    local _hp _hname _hkeep _hout=""
    while IFS= read -r _hline; do
      [ -n "$_hline" ] || continue
      _hname="${_hline#*"$US"}"; _hname="${_hname%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254  # the pattern is a glob by design
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done <<< "$sessions_raw"
    sessions_raw="${_hout%$'\n'}"

    # windows and panes carry the session name in field 1
    _hout=""
    while IFS= read -r _hline; do
      [ -n "$_hline" ] || continue
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done <<< "$all_windows_raw"
    all_windows_raw="${_hout%$'\n'}"

    _hout=""
    while IFS= read -r _hline; do
      [ -n "$_hline" ] || continue
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done <<< "$all_panes_raw"
    all_panes_raw="${_hout%$'\n'}"
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
    _imux_out=$(
      INTERDIMUX_COLS="$(term_cols)" \
      INTERDIMUX_NOW="$NOW_EPOCH" \
      INTERDIMUX_SHOW_FULL_COMMAND="$SHOW_FULL_COMMAND" \
      INTERDIMUX_SHOW_GIT_BRANCH="$SHOW_GIT_BRANCH" \
      INTERDIMUX_SHOW_PREVIEW="$(live_preview_state)" \
      INTERDIMUX_ORDER="$ORDER" \
      INTERDIMUX_SHOW_DIRS="$SHOW_DIRS" \
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
      "$IMUX_BIN" gather <<IMUX_SECTIONS
${sessions_raw}
$RS
${all_windows_raw}
$RS
${all_panes_raw}
$RS
${cur_raw}
IMUX_SECTIONS
    ) || _imux_out=""
    # A failed or empty render must fall through to the bash renderer, never be
    # mistaken for "there is nothing to show".  Capturing costs ~2ms (the binary
    # renders the whole list in about that) and buys a safe failure mode.
    if [ -n "$_imux_out" ]; then
      printf '%s\n' "$_imux_out"
      return 0
    fi
  fi

  # We only reach here when the Rust core is absent or fell through — i.e. the
  # bash renderer will do the work, and IT needs the ps process table (the binary
  # built its own).  On Linux this is a no-op (the /proc backend needs no table);
  # elsewhere it is the one ps fork, paid only when there is no working binary.
  [ "$SHOW_FULL_COMMAND" = "on" ] && build_process_table

  # Size the columns to the content we just fetched (fork-free).
  measure_widths
  compute_widths

  # MRU ordering: most recently attended sessions first (last-attached,
  # falling back to activity for never-attached sessions); the current
  # session moves to the END so the top row is the previous session —
  # Enter with an empty query toggles back to it.  --cycle makes the
  # current session's windows one ↑ away.
  if [ "$ORDER" = "mru" ]; then
    local sorted current_line="" other_lines="" line sn_check
    sorted=$(printf '%s\n' "$sessions_raw" | sort -t"$US" -k1,1nr)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      sn_check="${line#*"$US"}"
      sn_check="${sn_check%%"$US"*}"
      if [ "$sn_check" = "$current_session" ]; then
        current_line="$line"
      else
        other_lines+="${line}"$'\n'
      fi
    done <<< "$sorted"
    sessions_raw="${other_lines}${current_line}"
    sessions_raw="${sessions_raw%$'\n'}"
  fi

  # cwd of each session's active window — emit_dir_rows uses it to skip
  # directories that already have a session.
  declare -A SESSION_DIRS=()

  # Build lookup: windows grouped by session name
  declare -A windows_by_session=()
  while IFS= read -r line; do
    local sn="${line%%"$US"*}"
    if [[ -v "windows_by_session[$sn]" ]]; then
      windows_by_session["$sn"]+=$'\n'"$line"
    else
      windows_by_session["$sn"]="$line"
    fi
  done <<< "$all_windows_raw"

  # Build lookup: panes grouped by "session\x1fwindow_index"
  declare -A panes_by_window=()
  while IFS="$US" read -r sn widx rest; do
    local key="${sn}${US}${widx}"
    if [[ -v "panes_by_window[$key]" ]]; then
      panes_by_window["$key"]+=$'\n'"$rest"
    else
      panes_by_window["$key"]="$rest"
    fi
  done <<< "$all_panes_raw"

  local sla sname swins sattach marker meta age sdisp
  local session_windows win_count wi branch_glyph cont idname maxid ident ctx
  local wmarker raw_cmd cmd_formatted wflags
  local pane_data pane_count pi pglyph pmarker pprefix pdisp pover

  while IFS="$US" read -r sla sname swins sattach; do
    [ -z "$sname" ] && continue
    marker=" "
    [ "$sname" = "$current_session" ] && marker="${MARKER_COLOR}*${RST}"

    # Session row: identity | meta | (empty command) | spec.  Tabs in
    # names would break the field contract — display them as spaces.
    # The name is capped so the row never exceeds the identity column
    # (4 = marker + space + ▸ + space).
    sdisp="${sname//$'\t'/ }"
    [ "${#sdisp}" -gt $(( IDENT_W - 4 )) ] && sdisp="${sdisp:0:IDENT_W-5}…"
    fld_reset
    fld_add "$marker" 1
    fld_add " ${DIM_TREE}▸${RST} " 3
    fld_add "${BOLD}${sdisp}${RST}" "${#sdisp}"
    fld_pad "$IDENT_W"
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
      format_command "$raw_cmd"; cmd_formatted="$REPLY"

      printf '%s\t%s\t%s\tW:%s:%s\n' \
        "$ident" "$ctx" "$cmd_formatted" "$sname" "$widx"

      # Panes (only for multi-pane windows)
      if [ "$wpanes" -gt 1 ]; then
        pane_data="${panes_by_window[${sname}${US}${widx}]:-}"
        [ -z "$pane_data" ] && continue

        pane_count="${pane_data//[!$'\n']/}"
        pane_count=$(( ${#pane_count} + 1 ))
        pi=0

        while IFS="$US" read -r pidx _pact pcmd ppath ppid _wp2; do
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
          if [ "$pover" -gt 0 ] && [ "${#pdisp}" -gt $(( pover + 1 )) ]; then
            pdisp="${pdisp:0:${#pdisp}-pover-1}…"
          fi
          pprefix="${pdisp} ${widx}."
          fld_reset
          fld_add "$pmarker" 1
          fld_add " ${DIM_TREE}${cont} ${pglyph}${RST} " 6
          fld_add "${DIM}${pprefix}${RST}${pidx}" $(( ${#pprefix} + ${#pidx} ))
          fld_pad "$IDENT_W"
          ident="$FLD"

          build_ctx_field "$ppath" "" "" ""
          ctx="$FLD"

          resolve_command "$pcmd" "$ppid"; raw_cmd="$REPLY"
          format_command "$raw_cmd"; cmd_formatted="$REPLY"

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
      # Trailing colon: resolves the session to its active pane (a bare
      # "=name" is not a valid pane target on newer tmux)
      info=$(tmux display-message -p -t "=${SPEC_SESSION}:" \
        "#{session_windows}${US}#{?session_attached,attached,detached}" 2>/dev/null)
      IFS="$US" read -r s_wins s_att <<< "$info"
      printf "${BOLD_AMBER}▸ %s${RST}  ${DIM}%s win · %s${RST}\n" \
        "$SPEC_SESSION" "${s_wins:-?}" "${s_att:-}"
      preview_rule
      tmux list-windows -t "=$SPEC_SESSION" \
        -F "#{window_index}:#{window_name}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_active}${US}#{window_panes}" 2>/dev/null | \
      while IFS="$US" read -r wid wcmd wpath wact wpanes; do
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
      print_capture "$(tmux capture-pane -t "=${SPEC_SESSION}:" -p -e -S -30 2>/dev/null)" || echo "(no active pane)"
      ;;
    *)
      info=$(tmux display-message -p -t "$target" \
        "#{pane_current_command}${US}#{pane_current_path}" 2>/dev/null)
      IFS="$US" read -r p_cmd p_path <<< "$info"
      p_path="${p_path/#$HOME/\~}"
      if [ "$SPEC_TYPE" = "W" ]; then
        printf "${BOLD_AMBER}%s:%s${RST}" "$SPEC_SESSION" "$SPEC_WIDX"
      else
        printf "${BOLD_AMBER}%s:%s.%s${RST}" "$SPEC_SESSION" "$SPEC_WIDX" "$SPEC_PIDX"
      fi
      printf "  ${DIM_CMD}%s${RST} ${DIM}·${RST} ${DIM_PATH}%s${RST}\n" \
        "${p_cmd:-?}" "${p_path:-?}"
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
  # One tmux invocation, keyed on each session's ACTIVE window, the same basis
  # the navigator's directory rows use.  This is the ctrl-o picker, not the hot
  # path, so ~5 ms of round-trip is affordable here.
  declare -A DIR_SESSION=()
  while IFS="$US" read -r _ds_name _ds_path; do
    [ -n "$_ds_path" ] || continue
    [[ -v "DIR_SESSION[$_ds_path]" ]] || DIR_SESSION["$_ds_path"]="$_ds_name"
  done < <(tmux list-windows -a -F \
             "#{?window_active,#{session_name}${US}#{pane_current_path},}" 2>/dev/null)

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
    [[ -v "seen[$dir]" ]] && return
    seen["$dir"]=1
    local display_path="${dir/#$HOME/\~}"
    trim_path "$display_path" "$DIRS_PATH_W"; display_path="$REPLY"

    # Already open?  Say so, and say WHERE -- the badge column is outside fzf's
    # match scope, so the session name is display-only and cannot skew results.
    if [[ -v "DIR_SESSION[$dir]" ]]; then
      printf '  %s▸%s  %s\t%s→%s %s%s%s\t%s\n' \
        "$BOLD_AMBER" "$RST" "$(dpad "$display_path" "$DIRS_PATH_W")" \
        "$DIM" "$RST" "$ACCENT_ESC" "${DIR_SESSION[$dir]}" "$RST" "$dir"
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
            for d in "${_matches[@]}"; do
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
# What a query WOULD become.  Sets CREATE_DIR / CREATE_NAME / CREATE_SRC;
# returns 1 when the query cannot produce a session at all.
#
# One resolver for both the header and the accept, because they used to derive
# the name independently and disagreed: describe_create did a plain
# `basename | tr`, while the accept went through resolve_session_name, which
# DISAMBIGUATES against existing sessions.  With a session "api" already open at
# ~/work/api, typing ~/other/api showed "create api" and created "other-api".
# The header is the only thing telling the user what Enter does, so it has to be
# derived from the same code that does it.
resolve_create_target() {
  local query="$1" expanded
  CREATE_DIR=""; CREATE_NAME=""; CREATE_SRC=""
  [ -n "$query" ] || return 1
  expanded="${query/#\~/$HOME}"
  if [ -d "$expanded" ] && CREATE_DIR=$(cd "$expanded" 2>/dev/null && pwd -P); then
    CREATE_SRC="path"
    # the PHYSICAL path, so a symlinked query names the session after where it
    # actually lands -- describe_create used the unresolved one
    CREATE_NAME=$(resolve_session_name "$CREATE_DIR")
  else
    CREATE_DIR=""
    if [ "$USE_ZOXIDE" = "on" ] && command -v zoxide >/dev/null 2>&1; then
      CREATE_DIR=$(zoxide query -- "$query" 2>/dev/null | head -1) || true
    fi
    if [ -d "$CREATE_DIR" ]; then CREATE_SRC="zoxide"; else CREATE_DIR="$HOME"; CREATE_SRC="home"; fi
    CREATE_NAME=$(printf '%s' "$query" | tr '.: /' '----')
  fi
  [ -n "$CREATE_NAME" ] || return 1
  return 0
}

# Sets REPLY to the session name; prints nothing.
create_from_query() {
  local query="$1"
  REPLY=""
  resolve_create_target "$query" || return 1
  if ! tmux has-session -t "=$CREATE_NAME" 2>/dev/null; then
    record_dir_use "$CREATE_DIR"
  fi
  connect_dir "$CREATE_DIR" "$CREATE_NAME" || return 1
  REPLY="$CREATE_NAME"
  return 0
}

# What find-or-create WOULD do for a query, as a human-readable string.  Used by
# the zero-match header so the feature stops being invisible (IDEAS #1) and a
# typo cannot silently create junk.
describe_create() {
  local query="$1" verb
  REPLY=""
  resolve_create_target "$query" || return 0
  # "switch to", not "create", when the name already exists -- that is what
  # connect_dir does, and promising a new session it will not make is the same
  # class of lie as naming the wrong one.
  if tmux has-session -t "=$CREATE_NAME" 2>/dev/null; then
    verb="switch to"
  else
    verb="create"
  fi
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
  local q_logdir q_log q_sock q_want q_pane q_keys
  shq "$SCHED_LOGDIR"; q_logdir="$REPLY"
  shq "$SCHED_LOG";    q_log="$REPLY"
  shq "$sock";         q_sock="$REPLY"
  shq "$srvpid";       q_want="$REPLY"
  shq "$pane";         q_pane="$REPLY"
  shq "$keys";         q_keys="$REPLY"
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
    "tmux -S \"\$sock\" send-keys -t \"\$pane\" -- ${q_keys} 2>/dev/null || exit 0" \
    "tmux -S \"\$sock\" send-keys -t \"\$pane\" Enter 2>/dev/null"
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
    # run-shell FORMAT-EXPANDS its argument before /bin/sh ever sees it, so a
    # '#H' or '#{...}' in the user's command is substituted by tmux — verified:
    # "echo host-is-#H" arrived as "echo host-is-krootabulon".  Worse, the
    # substituted text is not re-quoted, so a pane title could inject shell.
    # '##' is tmux's escape for a literal '#'.
    _rs_keys="${_keys//\#/##}"
    # POSIX quoting: tmux hands this to /bin/sh, which is dash here.  See shq().
    shq "$SCHED_SOCK"; _q_sock="$REPLY"
    shq "$SCHED_PANE"; _q_pane="$REPLY"
    shq "$_rs_keys";   _q_keys="$REPLY"
    tmux run-shell -b -d "$_when" \
      "tmux -S $_q_sock send-keys -t $_q_pane -- $_q_keys && tmux -S $_q_sock send-keys -t $_q_pane Enter" \
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
  _out=$(cd / && sched_job_body "$SCHED_PANE" "$SCHED_SOCK" "$SCHED_SRVPID" "$SCHED_LABEL" "$_keys" \
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
    tmux display-message "interdimux: could not create a session from '${2:-}'" 2>/dev/null
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
# red (later attributes win in tmux styles, so bg/attrs are preserved)
danger_style() {
  local base
  base=$(popup_user_style)
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
  local style
  if [ "$1" = "danger" ]; then style=$(danger_style); else style=$(popup_user_style); fi
  local -a t=()
  # -T is a FORMAT, and the title now carries the session name, so any '#' in it
  # would be re-expanded on every repaint.  In practice tmux already expands a
  # name at create/rename time -- "has#hash" is stored as "has<hostname>ash" --
  # so only benign sequences ('#x', '#1') can reach here and nothing observable
  # breaks today.  Doubling is free, and this stops being true the moment tmux
  # gains a format character.  The style prefix is left alone: its '#[' is meant
  # as a format.
  [ -n "${INTERDIMUX_TITLE:-}" ] && t=(-T "${POPUP_TITLE_STYLE}${INTERDIMUX_TITLE//'#'/##}")
  tmux display-popup -b "$(popup_user_lines)" -S "$style" ${t[@]+"${t[@]}"} 2>/dev/null || true
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
#   combining marks, ZWJ, U+FE0E                  0
#   everything else                               1
#
# so ❤️ and 日本 come out exact, while a ZWJ sequence like 👨‍💻 counts 4 instead of
# 2 and a flag counts 4 instead of 2 — wide, never narrow.  Exact cluster
# handling lives in the Rust core, where it is on the path that needs it.
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
    if (( (cp >= 0x300 && cp <= 0x36f) || cp == 0x200d || cp == 0xfe0e )); then
      :
    elif (( (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) \
         || (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) \
         || (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) \
         || (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff) \
         || (cp >= 0x1f000 && cp <= 0x1f2ff) || (cp >= 0x20000 && cp <= 0x3fffd) )); then
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
  local field_start=$(( col_prompt + ${#prompt} ))
  local field_end=$(( DLG_LEFT + DLG_W - 3 ))   # one-column gutter before the border
  local field_w=$(( field_end - field_start + 1 ))
  [ "$field_w" -lt 1 ] && field_w=1

  # The prompt is static — draw it once; the loop only repaints the field.
  printf '\033[%d;%dH%s%s%s\033[?25h' \
    "$irow" "$col_prompt" "$accent" "$prompt" "$RST" >>"$tty_out"

  local buf="$initial" pos=${#initial} scroll=0
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
  local c c2 c3 c4 vis pad len
  while true; do
    len=${#buf}
    (( pos < scroll )) && scroll=$pos
    (( pos - scroll >= field_w )) && scroll=$(( pos - field_w + 1 ))
    (( scroll < 0 )) && scroll=0
    vis="${buf:scroll:field_w}"
    printf -v pad '%*s' $(( field_w - ${#vis} )) ''
    # repaint the field and place the cursor; nothing is written outside
    # [field_start, field_end], so the borders are never touched
    printf '\033[%d;%dH%s%s\033[%d;%dH' \
      "$irow" "$field_start" "$vis" "$pad" \
      "$irow" $(( field_start + pos - scroll )) >>"$tty_out"

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
              IFS= read -rsN1 -t 0.05 -u "$ifd" c4          # swallow the trailing '~'
              case "$c3" in
                1|7) pos=0 ;;
                4|8) pos=$len ;;
                3) (( pos < len )) && buf="${buf:0:pos}${buf:pos+1}" ;;   # delete
              esac ;;
          esac
        else
          buf=""; break                                      # lone ESC → cancel
        fi ;;
      $'\x7f'|$'\x08') (( pos > 0 )) && { buf="${buf:0:pos-1}${buf:pos}"; pos=$(( pos - 1 )); } ;;
      $'\x03') buf=""; break ;;                              # Ctrl-C → cancel
      $'\x01') pos=0 ;;                                       # Ctrl-A → start
      $'\x05') pos=$len ;;                                    # Ctrl-E → end
      $'\x15') buf="${buf:pos}"; pos=0 ;;                     # Ctrl-U → delete to start
      $'\x0b') buf="${buf:0:pos}" ;;                          # Ctrl-K → delete to end
      $'\x17')                                                # Ctrl-W → delete word before cursor
        local l="${buf:0:pos}" r="${buf:pos}"
        while [ -n "$l" ] && [ "${l: -1}" = ' ' ]; do l="${l%?}"; done
        while [ -n "$l" ] && [ "${l: -1}" != ' ' ]; do l="${l%?}"; done
        buf="$l$r"; pos=${#l} ;;
      *) [[ -n "$c" && "$c" != [[:cntrl:]] ]] && { buf="${buf:0:pos}$c${buf:pos}"; pos=$(( pos + 1 )); } ;;
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
      zoom) tmux display-message "interdimux: $label is not a tmux target" 2>/dev/null ;;
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
  case "$SPEC_TYPE" in
    S) tmux has-session -t "$target" 2>/dev/null ;;
    *) [ -n "$(tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null)" ] ;;
  esac || {
    if [ "$action" = zoom ]; then
      # zoom has no dialog of its own; it reports through the status line
      tmux display-message "interdimux: $label is gone — press ^r to reload" 2>/dev/null
    else
      info_flash "$BOLD_AMBER" "Gone" "$label no longer exists." "The list is stale — press ^r to reload."
    fi
    exit 0
  }

  case "$action" in
    kill)
      popup_accent danger
      if confirm_dialog "$BOLD_RED" "Kill ${label}?" "This cannot be undone."; then
        case "$SPEC_TYPE" in
          S)
            # Destroying a session detaches its clients (default
            # detach-on-destroy), ejecting the user from tmux even when
            # other sessions exist — hop them to the next MRU session
            # first so the stay-open kill workflow survives.
            fallback=$(tmux list-sessions -F "#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_name}" 2>/dev/null \
              | sort -t "$US" -k1,1nr | cut -d "$US" -f2- \
              | grep -vxF -- "$SPEC_SESSION" | head -1)
            if [ -n "$fallback" ]; then
              while IFS= read -r c; do
                [ -n "$c" ] && tmux switch-client -c "$c" -t "=${fallback}:" 2>/dev/null
              done < <(tmux list-clients -F '#{client_name}' -t "$target" 2>/dev/null)
            fi
            tmux kill-session -t "$target" 2>/dev/null
            ;;
          W) tmux kill-window  -t "$target" 2>/dev/null ;;
          P) tmux kill-pane    -t "$target" 2>/dev/null ;;
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
      current_name=""
      case "$SPEC_TYPE" in
        # display-message -t wants a pane target: a bare "=name" is not
        # valid on newer tmux (expands empty) — use the "=name:" form
        S) current_name=$(tmux display-message -p -t "=${SPEC_SESSION}:" '#{session_name}' 2>/dev/null) ;;
        W) current_name=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) ;;
      esac
      input_dialog "$BOLD_AMBER" "Rename ${label}" "❯ " "$current_name"
      new_name="$REPLY"
      # tmux splits a target at the FIRST ':', so a name containing one makes
      # the session permanently unreachable from this picker: parse_spec is
      # careful to parse indices from the right, but spec_target still emits
      # "=name:idx" and tmux resolves that against the wrong thing.  tmux itself
      # accepts the rename, so refuse it here rather than create a session the
      # user cannot get back to.  ('.' is fine — "=my.app:0" parses correctly.)
      case "$new_name" in
        *:*)
          dialog_status "${RED}✗ a name cannot contain ':' (tmux splits targets there)${RST}"
          sleep 1.2
          dialog_close
          exit 0
          ;;
      esac
      if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
        # Capture tmux's own message instead of discarding it: "session names
        # cannot contain '.' or ':'" tells the user what to do, where
        # "failed to rename" leaves them guessing (IDEAS #23).
        _err=""
        case "$SPEC_TYPE" in
          S) _err=$(tmux rename-session -t "$target" -- "$new_name" 2>&1) ;;
          W) _err=$(tmux rename-window  -t "$target" -- "$new_name" 2>&1) ;;
        esac
        if [ $? -eq 0 ]; then
          dialog_status "${GREEN}✓ renamed to ${new_name}${RST}"
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
        tmux display-message "interdimux: only panes can be zoomed" 2>/dev/null
        exit 0
      fi
      tmux resize-pane -Z -t "$target" 2>/dev/null || \
        tmux display-message "interdimux: failed to toggle zoom" 2>/dev/null
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
      input_dialog "$BOLD_AMBER" "Send keys to ${label}" "❯ " ""
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
              send_targets+=("=$SPEC_SESSION:$SPEC_WIDX.$pidx")
            done < <(tmux list-panes -t "$target" -F '#{pane_index}' 2>/dev/null)
            ;;
          S)
            # All panes in all windows of this session
            while IFS=$'\t' read -r widx pidx; do
              send_targets+=("=$SPEC_SESSION:$widx.$pidx")
            done < <(tmux list-panes -s -t "$target" -F '#{window_index}	#{pane_index}' 2>/dev/null)
            ;;
        esac

        sent=0 failed=0
        for t in "${send_targets[@]}"; do
          # -- so a command starting with '-' is not parsed as a flag
          if tmux send-keys -t "$t" -- "$send_cmd" Enter 2>/dev/null; then
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
      case "$SPEC_TYPE" in
        S) sched_pick="=${SPEC_SESSION}:" ;;
        *) sched_pick="$target" ;;
      esac
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
            "${DIM}sent as keys, then Enter${RST}"
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
      # Re-parse first: gather_targets ran in between, and the code below already
      # re-parses "$spec" for the same reason before computing src_target.
      parse_spec "$spec"
      _swap_src=$(spec_label)
      # A session name can contain a newline, which a prompt cannot.
      _swap_src="${_swap_src//$'\n'/ }"

      printf '\033[2J\033[H' >>"$tty_out"
      dest=$(printf '%s\n' "$swap_list" | fzf \
        "${FZF_THEME[@]}" \
        --delimiter=$'\t' \
        --with-nth=1..3 \
        --nth=1,3 \
        --prompt="swap $_swap_src with ❯ " \
        --header="$(hint enter 'swap destination' esc cancel)" \
      ) || exit 0

      dest_spec="${dest##*	}"
      parse_spec "$dest_spec"
      dest_target=$(spec_target)

      parse_spec "$spec"
      src_target=$(spec_target)

      case "$SPEC_TYPE" in
        W) tmux swap-window -s "$src_target" -t "$dest_target" 2>/dev/null ;;
        P) tmux swap-pane   -s "$src_target" -t "$dest_target" 2>/dev/null ;;
      esac

      if [ $? -ne 0 ]; then
        tmux display-message "interdimux: swap failed" 2>/dev/null
      fi
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Directory picker header (called by fzf transform-header)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dirs-header" ]; then
  case "${2:-default}" in
    deep)   printf '%s%s\n' "$(hint '🔎 deep search' "${3:-}")" "   $(hint ^r reset esc cancel)" ;;
    browse) printf '%s%s\n' "$(hint '⤷ browsing' "${3:-}")" "   $(hint ^r reset esc cancel)" ;;
    *)      hint enter create ^f 'deep search' ^g 'browse into' ^r reset esc cancel; echo ;;
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
  # picker could open.  (The ctrl-f/ctrl-g binds still call --dirs-header:
  # theirs are per-mode and carry the live query.)
  hint_r enter create ^f 'deep search' ^g 'browse into' ^r reset esc cancel
  DIRS_HEADER="$REPLY"

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
    --header="$DIRS_HEADER" \
    --preview="bash '$SCRIPT_PATH' --dirs-preview {-1}" \
    --preview-window="right,40%,border-left,nowrap" \
    --bind="ctrl-f:reload(bash '$SCRIPT_PATH' --dirs-list --deep {q})+transform-header(bash '$SCRIPT_PATH' --dirs-header deep {q})${ctrl_f_extra}" \
    --bind="ctrl-g:reload(bash '$SCRIPT_PATH' --dirs-list --scan {-1})+transform-header(bash '$SCRIPT_PATH' --dirs-header browse {-1})" \
    --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --dirs-list)+transform-header(bash '$SCRIPT_PATH' --dirs-header)" \
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
    tmux display-message "interdimux: no session #$_jn" 2>/dev/null
    exit 1
  fi
  tmux switch-client -t "=$_jt" 2>/dev/null || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Dynamic header (called by fzf focus:transform-header)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--header-for" ]; then
  spec="${2:-}"
  spec="${spec%%	*}"
  type="${spec%%:*}"
  scope_hint=()
  fzf_ge 58 && scope_hint=('^]' scope)
  case "$type" in
    S) hint enter switch ^x kill ^e rename ^d detach ^o new ^/ preview ${scope_hint[@]+"${scope_hint[@]}"} ;;
    W) hint enter switch ^x kill ^e rename ^s swap ^o new ^/ preview ${scope_hint[@]+"${scope_hint[@]}"} ;;
    P) hint enter switch ^x kill ^z zoom ^s swap ^t send ^/ preview ${scope_hint[@]+"${scope_hint[@]}"} ;;
    D) hint enter open ^o new ^r reload ^/ preview ${scope_hint[@]+"${scope_hint[@]}"} ;;
    *) hint enter switch ^x kill ^e rename ^o new ^r reload ^/ preview ;;
  esac
  echo
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
  _ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
  _warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }
  _bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; _doc_fail=1; }
  _note() { printf '      \033[2m%s\033[0m\n' "$1"; }

  printf '\033[1minterdimux doctor\033[0m\n\n\033[1menvironment\033[0m\n'

  if [ "$TMUX_VNUM" -ge 304 ]; then
    _ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}') (fast prefix-key binding available)"
  elif [ "$TMUX_VNUM" -ge 300 ]; then
    _warn "tmux $(tmux -V 2>/dev/null | awk '{print $2}') — works, but opening the picker forks a shell first"
    _note "tmux 3.4 adds run-shell -C, which binds the popup with no shell at all"
  else
    _bad "tmux $(tmux -V 2>/dev/null | awk '{print $2}') is older than 3.0"
  fi

  if command -v fzf >/dev/null 2>&1; then
    if   [ "$FZF_MINOR" -ge 74 ]; then _ok "fzf $(fzf --version | awk '{print $1}') (raw filter mode available)"
    elif [ "$FZF_MINOR" -ge 63 ]; then _warn "fzf $(fzf --version | awk '{print $1}') — 0.74 adds raw mode, which stops the tree collapsing as you type"
    elif [ "$FZF_MINOR" -ge 61 ]; then _warn "fzf $(fzf --version | awk '{print $1}') — 0.63 adds background transforms, so headers update without blocking"
    else _warn "fzf $(fzf --version | awk '{print $1}') — old, but supported"
    fi
  else
    _bad "fzf is not on PATH"
    _note "it must be on the PATH the TMUX SERVER inherited, not just your shell's"
  fi

  _repo="${SCRIPT_PATH%/scripts/*}"
  if [ -n "${IMUX_BIN:-}" ] && [ -x "$IMUX_BIN" ]; then
    if _v=$("$IMUX_BIN" --version 2>/dev/null) && [ -n "$_v" ]; then
      _ok "$_v at $IMUX_BIN"
    else
      _bad "rust helper at $IMUX_BIN is present but does not run"
      _note "rebuild with: (cd '$_repo/rust' && cargo build --release)"
    fi
  elif [ "${INTERDIMUX_USE_RUST:-on}" = off ]; then
    _warn "rust helper disabled by INTERDIMUX_USE_RUST=off"
  else
    _warn "rust helper not found — falling back to the minimal bash renderer"
    _note "build it with: (cd '$_repo/rust' && cargo build --release)"
  fi

  if command -v at >/dev/null 2>&1; then
    _ok "at is installed (Schedule, --send-at / --send-in beyond a minute)"
    # `at` without its job-runner accepts jobs, queues them, and never fires
    # them — silently.  The only symptom is a command that did not run, hours
    # later, which is exactly the failure this tool must not have.  The runner is
    # atd on Linux and atrun (launchd) on macOS; at_daemon_state knows the
    # difference and reads each without root, and says so honestly when it cannot
    # tell (BSD's cron-atrun, or a host without pgrep) rather than crying wolf.
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

  # --- key bindings -----------------------------------------------------------
  printf '\n\033[1mkey bindings\033[0m\n'
  _k=$(tmux show-option -gqv @interdimux-key);           _k="${_k:-f}"
  _dk=$(tmux show-option -gqv @interdimux-dashboard-key); _dk="${_dk:-g}"
  # Read the table once and match the key column ourselves: `list-keys -T prefix
  # <key>` prints nothing on tmux 3.7b, so filtering with it silently reports
  # every binding as missing.
  _keytable=$(tmux list-keys -T prefix 2>/dev/null)
  if printf '%s' "$_keytable" | grep -q interdimux; then
    for _pair in "$_k:navigator" "$_dk:dashboard"; do
      _key="${_pair%%:*}"; _what="${_pair#*:}"
      if printf '%s\n' "$_keytable" | awk -v k="$_key" '$2=="-T" && $3=="prefix" && $4==k' \
           | grep -q interdimux; then
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

  # --- options ----------------------------------------------------------------
  printf '\n\033[1moptions\033[0m\n'
  # Names the code understands but that are not in OPT_MAP: they are read
  # directly rather than forwarded to the popup.
  _known=("${OPT_NAMES[@]}" key dashboard-key binary project-dirs jump-keys)

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
    local n="$1" v="$2"
    [ -n "$v" ] || return 0
    case "$n" in
      show-preview|show-full-command|show-git-branch|use-zoxide|dirs-live-search|hydrate|show-dirs|raw)
        case "$v" in on|off) ;; *) printf "expected 'on' or 'off'" ;; esac ;;
      order)
        case "$v" in mru|index) ;; *) printf "expected 'mru' or 'index'" ;; esac ;;
      recent-limit|dirs-limit|scan-depth)
        case "$v" in ''|*[!0-9]*) printf 'expected a whole number' ;; esac
        [ "$n" = scan-depth ] && case "$v" in ''|*[!0-9]*) ;; *) [ "$v" -gt 10 ] && printf 'deeper than 10 will not finish inside a popup' ;; esac ;;
      popup-width|popup-height)
        case "$v" in *%) case "${v%\%}" in ''|*[!0-9]*) printf 'expected NN or NN%%' ;; esac ;;
                     ''|*[!0-9]*) printf 'expected NN or NN%%' ;; esac ;;
      color-*)
        case "$v" in
          default|-1) ;;
          '#'*) [ "${#v}" -eq 7 ] || printf 'a hex colour must be #rrggbb' ;;
          ''|*[!0-9]*) printf 'expected #rrggbb, a 0-255 index, or default' ;;
          *) [ "$v" -le 255 ] || printf 'a colour index must be 0-255' ;;
        esac ;;
      key|dashboard-key)
        [ "${#v}" -eq 1 ] || printf 'expected a single key' ;;
      jump-keys)
        # space-separated tmux key specs; the count is what maps to #1, #2, …
        case "$v" in *[!A-Za-z0-9\ ^\-]*) printf 'expected space-separated tmux keys, e.g. "M-1 M-2 M-3"' ;; esac ;;
      binary)
        [ -x "$v" ] || printf 'not an executable file' ;;
    esac
  }

  # Every @interdimux-* actually set, global and session scope.
  _seen=0
  while IFS= read -r _line; do
    _name="${_line%% *}"; _name="${_name#@interdimux-}"
    _val="${_line#* }"; [ "$_val" = "$_line" ] && _val=""
    _val="${_val%\"}"; _val="${_val#\"}"
    _seen=$((_seen + 1))
    if ! _is_known "$_name"; then
      _suggest "$_name"
      if [ -n "$REPLY" ]; then
        _bad "unknown option @interdimux-$_name — did you mean @interdimux-$REPLY?"
      else
        _bad "unknown option @interdimux-$_name"
      fi
      continue
    fi
    _why=$(_check_value "$_name" "$_val")
    if [ -n "$_why" ]; then
      _bad "@interdimux-$_name = '$_val' — $_why"
    else
      _ok "@interdimux-$_name = '$_val'"
    fi
  done < <( { tmux show-options -g 2>/dev/null; tmux show-options 2>/dev/null; } \
            | grep '^@interdimux-' | sort -u )
  [ "$_seen" = 0 ] && _note 'nothing set — every option is at its default'

  printf '\n'
  [ "$_doc_fail" = 1 ] && exit 1
  exit 0
fi

if [ "${1:-}" = "--launch" ]; then
  set +e
  mode="${2:-switch}"

  # The navigator's title names the session you are in, so there is a "you are
  # here" anchor even once the current row has scrolled out of the list.  The
  # baked prefix+f binding gets this from a tmux format for free; this path is
  # already forking, so one more round-trip costs nothing that matters.
  _cur_sess=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} '#S' 2>/dev/null) || _cur_sess=""
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
  esac

  sp="$SQ_SCRIPT"
  chrome=()
  if tmux_ge 303; then
    # Border style/lines are left to the user's popup-border-* options;
    # only destructive modes recolour the frame
    chrome=(-T "${POPUP_TITLE_STYLE}${title}")
    [ "$mode" = "kill" ] && chrome+=(-S "$(danger_style)")
    # Popups don't inherit TMUX_PANE — forward it (run-shell sets it for
    # this process) so current-target detection is exact even with
    # multiple attached clients
    [ -n "${TMUX_PANE:-}" ] && chrome+=(-e "TMUX_PANE=$TMUX_PANE")
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
      switch) cmd="bash '$sp'" ;;
      *)      chrome+=(-e "INTERDIMUX_MODE=$mode"); cmd="bash '$sp'" ;;
    esac
  else
    env_fwd=$(build_env_fwd)
    case "$mode" in
      dirs)   cmd="$env_fwd bash '$sp' --dirs || true" ;;
      jobs)   cmd="$env_fwd bash '$sp' --jobs" ;;
      switch) cmd="$env_fwd bash '$sp'" ;;
      *)      cmd="$env_fwd INTERDIMUX_MODE=$mode bash '$sp'" ;;
    esac
  fi

  exec tmux display-popup -w "$POPUP_WIDTH" -h "$POPUP_HEIGHT" \
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
    --header="$(hint enter cancel ^r reload esc quit)" \
    --bind="enter:${_jwait}execute(bash '$SQ_SCRIPT' --job-cancel {-1})+reload($_jl)" \
    --bind="ctrl-r:reload($_jl)" \
    >/dev/null 2>&1
  set -o pipefail
  exit 0
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

# The pressing client's width or height in cells, or 0 when it cannot be read.
# Sets REPLY.
#
# Targeted first, so the answer is the pressing client's when several are
# attached; untargeted second, because a TMUX_PANE inherited from a DIFFERENT
# server does not resolve here and would otherwise read as "unknown".
client_dim() {
  local fmt="$1" v
  v=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} "$fmt" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v=$(tmux display-message -p "$fmt" 2>/dev/null) ;; esac
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  REPLY="$v"
}

# Entry point for the prefix+g binding: a native styled menu on
# tmux >= 3.4, otherwise a compact fzf menu in a popup.
if [ "${1:-}" = "--dashboard-launch" ]; then
  set +e
  sp="$SQ_SCRIPT"

  # display-menu SILENTLY draws nothing and exits 0 when the menu is taller than
  # the client.  Verified on 3.7b: this menu appears on a 15-row client and does
  # not appear at all on a 14-row one — no message, no error, prefix+g simply
  # becomes a dead key.  Menu height is items + 2 for the borders, and this menu
  # is 13 items (10 entries + 3 separators), so it needs 15.
  #
  # The fzf fallback below has no such ceiling: its list scrolls.  So the tmux
  # version is not the only thing that decides which one to draw.
  MENU_ROWS=15
  client_dim '#{client_height}'; _cli_h="$REPLY"
  client_dim '#{client_width}';  _cli_w="$REPLY"
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
    # Item names are FORMATS, so #[...] styles them.  Kill is the only entry here
    # that destroys something; give it the same danger colour as the frame it
    # turns red.
    tmux display-menu -x C -y C \
      -T '#[align=centre,bold] interdimux ' \
      -H "bg=${MENU_SEL_BG},fg=${MENU_SEL_FG},bold" \
      'Switch'      s "run-shell -b \"bash '$menu_sp' --launch switch\"" \
      'New session' n "run-shell -b \"bash '$menu_sp' --launch dirs\"" \
      '' \
      'Rename'      r "run-shell -b \"bash '$menu_sp' --launch rename\"" \
      "#[fg=${POPUP_BORDER_DANGER}]Kill" i "run-shell -b \"bash '$menu_sp' --launch kill\"" \
      'Swap'        w "run-shell -b \"bash '$menu_sp' --launch swap\"" \
      'Zoom'        z "run-shell -b \"bash '$menu_sp' --launch zoom\"" \
      '' \
      'Detach'      d "run-shell -b \"bash '$menu_sp' --launch detach\"" \
      'Send keys'   t "run-shell -b \"bash '$menu_sp' --launch send\"" \
      '' \
      "$_m_sched"   a "run-shell -b \"bash '$menu_sp' --launch schedule\"" \
      "$_m_jobs"    o "run-shell -b \"bash '$menu_sp' --launch jobs\""
  else
    chrome=()
    cmd="$(build_env_fwd) bash '$sp' --dashboard"
    if tmux_ge 303; then
      chrome=(-T "${POPUP_TITLE_STYLE} interdimux ")
      [ -n "${TMUX_PANE:-}" ] && chrome+=(-e "TMUX_PANE=$TMUX_PANE")
      env_fwd_flags
      chrome+=("${ENV_FWD_FLAGS[@]}")
      cmd="bash '$sp' --dashboard"
    fi
    # 10 entries + fzf's prompt, header and border; too short and fzf scrolls
    # the menu, which hides the entries added last.
    #
    # Clamped to the client, because display-popup does NOT clamp: it fails with
    # "height too large" and draws nothing.  Verified — on a 14-row client `-h 14`
    # succeeds and `-h 15` errors, so the limit is exactly the client's size.  A
    # fixed 64x19 made this the same dead key as an oversized menu, reached by the
    # other path.  fzf's list scrolls, so a short popup is merely cramped.
    _pop_w=64 _pop_h=19
    [ "$_cli_w" -gt 0 ] && [ "$_cli_w" -lt "$_pop_w" ] && _pop_w="$_cli_w"
    [ "$_cli_h" -gt 0 ] && [ "$_cli_h" -lt "$_pop_h" ] && _pop_h="$_cli_h"
    tmux display-popup -w "$_pop_w" -h "$_pop_h" ${chrome[@]+"${chrome[@]}"} \
      -E "$cmd"
  fi
  exit 0
fi

# fzf fallback menu (tmux < 3.4)
if [ "${1:-}" = "--dashboard" ]; then
  set +e

  items=$(printf "%s\t  ${BOLD_AMBER}%-14s${RST} ${DIM}%s${RST}\n" \
    "switch" "Switch"       "Navigate & jump to target" \
    "dirs"   "New session"  "Create session from directory" \
    "rename" "Rename"       "Rename a session or window" \
    "kill"   "Kill"         "Remove sessions, windows, or panes" \
    "zoom"   "Zoom"         "Toggle pane zoom" \
    "swap"   "Swap"         "Swap windows or panes" \
    "detach" "Detach"       "Detach clients from session" \
    "send"   "Send keys"    "Send a command to a pane" \
    "schedule" "Schedule"   "Run a command later, via at" \
    "jobs"   "Jobs"         "See and cancel scheduled commands")

  choice=$(printf '%s\n' "$items" | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --no-info \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='interdimux ❯ ' \
    --header="$(hint enter select esc quit)" \
  ) || exit 0

  action="${choice%%	*}"

  # Launch the selected tool in a new popup via run-shell -b (popups
  # can't nest, so this runs after the dashboard popup closes)
  tmux run-shell -b "bash '$SQ_SCRIPT_FMT' --launch $action"
  exit 0
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
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
  RESUME_FILE="$XDG_RUNTIME_DIR/interdimux-resume.$$"
else
  RESUME_FILE=$(mktemp "${TMPDIR:-/tmp}/interdimux-resume.XXXXXX")
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
# fzf draws its interface on /dev/tty rather than stderr, so redirecting fd 2
# costs the UI nothing.
#
# Reported, never swallowed: the first line goes to `display-message` (which
# also lands in `tmux show-messages`) and the whole thing is appended to a log
# that --doctor points at.
#
# Only on this path.  Child modes (--list, --preview, --action, --doctor …) keep
# their real stderr: they are called by fzf, by the test suites, and by the user.
ERR_FILE="${RESUME_FILE}.err"
if : > "$ERR_FILE" 2>/dev/null; then
  exec 2>"$ERR_FILE"
else
  ERR_FILE=""
fi

_report_stderr() {
  [ -n "$ERR_FILE" ] && [ -s "$ERR_FILE" ] || return 0
  local first
  { read -r first < "$ERR_FILE"; } 2>/dev/null || :
  [ -n "$first" ] || return 0
  # `#` would be format-expanded by display-message; a long line would be
  # truncated by the status line anyway, so cut it where it stays readable
  first="${first//\#/##}"
  [ "${#first}" -gt 160 ] && first="${first:0:157}…"
  tmux display-message "interdimux: $first" 2>/dev/null || :
  if mkdir -p "$SCHED_LOGDIR" 2>/dev/null; then
    {
      printf '== %s navigator stderr\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      cat "$ERR_FILE"
    } >> "$SCHED_LOGDIR/errors.log" 2>/dev/null || :
  fi
}

trap '_report_stderr; rm -f "$RESUME_FILE" "$PREVIEW_STATE_FILE" ${ERR_FILE:+"$ERR_FILE"}' EXIT

LIST_CMD="bash '$SCRIPT_PATH' --list"
ACTION_CMD="bash '$SCRIPT_PATH' --action"

while true; do
  : > "$RESUME_FILE"
  # Re-seed each iteration: the loop restarts fzf using the STATIC $SHOW_PREVIEW
  # to choose --preview-window …hidden, while compute_widths reads the file.
  # ctrl-o -> Esc re-enters the loop, so without this the two go permanently out
  # of phase and rows are sized for a preview that is not shown.
  [ -n "$PREVIEW_STATE_FILE" ] && printf '%s' "$SHOW_PREVIEW" > "$PREVIEW_STATE_FILE" 2>/dev/null

  # shellcheck disable=SC2054  # commas are part of a single fzf argument
  fzf_opts=(
    "${FZF_THEME[@]}"
    --delimiter=$'\t'
    --with-nth=1..3
    --nth=1,3
    --tiebreak=chunk,begin,index
    --bind='change:first'
    --bind="ctrl-r:reload($LIST_CMD)"
  )


  # Cursor stability across the execute+reload cycle every action performs.
  # --id-nth keys rows by their SPEC (field 4), so after a reload the cursor
  # stays on the same TARGET rather than the same row number — which in kill
  # mode is the difference between confirming what you meant and confirming
  # whatever slid into that position.
  #
  # Deliberately WITHOUT --track: --track arms trackBlocked, which DISCARDS
  # every keystroke except abort while a reload is in flight
  # (fzf src/terminal.go:6821-6827), and that window is widest right after the
  # popup opens.  --id-nth alone never blocks.
  fzf_ge 71 && fzf_opts+=(--id-nth=4)


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
      fzf_opts+=(
        --prompt='kill ❯ '
        --header="$(hint enter kill ^r reload esc quit)"
        --bind="enter:${_wait}execute($ACTION_CMD kill {-1})+reload($LIST_CMD)"
      )
      ;;
    rename)
      fzf_opts+=(
        --prompt='rename ❯ '
        --header="$(hint enter rename ^r reload esc quit)"
        --bind="enter:${_wait}execute($ACTION_CMD rename {-1})+reload($LIST_CMD)"
      )
      ;;
    zoom)
      fzf_opts+=(
        --prompt='zoom ❯ '
        --header="$(hint enter 'toggle zoom' ^r reload esc quit)"
        --bind="enter:${_wait}execute-silent($ACTION_CMD zoom {-1})+reload($LIST_CMD)+refresh-preview"
      )
      ;;
    swap)
      fzf_opts+=(
        --prompt='swap ❯ '
        --header="$(hint enter swap ^r reload esc quit)"
        --bind="enter:${_wait}execute($ACTION_CMD swap {-1})+reload($LIST_CMD)"
      )
      ;;
    detach)
      fzf_opts+=(
        --prompt='detach ❯ '
        --header="$(hint enter detach ^r reload esc quit)"
        --bind="enter:${_wait}execute($ACTION_CMD detach {-1})+reload($LIST_CMD)"
      )
      ;;
    send)
      fzf_opts+=(
        --prompt='send ❯ '
        --header="$(hint enter 'send keys' ^r reload esc quit)"
        --bind="enter:${_wait}execute($ACTION_CMD send {-1})+reload($LIST_CMD)"
      )
      ;;
    schedule)
      fzf_opts+=(
        --prompt='schedule ❯ '
        --header="$(hint enter 'schedule a command' ^r reload esc quit)"
        --bind="enter:${_wait}execute($ACTION_CMD schedule {-1})+reload($LIST_CMD)"
      )
      ;;
    *)
      # The per-row header only ever picks between these four strings, and all
      # four are known right here.  Export them so the focus bind can choose
      # inline instead of re-exec'ing this script on every cursor move.
      _scope_hint=()
      fzf_ge 58 && _scope_hint=('^]' scope)
      hint_r enter switch ^x kill ^e rename ^d detach ^o new ^/ preview ${_scope_hint[@]+"${_scope_hint[@]}"}
      export INTERDIMUX_HDR_S="$REPLY"
      hint_r enter switch ^x kill ^e rename ^s swap ^o new ^/ preview ${_scope_hint[@]+"${_scope_hint[@]}"}
      export INTERDIMUX_HDR_W="$REPLY"
      hint_r enter switch ^x kill ^z zoom ^s swap ^t send ^/ preview ${_scope_hint[@]+"${_scope_hint[@]}"}
      export INTERDIMUX_HDR_P="$REPLY"
      hint_r enter open ^o new ^r reload ^/ preview ${_scope_hint[@]+"${_scope_hint[@]}"}
      export INTERDIMUX_HDR_D="$REPLY"
      hint_r enter switch ^x kill ^e rename ^o new ^r reload ^/ preview
      export INTERDIMUX_HDR_X="$REPLY"

      fzf_opts+=(
        --prompt='❯ '
        --print-query
        --header="$INTERDIMUX_HDR_X"
        --bind="ctrl-x:${_wait}execute($ACTION_CMD kill {-1})+reload($LIST_CMD)"
        --bind="ctrl-e:${_wait}execute($ACTION_CMD rename {-1})+reload($LIST_CMD)"
        --bind="ctrl-z:${_wait}execute-silent($ACTION_CMD zoom {-1})+reload($LIST_CMD)+refresh-preview"
        --bind="ctrl-s:${_wait}execute($ACTION_CMD swap {-1})+reload($LIST_CMD)"
        --bind="ctrl-d:${_wait}execute($ACTION_CMD detach {-1})+reload($LIST_CMD)"
        --bind="ctrl-t:${_wait}execute($ACTION_CMD send {-1})+reload($LIST_CMD)"
        --bind="ctrl-o:execute(bash '$SCRIPT_PATH' --dirs || echo resume > '$RESUME_FILE')+abort"
        # Column widths are computed against the space actually available, so
        # toggling the preview or resizing the popup invalidates them: without
        # the reload the rows stay sized for the old geometry (IDEAS #26).
        # A reload used to cost ~195ms, which is why this was deferred; it is
        # ~25ms now.
        --bind="ctrl-/:toggle-preview+execute-silent(f='$PREVIEW_STATE_FILE'; read -r st < \"\$f\" 2>/dev/null; [ \"\$st\" = on ] && printf off > \"\$f\" || printf on > \"\$f\")+reload($LIST_CMD)"
        --bind='resize:reload('"$LIST_CMD"')'
      )
      # Per-row header hints, once per cursor move.  A focus bind runs
      # SYNCHRONOUSLY — the fzf man page warns it "can make the interface
      # sluggish" — so on fzf >= 0.63 we use the async bg- variant and
      # bg-cancel to coalesce rapid scrolling.
      #
      # The command itself is an inline `case` over the exported headers, which
      # costs one ~1ms `sh -c` instead of re-parsing and re-executing this
      # 2500-line script (~17ms) per move.  Notes on the two sharp edges:
      #   * `_{-1}` — with an EMPTY result list fzf expands {-1} to *zero*
      #     words, so a bare `case {-1} in` becomes `case in`: a syntax error
      #     and a blank header.  The `_` prefix keeps the word present.
      #   * `action:rest-of-string` rather than `action(...)` — the arms contain
      #     `)`, which can terminate fzf's parenthesised argument parser.  This
      #     form has no terminator, so it must come last in the `+` chain.
      # fzf single-quotes the placeholder, so a spec can't inject shell.
      _hdr_case='case _{-1} in'
      _hdr_case+=' _S:*) printf "%s\n" "$INTERDIMUX_HDR_S";;'
      _hdr_case+=' _W:*) printf "%s\n" "$INTERDIMUX_HDR_W";;'
      _hdr_case+=' _P:*) printf "%s\n" "$INTERDIMUX_HDR_P";;'
      _hdr_case+=' _D:*) printf "%s\n" "$INTERDIMUX_HDR_D";;'
      _hdr_case+=' *) printf "%s\n" "$INTERDIMUX_HDR_X";; esac'
      if [ "$INLINE_CALLBACKS" = 1 ] && fzf_ge 63; then
        fzf_opts+=(--bind="focus:bg-cancel+bg-transform-header:$_hdr_case")
      elif [ "$INLINE_CALLBACKS" = 1 ]; then
        fzf_opts+=(--bind="focus:transform-header:$_hdr_case")
      elif fzf_ge 63; then
        fzf_opts+=(--bind="focus:bg-cancel+bg-transform-header(bash '$SCRIPT_PATH' --header-for {-1})")
      else
        fzf_opts+=(--bind="focus:transform-header(bash '$SCRIPT_PATH' --header-for {-1})")
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
          --bind="enter:transform:[ \"\${FZF_MATCH_COUNT:-0}\" -eq 0 ] && echo 'execute(bash \"$SQ_SCRIPT\" --create-from-query {q})+abort' || echo accept"
        )
      fi

      # Raw mode still needs the cursor moved even when the inline header
      # snippets are unavailable (old fzf, or a user-supplied --with-shell).
      if [ "$_raw_on" = 1 ] && [ "$INLINE_CALLBACKS" != 1 ]; then
        fzf_opts+=(--bind='result:best')
      fi

      # Announce find-or-create in the zero-match state (IDEAS #1).  Without it
      # the feature is invisible and a typo silently creates a junk session; now
      # the header says exactly which session would be created, and where.
      # The announcement is precomputed per-keystroke by the same inline-snippet
      # trick the row header uses: describe_create needs zoxide and the
      # filesystem, so it cannot be inlined, but `zero` only fires when the
      # match count reaches 0 — not on every keystroke — so one process there is
      # acceptable where one per cursor move would not be.
      # The `focus` bind restores the normal per-row header as soon as matches
      # come back, so no explicit restore bind is needed.
      if [ "$INLINE_CALLBACKS" = 1 ]; then
        # ONE bind owns the header on result changes, because two of them fight:
        # a `zero` bind that announces the create, plus a `result` bind that
        # restores the row header, means the result bind emits nothing at zero
        # matches — and an empty transform-header CLEARS the header, wiping the
        # announcement that `zero` just set.
        #
        # bg- so it never blocks typing: the create description has to shell out
        # (it consults zoxide and the filesystem), and `result` fires on every
        # keystroke.
        _hdr_bind="if [ \"\${FZF_MATCH_COUNT:-0}\" -gt 0 ]; then $_hdr_case; else bash '$SQ_SCRIPT' --describe-create {q}; fi"
        # `best` FIRST, and only on `result`: in raw mode every row stays
        # displayed, so nothing moves the cursor onto a match and
        # `--bind=change:first` actively pins it to row 1 — filter, press ctrl-x,
        # and you kill whatever happened to be at the top.  Verified: with --raw,
        # typing "delta" left the cursor on "alpha" under change:first AND under
        # change:best (which fires before the search completes); result:best
        # lands on "delta".
        # It must be chained here rather than bound separately, because fzf's
        # last --bind for an event replaces the earlier one.
        _res_pre=""
        [ "$_raw_on" = 1 ] && _res_pre="best+"
        if fzf_ge 63; then
          fzf_opts+=(--bind="result:${_res_pre}bg-cancel+bg-transform-header:$_hdr_bind")
        else
          fzf_opts+=(--bind="result:${_res_pre}transform-header:$_hdr_bind")
        fi
      fi
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
        record_dir_use "$SPEC_DIR"
        connect_dir "$SPEC_DIR" || \
          tmux display-message "interdimux: could not open $SPEC_DIR"
      else
        tmux display-message "interdimux: $(spec_label) no longer exists"
      fi
      exit 0
    fi
    target=$(spec_target)
    tmux switch-client -t "$target" 2>/dev/null || \
      tmux display-message "interdimux: $(spec_label) no longer exists"
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
