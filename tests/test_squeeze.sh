#!/usr/bin/env bash
#
# The width squeeze: what gives way when a row does not fit the popup.
#
# The order used to be: the session prefix first, then the git badge (and the
# Z/!/# flags, which lived inside it), then the path.  Both halves were wrong.
#
#   * fzf matches the identity column AS DISPLAYED, so once the prefix read
#     `my-pr…` the query `my-project shell` matched nothing — on an 80-column
#     popup, with a perfectly ordinary name (review BUG-02).  In raw mode, Enter
#     on that empty result then ran find-or-create with the query split into
#     words, creating `zzz` while the bar promised `zzz-shell`.
#   * one 39-cell path anywhere in the tree zeroed the badge, and the flags with
#     it, on EVERY row of a 96-column popup, without the path giving up a single
#     cell first (review BUG-24).
#
# Oracles: fzf itself for matching (the real matcher, given the navigator's own
# --delimiter/--with-nth/--nth), the rendered rows for what is on screen, and
# tmux's grid (#{cursor_x}) for where a glyph lands.  Both renderers, always:
# the bash one is what a TPM install without cargo runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-squeeze-test-$$"
PROBE="${SOCK}-probe"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-squeeze.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$PROBE" kill-server 2>/dev/null || true
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
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
# Poll for a condition instead of sleeping a fixed time: $1 = tries (x0.1 s),
# rest = the command that must succeed.
until_ok() {
  local n="$1" i; shift
  for i in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux width squeeze tests"
echo

# --- bench --------------------------------------------------------------------
# HOME is pointed into the bench so the paths tildify the way a user's do
# (~/work/my-project), instead of the long scratch path a test would otherwise
# carry on every row.
H="$TMPD/home"
mkdir -p "$H/work/my-project" "$H/s" "$H/proj-a/.git" "$H/proj-b/.git" \
         "$H/work/some/deeper/path/epsilon-project" "$TMPD/data"
printf 'ref: refs/heads/feature/x\n' > "$H/proj-a/.git/HEAD"
printf 'ref: refs/heads/main\n'      > "$H/proj-b/.git/HEAD"

PC='bash --norc --noprofile -c "sleep 99999 & wait"'
tmux -f /dev/null -L "$SOCK" new-session -d -s my-project -n editor -x 200 -y 50 \
  -c "$H/work/my-project" "$PC"
tmux -L "$SOCK" set -g default-command 'bash --norc --noprofile -i'
tmux -L "$SOCK" new-window -d -t '=my-project:' -n shell -c "$H/work/my-project" "$PC"
tmux -L "$SOCK" new-session -d -s other-session -x 200 -y 50 -c "$H/s" "$PC"
# api: a zoomed two-pane window on branch feature/x, a window that rang the
# bell and one with bell AND activity, both on branch main (a different
# length, so a flag trailing the branch would land at a different x)
tmux -L "$SOCK" new-session -d -s api -n server -x 200 -y 50 -c "$H/proj-a" "$PC"
tmux -L "$SOCK" split-window -d -t '=api:server' -c "$H/proj-a" "$PC"
tmux -L "$SOCK" resize-pane -Z -t '=api:server.0'
tmux -L "$SOCK" new-window -d -t '=api:' -n ding -c "$H/proj-b" \
  "sh -c 'sleep 0.3; printf \"\\a\"; exec sleep 99999'"
tmux -L "$SOCK" new-window -d -t '=api:' -n noisy -c "$H/proj-b" \
  "sh -c 'sleep 0.5; printf \"x\\a\"; exec sleep 99999'"
tmux -L "$SOCK" set-option -w -t '=api:noisy' monitor-activity on
# the one long path: 39 cells once tildified
tmux -L "$SOCK" new-session -d -s eps -x 200 -y 50 \
  -c "$H/work/some/deeper/path/epsilon-project" "$PC"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=other-session:0' -F '#{pane_id}' | head -1)"
export HOME="$H" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on
export INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_NOW="$(date +%s)"
export FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE=''

# tmux reports a pane before it reports that pane's cwd, and the flags only
# once the bell has rung — wait for exactly what the rows are built from.
bench_ready() {
  local paths flags
  paths=$(tmux -L "$SOCK" list-panes -a -F '#{pane_current_path}' 2>/dev/null)
  [ "$(printf '%s\n' "$paths" | grep -c "^$H/")" -ge 8 ] || return 1
  flags=$(tmux -L "$SOCK" list-windows -t '=api:' \
            -F '#{window_name}=#{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag}')
  [[ "$flags" == *server=100* && "$flags" == *ding=010* && "$flags" == *noisy=011* ]]
}
if until_ok 100 bench_ready; then
  report "bench built (paths reported, Z / ! / !# flags set)" pass
else
  report "bench built (paths reported, Z / ! / !# flags set)" fail
  ERRORS+="     $(tmux -L "$SOCK" list-windows -a -F '#S:#W #{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag} #{pane_current_path}' | tr '\n' '|')"$'\n'
fi

RENDERERS="bash"
if [ -x "$BIN" ]; then
  RENDERERS="rust bash"
else
  echo "  (rust binary not built: only the bash renderer is exercised)"
fi
list() { # $1 = renderer, $2 = FZF_COLUMNS, rest = extra env
  local r="$1" c="$2"; shift 2
  if [ "$r" = bash ]; then set -- INTERDIMUX_USE_RUST=off "$@"; fi
  env "$@" FZF_COLUMNS="$c" bash "$SCRIPT" --list 2>/dev/null
}
# field 2 (the context column) of the row whose spec is $2, colour stripped
ctx_of() { printf '%s\n' "$1" | plain | awk -F'\t' -v s="$2" '$4 == s { print $2 }'; }

# --- 1. compound queries match at ordinary popup widths (BUG-02) --------------
# The navigator's own matching options.  Before: 64, 72 and 80 matched nothing
# (the prefix read `my-proj…` / `my-pr…`).
for r in $RENDERERS; do
  for w in 64 72 80; do
    # `|| true`: fzf --filter exits 1 on no match, which pipefail would turn
    # into the suite aborting instead of this assertion failing
    hits=$(list "$r" "$w" \
      | fzf --filter='my-project shell' --delimiter=$'\t' --with-nth=1..3 --nth=1,3 --ansi \
      | cut -f4) || true
    if printf '%s\n' "$hits" | grep -qx 'W:my-project:1'; then
      report "$r @ $w cols: 'my-project shell' finds the shell window" pass
    else
      report "$r @ $w cols: 'my-project shell' finds the shell window" fail
      ERRORS+="     hits: $(printf '%s' "$hits" | tr '\n' ' ')"$'\n'
      ERRORS+="     row : $(list "$r" "$w" | plain | grep $'\tW:my-project:1$' | cut -f1)"$'\n'
    fi
  done
done
# control: the harness itself — a width where it always matched
hits=$(list bash 160 | fzf --filter='my-project shell' --delimiter=$'\t' \
         --with-nth=1..3 --nth=1,3 --ansi | cut -f4) || true
printf '%s\n' "$hits" | grep -qx 'W:my-project:1' \
  && report "control: it matches on a wide popup" pass \
  || report "control: it matches on a wide popup" fail

# --- 2. the path gives way before the badge and the flags (BUG-24) ------------
# 96 columns is an 80% popup on a 120-column terminal.  Before: no badge and no
# Z on any row, while the path column stayed padded to all 39 cells.
for r in $RENDERERS; do
  out=$(list "$r" 96)
  c=$(ctx_of "$out" 'W:api:0')
  case "$c" in
    *'‹feature/x›'*) report "$r @ 96 cols: the branch badge survives a 39-cell path" pass ;;
    *) report "$r @ 96 cols: the branch badge survives a 39-cell path (got: $c)" fail ;;
  esac
  case "$c" in
    *Z*) report "$r @ 96 cols: the zoom flag is shown" pass ;;
    *) report "$r @ 96 cols: the zoom flag is shown (got: $c)" fail ;;
  esac
  e=$(ctx_of "$out" 'W:eps:0')
  case "$e" in
    *epsilon-project*) report "$r @ 96 cols: ...and the long path keeps its tail" pass ;;
    *) report "$r @ 96 cols: ...and the long path keeps its tail (got: $e)" fail ;;
  esac
done

# --- 3. a squeeze that drops the badge keeps the flags ------------------------
for r in $RENDERERS; do
  out=$(list "$r" 60)
  rows=$(printf '%s\n' "$out" | plain | awk -F'\t' '$4 ~ /^W:api:/ { print $2 }')
  if [[ "$rows" == *'‹'* ]]; then
    report "$r @ 60 cols: precondition — the badge has no room here" fail
    ERRORS+="     $(printf '%s' "$rows" | tr '\n' '|')"$'\n'
    continue
  fi
  s=$(ctx_of "$out" 'W:api:0'); d=$(ctx_of "$out" 'W:api:1'); n=$(ctx_of "$out" 'W:api:2')
  if [[ "$s" == *Z* && "$d" == *'!'* && "$n" == *'!#'* ]]; then
    report "$r @ 60 cols: Z, ! and !# survive the badge being dropped" pass
  else
    report "$r @ 60 cols: Z, ! and !# survive the badge being dropped" fail
    ERRORS+="     $(printf '%s|%s|%s' "$s" "$d" "$n")"$'\n'
  fi
done

# --- 4. the flags are a column: same x on every row, whatever the branch ------
# Where a glyph lands is a question for the terminal, so ask one: write the row
# up to the flag into a pane of a private server and read tmux's #{cursor_x}.
# fzf draws the field TAB as one cell (--tabstop=1), so it becomes one space.
tmux -f /dev/null -L "$PROBE" new-session -d -s p -x 250 -y 10 'sleep 600'
probe_n=0
cell_x() { # $1 = raw text (ANSI allowed, no newline) -> REPLY = cells drawn
  probe_n=$((probe_n + 1))
  printf '%s' "$1" > "$TMPD/probe$probe_n"
  tmux -L "$PROBE" new-window -d -t '=p:' -n "w$probe_n" "cat '$TMPD/probe$probe_n'; sleep 600"
  REPLY=0
  local i
  for i in $(seq 1 50); do
    REPLY=$(tmux -L "$PROBE" display-message -p -t "=p:w$probe_n" '#{cursor_x}' 2>/dev/null || echo 0)
    [ "${REPLY:-0}" -gt 0 ] && break
    sleep 0.1
  done
  tmux -L "$PROBE" kill-window -t "=p:w$probe_n" 2>/dev/null || true
}
flag_x() { # $1 = rendered output, $2 = spec, $3 = the flag glyph
  local line
  line=$(printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$4 == s { print $1 " " $2 }')
  [[ "$line" == *"$3"* ]] || { REPLY="none"; return 0; }
  cell_x "${line%%"$3"*}"
}
for r in $RENDERERS; do
  for w in 60 96 200; do
    out=$(list "$r" "$w")
    flag_x "$out" 'W:api:0' 'Z'; xz=$REPLY
    flag_x "$out" 'W:api:1' '!'; xd=$REPLY
    flag_x "$out" 'W:api:2' '!'; xn=$REPLY
    if [ "$xz" != none ] && [ "$xz" -gt 0 ] && [ "$xz" = "$xd" ] && [ "$xz" = "$xn" ]; then
      report "$r @ $w cols: Z and ! land in the same terminal column ($xz)" pass
    else
      report "$r @ $w cols: Z and ! land in the same terminal column" fail
      ERRORS+="     Z at $xz, ! at $xd and $xn"$'\n'
    fi
  done
done

# --- 5. both renderers agree, with flags and badges in play -------------------
# tests/test_rust_parity.sh's bench has neither a flag nor a zoomed window, and
# this is exactly the part of the row that moved.
if [ -x "$BIN" ]; then
  bad=""
  for g in on off; do
    for pv in off on; do
      for w in 40 52 60 72 80 96 120 200; do
        b1=$(list bash "$w" INTERDIMUX_SHOW_GIT_BRANCH=$g INTERDIMUX_SHOW_PREVIEW=$pv)
        rr=$(list rust "$w" INTERDIMUX_SHOW_GIT_BRANCH=$g INTERDIMUX_SHOW_PREVIEW=$pv)
        b2=$(list bash "$w" INTERDIMUX_SHOW_GIT_BRANCH=$g INTERDIMUX_SHOW_PREVIEW=$pv)
        if [ "$b1" != "$b2" ]; then
          bad+=" [control: bash vs bash differs at $w git=$g preview=$pv]"
        elif [ "$b1" != "$rr" ]; then
          bad+=" [$w git=$g preview=$pv]"
          # `|| true`: diff exits 1 on a difference, which pipefail + set -e
          # would turn into the suite dying here without a Results line
          if [ -z "${first_diff:-}" ]; then
            first_diff=$(diff <(printf '%s\n' "$b1" | plain) <(printf '%s\n' "$rr" | plain) \
                           | head -4) || true
          fi
        fi
      done
    done
  done
  if [ -z "$bad" ]; then
    report "rust and bash render byte-identical rows at every width (git on/off, preview on/off)" pass
  else
    report "rust and bash render byte-identical rows at every width" fail
    ERRORS+="     differs:$bad"$'\n'"${first_diff:-}"$'\n'
  fi
else
  echo "  (skipped the parity sweep: $BIN not built)"
fi

# --- 6. Enter on a zero-match query creates what the bar announced ------------
# Raw mode (fzf >= 0.74) performs find-or-create inside fzf, from the enter bind.
# Runs LAST: it creates sessions on the bench.
fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped the raw-mode Enter cases: fzf >= 0.74 needed, found 0.${fzf_minor:-?})"
else
  known=$(tmux -L "$SOCK" list-sessions -F '#S' | sort)
  bar_name() { plain | sed -n 's/^ *create \(.*\) in .*/\1/p' | head -1; }
  enter_query() { # $1 = query, $2 = the name the bar must announce first
    # sets BAR (what the bar last announced) and MADE (the sessions created)
    tmux -L "$SOCK" kill-session -t '=drv' 2>/dev/null || true
    tmux -L "$SOCK" new-session -d -s drv -x 140 -y 24 -c "$H" \
      "env HOME='$H' XDG_DATA_HOME='$TMPD/data' TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' \
           INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
           INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_PREVIEW=off \
           FZF_DEFAULT_OPTS= bash '$SCRIPT'; sleep 60"
    known=$(printf '%s\ndrv\n' "$known" | sort -u)
    until_ok 150 eval "tmux -L '$SOCK' capture-pane -t '=drv:' -p 2>/dev/null | grep -q '▸'" || true
    tmux -L "$SOCK" send-keys -t '=drv:' -l "$1"
    # Wait for the announcement of the WHOLE query: keys arrive one by one, and
    # the bar says `create z …` the moment the first one matches nothing.
    # Pressing Enter before it settles would test a different query.
    BAR=""
    local i
    for i in $(seq 1 150); do
      BAR=$(tmux -L "$SOCK" capture-pane -t '=drv:' -p 2>/dev/null | bar_name)
      [ "$BAR" = "$2" ] && break
      sleep 0.1
    done
    tmux -L "$SOCK" send-keys -t '=drv:' Enter
    MADE=""
    for i in $(seq 1 100); do
      MADE=$(comm -13 <(printf '%s\n' "$known") <(tmux -L "$SOCK" list-sessions -F '#S' | sort))
      [ -n "$MADE" ] && break
      sleep 0.1
    done
    known=$(printf '%s\n%s\n' "$known" "$MADE" | grep -v '^$' | sort -u)
  }

  enter_query 'zzz shell' 'zzz-shell'
  if [ "$BAR" = "zzz-shell" ] && [ "$MADE" = "zzz-shell" ]; then
    report "Enter on 'zzz shell' creates zzz-shell, as the bar said" pass
  else
    report "Enter on 'zzz shell' creates zzz-shell, as the bar said" fail
    ERRORS+="     bar announced '${BAR}', created '$(printf '%s' "$MADE" | tr '\n' ' ')'"$'\n'
  fi

  # Shell metacharacters: the query must reach find-or-create as ONE argument,
  # never re-parsed on the way.  The name to expect is whatever the bar
  # announces for it (--describe-create is what draws the bar); the claim under
  # test is that Enter does what the bar said.
  q="it's (a) \$HOME \"x\""
  want=$(bash "$SCRIPT" --describe-create "$q" 2>/dev/null | bar_name) || true
  enter_query "$q" "$want"
  if [ -n "$want" ] && [ "$BAR" = "$want" ] && [ "$MADE" = "$want" ]; then
    report "a query with quotes, parens and \$ creates exactly the announced session" pass
  else
    report "a query with quotes, parens and \$ creates exactly the announced session" fail
    ERRORS+="     want '$want', bar announced '${BAR}', created '$(printf '%s' "$MADE" | tr '\n' ' ')'"$'\n'
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
