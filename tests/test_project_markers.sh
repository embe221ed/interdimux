#!/usr/bin/env bash
#
# @interdimux-project-markers: a typo must not turn every directory into a
# project.
#
# The option is a ':'-separated list, split with `read -a`, which KEEPS the
# empty field a doubled or leading ':' produces.  is_project_root then tested
# `[ -e "$dir/" ]` for it -- true for every directory -- so 'Move.toml::deno.json'
# (the README's own example, one keystroke off) promoted every scanned directory
# to the ◆ project tier.
#
# The oracle is the tier glyph --dirs-list prints for a directory that has NO
# marker in it at all: it must stay '·' whatever the marker list says, and a
# directory that DOES carry a user marker must still be '◆' (so the filter did
# not simply throw the user's markers away).
#
# No tmux server: --dirs-list only asks tmux which directories already have a
# session, and TMUX points at a socket that does not exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-markers.XXXXXX")" && pwd -P)"
FIX_HOME="$TMPD/home"
PASS=0
FAIL=0
ERRORS=""

cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux project-marker tests"
echo

mkdir -p "$FIX_HOME/work/plain" "$FIX_HOME/work/denoproj" "$FIX_HOME/work/ciproj/.github/workflows"
mkdir -p "$FIX_HOME/.local/share/interdimux"
: > "$FIX_HOME/work/denoproj/deno.json"

# The tier glyph of one directory's row, ANSI stripped.  $1 = marker list.
tier_of() { # $1 = markers, $2 = directory
  env -i \
    PATH="$PATH" HOME="$FIX_HOME" \
    XDG_DATA_HOME="$FIX_HOME/.local/share" \
    TMUX="$TMPD/no-such-socket,0,0" \
    INTERDIMUX_PROJECT_DIRS="$FIX_HOME/work" \
    INTERDIMUX_PROJECT_MARKERS="$1" \
    INTERDIMUX_USE_ZOXIDE=off \
    bash "$SCRIPT" --dirs-list 2>/dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -F'\t' -v d="$2" '$3 == d { split($1, a, " "); for (i in a) if (a[i] != "") { print a[i]; exit } }'
}

# Control: a well-formed list classifies correctly, so the probe itself works.
got=$(tier_of 'Move.toml:deno.json' "$FIX_HOME/work/plain")
[ "$got" = "·" ] && report "control: a directory with no marker is plain (·)" pass \
                  || report "control: a directory with no marker is plain (· — got '$got')" fail
got=$(tier_of 'Move.toml:deno.json' "$FIX_HOME/work/denoproj")
[ "$got" = "◆" ] && report "control: a user marker makes a project (◆)" pass \
                  || report "control: a user marker makes a project (◆ — got '$got')" fail

# The typos.  Each one used to make 'plain' a project.
for markers in 'Move.toml::deno.json' ':Gemfile' 'Gemfile:.' 'Gemfile:/' 'Gemfile:./' 'Gemfile:..'; do
  got=$(tier_of "$markers" "$FIX_HOME/work/plain")
  if [ "$got" = "·" ]; then
    report "markers '$markers': a directory with no marker stays plain" pass
  else
    report "markers '$markers': a directory with no marker stays plain (got '$got')" fail
  fi
done

# ...and the rest of a typo'd list still works.
got=$(tier_of 'Move.toml::deno.json' "$FIX_HOME/work/denoproj")
[ "$got" = "◆" ] && report "markers 'Move.toml::deno.json': deno.json still marks a project" pass \
                  || report "markers 'Move.toml::deno.json': deno.json still marks a project (got '$got')" fail

# A marker with a '/' in it is a real, nested marker -- not a typo to drop.
got=$(tier_of '.github/workflows' "$FIX_HOME/work/ciproj")
[ "$got" = "◆" ] && report "a nested marker (.github/workflows) still marks a project" pass \
                  || report "a nested marker (.github/workflows) still marks a project (got '$got')" fail

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
