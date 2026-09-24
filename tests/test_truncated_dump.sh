#!/usr/bin/env bash
#
# Lines tmux cut short must not cost the row.
#
# tmux gives every list-* line a 100 ms wall-clock budget (format.c,
# FORMAT_TIME_LIMIT) and, when the server is descheduled for that long in the
# middle of one, returns the line cut at the next '#{' -- with no error.  It
# takes a starved server, so it cannot be provoked on demand without SIGSTOPping
# tmux; instead a PATH shim for tmux cuts ONE line of the real server's output
# exactly the way tmux does (keep the first K fields and the separator after
# them).  Before the fix:
#   * a cut window line: the Rust core dropped the window (and its panes); the
#     bash renderer printed "[: : integer expression expected" into the
#     navigator's stderr, i.e. into errors.log, keeping --doctor red
#   * a cut pane line: the Rust core dropped the pane
#   * a cut session line: the session had no name (the timestamp came first),
#     so BOTH renderers dropped it with every window under it
# Both renderers are checked; the shim delegates everything else to real tmux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-trunc-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-trunc.XXXXXX")"
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

echo "interdimux truncated-dump tests"
echo

REAL_TMUX="$(command -v tmux)"
mkdir -p "$TMPD/shim" "$TMPD/home" "$TMPD/data"
# SHIM_CUT=KIND/FIRST/K cuts the first matching line to its first K fields plus
# the separator that followed them.  KIND picks the line by shape:
#   s  a session line (4 or 5 fields) naming FIRST in field 1 or 2 (field 2
#      is where the name sat before it moved to the front)
#   w  a window line (9 fields), p  a pane line (8 fields): field 1 is FIRST
#   v  the --preview window list (5 fields)
cat > "$TMPD/shim/tmux" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" list-windows "*|*" list-panes "*|*" list-sessions "*)
    out=\$("$REAL_TMUX" "\$@"); rc=\$?
    if [ -n "\${SHIM_CUT:-}" ]; then
      out=\$(printf '%s\n' "\$out" | awk -F\$'\x1f' -v OFS=\$'\x1f' -v spec="\$SHIM_CUT" '
        BEGIN { split(spec, b, "/"); ty = b[1]; who = b[2]; k = b[3] + 0; done = 0 }
        function cut(   i, l) { l = ""; for (i = 1; i <= k; i++) l = l \$i OFS; print l; done = 1 }
        done { print; next }
        (ty == "s" && (NF == 4 || NF == 5) && (\$1 == who || \$2 == who)) \\
          || (\$1 == who && ((ty == "w" && NF == 9) || (ty == "p" && NF == 8) \\
                            || (ty == "v" && NF == 5))) { cut(); next }
        { print }')
    fi
    printf '%s\n' "\$out"; exit \$rc ;;
  *) exec "$REAL_TMUX" "\$@" ;;
esac
EOF
chmod +x "$TMPD/shim/tmux"

PANECMD='sleep 99999'
tmux -f /dev/null -L "$SOCK" new-session -d -s s1 -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" new-session -d -s s2 -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" split-window -d -t '=s2:0' -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" rename-window -t '=s2:0' split
tmux -L "$SOCK" new-window -d -t '=s2:' -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" new-session -d -s s3 -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=s1:0' -F '#{pane_id}' | head -1)"
export HOME="$TMPD/home" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off
wait_for "the bench panes" sh -c "[ \"\$(tmux -L '$SOCK' list-panes -a | wc -l)\" -ge 5 ]"

# Control: without a cut, the shim is transparent -- and the bench has the rows
# every case below expects.
base=$(PATH="$TMPD/shim:$PATH" INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list 2>/dev/null | cut -f4 | tr '\n' ' ')
case "$base" in
  *"W:s2:0 P:s2:0:0 P:s2:0:1 W:s2:1"*) report "control: the shim is transparent without a cut" pass ;;
  *) report "control: the shim is transparent without a cut (got: $base)" fail ;;
esac

renderers="off"
if [ -x "$BIN" ]; then renderers="on off"; else echo "  (rust binary not built: bash renderer only)"; fi

# $1 = on|off, $2 = SHIM_CUT; sets ROWS (the spec column, space-joined) and ERR
list_cut() {
  ROWS=$(PATH="$TMPD/shim:$PATH" SHIM_CUT="$2" INTERDIMUX_USE_RUST="$1" \
         bash "$SCRIPT" --list 2>"$TMPD/err" | cut -f4 | tr '\n' ' ')
  ERR=$(cat "$TMPD/err")
}

has() { case " $ROWS" in *" $1 "*) return 0 ;; esac; return 1; }

for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)

  # the window line of s2:0, cut before #{pane_current_path} (5 fields kept):
  # the shape observed on a real server, where #{pane_current_command} -- a
  # /proc read -- is what runs out the clock
  list_cut "$r" "w/s2/5"
  has "W:s2:0" && report "$label: a window line cut short still renders its window" pass \
               || report "$label: a window line cut short still renders its window (got: $ROWS)" fail
  has "W:s2:1" && has "S:s3" && report "$label: ...and the rows after it" pass \
                             || report "$label: ...and the rows after it (got: $ROWS)" fail
  [ -z "$ERR" ] && report "$label: a cut window line writes nothing to stderr" pass \
                || report "$label: a cut window line writes nothing to stderr (got: $ERR)" fail

  # an earlier cut: before #{pane_current_command}
  list_cut "$r" "w/s2/4"
  has "W:s2:0" && [ -z "$ERR" ] && report "$label: a window line cut before its command still renders" pass \
               || report "$label: a window line cut before its command still renders (got: $ROWS / $ERR)" fail

  # the first pane line of s2, cut the same way
  list_cut "$r" "p/s2/5"
  has "P:s2:0:0" && has "P:s2:0:1" && report "$label: a pane line cut short still renders its pane" pass \
                                   || report "$label: a pane line cut short still renders its pane (got: $ROWS)" fail
  [ -z "$ERR" ] && report "$label: a cut pane line writes nothing to stderr" pass \
                || report "$label: a cut pane line writes nothing to stderr (got: $ERR)" fail

  # the session line of s2, cut right after its name
  list_cut "$r" "s/s2/1"
  has "S:s2" && report "$label: a session line cut after its name keeps the session" pass \
             || report "$label: a session line cut after its name keeps the session (got: $ROWS)" fail
  has "W:s2:0" && has "P:s2:0:1" && has "W:s2:1" \
    && report "$label: ...and every window and pane under it" pass \
    || report "$label: ...and every window and pane under it (got: $ROWS)" fail
done

# The other short line there is: a newline in a pane's cwd splits ONE window
# line into two, and the second half -- `victim^_<panes>^_<pid>^_<flags>` --
# starts with whatever follows the newline.  Accepting cut lines must not turn
# that into a window of a session that happens to be called `victim`: the bash
# renderer used to draw exactly that phantom (W:victim:1, named after a pid).
nldir="$TMPD/home/nl"$'\n'"victim"
mkdir -p "$nldir"
tmux -L "$SOCK" new-session -d -s victim -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" new-window -d -t '=s3:' -c "$nldir" "$PANECMD"
wait_for "the newline cwd to be reported" sh -c "tmux -L '$SOCK' list-windows -t '=s3:' -F '#{pane_current_path}' | grep -qx victim"
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  ROWS=$(INTERDIMUX_USE_RUST="$r" bash "$SCRIPT" --list 2>"$TMPD/err" | cut -f4 | tr '\n' ' ')
  ERR=$(cat "$TMPD/err")
  victim_rows=$(printf '%s\n' $ROWS | grep -c '^W:victim:' || true)
  if has "W:s3:1" && [ "$victim_rows" = 1 ] && [ -z "$ERR" ]; then
    report "$label: a newline in a cwd renders its window once, with no phantom" pass
  else
    report "$label: a newline in a cwd renders its window once, with no phantom (got: $ROWS / $ERR)" fail
  fi
done

# The session preview reads its own window list; a cut line there printed the
# same "integer expression expected" into the preview pane.
out=$(PATH="$TMPD/shim:$PATH" SHIM_CUT="v/0:split/3" FZF_PREVIEW_COLUMNS=80 \
      bash "$SCRIPT" --preview 'S:s2' 2>&1 >/dev/null || true)
[ -z "$out" ] && report "--preview: a cut window line writes nothing to stderr" pass \
              || report "--preview: a cut window line writes nothing to stderr (got: $out)" fail

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
