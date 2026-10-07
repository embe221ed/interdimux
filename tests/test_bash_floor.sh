#!/usr/bin/env bash
#
# The bash floor is 4.3, and it is enforced and true.
#
#   * A bash older than 4.3 -- macOS's own /bin/bash is 3.2, RHEL 7's is 4.2 --
#     or a shell that is not bash is refused with ONE line naming what it found.
#     Unchecked, 3.2 died with "declare: -A: invalid option" and 4.2 with
#     "local: -n: invalid option", from somewhere inside, and behind a key
#     binding nobody saw even that.  From inside tmux the line also reaches the
#     status line, which outlives a popup.
#   * 4.3 itself works: the list, and the paths where an empty array is
#     "unbound" to bash < 4.4 under `set -u` -- the directory picker's deep
#     search with no match, and a doubled ':' in @interdimux-project-markers.
#   * A '$' in a session name or a directory works on every bash from 4.3 to
#     5.1 -- the ones that expand an array subscript twice -- and runs nothing.
#
# Old bashes are real binaries: point INTERDIMUX_OLD_BASH_DIR at a directory
# holding <major.minor>/bash for each of OLD_VERSIONS below -- 3.2, 4.2, 4.3,
# 4.4, 5.0 and 5.1.  CI and the dev image build exactly those
# (OLD_BASH_VERSIONS in dev/versions.env) with dev/install/bash-old.sh, the
# recipe, with the flags a modern gcc needs.
# With the variable set, a version that is not there FAILS, by name: a skip
# there is how 4.4 and 5.0 went unrun on every CI run while the totals read
# green.  Unset (a local run without them), each is reported as skipped where
# it would have run.  The not-bash case needs only dash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-bashfloor-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-bashfloor.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
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
check() { if eval "$2"; then report "$1" pass; else report "$1" fail; fi; }

echo "interdimux bash-floor tests"
echo

export LC_ALL=C.UTF-8 LANG=C.UTF-8
tmux -f /dev/null -L "$SOCK" new-session -d -s main -x 120 -y 30 'sleep 900'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_USE_ZOXIDE=off

# $1 = the shell, then the script's arguments.  Sets RC, OUT and ERR.  $TMUX
# stays pointed at the private server even here: were the check missing,
# --bind-keys would otherwise rebind whatever server a bare `tmux` reaches.
run() {
  local sh="$1"; shift
  RC=0
  OUT=$(timeout 20 "$sh" "$SCRIPT" "$@" </dev/null 2>"$TMPD/err") || RC=$?
  ERR=$(cat "$TMPD/err")
}
# The refusal, as the user reads it.  $1 = the shell, $2 = what it says it found.
refused() {
  local sh="$1" found="$2" want arg
  want="interdimux: bash >= 4.3 is required (found $found)"
  for arg in --version --list --doctor --bind-keys; do
    run "$sh" "$arg"
    check "$found, $arg: exit 1 (got $RC)" '[ "$RC" = 1 ]'
    check "...and exactly one line on stderr, naming it (got: ${ERR%%$'\n'*})" \
      '[ "$ERR" = "$want" ]'
    check "...and nothing on stdout" '[ -z "$OUT" ]'
  done
}

OLD_DIR="${INTERDIMUX_OLD_BASH_DIR:-}"
old_bash() { # $1 = version: sets REPLY to a bash of exactly that version, or fails
  REPLY="$OLD_DIR/$1/bash"
  [ -n "$OLD_DIR" ] && [ -x "$REPLY" ] \
    && case "$("$REPLY" -c 'echo "$BASH_VERSION"' 2>/dev/null)" in "$1".*) true ;; *) false ;; esac
}
# Every version a case below runs on: the two that must be refused, then 4.3
# to 5.1, the bashes that expand an array subscript twice.  These lists are the
# authority: the cases loop over them, not over lists of their own, so every
# version a case runs on is one the check below requires.  CI's
# OLD_BASH_VERSIONS has to cover them.
REFUSED_VERSIONS=(3.2 4.2)
DOUBLE_EXPANSION_VERSIONS=(4.3 4.4 5.0 5.1)
OLD_VERSIONS=("${REFUSED_VERSIONS[@]}" "${DOUBLE_EXPANSION_VERSIONS[@]}")

# --- the old bashes are there, when they were promised ---------------------------------
if [ -n "$OLD_DIR" ]; then
  for v in "${OLD_VERSIONS[@]}"; do
    old_bash "$v" \
      || report "bash $v is in \$INTERDIMUX_OLD_BASH_DIR (no $OLD_DIR/$v/bash of that version)" fail
  done
fi

# --- the control: this bash passes ----------------------------------------------------
run "$BASH" --version
check "control: bash $BASH_VERSION runs it (--version exits 0)" \
  '[ "$RC" = 0 ] && [[ "$OUT" =~ ^interdimux\ [0-9] ]] && [ -z "$ERR" ]'

# --- refused ------------------------------------------------------------------------------
echo
echo "a shell below the floor is refused, in one line"
if command -v dash >/dev/null 2>&1; then
  refused dash "a shell that is not bash"
else
  echo "  (skipped: no dash for the not-bash case)"
fi
for v in "${REFUSED_VERSIONS[@]}"; do
  if old_bash "$v"; then
    b="$REPLY"
    refused "$b" "bash $("$b" -c 'echo "$BASH_VERSION"')"
  else
    echo "  (skipped bash $v: not in \$INTERDIMUX_OLD_BASH_DIR)"
  fi
done

# From inside tmux it says so on the status line too: behind a key binding or in
# a popup, stderr is never seen.  A client is attached, so the message is drawn.
refuser=""
if old_bash 3.2; then refuser="$REPLY"; elif command -v dash >/dev/null 2>&1; then refuser=dash; fi
if [ -n "$refuser" ]; then
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 200 -y 10 \
    "env -u TMUX -u TMUX_PANE tmux -L '$SOCK' attach -t main"
  for _ in $(seq 1 100); do [ -n "$(tmux -L "$SOCK" list-clients 2>/dev/null)" ] && break; sleep 0.1; done
  RC=0
  timeout 20 "$refuser" "$SCRIPT" --list >/dev/null 2>&1 </dev/null || RC=$?
  seen=0
  for _ in $(seq 1 50); do
    tmux -L "$OUTER" capture-pane -p -t '=drv:' 2>/dev/null \
      | grep -qF 'interdimux: bash >= 4.3 is required' && { seen=1; break; }
    sleep 0.1
  done
  check "inside tmux, the refusal is on the status line too ($refuser)" '[ "$RC" = 1 ] && [ "$seen" = 1 ]'
  tmux -L "$OUTER" kill-server 2>/dev/null || true
else
  echo "  (skipped the status-line case: neither bash 3.2 nor dash is here)"
fi

# --- 4.3 works --------------------------------------------------------------------------
echo
echo "bash 4.3 itself works"
if old_bash 4.3; then
  b43="$REPLY"
  run43() { # like run, but inside the private tmux
    RC=0
    OUT=$(env "$@" timeout 30 "$b43" "$SCRIPT" "${ARGS[@]}" </dev/null 2>"$TMPD/err") || RC=$?
    ERR=$(cat "$TMPD/err")
  }
  ARGS=(--list); run43 INTERDIMUX_SHOW_DIRS=off
  check "--list lists the session (rc $RC)" \
    '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "S:main\$" && [ -z "$ERR" ]'

  # The deep search (ctrl-f in the directory picker) collects its matches with
  # mapfile, and a query that matches nothing leaves that array empty.
  mkdir -p "$TMPD/proj/alpha" "$TMPD/proj/beta"
  ARGS=(--dirs-list --deep alp); run43 INTERDIMUX_PROJECT_DIRS="$TMPD/proj"
  check "control: a deep search finds a match (rc $RC)" \
    '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "$TMPD/proj/alpha\$"'
  ARGS=(--dirs-list --deep zzqqnomatch); run43 INTERDIMUX_PROJECT_DIRS="$TMPD/proj"
  check "a deep search that matches nothing ends quietly (rc $RC)" '[ "$RC" = 0 ] && [ -z "$ERR" ]'
  check "...and lists nothing" '[ -z "$OUT" ]'

  # A doubled ':' is an empty marker, which the marker filter splits into no
  # parts at all -- on every invocation, since the markers are read at startup.
  ARGS=(--list); run43 INTERDIMUX_SHOW_DIRS=off INTERDIMUX_PROJECT_MARKERS='Move.toml::deno.json'
  check "a doubled ':' in @interdimux-project-markers still lists (rc $RC)" \
    '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "S:main\$" && [ -z "$ERR" ]'
else
  echo "  (skipped bash 4.3: not in \$INTERDIMUX_OLD_BASH_DIR)"
fi

# --- a '$' in a name, on every bash up to 5.1 -----------------------------------
# `[[ -v "arr[$key]" ]]` expands the subscript a SECOND time on every bash before
# 5.2, so a '$' in a key was read as a parameter: under set -u a session named
# `$work` killed the whole list with "work: unbound variable", one named `$(…)`
# RAN its name, and a recent directory like `$RECYCLE.BIN` cut ctrl-o's list off
# there -- without the Rust core on the list, and in ctrl-o (which bash always
# draws) with it.  Each key that reaches such a test is here: a session and its
# window and pane lines, a pane's cwd (the git cache), a recent directory (the
# recent list, the navigator's directory rows, ctrl-o's), a zoxide entry, and a
# network mount point with the directory below it.  It runs on every bash in
# DOUBLE_EXPANSION_VERSIONS: 4.3, the floor, to 5.1, the last bash with the
# double expansion, 4.4 and 5.0 included.
echo
echo "a '\$' in a session name or directory, on bash < 5.2"
DL="$TMPD/dl"
mkdir -p "$DL/\$pane" "$DL/before" "$DL/\$RECYCLE.BIN" "$DL/after" "$DL/\$zox" "$DL/\$nfs" \
  "$TMPD/zbin" "$TMPD/data/interdimux"
mkdir -p "$DL/\$pane/.git" && printf 'ref: refs/heads/dollarbranch\n' > "$DL/\$pane/.git/HEAD"
printf '%s\n' "$DL/before" "$DL/\$RECYCLE.BIN" "$DL/\$nfs/gone" "$DL/after" \
  > "$TMPD/data/interdimux/recent_dirs"
printf "#!/bin/sh\nprintf '%%s\\\\n' '%s'\n" "$DL/\$zox" > "$TMPD/zbin/zoxide"
chmod +x "$TMPD/zbin/zoxide"
{ cat /proc/self/mountinfo 2>/dev/null || :
  echo "900 1 0:900 / $DL/\$nfs rw,relatime shared:900 - nfs4 srv:/nas rw"; } > "$TMPD/mountinfo"
MARKER="$TMPD/marker"
# (by window ID: tmux reads any target starting with '$', even '=$work', as a session ID)
wid=$(tmux -L "$SOCK" new-session -d -P -F '#{window_id}' -s '$work' -c "$DL/\$pane" 'sleep 900')
tmux -L "$SOCK" split-window -d -t "$wid" -c "$DL/\$pane" 'sleep 900'
tmux -L "$SOCK" new-session -d -s "\$(touch $MARKER)" 'sleep 900'
for _ in $(seq 1 100); do
  [ "$(tmux -L "$SOCK" list-panes -a -F '#{pane_current_path}' 2>/dev/null | grep -cxF "$DL/\$pane")" = 2 ] && break
  sleep 0.1
done
DENV=(PATH="$TMPD/zbin:$PATH" INTERDIMUX_USE_RUST=off INTERDIMUX_SHOW_DIRS=on INTERDIMUX_DIRS_LIMIT=20
      INTERDIMUX_USE_ZOXIDE=on INTERDIMUX_SHOW_GIT_BRANCH=on FZF_COLUMNS=200
      INTERDIMUX_MOUNTINFO="$TMPD/mountinfo" INTERDIMUX_PROJECT_DIRS="$TMPD/nowhere")
specs() { printf '%s\n' "$OUT" | awk -F'\t' '{ print $NF }' | tr '\n' ' '; }
has_rows() { # $@ = specs that must all be in $rows
  local s
  for s in "$@"; do case " $rows" in *" $s "*) ;; *) return 1 ;; esac; done
}
dollar_ok=0
for v in "${DOUBLE_EXPANSION_VERSIONS[@]}"; do
  if ! old_bash "$v"; then
    echo "  (skipped bash $v: not in \$INTERDIMUX_OLD_BASH_DIR)"
    continue
  fi
  dollar_ok=1
  b="$REPLY"; rm -f "$MARKER"
  RC=0
  OUT=$(env "${DENV[@]}" timeout 30 "$b" "$SCRIPT" --list </dev/null 2>"$TMPD/err") || RC=$?
  ERR=$(cat "$TMPD/err")
  rows=$(specs)
  check "$v: the bash renderer lists '\$' names (rc $RC, stderr: ${ERR%%$'\n'*})" '[ "$RC" = 0 ] && [ -z "$ERR" ]'
  check "$v: ...every session, window and pane of them" \
    'has_rows "S:\$work" "W:\$work:0" "P:\$work:0:0" "P:\$work:0:1" "S:\$(touch $MARKER)" "W:\$(touch $MARKER):0"'
  check "$v: ...and every directory row: recent, zoxide, and one on a network mount" \
    'has_rows "D:$DL/before" "D:$DL/\$RECYCLE.BIN" "D:$DL/\$nfs/gone" "D:$DL/after" "D:$DL/\$zox"'
  # the badge is read through the git cache, keyed on the pane's '$' cwd
  badge=$(printf '%s\n' "$OUT" | awk -F'\t' -v s="W:\$work:0" '$4 == s { print $2 }')
  check "$v: ...and the git badge of the pane in a '\$' directory" '[[ "$badge" == *"‹dollarbranch›"* ]]'
  RC=0
  OUT=$(env "${DENV[@]}" timeout 30 "$b" "$SCRIPT" --dirs-list </dev/null 2>"$TMPD/err") || RC=$?
  ERR=$(cat "$TMPD/err")
  rows=$(specs)
  check "$v: ctrl-o's list keeps a '\$' directory and every one after it (rc $RC, stderr: ${ERR%%$'\n'*})" \
    '[ "$RC" = 0 ] && [ -z "$ERR" ] && [ "$rows" = "$DL/before $DL/\$RECYCLE.BIN $DL/\$nfs/gone $DL/after $DL/\$zox " ]'
  check "$v: a session named \$(touch …) never ran its name" '[ ! -e "$MARKER" ]'
done
[ "$dollar_ok" = 1 ] || echo "  (skipped every '\$' case: no bash from 4.3 to 5.1 to run them on)"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
