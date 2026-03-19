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

# Silently disable full command display when pgrep is unavailable
if [ "$SHOW_FULL_COMMAND" = "on" ] && ! command -v pgrep >/dev/null 2>&1; then
  SHOW_FULL_COMMAND="off"
fi

# ---------------------------------------------------------------------------
# Colors — warm palette inspired by Claude Code UI
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
  echo ""
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

  # Build new file: selected dir on top, then existing entries (deduped)
  local tmp
  tmp=$(mktemp)
  echo "$dir" > "$tmp"
  if [ -f "$RECENT_DIRS_FILE" ]; then
    grep -v "^${dir}$" "$RECENT_DIRS_FILE" >> "$tmp" 2>/dev/null || true
  fi
  # Truncate to 50 entries
  head -50 "$tmp" > "$RECENT_DIRS_FILE"
  rm -f "$tmp"
}

# Resolve the directory finder binary once
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

# Scan directories under a root at a given depth using fd or find
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

# Resolve search paths from config or defaults
resolve_search_paths() {
  local project_dirs="${INTERDIMUX_PROJECT_DIRS:-$(tmux show-option -gqv @interdimux-project-dirs 2>/dev/null || true)}"
  if [ -n "${project_dirs:-}" ]; then
    IFS=':' read -ra _paths <<< "$project_dirs"
    for p in "${_paths[@]}"; do
      eval echo "$p"  # expand ~
    done
  else
    for d in "$HOME/projects" "$HOME/code" "$HOME/src" "$HOME/repos" "$HOME/work" "$HOME/dev"; do
      [ -d "$d" ] && echo "$d"
    done
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

# Walk the process tree from a given pid to its leaf child
full_command() {
  local pid="$1" children
  while true; do
    children="${PS_CHILDREN[$pid]:-}"
    [ -z "$children" ] && break
    pid="${children%% *}"
  done
  printf '%s' "${PS_ARGS[$pid]:-}"
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

  # Check cache first
  if [ -n "${GIT_BRANCH_CACHE[$dir]+x}" ]; then
    printf '%s' "${GIT_BRANCH_CACHE[$dir]}"
    return
  fi

  # Walk up to find .git
  local d="$dir"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -d "$d/.git" ]; then
      local head_file="$d/.git/HEAD"
      [ -f "$head_file" ] || break
      local head_content
      read -r head_content < "$head_file" 2>/dev/null || break
      local branch=""
      case "$head_content" in
        "ref: refs/heads/"*)
          branch="${head_content#ref: refs/heads/}"
          ;;
        *)
          # Detached HEAD — show short SHA
          branch="@${head_content:0:7}"
          ;;
      esac
      GIT_BRANCH_CACHE["$dir"]="$branch"
      printf '%s' "$branch"
      return
    fi
    d="${d%/*}"
  done

  GIT_BRANCH_CACHE["$dir"]=""
}

# ---------------------------------------------------------------------------
# Smart command formatting (SSH host, editor context)
# ---------------------------------------------------------------------------

# Known editors for context-aware display
EDITORS_PATTERN='^(n?vim|vi|nvim|nano|emacs|code|hx|helix|micro|kate|gedit|subl)$'

format_command() {
  local cmd_str="$1"
  local cmd_name="${cmd_str%% *}"
  local cmd_base="${cmd_name##*/}"

  # SSH: highlight user@host
  case "$cmd_base" in
    ssh|mosh)
      local host=""
      local args="${cmd_str#* }"
      # Extract last non-flag argument as the host
      local word=""
      for word in $args; do
        case "$word" in
          -*) ;;
          *)  host="$word" ;;
        esac
      done
      if [ -n "$host" ]; then
        printf '%s%s %s%s%s' "$DIM_CMD" "$cmd_base" "$DIM_SSH" "$host" "$RST"
        return
      fi
      ;;
  esac

  # Editors: highlight the file being edited
  if [[ "$cmd_base" =~ $EDITORS_PATTERN ]]; then
    local file=""
    local args="${cmd_str#* }"
    [ "$args" = "$cmd_str" ] && args=""
    local word=""
    for word in $args; do
      case "$word" in
        -*) ;;
        *)  file="$word" ;;
      esac
    done
    if [ -n "$file" ]; then
      local fname="${file##*/}"
      printf '%s%s %s%s%s' "$DIM_CMD" "$cmd_base" "$DIM_EDIT" "$fname" "$RST"
      return
    fi
  fi

  # Default
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

  # Already fits
  [ "${#path}" -le "$max_width" ] && { printf '%s' "$path"; return; }

  # Preserve leading ~ or / as the root prefix
  local prefix=""
  case "$path" in
    "~/"*) prefix="~/"; path="${path#\~/}" ;;
    "/"*)  prefix="/";  path="${path#/}" ;;
  esac

  local ellipsis="…/"
  local budget=$(( max_width - ${#prefix} - ${#ellipsis} ))

  # Take path components from the right until budget is exhausted
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

    # Pop rightmost component
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
    if [ -n "${windows_by_session[$sn]+x}" ]; then
      windows_by_session["$sn"]+=$'\n'"$line"
    else
      windows_by_session["$sn"]="$line"
    fi
  done <<< "$all_windows_raw"

  # Build lookup: panes grouped by "session\x1fwindow_index"
  declare -A panes_by_window=()
  while IFS="$US" read -r sn widx rest; do
    local key="${sn}${US}${widx}"
    if [ -n "${panes_by_window[$key]+x}" ]; then
      panes_by_window["$key"]+=$'\n'"$rest"
    else
      panes_by_window["$key"]="$rest"
    fi
  done <<< "$all_panes_raw"

  # Iterate sessions in list-sessions order
  while IFS="$US" read -r sname swins sattach; do
    # --- Session header ---
    local marker=" "
    [ "$sname" = "$current_session" ] && marker="${MARKER_COLOR}*${RST}"

    local flags=""
    [ -n "$sattach" ] && flags=" ${DIM}[a]${RST}"

    printf 'S:%s\t%s▸%s %s %s%s  %s(%s wins)%s%s\n' \
      "$sname" \
      "$BOLD" "$RST" "$marker" "$BOLD" "$sname" "$DIM" "$swins" "$RST" "$flags"

    # --- Windows for this session ---
    local session_windows="${windows_by_session[$sname]:-}"
    [ -z "$session_windows" ] && continue

    local win_count
    win_count=$(printf '%s\n' "$session_windows" | wc -l)
    win_count=${win_count// /}

    local wi=0
    while IFS="$US" read -r _sn widx wname _wact wcmd wpath wpanes wpid; do
      wi=$((wi + 1))

      local wmarker=" "
      [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && wmarker="${MARKER_COLOR}*${RST}"

      local wpath_raw="$wpath"
      wpath="${wpath/#$HOME/\~}"
      wpath=$(trim_path "$wpath" 22)

      local branch="├─"
      [ "$wi" -eq "$win_count" ] && branch="└─"

      local raw_cmd
      raw_cmd=$(resolve_command "$wcmd" "$wpid")
      local cmd_formatted
      cmd_formatted=$(format_command "$raw_cmd")

      # Git branch badge
      local git_badge=""
      local gbranch
      gbranch=$(get_git_branch "$wpath_raw")
      [ -n "$gbranch" ] && git_badge=" ${DIM_GIT}‹${gbranch}›${RST}"

      local padded_id padded_path
      padded_id=$(dpad "$widx:$wname" 14)
      padded_path=$(dpad "$wpath" 22)

      printf 'W:%s:%s\t  %s %s %s %s %s%s%s %s %s%s\n' \
        "$sname" "$widx" \
        "$branch" "$wmarker" "$padded_id" \
        "$SEP" "$DIM_PATH" "$padded_path" "$RST" \
        "$SEP" "$cmd_formatted" "$git_badge"

      # --- Panes (only for multi-pane windows) ---
      if [ "$wpanes" -gt 1 ]; then
        local pane_data="${panes_by_window[${sname}${US}${widx}]:-}"
        [ -z "$pane_data" ] && continue

        local pane_count
        pane_count=$(printf '%s\n' "$pane_data" | wc -l)
        pane_count=${pane_count// /}
        local pi=0

        # Continuation: │ aligns under ├/└, blank for last window
        local cont="│  "
        [ "$wi" -eq "$win_count" ] && cont="   "

        while IFS="$US" read -r pidx _pact pcmd ppath ppid _wp2; do
          pi=$((pi + 1))

          local pmarker=" "
          [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && [ "$pidx" = "$current_pane" ] && pmarker="${MARKER_COLOR}*${RST}"

          local ppath_raw="$ppath"
          ppath="${ppath/#$HOME/\~}"
          ppath=$(trim_path "$ppath" 22)

          local pbranch="├─"
          [ "$pi" -eq "$pane_count" ] && pbranch="└─"

          local raw_cmd
          raw_cmd=$(resolve_command "$pcmd" "$ppid")
          local cmd_formatted
          cmd_formatted=$(format_command "$raw_cmd")

          # Git branch badge
          local git_badge=""
          local gbranch
          gbranch=$(get_git_branch "$ppath_raw")
          [ -n "$gbranch" ] && git_badge=" ${DIM_GIT}‹${gbranch}›${RST}"

          local padded_id padded_path
          padded_id=$(dpad ".$pidx" 11)
          padded_path=$(dpad "$ppath" 22)

          printf 'P:%s:%s:%s\t  %s%s %s %s %s %s%s%s %s %s%s\n' \
            "$sname" "$widx" "$pidx" \
            "$cont" "$pbranch" "$pmarker" "$padded_id" \
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
  spec="$2"
  spec="${spec%%	*}"
  parse_spec "$spec"

  target=$(spec_target)

  case "$SPEC_TYPE" in
    S)
      # Session summary: list windows with their commands and paths
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
      # Show active pane content of the session
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
  dir="$2"
  [ -d "$dir" ] || { echo "(directory not found)"; exit 0; }

  display_path="${dir/#$HOME/\~}"
  printf '\033[1;38;5;173m%s\033[0m\n' "$(basename "$dir")"
  printf '\033[2m%s\033[0m\n\n' "$display_path"

  # Project type
  ptype=$(detect_project_type "$dir")
  [ -n "$ptype" ] && printf '  \033[38;5;150mType:\033[0m %s\n' "$ptype"

  # Git info
  if [ -d "$dir/.git" ]; then
    local_branch=""
    head_file="$dir/.git/HEAD"
    if [ -f "$head_file" ]; then
      head_content=""
      read -r head_content < "$head_file" 2>/dev/null
      case "$head_content" in
        "ref: refs/heads/"*) local_branch="${head_content#ref: refs/heads/}" ;;
        *) local_branch="@${head_content:0:7}" ;;
      esac
    fi
    [ -n "$local_branch" ] && printf '  \033[38;5;140mBranch:\033[0m %s\n' "$local_branch"

    # Last commit (one-liner)
    last_commit=$(git -C "$dir" log -1 --oneline 2>/dev/null || true)
    [ -n "$last_commit" ] && printf '  \033[38;5;180mCommit:\033[0m %s\n' "$last_commit"

    # Working tree status summary
    changed=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$changed" -gt 0 ] && printf '  \033[38;5;173mChanges:\033[0m %s files\n' "$changed"
  fi

  # README excerpt
  for readme in README.md README.rst README.txt README; do
    if [ -f "$dir/$readme" ]; then
      desc=""
      while IFS= read -r line; do
        # Skip empty lines and markdown headings
        case "$line" in
          ""|\#*|=*|-*) continue ;;
          *) desc="$line"; break ;;
        esac
      done < "$dir/$readme"
      [ -n "$desc" ] && printf '\n  \033[2m%s\033[0m\n' "$desc"
      break
    fi
  done

  # Compact directory listing
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
      --deep) mode="deep"; query="$2"; shift 2 ;;
      --scan) mode="scan"; query="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  finder=$(resolve_finder)
  [ -z "$finder" ] && { echo "interdimux: no directory finder available" >&2; exit 1; }

  # Collect search paths
  mapfile -t search_paths < <(resolve_search_paths)
  [ ${#search_paths[@]} -eq 0 ] && search_paths=("$HOME")

  # Track already-emitted paths to avoid duplicates
  declare -A seen=()

  emit_dir() {
    local dir="$1" tier="$2" extra="$3"
    [ -n "${seen[$dir]+x}" ] && return
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
      # Tier 1: Recent directories
      while IFS= read -r d; do
        [ -n "$d" ] && emit_dir "$d" recent ""
      done < <(load_recent_dirs)

      # Tier 2: Project roots (depth 1 children of search paths)
      projects=()
      others=()
      for sp in "${search_paths[@]}"; do
        [ -d "$sp" ] || continue
        while IFS= read -r d; do
          [ -z "$d" ] || [ "$d" = "$sp" ] && continue
          if is_project_root "$d"; then
            projects+=("$d")
          else
            others+=("$d")
          fi
        done < <(scan_dirs "$sp" 1 "$finder")
      done

      # Emit projects sorted
      IFS=$'\n' sorted_projects=($(printf '%s\n' "${projects[@]}" | sort)); unset IFS
      for d in "${sorted_projects[@]}"; do
        emit_dir "$d" project ""
      done

      # Tier 3: Other directories
      IFS=$'\n' sorted_others=($(printf '%s\n' "${others[@]}" | sort)); unset IFS
      for d in "${sorted_others[@]}"; do
        emit_dir "$d" dir ""
      done
      ;;

    deep)
      # Deep scan: increase depth on directories matching the query.
      # If query is empty, scan all search paths at depth 2.

      # Emit matching recent dirs
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -z "$query" ] || [[ "$d" == *"$query"* ]] && emit_dir "$d" recent ""
      done < <(load_recent_dirs)

      # Collect all candidates, then emit projects before plain dirs
      projects=()
      others=()

      collect_dir() {
        local d="$1"
        if is_project_root "$d"; then
          projects+=("$d")
        else
          others+=("$d")
        fi
      }

      if [ -z "$query" ]; then
        # No query: scan all search paths at depth 2
        for sp in "${search_paths[@]}"; do
          [ -d "$sp" ] || continue
          while IFS= read -r d; do
            [ -z "$d" ] || [ "$d" = "$sp" ] && continue
            collect_dir "$d"
          done < <(scan_dirs "$sp" 2 "$finder")
        done
      else
        # Query present: deep-scan only matching children at depth 3
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

        # If query looks like an absolute path, scan it directly
        if [[ "$query" == /* ]] && [ -d "$query" ]; then
          while IFS= read -r d; do
            [ -z "$d" ] && continue
            collect_dir "$d"
          done < <(scan_dirs "$query" 3 "$finder")
        fi
      fi

      IFS=$'\n' sorted_projects=($(printf '%s\n' "${projects[@]}" | sort -u)); unset IFS
      for d in "${sorted_projects[@]}"; do
        emit_dir "$d" project ""
      done
      IFS=$'\n' sorted_others=($(printf '%s\n' "${others[@]}" | sort -u)); unset IFS
      for d in "${sorted_others[@]}"; do
        emit_dir "$d" dir ""
      done
      ;;

    scan)
      # Custom path scan: treat query as a filesystem path
      scan_root=""

      # Try the query as-is first, then expand ~
      if [ -d "$query" ]; then
        scan_root="$query"
      else
        expanded="${query/#\~/$HOME}"
        if [ -d "$expanded" ]; then
          scan_root="$expanded"
        else
          # Try the parent directory
          parent="$(dirname "$expanded")"
          [ -d "$parent" ] && scan_root="$parent"
        fi
      fi

      if [ -n "$scan_root" ]; then
        # Collect all candidates, then emit projects before plain dirs
        projects=()
        others=()

        collect_dir() {
          local d="$1"
          if is_project_root "$d"; then
            projects+=("$d")
          else
            others+=("$d")
          fi
        }

        collect_dir "$scan_root"
        while IFS= read -r d; do
          [ -z "$d" ] || [ "$d" = "$scan_root" ] && continue
          collect_dir "$d"
        done < <(scan_dirs "$scan_root" 2 "$finder")

        IFS=$'\n' sorted_projects=($(printf '%s\n' "${projects[@]}" | sort -u)); unset IFS
        for d in "${sorted_projects[@]}"; do
          emit_dir "$d" project ""
        done
        IFS=$'\n' sorted_others=($(printf '%s\n' "${others[@]}" | sort -u)); unset IFS
        for d in "${sorted_others[@]}"; do
          emit_dir "$d" dir ""
        done
      fi
      ;;
  esac

  exit 0
fi

# ---------------------------------------------------------------------------
# Actions (called by fzf keybindings via execute)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--action" ]; then
  # Disable set -e inside action handlers — we handle errors ourselves
  set +e
  # Disable set -e inside action handlers — we handle errors ourselves
  set +e
  action="$2"
  spec="$3"
  spec="${spec%%	*}"
  parse_spec "$spec"
  target=$(spec_target)
  label=$(spec_label)

  # Write directly to /dev/tty — fzf's execute captures stdout,
  # so normal printf is invisible inside a tmux popup.
  tty=/dev/tty

  case "$action" in
    kill)
      printf '\n  \033[1;31mKill %s?\033[0m\n\n  Press [y] to confirm, any other key to cancel: ' "$label" >"$tty"
      read -rsn1 confirm <"$tty"
      echo >"$tty"
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        case "$SPEC_TYPE" in
          S) tmux kill-session -t "$target" 2>/dev/null ;;
          W) tmux kill-window  -t "$target" 2>/dev/null ;;
          P) tmux kill-pane    -t "$target" 2>/dev/null ;;
        esac
        if [ $? -eq 0 ]; then
          printf '\n  \033[32mDone.\033[0m\n' >"$tty"
        else
          printf '\n  \033[31mFailed to kill %s.\033[0m\n' "$label" >"$tty"
        fi
        sleep 0.5
      fi
      ;;

    rename)
      if [ "$SPEC_TYPE" = "P" ]; then
        printf '\n  Panes cannot be renamed.\n' >"$tty"
        sleep 1
        exit 0
      fi
      printf '\n  \033[1mRename %s\033[0m\n\n  New name: ' "$label" >"$tty"
      read -r new_name <"$tty"
      if [ -n "$new_name" ]; then
        case "$SPEC_TYPE" in
          S) tmux rename-session -t "$target" "$new_name" 2>/dev/null ;;
          W) tmux rename-window  -t "$target" "$new_name" 2>/dev/null ;;
        esac
        if [ $? -eq 0 ]; then
          printf '\n  \033[32mRenamed to: %s\033[0m\n' "$new_name" >"$tty"
        else
          printf '\n  \033[31mFailed to rename.\033[0m\n' >"$tty"
        fi
        sleep 0.5
      fi
      ;;

    zoom)
      if [ "$SPEC_TYPE" != "P" ]; then
        printf '\n  Only panes can be zoomed.\n' >"$tty"
        sleep 1
        exit 0
      fi
      tmux resize-pane -Z -t "$target" 2>/dev/null
      if [ $? -eq 0 ]; then
        printf '\n  \033[32mToggled zoom on %s.\033[0m\n' "$label" >"$tty"
      else
        printf '\n  \033[31mFailed to toggle zoom.\033[0m\n' >"$tty"
      fi
      sleep 0.4
      ;;

    detach)
      if [ "$SPEC_TYPE" != "S" ]; then
        printf '\n  Only sessions can be detached.\n' >"$tty"
        sleep 1
        exit 0
      fi
      printf '\n  \033[1mDetach all clients from %s?\033[0m\n\n  Press [y] to confirm: ' "$label" >"$tty"
      read -rsn1 confirm <"$tty"
      echo >"$tty"
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        tmux detach-client -s "$target" 2>/dev/null
        if [ $? -eq 0 ]; then
          printf '\n  \033[32mDetached clients from %s.\033[0m\n' "$label" >"$tty"
        else
          printf '\n  \033[31mFailed to detach.\033[0m\n' >"$tty"
        fi
        sleep 0.5
      fi
      ;;

    send)
      printf '\n  \033[1mSend keys to %s\033[0m\n\n  Command: ' "$label" >"$tty"
      read -r send_cmd <"$tty"
      if [ -n "$send_cmd" ]; then
        tmux send-keys -t "$target" "$send_cmd" Enter 2>/dev/null
        if [ $? -eq 0 ]; then
          printf '\n  \033[32mSent to %s.\033[0m\n' "$label" >"$tty"
        else
          printf '\n  \033[31mFailed to send keys.\033[0m\n' >"$tty"
        fi
        sleep 0.5
      fi
      ;;

    swap)
      printf '\n  \033[1mSwap %s with…\033[0m\n' "$label" >"$tty"
      sleep 0.3

      # Build list of valid swap targets (same type)
      local swap_list
      swap_list=$(bash "$SCRIPT_PATH" --list)

      case "$SPEC_TYPE" in
        W)
          swap_list=$(printf '%s\n' "$swap_list" | grep "^W:")
          ;;
        P)
          swap_list=$(printf '%s\n' "$swap_list" | grep "^P:")
          ;;
        *)
          printf '\n  Only windows and panes can be swapped.\n' >"$tty"
          sleep 1
          exit 0
          ;;
      esac

      [ -z "$swap_list" ] && { printf '\n  No valid swap targets.\n' >"$tty"; sleep 1; exit 0; }

      local dest
      dest=$(printf '%s\n' "$swap_list" | fzf \
        "${FZF_THEME[@]}" \
        --delimiter=$'\t' \
        --with-nth=2 \
        --prompt='swap with ❯ ' \
        --header='Select swap destination (ESC to cancel)' \
      ) || exit 0

      local dest_spec="${dest%%	*}"
      parse_spec "$dest_spec"
      local dest_target
      dest_target=$(spec_target)

      # Re-parse source
      parse_spec "$spec"
      local src_target
      src_target=$(spec_target)

      case "$SPEC_TYPE" in
        W) tmux swap-window -s "$src_target" -t "$dest_target" 2>/dev/null ;;
        P) tmux swap-pane   -s "$src_target" -t "$dest_target" 2>/dev/null ;;
      esac

      if [ $? -eq 0 ]; then
        printf '\n  \033[32mSwapped.\033[0m\n' >"$tty"
      else
        printf '\n  \033[31mSwap failed.\033[0m\n' >"$tty"
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
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  selected=$(bash "$SCRIPT_PATH" --dirs-list | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='new session ❯ ' \
    --header='enter=create  ^f=deep search  ^g=browse into  ^r=reset  esc=cancel' \
    --preview="bash '$SCRIPT_PATH' --dirs-preview {1}" \
    --preview-window="right:40%:wrap" \
    --bind="ctrl-f:reload:bash '$SCRIPT_PATH' --dirs-list --deep {q}" \
    --bind="ctrl-g:reload:bash '$SCRIPT_PATH' --dirs-list --scan {1}" \
    --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --dirs-list)+transform-header(echo 'enter=create  ^f=deep search  ^g=browse into  ^r=reset  esc=cancel')" \
  ) || exit 0

  dir_path="${selected%%	*}"
  dir_path="${dir_path%/}"

  # Record to history
  record_recent_dir "$dir_path"

  session_name=$(basename "$dir_path" | tr '.:' '-')

  # Switch to existing session or create a new one
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
    S) echo "enter=switch  ^x=kill  ^e=rename  ^d=detach  ^o=new  ^/=preview" ;;
    W) echo "enter=switch  ^x=kill  ^e=rename  ^s=swap  ^o=new  ^/=preview" ;;
    P) echo "enter=switch  ^x=kill  ^z=zoom  ^s=swap  ^t=send  ^/=preview" ;;
    *)  echo "enter=switch  ^x=kill  ^e=rename  ^o=new  ^/=preview" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dashboard" ]; then
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  # Popup dimensions for the full-size tools (passed from interdimux.tmux)
  PW="${INTERDIMUX_POPUP_WIDTH:-80%}"
  PH="${INTERDIMUX_POPUP_HEIGHT:-75%}"

  # Re-export env vars for the child popup
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

  # Launch the selected tool in a new full-size popup.
  # Use run-shell -b so the popup command runs asynchronously after
  # the dashboard's popup closes (can't nest popups).
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
# Main
# ---------------------------------------------------------------------------

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
INTERDIMUX_MODE="${INTERDIMUX_MODE:-switch}"

# Base fzf options shared across all modes
fzf_opts=(
  "${FZF_THEME[@]}"
  --delimiter=$'\t'
  --with-nth=2
  --tiebreak=length,begin,index
  --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --list)"
)

# Mode-specific prompt, header, and bindings
case "$INTERDIMUX_MODE" in
  kill)
    fzf_opts+=(
      --prompt='interdimux kill ❯ '
      --header='enter=kill  ctrl-r=reload  esc=quit'
      --bind="enter:execute(bash '$SCRIPT_PATH' --action kill {1})+reload(bash '$SCRIPT_PATH' --list)"
    )
    ;;
  rename)
    fzf_opts+=(
      --prompt='interdimux rename ❯ '
      --header='enter=rename  ctrl-r=reload  esc=quit'
      --bind="enter:execute(bash '$SCRIPT_PATH' --action rename {1})+reload(bash '$SCRIPT_PATH' --list)"
    )
    ;;
  zoom)
    fzf_opts+=(
      --prompt='interdimux zoom ❯ '
      --header='enter=toggle zoom  ctrl-r=reload  esc=quit'
      --bind="enter:execute-silent(bash '$SCRIPT_PATH' --action zoom {1})+reload(bash '$SCRIPT_PATH' --list)"
    )
    ;;
  swap)
    fzf_opts+=(
      --prompt='interdimux swap ❯ '
      --header='enter=swap  ctrl-r=reload  esc=quit'
      --bind="enter:execute(bash '$SCRIPT_PATH' --action swap {1})+reload(bash '$SCRIPT_PATH' --list)"
    )
    ;;
  detach)
    fzf_opts+=(
      --prompt='interdimux detach ❯ '
      --header='enter=detach  ctrl-r=reload  esc=quit'
      --bind="enter:execute(bash '$SCRIPT_PATH' --action detach {1})+reload(bash '$SCRIPT_PATH' --list)"
    )
    ;;
  send)
    fzf_opts+=(
      --prompt='interdimux send ❯ '
      --header='enter=send keys  ctrl-r=reload  esc=quit'
      --bind="enter:execute(bash '$SCRIPT_PATH' --action send {1})+reload(bash '$SCRIPT_PATH' --list)"
    )
    ;;
  *)
    fzf_opts+=(
      --prompt='interdimux ❯ '
      --header='enter=switch  ^x=kill  ^e=rename  ^o=new  ^/=preview'
      --bind="focus:transform-header(bash '$SCRIPT_PATH' --header-for {1})"
      --bind="ctrl-x:execute(bash '$SCRIPT_PATH' --action kill {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-e:execute(bash '$SCRIPT_PATH' --action rename {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-o:execute(bash '$SCRIPT_PATH' --dirs)+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-z:execute-silent(bash '$SCRIPT_PATH' --action zoom {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-s:execute(bash '$SCRIPT_PATH' --action swap {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-d:execute(bash '$SCRIPT_PATH' --action detach {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-t:execute(bash '$SCRIPT_PATH' --action send {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind='ctrl-/:toggle-preview'
    )
    ;;
esac

if [ "${INTERDIMUX_SHOW_PREVIEW:-on}" = "on" ]; then
  fzf_opts+=(
    --preview="bash '$SCRIPT_PATH' --preview {1}"
    --preview-window="right:50%:wrap"
  )
fi

# In kill/rename modes, Enter is bound to execute (not accept),
# so fzf only exits via ESC/ctrl-c — no selection to process.
if [ "$INTERDIMUX_MODE" != "switch" ]; then
  gather_targets | fzf "${fzf_opts[@]}" || true
  exit 0
fi

selection=$(gather_targets | fzf "${fzf_opts[@]}") || exit 0

# ---------------------------------------------------------------------------
# Switch to selected target
# ---------------------------------------------------------------------------

spec="${selection%%	*}"
parse_spec "$spec"
target=$(spec_target)

tmux switch-client -t "$target" 2>/dev/null || \
  tmux display-message "interdimux: $(spec_label) no longer exists"
