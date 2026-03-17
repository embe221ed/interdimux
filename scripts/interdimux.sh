#!/usr/bin/env bash
#
# interdimux — fuzzy tmux navigator
#
# Gathers sessions, windows, and panes into a tree-structured fzf list
# and switches to the selected target.

set -euo pipefail

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

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

RST=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
CYAN=$'\033[36m'
DIM_SEP=$'\033[2;37m'  # dim white for separator
DIM_PATH=$'\033[2;33m' # dim yellow for path
DIM_CMD=$'\033[0;36m'  # cyan for command
MARKER_COLOR=$'\033[1;32m' # bold green for *

# Column separator (dim pipe)
SEP="${DIM_SEP}│${RST}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Get full command line for a pane by walking the process tree
# from the shell pid down to the leaf (the actual foreground command).
full_command() {
  local pid="$1"
  local child
  while true; do
    child=$(pgrep -P "$pid" 2>/dev/null | head -1)
    [ -z "$child" ] && break
    pid="$child"
  done
  ps -o args= -p "$pid" 2>/dev/null || echo ""
}

# Resolve the command string to display for a pane.
# When full command is enabled, walks the process tree.
# Otherwise, uses the short command name from tmux.
resolve_command() {
  local short_cmd="$1" pid="$2"
  if [ "$SHOW_FULL_COMMAND" = "on" ]; then
    local fcmd
    fcmd=$(full_command "$pid")
    fcmd="${fcmd#"${fcmd%%[![:space:]]*}"}"
    fcmd="${fcmd%"${fcmd##*[![:space:]]}"}"
    if [ -n "$fcmd" ]; then
      printf '%s' "$fcmd"
    else
      printf '%s' "$short_cmd"
    fi
  else
    printf '%s' "$short_cmd"
  fi
}

# Pad a string to a target display width using character count
# (correct for multibyte UTF-8 like …, ├, │).
# printf %-Ns counts bytes, which breaks with multibyte chars.
dpad() {
  local str="$1" width="$2"
  local display_len=${#str}
  printf '%s' "$str"
  local pad=$((width - display_len))
  [ "$pad" -gt 0 ] && printf '%*s' "$pad" ""
}

# Trim a path to fit within max_width display columns.
# Keeps the leading ~ or / and the rightmost path components,
# replacing omitted middle parts with "…".
#   trim_path "~/very/deep/nested/project/src" 20
#   → "~/…/project/src"
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
      # Last (or only) component
      if [ -z "$result" ]; then
        result="$component"
      else
        local candidate="$component/$result"
        if [ "${#candidate}" -le "$budget" ]; then
          result="$candidate"
        fi
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
# SPEC encodes the tmux target for reliable parsing:
#   S:session_name
#   W:session_name:window_index
#   P:session_name:window_index:pane_index
#
# Display columns for windows and panes are aligned:
#
#   Window: "  BR M IDENTITY       PATH                  COMMAND"
#   Pane:   "  CO BR M IDENTITY    PATH                  COMMAND"
#
#   BR = ├─ or └─  (2 display cols)
#   CO = │  or     (3 display cols, aligns │ under ├/└)
#   M  = * or      (1 display col)
#
#   IDENTITY is padded to 14 (window) or 11 (pane) chars so that
#   PATH starts at display column 21 for both levels.

gather_targets() {
  local current_session current_window current_pane
  current_session=$(tmux display-message -p '#S')
  current_window=$(tmux display-message -p '#I')
  current_pane=$(tmux display-message -p '#P')

  # Collect all data in bulk to minimise tmux round-trips
  local all_windows all_panes
  all_windows=$(tmux list-windows -a \
    -F '#{session_name}|#{window_index}|#{window_name}|#{window_active}|#{pane_current_command}|#{pane_current_path}|#{window_panes}|#{pane_pid}')
  all_panes=$(tmux list-panes -a \
    -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_active}|#{pane_current_command}|#{pane_current_path}|#{pane_pid}|#{window_panes}')

  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}|#{session_windows}|#{?session_attached,attached,}')

  echo "$sessions" | while IFS='|' read -r sname swins sattach; do
    # --- Session line ---
    local marker=" "
    [ "$sname" = "$current_session" ] && marker="${MARKER_COLOR}*${RST}"

    local flags=""
    [ -n "$sattach" ] && flags=" ${DIM}[a]${RST}"

    printf 'S:%s\t%s▸%s %s %s%s  %s(%s wins)%s%s\n' \
      "$sname" "$BOLD" "$RST" "$marker" "$BOLD" "$sname" "$DIM" "$swins" "$RST" "$flags"

    # --- Windows for this session ---
    local session_windows
    session_windows=$(echo "$all_windows" | grep "^${sname}|" || true)
    [ -z "$session_windows" ] && continue

    local win_count
    win_count=$(echo "$session_windows" | wc -l | tr -d ' ')
    local wi=0

    echo "$session_windows" | while IFS='|' read -r _sn widx wname _wact wcmd wpath wpanes wpid; do
      wi=$((wi + 1))

      local wmarker=" "
      [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && wmarker="${MARKER_COLOR}*${RST}"

      wpath="${wpath/#$HOME/\~}"
      wpath=$(trim_path "$wpath" 22)

      local branch="├─"
      [ "$wi" -eq "$win_count" ] && branch="└─"

      local cmd_display
      cmd_display=$(resolve_command "$wcmd" "$wpid")

      # Prefix:   2 + 2(branch) + 1 + 1(marker) + 1 = 7 cols
      # Identity: 14 cols → path starts at col 21
      # Path:     22 cols → command starts at col 43
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
        local window_panes
        window_panes=$(echo "$all_panes" | grep "^${sname}|${widx}|" || true)
        [ -z "$window_panes" ] && continue

        local pane_count
        pane_count=$(echo "$window_panes" | wc -l | tr -d ' ')
        local pi=0

        # Continuation: 3 display cols, │ aligns under ├/└
        local cont="│  "
        [ "$wi" -eq "$win_count" ] && cont="   "

        echo "$window_panes" | while IFS='|' read -r _sn2 _widx2 pidx _pact pcmd ppath ppid _wp2; do
          pi=$((pi + 1))

          local pmarker=" "
          [ "$sname" = "$current_session" ] && [ "$widx" = "$current_window" ] && [ "$pidx" = "$current_pane" ] && pmarker="${MARKER_COLOR}*${RST}"

          ppath="${ppath/#$HOME/\~}"
          ppath=$(trim_path "$ppath" 22)

          local pbranch="├─"
          [ "$pi" -eq "$pane_count" ] && pbranch="└─"

          local cmd_display
          cmd_display=$(resolve_command "$pcmd" "$ppid")

          # Prefix:   2 + 3(cont) + 2(branch) + 1 + 1(marker) + 1 = 10 cols
          # Identity: 11 cols → path starts at col 21
          # Path:     22 cols → command starts at col 43
          local padded_id padded_path
          padded_id=$(dpad ".$pidx" 11)
          padded_path=$(dpad "$ppath" 22)

          printf 'P:%s:%s:%s\t  %s%s %s %s %s %s%s%s %s %s%s%s\n' \
            "$sname" "$widx" "$pidx" \
            "$cont" "$pbranch" "$pmarker" "$padded_id" \
            "$SEP" "$DIM_PATH" "$padded_path" "$RST" \
            "$SEP" "$DIM_CMD" "$cmd_display" "$RST"
        done
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# Preview command (called by fzf --preview)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--preview" ]; then
  line="$2"

  # The target spec is everything before the first tab
  spec="${line%%	*}"

  IFS=':' read -r type f1 f2 f3 <<< "$spec"

  case "$type" in
    S)
      target="${f1}"
      ;;
    W)
      target="${f1}:${f2}"
      ;;
    P)
      target="${f1}:${f2}.${f3}"
      ;;
    *)
      echo "Unknown target type: $type"
      exit 1
      ;;
  esac

  # -S -50: grab scrollback so inactive panes show content
  tmux capture-pane -t "$target" -p -e -S -50 2>/dev/null || echo "(cannot capture pane)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

fzf_opts=(
  --ansi
  --reverse
  --delimiter=$'\t'
  --with-nth=2
  --tiebreak=length,begin,index
  --prompt="interdimux> "
  --header="*=current  [a]=attached  ctrl-r=reload"
  --bind="ctrl-r:reload(bash '$SCRIPT_PATH')"
)

if [ "${INTERDIMUX_SHOW_PREVIEW:-on}" = "on" ]; then
  fzf_opts+=(
    --preview="bash '$SCRIPT_PATH' --preview {}"
    --preview-window="right:50%:wrap"
  )
fi

selection=$(gather_targets | fzf "${fzf_opts[@]}") || exit 0

# ---------------------------------------------------------------------------
# Switch to selected target
# ---------------------------------------------------------------------------

spec="${selection%%	*}"
IFS=':' read -r type f1 f2 f3 <<< "$spec"

case "$type" in
  S)
    tmux switch-client -t "$f1"
    ;;
  W)
    tmux switch-client -t "${f1}:${f2}"
    ;;
  P)
    tmux switch-client -t "${f1}:${f2}.${f3}"
    ;;
esac
