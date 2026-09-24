#!/usr/bin/env bash
#
# Does a row act on the thing it names -- and only on that thing?
#
# The picker hands every action a spec ("S:name", "W:name:idx", "P:name:idx:p")
# and turns it into a tmux target.  Each failure below acted on the WRONG
# target, or on none, with nothing on screen to say so:
#
#   "$1"     tmux reads a leading '$' as a session ID before it tries names,
#            and "=" does not stop it: ctrl-x on the session NAMED "$1"
#            confirmed that name, then killed session ID 1 -- someone else
#   "c:d"    a target is split at its first ':', so no "=name" spelling
#            reaches it (tmux >= 3.7 allows such names)
#   "e.f"    a bare "=e.f" is split at the '.', so session-level commands
#            (kill, rename, switch, the preview's window list) missed it
#   stale    "=st:3" for a window that has since closed is retried as a
#   index    window NAME, prefix included -- it matched "3rd" and killed it
#   '#'      new-session and rename-* FORMAT-EXPAND the name (and new-session
#            its -c too): "proj#Sync" became "proj<session>ync" in $HOME
#
# Every oracle is tmux's own state, read back after the fact -- never the
# script's target-building code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-targets-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-targets.XXXXXX")"
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
T() { tmux -L "$SOCK" "$@"; }
names() { T list-sessions -F '#{session_name}' 2>/dev/null || true; }
has_name() { names | grep -qxF -- "$1"; }
wait_for() { # $1 = a command that must succeed; bounded poll, no fixed sleep
  local i
  for i in $(seq 1 60); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux target tests"
echo

# demo is created first, so it is session ID $0 and 'a b' is ID $1 -- the ID a
# session NAMED "$1" would be mistaken for.
T -f /dev/null new-session -d -s demo -x 120 -y 30
T set -g default-command 'bash --norc --noprofile -i'
T new-session -d -s 'a b' -x 120 -y 30 -n ab-win
T split-window -d -t '=a b:'
T new-session -d -s '$1' -x 120 -y 30 -n one-win
T new-session -d -s '$work' -x 120 -y 30 -n work-win
T new-session -d -s 'e.f' -x 120 -y 30 -n ef-win
T new-session -d -s 'c:d' -x 120 -y 30 -n cd-win 2>/dev/null || true
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(T list-panes -t '=demo:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=302
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off INTERDIMUX_SHOW_DIRS=off
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CACHE_HOME="$TMPD/cache"
unset INTERDIMUX_CLIENT

if [ "$(T display-message -p -t '$1' '#{session_name}')" != 'a b' ]; then
  echo "  setup: expected 'a b' to be session \$1"; exit 1
fi
# tmux < 3.7 rewrites ':' and '.' in a new session's name to '_'; the ':' and '.'
# cases only exist where tmux keeps them.
HAVE_CD=0; has_name 'c:d' && HAVE_CD=1
HAVE_EF=0; has_name 'e.f' && HAVE_EF=1

preview() { bash "$SCRIPT" --preview "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }

# --action with a scripted answer; the dialog is appended to a file
act() { # $1 = action, $2 = spec, $3 = the keys typed -> prints the dialog text
  printf '%b' "$3" > "$TMPD/in"
  : > "$TMPD/out"
  INTERDIMUX_TTY_IN="$TMPD/in" INTERDIMUX_TTY_OUT="$TMPD/out" \
    timeout 20 bash "$SCRIPT" --action "$1" "$2" >/dev/null 2>&1 || true
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$TMPD/out" | tr -s ' ─│╭╮╰╯' ' '
}

# --- sessions whose names tmux's own targets cannot spell ------------------------
out=$(preview 'S:$1')
if printf '%s' "$out" | grep -q 'one-win' && ! printf '%s' "$out" | grep -q 'ab-win'; then
  report "the preview of session '\$1' shows that session, not session ID 1" pass
else
  report "the preview of session '\$1' shows that session, not session ID 1" fail
  ERRORS+="$(printf '%s\n' "$out" | head -4 | sed 's/^/      /' || true)"$'\n'
fi
out=$(preview 'S:$work')
printf '%s' "$out" | grep -q 'work-win' \
  && report "the preview of session '\$work' finds it" pass \
  || report "the preview of session '\$work' finds it" fail
if [ "$HAVE_EF" = 1 ]; then
  out=$(preview 'S:e.f')
  printf '%s' "$out" | grep -q 'ef-win' \
    && report "the preview of session 'e.f' lists its windows" pass \
    || report "the preview of session 'e.f' lists its windows" fail
fi
if [ "$HAVE_CD" = 1 ]; then
  out=$(preview 'S:c:d')
  printf '%s' "$out" | grep -q 'cd-win' \
    && report "the preview of session 'c:d' lists its windows" pass \
    || report "the preview of session 'c:d' lists its windows" fail
fi

# The headline case: confirm "Kill session '$1'?" and the session called $1 must
# be the one that dies.
out=$(act kill 'S:$1' 'y')
if ! has_name '$1' && has_name 'a b'; then
  report "killing session '\$1' kills that session and leaves session ID 1 alone" pass
else
  report "killing session '\$1' kills that session and leaves session ID 1 alone" fail
  ERRORS+="    sessions now: $(names | tr '\n' '|')"$'\n'
fi
act kill 'S:$work' 'y' >/dev/null
has_name '$work' \
  && report "a session named '\$work' can be killed from its row" fail \
  || report "a session named '\$work' can be killed from its row" pass
if [ "$HAVE_EF" = 1 ]; then
  act kill 'S:e.f' 'y' >/dev/null
  has_name 'e.f' \
    && report "a session named 'e.f' can be killed from its row" fail \
    || report "a session named 'e.f' can be killed from its row" pass
fi
if [ "$HAVE_CD" = 1 ]; then
  act kill 'S:c:d' 'y' >/dev/null
  has_name 'c:d' \
    && report "a session named 'c:d' can be killed from its row" fail \
    || report "a session named 'c:d' can be killed from its row" pass
fi

# --- a window index that no longer exists ------------------------------------------
# Session st: windows 0 and 5, window 5 NAMED "3rd", no window 3.  A row for the
# old window 3 must be reported gone -- not matched against "3rd" by prefix.
T new-session -d -s st -x 120 -y 30
T new-window -d -t '=st:5' -n 3rd 'printf "ST5-%s\n" MARKER; exec cat'
T split-window -d -t '=st:5' 'exec cat'
wait_for "T capture-pane -p -t '=st:5.0' | grep -q ST5-MARKER" || true

# control: the marker IS capturable through the window's own row, so the
# negative assertion below cannot pass vacuously
out=$(preview 'W:st:5')
printf '%s' "$out" | grep -q 'ST5-MARKER' \
  && report "control: window 5's own row previews its content" pass \
  || report "control: window 5's own row previews its content" fail
out=$(preview 'W:st:3')
printf '%s' "$out" | grep -q 'ST5-MARKER' \
  && report "a stale window row does not preview a different window" fail \
  || report "a stale window row does not preview a different window" pass

out=$(act kill 'W:st:3' 'y')
if printf '%s' "$out" | grep -q 'no longer exists'; then
  report "ctrl-x on a closed window's row says it is gone" pass
else
  report "ctrl-x on a closed window's row says it is gone" fail
  ERRORS+="    drew: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200 || true)"$'\n'
fi
T list-windows -t '=st:' -F '#{window_name}' | grep -qx '3rd' \
  && report "...and the window called '3rd' survives" pass \
  || report "...and the window called '3rd' survives" fail

# control first: through the pane's own row the text does arrive (the pane runs
# cat, which echoes it), so the stale case below cannot pass vacuously
act send 'P:st:5:1' 'LIVE-HIT\n' >/dev/null
wait_for "T capture-pane -p -t '=st:5.1' | grep -q LIVE-HIT" \
  && report "control: keys sent through a live pane's row arrive" pass \
  || report "control: keys sent through a live pane's row arrive" fail
out=$(act send 'P:st:3:1' 'STALE-HIT\n')
if printf '%s' "$out" | grep -q 'no longer exists' \
   && ! T capture-pane -p -t '=st:5.1' | grep -q 'STALE-HIT'; then
  report "keys sent to a closed pane's row do not land in another pane" pass
else
  report "keys sent to a closed pane's row do not land in another pane" fail
fi

# --- find-or-create with a name tmux would read as an ID ---------------------------
# "$0" names no session, although session ID $0 exists
out=$(bash "$SCRIPT" --describe-create '$0' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$out" in
  "create \$0 "*) report "the header offers to CREATE '\$0', not to switch to session ID 0" pass ;;
  *) report "the header offers to CREATE '\$0', not to switch to session ID 0 (got: $out)" fail ;;
esac
bash "$SCRIPT" --create-from-query '$0' >/dev/null 2>&1 || true
has_name '$0' && has_name 'demo' \
  && report "...and Enter creates it" pass \
  || report "...and Enter creates it" fail

# --- names the rename dialog refuses, and one it must not mistake for a flag -------
# A leading '$' is refused for a session: nothing outside the picker could reach
# it by name, since tmux reads it as an ID.
T new-session -d -s dolsrc -x 120 -y 30
out=$(act rename 'S:dolsrc' '\025$x\n')
if printf '%s' "$out" | grep -q "cannot start with" && ! has_name '$x' && has_name dolsrc; then
  report "a rename to a name starting with '\$' is refused, with the reason" pass
else
  report "a rename to a name starting with '\$' is refused, with the reason" fail
fi

# A leading '-' reaches tmux as the name, not as a flag
T new-session -d -s dashsrc -x 120 -y 30
act rename 'S:dashsrc' '\025-dash\n' >/dev/null
has_name '-dash' \
  && report "a rename to '-dash' is taken as the name, not as a flag" pass \
  || report "a rename to '-dash' is taken as the name, not as a flag" fail

# --- '#' in a name: tmux format-expands new-session -s/-c and rename-* ---------------
mkdir -p "$TMPD/dirs/proj#Sync"
PROJ="$(cd "$TMPD/dirs/proj#Sync" && pwd -P)"
bash "$SCRIPT" --connect-dir "$PROJ" >/dev/null 2>&1 || true
if has_name 'proj#Sync'; then
  report "a directory named 'proj#Sync' opens as a session of exactly that name" pass
else
  report "a directory named 'proj#Sync' opens as a session of exactly that name" fail
  ERRORS+="    sessions now: $(names | tr '\n' '|')"$'\n'
fi
# pane_current_path is read from /proc at query time, and the cwd is set at spawn
cwd=$(T display-message -p -t "$(T list-sessions -F '#{session_id} #{session_name}' | awk '$2=="proj#Sync"{print $1}'):" '#{pane_current_path}' 2>/dev/null || true)
[ "$cwd" = "$PROJ" ] \
  && report "...and its shell starts in that directory, not in \$HOME" pass \
  || { report "...and its shell starts in that directory, not in \$HOME" fail
       ERRORS+="    cwd: $cwd"$'\n'; }

n_before=$(names | wc -l)
rc1=0 rc2=0
bash "$SCRIPT" --create-from-query 'a#Sb' >/dev/null 2>&1 || rc1=$?
bash "$SCRIPT" --create-from-query 'a#Sb' >/dev/null 2>&1 || rc2=$?
n_after=$(names | wc -l)
if has_name 'a#Sb' && [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$n_after" = $((n_before + 1)) ]; then
  report "find-or-create 'a#Sb' makes that session once, and Enter again reuses it" pass
else
  report "find-or-create 'a#Sb' makes that session once, and Enter again reuses it" fail
  ERRORS+="    rc=$rc1/$rc2 sessions: $(names | tr '\n' '|')"$'\n'
fi
out=$(bash "$SCRIPT" --describe-create 'a#Sb' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case "$out" in
  "switch to a#Sb "*) report "...and the header then says it will switch to it" pass ;;
  *) report "...and the header then says it will switch to it (got: $out)" fail ;;
esac

# rename through the dialog: ^U clears the pre-filled name
T new-session -d -s hashsrc -x 120 -y 30 -n hashwin
out=$(act rename 'S:hashsrc' '\025x#Hy\n')
if has_name 'x#Hy'; then
  report "renaming a session to 'x#Hy' stores exactly that" pass
else
  report "renaming a session to 'x#Hy' stores exactly that" fail
  ERRORS+="    sessions now: $(names | tr '\n' '|')"$'\n'
fi
# whatever the dialog claims, tmux must have a session by exactly that name
said=$(printf '%s' "$out" | grep -o 'renamed to [^ ]*' | tail -1 | sed 's/^renamed to //' || true)
if [ -n "$said" ] && has_name "$said"; then
  report "...and the name the dialog reports is the one tmux stored ($said)" pass
else
  report "...and the name the dialog reports is the one tmux stored" fail
  ERRORS+="    dialog said '$said'; sessions: $(names | tr '\n' '|')"$'\n'
fi
act rename 'W:x#Hy:0' '\025w#Sname\n' >/dev/null
T list-windows -t "$(T list-sessions -F '#{session_id} #{session_name}' | awk '$2=="x#Hy"{print $1}'):" -F '#{window_name}' \
  | grep -qxF 'w#Sname' \
  && report "renaming a window to 'w#Sname' stores exactly that" pass \
  || report "renaming a window to 'w#Sname' stores exactly that" fail

# --- the dialogs name windows and panes the way the list does ----------------------
T new-window -d -t '=st:7' -n buildwin 'exec sleep 1000'
wait_for "[ \"\$(T display-message -p -t '=st:=7.0' '#{pane_current_command}')\" = sleep ]" || true
out=$(act kill 'W:st:7' 'n')
printf '%s' "$out" | grep -q "Kill window 'st:7' buildwin?" \
  && report "the kill dialog names the window as the list does ('st:7' buildwin)" pass \
  || { report "the kill dialog names the window as the list does" fail
       ERRORS+="    drew: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200 || true)"$'\n'; }
out=$(act kill 'P:st:7:0' 'n')
printf '%s' "$out" | grep -q "Kill pane 'st:7.0' sleep?" \
  && report "...and a pane by what runs in it ('st:7.0' sleep)" pass \
  || { report "...and a pane by what runs in it" fail
       ERRORS+="    drew: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200 || true)"$'\n'; }
T list-windows -t '=st:' -F '#{window_name}' | grep -qx 'buildwin' \
  && report "...and answering n kills nothing" pass \
  || report "...and answering n kills nothing" fail

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
