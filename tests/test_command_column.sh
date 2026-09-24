#!/usr/bin/env bash
#
# How the COMMAND column renders a resolved command, in BOTH renderers.
#
# test_full_command.sh owns WHICH process the column names; this suite owns
# what that command then looks like on the row:
#
#   argv0 basename   `/usr/bin/sleep 998` spends a third of a narrow column on
#                    `/usr/bin/`; argv0 is shown by its basename.  A script run
#                    through its shebang reads `sh tool.sh`, not
#                    `/bin/sh /tmp/…/tool.sh` (review UX-02).
#   idle shells      a shell with nothing but options (`-zsh`, `/bin/bash`,
#                    `bash --norc -i`) is its bare name in the TREE colour, so
#                    the rows doing real work are the ones in the accent; a
#                    shell running something keeps the accent (review UX-01).
#
# Assertions are on the exact bytes of the field, colours included, against
# escapes written out here from the SGR spec for two deliberately unusual
# palette values — never against the script's own palette helpers.
#
# Most panes are `exec -a NAME cat FIFO`: a process with an arbitrary argv0 and
# path arguments that blocks forever (open() of a FIFO waits for a writer; a
# bare cat reads the pane tty).  `grep -fFIFO` and `find DIR/ … -exec cat FIFO`
# block the same way while carrying an option with a '/' in it and a first
# argument with no basename.  That reaches the edge cases of the formatting
# rules through a real pane, in both renderers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-cmdcol-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-cmdcol.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

# -f /dev/null: keep the test server hermetic (see test_list_format.sh)
tmux_cmd() { tmux -f /dev/null -L "$SOCK" "$@"; }

echo "interdimux command column tests"
echo

# 208 and 66 appear nowhere else in a row, so a match can only be the command.
ACCENT=$'\033[38;5;208m'
TREE=$'\033[38;5;66m'
RST=$'\033[0m'
export INTERDIMUX_COLOR_ACCENT=208 INTERDIMUX_COLOR_TREE=66

SLEEP_BIN="$(command -v sleep)"
printf '#!/bin/sh\nread -r _\n' > "$TMPD/tool.sh"    # a builtin wait: no child
chmod +x "$TMPD/tool.sh"
FIFO="$TMPD/in.fifo"
mkfifo "$FIFO"

# Every pane EXECs its command, so the pane pid is the process under test.
tmux_cmd new-session -d -s t -x 200 -y 40 -c "$TMPD" "exec '$SLEEP_BIN' 998"
tmux_cmd rename-window -t '=t:0' abs
tmux_cmd new-window -d -t '=t:' -n script -c "$TMPD" "exec '$TMPD/tool.sh'"

# window name | argv0 | the real program and its arguments, as bash source |
# the rest of the argv as ps will then show it
CRAFTED=(
  "noslash|a/|cat '$FIFO'|$FIFO"
  "pyver|/opt/py/bin/python3.12|cat '$FIFO'|$FIFO"
  "nodeopt|/usr/local/bin/node|cat -u '$FIFO'|-u $FIFO"
  "notinterp|/usr/bin/pythonx|cat '$FIFO'|$FIFO"
  "optslash|perl|grep '-f$FIFO'|-f$FIFO"
  "dirarg|ruby|find '$TMPD/' -maxdepth 0 -exec cat '$FIFO' ';'|$TMPD/ -maxdepth 0 -exec cat $FIFO ;"
  "loginsh|-zsh|cat|"
  "pathsh|/bin/bash|cat|"
  "optsh|-bash|cat -u|-u"
  "worksh|bash|cat '$FIFO'|$FIFO"
)
# A real interactive shell with only options, one busy with a foreground job.
tmux_cmd new-window -d -t '=t:' -n idle -c "$TMPD" 'exec bash --norc --noprofile -i'
tmux_cmd new-window -d -t '=t:' -n busy -c "$TMPD" 'exec bash --norc --noprofile -i'
tmux_cmd send-keys -t '=t:busy' 'sleep 997' Enter

for _row in "${CRAFTED[@]}"; do
  IFS='|' read -r _name _argv0 _prog _ <<< "$_row"
  printf '#!/usr/bin/env bash\nexec -a %q %s\n' "$_argv0" "$_prog" > "$TMPD/launch_$_name"
  chmod +x "$TMPD/launch_$_name"
  tmux_cmd new-window -d -t '=t:' -n "$_name" -c "$TMPD" "exec '$TMPD/launch_$_name'"
done

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=index INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off

# Settled when the KERNEL shows each pane's final argv, not when the output
# under test does.  ps rather than /proc, so this holds off Linux too.
argv_of() {  # window name -> argv of its pane process
  local pid
  pid=$(tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_pid}')
  ps -o args= -p "$pid" 2>/dev/null || :
}
children_of() {  # window name -> argv of each direct child of its pane process
  local pid
  pid=$(tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_pid}')
  ps -eo ppid=,args= | awk -v p="$pid" '$1 == p { $1 = ""; sub(/^ /, ""); print }'
}
settled() {
  local row name argv0 args
  [ "$(argv_of abs)" = "$SLEEP_BIN 998" ] || return 1
  case "$(argv_of script)" in */sh\ "$TMPD/tool.sh") ;; *) return 1 ;; esac
  for row in "${CRAFTED[@]}"; do
    IFS='|' read -r name argv0 _ args <<< "$row"
    [ "$(argv_of "$name")" = "$argv0${args:+ $args}" ] || return 1
  done
  [ "$(argv_of idle)" = "bash --norc --noprofile -i" ] || return 1
  [ -z "$(children_of idle)" ] || return 1
  [ "$(children_of busy)" = "sleep 997" ] || return 1
}
for _i in $(seq 1 200); do settled && break; sleep 0.1; done
settled || echo "  (warning: panes did not settle)" >&2

cmd_in() {  # list output, window name -> that window's COMMAND field, raw bytes
  local idx
  idx=$(tmux -L "$SOCK" list-windows -t '=t:' -F '#{window_index} #{window_name}' \
        | awk -v n="$2" '$2 == n {print $1; exit}')
  printf '%s\n' "$1" | awk -F'\t' -v spec="W:t:$idx" '$4 == spec {print $3; exit}'
}
vis() { printf '%s' "$1" | cat -v; }
expect() {  # label, got, want
  if [ "$2" = "$3" ]; then
    report "$1" pass
  else
    report "$1 (got '$(vis "$2")', want '$(vis "$3")')" fail
  fi
}

if [ -x "$SCRIPT_DIR/rust/target/release/imux" ]; then first="rust renderer"; else first="default renderer (no binary built)"; fi
for cfg in "$first:" "bash renderer:INTERDIMUX_USE_RUST=off"; do
  label="${cfg%%:*}"
  # shellcheck disable=SC2086
  out=$(env ${cfg#*:} bash "$SCRIPT" --list 2>/dev/null)

  # --- argv0 by its basename (UX-02) -----------------------------------------
  case "$SLEEP_BIN" in
    /*) expect "$label: an absolute argv0 is shown by its basename" \
          "$(cmd_in "$out" abs)" "${ACCENT}sleep 998${RST}" ;;
    *)  echo "  (skipped the absolute-argv0 case: sleep is not an external command here)" ;;
  esac
  expect "$label: a shebang script reads as interpreter + script name" \
    "$(cmd_in "$out" script)" "${ACCENT}sh tool.sh${RST}"
  expect "$label: an argv0 with no basename is kept whole" \
    "$(cmd_in "$out" noslash)" "${ACCENT}a/ $FIFO${RST}"
  expect "$label: a versioned interpreter's script is basenamed" \
    "$(cmd_in "$out" pyver)" "${ACCENT}python3.12 in.fifo${RST}"
  expect "$label: an option before the script leaves the arguments alone" \
    "$(cmd_in "$out" nodeopt)" "${ACCENT}node -u $FIFO${RST}"
  expect "$label: a non-interpreter's arguments are left alone" \
    "$(cmd_in "$out" notinterp)" "${ACCENT}pythonx $FIFO${RST}"
  expect "$label: an option carrying a path is not taken for the script" \
    "$(cmd_in "$out" optslash)" "${ACCENT}perl -f$FIFO${RST}"
  expect "$label: a first argument with no basename is kept whole" \
    "$(cmd_in "$out" dirarg)" "${ACCENT}ruby $TMPD/ -maxdepth 0 -exec cat $FIFO ;${RST}"

  # --- idle shells in the tree colour (UX-01) ----------------------------------
  expect "$label: a login shell is its bare name, dimmed" \
    "$(cmd_in "$out" loginsh)" "${TREE}zsh${RST}"
  expect "$label: a path-qualified shell is its bare name, dimmed" \
    "$(cmd_in "$out" pathsh)" "${TREE}bash${RST}"
  expect "$label: a shell with only options is still idle" \
    "$(cmd_in "$out" optsh)" "${TREE}bash${RST}"
  expect "$label: an interactive shell at its prompt is dimmed" \
    "$(cmd_in "$out" idle)" "${TREE}bash${RST}"
  expect "$label: the command a shell is running keeps the accent" \
    "$(cmd_in "$out" busy)" "${ACCENT}sleep 997${RST}"
  expect "$label: a shell running a script keeps the accent" \
    "$(cmd_in "$out" worksh)" "${ACCENT}bash in.fifo${RST}"

  # tmux's own short name, when full-command resolution is off
  # shellcheck disable=SC2086
  out=$(env ${cfg#*:} INTERDIMUX_SHOW_FULL_COMMAND=off bash "$SCRIPT" --list 2>/dev/null)
  expect "$label, full command off: tmux's short name for a shell is dimmed" \
    "$(cmd_in "$out" idle)" "${TREE}bash${RST}"
  expect "$label, full command off: a running command keeps the accent" \
    "$(cmd_in "$out" busy)" "${ACCENT}sleep${RST}"
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
