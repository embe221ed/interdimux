#!/usr/bin/env bash
#
# Config-forwarding contract tests.
#
# The popup navigator and every fzf callback run with INTERDIMUX_OPTS_PRIMED=1,
# which tells load_tmux_opts that the launcher already resolved every option --
# so it skips the tmux dump entirely.  That is only safe while the three lists
# below stay in sync:
#
#   get_opt env var   ->  must be forwarded by env_fwd_vars
#   get_opt @option   ->  must be listed in OPT_NAMES (or the cold dump misses it)
#
# If a get_opt env var is NOT forwarded, a primed child silently falls back to
# the BUILT-IN DEFAULT and the user's @interdimux-* setting is ignored with no
# error.  These are static checks -- no tmux server required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
PASS=0
FAIL=0
ERRORS=""

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $name"$'\n'
    printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux config-forwarding tests"
echo

# --- the three lists --------------------------------------------------------

# Env var names referenced by get_opt calls: get_opt VAR "${INTERDIMUX_X:-}" @opt default
mapfile -t GETOPT_ENV < <(grep -E '^[[:space:]]*get_opt ' "$SCRIPT" \
  | grep -oE '\$\{INTERDIMUX_[A-Z_]+:-\}' | grep -oE 'INTERDIMUX_[A-Z_]+' | sort -u)

# Option names referenced by get_opt calls
mapfile -t GETOPT_OPTS < <(grep -E '^[[:space:]]*get_opt ' "$SCRIPT" \
  | grep -oE '@interdimux-[a-z-]+' | sed 's/^@interdimux-//' | sort -u)

# Env vars actually forwarded into the popup by env_fwd_vars
mapfile -t FWD_ENV < <(sed -n '/^env_fwd_vars()/,/^}/p' "$SCRIPT" \
  | grep -oE '"INTERDIMUX_[A-Z_]+=' | grep -oE 'INTERDIMUX_[A-Z_]+' | sort -u)

# Option names covered by the one-shot dump
mapfile -t OPT_NAMES < <(sed -n '/^OPT_NAMES=(/,/^)/p' "$SCRIPT" \
  | sed -e 's/^OPT_NAMES=(//' -e 's/)$//' | tr ' ' '\n' | grep -E '^[a-z-]+$' | sort -u)

has() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# --- assertions -------------------------------------------------------------

if [ "${#GETOPT_ENV[@]}" -ge 20 ]; then
  report "found get_opt env vars to check (${#GETOPT_ENV[@]})" pass
else
  report "found get_opt env vars to check (${#GETOPT_ENV[@]}, expected >= 20)" fail
fi

missing_fwd=""
for e in ${GETOPT_ENV[@]+"${GETOPT_ENV[@]}"}; do
  has "$e" ${FWD_ENV[@]+"${FWD_ENV[@]}"} || missing_fwd+=" $e"
done
if [ -z "$missing_fwd" ]; then
  report "every get_opt env var is forwarded by env_fwd_vars" pass
else
  report "every get_opt env var is forwarded by env_fwd_vars (missing:$missing_fwd)" fail
fi

missing_opt=""
for o in ${GETOPT_OPTS[@]+"${GETOPT_OPTS[@]}"}; do
  has "$o" ${OPT_NAMES[@]+"${OPT_NAMES[@]}"} || missing_opt+=" $o"
done
if [ -z "$missing_opt" ]; then
  report "every get_opt option is covered by OPT_NAMES" pass
else
  report "every get_opt option is covered by OPT_NAMES (missing:$missing_opt)" fail
fi

# The sentinel itself must be forwarded, or the whole warm path is dead again.
if sed -n '/^env_fwd_vars()/,/^}/p' "$SCRIPT" | grep -q 'INTERDIMUX_OPTS_PRIMED=1'; then
  report "env_fwd_vars forwards INTERDIMUX_OPTS_PRIMED" pass
else
  report "env_fwd_vars forwards INTERDIMUX_OPTS_PRIMED" fail
fi

# ...and load_tmux_opts must actually honour it.
if sed -n '/^load_tmux_opts()/,/^}/p' "$SCRIPT" | grep -q 'INTERDIMUX_OPTS_PRIMED'; then
  report "load_tmux_opts honours INTERDIMUX_OPTS_PRIMED" pass
else
  report "load_tmux_opts honours INTERDIMUX_OPTS_PRIMED" fail
fi

# Guard against the reverse desync: a forwarded var nothing reads is dead weight
# (and usually means a rename went half-applied).
unread=""
for e in ${FWD_ENV[@]+"${FWD_ENV[@]}"}; do
  case "$e" in
    INTERDIMUX_FZF_MINOR|INTERDIMUX_TMUX_VNUM|INTERDIMUX_OPTS_PRIMED) continue ;;
  esac
  has "$e" ${GETOPT_ENV[@]+"${GETOPT_ENV[@]}"} || unread+=" $e"
done
if [ -z "$unread" ]; then
  report "no forwarded var is unread by get_opt" pass
else
  report "no forwarded var is unread by get_opt (orphans:$unread)" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
