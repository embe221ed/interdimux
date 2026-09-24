#!/usr/bin/env bash
#
# A directory is the same directory however it is spelled.
#
# "Which session is this directory's?" is answered in four places that must
# agree: the ctrl-o picker's "→ session" badge, --session-name-for, the
# find-or-create header, and Enter (connect_dir).  The navigator's directory
# rows, in both renderers, must also drop out when Enter would switch rather
# than create.  All of them matched a session's start directory, #{session_path},
# as a STRING -- and tmux keeps that string exactly as it was given:
#
#   * `tmux new -s foo -c ~/w/repo/` (tab-completed) keeps the slash, so
#     ~/w/repo had no badge and Enter created `repo`, a second session there
#   * `tmux new -s bar`, typed in a shell whose $PWD runs through a symlink,
#     keeps the LOGICAL path.  Enter resolves every row with `pwd -P`, so the
#     logical row (zoxide stores those by default) was badged "→ bar" and Enter
#     created `proj` at the physical path instead -- the badge promised one
#     session and Enter made another
#   * the reverse, a session at the physical path and a row through the
#     symlink: no badge, the row offered as new, and Enter switched anyway
#
# And the navigator's own Enter on a directory row passed the row's spelling
# straight to new-session, so the plugin itself created logical start
# directories.
#
# The oracles are the user-visible outcomes: the badge --dirs-list prints, the
# name --session-name-for resolves, the header --describe-create prints, the
# D: rows each renderer offers, and how many sessions exist after Enter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-dirident-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dirident.XXXXXX")" && pwd -P)"
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
I() { tmux -L "$SOCK" "$@"; }
wait_for() { # $1 = a command that must succeed, $2 = tenths of a second (default 150)
  local i
  for i in $(seq 1 "${2:-150}"); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux directory-identity tests"
echo

H="$TMPD/home"
mkdir -p "$H/w/repo" "$H/real/proj" "$H/real/api" "$H/real/fresh" "$TMPD/elsewhere" \
         "$TMPD/nas/real" "$TMPD/nas/tidy" "$TMPD/data/interdimux"
ln -s "$H/real/proj" "$H/w/link"      # a symlinked project directory
ln -s "$H/real" "$H/dev"              # ...and a symlinked parent
ln -s "$TMPD/nas/real" "$TMPD/nas/link"
# The rows: the recent list, as zoxide would hand them over -- logical where the
# user's shell was logical.
printf '%s\n' "$H/w/repo" "$H/w/link" "$H/real/proj" "$H/dev/api" "$H/dev/fresh" \
              "$TMPD/nas/real" "$TMPD/nas/tidy" > "$TMPD/data/interdimux/recent_dirs"
# $TMPD/nas is an NFS mount, as far as either renderer can tell (see
# tests/test_remote_mounts.sh): a path on it must never be resolved.
MI="$TMPD/mountinfo"
if [ -r /proc/self/mountinfo ]; then
  { cat /proc/self/mountinfo
    echo "900 1 0:900 / $TMPD/nas rw,relatime shared:900 - nfs4 srv:/nas rw"; } > "$MI"
else
  : > "$MI"
fi

I -f /dev/null new-session -d -s bench -x 200 -y 50 -c "$H" 'sleep 99999'
I set -g default-command 'bash --norc --noprofile -i'
export TMUX="$(I display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(I list-panes -t '=bench:0' -F '#{pane_id}' | head -1)"
export HOME="$H" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CACHE_HOME="$TMPD/cache"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off INTERDIMUX_SHOW_PREVIEW=off
export INTERDIMUX_PROJECT_DIRS="$TMPD/no-such-dir" INTERDIMUX_MOUNTINFO="$MI"

# start SESSION DIR... -- a session as a user starts one BY HAND, from a shell in
# DIR: tmux takes the client's $PWD, logical and all, as its start directory.
# Its active window then moves elsewhere, so only the start directory can tie
# it to DIR (the active window's cwd is a second, separate rule).
start() {
  local s="$1" d="$2"
  (cd "$d" && PWD="$d" tmux -L "$SOCK" new-session -d -s "$s" -x 200 -y 50 'sleep 99999')
  I new-window -t "=$s:" -c "$TMPD/elsewhere" 'sleep 99999'
}
spath_of() { I display-message -p -t "=$1:" '#{session_path}' 2>/dev/null; }
count() { I list-sessions 2>/dev/null | wc -l; }

renderers="off"
[ -x "$BIN" ] && renderers="on off"
d_rows() { # $1 = on|off -> the D: paths --list offers
  INTERDIMUX_USE_RUST="$1" bash "$SCRIPT" --list 2>/dev/null | awk -F'\t' '$4 ~ /^D:/ { print substr($4, 3) }'
}
badge_of() { # $1 = directory -> its --dirs-list badge column, ANSI stripped
  bash "$SCRIPT" --dirs-list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -F'\t' -v d="$1" '$3 == d { print $2; exit }'
}

# DIR is SESSION's, everywhere: $1 = what, $2 = DIR, $3 = SESSION
is_theirs() {
  local what="$1" d="$2" s="$3" got r label before after
  got=$(badge_of "$d")
  case "$got" in
    *"→ $s") report "$what: the ctrl-o badge names $s" pass ;;
    *) report "$what: the ctrl-o badge names $s (got: '$got')" fail ;;
  esac
  got=$(bash "$SCRIPT" --session-name-for "$d")
  [ "$got" = "$s" ] && report "$what: --session-name-for says $s" pass \
                    || report "$what: --session-name-for says $s (got: $got)" fail
  got=$(bash "$SCRIPT" --describe-create "$d" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
  case "$got" in
    "switch to $s "*) report "$what: the find-or-create header offers to switch to $s" pass ;;
    *) report "$what: the find-or-create header offers to switch to $s (got: $got)" fail ;;
  esac
  for r in $renderers; do
    label=$([ "$r" = on ] && echo rust || echo bash)
    if d_rows "$r" | grep -qxF "$d"; then
      report "$what, $label: the navigator does not offer it as a new directory" fail
    else
      report "$what, $label: the navigator does not offer it as a new directory" pass
    fi
  done
  before=$(count)
  bash "$SCRIPT" --connect-dir "$d" >/dev/null 2>&1 || true
  after=$(count)
  [ "$before" = "$after" ] && report "$what: Enter creates no second session" pass \
    || report "$what: Enter creates no second session ($before -> $after: $(I list-sessions -F '#S' | tr '\n' ' '))" fail
}

# Controls first: with nothing started, a row IS offered, and Enter would create.
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  if d_rows "$r" | grep -qxF "$H/w/repo"; then
    report "control, $label: a directory with no session is offered" pass
  else
    report "control, $label: a directory with no session is offered" fail
  fi
done

# --- a trailing slash ------------------------------------------------------------
I new-session -d -s foo -x 200 -y 50 -c "$H/w/repo/" 'sleep 99999'
I new-window -t '=foo:' -c "$TMPD/elsewhere" 'sleep 99999'
if [ "$(spath_of foo)" = "$H/w/repo/" ]; then
  report "premise: tmux keeps -c '…/repo/' with its slash" pass
  is_theirs "started with -c 'w/repo/'" "$H/w/repo" foo
else
  report "premise: tmux keeps -c '…/repo/' with its slash (got: $(spath_of foo))" fail
fi

# --- started through a symlink: the row spelled as it was, and physically ----------
start bar "$H/w/link"
if [ "$(spath_of bar)" = "$H/w/link" ]; then
  report "premise: a session started from a symlinked \$PWD keeps the logical path" pass
  is_theirs "started at the logical w/link, its logical row" "$H/w/link" bar
  is_theirs "started at the logical w/link, its physical row" "$H/real/proj" bar
else
  report "premise: a session started from a symlinked \$PWD keeps the logical path (got: $(spath_of bar))" fail
fi

# --- started at the physical path, the row through a symlinked parent -------------
I new-session -d -s api -x 200 -y 50 -c "$H/real/api" 'sleep 99999'
I new-window -t '=api:' -c "$TMPD/elsewhere" 'sleep 99999'
is_theirs "started at real/api, its row via the symlinked dev/" "$H/dev/api" api

# --- a network filesystem is compared as spelled, never resolved ---------------------
# Resolving a path means a stat on every component, which on a stalled mount
# blocks the list for the mount's timeout; so a start directory on one is left
# as it was spelled -- only tidied, which needs no stat: a trailing slash still
# matches.  The observable half of "never resolved": the physical spelling of
# a directory there is NOT tied to the session started at its logical one.
if [ -s "$MI" ]; then
  I new-session -d -s nasfoo -x 200 -y 50 -c "$TMPD/nas/tidy/" 'sleep 99999'
  I new-window -t '=nasfoo:' -c "$TMPD/elsewhere" 'sleep 99999'
  got=$(badge_of "$TMPD/nas/tidy")
  case "$got" in
    *"→ nasfoo") report "on NFS, -c 'tidy/' is still the directory tidy: the badge names nasfoo" pass ;;
    *) report "on NFS, -c 'tidy/' is still the directory tidy: the badge names nasfoo (got: '$got')" fail ;;
  esac
  for r in $renderers; do
    label=$([ "$r" = on ] && echo rust || echo bash)
    if d_rows "$r" | grep -qxF "$TMPD/nas/tidy"; then
      report "...$label: and the navigator does not offer it as a new directory" fail
    else
      report "...$label: and the navigator does not offer it as a new directory" pass
    fi
  done
  start nasbar "$TMPD/nas/link"
  got=$(badge_of "$TMPD/nas/real")
  case "$got" in
    *"→"*) report "a start directory on NFS is not resolved to match another spelling (badge: '$got')" fail ;;
    *) report "a start directory on NFS is not resolved to match another spelling" pass ;;
  esac
  for r in $renderers; do
    label=$([ "$r" = on ] && echo rust || echo bash)
    if d_rows "$r" | grep -qxF "$TMPD/nas/real"; then
      report "...$label: nor is its row hidden by it" pass
    else
      report "...$label: nor is its row hidden by it" fail
    fi
  done
else
  echo "  (skipped the network-filesystem case: no /proc/self/mountinfo here)"
fi

# --- the navigator's Enter on a D: row --------------------------------------------------
# dev/fresh has no session.  Enter on its row -- the real navigator, on a real
# terminal -- must create the session at the PHYSICAL path, as ctrl-o's Enter
# and --connect-dir do: a logical start directory is the thing the lookups
# above have to work around.
O() { tmux -L "$OUTER" "$@"; }
screen() { { O capture-pane -p -t '=drv:' 2>/dev/null || true; } | sed 's/\x1b\[[0-9;]*m//g'; }
O -f /dev/null new-session -d -s drv -x 160 -y 30 -c "$TMPD" \
  "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' HOME='$H' XDG_DATA_HOME='$TMPD/data' \
       XDG_STATE_HOME='$TMPD/state' XDG_CACHE_HOME='$TMPD/cache' \
       INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
       INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off \
       INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_MOUNTINFO='$MI' \
       bash '$SCRIPT'; echo DONE-drv; sleep 60"
if wait_for "screen | grep -q 'fresh'" 250; then
  O send-keys -t '=drv:' -l 'fresh'
  if wait_for "screen | grep -qE '❯ fresh .* 1/[0-9]+'" 100; then
    O send-keys -t '=drv:' Enter
    wait_for "screen | grep -q 'DONE-drv'" 150 || true
    got=$(I list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null | grep '^fresh|' || true)
    [ "$got" = "fresh|$H/real/fresh" ] \
      && report "Enter on a D: row spelled through a symlink starts the session at the physical path" pass \
      || report "Enter on a D: row spelled through a symlink starts the session at the physical path (got: '$got')" fail
  else
    report "Enter on a D: row (the row could not be picked: $(screen | grep -m1 '❯'))" fail
  fi
else
  report "Enter on a D: row (the navigator did not draw: $(screen | grep -v '^ *$' | head -2 | tr '\n' '|'))" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
