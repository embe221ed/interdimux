#!/usr/bin/env bash
#
# The golden corpus, rendered by BOTH renderers.
#
# rust/tests/corpus/*.dump are recorded tmux dumps -- hostile names, bad ages,
# every window flag, indexes at tmux's ceilings, an empty server -- and until
# this suite only the Rust core ever saw them (rust/tests/golden.rs feeds them to
# `imux gather3` on stdin).  The bash renderer is the one every install without
# cargo runs, and it had no way to read a dump: its sections came straight from
# tmux.  INTERDIMUX_DUMP_IN=<file> is that way in, at gather_targets' fetch site.
#
# No tmux server, no pty, no timing: every render here is a pure function of
# the dump and the pinned environment below (golden.rs's own).  tmux is a PATH
# stub that logs and fails, so a seam that fell through to a real server --
# which, with no private socket to point at, would be the USER's -- is caught
# rather than rendered.
#
# The oracle is always the OTHER implementation (or the checked-in golden it
# blessed), never the code under test.  Where the two renderers are documented
# to differ -- bash pads by characters, so a wide glyph shifts its columns
# (rust/README.md, "Intentional divergences") -- the case sits on an explicit
# list below and must still agree on every row's existence, order and target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
CORPUS="$SCRIPT_DIR/rust/tests/corpus"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-corpus.XXXXXX")"
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

echo "interdimux corpus parity tests (both renderers, no server)"
echo

# --- known divergences ------------------------------------------------------
# Byte parity is NOT asserted for these, and only these.  Each must still emit
# the same rows in the same order with the same SPEC field (so a dropped or
# extra row cannot hide here), every row with exactly four fields.
#
#   cjk, emoji   wide glyphs.  bash measures ${#var} -- characters -- and a CJK
#                character or an emoji cluster is two cells, so bash's columns
#                shift and it draws no session rule for a non-ASCII name.  The
#                documented intentional divergence (rust/README.md); the bash
#                width model is frozen rather than given a width table.
KNOWN_DIVERGENT=" cjk emoji "

# --- a tmux that must never run ---------------------------------------------
mkdir -p "$TMPD/stub"
cat > "$TMPD/stub/tmux" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPD/tmux-calls"
exit 1
STUB
chmod +x "$TMPD/stub/tmux"

# --- golden.rs's environment, verbatim ---------------------------------------
# plus what the SCRIPT needs to start at all: a TMUX (pointing at nothing), the
# version pins the launcher would forward, OPTS_PRIMED so it never asks tmux for
# options, and a UTF-8 locale -- bash counts characters only under one.
GENV=(
  HOME=/home/u
  PATH="$TMPD/stub:$PATH"
  LANG=C.UTF-8 LC_ALL=C.UTF-8
  INTERDIMUX_NOW=1700086400
  INTERDIMUX_SHOW_PREVIEW=off
  INTERDIMUX_SHOW_FULL_COMMAND=off
  INTERDIMUX_SHOW_GIT_BRANCH=off
  INTERDIMUX_SHOW_DIRS=off
  INTERDIMUX_ORDER=mru
  INTERDIMUX_COLOR_ACCENT=173 INTERDIMUX_COLOR_PATH=180 INTERDIMUX_COLOR_GIT=140
  INTERDIMUX_COLOR_SSH=109 INTERDIMUX_COLOR_EDITOR=150 INTERDIMUX_COLOR_DANGER=167
  INTERDIMUX_COLOR_TREE=240 INTERDIMUX_COLOR_SEPARATOR=245
)
SENV=(
  TMUX="$TMPD/no-server,1,0"
  INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
)

# $1 = dump, $2 = cols, $3 = rule on|off, $4 = on|off (the Rust core), rest = extra env
# The script reads its width from FZF_COLUMNS (what fzf exports to a reload)
# and hands the binary INTERDIMUX_COLS itself.
render_script() {
  local dump="$1" cols="$2" rule="$3" rust="$4"; shift 4
  env -i "${GENV[@]}" "${SENV[@]}" FZF_COLUMNS="$cols" INTERDIMUX_SESSION_RULE="$rule" \
      INTERDIMUX_USE_RUST="$rust" INTERDIMUX_DUMP_IN="$dump" "$@" \
      bash "$SCRIPT" --list
}
# The title rules the script ships, which it hands the binary itself -- read
# out of the script exactly as golden.rs reads them.
RULESET=$(awk "/^DEFAULT_TITLE_RULES='/ { on = 1; sub(/^DEFAULT_TITLE_RULES='/, \"\"); print; next }
               on && /^'\$/ { exit } on { print }" "$SCRIPT")
STATE_OPTS=$(sed -n "s/^DEFAULT_STATE_OPTS='\\(.*\\)'\$/\\1/p" "$SCRIPT")
# the binary alone, exactly as golden.rs runs it
render_bin() {
  local dump="$1" cols="$2" rule="$3"
  env -i "${GENV[@]}" INTERDIMUX_COLS="$cols" INTERDIMUX_SESSION_RULE="$rule" \
      INTERDIMUX_TITLE_RULESET="$RULESET" INTERDIMUX_STATE_OPTS="$STATE_OPTS" "$BIN" gather3 < "$dump"
}

# every row has exactly four tab-separated fields and a known spec kind
four_fields() {
  awk -F'\t' 'NF != 4 || $4 !~ /^[SWPD]:/ { bad = 1 } END { exit bad }' "$1"
}

strip() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }

dumps=()
for d in "$CORPUS"/*.dump; do dumps+=("$d"); done
if [ "${#dumps[@]}" -ge 8 ]; then
  report "the corpus is there (${#dumps[@]} dumps)" pass
else
  report "the corpus is there (${#dumps[@]} dumps, expected >= 8)" fail
fi

# --- 1. the bash renderer against the checked-in goldens ----------------------
# Needs no binary, so it runs on a cargo-less box too.  The width each golden was
# blessed at is golden.rs's: 120, except `bigindex`, which golden.rs pins to 52
# (the width at which its pane-id clamp engages).
for d in "${dumps[@]}"; do
  n=$(basename "$d" .dump)
  exp="$CORPUS/$n.expected"
  [ -f "$exp" ] || continue
  case "$KNOWN_DIVERGENT" in *" $n "*) continue ;; esac
  cols=120; [ "$n" = bigindex ] && cols=52
  render_script "$d" "$cols" on off > "$TMPD/out" 2> "$TMPD/err" || true
  if [ -s "$TMPD/err" ]; then
    report "golden $n: bash renders it without a word on stderr" fail
    ERRORS+="$(head -3 "$TMPD/err")"$'\n'
  elif cmp -s "$TMPD/out" "$exp"; then
    report "golden $n: the bash renderer matches the blessed rows byte for byte" pass
  else
    report "golden $n: the bash renderer matches the blessed rows byte for byte" fail
    ERRORS+="$(diff <(strip "$exp") <(strip "$TMPD/out") | head -6 || true)"$'\n'
  fi
done

# an empty server has no golden file (golden.rs asserts "no rows" directly)
render_script "$CORPUS/empty.dump" 120 on off > "$TMPD/out" 2> "$TMPD/err" || true
if [ ! -s "$TMPD/out" ] && [ ! -s "$TMPD/err" ]; then
  report "empty server: bash renders no rows and no error" pass
else
  report "empty server: bash renders no rows and no error" fail
  ERRORS+="$(head -3 "$TMPD/out" "$TMPD/err")"$'\n'
fi

# --- 2. both renderers across the geometry -----------------------------------
if [ ! -x "$BIN" ]; then
  echo "  (rust binary not built: the cross-renderer sweep is skipped)"
else
  # Widths from golden.rs's own sweeps: 40/52 are below the point where the
  # session rule switches itself off and where the pane-id clamp engages.
  for d in "${dumps[@]}"; do
    n=$(basename "$d" .dump)
    known=0; case "$KNOWN_DIVERGENT" in *" $n "*) known=1 ;; esac
    bad="" rows_b=0 rows_r=0
    for cols in 40 52 80 120 200; do
      for rule in on off; do
        render_script "$d" "$cols" "$rule" off > "$TMPD/b" 2> "$TMPD/berr" || true
        render_bin    "$d" "$cols" "$rule"     > "$TMPD/r" 2>/dev/null || true
        rows_b=$(wc -l < "$TMPD/b"); rows_r=$(wc -l < "$TMPD/r")
        if [ -s "$TMPD/berr" ]; then
          bad+=" ${cols}/${rule}:stderr"
        elif ! four_fields "$TMPD/b"; then
          bad+=" ${cols}/${rule}:fields"
        elif [ "$known" = 1 ]; then
          # the same rows, in the same order, naming the same targets
          cmp -s <(cut -f4 "$TMPD/b") <(cut -f4 "$TMPD/r") || bad+=" ${cols}/${rule}:specs"
        else
          cmp -s "$TMPD/b" "$TMPD/r" || bad+=" ${cols}/${rule}:bytes"
        fi
      done
    done
    if [ "$known" = 1 ]; then
      label="$n (known divergence: rows and targets only)"
    else
      label="$n: byte-identical"
    fi
    if [ -z "$bad" ]; then
      report "sweep $label at 40-200 cols, rule on/off ($rows_r rows)" pass
    else
      report "sweep $label at 40-200 cols, rule on/off (differs at:$bad)" fail
      ERRORS+="$(diff <(strip "$TMPD/r") <(strip "$TMPD/b") | head -6 || true)"$'\n'
    fi
  done

  # --- 3. the real pipeline: bash fetches, the binary renders -----------------
  # The dump through the script with the core enabled is what a user's reload
  # runs; it must be exactly what the binary makes of the same dump on stdin, or
  # the seam is not delivering the sections the way tmux does.
  bad=""
  for d in "${dumps[@]}"; do
    n=$(basename "$d" .dump)
    render_script "$d" 120 on on > "$TMPD/p" 2>/dev/null || true
    render_bin    "$d" 120 on    > "$TMPD/r" 2>/dev/null || true
    cmp -s "$TMPD/p" "$TMPD/r" || bad+=" $n"
  done
  if [ -z "$bad" ]; then
    report "through the script, the core renders each dump exactly as on stdin" pass
  else
    report "through the script, the core renders each dump exactly as on stdin (differs:$bad)" fail
  fi
fi

# --- 3b. @interdimux-hide next to a Latin-1 start directory -------------------
# The hide filter runs in the script, ahead of either renderer, over the same
# session lines whose last field is a raw #{session_path}.  In latin1.dump two
# of those end in a Latin-1 byte, each followed by another session; hiding any
# one of them must hide exactly that session, in both renderers (review
# BUG-111: bash's `read` had joined the line after such a path onto it).
for h in cafe naive zulu; do
  want=" "; for sn in cafe naive zulu after; do [ "$sn" = "$h" ] || want+="S:$sn "; done
  render_script "$CORPUS/latin1.dump" 120 on off INTERDIMUX_HIDE="$h" > "$TMPD/hb" 2>/dev/null || true
  got=" $(grep -o $'\tS:[^\t]*$' "$TMPD/hb" | tr -d '\t' | tr '\n' ' ')"
  bad=""
  [ "$got" = "$want" ] || bad+=" bash sessions:[$got] want [$want]"
  if [ -x "$BIN" ]; then
    render_script "$CORPUS/latin1.dump" 120 on on INTERDIMUX_HIDE="$h" > "$TMPD/hr" 2>/dev/null || true
    cmp -s "$TMPD/hb" "$TMPD/hr" || bad+=" bash and rust differ"
  fi
  if [ -z "$bad" ]; then
    report "latin1, @interdimux-hide '$h': exactly that session goes" pass
  else
    report "latin1, @interdimux-hide '$h': exactly that session goes ($bad)" fail
  fi
done

# --- 4. the seam itself -------------------------------------------------------
# INTERDIMUX_NO_BATCH selects the four-query fetch path; a dump serves that path
# too, identically, rather than dropping through to tmux.
render_script "$CORPUS/basic.dump" 120 on off > "$TMPD/a" 2>/dev/null || true
render_script "$CORPUS/basic.dump" 120 on off INTERDIMUX_NO_BATCH=1 > "$TMPD/nb" 2>/dev/null || true
if [ -s "$TMPD/a" ] && cmp -s "$TMPD/a" "$TMPD/nb"; then
  report "the dump serves the unbatched fetch path too" pass
else
  report "the dump serves the unbatched fetch path too" fail
fi

# A dump with a stray RS (a cwd containing \x1e) is mis-framed.  Live, bash would
# re-query tmux section by section; a dump has no second source, so it must
# render NOTHING and say why -- never a shifted list, never a live server's.
printf 's\x1f1700000000\x1f1\x1f\n\x1e\ns\x1f0\x1fw\x1f1\x1fsh\x1f/tmp/a\x1eb\x1f1\x1f0\x1f000\n\x1e\n\x1e\ns\x1f0\x1f0\n\x1e\n' > "$TMPD/stray.dump"
render_script "$TMPD/stray.dump" 120 on off > "$TMPD/out" 2> "$TMPD/err" || true
if [ ! -s "$TMPD/out" ] && grep -q 'expected 4 or 5 sections, got 6' "$TMPD/err"; then
  report "a mis-framed dump renders nothing and says so" pass
else
  report "a mis-framed dump renders nothing and says so" fail
  ERRORS+="$(head -3 "$TMPD/out" "$TMPD/err")"$'\n'
fi
render_script "$TMPD/does-not-exist.dump" 120 on off > "$TMPD/out" 2> "$TMPD/err" || true
if [ ! -s "$TMPD/out" ] && grep -q 'cannot read' "$TMPD/err"; then
  report "an unreadable dump renders nothing and says so" pass
else
  report "an unreadable dump renders nothing and says so" fail
fi

# Last: nothing above may have reached for tmux.
if [ ! -e "$TMPD/tmux-calls" ]; then
  report "no render asked tmux for anything" pass
else
  report "no render asked tmux for anything ($(wc -l < "$TMPD/tmux-calls") calls)" fail
  ERRORS+="$(head -3 "$TMPD/tmux-calls")"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
