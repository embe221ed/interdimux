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

  # The dashboard is not the hot path — it keeps the simple launcher.
  tmux bind-key "$_bk_dash" run-shell -b "bash '$SQ_SCRIPT' --dashboard-launch"

  # run-shell -C needs tmux >= 3.4; below it, keep the original binding.
  if [ "$_bk_tvnum" -lt 304 ]; then
    tmux bind-key "$_bk_nav" run-shell -b "bash '$SQ_SCRIPT' --launch switch"
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
  _bk_env+=" -e \"INTERDIMUX_TITLE= interdimux \""

  # #{?…,…,…} treats the string "0" as FALSE, so it cannot be used as an
  # emptiness test — #{==:…,} can.  (Width/height can't legitimately be 0, but
  # the same idiom is wrong for colour-tree 0 or recent-limit 0.)
  _bk_w='#{?#{==:#{@interdimux-popup-width},},80%,#{@interdimux-popup-width}}'
  _bk_h='#{?#{==:#{@interdimux-popup-height},},75%,#{@interdimux-popup-height}}'

  # -T is NOT #{q:}-quoted: rs_quote would double the '#' and '##[' does not
  # collapse back before '[', so the popup would show a literal "#[bold]".
  tmux bind-key "$_bk_nav" run-shell -bC \
    "display-popup -w \"$_bk_w\" -h \"$_bk_h\" -T \"#[bold] interdimux \"$_bk_env -E \"bash '$SQ_SCRIPT'\""
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

record_recent_dir() {
  local dir="$1"
  local dir_parent
  dir_parent="$(dirname "$RECENT_DIRS_FILE")"
  [ -d "$dir_parent" ] || mkdir -p "$dir_parent"

  # Rebuild the file: new dir first, then surviving entries (pruning
  # duplicates and dirs that no longer exist), atomically replaced.
  local tmp d count=1
  tmp=$(mktemp "$dir_parent/.recent_dirs.XXXXXX")
  echo "$dir" > "$tmp"
  if [ -f "$RECENT_DIRS_FILE" ]; then
    while IFS= read -r d; do
      [ "$d" = "$dir" ] && continue
      [ -d "$d" ] || continue
      echo "$d" >> "$tmp"
      count=$((count + 1))
      [ "$count" -ge 50 ] && break
    done < "$RECENT_DIRS_FILE"
  fi
  mv -f "$tmp" "$RECENT_DIRS_FILE"
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
    tmux send-keys -t "$target" "$line" Enter 2>/dev/null || true
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
printf -v NOW_EPOCH '%(%s)T' -1   # current epoch, fork-free (bash >= 4.2)
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

  # Build process table once (instead of per-pane pgrep+ps).  Started before
  # the queries so a slow ps overlaps the tmux round-trip; on Linux this is a
  # no-op (the /proc backend needs no table).
  [ "$SHOW_FULL_COMMAND" = "on" ] && build_process_table

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

  # Hand the whole render to the Rust core when it is available.  This is the
  # part that was ~181 ms of in-process bash (measure_widths + grouping + emit);
  # the binary does it in ~2 ms.  bash keeps the tmux plumbing so the socket
  # handling lives in exactly one place, and keeps its own renderer below as the
  # fallback for anyone without the binary.
  # The binary resolves full commands from /proc only — it has no ps backend.
  # Where /proc is unavailable (macOS/BSD) or has been forced off, bash renders
  # instead, because bash still carries the ps table.  Slower, but correct; the
  # alternative would be silently downgrading those rows to the short command.
  if [ -n "$IMUX_BIN" ] && { [ "$PROC_CMDLINE_OK" = 1 ] || [ "$SHOW_FULL_COMMAND" != "on" ]; }; then
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

    last_commit=$(git -C "$dir" --no-optional-locks log -1 --oneline 2>/dev/null || true)
    [ -n "$last_commit" ] && printf "  ${DIM_PATH}Commit:${RST} %s\n" "$last_commit"

    changed=$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | head -200 | wc -l | tr -d ' ')
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
    case "$tier" in
      recent)
        printf '  %s★%s  %s\t\t%s\n' \
          "$BOLD_AMBER" "$RST" "$(dpad "$display_path" "$DIRS_PATH_W")" "$dir"
        ;;
      project)
        detect_project_type "$dir"
        local type_badge=""
        [ -n "$REPLY" ] && type_badge="${DIM}${REPLY}${RST}"
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
  printf '%s\n' \
    "# imux:v1 pane=${pane} target=${label} desc=$(printf '%s' "$keys" | tr '\n' ' ')" \
    "# atd tries to MAIL a job's output.  With no MTA installed that output is" \
    "# destroyed and leaves only 'Exec failed for mail command' in the journal --" \
    "# which reads exactly like 'my job never ran'.  Log instead of discarding." \
    "mkdir -p $(printf '%q' "$SCHED_LOGDIR") 2>/dev/null" \
    "exec >>$(printf '%q' "$SCHED_LOG") 2>&1" \
    "echo \"== \$(date '+%Y-%m-%d %H:%M:%S') firing for ${label} (${pane})\"" \
    "sock=$(printf '%q' "$sock")" \
    "want=$(printf '%q' "$srvpid")" \
    "pane=$(printf '%q' "$pane")" \
    "got=\$(tmux -S \"\$sock\" display-message -p '#{pid}' 2>/dev/null) || exit 0" \
    "if [ \"\$got\" != \"\$want\" ]; then" \
    "  # the server restarted: pane ids have been recycled and \$pane may now" \
    "  # belong to a completely different session.  Refuse rather than misfire." \
    "  tmux -S \"\$sock\" display-message 'interdimux: scheduled keys skipped (tmux restarted)' 2>/dev/null" \
    "  exit 0" \
    "fi" \
    "tmux -S \"\$sock\" send-keys -t \"\$pane\" -- $(printf '%q' "$keys") 2>/dev/null || exit 0" \
    "tmux -S \"\$sock\" send-keys -t \"\$pane\" Enter 2>/dev/null"
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
    tmux run-shell -b -d "$_when" \
      "tmux -S $(printf '%q' "$SCHED_SOCK") send-keys -t $(printf '%q' "$SCHED_PANE") -- $(printf '%q' "$_keys") && tmux -S $(printf '%q' "$SCHED_SOCK") send-keys -t $(printf '%q' "$SCHED_PANE") Enter" \
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
  _out=$(cd / && sched_job_body "$SCHED_PANE" "$SCHED_SOCK" "$SCHED_SRVPID" "$SCHED_LABEL" "$_keys" \
         | at -M -q "$SCHED_QUEUE" $_spec 2>&1)
  if [ $? -ne 0 ]; then
    printf '%s\n' "$_out" >&2
    echo "interdimux: at rejected the time spec '$_spec'" >&2
    exit 1
  fi
  printf 'interdimux: %s -> %s (%s)\n' \
    "$(printf '%s' "$_out" | sed -n 's/^job \([0-9]*\) at \(.*\)$/job \1 at \2/p' | head -1)" \
    "$SCHED_LABEL" "$SCHED_PANE"
  exit 0
fi

if [ "${1:-}" = "--sched-list" ]; then
  set +e
  command -v atq >/dev/null 2>&1 || { echo "interdimux: 'at' is not installed" >&2; exit 1; }
  _n=0
  while read -r _id _rest; do
    [ -n "$_id" ] || continue
    _n=$((_n + 1))
    _desc=$(at -c "$_id" 2>/dev/null | sed -n 's/^# imux:v1 .*desc=//p' | head -1)
    _tgt=$(at -c "$_id" 2>/dev/null | sed -n 's/^# imux:v1 pane=[^ ]* target=\([^ ]*\).*/\1/p' | head -1)
    printf '%-6s %-30s %-22s %s\n' "$_id" "${_rest% i *}" "${_tgt:-?}" "${_desc:-?}"
  done < <(atq -q "$SCHED_QUEUE" 2>/dev/null | sort -k2)
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
  [ -n "${INTERDIMUX_TITLE:-}" ] && t=(-T "${POPUP_TITLE_STYLE}${INTERDIMUX_TITLE}")
  tmux display-popup -b "$(popup_user_lines)" -S "$style" ${t[@]+"${t[@]}"} 2>/dev/null || true
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
  w=$(( ${#title} + 10 ))
  for line in "$@"; do
    [ $(( ${#line} + 8 )) -gt "$w" ] && w=$(( ${#line} + 8 ))
  done
  [ "$w" -lt 44 ] && w=44
  [ "$w" -gt $(( DLG_COLS - 2 )) ] && w=$(( DLG_COLS - 2 ))
  DLG_W="$w"
  DLG_H=$(( $# + 5 ))   # top border, blank, body…, blank, hint, bottom border
  DLG_TOP=$(( (DLG_ROWS - DLG_H) / 2 ))
  [ "$DLG_TOP" -lt 1 ] && DLG_TOP=1
  DLG_LEFT=$(( (DLG_COLS - DLG_W) / 2 ))
  [ "$DLG_LEFT" -lt 1 ] && DLG_LEFT=1
  [ "${#title}" -gt $(( DLG_W - 6 )) ] && title="${title:0:DLG_W-7}…"

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
      printf '\033[%d;%dH%s' "$r" $(( DLG_LEFT + 4 )) "$line"
      r=$(( r + 1 ))
    done
  } >"$tty_out"
}

# Write a hint/status line on the reserved row inside the box
dialog_status() {
  local text="$1" sp
  local r=$(( DLG_TOP + DLG_H - 2 ))
  printf -v sp '%*s' $(( DLG_W - 8 )) ''
  printf '\033[%d;%dH%s\033[%d;%dH%s' \
    "$r" $(( DLG_LEFT + 4 )) "$sp" \
    "$r" $(( DLG_LEFT + 4 )) "$text" >"$tty_out"
}

dialog_close() {
  printf '\033[?25h' >"$tty_out"
}

# Drain pending input (only on a real tty — a test fixture file would
# be consumed by the read loop)
drain_input() {
  [ -c "$tty_in" ] || return 0
  while IFS= read -rsn1 -t 0.01 _ <"$tty_in"; do :; done
}

# confirm_dialog ACCENT TITLE [BODY...] → 0 when confirmed with y/Y
confirm_dialog() {
  local accent="$1" title="$2"
  shift 2
  dialog_open "$accent" "$title" "$@"
  dialog_status "$(hint y confirm n/esc cancel)"
  drain_input
  local key=""
  IFS= read -rsn1 key <"$tty_in" 2>/dev/null
  if [ "$key" = $'\x1b' ]; then
    drain_input   # swallow escape-sequence tails (arrow keys, etc.)
    return 1
  fi
  [[ "$key" =~ ^[yY]$ ]]
}

# input_dialog ACCENT TITLE PROMPT INITIAL — a single-line text editor drawn
# inside the dialog box.  Sets REPLY (empty = cancelled).
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
  dialog_open "$accent" "$title" ""
  dialog_status "${DIM}enter apply · esc cancel${RST}"

  local irow=$(( DLG_TOP + 2 ))
  local col_prompt=$(( DLG_LEFT + 4 ))
  local field_start=$(( col_prompt + ${#prompt} ))
  local field_end=$(( DLG_LEFT + DLG_W - 3 ))   # one-column gutter before the border
  local field_w=$(( field_end - field_start + 1 ))
  [ "$field_w" -lt 1 ] && field_w=1

  # The prompt is static — draw it once; the loop only repaints the field.
  printf '\033[%d;%dH%s%s%s\033[?25h' \
    "$irow" "$col_prompt" "$accent" "$prompt" "$RST" >"$tty_out"

  local buf="$initial" pos=${#initial} scroll=0
  drain_input

  # Read the input source through ONE fd.  Re-opening `<"$tty_in"` per read
  # works for a tty (each open reads the next queued key) but rewinds a regular
  # file to offset 0 every time — an infinite loop when input comes from a
  # fixture file (tests) or any non-tty.  A single fd advances for both.
  local ifd; exec {ifd}<"$tty_in"
  # On a real terminal, edit in raw/no-echo mode for the duration so fast keys
  # arriving between reads aren't echoed over the box, and Ctrl-C cancels
  # cleanly (delivered as a byte, not SIGINT).  Skipped for non-ttys.
  local saved_stty=""
  if [ -c "$tty_in" ]; then
    saved_stty=$(stty -g <"$tty_in" 2>/dev/null) || saved_stty=""
    [ -n "$saved_stty" ] && stty -echo -icanon -isig min 1 time 0 <"$tty_in" 2>/dev/null
  fi

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
      "$irow" $(( field_start + pos - scroll )) >"$tty_out"

    IFS= read -rsN1 -u "$ifd" c || c=$'\n'   # EOF → accept what we have
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
  exec {ifd}<&-
  REPLY="$buf"
}

# Brief informational dialog
info_flash() {
  dialog_open "$1" "$2" "${3:-}"
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

  # Every action below operates on a live tmux target; a directory row has none.
  if [ "$SPEC_TYPE" = "D" ]; then
    tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"
    case "$action" in
      zoom) tmux display-message "interdimux: $label is not a tmux target" 2>/dev/null ;;
      *)    info_flash "$BOLD_AMBER" "Not applicable" "That row is a directory, not a session." ;;
    esac
    exit 0
  fi

  # /dev/tty for interactive I/O; overridable for testing
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"

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
      if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
        case "$SPEC_TYPE" in
          S) tmux rename-session -t "$target" "$new_name" 2>/dev/null ;;
          W) tmux rename-window  -t "$target" "$new_name" 2>/dev/null ;;
        esac
        if [ $? -eq 0 ]; then
          dialog_status "${GREEN}✓ renamed to ${new_name}${RST}"
        else
          dialog_status "${RED}✗ failed to rename${RST}"
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
          if tmux send-keys -t "$t" "$send_cmd" Enter 2>/dev/null; then
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

      printf '\033[2J\033[H' >"$tty_out"
      dest=$(printf '%s\n' "$swap_list" | fzf \
        "${FZF_THEME[@]}" \
        --delimiter=$'\t' \
        --with-nth=1..3 \
        --nth=1,3 \
        --prompt='swap with ❯ ' \
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

  # The default header is static and this process already has the builder —
  # re-exec'ing the whole script for it cost ~18 ms of dead time before the
  # picker could open.  (The ctrl-f/ctrl-g binds still call --dirs-header:
  # theirs are per-mode and carry the live query.)
  hint_r enter create ^f 'deep search' ^g 'browse into' ^r reset esc cancel
  DIRS_HEADER="$REPLY"

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
  case "${FZF_NTH:-}" in
    1)     echo 'name ❯ ' ;;
    2)     echo 'path ❯ ' ;;
    3)     echo 'cmd ❯ ' ;;
    1,2,3) echo 'all ❯ ' ;;
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
  for kv in "${ENV_FWD[@]}"; do out+=" $(printf '%q' "$kv")"; done
  printf '%s' "$out"
}

if [ "${1:-}" = "--launch" ]; then
  set +e
  mode="${2:-switch}"

  title=' interdimux '
  case "$mode" in
    kill)   title=' interdimux · kill ' ;;
    rename) title=' interdimux · rename ' ;;
    zoom)   title=' interdimux · zoom ' ;;
    swap)   title=' interdimux · swap ' ;;
    detach) title=' interdimux · detach ' ;;
    send)   title=' interdimux · send keys ' ;;
    dirs)   title=' interdimux · new session ' ;;
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
      switch) cmd="bash '$sp'" ;;
      *)      chrome+=(-e "INTERDIMUX_MODE=$mode"); cmd="bash '$sp'" ;;
    esac
  else
    env_fwd=$(build_env_fwd)
    case "$mode" in
      dirs)   cmd="$env_fwd bash '$sp' --dirs || true" ;;
      switch) cmd="$env_fwd bash '$sp'" ;;
      *)      cmd="$env_fwd INTERDIMUX_MODE=$mode bash '$sp'" ;;
    esac
  fi

  exec tmux display-popup -w "$POPUP_WIDTH" -h "$POPUP_HEIGHT" \
    ${chrome[@]+"${chrome[@]}"} -E "$cmd"
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

# Entry point for the prefix+g binding: a native styled menu on
# tmux >= 3.4, otherwise a compact fzf menu in a popup.
if [ "${1:-}" = "--dashboard-launch" ]; then
  set +e
  sp="$SQ_SCRIPT"

  if tmux_ge 304; then
    # Menu item commands are re-parsed by tmux's command parser when
    # selected: inside its double-quoted token, \ " $ are escapes and
    # run-shell format-expands #{...} — escape those layers on top of
    # the shell quoting so exotic install paths survive.
    menu_sp="$sp"
    menu_sp="${menu_sp//\\/\\\\}"
    menu_sp="${menu_sp//\"/\\\"}"
    menu_sp="${menu_sp//\$/\\\$}"
    # quoted pattern: a bare # in ${var//#/…} is the match-at-start anchor
    menu_sp="${menu_sp//'#'/##}"
    tmux display-menu -x C -y C \
      -T '#[align=centre,bold] interdimux ' \
      -H "bg=${MENU_SEL_BG},fg=${MENU_SEL_FG},bold" \
      'Switch'      s "run-shell -b \"bash '$menu_sp' --launch switch\"" \
      'New session' n "run-shell -b \"bash '$menu_sp' --launch dirs\"" \
      '' \
      'Rename'      r "run-shell -b \"bash '$menu_sp' --launch rename\"" \
      'Kill'        i "run-shell -b \"bash '$menu_sp' --launch kill\"" \
      'Swap'        w "run-shell -b \"bash '$menu_sp' --launch swap\"" \
      'Zoom'        z "run-shell -b \"bash '$menu_sp' --launch zoom\"" \
      '' \
      'Detach'      d "run-shell -b \"bash '$menu_sp' --launch detach\"" \
      'Send keys'   t "run-shell -b \"bash '$menu_sp' --launch send\""
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
    tmux display-popup -w 64 -h 17 ${chrome[@]+"${chrome[@]}"} \
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
    "send"   "Send keys"    "Send a command to a pane")

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
  tmux run-shell -b "bash '$SQ_SCRIPT' --launch $action"
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
trap 'rm -f "$RESUME_FILE" "$PREVIEW_STATE_FILE"' EXIT

LIST_CMD="bash '$SCRIPT_PATH' --list"
ACTION_CMD="bash '$SCRIPT_PATH' --action"

while true; do
  : > "$RESUME_FILE"

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
          _scope_case+=' *) printf "❯ \n";; esac'
          fzf_opts+=(--bind="ctrl-]:change-nth(1|2|3|1,2,3|1,3)+transform-prompt:$_scope_case")
        else
          fzf_opts+=(--bind="ctrl-]:change-nth(1|2|3|1,2,3|1,3)+transform-prompt(bash '$SCRIPT_PATH' --scope-prompt)")
        fi
      fi
      fzf_ge 61 && fzf_opts+=(--ghost='session · window · pane')
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
  out=$(gather_targets | fzf "${fzf_opts[@]}")
  fzf_rc=$?
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
    # set -e is live here: every fallible assignment below must be
    # defused (a zoxide miss exits 1 and would kill the script mid-flow)
    dir=""
    session_name=""
    expanded="${query/#\~/$HOME}"
    if [ -d "$expanded" ] && dir=$(cd "$expanded" 2>/dev/null && pwd -P); then
      session_name=$(resolve_session_name "$dir")
    else
      dir=""
      if [ "$USE_ZOXIDE" = "on" ] && command -v zoxide >/dev/null 2>&1; then
        dir=$(zoxide query -- "$query" 2>/dev/null | head -1) || true
      fi
      [ -d "$dir" ] || dir="$HOME"
      session_name=$(printf '%s' "$query" | tr '.: /' '----')
    fi
    [ -z "$session_name" ] && exit 0
    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
      record_dir_use "$dir"
    fi
    connect_dir "$dir" "$session_name" || true
    exit 0
  fi

  exit 0
done
