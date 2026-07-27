#!/usr/bin/env bash
#
# The four UI changes, asserted against what fzf is actually given and what a
# real client actually draws.
#
# Everything here exists because a source-level check could not see it:
#
#   gating    - an unknown fzf flag or --color key is FATAL (exit 2, no TUI), so
#               a capability token that escapes its version gate is a dead key,
#               not a graceful degradation.  INTERDIMUX_FZF_MINOR only changes
#               what the script EMITS — the installed fzf is 0.74 and accepts
#               everything — so the only way to see the gate work is to read the
#               argv.  A stub fzf on PATH does that.
#   the loop  - the navigator packs the hint ladders in its own loop, separate
#               from the --hint-ladder entry point the drift test drives.  The
#               stub logs the environment fzf was handed, which is that loop's
#               actual output.
#   rendering - the scope highlight, the frozen identity column and the
#               fallback callback path only exist on a screen.
#
# Two of these caught real defects the first time they were written: the
# fallback path never re-fitting the bar after ^/, and ten call sites passing a
# literal `--footer=` when nothing fits (which costs a list row for a blank).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-render-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-render.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$OUTER" kill-server 2>/dev/null || true
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

echo "interdimux rendered UI tests"
echo

# A long argv on the pane's OWN process: exec -a rewrites argv[0], so there is
# no shell in between for the command resolver to descend through.  This is what
# makes a row overflow, which is what --freeze-left is for.
LONGCMD='buildtool --config set-rtp+=share/x --stage lua-require-cfg plugins/lsp/servers/zebra.lua'

tmux -f /dev/null -L "$SOCK" new-session -d -s proj -x 200 -y 50 -c "$SCRIPT_DIR" \
  "bash --norc --noprofile -c 'exec -a \"$LONGCMD\" sleep 900'"
tmux -L "$SOCK" new-window -d -t '=proj:' -n editor -c "$SCRIPT_DIR" 'sleep 900'
tmux -L "$SOCK" new-session -d -s other -x 200 -y 50 -c "$HOME" 'sleep 900'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=proj:editor' -F '#{pane_id}' | head -1)"
export INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_SHOW_DIRS=off

# --- the stub fzf: record argv and the environment, then decline --------------
mkdir -p "$TMPD/shim"
cat > "$TMPD/shim/fzf" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV\t%s\n' "$@"
  for v in S W P D X; do
    eval "printf 'ENV_%s\t%s\n' \"\$v\" \"\${INTERDIMUX_HINTS_$v-<unset>}\""
  done
} >> "$IMUX_ARGV_LOG"
cat >/dev/null 2>&1
exit 130
STUB
chmod +x "$TMPD/shim/fzf"
export IMUX_ARGV_LOG="$TMPD/argv.log"

capture() { # $1 = fzf minor, $2 = FZF_COLUMNS, rest = script args
  : > "$IMUX_ARGV_LOG"
  local m="$1" c="$2"; shift 2
  PATH="$TMPD/shim:$PATH" FZF_COLUMNS="$c" INTERDIMUX_FZF_MINOR="$m" \
    timeout 30 bash "$SCRIPT" "$@" >/dev/null 2>&1 || true
}
argv() { sed -n 's/^ARGV\t//p' "$IMUX_ARGV_LOG"; }
has()  { argv | grep -qx -- "$1"; }
hasp() { argv | grep -q -- "$1"; }

# --- gating: every capability token stays behind its fzf version --------------
# Each of these is fatal on an fzf that does not know it, so "it degrades
# gracefully" is exactly the wrong assumption.
# The scope highlight is gated at 66, not the 58 that introduced `nth:` —
# fzf 0.65.1 fixed "a highlighting bug when using --color fg:dim,nth:regular
# pattern over ANSI-colored items", and every row here is ANSI coloured.
for spec in "40:header:no-footer:no-freeze:no-nth" \
            "57:header:no-footer:no-freeze:no-nth" \
            "58:header:no-footer:no-freeze:no-nth" \
            "62:header:no-footer:no-freeze:no-nth" \
            "63:footer:no-header:no-freeze:no-nth" \
            "65:footer:no-header:no-freeze:no-nth" \
            "66:footer:no-header:no-freeze:nth" \
            "67:footer:no-header:freeze:nth" \
            "74:footer:no-header:freeze:nth"; do
  IFS=: read -r m want_bar _ want_fr want_nth <<< "$spec"
  capture "$m" 120
  ok=1 why=""
  case "$want_bar" in
    footer) hasp '^--footer=.' || { ok=0; why+=" no --footer;"; }
            hasp '^--header='  && { ok=0; why+=" still has --header;"; }
            hasp 'footer:'        || { ok=0; why+=" no footer: colour;"; } ;;
    header) hasp '^--header=.' || { ok=0; why+=" no --header;"; }
            hasp '^--footer='  && { ok=0; why+=" has --footer below 0.63;"; }
            hasp 'footer:'        && { ok=0; why+=" names footer: below 0.63;"; } ;;
  esac
  case "$want_fr" in
    freeze)    has '--freeze-left=1' || { ok=0; why+=" no --freeze-left;"; }
               has '--no-hscroll'    && { ok=0; why+=" both freeze and no-hscroll;"; } ;;
    no-freeze) hasp '--freeze-left' && { ok=0; why+=" --freeze-left below 0.67;"; }
               has '--no-hscroll'      || { ok=0; why+=" no --no-hscroll fallback;"; } ;;
  esac
  case "$want_nth" in
    nth)    hasp 'nth:regular' || { ok=0; why+=" no nth:regular;"; } ;;
    no-nth) hasp 'nth:regular' && { ok=0; why+=" nth:regular below 0.58;"; } ;;
  esac
  [ "$ok" = 1 ] && report "fzf 0.$m is given only the tokens it knows" pass \
                || { report "fzf 0.$m is given only the tokens it knows" fail
                     ERRORS+="     $why"$'\n'; }
done

# --- the bar flag is omitted, never passed empty ------------------------------
# `--footer=''` still draws the section: a blank row where the list should be.
capture 74 120
hasp '^--footer=.' && report "a bar that fits is passed" pass \
                      || report "a bar that fits is passed" fail
ok=1
for c in 8 4; do
  for args in "" "--jobs" "--dashboard"; do
    # shellcheck disable=SC2086
    capture 74 "$c" $args
    argv | grep -qx -- '--footer=' && { ok=0; ERRORS+="     empty --footer= at $c cols ${args:-(navigator)}"$'\n'; }
    argv | grep -qx -- '--header=' && { ok=0; ERRORS+="     empty --header= at $c cols ${args:-(navigator)}"$'\n'; }
  done
done
[ "$ok" = 1 ] && report "a bar that does not fit is omitted, not passed empty" pass \
              || report "a bar that does not fit is omitted, not passed empty" fail

# --- the navigator's OWN ladder loop ------------------------------------------
# The drift suite drives --hint-ladder; this is the second copy of that loop,
# the one whose output fzf actually receives.
capture 74 120
ok=1
for t in S W P D X; do
  from_nav=$(sed -n "s/^ENV_$t\t//p" "$IMUX_ARGV_LOG" | head -1)
  from_cli=$(bash "$SCRIPT" --hint-ladder "$t")
  [ -n "$from_nav" ] && [ "$from_nav" = "$from_cli" ] || {
    ok=0; ERRORS+="     $t: navigator exported $(printf '%.60s' "$(printf '%s' "$from_nav" | plain)")…"$'\n'; }
done
[ "$ok" = 1 ] && report "the navigator exports the same ladders --hint-ladder builds" pass \
              || report "the navigator exports the same ladders --hint-ladder builds" fail

# --- rendering ----------------------------------------------------------------
# A real client, because none of what follows exists anywhere else.
launch() { # $1 = cols, $2 = rows, rest = extra `export` lines for the launcher
  local cols="$1" rows="$2"; shift 2
  local sh="$TMPD/launch.sh"
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export TMUX=%q TMUX_PANE=%q\n' "$TMUX" "$TMUX_PANE"
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307\n'
    printf 'export INTERDIMUX_SHOW_DIRS=off FZF_DEFAULT_OPTS=\n'
    printf 'export INTERDIMUX_FZF_MINOR=74\n'
    # %q the VALUE, not the line: @interdimux-fzf-opts is itself a shell word
    # list, so `--with-shell="sh -c"` has to survive with its inner quotes.
    local e n v
    for e in "$@"; do n="${e%%=*}"; v="${e#*=}"; printf 'export %s=%q\n' "$n" "$v"; done
    printf 'exec bash %q\n' "$SCRIPT"
  } > "$sh"
  chmod +x "$sh"
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x "$cols" -y "$rows" "$sh; sleep 45"
  local i
  for i in $(seq 1 200); do
    tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '❯' && break
    sleep 0.15
  done
  sleep 0.8
}
keys() { tmux -L "$OUTER" send-keys -t '=drv:' "$@"; sleep 1.0; }
# Rows stream in, so waiting for the prompt is not waiting for the list.  Poll
# for the thing about to be asserted on rather than sleeping a fixed time — a
# loaded box otherwise reports "the picker is broken" when it was merely slow.
wait_for() { # $1 = pattern
  local i
  for i in $(seq 1 100); do
    tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | grep -q "$1" && return 0
    sleep 0.1
  done
  return 1
}
screen()  { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain; }
screen_e() { tmux -L "$OUTER" capture-pane -t '=drv:' -p -e 2>/dev/null; }
row_e() { screen_e | grep -a "$1" | head -1 || true; }

# 02 — a hscrolling long command must not take the row's identity with it.
launch 100 14
wait_for 'buildtool' || true
keys zebra
cur=$(screen | grep '▌' | head -1) || true
case "$cur" in
  *zebra*) report "the matched token is on screen" pass ;;
  *) report "the matched token is on screen (got: $cur)" fail ;;
esac
case "$cur" in
  *proj*) report "--freeze-left keeps the row's identity while it scrolls" pass ;;
  *) report "--freeze-left keeps the row's identity while it scrolls (got: $cur)" fail
     ERRORS+="     without it the identity column is replaced by the ellipsis"$'\n' ;;
esac
tmux -L "$OUTER" kill-server 2>/dev/null || true

# 01 — the ^] scope must be visible in the ROWS, not just named in the prompt.
# The discriminator is behavioural and needs no SGR decoding: with the highlight
# on, cycling the scope restyles the row; with it off, nothing about the row
# changes at all.
for state in on off; do
  launch 100 14 "INTERDIMUX_SCOPE_HIGHLIGHT=$state"
  wait_for '‹main›' || true
  before=$(row_e '‹main›')
  keys C-] C-]
  after=$(row_e '‹main›')
  prompt=$(screen | head -1 || true)
  if [ -z "$before" ] || [ -z "$after" ]; then
    report "scope-highlight=$state: a window row was captured" fail
    tmux -L "$OUTER" kill-server 2>/dev/null || true
    continue
  fi
  case "$prompt" in
    path*) : ;;
    *) report "scope-highlight=$state: ^] reached the path scope (got: ${prompt:0:20})" fail ;;
  esac
  if [ "$state" = on ]; then
    [ "$before" != "$after" ] \
      && report "the ^] scope restyles the rows, and the band moves with it" pass \
      || report "the ^] scope restyles the rows, and the band moves with it" fail
  else
    [ "$before" = "$after" ] \
      && report "@interdimux-scope-highlight=off leaves the rows alone" pass \
      || report "@interdimux-scope-highlight=off leaves the rows alone" fail
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
done

# 03 — the fallback callback path.  A user's own --with-shell turns the inline
# snippet off, and that path has to re-fit the bar itself: ^/ halves the list,
# and `focus` does not fire on the reload it triggers.  Measured before this was
# fixed: the bar stayed at the launch rung and fzf truncated it, cutting
# `^] scope` — the exact failure the tier ladder exists to remove.
for path in inline fallback; do
  if [ "$path" = fallback ]; then
    launch 100 20 'INTERDIMUX_FZF_OPTS=--with-shell="sh -c"'
  else
    launch 100 20
  fi
  wait_for 'kill' || true
  wide=$(screen | grep 'kill' | head -1) || true
  keys C-_
  narrow=$(screen | grep 'kill' | head -1) || true
  if [ -z "$wide" ] || [ -z "$narrow" ]; then
    report "$path path: the hint bar was captured" fail
  elif [ "${#narrow}" -lt "${#wide}" ] && [[ "$narrow" != *…* && "$narrow" != *··* ]]; then
    report "$path path: ^/ re-fits the bar instead of truncating it" pass
  else
    report "$path path: ^/ re-fits the bar instead of truncating it" fail
    ERRORS+="     wide  : $wide"$'\n'"     narrow: $narrow"$'\n'
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
