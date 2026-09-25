#!/usr/bin/env bash
#
# Find-or-create: the zero-match header must describe what Enter actually does.
#
# The header is the ONLY thing telling the user what a query will produce, so
# "close enough" is not a category here.  describe_create and create_from_query
# used to derive the session name independently — a plain `basename | tr` versus
# resolve_session_name, which disambiguates against existing sessions — so with
# a session "api" already open at ~/work/api, typing ~/other/api announced
# "create api" and created "other-api".
#
# Every assertion below compares the ANNOUNCED name against the name that a real
# create then produces, rather than against a hardcoded string: the point is that
# the two agree, not what either one happens to say.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-foc-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-foc.XXXXXX")"
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

echo "interdimux find-or-create tests"
echo

mkdir -p "$TMPD/work/api" "$TMPD/other/api" "$TMPD/real/target" "$TMPD/plain"
ln -s "$TMPD/real/target" "$TMPD/linkdir"

tmux -f /dev/null -L "$SOCK" new-session -d -s anchor -x 120 -y 40 -c "$TMPD"
# connect_dir creates its own sessions, so the pane shell cannot be passed per
# session -- pin it on the server.  resolve_session_name decides whether to
# reuse a name by comparing the session's CURRENT cwd against the requested dir,
# and the user's login shell rc can move that cwd transiently: observed as
# "target" being disambiguated to "real-target" while tmux was, moments later,
# reporting exactly the right path.
tmux -L "$SOCK" set -g default-command 'bash --norc --noprofile -i' 
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=anchor:' -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
# zoxide off: its database is the user's own, and a hit would make the "home"
# fallback branch untestable and the results machine-dependent
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off

sessions() { tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | sort; }

# The name inside the announcement.  Format:
#   "<verb> <name> in <dir> (<src>)"
announced_name() {
  bash "$SCRIPT" --describe-create "$1" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | sed -n 's/^\(create\|switch to\) \(.*\) in .*$/\2/p'
}
announced_verb() {
  bash "$SCRIPT" --describe-create "$1" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | sed -n 's/^\(create\|switch to\) .*$/\1/p'
}

# Run the real thing and report which session name appeared.
created_name() { # $1 = query
  local before after
  before=$(sessions)
  bash "$SCRIPT" --create-from-query "$1" >/dev/null 2>&1 || true
  # wait for the session to exist rather than sleeping
  local i new
  for i in $(seq 1 60); do
    after=$(sessions)
    [ "$after" != "$before" ] && break
    sleep 0.1
  done
  new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  # ...and then for tmux to report the RIGHT cwd, not merely a non-empty one.
  # resolve_session_name compares an existing session's cwd against the
  # requested dir to decide whether to reuse the name or disambiguate, and tmux
  # derives that cwd from /proc at query time.  On a loaded box the pane exists
  # before its cwd is right, and a stale value is just as wrong as an empty one:
  # observed as "target" being disambiguated to "real-target" because the
  # comparison ran against whatever cwd tmux had at that instant.
  #
  # $2 is the physical directory the session should land in, when the caller
  # knows it (every path-shaped query does).
  local want="${2:-}"
  if [ -n "$new" ] && [ -n "$want" ]; then
    for i in $(seq 1 80); do
      [ "$(tmux -L "$SOCK" list-panes -t "=$new" -F '#{pane_current_path}' \
             -f '#{pane_active}' 2>/dev/null | head -1)" = "$want" ] && break
      sleep 0.1
    done
  fi
  printf '%s' "$new"
}

check_agrees() { # $1 = label, $2 = query
  local label="$1" query="$2" want got expect_dir=""
  # a path-shaped query lands in its PHYSICAL directory; tell created_name so it
  # can wait for tmux to report exactly that
  [ -d "$query" ] && expect_dir=$(cd "$query" 2>/dev/null && pwd -P)
  want=$(announced_name "$query")
  got=$(created_name "$query" "$expect_dir")
  if [ -n "$want" ] && [ "$want" = "$got" ]; then
    report "$label — announced '$want', created '$got'" pass
  else
    report "$label — announced '$want', created '$got'" fail
    ERRORS+="    query: $query"$'\n'
  fi
}

# --- the plain cases ------------------------------------------------------------
check_agrees "a bare word falls back to \$HOME"        'brandnewthing'
check_agrees "an existing path is named after its dir" "$TMPD/plain"

# --- THE ONE THAT WAS WRONG -----------------------------------------------------
# "api" is now taken by $TMPD/work/api, so a second api elsewhere must be
# disambiguated -- and announced disambiguated.
check_agrees "a first api"                             "$TMPD/work/api"
check_agrees "a SECOND api elsewhere is disambiguated" "$TMPD/other/api"
# ...and it really is a different session, not a switch to the first
if [ "$(sessions | grep -c '^api$\|^other-api$\|^api-2$')" -ge 2 ]; then
  report "both api sessions exist independently" pass
else
  report "both api sessions exist independently" fail
  ERRORS+="    sessions: $(sessions | tr '\n' ' ')"$'\n'
fi

# --- a symlinked query is named after where it LANDS ------------------------------
# describe_create used the unresolved path, create_from_query used `pwd -P`.
check_agrees "a symlinked path resolves to its target" "$TMPD/linkdir"
link_name=$(announced_name "$TMPD/linkdir")
if [ "$link_name" = "target" ]; then
  report "...and that name is the physical target, not the link" pass
else
  report "...and that name is the physical target, not the link (got: $link_name)" fail
  ERRORS+="    want dir: $(cd "$TMPD/linkdir" && pwd -P)"$'\n'
  ERRORS+="    sessions: $(tmux -L "$SOCK" list-panes -a -F '#{session_name}=[#{pane_current_path}] act=#{pane_active}' | tr '\n' ' ')"$'\n'
fi

# --- an existing name says "switch to", not "create" -------------------------------
# connect_dir switches when the session exists; announcing "create" promises a
# new session that will not be made.
if [ "$(announced_verb 'brandnewthing')" = "switch to" ]; then
  report "an existing session is announced as a switch, not a create" pass
else
  report "an existing session is announced as a switch, not a create (got: $(announced_verb 'brandnewthing'))" fail
fi
if [ "$(announced_verb 'never-seen-before-xyz')" = "create" ]; then
  report "a genuinely new name is announced as a create" pass
else
  report "a genuinely new name is announced as a create" fail
fi

# --- and switching really does not make a second session ---------------------------
before=$(sessions | wc -l)
bash "$SCRIPT" --create-from-query 'brandnewthing' >/dev/null 2>&1 || true
# no wait needed: connect_dir's new-session is synchronous, so a session it
# made would already be listed when the command returns
after=$(sessions | wc -l)
if [ "$before" = "$after" ]; then
  report "re-running an existing query switches instead of duplicating" pass
else
  report "re-running an existing query switches instead of duplicating ($before -> $after)" fail
fi

# --- fzf's search syntax is not part of the name (review UX-54) --------------------
# `'docs` is fzf's exact match, and the instinctive way out of a scattered
# match -- it reaches zero matches, and Enter created a session called `'docs`.
# Each query must be announced AND created as the plain name, so this checks
# both against a literal, not only against each other.
check_named() { # $1 = label, $2 = query, $3 = the name it must make
  local want got
  want=$(announced_name "$2")
  got=$(created_name "$2")
  if [ "$want" = "$3" ] && [ "$got" = "$3" ]; then
    report "$1 — announced '$want', created '$got'" pass
  else
    report "$1 — announced '$want', created '$got', want '$3'" fail
    ERRORS+="    query: $2"$'\n'
  fi
}
check_named "a leading ' (exact) is not part of the name"   "'opexact"     opexact
check_named "nor a leading ^ (prefix)"                      '^opprefix'    opprefix
check_named "nor a trailing \$ (suffix)"                     'opsuffix$'    opsuffix
check_named "nor a leading ! (not)"                          '!opnot'       opnot
check_named "nor 'word' quotes (word boundaries)"            "'opbound'"    opbound
check_named "nor ^...\$ together"                             '^opwhole$'    opwhole
check_named "each term loses its own, runs of blanks are one" "'op  ^multi$ " op-multi
if [ -z "$(bash "$SCRIPT" --describe-create "' ^ !" 2>/dev/null)" ]; then
  report "a query that is only fzf syntax describes nothing" pass
else
  report "a query that is only fzf syntax describes nothing" fail
fi
before=$(sessions | wc -l)
bash "$SCRIPT" --create-from-query "'  " >/dev/null 2>&1 || true
if [ "$before" = "$(sessions | wc -l)" ]; then
  report "...and creates nothing" pass
else
  report "...and creates nothing" fail
  ERRORS+="    sessions: $(sessions | tr '\n' ' ')"$'\n'
fi

# --- an empty query produces neither an announcement nor a session -----------------
if [ -z "$(bash "$SCRIPT" --describe-create '' 2>/dev/null)" ]; then
  report "an empty query describes nothing" pass
else
  report "an empty query describes nothing" fail
fi
before=$(sessions | wc -l)
bash "$SCRIPT" --create-from-query '' >/dev/null 2>&1 || true
if [ "$before" = "$(sessions | wc -l)" ]; then
  report "an empty query creates nothing" pass
else
  report "an empty query creates nothing" fail
fi

# --- the agents view's query is a filter (review R03) ------------------------------
# The agents view (the dashboard's Agents entry) opens on `^! | ^?`.  Any
# edit of it -- a trailing space, a word typed after it, the OR taken out --
# is still that filter, and names nothing (it used to offer and create
# `approve-|-input-qqq` in ~).
agents_names_nothing() { # $1 = label, $2 = query
  local d k before
  d=$(INTERDIMUX_VIEW=agents bash "$SCRIPT" --describe-create "$2" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
  k=$(INTERDIMUX_VIEW=agents FZF_QUERY="$2" bash "$SCRIPT" --create-key 2>/dev/null)
  before=$(sessions | tr '\n' ' ')
  INTERDIMUX_VIEW=agents bash "$SCRIPT" --create-from-query "$2" >/dev/null 2>&1 || true
  if [[ "$d" == "∅"* && "$d" != *create* ]] && [ -z "$k" ] && [ "$before" = "$(sessions | tr '\n' ' ')" ]; then
    report "agents view, $1: names nothing, no alt-enter action, no session" pass
  else
    report "agents view, $1: names nothing (bar: '$d', alt-enter: '$k', sessions: $(sessions | tr '\n' ' '))" fail
  fi
}
agents_names_nothing "its own query"              '^! | ^?'
agents_names_nothing "with a trailing space"      '^! | ^? '
agents_names_nothing "with a word typed after it" '^! | ^? qqq'
agents_names_nothing "with the OR taken out"      '^! qqq'
agents_names_nothing "with one mark left"         '^?'
# ...and once the marks are gone it is an ordinary query again.
if [ "$(INTERDIMUX_VIEW=agents announced_name 'agq')" = agq ]; then
  report "agents view: a query without its marks names a session as usual" pass
else
  report "agents view: a query without its marks names a session as usual" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
