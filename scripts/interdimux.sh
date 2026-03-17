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

      wpath="${wpath/#$HOME/\~}"
      wpath=$(trim_path "$wpath" 22)

      local branch="├─"
      [ "$wi" -eq "$win_count" ] && branch="└─"

      local cmd_display
      cmd_display=$(resolve_command "$wcmd" "$wpid")

      local padded_id padded_path
      padded_id=$(dpad "$widx:$wname" 14)
      padded_path=$(dpad "$wpath" 22)

      printf 'W:%s:%s\t  %s %s %s %s %s%s%s %s %s%s%s\n' \
        "$sname" "$widx" \
        "$branch" "$wmarker" "$padded_id" \
        "$SEP" "$DIM_PATH" "$padded_path" "$RST" \
        "$SEP" "$DIM_CMD" "$cmd_display" "$RST"

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

          ppath="${ppath/#$HOME/\~}"
          ppath=$(trim_path "$ppath" 22)

          local pbranch="├─"
          [ "$pi" -eq "$pane_count" ] && pbranch="└─"

          local cmd_display
          cmd_display=$(resolve_command "$pcmd" "$ppid")

          local padded_id padded_path
          padded_id=$(dpad ".$pidx" 11)
          padded_path=$(dpad "$ppath" 22)

          printf 'P:%s:%s:%s\t  %s%s %s %s %s %s%s%s %s %s%s%s\n' \
            "$sname" "$widx" "$pidx" \
            "$cont" "$pbranch" "$pmarker" "$padded_id" \
            "$SEP" "$DIM_PATH" "$padded_path" "$RST" \
            "$SEP" "$DIM_CMD" "$cmd_display" "$RST"
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
  tmux capture-pane -t "$target" -p -e -S -50 2>/dev/null || echo "(cannot capture pane)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Actions (called by fzf keybindings via execute)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--action" ]; then
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
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# New session from directory (ctrl-o)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dirs" ]; then
  set +e
  project_dirs="${INTERDIMUX_PROJECT_DIRS:-$(tmux show-option -gqv @interdimux-project-dirs 2>/dev/null)}"

  # Pick the fastest available directory finder
  if command -v fd >/dev/null 2>&1; then
    finder="fd"
  elif command -v fdfind >/dev/null 2>&1; then
    finder="fdfind"
  elif command -v find >/dev/null 2>&1; then
    finder="find"
  else
    echo "interdimux: no directory finder (fd/find) available" >&2
    exit 1
  fi

  # Determine search roots
  search_paths=()
  if [ -n "${project_dirs:-}" ]; then
    IFS=':' read -ra search_paths <<< "$project_dirs"
  else
    for d in "$HOME/projects" "$HOME/code" "$HOME/src" "$HOME/repos" "$HOME/work" "$HOME/dev"; do
      [ -d "$d" ] && search_paths+=("$d")
    done
    [ ${#search_paths[@]} -eq 0 ] && search_paths=("$HOME")
  fi

  # Collect directories
  dir_list=""
  for sp in "${search_paths[@]}"; do
    [ -d "$sp" ] || continue
    case "$finder" in
      fd|fdfind)
        dir_list+=$("$finder" --type d --max-depth 3 --absolute-path . "$sp" 2>/dev/null || true)$'\n'
        ;;
      find)
        dir_list+=$(find "$sp" -maxdepth 3 -type d -not -path '*/.*' 2>/dev/null || true)$'\n'
        ;;
    esac
    dir_list+="${sp}"$'\n'
  done

  dir_list=$(printf '%s' "$dir_list" | sed '/^$/d' | sort -u)
  [ -z "$dir_list" ] && { echo "No directories found"; exit 1; }

  selected=$(printf '%s\n' "$dir_list" | \
    fzf "${FZF_THEME[@]}" \
      --prompt='interdimux new session ❯ ' \
      --header='Select directory (ESC to cancel)' \
      --preview="ls -la --color=always {} 2>/dev/null || ls -la {} 2>/dev/null | head -30" \
      --preview-window="right:40%:wrap" \
  ) || exit 0

  dir_path="$selected"
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
# Dashboard
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--dashboard" ]; then
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  items=$(printf '%s\t  \033[1;38;5;173m%-16s\033[0m \033[2m%s\033[0m\n' \
    "switch" "Switch"      "Navigate & jump to target" \
    "new"    "New Session"  "Create session from directory" \
    "rename" "Rename"       "Rename a session or window" \
    "kill"   "Kill"         "Remove sessions, windows, or panes")

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
  case "$action" in
    switch) exec bash "$SCRIPT_PATH" ;;
    new)    exec bash "$SCRIPT_PATH" --dirs ;;
    rename) INTERDIMUX_MODE=rename exec bash "$SCRIPT_PATH" ;;
    kill)   INTERDIMUX_MODE=kill   exec bash "$SCRIPT_PATH" ;;
  esac
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
  *)
    fzf_opts+=(
      --prompt='interdimux ❯ '
      --header='enter=switch  ctrl-x=kill  ctrl-e=rename  ctrl-o=new session  ctrl-r=reload'
      --bind="ctrl-x:execute(bash '$SCRIPT_PATH' --action kill {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-e:execute(bash '$SCRIPT_PATH' --action rename {1})+reload(bash '$SCRIPT_PATH' --list)"
      --bind="ctrl-o:execute(bash '$SCRIPT_PATH' --dirs)+reload(bash '$SCRIPT_PATH' --list)"
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
