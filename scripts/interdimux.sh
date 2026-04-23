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

if [ -z "${TMUX:-}" ]; then
  echo "interdimux: not running inside tmux" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SHOW_FULL_COMMAND="${INTERDIMUX_SHOW_FULL_COMMAND:-on}"
SHOW_GIT_BRANCH="${INTERDIMUX_SHOW_GIT_BRANCH:-on}"

# ---------------------------------------------------------------------------
# Colors — warm palette
# ---------------------------------------------------------------------------

RST=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
AMBER=$'\033[38;5;173m'     # #d7875f — warm amber accent
BOLD_AMBER=$'\033[1;38;5;173m'
DIM_SEP=$'\033[2;37m'       # dim white for separator
DIM_PATH=$'\033[38;5;180m'  # #d7af87 — warm muted gold for paths
DIM_CMD=$'\033[38;5;173m'   # amber for commands
DIM_SSH=$'\033[38;5;109m'   # #87afaf — muted blue for SSH hosts
DIM_EDIT=$'\033[38;5;150m'  # #afd787 — muted green for editor files
DIM_GIT=$'\033[38;5;140m'   # #af87d7 — muted purple for git branches
MARKER_COLOR=$'\033[1;38;5;173m' # bold amber for *

# Column separator (dim pipe)
SEP="${DIM_SEP}│${RST}"

# Shared fzf theme — applied to all pickers for consistency
FZF_THEME=(
  --ansi
  --reverse
  --pointer='❯'
  --color='pointer:173,prompt:173,hl:173,hl+:173:bold,fg+:white:bold,bg+:237,header:245,info:245,spinner:173'
)

# ---------------------------------------------------------------------------
# Directory picker: project detection & history
# ---------------------------------------------------------------------------

PROJECT_MARKERS=(.git Makefile package.json Cargo.toml go.mod pyproject.toml CMakeLists.txt .hg .svn build.gradle pom.xml mix.exs flake.nix)

is_project_root() {
  local dir="$1"
  for m in "${PROJECT_MARKERS[@]}"; do
    [ -e "$dir/$m" ] && return 0
  done
  return 1
}

detect_project_type() {
  local dir="$1"
  [ -f "$dir/Cargo.toml" ]      && { echo "Rust";    return; }
  [ -f "$dir/go.mod" ]          && { echo "Go";      return; }
  [ -f "$dir/package.json" ]    && { echo "Node.js"; return; }
  [ -f "$dir/pyproject.toml" ]  && { echo "Python";  return; }
  [ -f "$dir/CMakeLists.txt" ]  && { echo "C/C++";   return; }
  [ -f "$dir/build.gradle" ]    && { echo "Java";    return; }
  [ -f "$dir/pom.xml" ]         && { echo "Java";    return; }
  [ -f "$dir/mix.exs" ]         && { echo "Elixir";  return; }
  [ -f "$dir/flake.nix" ]       && { echo "Nix";     return; }
  [ -f "$dir/Makefile" ]        && { echo "Make";    return; }
  [ -d "$dir/.git" ]            && { echo "Git";     return; }
  return 0
}

RECENT_DIRS_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/interdimux/recent_dirs"

load_recent_dirs() {
  [ -f "$RECENT_DIRS_FILE" ] || return
  local count=0
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    echo "$d"
    count=$((count + 1))
    [ "$count" -ge 10 ] && break
  done < "$RECENT_DIRS_FILE"
}

record_recent_dir() {
  local dir="$1"
  local dir_parent
  dir_parent="$(dirname "$RECENT_DIRS_FILE")"
  [ -d "$dir_parent" ] || mkdir -p "$dir_parent"

  local tmp
  tmp=$(mktemp)
  echo "$dir" > "$tmp"
  if [ -f "$RECENT_DIRS_FILE" ]; then
    grep -Fxv "$dir" "$RECENT_DIRS_FILE" >> "$tmp" 2>/dev/null || true
  fi
  head -50 "$tmp" > "$RECENT_DIRS_FILE"
  rm -f "$tmp"
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

scan_dirs() {
  local root="$1" depth="$2" finder="$3"
  [ -d "$root" ] || return
  case "$finder" in
    fd|fdfind)
      "$finder" --type d --max-depth "$depth" --absolute-path . "$root" 2>/dev/null || true
      ;;
    find)
      find "$root" -maxdepth "$depth" -type d -not -path '*/.*' 2>/dev/null || true
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

# Sort and emit arrays of dirs by tier (projects first, then others)
emit_sorted_tiers() {
  if [ "${#_projects[@]}" -gt 0 ]; then
    local sorted
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
      printf '%s' "${PS_ARGS[$child]:-}"
      return
    fi
  fi

  # Not a shell (or shell has no children) — use as-is
  printf '%s' "$args"
}

# Resolve the command string to display for a pane.
resolve_command() {
  local short_cmd="$1" pid="$2"
  if [ "$SHOW_FULL_COMMAND" = "on" ]; then
    local fcmd
    fcmd=$(full_command "$pid")
    fcmd="${fcmd#"${fcmd%%[![:space:]]*}"}"
    fcmd="${fcmd%"${fcmd##*[![:space:]]}"}"
    [ -n "$fcmd" ] && { printf '%s' "$fcmd"; return; }
  fi
  printf '%s' "$short_cmd"
}

# ---------------------------------------------------------------------------
# Git branch (pure bash — no subprocess per pane)
# ---------------------------------------------------------------------------

declare -A GIT_BRANCH_CACHE=()

get_git_branch() {
  local dir="$1"
  [ "$SHOW_GIT_BRANCH" != "on" ] && return
  [ -z "$dir" ] && return

  local _cache_key="$dir"
  if [[ -v "GIT_BRANCH_CACHE[$_cache_key]" ]]; then
    printf '%s' "${GIT_BRANCH_CACHE[$_cache_key]}"
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
      printf '%s' "$branch"
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
        printf '%s%s %s%s%s' "$DIM_CMD" "$cmd_base" "$DIM_SSH" "$host" "$RST"
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
      printf '%s%s %s%s%s' "$DIM_CMD" "$cmd_base" "$DIM_EDIT" "$fname" "$RST"
      return
    fi
  fi

  [[ "$old_set" != *f* ]] && set +f
  printf '%s%s%s' "$DIM_CMD" "$cmd_str" "$RST"
}

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

# Pad a string to a target display width using character count
dpad() {
  local str="$1" width="$2"
  printf '%s' "$str"
  local pad=$(( width - ${#str} ))
  [ "$pad" -gt 0 ] && printf '%*s' "$pad" ""
}

# Trim a path to fit within max_width display columns.
trim_path() {
  local path="$1" max_width="$2"

  [ "${#path}" -le "$max_width" ] && { printf '%s' "$path"; return; }

  local prefix=""
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

  printf '%s' "${prefix}${ellipsis}${result}"
}

# ---------------------------------------------------------------------------
# Gather targets (tree layout)
# ---------------------------------------------------------------------------
#
# Output format (tab-delimited):
#   SPEC <TAB> DISPLAY
#
# SPEC uses printable ":" delimiter (parsed right-to-left):
#   S:session_name
#   W:session_name:window_index
#   P:session_name:window_index:pane_index

gather_targets() {
  local current_session current_window current_pane
  current_session=$(tmux display-message -p '#S')
  current_window=$(tmux display-message -p '#I')
  current_pane=$(tmux display-message -p '#P')

  # Build process table once (instead of per-pane pgrep+ps)
  [ "$SHOW_FULL_COMMAND" = "on" ] && build_process_table

  # Bulk-fetch all data using unit separator as internal field delimiter
  local sessions_raw all_windows_raw all_panes_raw
  sessions_raw=$(tmux list-sessions \
    -F "#{session_name}${US}#{session_windows}${US}#{?session_attached,attached,}")
  all_windows_raw=$(tmux list-windows -a \
    -F "#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_panes}${US}#{pane_pid}")
  all_panes_raw=$(tmux list-panes -a \
    -F "#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{pane_pid}${US}#{window_panes}")

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

  # Iterate sessions in list-sessions order
  local marker flags session_windows win_count wi
  local wmarker wpath_raw raw_cmd cmd_formatted git_badge gbranch padded_id padded_path
  local pane_data pane_count pi
  local pmarker ppath_raw

  while IFS="$US" read -r sname swins sattach; do
    marker=" "
    [ "$sname" = "$current_session" ] && marker="${MARKER_COLOR}*${RST}"

    flags=""
    [ -n "$sattach" ] && flags=" ${DIM}[a]${RST}"

    printf 'S:%s\t%s▸%s %s %s%s  %s(%s wins)%s%s\n' \
      "$sname" \
      "$BOLD" "$RST" "$marker" "$BOLD" "$sname" "$DIM" "$swins" "$RST" "$flags"

    session_windows="${windows_by_session[$sname]:-}"
    [ -z "$session_windows" ] && continue

    win_count=$(printf '%s\n' "$session_windows" | wc -l)
    win_count=${win_count// /}

    wi=0
    while IFS="$US" read -r _sn widx wname _wact wcmd wpath wpanes wpid; do
      wi=$((wi + 1))

      wmarker=" "
      [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && wmarker="${MARKER_COLOR}*${RST}"

      wpath_raw="$wpath"
      wpath="${wpath/#$HOME/\~}"
      wpath=$(trim_path "$wpath" 22)

      raw_cmd=$(resolve_command "$wcmd" "$wpid")
      cmd_formatted=$(format_command "$raw_cmd")

      git_badge=""
      gbranch=$(get_git_branch "$wpath_raw")
      [ -n "$gbranch" ] && git_badge=" ${DIM_GIT}‹${gbranch}›${RST}"

      padded_id=$(dpad "$widx:$wname" 14)
      padded_path=$(dpad "$wpath" 22)

      printf 'W:%s:%s\t    %s %s %s %s%s%s %s %s%s\n' \
        "$sname" "$widx" \
        "$wmarker" "$padded_id" \
        "$SEP" "$DIM_PATH" "$padded_path" "$RST" \
        "$SEP" "$cmd_formatted" "$git_badge"

      # Panes (only for multi-pane windows)
      if [ "$wpanes" -gt 1 ]; then
        pane_data="${panes_by_window[${sname}${US}${widx}]:-}"
        [ -z "$pane_data" ] && continue

        pane_count=$(printf '%s\n' "$pane_data" | wc -l)
        pane_count=${pane_count// /}
        pi=0

        while IFS="$US" read -r pidx _pact pcmd ppath ppid _wp2; do
          pi=$((pi + 1))

          pmarker=" "
          [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && [ "$pidx" = "$current_pane" ] && pmarker="${MARKER_COLOR}*${RST}"

          ppath_raw="$ppath"
          ppath="${ppath/#$HOME/\~}"
          ppath=$(trim_path "$ppath" 22)

          raw_cmd=$(resolve_command "$pcmd" "$ppid")
          cmd_formatted=$(format_command "$raw_cmd")

          git_badge=""
          gbranch=$(get_git_branch "$ppath_raw")
          [ -n "$gbranch" ] && git_badge=" ${DIM_GIT}‹${gbranch}›${RST}"

          padded_id=$(dpad ".$pidx" 12)
          padded_path=$(dpad "$ppath" 22)

          printf 'P:%s:%s:%s\t      %s %s %s %s%s%s %s %s%s\n' \
            "$sname" "$widx" "$pidx" \
            "$pmarker" "$padded_id" \
            "$SEP" "$DIM_PATH" "$padded_path" "$RST" \
            "$SEP" "$cmd_formatted" "$git_badge"
        done <<< "$pane_data"
      fi
    done <<< "$session_windows"
  done <<< "$sessions_raw"
}

# ---------------------------------------------------------------------------
# Preview command (called by fzf --preview)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--preview" ]; then
  set +e
  spec="$2"
  spec="${spec%%	*}"
  parse_spec "$spec"

  target=$(spec_target)

  case "$SPEC_TYPE" in
    S)
      printf '\033[1;38;5;173m%s\033[0m\n\n' "$SPEC_SESSION"
      tmux list-windows -t "=$SPEC_SESSION" \
        -F "#{window_index}:#{window_name}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_active}${US}#{window_panes}" 2>/dev/null | \
      while IFS="$US" read -r wid wcmd wpath wact wpanes; do
        marker=" "
        [ "$wact" = "1" ] && marker="*"
        wpath="${wpath/#$HOME/\~}"
        printf ' %s \033[1m%-14s\033[0m \033[38;5;173m%-16s\033[0m \033[38;5;180m%s\033[0m' \
          "$marker" "$wid" "$wcmd" "$wpath"
        [ "$wpanes" -gt 1 ] && printf '  \033[2m(%s panes)\033[0m' "$wpanes"
        printf '\n'
      done
      echo ""
      printf '\033[2m── active pane ──\033[0m\n'
      tmux capture-pane -t "=$SPEC_SESSION" -p -e -S -30 2>/dev/null || echo "(no active pane)"
      ;;
    *)
      tmux capture-pane -t "$target" -p -e -S -50 2>/dev/null || echo "(cannot capture pane)"
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
  printf '\033[1;38;5;173m%s\033[0m\n' "$(basename "$dir")"
  printf '\033[2m%s\033[0m\n\n' "$display_path"

  ptype=$(detect_project_type "$dir")
  [ -n "$ptype" ] && printf '  \033[38;5;150mType:\033[0m %s\n' "$ptype"

  if [ -d "$dir/.git" ]; then
    head_file="$dir/.git/HEAD"
    if [ -f "$head_file" ]; then
      read -r head_content < "$head_file" 2>/dev/null || head_content=""
      case "$head_content" in
        "ref: refs/heads/"*) printf '  \033[38;5;140mBranch:\033[0m %s\n' "${head_content#ref: refs/heads/}" ;;
        ?*) printf '  \033[38;5;140mBranch:\033[0m @%s\n' "${head_content:0:7}" ;;
      esac
    fi

    last_commit=$(git -C "$dir" log -1 --oneline 2>/dev/null || true)
    [ -n "$last_commit" ] && printf '  \033[38;5;180mCommit:\033[0m %s\n' "$last_commit"

    changed=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$changed" -gt 0 ] && printf '  \033[38;5;173mChanges:\033[0m %s files\n' "$changed"
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

  printf '\n\033[2m── contents ──\033[0m\n'
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
      --deep) mode="deep"; query="${2:-}"; shift 2 ;;
      --scan) mode="scan"; query="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  finder=$(resolve_finder)
  [ -z "$finder" ] && { echo "interdimux: no directory finder available" >&2; exit 1; }

  mapfile -t search_paths < <(resolve_search_paths)
  [ ${#search_paths[@]} -eq 0 ] && search_paths=("$HOME")

  declare -A seen=()

  emit_dir() {
    local dir="$1" tier="$2" extra="$3"
    [[ -v "seen[$dir]" ]] && return
    seen["$dir"]=1
    local display_path="${dir/#$HOME/\~}"
    case "$tier" in
      recent)
        printf '%s\t  %s★%s  %-40s %s(recent)%s\n' \
          "$dir" "$BOLD_AMBER" "$RST" "$display_path" "$DIM" "$RST"
        ;;
      project)
        local ptype
        ptype=$(detect_project_type "$dir")
        local type_badge=""
        [ -n "$ptype" ] && type_badge=" ${DIM}${ptype}${RST}"
        printf '%s\t  \033[38;5;150m◆\033[0m  %-40s%s\n' \
          "$dir" "$display_path" "$type_badge"
        ;;
      dir)
        printf '%s\t  %s·%s  %s\n' \
          "$dir" "$DIM" "$RST" "$display_path"
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
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ -z "$query" ] || [[ "$d" == *"$query"* ]]; then
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
        for sp in "${search_paths[@]}"; do
          [ -d "$sp" ] || continue
          while IFS= read -r d; do
            [ -z "$d" ] || [ "$d" = "$sp" ] && continue
            if [[ "$d" == *"$query"* ]]; then
              collect_dir "$d"
              while IFS= read -r sub; do
                [ -z "$sub" ] && continue
                collect_dir "$sub"
              done < <(scan_dirs "$d" 3 "$finder")
            fi
          done < <(scan_dirs "$sp" 1 "$finder")
        done

        if [[ "$query" == /* ]] && [ -d "$query" ]; then
          while IFS= read -r d; do
            [ -z "$d" ] && continue
            collect_dir "$d"
          done < <(scan_dirs "$query" 3 "$finder")
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
# Actions (called by fzf keybindings via execute)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--action" ]; then
  set +e
  action="$2"
  spec="$3"
  spec="${spec%%	*}"
  parse_spec "$spec"
  target=$(spec_target)
  label=$(spec_label)

  # /dev/tty for interactive I/O; overridable for testing
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"

  case "$action" in
    kill)
      printf '\n  \033[1;31mKill %s?\033[0m\n\n  Press [y] to confirm, any other key to cancel: ' "$label" >"$tty_out"
      read -rsn1 confirm <"$tty_in"
      echo >"$tty_out"
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        case "$SPEC_TYPE" in
          S) tmux kill-session -t "$target" 2>/dev/null ;;
          W) tmux kill-window  -t "$target" 2>/dev/null ;;
          P) tmux kill-pane    -t "$target" 2>/dev/null ;;
        esac
        if [ $? -eq 0 ]; then
          printf '\n  \033[32mDone.\033[0m\n' >"$tty_out"
        else
          printf '\n  \033[31mFailed to kill %s.\033[0m\n' "$label" >"$tty_out"
        fi
        sleep 0.5
      fi
      ;;

    rename)
      if [ "$SPEC_TYPE" = "P" ]; then
        printf '\n  Panes cannot be renamed.\n' >"$tty_out"
        sleep 1
        exit 0
      fi
      printf '\n  \033[1mRename %s\033[0m\n\n  New name: ' "$label" >"$tty_out"
      read -r new_name <"$tty_in"
      if [ -n "$new_name" ]; then
        case "$SPEC_TYPE" in
          S) tmux rename-session -t "$target" "$new_name" 2>/dev/null ;;
          W) tmux rename-window  -t "$target" "$new_name" 2>/dev/null ;;
        esac
        if [ $? -eq 0 ]; then
          printf '\n  \033[32mRenamed to: %s\033[0m\n' "$new_name" >"$tty_out"
        else
          printf '\n  \033[31mFailed to rename.\033[0m\n' >"$tty_out"
        fi
        sleep 0.5
      fi
      ;;

    zoom)
      if [ "$SPEC_TYPE" != "P" ]; then
        printf '\n  Only panes can be zoomed.\n' >"$tty_out"
        sleep 1
        exit 0
      fi
      if tmux resize-pane -Z -t "$target" 2>/dev/null; then
        printf '\n  \033[32mToggled zoom on %s.\033[0m\n' "$label" >"$tty_out"
      else
        printf '\n  \033[31mFailed to toggle zoom.\033[0m\n' >"$tty_out"
      fi
      sleep 0.4
      ;;

    detach)
      if [ "$SPEC_TYPE" != "S" ]; then
        printf '\n  Only sessions can be detached.\n' >"$tty_out"
        sleep 1
        exit 0
      fi
      printf '\n  \033[1mDetach all clients from %s?\033[0m\n\n  Press [y] to confirm: ' "$label" >"$tty_out"
      read -rsn1 confirm <"$tty_in"
      echo >"$tty_out"
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        if tmux detach-client -s "$target" 2>/dev/null; then
          printf '\n  \033[32mDetached clients from %s.\033[0m\n' "$label" >"$tty_out"
        else
          printf '\n  \033[31mFailed to detach.\033[0m\n' >"$tty_out"
        fi
        sleep 0.5
      fi
      ;;

    send)
      printf '\n  \033[1mSend keys to %s\033[0m\n\n  Command: ' "$label" >"$tty_out"
      read -r send_cmd <"$tty_in"
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
          printf '\n  \033[32mSent to %d pane(s) in %s.\033[0m\n' "$sent" "$label" >"$tty_out"
        else
          printf '\n  \033[33mSent to %d pane(s), %d failed in %s.\033[0m\n' "$sent" "$failed" "$label" >"$tty_out"
        fi
        sleep 0.5
      fi
      ;;

    swap)
      printf '\n  \033[1mSwap %s with…\033[0m\n' "$label" >"$tty_out"
      sleep 0.3

      # Call gather_targets directly (subprocess would hit set -euo issues)
      swap_list=$(gather_targets)

      case "$SPEC_TYPE" in
        W) swap_list=$(printf '%s\n' "$swap_list" | grep "^W:" || true) ;;
        P) swap_list=$(printf '%s\n' "$swap_list" | grep "^P:" || true) ;;
        *)
          printf '\n  Only windows and panes can be swapped.\n' >"$tty_out"
          sleep 1
          exit 0
          ;;
      esac

      [ -z "$swap_list" ] && { printf '\n  No valid swap targets.\n' >"$tty_out"; sleep 1; exit 0; }

      dest=$(printf '%s\n' "$swap_list" | fzf \
        "${FZF_THEME[@]}" \
        --delimiter=$'\t' \
        --with-nth=2 \
        --prompt='swap with ❯ ' \
        --header='Select swap destination (ESC to cancel)' \
      ) || exit 0

      dest_spec="${dest%%	*}"
      parse_spec "$dest_spec"
      dest_target=$(spec_target)

      parse_spec "$spec"
      src_target=$(spec_target)

      case "$SPEC_TYPE" in
        W) tmux swap-window -s "$src_target" -t "$dest_target" 2>/dev/null ;;
        P) tmux swap-pane   -s "$src_target" -t "$dest_target" 2>/dev/null ;;
      esac

      if [ $? -eq 0 ]; then
        printf '\n  \033[32mSwapped.\033[0m\n' >"$tty_out"
      else
        printf '\n  \033[31mSwap failed.\033[0m\n' >"$tty_out"
      fi
      sleep 0.4
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# New session from directory (ctrl-o)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dirs" ]; then
  set +e

  selected=$(bash "$SCRIPT_PATH" --dirs-list | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='new session ❯ ' \
    --header='enter=create  ^f=deep search  ^g=browse into  ^r=reset  esc=cancel' \
    --preview="bash '$SCRIPT_PATH' --dirs-preview {1}" \
    --preview-window="right:40%:nowrap" \
    --bind="ctrl-f:reload:bash '$SCRIPT_PATH' --dirs-list --deep {q}" \
    --bind="ctrl-g:reload:bash '$SCRIPT_PATH' --dirs-list --scan {1}" \
    --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --dirs-list)+transform-header(echo 'enter=create  ^f=deep search  ^g=browse into  ^r=reset  esc=cancel')" \
  ) || exit 0

  dir_path="${selected%%	*}"
  dir_path="${dir_path%/}"

  record_recent_dir "$dir_path"

  session_name=$(basename "$dir_path" | tr '.:' '-')

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
  spec="$2"
  spec="${spec%%	*}"
  type="${spec%%:*}"
  case "$type" in
    S) echo "enter=switch  ^x=kill  ^e=rename  ^d=detach  ^o=new  ^r=reload  ^/=preview" ;;
    W) echo "enter=switch  ^x=kill  ^e=rename  ^s=swap  ^o=new  ^r=reload  ^/=preview" ;;
    P) echo "enter=switch  ^x=kill  ^z=zoom  ^s=swap  ^t=send  ^r=reload  ^/=preview" ;;
    *)  echo "enter=switch  ^x=kill  ^e=rename  ^o=new  ^r=reload  ^/=preview" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dashboard" ]; then
  set +e
  PW="${INTERDIMUX_POPUP_WIDTH:-80%}"
  PH="${INTERDIMUX_POPUP_HEIGHT:-75%}"

  ENV_FWD="INTERDIMUX_SHOW_PREVIEW=${INTERDIMUX_SHOW_PREVIEW:-on}"
  ENV_FWD+=" INTERDIMUX_SHOW_FULL_COMMAND=${INTERDIMUX_SHOW_FULL_COMMAND:-on}"
  ENV_FWD+=" INTERDIMUX_SHOW_GIT_BRANCH=${INTERDIMUX_SHOW_GIT_BRANCH:-on}"
  ENV_FWD+=" INTERDIMUX_POPUP_WIDTH=$PW INTERDIMUX_POPUP_HEIGHT=$PH"

  items=$(printf '%s\t  \033[1;38;5;173m%-16s\033[0m \033[2m%s\033[0m\n' \
    "switch" "Switch"       "Navigate & jump to target" \
    "new"    "New Session"  "Create session from directory" \
    "rename" "Rename"       "Rename a session or window" \
    "kill"   "Kill"         "Remove sessions, windows, or panes" \
    "zoom"   "Zoom"         "Toggle pane zoom" \
    "swap"   "Swap"         "Swap windows or panes" \
    "detach" "Detach"       "Detach clients from session" \
    "send"   "Send Keys"    "Send a command to a pane")

  choice=$(printf '%s\n' "$items" | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --no-info \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='interdimux ❯ ' \
    --header='' \
  ) || exit 0

  action="${choice%%	*}"

  # Launch the selected tool in a new full-size popup via run-shell -b
  # (can't nest popups, so this runs asynchronously after dashboard closes)
  launch() {
    tmux run-shell -b "tmux popup -w '$PW' -h '$PH' -E '$ENV_FWD $1'"
  }

  case "$action" in
    switch) launch "bash '${SCRIPT_PATH}'" ;;
    new)    launch "bash '${SCRIPT_PATH}' --dirs" ;;
    rename) launch "INTERDIMUX_MODE=rename bash '${SCRIPT_PATH}'" ;;
    kill)   launch "INTERDIMUX_MODE=kill bash '${SCRIPT_PATH}'" ;;
    zoom)   launch "INTERDIMUX_MODE=zoom bash '${SCRIPT_PATH}'" ;;
    swap)   launch "INTERDIMUX_MODE=swap bash '${SCRIPT_PATH}'" ;;
    detach) launch "INTERDIMUX_MODE=detach bash '${SCRIPT_PATH}'" ;;
    send)   launch "INTERDIMUX_MODE=send bash '${SCRIPT_PATH}'" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Main — navigator loop
# ---------------------------------------------------------------------------

INTERDIMUX_MODE="${INTERDIMUX_MODE:-switch}"

# Temp file to signal "run action then restart fzf"
RESUME_FILE=$(mktemp "${TMPDIR:-/tmp}/interdimux-resume.XXXXXX")
trap 'rm -f "$RESUME_FILE"' EXIT

# Helper: build an fzf --bind that executes an action, signals resume, and aborts.
_action_bind() {
  local key="$1" action_cmd="$2"
  fzf_opts+=(
    --bind="$key:execute($action_cmd)+execute-silent(echo resume > '$RESUME_FILE')+abort"
  )
}

while true; do
  : > "$RESUME_FILE"

  fzf_opts=(
    "${FZF_THEME[@]}"
    --delimiter=$'\t'
    --with-nth=2
    --tiebreak=length,begin,index
    --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --list)"
  )

  case "$INTERDIMUX_MODE" in
    kill)
      fzf_opts+=(--prompt='interdimux kill ❯ ' --header='enter=kill  ctrl-r=reload  esc=quit')
      _action_bind "enter" "bash '$SCRIPT_PATH' --action kill {1}"
      ;;
    rename)
      fzf_opts+=(--prompt='interdimux rename ❯ ' --header='enter=rename  ctrl-r=reload  esc=quit')
      _action_bind "enter" "bash '$SCRIPT_PATH' --action rename {1}"
      ;;
    zoom)
      fzf_opts+=(
        --prompt='interdimux zoom ❯ '
        --header='enter=toggle zoom  ctrl-r=reload  esc=quit'
        --bind="enter:execute-silent(bash '$SCRIPT_PATH' --action zoom {1})+execute-silent(echo resume > '$RESUME_FILE')+abort"
      )
      ;;
    swap)
      fzf_opts+=(--prompt='interdimux swap ❯ ' --header='enter=swap  ctrl-r=reload  esc=quit')
      _action_bind "enter" "bash '$SCRIPT_PATH' --action swap {1}"
      ;;
    detach)
      fzf_opts+=(--prompt='interdimux detach ❯ ' --header='enter=detach  ctrl-r=reload  esc=quit')
      _action_bind "enter" "bash '$SCRIPT_PATH' --action detach {1}"
      ;;
    send)
      fzf_opts+=(--prompt='interdimux send ❯ ' --header='enter=send keys  ctrl-r=reload  esc=quit')
      _action_bind "enter" "bash '$SCRIPT_PATH' --action send {1}"
      ;;
    *)
      fzf_opts+=(
        --prompt='interdimux ❯ '
        --header='enter=switch  ^x=kill  ^e=rename  ^o=new  ^r=reload  ^/=preview'
        --bind="focus:transform-header(bash '$SCRIPT_PATH' --header-for {1})"
        --bind="ctrl-z:execute-silent(bash '$SCRIPT_PATH' --action zoom {1})+execute-silent(echo resume > '$RESUME_FILE')+abort"
        --bind='ctrl-/:toggle-preview'
      )
      _action_bind "ctrl-x" "bash '$SCRIPT_PATH' --action kill {1}"
      _action_bind "ctrl-e" "bash '$SCRIPT_PATH' --action rename {1}"
      _action_bind "ctrl-o" "bash '$SCRIPT_PATH' --dirs"
      _action_bind "ctrl-s" "bash '$SCRIPT_PATH' --action swap {1}"
      _action_bind "ctrl-d" "bash '$SCRIPT_PATH' --action detach {1}"
      _action_bind "ctrl-t" "bash '$SCRIPT_PATH' --action send {1}"
      ;;
  esac

  if [ "${INTERDIMUX_SHOW_PREVIEW:-on}" = "on" ]; then
    fzf_opts+=(
      --preview="bash '$SCRIPT_PATH' --preview {1}"
      --preview-window="right:50%:nowrap"
    )
  fi

  set +e
  selection=$(gather_targets | fzf "${fzf_opts[@]}")
  fzf_rc=$?
  set -e

  # Action requested a restart — loop back
  [ -s "$RESUME_FILE" ] && continue

  # Esc/ctrl-c or empty selection — exit
  if [ "$fzf_rc" -ne 0 ] || [ -z "$selection" ]; then
    exit 0
  fi

  # Action modes use execute+abort (always resume), so reaching here
  # in a non-switch mode means something unexpected — just exit
  [ "$INTERDIMUX_MODE" != "switch" ] && exit 0

  # Switch to selected target
  spec="${selection%%	*}"
  parse_spec "$spec"
  target=$(spec_target)

  tmux switch-client -t "$target" 2>/dev/null || \
    tmux display-message "interdimux: $(spec_label) no longer exists"
  exit 0
done
