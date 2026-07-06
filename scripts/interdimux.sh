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

# Script path — computed once, used by fzf bindings to call back into this script
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

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
  fzf_version=$(fzf --version 2>/dev/null | awk '{print $1}') || true
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

# Read a config value: env override → tmux option → default.
get_opt() {
  local env_val="$1" opt_name="$2" default="$3"
  if [ -n "$env_val" ]; then
    printf '%s' "$env_val"
    return
  fi
  local v
  v=$(tmux show-option -gqv "$opt_name" 2>/dev/null || true)
  printf '%s' "${v:-$default}"
}

SHOW_PREVIEW=$(get_opt "${INTERDIMUX_SHOW_PREVIEW:-}" @interdimux-show-preview on)
SHOW_FULL_COMMAND=$(get_opt "${INTERDIMUX_SHOW_FULL_COMMAND:-}" @interdimux-show-full-command on)
SHOW_GIT_BRANCH=$(get_opt "${INTERDIMUX_SHOW_GIT_BRANCH:-}" @interdimux-show-git-branch on)
POPUP_WIDTH=$(get_opt "${INTERDIMUX_POPUP_WIDTH:-}" @interdimux-popup-width 80%)
POPUP_HEIGHT=$(get_opt "${INTERDIMUX_POPUP_HEIGHT:-}" @interdimux-popup-height 75%)
ORDER=$(get_opt "${INTERDIMUX_ORDER:-}" @interdimux-order mru)
FZF_USER_OPTS=$(get_opt "${INTERDIMUX_FZF_OPTS:-}" @interdimux-fzf-opts "")
RECENT_LIMIT=$(get_opt "${INTERDIMUX_RECENT_LIMIT:-}" @interdimux-recent-limit 10)
SCAN_DEPTH=$(get_opt "${INTERDIMUX_SCAN_DEPTH:-}" @interdimux-scan-depth 3)
USE_ZOXIDE=$(get_opt "${INTERDIMUX_USE_ZOXIDE:-}" @interdimux-use-zoxide on)
DIRS_LIVE=$(get_opt "${INTERDIMUX_DIRS_LIVE:-}" @interdimux-dirs-live-search off)
EXTRA_MARKERS=$(get_opt "${INTERDIMUX_PROJECT_MARKERS:-}" @interdimux-project-markers "")

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

COLOR_ACCENT=$(get_opt "${INTERDIMUX_COLOR_ACCENT:-}" @interdimux-color-accent 173)
COLOR_PATH=$(get_opt "${INTERDIMUX_COLOR_PATH:-}" @interdimux-color-path 180)
COLOR_GIT=$(get_opt "${INTERDIMUX_COLOR_GIT:-}" @interdimux-color-git 140)
COLOR_SSH=$(get_opt "${INTERDIMUX_COLOR_SSH:-}" @interdimux-color-ssh 109)
COLOR_EDITOR=$(get_opt "${INTERDIMUX_COLOR_EDITOR:-}" @interdimux-color-editor 150)
COLOR_SUCCESS=$(get_opt "${INTERDIMUX_COLOR_SUCCESS:-}" @interdimux-color-success 150)
COLOR_DANGER=$(get_opt "${INTERDIMUX_COLOR_DANGER:-}" @interdimux-color-danger 167)
COLOR_TREE=$(get_opt "${INTERDIMUX_COLOR_TREE:-}" @interdimux-color-tree 240)
COLOR_SEPARATOR=$(get_opt "${INTERDIMUX_COLOR_SEPARATOR:-}" @interdimux-color-separator 245)
COLOR_QUERY=$(get_opt "${INTERDIMUX_COLOR_QUERY:-}" @interdimux-color-query 223)
COLOR_MATCH_CURRENT=$(get_opt "${INTERDIMUX_COLOR_MATCH_CURRENT:-}" @interdimux-color-match-current 215)
COLOR_CURRENT_BG=$(get_opt "${INTERDIMUX_COLOR_CURRENT_BG:-}" @interdimux-color-current-bg 236)
COLOR_HEADER=$(get_opt "${INTERDIMUX_COLOR_HEADER:-}" @interdimux-color-header 246)
COLOR_BORDER=$(get_opt "${INTERDIMUX_COLOR_BORDER:-}" @interdimux-color-border 238)
COLOR_MENU_SEL_FG=$(get_opt "${INTERDIMUX_COLOR_MENU_SEL_FG:-}" @interdimux-color-menu-sel-fg 235)

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

# Header hint builder: accent key + dim label pairs
hint() {
  local out="" k l
  while [ $# -ge 2 ]; do
    k="$1" l="$2"
    shift 2
    out+="${ACCENT_ESC}${k}"$'\033[0m\033[2m '"${l}"$'\033[0m'
    [ $# -ge 2 ] && out+="  "
  done
  printf '%s' "$out"
}

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

SPEC_TYPE="" SPEC_SESSION="" SPEC_WIDX="" SPEC_PIDX=""

parse_spec() {
  local spec="$1"
  SPEC_TYPE="${spec%%:*}"
  local rest="${spec#*:}"
  case "$SPEC_TYPE" in
    S)
      SPEC_SESSION="$rest"
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
  esac
}

# Human-readable spec label for prompts
spec_label() {
  case "$SPEC_TYPE" in
    S) printf '%s' "session '$SPEC_SESSION'" ;;
    W) printf '%s' "window '$SPEC_SESSION:$SPEC_WIDX'" ;;
    P) printf '%s' "pane '$SPEC_SESSION:$SPEC_WIDX.$SPEC_PIDX'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Process table (built once, used for full-command resolution)
# ---------------------------------------------------------------------------

declare -A PS_CHILDREN=()
declare -A PS_ARGS=()

build_process_table() {
  local pid ppid args
  while read -r pid ppid args; do
    PS_ARGS[$pid]="$args"
    PS_CHILDREN[$ppid]+="$pid "
  done < <(ps -eo pid=,ppid=,args= 2>/dev/null)
}

# Known shells — used to decide whether to descend one level
SHELLS_PATTERN='^-?(ba|z|fi|da|a|k|tc|c)?sh$|^-?login$'

# Get the user's actual command from a pane pid.
# Strategy: if the pane process is a shell, show its direct child (the
# command the user typed).  Do NOT walk further — deeper children are
# subprocesses of that command (LSPs, formatters, watchers, …) and
# showing those is misleading.
full_command() {
  local pid="$1"
  local args="${PS_ARGS[$pid]:-}"
  local cmd_name="${args%% *}"
  cmd_name="${cmd_name##*/}"

  # If the pane process is a shell, look one level down
  if [[ "$cmd_name" =~ $SHELLS_PATTERN ]]; then
    local children="${PS_CHILDREN[$pid]:-}"
    if [ -n "$children" ]; then
      local child="${children%% *}"
      REPLY="${PS_ARGS[$child]:-}"
      return
    fi
  fi

  # Not a shell (or shell has no children) — use as-is
  REPLY="$args"
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
NOW_EPOCH=$(date +%s)
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
  local dims cols=80
  if dims=$({ stty size </dev/tty; } 2>/dev/null); then
    cols="${dims#* }"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  printf '%s' "$cols"
}

# Column widths for the navigator tree, derived from the popup width
# (minus the preview share when the preview starts visible)
IDENT_W=24 PATH_W=24 BADGE_W=14
compute_widths() {
  local avail
  avail=$(term_cols)
  [ "$SHOW_PREVIEW" = "on" ] && avail=$(( avail / 2 ))
  avail=$(( avail - 8 ))
  if   [ "$avail" -ge 88 ]; then IDENT_W=28 PATH_W=32 BADGE_W=16
  elif [ "$avail" -ge 64 ]; then IDENT_W=24 PATH_W=24 BADGE_W=14
  elif [ "$avail" -ge 48 ]; then IDENT_W=20 PATH_W=18 BADGE_W=10
  else                           IDENT_W=18 PATH_W=14 BADGE_W=0
  fi
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

gather_targets() {
  # Current target: anchor to $TMUX_PANE when tmux provides it (popups
  # and run-shell both do) — a bare display-message in a clientless
  # context silently resolves to the most recently attached session.
  local current_session current_window current_pane cur_raw
  cur_raw=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} "#S${US}#I${US}#P")
  IFS="$US" read -r current_session current_window current_pane <<< "$cur_raw"

  compute_widths

  # Build process table once (instead of per-pane pgrep+ps)
  [ "$SHOW_FULL_COMMAND" = "on" ] && build_process_table

  # Bulk-fetch all data using unit separator as internal field delimiter
  local sessions_raw all_windows_raw all_panes_raw
  sessions_raw=$(tmux list-sessions \
    -F "#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_name}${US}#{session_windows}${US}#{?session_attached,attached,}")
  all_windows_raw=$(tmux list-windows -a \
    -F "#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_panes}${US}#{pane_pid}${US}#{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag}")
  all_panes_raw=$(tmux list-panes -a \
    -F "#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{pane_pid}${US}#{window_panes}")

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

  local sla sname swins sattach marker meta age sdisp pfx_cap
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
    # and makes compound queries ("proj edit") work.  The cap is derived
    # from IDENT_W so child rows can't overflow the identity column:
    # window rows spend 6 columns on marker/glyphs + the id, pane rows 7
    # + "w.p" (12 covers both with 2-digit indexes).
    pfx_cap=$(( IDENT_W - 12 ))
    [ "$pfx_cap" -gt 14 ] && pfx_cap=14
    [ "${#sdisp}" -gt "$pfx_cap" ] && sdisp="${sdisp:0:pfx_cap-1}…"

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

# input_dialog ACCENT TITLE PROMPT INITIAL — line editor inside the box
# (readline with the current value prefilled on a real tty); sets REPLY,
# empty means cancelled
input_dialog() {
  local accent="$1" title="$2" prompt="$3" initial="$4"
  dialog_open "$accent" "$title" ""
  dialog_status "${DIM}enter apply · empty input cancels${RST}"
  local irow=$(( DLG_TOP + 2 ))
  printf '\033[%d;%dH%s%s%s\033[?25h' \
    "$irow" $(( DLG_LEFT + 4 )) "$accent" "$prompt" "$RST" >"$tty_out"
  printf '\033[%d;%dH' "$irow" $(( DLG_LEFT + 4 + ${#prompt} )) >"$tty_out"
  drain_input
  REPLY=""
  if [ -n "$initial" ]; then
    IFS= read -e -r -i "$initial" REPLY <"$tty_in" 2>"$tty_out"
  else
    IFS= read -e -r REPLY <"$tty_in" 2>"$tty_out"
  fi
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

  selected=$(bash "$SCRIPT_PATH" --dirs-list | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=1..2 \
    --nth=1 \
    --prompt='new session ❯ ' \
    --header="$(bash "$SCRIPT_PATH" --dirs-header)" \
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

  record_recent_dir "$dir_path"
  # Feed the switch back into zoxide so its frecency learns from
  # navigator usage too
  command -v zoxide >/dev/null 2>&1 && zoxide add "$dir_path" 2>/dev/null

  session_name=$(resolve_session_name "$dir_path")

  if tmux has-session -t "=$session_name" 2>/dev/null; then
    tmux switch-client -t "=$session_name"
  else
    tmux new-session -d -s "$session_name" -c "$dir_path"
    tmux switch-client -t "=$session_name"
  fi
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
sq_script() { printf '%s' "${SCRIPT_PATH//\'/\'\\\'\'}"; }

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

  sp=$(sq_script)
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
  sp=$(sq_script)

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
      'Kill'        k "run-shell -b \"bash '$menu_sp' --launch kill\"" \
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
  tmux run-shell -b "bash '$(sq_script)' --launch $action"
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

RESUME_FILE=$(mktemp "${TMPDIR:-/tmp}/interdimux-resume.XXXXXX")
trap 'rm -f "$RESUME_FILE"' EXIT

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

  case "$INTERDIMUX_MODE" in
    kill)
      fzf_opts+=(
        --prompt='kill ❯ '
        --header="$(hint enter kill ^r reload esc quit)"
        --bind="enter:execute($ACTION_CMD kill {-1})+reload($LIST_CMD)"
      )
      ;;
    rename)
      fzf_opts+=(
        --prompt='rename ❯ '
        --header="$(hint enter rename ^r reload esc quit)"
        --bind="enter:execute($ACTION_CMD rename {-1})+reload($LIST_CMD)"
      )
      ;;
    zoom)
      fzf_opts+=(
        --prompt='zoom ❯ '
        --header="$(hint enter 'toggle zoom' ^r reload esc quit)"
        --bind="enter:execute-silent($ACTION_CMD zoom {-1})+reload($LIST_CMD)+refresh-preview"
      )
      ;;
    swap)
      fzf_opts+=(
        --prompt='swap ❯ '
        --header="$(hint enter swap ^r reload esc quit)"
        --bind="enter:execute($ACTION_CMD swap {-1})+reload($LIST_CMD)"
      )
      ;;
    detach)
      fzf_opts+=(
        --prompt='detach ❯ '
        --header="$(hint enter detach ^r reload esc quit)"
        --bind="enter:execute($ACTION_CMD detach {-1})+reload($LIST_CMD)"
      )
      ;;
    send)
      fzf_opts+=(
        --prompt='send ❯ '
        --header="$(hint enter 'send keys' ^r reload esc quit)"
        --bind="enter:execute($ACTION_CMD send {-1})+reload($LIST_CMD)"
      )
      ;;
    *)
      fzf_opts+=(
        --prompt='❯ '
        --print-query
        --header="$(hint enter switch ^x kill ^e rename ^o new ^r reload ^/ preview)"
        --bind="focus:transform-header(bash '$SCRIPT_PATH' --header-for {-1})"
        --bind="ctrl-x:execute($ACTION_CMD kill {-1})+reload($LIST_CMD)"
        --bind="ctrl-e:execute($ACTION_CMD rename {-1})+reload($LIST_CMD)"
        --bind="ctrl-z:execute-silent($ACTION_CMD zoom {-1})+reload($LIST_CMD)+refresh-preview"
        --bind="ctrl-s:execute($ACTION_CMD swap {-1})+reload($LIST_CMD)"
        --bind="ctrl-d:execute($ACTION_CMD detach {-1})+reload($LIST_CMD)"
        --bind="ctrl-t:execute($ACTION_CMD send {-1})+reload($LIST_CMD)"
        --bind="ctrl-o:execute(bash '$SCRIPT_PATH' --dirs || echo resume > '$RESUME_FILE')+abort"
        --bind='ctrl-/:toggle-preview'
      )
      fzf_ge 58 && fzf_opts+=(
        --bind="ctrl-]:change-nth(1|2|3|1,2,3|1,3)+transform-prompt(bash '$SCRIPT_PATH' --scope-prompt)"
      )
      fzf_ge 61 && fzf_opts+=(--ghost='session · window · pane')
      ;;
  esac

  if [ "$SHOW_PREVIEW" = "on" ]; then
    fzf_opts+=(
      --preview="bash '$SCRIPT_PATH' --preview {-1}"
      --preview-window="right,50%,border-left,nowrap"
    )
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
      tmux new-session -d -s "$session_name" -c "$dir" 2>/dev/null || true
      if [ "$dir" != "$HOME" ]; then record_recent_dir "$dir" || true; fi
    fi
    tmux switch-client -t "=$session_name" 2>/dev/null || true
    exit 0
  fi

  exit 0
done
