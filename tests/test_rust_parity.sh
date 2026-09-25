#!/usr/bin/env bash
#
# The Rust core and the bash renderer must produce byte-identical rows.
#
# bash keeps its own renderer as the fallback for anyone without the binary, so
# the two implementations have to stay in step.  This sweeps the configuration
# space that changes the output — column widths, preview on/off, git badges,
# full-command resolution, MRU vs index ordering, directory rows — and diffs
# them, with a bash-vs-bash control on every case so a churning bench cannot
# produce a false pass.
#
# Skips cleanly when the binary has not been built.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-parity-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-parity.XXXXXX")"
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

echo "interdimux rust/bash parity tests"
echo

if [ ! -x "$BIN" ]; then
  echo "  (skipped: $BIN not built — run 'cargo build --release' in rust/)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# --- bench: mixed shapes, plus names and paths that have broken things before -
PANECMD='bash --norc --noprofile -c "sleep 99999 & wait"'
tmux -f /dev/null -L "$SOCK" new-session -d -s q01 -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
# The two windows below start the DEFAULT command; without this that is the
# user's login shell, rc files and all.  And names are frozen at creation: see
# bench_settled for why a name cannot be waited for.
tmux -L "$SOCK" set -g default-command 'bash --norc --noprofile -i'
tmux -L "$SOCK" set -g automatic-rename off
for i in 02 03 04 05 06 07 08; do
  tmux -L "$SOCK" new-session -d -s "q$i" -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
done
for i in 01 02 03 04 05 06 07 08; do
  tmux -L "$SOCK" new-window  -d -t "=q$i:" -c "$SCRIPT_DIR" "$PANECMD"
  tmux -L "$SOCK" split-window -d -t "=q$i:1" -c "$SCRIPT_DIR" "$PANECMD" 2>/dev/null || true
done
# shapes the uniform panes miss
tmux -L "$SOCK" new-window -d -t '=q01:' -n fg -c "$SCRIPT_DIR"
tmux -L "$SOCK" send-keys  -t '=q01:fg' 'sleep 900' Enter
tmux -L "$SOCK" new-window -d -t '=q01:' -n idle -c "$SCRIPT_DIR"
tmux -L "$SOCK" new-session -d -s 'has space'   -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
tmux -L "$SOCK" new-session -d -s 'has"quote'   -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
tmux -L "$SOCK" new-session -d -s 'a-very-long-session-name-that-will-be-truncated' \
     -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
deep="$TMPD/a/very/deep/nested/directory/structure/for/path/trimming"
mkdir -p "$deep"
tmux -L "$SOCK" new-session -d -s deep -x 200 -y 50 -c "$deep" "$PANECMD"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=q01:1' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export XDG_DATA_HOME="$TMPD/data"
mkdir -p "$XDG_DATA_HOME/interdimux"
mkdir -p "$TMPD/rustproj" && printf '[package]\n' > "$TMPD/rustproj/Cargo.toml"
mkdir -p "$TMPD/gitproj/.git" && printf 'ref: refs/heads/parity-branch\n' > "$TMPD/gitproj/.git/HEAD"
# a directory whose name is not UTF-8: neither renderer may offer it (fzf would
# hand the selection back with U+FFFD in place of the byte, naming nothing)
mkdir -p "$TMPD/nonutf8-"$'\377'
printf '%s\n%s\n%s\n' "$TMPD/rustproj" "$TMPD/nonutf8-"$'\377' "$TMPD/gitproj" > "$XDG_DATA_HOME/interdimux/recent_dirs"

# --- the shapes where the two renderers used to DISAGREE ----------------------
# A bench of well-behaved ASCII passes byte-for-byte while the fallback renderer
# is wrong (review TEST-04).  Every fixture below is a case the two once rendered
# differently; each is also asserted on its own further down, against what the
# row must say -- not just against the other renderer.  Named windows (-n), so
# automatic-rename cannot churn them between two renders.
H="$TMPD/h"
mkdir -p "$H"
# a branch longer than the badge, on a ZOOMED window: the Z flag and the cut
# branch once shared the badge's budget and came out two cells apart
mkdir -p "$H/longrepo/.git" && printf 'ref: refs/heads/feature/a-really-long-branch\n' > "$H/longrepo/.git/HEAD"
# a HEAD written without its trailing newline (bash's `read` reports EOF on it)
mkdir -p "$H/nonl/.git" && printf 'ref: refs/heads/no-newline' > "$H/nonl/.git/HEAD"
# an EMPTY .git inside a repository: not a repository, so the outer one's branch
mkdir -p "$H/outer/.git" "$H/outer/inner/.git" && printf 'ref: refs/heads/outer-main\n' > "$H/outer/.git/HEAD"
# a worktree-style .git FILE without a newline, whose HEAD is CRLF
mkdir -p "$H/realgit" "$H/wt" && printf 'ref: refs/heads/wt-branch\r\n' > "$H/realgit/HEAD"
printf 'gitdir: %s' "$H/realgit" > "$H/wt/.git"
# a TAB in a ref name: once a FIVE-field row
mkdir -p "$H/tabhead/.git" && printf 'ref: refs/heads/a\tb\n' > "$H/tabhead/.git/HEAD"
# control bytes in a cwd: ESC (a live escape in the popup), CR, TAB, and US --
# the tmux field delimiter, which shifted every later field of a bash row
ESCD="$H/esc"$'\e'"[31mred"; CRD="$H/cr"$'\r'"z"; TABD="$H/tab"$'\t'"dir"; USD="$H/us"$'\x1f'"part2"
mkdir -p "$ESCD" "$CRD" "$TABD" "$USD"
tmux -L "$SOCK" new-session -d -s longbr  -n zoomed -x 200 -y 50 -c "$H/longrepo" "$PANECMD"
tmux -L "$SOCK" split-window -d -t '=longbr:0' -c "$H/longrepo" "$PANECMD"
tmux -L "$SOCK" resize-pane -Z -t '=longbr:0.0'
tmux -L "$SOCK" new-session -d -s nonl    -n w -x 200 -y 50 -c "$H/nonl"        "$PANECMD"
tmux -L "$SOCK" new-session -d -s inner   -n w -x 200 -y 50 -c "$H/outer/inner" "$PANECMD"
tmux -L "$SOCK" new-session -d -s wt      -n w -x 200 -y 50 -c "$H/wt"          "$PANECMD"
tmux -L "$SOCK" new-session -d -s tabhead -n w -x 200 -y 50 -c "$H/tabhead"     "$PANECMD"
tmux -L "$SOCK" new-session -d -s escsess -n w -x 200 -y 50 -c "$ESCD" "$PANECMD"
tmux -L "$SOCK" new-session -d -s crsess  -n w -x 200 -y 50 -c "$CRD"  "$PANECMD"
tmux -L "$SOCK" new-session -d -s tabsess -n w -x 200 -y 50 -c "$TABD" "$PANECMD"
tmux -L "$SOCK" new-session -d -s ussess  -n w -x 200 -y 50 -c "$USD"  "$PANECMD"
# ...and a US in ONE pane of a split window: that pane's row goes, not its sibling's
tmux -L "$SOCK" new-session -d -s uspane  -n w -x 200 -y 50 -c "$H"    "$PANECMD"
tmux -L "$SOCK" split-window -d -t '=uspane:0' -c "$USD" "$PANECMD"

# Settled, rather than a fixed sleep (which this was: `sleep 4`).  What a row
# shows that is still moving just after the bench is built:
#   * a pane's cwd -- tmux lists the pane before /proc has its cwd
#   * a pane's command -- "tmux" until the forked child has exec'd
#   * the full command -- `bash -c "sleep … & wait"` until bash has forked
#   * q01:fg's foreground command, typed into an interactive shell
# Window NAMES are frozen instead (automatic-rename off, above): a name follows
# its pane's output a timer tick behind, and these panes print nothing, so
# there is no condition to wait for -- only a race to remove.  The bash-vs-bash
# control in run_case still catches any churn, but as a FAILURE.
bench_settled() {
  local line pid start
  while IFS='|' read -r line pid start; do
    case "$line" in nocwd*|*' '|*' tmux') return 1 ;; esac
    case "$start" in
      *'sleep 99999 & wait'*) pgrep -P "$pid" >/dev/null 2>&1 || return 1 ;;
    esac
  done < <(tmux -L "$SOCK" list-panes -a \
             -F '#{?pane_current_path,cwd,nocwd} #{pane_current_command}|#{pane_pid}|#{pane_start_command}' 2>/dev/null)
  [ "$(tmux -L "$SOCK" display-message -p -t '=q01:fg' '#{pane_current_command}' 2>/dev/null)" = sleep ]
}
settled=0
for _i in $(seq 1 150); do
  if bench_settled; then settled=1; break; fi
  sleep 0.1
done
if [ "$settled" = 1 ]; then
  report "bench settled: every pane has its cwd and its command" pass
else
  report "bench settled: every pane has its cwd and its command (timed out)" fail
fi

rows=$(INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
if [ "$rows" -ge 45 ]; then
  report "bench built ($rows rows)" pass
else
  report "bench built ($rows rows, expected >= 45)" fail
fi

# --- the sweep ----------------------------------------------------------------
# Each case: a label and the env that distinguishes it.
run_case() {
  local label="$1"; shift
  local b1="$TMPD/b1" b2="$TMPD/b2" r="$TMPD/r"
  env "$@" INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list > "$b1" 2>/dev/null || true
  env "$@"                        bash "$SCRIPT" --list > "$r"  2>/dev/null || true
  env "$@" INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list > "$b2" 2>/dev/null || true
  if ! cmp -s "$b1" "$b2"; then
    report "$label — CONTROL FAILED (bash vs bash differs; bench churning)" fail
    return
  fi
  if cmp -s "$b1" "$r"; then
    report "$label" pass
  else
    report "$label" fail
    ERRORS+="$(diff <(sed 's/\x1b\[[0-9;]*m//g' "$b1") <(sed 's/\x1b\[[0-9;]*m//g' "$r") | head -6 || true)"$'\n'
  fi
}

run_case "defaults"                     INTERDIMUX_SHOW_DIRS=off
run_case "full command resolution on"   INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_FULL_COMMAND=on
run_case "full command resolution off"  INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_FULL_COMMAND=off
# Force the ps backend on BOTH sides: rust's ps snapshot vs bash's ps table.
# On Linux this is the only case that exercises the ps backend (the default
# uses /proc); on macOS/BSD it is what every open runs.
run_case "full command via ps backend"  INTERDIMUX_SHOW_DIRS=off INTERDIMUX_FORCE_PS=1 INTERDIMUX_SHOW_FULL_COMMAND=on
run_case "git badges on"                INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_GIT_BRANCH=on
run_case "git badges off"               INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_GIT_BRANCH=off
run_case "preview on (half width)"      INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=on
run_case "index ordering"               INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index
run_case "directory rows on"            INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off
run_case "directory rows + git"         INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on
# The session rule is a second layout regime: it moves the meta into the command
# column when there is one, and switches itself off when the squeeze runs out of
# room.  Both renderers have to agree about WHICH regime they are in.
run_case "session rule off"             INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SESSION_RULE=off
run_case "custom palette (hex)"         INTERDIMUX_SHOW_DIRS=off INTERDIMUX_COLOR_ACCENT='#e78a4e' INTERDIMUX_COLOR_PATH='#d8a657'
run_case "palette inherit (-1)"         INTERDIMUX_SHOW_DIRS=off INTERDIMUX_COLOR_ACCENT=-1 INTERDIMUX_COLOR_TREE=default

# widths are the most output-sensitive input: sweep the popup geometry
# 40/44/52 sit BELOW the width where the squeeze still fits a command column,
# which is exactly where the session rule turns itself off — the regime boundary
# is the interesting place for two renderers to disagree.
for cols in 40 44 52 60 80 100 120 160 200 260; do
  run_case "width ${cols} cols" INTERDIMUX_SHOW_DIRS=off FZF_COLUMNS="$cols"
done
for cols in 80 120 200; do
  run_case "width ${cols} cols + preview" INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=on FZF_COLUMNS="$cols"
done
run_case "hostile fixtures, git badges, 200 cols" INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_GIT_BRANCH=on FZF_COLUMNS=200

# --- the hostile fixtures, row by row, in EACH renderer ------------------------
# Byte parity says the two agree; it cannot say they are right -- both could
# drop a row, or both leak an ESC.  So each renderer is also held to what the
# fixture itself says the row must show.
kinds() { awk -F'\t' '{ n[substr($4, 1, 1)]++ } END { printf "S=%d W=%d P=%d D=%d", n["S"], n["W"], n["P"], n["D"] }' "$1"; }
ctx_of() { awk -F'\t' -v s="$2" '$4 == s { print $2 }' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
has_spec() { awk -F'\t' -v s="$2" '$4 == s { f = 1 } END { exit !f }' "$1"; }
for r in rust bash; do
  out="$TMPD/hostile.$r"
  if [ "$r" = bash ]; then u=off; else u=on; fi
  INTERDIMUX_USE_RUST=$u INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_GIT_BRANCH=on FZF_COLUMNS=200 \
    bash "$SCRIPT" --list > "$out" 2> "$TMPD/hostile.$r.err" || true

  if [ -s "$TMPD/hostile.$r.err" ]; then
    report "[$r] the hostile bench renders with nothing on stderr" fail
    ERRORS+="    $(head -2 "$TMPD/hostile.$r.err")"$'\n'
  else
    report "[$r] the hostile bench renders with nothing on stderr" pass
  fi
  if awk -F'\t' 'NF != 4 { bad = 1 } END { exit bad }' "$out"; then
    report "[$r] every row has exactly four fields (a TAB in a ref name or a cwd included)" pass
  else
    report "[$r] every row has exactly four fields (a TAB in a ref name or a cwd included)" fail
  fi
  # With the palette's own SGR sequences removed, and the tab delimiters and
  # newlines, nothing may be left that is not printable: every control byte a
  # cwd or a HEAD carried has to have been neutralised on the way.
  ctl=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | tr -d '\t\n' | LC_ALL=C tr -d '\040-\176\200-\377' | wc -c)
  if [ "$ctl" -eq 0 ]; then
    report "[$r] no raw control byte reaches a row (ESC, CR, TAB in cwds and HEAD)" pass
  else
    report "[$r] no raw control byte reaches a row ($ctl found)" fail
  fi
  for want in "W:escsess:0:esc?[31mred" "W:crsess:0:cr?z" "W:tabsess:0:tab?dir" \
              "W:nonl:0:‹no-newline›" "W:inner:0:‹outer-main›" "W:wt:0:‹wt-branch›" \
              "W:tabhead:0:‹a?b›"; do
    spec="${want%:*}"; frag="${want##*:}"
    got=$(ctx_of "$out" "$spec")
    case "$got" in
      *"$frag"*) report "[$r] $spec shows $frag" pass ;;
      *) report "[$r] $spec shows $frag (got: $(printf '%s' "$got" | cat -v | tr -s ' '))" fail ;;
    esac
  done
  got=$(ctx_of "$out" "W:longbr:0")
  case "$got" in
    *"‹feature/"*"…›"*) ;;
    *) got="NO-BADGE $got" ;;
  esac
  case "$got" in
    *" Z "*"‹feature/"*) report "[$r] a zoomed window keeps its Z and a cut long branch" pass ;;
    *) report "[$r] a zoomed window keeps its Z and a cut long branch (got: $(printf '%s' "$got" | tr -s ' '))" fail ;;
  esac
  # A US in a cwd leaves no telling which separator is the path's: the row goes
  # (and only that row), never rendered from shifted fields.
  if has_spec "$out" "S:ussess" && ! has_spec "$out" "W:ussess:0"; then
    report "[$r] a window whose cwd holds a US is dropped, its session kept" pass
  else
    report "[$r] a window whose cwd holds a US is dropped, its session kept" fail
  fi
  if has_spec "$out" "P:uspane:0:0" && ! has_spec "$out" "P:uspane:0:1"; then
    report "[$r] ...and a pane whose cwd holds one, not its sibling" pass
  else
    report "[$r] ...and a pane whose cwd holds one, not its sibling" fail
  fi
done
if [ "$(kinds "$TMPD/hostile.rust")" = "$(kinds "$TMPD/hostile.bash")" ]; then
  report "both renderers emit the same S:/W:/P:/D: row counts ($(kinds "$TMPD/hostile.bash"))" pass
else
  report "both renderers emit the same S:/W:/P:/D: row counts (rust $(kinds "$TMPD/hostile.rust"), bash $(kinds "$TMPD/hostile.bash"))" fail
fi

# --- locale: neither renderer may depend on it ---------------------------------
#
# This suite was developed under C.UTF-8 and passed 30/30 there while failing
# 20/30 on an ordinary desktop, which is as close to useless as a parity suite
# gets.  The cause: the MRU key is `session_last_attached`, which has one-second
# resolution, so ties are routine — and GNU sort breaks a tie with its
# "last-resort comparison", which compares the WHOLE LINE under the user's
# collation.  The Rust core sorts stably and keeps tmux's order.  glibc's en_US
# ignores punctuation at the first collation level, so `has space` and
# `has"quote` compare as `hasspace` vs `hasquote` and swap; under C.UTF-8 they
# do not.  Both of those names are in the bench above, which is why it showed up
# at all.
#
# The locale is chosen by PROBING for the property that matters — a collation
# that differs from C's — rather than by parsing `locale -a`, whose spelling
# varies (`en_US.utf8` vs `en_US.UTF-8`) and whose presence does not imply the
# collation is actually different.
collation_differs() { # $1 = locale name
  local c alt
  c=$(printf 'has space\nhas"quote\n' | LC_ALL=C sort 2>/dev/null | head -1)
  alt=$(printf 'has space\nhas"quote\n' | LC_ALL="$1" sort 2>/dev/null | head -1)
  [ -n "$alt" ] && [ "$c" != "$alt" ]
}
ALT_LOCALE=""
for _l in en_US.UTF-8 en_US.utf8 en_GB.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 C.UTF-8; do
  if collation_differs "$_l"; then ALT_LOCALE="$_l"; break; fi
done
# The BASELINE is probed too, not hardcoded.  `C.UTF-8` does not exist on macOS —
# setlocale falls back to `C` there, so a hardcoded baseline would silently be
# comparing something other than what it says it is.  Both members of the pair
# have to be locales this box actually has.
BASE_LOCALE=C
for _l in C.UTF-8 C.utf8; do
  if [ "$(LC_ALL="$_l" locale charmap 2>/dev/null)" = "UTF-8" ]; then BASE_LOCALE="$_l"; break; fi
done

# The `-s` itself, asserted structurally and unconditionally.  Everything below
# needs a second locale to exist, and on a musl or C-only box none does — which
# would silently take the whole regression suite for this fix with it (measured:
# 31 assertions instead of 36, exit 0, with the `-s` also removed).  This one
# assertion cannot be skipped, and it covers BOTH sort sites — the kill-fallback
# MRU hop is not reachable from any case below.
# (Any numeric-reverse key, not `-k1,1nr` literally: the timestamp became field
# 2 when the session name moved to the front, and a pattern pinned to the old
# key would have matched nothing -- and passed -- from then on.  So the count
# of sort sites is asserted too.)
unstable=$(grep -nE "sort .*-k[0-9]+,[0-9]+nr" "$SCRIPT" | grep -v 'sort -s' || true)
mru_sorts=$(grep -cE "sort .*-k[0-9]+,[0-9]+nr" "$SCRIPT" || true)
if [ -z "$unstable" ] && [ "$mru_sorts" -ge 2 ]; then
  report "every MRU sort is stable (-s), including the kill-fallback hop" pass
else
  report "every MRU sort is stable (-s), including the kill-fallback hop" fail
  ERRORS+="$(printf '%s\n' "$unstable" | sed 's/^/     /')"$'\n'
fi

if [ -z "$ALT_LOCALE" ]; then
  # An echo, not a passing assertion: a skip dressed as a ✓ is how a suite comes
  # to report success for work it did not do.
  echo "  (skipped the locale cases: no installed locale collates differently from C)"
else
  report "comparing $BASE_LOCALE against $ALT_LOCALE, whose collation differs" pass

  # The direct regression: the two renderers must still agree under it.
  run_case "collation locale ($ALT_LOCALE)"          INTERDIMUX_SHOW_DIRS=off LC_ALL="$ALT_LOCALE"
  run_case "collation locale + dir rows"             INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off LC_ALL="$ALT_LOCALE"
  run_case "collation locale, index ordering"        INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index LC_ALL="$ALT_LOCALE"

  # ...and the stronger statement, which is the one that would have caught this
  # even with a single renderer: the OUTPUT itself must not move with the
  # locale.  Checked for each renderer separately, so a divergence names which.
  # The clock is PINNED across the pair.  Unlike run_case, this comparison has no
  # bash-vs-bash control to notice churn, and the rows carry age_of's token, which
  # flips at 90 s and then every 60 s — so a boundary landing between the two
  # renders would be reported as a locale failure.  INTERDIMUX_NOW is the seam the
  # renderer already exposes for exactly this (see the comment above age_of).
  _pin=$(date +%s)
  for _r in "rust:" "bash:INTERDIMUX_USE_RUST=off"; do
    _label="${_r%%:*}"; _env="${_r#*:}"
    _c="$TMPD/loc_c" _a="$TMPD/loc_alt"
    # shellcheck disable=SC2086
    env $_env INTERDIMUX_SHOW_DIRS=off INTERDIMUX_NOW="$_pin" LC_ALL="$BASE_LOCALE" bash "$SCRIPT" --list > "$_c" 2>/dev/null || true
    # shellcheck disable=SC2086
    env $_env INTERDIMUX_SHOW_DIRS=off INTERDIMUX_NOW="$_pin" LC_ALL="$ALT_LOCALE" bash "$SCRIPT" --list > "$_a" 2>/dev/null || true
    if [ ! -s "$_c" ]; then
      report "the $_label renderer produced rows to compare across locales" fail
    elif cmp -s "$_c" "$_a"; then
      report "the $_label renderer renders identically under $BASE_LOCALE and $ALT_LOCALE" pass
    else
      report "the $_label renderer renders identically under $BASE_LOCALE and $ALT_LOCALE" fail
      ERRORS+="$(diff <(sed 's/\x1b\[[0-9;]*m//g' "$_c") <(sed 's/\x1b\[[0-9;]*m//g' "$_a") | head -6 || true)"$'\n'
    fi
  done
fi

# The directory PICKER's tiers are still locale-collated (`sort -u` in
# emit_sorted_tiers) and deliberately so: that list has no second
# implementation to disagree with, and sorting a user's directory names by their
# own collation is the behaviour they want.  Only the tmux tree is pinned.

# --- failure modes: the binary must never turn into an empty picker ---------
broken="$TMPD/broken"; printf '#!/bin/sh\nexit 7\n' > "$broken"; chmod +x "$broken"
silent="$TMPD/silent"; printf '#!/bin/sh\nexit 0\n' > "$silent"; chmod +x "$silent"
want=$(INTERDIMUX_USE_RUST=off INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
got_b=$(INTERDIMUX_BIN="$broken" INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
got_s=$(INTERDIMUX_BIN="$silent" INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
[ "$got_b" = "$want" ] && report "a failing binary falls back to bash ($got_b rows)" pass \
                       || report "a failing binary falls back to bash (got $got_b, want $want)" fail
[ "$got_s" = "$want" ] && report "a silent binary falls back to bash ($got_s rows)" pass \
                       || report "a silent binary falls back to bash (got $got_s, want $want)" fail

# A pane cwd is arbitrary bytes on Linux; invalid UTF-8 must degrade one path,
# not blank the whole list.
# (`gather3`: the protocol the script speaks, IMUX_PROTO.  Under any other name
# the binary renders nothing, and 0 = 0 would pass -- hence the -ge 1.)
bad=$(printf 'a\x1fb\x1f1\x1f\n\x1e\n\x1e\n\x1e\n\x1e\n' | "$BIN" gather3 2>/dev/null | wc -l)
badu=$(printf 'a\x1fb\x1f1\x1f\xff\xfe\n\x1e\n\x1e\n\x1e\n\x1e\n' | "$BIN" gather3 2>/dev/null | wc -l)
[ "$bad" -ge 1 ] && [ "$badu" = "$bad" ] && report "invalid UTF-8 input still renders its row" pass \
                     || report "invalid UTF-8 input still renders its row (got $badu, want $bad >= 1)" fail

# --- known divergences: the rows must still be the same rows -------------------
# Byte parity is NOT asserted for these, and only these.  Row-count and target
# parity is: the same S:/W:/P:/D: rows, in the same order, naming the same
# targets, four fields each -- so a dropped or extra row cannot hide here.
#
#   wide glyphs  bash pads by CHARACTERS (${#var}); a CJK character is two
#                cells, so bash's columns shift on such a row and it draws no
#                session rule for a non-ASCII name.  The documented intentional
#                divergence (rust/README.md, "Intentional divergences") and
#                docs/UI-EXPLORATION.md's "gap to close": the bash width model is
#                frozen rather than given a width table.  Added LAST, because a
#                wide path widens the path column of EVERY row, which would turn
#                each byte-parity case above into a failure.
#
# Not listed because not reachable here: the two display-only divergences of the
# macOS libproc backend that docs/PERFORMANCE.md accepts (child selection among
# setsid'd siblings, invalid-UTF-8 argv).
WIDE_S='日本語セッション'
mkdir -p "$TMPD/日本語パス" "$TMPD/日本語ディレクトリ"
tmux -L "$SOCK" new-session -d -s "$WIDE_S" -n '編集' -x 200 -y 50 -c "$TMPD/日本語パス" "$PANECMD"
tmux -L "$SOCK" split-window -d -t "=$WIDE_S:0" -c "$TMPD/日本語パス" "$PANECMD"
printf '%s\n' "$TMPD/日本語ディレクトリ" >> "$XDG_DATA_HOME/interdimux/recent_dirs"
for _i in $(seq 1 150); do
  case "$(tmux -L "$SOCK" list-panes -t "=$WIDE_S:0" -F '#{?pane_current_path,,nocwd}' 2>/dev/null)" in
    *nocwd*|'') sleep 0.1 ;;
    *) break ;;
  esac
done
for cols in 80 200; do
  env INTERDIMUX_USE_RUST=off INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on \
      FZF_COLUMNS="$cols" bash "$SCRIPT" --list > "$TMPD/wide.bash" 2>/dev/null || true
  env INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on \
      FZF_COLUMNS="$cols" bash "$SCRIPT" --list > "$TMPD/wide.rust" 2>/dev/null || true
  why=""
  has_spec "$TMPD/wide.bash" "W:$WIDE_S:0" && has_spec "$TMPD/wide.bash" "P:$WIDE_S:0:1" \
    && has_spec "$TMPD/wide.bash" "D:$TMPD/日本語ディレクトリ" || why+=" the wide rows are missing;"
  [ "$(kinds "$TMPD/wide.bash")" = "$(kinds "$TMPD/wide.rust")" ] \
    || why+=" counts rust $(kinds "$TMPD/wide.rust") vs bash $(kinds "$TMPD/wide.bash");"
  cmp -s <(cut -f4 "$TMPD/wide.bash") <(cut -f4 "$TMPD/wide.rust") || why+=" the spec columns differ;"
  for f in "$TMPD/wide.bash" "$TMPD/wide.rust"; do
    awk -F'\t' 'NF != 4 { bad = 1 } END { exit bad }' "$f" || why+=" a row without four fields in ${f##*.};"
  done
  if [ -z "$why" ]; then
    report "known divergence, wide glyphs at $cols cols: the same rows, targets and counts ($(kinds "$TMPD/wide.rust"))" pass
  else
    report "known divergence, wide glyphs at $cols cols:$why" fail
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
