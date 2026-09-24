#!/usr/bin/env bash
#
# The shared look: the colour palette, and the fzf theme every picker is built
# on.  Each case here was a dead key or a broken screen, and none of them could
# be seen from the source:
#
#   spellings  - one colour value reaches three sinks that disagree about what
#                they accept.  fzf takes -1 but rejects `default` (and an invalid
#                --color is FATAL: exit 2, nothing drawn); tmux takes `default`
#                but rejects -1 (and silently drops the WHOLE style); and a
#                '#'-plus-six value with a non-hex digit reached $((16#..)),
#                which killed every entry point under set -e -- --doctor too.
#
# Every oracle is tmux's own screen (capture-pane, with -e for colour) or the
# real fzf's exit status -- never the script's own expression.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-theme-test-$$"
OUTER="${SOCK}-outer"
DASH_OUT="${SOCK}-dash-o"
DASH_IN="${SOCK}-dash-i"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-theme.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  local s
  for s in "$SOCK" "$OUTER" "$DASH_OUT" "$DASH_IN"; do
    tmux -L "$s" kill-server 2>/dev/null || true
  done
  rm -rf "$TMPD"
}
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}
skip() { printf '  - %s (skipped: %s)\n' "$1" "$2"; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "interdimux theme tests"
echo

# Nothing here may touch the user's own state: a navigator that dies logs to
# $XDG_STATE_HOME/interdimux/errors.log, which --doctor then reports.
export XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data" XDG_CONFIG_HOME="$TMPD/config"
export XDG_RUNTIME_DIR="$TMPD/run"
mkdir -p "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
unset FZF_DEFAULT_OPTS_FILE
export FZF_DEFAULT_OPTS=""

tmux -f /dev/null -L "$SOCK" new-session -d -s themeproj -x 200 -y 50 -c "$SCRIPT_DIR" 'sleep 900'
tmux -L "$SOCK" new-window -d -t '=themeproj:' -n editor -c "$SCRIPT_DIR" 'sleep 900'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=themeproj:' -F '#{pane_id}' | head -1)"

# The REAL fzf decides what is fatal, so the rendered cases run against it, and
# a flag it does not know is skipped rather than failed.
FZF_REAL=0
_v=$(fzf --version 2>/dev/null || true); _v="${_v%% *}"
IFS=. read -r _maj _min _ <<< "$_v"
if [[ "${_maj:-}" =~ ^[0-9]+$ ]] && [[ "${_min:-}" =~ ^[0-9]+$ ]]; then
  FZF_REAL="$_min"; [ "$_maj" -gt 0 ] && FZF_REAL=999
fi

# =============================================================================
# 1. Spellings: rows and --doctor
# =============================================================================
# INTERDIMUX_NOW pins the clock so two renders can be compared byte for byte.
list() { # env assignments... -> rows on stdout, stderr to $TMPD/err
  env INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_SHOW_DIRS=off INTERDIMUX_NOW=2000000000 "$@" \
    bash "$SCRIPT" --list 2>"$TMPD/err"
}

for renderer in rust bash; do
  use=on; [ "$renderer" = bash ] && use=off
  if [ "$renderer" = rust ] && [ ! -x "$SCRIPT_DIR/rust/target/release/imux" ]; then
    skip "$renderer renderer cases" "rust/target/release/imux not built"
    continue
  fi
  inherit=$(list INTERDIMUX_USE_RUST=$use INTERDIMUX_COLOR_PATH=-1) || inherit=""
  for bad in '#12345g' '#gggggg'; do
    rc=0
    rows=$(list INTERDIMUX_USE_RUST=$use INTERDIMUX_COLOR_PATH="$bad") || rc=$?
    err=$(cat "$TMPD/err")
    if [ "$rc" = 0 ] && [ -z "$err" ] && [[ "$rows" == *themeproj* ]]; then
      report "$renderer: a path colour of '$bad' still lists the sessions" pass
    else
      report "$renderer: a path colour of '$bad' still lists the sessions (rc=$rc)" fail
      ERRORS+="     stderr: ${err:0:160}"$'\n'
    fi
    # An unusable colour means "inherit", in both renderers alike.
    if [ -n "$inherit" ] && [ "$rows" = "$inherit" ]; then
      report "$renderer: '$bad' renders exactly like -1 (inherit)" pass
    else
      report "$renderer: '$bad' renders exactly like -1 (inherit)" fail
    fi
  done
done

# The same typo arriving as a tmux option -- the way a user sets it -- and
# --doctor, whose whole job is to explain it, has to live long enough to.
tmux -L "$SOCK" set -g @interdimux-color-path '#12345g'
rc=0
doc=$(env -u INTERDIMUX_OPTS_PRIMED bash "$SCRIPT" --doctor 2>"$TMPD/err" | plain) || rc=$?
err=$(cat "$TMPD/err")
if [[ "$doc" == *"interdimux doctor"* ]] && [[ "$doc" == *"@interdimux-color-path"* ]] \
   && [[ "$err" != *"value too great"* ]] && [[ "$err" != *"unbound variable"* ]]; then
  report "--doctor survives @interdimux-color-path '#12345g' and reaches the option" pass
else
  report "--doctor survives @interdimux-color-path '#12345g' and reaches the option" fail
  ERRORS+="     stderr: ${err:0:160}"$'\n'
fi
rows=$(env -u INTERDIMUX_OPTS_PRIMED INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null) || rows=""
[[ "$rows" == *themeproj* ]] \
  && report "--list survives the same typo set as a tmux option" pass \
  || report "--list survives the same typo set as a tmux option" fail
tmux -L "$SOCK" set -gu @interdimux-color-path

# =============================================================================
# 2. Spellings: the navigator, rendered
# =============================================================================
# The pane runs the navigator and then prints how it exited, so "it died" and
# "it is slow" are told apart without a fixed sleep.
launch() { # $1 = cols, $2 = rows, rest = NAME=value exports for the navigator
  local cols="$1" rows="$2"; shift 2
  local sh="$TMPD/launch.sh" e n v
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  rm -f "$XDG_STATE_HOME/interdimux/errors.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export TMUX=%q TMUX_PANE=%q\n' "$TMUX" "$TMUX_PANE"
    printf 'export XDG_STATE_HOME=%q XDG_DATA_HOME=%q XDG_CONFIG_HOME=%q XDG_RUNTIME_DIR=%q\n' \
      "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
    printf 'export LANG=C.UTF-8 LC_ALL=C.UTF-8\n'
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307\n'
    printf 'export INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off FZF_DEFAULT_OPTS=\n'
    printf 'unset FZF_DEFAULT_OPTS_FILE INTERDIMUX_FZF_MINOR\n'
    for e in "$@"; do n="${e%%=*}"; v="${e#*=}"; printf 'export %s=%q\n' "$n" "$v"; done
    printf 'bash %q; echo "NAV-EXITED=$?"\n' "$SCRIPT"
  } > "$sh"
  chmod +x "$sh"
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x "$cols" -y "$rows" "$sh; sleep 60"
}
screen()   { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain || true; }
screen_e() { tmux -L "$OUTER" capture-pane -t '=drv:' -p -e 2>/dev/null || true; }
# Poll until the capture matches $1 (an ERE); fail fast once the navigator exited.
wait_for() { # $1 = ERE, $2 = tenths of a second (default 150)
  local i s
  for (( i = 0; i < ${2:-150}; i++ )); do
    s=$(screen)
    [[ "$s" =~ $1 ]] && return 0
    [[ "$s" == *NAV-EXITED* ]] && return 1
    sleep 0.1
  done
  return 1
}
why_dead() {
  local log="$XDG_STATE_HOME/interdimux/errors.log" s
  s=$(screen); s="${s%%$'\n'*}"
  ERRORS+="     first line: ${s:0:100}"$'\n'
  if [ -s "$log" ]; then ERRORS+="$(sed 's/^/     errors.log: /' "$log" || true)"$'\n'; fi
  return 0
}

# `default` is what README and --doctor both call valid; the others are the
# typos a hand-edited theme produces.  Each one alone was fatal to fzf.
launch 120 20 \
  INTERDIMUX_COLOR_ACCENT=default INTERDIMUX_COLOR_CURRENT_BG=default \
  INTERDIMUX_COLOR_PATH=default INTERDIMUX_COLOR_BORDER=default \
  INTERDIMUX_COLOR_HEADER=default INTERDIMUX_COLOR_QUERY=default
if wait_for 'themeproj'; then
  report "the navigator draws with every fzf-facing colour set to 'default'" pass
else
  report "the navigator draws with every fzf-facing colour set to 'default'" fail; why_dead
fi

launch 120 20 \
  INTERDIMUX_COLOR_ACCENT='#gggggg' INTERDIMUX_COLOR_PATH='#12345g' \
  INTERDIMUX_COLOR_BORDER='#abc' INTERDIMUX_COLOR_HEADER=300 \
  INTERDIMUX_COLOR_CURRENT_BG=colour173
if wait_for 'themeproj'; then
  report "the navigator draws with typo'd colours (#12345g, #abc, 300, colour173)" pass
else
  report "the navigator draws with typo'd colours (#12345g, #abc, 300, colour173)" fail; why_dead
fi

# =============================================================================
# 3. Spellings: the tmux sink, where inherit is `default`, never -1
# =============================================================================
# The dashboard menu's selected row is styled `-H bg=<accent>,fg=<menu-sel-fg>`.
# tmux rejects `-1` and then drops the WHOLE style, so the configured
# menu-sel-fg (235) vanished along with it and the row fell back to tmux's
# stock black-on-yellow.  display-menu needs an attached client, hence a nested
# pair of servers; the key press selects the second item.
dash_row() { # env... -> the selected menu row, escapes kept
  local i s
  tmux -L "$DASH_IN" kill-server 2>/dev/null || true
  tmux -L "$DASH_OUT" kill-server 2>/dev/null || true
  tmux -f /dev/null -L "$DASH_OUT" new-session -d -s drv -x 90 -y 30 \
    "tmux -f /dev/null -L '$DASH_IN' new-session -s host"
  for i in $(seq 1 100); do
    s=$(tmux -L "$DASH_IN" list-clients 2>/dev/null || true)
    [ -n "$s" ] && break
    sleep 0.1
  done
  env -u TMUX_PANE TMUX="$(tmux -L "$DASH_IN" display-message -p '#{socket_path}'),99999,0" \
      INTERDIMUX_OPTS_PRIMED=1 "$@" bash "$SCRIPT" --dashboard-launch >/dev/null 2>&1 &
  for i in $(seq 1 100); do
    s=$(tmux -L "$DASH_OUT" capture-pane -t '=drv:' -p 2>/dev/null || true)
    [[ "$s" == *"New session"* ]] && break
    sleep 0.1
  done
  tmux -L "$DASH_OUT" send-keys -t '=drv:' Down
  # poll until the highlight has moved onto "New session" (it is the row that
  # carries an SGR right before its label)
  for i in $(seq 1 50); do
    s=$(tmux -L "$DASH_OUT" capture-pane -t '=drv:' -p -e 2>/dev/null | grep -a 'New session' || true)
    [[ "$s" == *$'\033['*'m New session'* ]] && break
    sleep 0.1
  done
  tmux -L "$DASH_IN" kill-server 2>/dev/null || true
  tmux -L "$DASH_OUT" kill-server 2>/dev/null || true
  wait 2>/dev/null || true
  printf '%s' "$s"
}
for acc in -1 default; do
  row=$(dash_row INTERDIMUX_COLOR_ACCENT="$acc" INTERDIMUX_COLOR_MENU_SEL_FG=235)
  if [[ "$row" == *'38;5;235'* ]]; then
    report "accent '$acc': the menu's selection style survives (menu-sel-fg 235 drawn)" pass
  elif [ -z "$row" ]; then
    report "accent '$acc': the dashboard menu was captured" fail
  else
    report "accent '$acc': the menu's selection style survives (got $(printf '%s' "$row" | cat -v | head -c 60))" fail
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi

