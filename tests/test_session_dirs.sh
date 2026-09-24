#!/usr/bin/env bash
#
# Which directory a session belongs to must survive a `cd` inside it.
#
# "Does this directory already have a session?" used to be answered by the
# ACTIVE pane's cwd alone, in four places: the navigator's directory rows (both
# renderers), the ctrl-o picker's "→ session" badge, and resolve_session_name.
# So a plain `cd src` inside the project's session -- or a second window opened
# in /tmp -- made the project directory look session-less: its `+` row came
# back, the badge vanished, and Enter (connect_dir) created `code-web`, a
# second session for the same directory.  The session's start directory,
# #{session_path}, is what does not move; all four places consult it now.
#
# And the badge, the name and Enter must agree on WHICH session: one started in
# the directory under another name, one merely passing through it, and names
# that tmux's own targets misread ("$work" is not a session ID).
#
# The oracles are the user-visible outcomes: which D: rows --list prints, the
# badge --dirs-list prints, the name --session-name-for resolves, and how many
# sessions exist after --connect-dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-sessdirs-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-sessdirs.XXXXXX")" && pwd -P)"
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

wait_for() { # $1 = description, $2.. = a command that must succeed
  local desc="$1"; shift
  local i
  for i in $(seq 1 150); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "  (timed out waiting for: $desc)" >&2
  return 1
}

# the active pane's cwd of session $1 is $2
cwd_is() { [ "$(tmux -L "$SOCK" display-message -p -t "=$1:" '#{pane_current_path}' 2>/dev/null)" = "$2" ]; }

echo "interdimux session-directory tests"
echo

H="$TMPD/home"
WEB="$H/real/code/web"
OTHER="$H/real/code/other"
mkdir -p "$WEB/src" "$OTHER" "$H/work/api/src" "$H/work/proj" "$TMPD/elsewhere/tools" \
         "$H/work/tools/sub" "$TMPD/data/interdimux"
printf '%s\n' "$WEB" "$OTHER" > "$TMPD/data/interdimux/recent_dirs"

tmux -f /dev/null -L "$SOCK" new-session -d -s bench -x 200 -y 50 -c "$H" 'sleep 99999'
tmux -L "$SOCK" set -g default-command 'bash --norc --noprofile -i'
tmux -L "$SOCK" new-session -d -s web -x 200 -y 50 -c "$WEB"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=bench:0' -F '#{pane_id}' | head -1)"
export HOME="$H" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off
export INTERDIMUX_PROJECT_DIRS="$H/real/code"
wait_for "web's shell to report its cwd" cwd_is web "$WEB"

renderers="off"
[ -x "$BIN" ] && renderers="on off"

d_rows() { # $1 = on|off -> the D: paths --list offers
  INTERDIMUX_USE_RUST="$1" bash "$SCRIPT" --list 2>/dev/null | awk -F'\t' '$4 ~ /^D:/ { print substr($4, 3) }'
}
badge_of() { # $1 = directory -> its --dirs-list badge column, ANSI stripped
  bash "$SCRIPT" --dirs-list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -F'\t' -v d="$1" '$3 == d { print $2; exit }'
}

# Everything a directory-that-has-a-session must look like; $1 = when.
check_web_is_taken() {
  local when="$1" r label got
  for r in $renderers; do
    label=$([ "$r" = on ] && echo rust || echo bash)
    got=$(d_rows "$r")
    if printf '%s\n' "$got" | grep -qxF "$OTHER"; then
      report "$when, $label: control -- a session-less recent dir is still offered" pass
    else
      report "$when, $label: control -- a session-less recent dir is still offered" fail
    fi
    if printf '%s\n' "$got" | grep -qxF "$WEB"; then
      report "$when, $label: the project dir is not re-offered as a new session" fail
    else
      report "$when, $label: the project dir is not re-offered as a new session" pass
    fi
  done
  got=$(badge_of "$WEB")
  case "$got" in
    *"→ web"*) report "$when: the ctrl-o picker still badges it → web" pass ;;
    *) report "$when: the ctrl-o picker still badges it → web (got: '$got')" fail ;;
  esac
  got=$(bash "$SCRIPT" --session-name-for "$WEB")
  [ "$got" = web ] && report "$when: its name still resolves to the existing session" pass \
                   || report "$when: its name still resolves to the existing session (got: $got)" fail
}

check_web_is_taken "before any cd"

tmux -L "$SOCK" send-keys -t '=web:' 'cd src' Enter
wait_for "the cd to land" cwd_is web "$WEB/src"
check_web_is_taken "after cd src"

# Opening the project again must switch, not create a second session for it.
before=$(tmux -L "$SOCK" list-sessions | wc -l)
bash "$SCRIPT" --connect-dir "$WEB" >/dev/null 2>&1 || true
after=$(tmux -L "$SOCK" list-sessions | wc -l)
[ "$before" = "$after" ] && report "after cd src: --connect-dir creates no duplicate session" pass \
                         || report "after cd src: --connect-dir creates no duplicate session ($before -> $after: $(tmux -L "$SOCK" list-sessions -F '#S' | tr '\n' ' '))" fail

# Whatever that created goes, so the next case stands on its own (under the old
# code it was `code-web`, a second session AT the project dir, which would hide
# the project row by itself).
for s in $(tmux -L "$SOCK" list-sessions -F '#{session_name}'); do
  case "$s" in bench|web) ;; *) tmux -L "$SOCK" kill-session -t "=$s" ;; esac
done

# A second window elsewhere, and it is the active one.
tmux -L "$SOCK" new-window -t '=web:' -c /tmp
wait_for "the /tmp window to be active" cwd_is web /tmp
check_web_is_taken "with the active window in /tmp"

# --- the second chance: a session started ABOVE the directory ----------------
# `tmux new -s api` from ~, then work inside ~/work/api: no -c, so its
# session_path is ~, and its pane is below the directory, not at it.
tmux -L "$SOCK" new-session -d -s api -x 200 -y 50 -c "$H"
tmux -L "$SOCK" new-window -t '=api:' -c "$H/work/api/src"
wait_for "api's pane to sit in work/api/src" cwd_is api "$H/work/api/src"
got=$(bash "$SCRIPT" --session-name-for "$H/work/api")
[ "$got" = api ] && report "a session started above the dir, working below it, is that dir's session" pass \
                 || report "a session started above the dir, working below it, is that dir's session (got: $got)" fail

# ...but NOT a same-named session from an unrelated directory whose pane merely
# wandered in: `tools` was started in $TMPD/elsewhere/tools.
tmux -L "$SOCK" new-session -d -s tools -x 200 -y 50 -c "$TMPD/elsewhere/tools"
tmux -L "$SOCK" new-window -t '=tools:' -c "$H/work/tools/sub"
wait_for "tools' pane to sit in work/tools/sub" cwd_is tools "$H/work/tools/sub"
got=$(bash "$SCRIPT" --session-name-for "$H/work/tools")
[ "$got" = work-tools ] && report "an unrelated same-named session is still told apart" pass \
                        || report "an unrelated same-named session is still told apart (got: $got)" fail

# --- the badge names the session Enter lands in --------------------------------
# `aaa` (sorted first by tmux) merely has a window in work/proj; `proj` was
# started there.  connect_dir resolves the name `proj`, so that is the badge.
tmux -L "$SOCK" new-session -d -s proj -x 200 -y 50 -c "$H/work/proj"
tmux -L "$SOCK" new-session -d -s aaa -x 200 -y 50 -c "$H"
tmux -L "$SOCK" new-window -t '=aaa:' -c "$H/work/proj"
wait_for "aaa's pane to sit in work/proj" cwd_is aaa "$H/work/proj"
wait_for "proj's pane to report its cwd" cwd_is proj "$H/work/proj"
got=$(INTERDIMUX_PROJECT_DIRS="$H/work" badge_of "$H/work/proj")
case "$got" in
  *"→ proj"*) report "the badge names the session started there, not one passing through" pass ;;
  *) report "the badge names the session started there, not one passing through (got: '$got')" fail ;;
esac

# --- a session not named after its directory -----------------------------------
# `tmux new -s foo` in work/repo, and foo's active window is now elsewhere.  It
# was started there, so it IS work/repo's session -- and the badge, the name,
# the find-or-create header and Enter must all say so together.  The badge used
# to say "→ foo" while Enter looked only for a session NAMED `repo`, and created
# one: a second session for the same directory.
mkdir -p "$H/work/repo" "$H/work/wander"
tmux -L "$SOCK" new-session -d -s foo -x 200 -y 50 -c "$H/work/repo"
tmux -L "$SOCK" new-window -t '=foo:' -c "$TMPD/elsewhere"
wait_for "foo's active pane to sit elsewhere" cwd_is foo "$TMPD/elsewhere"
got=$(INTERDIMUX_PROJECT_DIRS="$H/work" badge_of "$H/work/repo")
case "$got" in
  *"→ foo"*) report "a session started in a dir under another name: the badge names it" pass ;;
  *) report "a session started in a dir under another name: the badge names it (got: '$got')" fail ;;
esac
got=$(bash "$SCRIPT" --session-name-for "$H/work/repo")
[ "$got" = foo ] && report "...and its name resolves to that session" pass \
                 || report "...and its name resolves to that session (got: $got)" fail
got=$(bash "$SCRIPT" --describe-create "$H/work/repo" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
case "$got" in
  "switch to foo "*) report "...and the find-or-create header offers to switch to it" pass ;;
  *) report "...and the find-or-create header offers to switch to it (got: $got)" fail ;;
esac
before=$(tmux -L "$SOCK" list-sessions | wc -l)
bash "$SCRIPT" --connect-dir "$H/work/repo" >/dev/null 2>&1 || true
after=$(tmux -L "$SOCK" list-sessions | wc -l)
[ "$before" = "$after" ] && report "...and Enter on it creates no second session" pass \
                         || report "...and Enter on it creates no second session ($before -> $after: $(tmux -L "$SOCK" list-sessions -F '#S' | tr '\n' ' '))" fail

# ...while a session merely PASSING THROUGH a directory is not its session:
# `passer` was started in ~ and only its active window sits in work/wander.
# Enter creates `wander`, so no badge may promise `passer` (it used to).
tmux -L "$SOCK" new-session -d -s passer -x 200 -y 50 -c "$H"
tmux -L "$SOCK" new-window -t '=passer:' -c "$H/work/wander"
wait_for "passer's pane to sit in work/wander" cwd_is passer "$H/work/wander"
got=$(INTERDIMUX_PROJECT_DIRS="$H/work" badge_of "$H/work/wander")
case "$got" in
  *"→"*) report "a session passing through a dir is not badged as its session (got: '$got')" fail ;;
  *) report "a session passing through a dir is not badged as its session" pass ;;
esac
bash "$SCRIPT" --connect-dir "$H/work/wander" >/dev/null 2>&1 || true
got=$(tmux -L "$SOCK" list-sessions -F '#{session_name}|#{session_path}' | grep -cxF "wander|$H/work/wander" || true)
[ "$got" = 1 ] && report "...and Enter on it creates the session 'wander' there" pass \
               || report "...and Enter on it creates the session 'wander' there" fail
got=$(INTERDIMUX_PROJECT_DIRS="$H/work" badge_of "$H/work/wander")
case "$got" in
  *"→ wander"*) report "...which the badge then names" pass ;;
  *) report "...which the badge then names (got: '$got')" fail ;;
esac

# --- a directory whose name starts with '$' ---------------------------------------
# tmux reads "=$work" as a session ID, not a name, so a lookup through tmux's
# own targets never saw the session "$work" as taken: the name for y/$work came
# back as "$work", and Enter switched into x/$work's session -- another
# project's -- without a word.
mkdir -p "$H/x/\$work" "$H/y/\$work" "$H/n/\$1"
bash "$SCRIPT" --connect-dir "$H/x/\$work" >/dev/null 2>&1 || true
if [ "$(tmux -L "$SOCK" list-sessions -F '#{session_name}|#{session_path}' | grep -cxF "\$work|$H/x/\$work" || true)" = 1 ]; then
  report "control: x/\$work opens as the session '\$work'" pass
else
  report "control: x/\$work opens as the session '\$work'" fail
fi
got=$(bash "$SCRIPT" --session-name-for "$H/y/\$work")
[ "$got" = 'y-$work' ] && report "y/\$work, with '\$work' taken by x/\$work, is named 'y-\$work'" pass \
                      || report "y/\$work, with '\$work' taken by x/\$work, is named 'y-\$work' (got: $got)" fail
before=$(tmux -L "$SOCK" list-sessions | wc -l)
rc=0; bash "$SCRIPT" --connect-dir "$H/y/\$work" >/dev/null 2>&1 || rc=$?
after=$(tmux -L "$SOCK" list-sessions | wc -l)
if [ "$rc" = 0 ] && [ "$after" = $((before + 1)) ] \
   && tmux -L "$SOCK" list-sessions -F '#{session_name}|#{session_path}' | grep -qxF "y-\$work|$H/y/\$work"; then
  report "...and Enter on it opens its own session, not x/\$work's" pass
else
  report "...and Enter on it opens its own session, not x/\$work's (rc=$rc, $before -> $after)" fail
fi
before=$(tmux -L "$SOCK" list-sessions | wc -l)
bash "$SCRIPT" --connect-dir "$H/x/\$work" >/dev/null 2>&1 || true
after=$(tmux -L "$SOCK" list-sessions | wc -l)
[ "$before" = "$after" ] && report "...while Enter on x/\$work still reuses '\$work'" pass \
                         || report "...while Enter on x/\$work still reuses '\$work' ($before -> $after)" fail
# The reverse: session ID $1 exists, but no session is NAMED "$1" -- so n/$1
# collides with nothing and keeps its own name.
if [ -n "$(tmux -L "$SOCK" display-message -p -t '$1' '#{session_name}' 2>/dev/null)" ] \
   && ! tmux -L "$SOCK" list-sessions -F '#{session_name}' | grep -qxF '$1'; then
  got=$(bash "$SCRIPT" --session-name-for "$H/n/\$1")
  [ "$got" = '$1' ] && report "a dir named '\$1' is not renamed for session ID 1" pass \
                   || report "a dir named '\$1' is not renamed for session ID 1 (got: $got)" fail
else
  report "setup: session ID \$1 exists and no session is named '\$1'" fail
fi

# --- a start directory with a newline in it -------------------------------------
# #{session_path} rides on the session line, so a newline in it would split that
# line and hand the fragment after it the session-NAME position: a phantom
# session row called `phantom`.  tmux rewrites it (#{s/…/?/:session_path}).
nldir="$H/nl"$'\n'"phantom"
mkdir -p "$nldir"
tmux -L "$SOCK" new-session -d -s nlsess -x 200 -y 50 -c "$nldir" 'sleep 99999'
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  got=$(INTERDIMUX_USE_RUST="$r" bash "$SCRIPT" --list 2>/dev/null | awk -F'\t' '$4 ~ /^S:/ { print substr($4, 3) }' | sort)
  want=$(tmux -L "$SOCK" list-sessions -F '#{session_name}' | sort)
  if [ "$got" = "$want" ]; then
    report "$label: a newline in a start directory adds no phantom session" pass
  else
    report "$label: a newline in a start directory adds no phantom session (got: $(echo $got))" fail
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
