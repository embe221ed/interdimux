#!/usr/bin/env bash
#
# What a list costs the bash renderer, in the one unit that does not depend on
# how busy the machine is: system calls.
#
#   * a pane's title and published options never pass through a `while read`
#     loop (review R09).  bash's `read` takes a here-string ONE BYTE per
#     read(2) -- it is a pipe -- and gather_targets used to append the pane
#     id, the title and ten option slots to every pane line that measure_widths
#     and the pane loop then read that way: each character of every title cost
#     about two system calls per list.  So the number of read(2) calls must
#     not grow with the titles' length.
#   * the callbacks fzf runs while you type and move -- the preview, the
#     footer, the zero-match description, the scope prompt -- never reach the
#     agent layer (review R15).  bash parses a script as it runs it, so a
#     callback that exits above those ~850 lines never parses them, and every
#     one of them paid ~2 ms to parse code that only a list draws with.  The
#     witness is bash's own execution trace (-x): the agent layer's first
#     top-level assignment, AGENT_KNOWN, is in the trace of a --list and must
#     not be in a callback's;
#   * the shortcut cmd_field takes for a row nothing can be added to (no
#     option published, no registry record, not an agent, no title a rule
#     reads -- review R09) is taken by no other row.  Each row below has
#     exactly one of those things, and must show it, in both renderers.
#
# No server: the list comes from a dump (INTERDIMUX_DUMP_IN, as in
# tests/test_corpus_parity.sh), with a tmux on PATH that logs and fails.
# The read(2) counts need strace; without it those cases are skipped, and say
# so.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-rcost.XXXXXX")" && pwd -P)"
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

echo "interdimux render cost tests"
echo

export LANG=C.UTF-8 LC_ALL=C.UTF-8

mkdir -p "$TMPD/stub"
cat > "$TMPD/stub/tmux" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPD/tmux-calls"
exit 1
STUB
chmod +x "$TMPD/stub/tmux"

US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
OPTS=""; for _ in 1 2 3 4 5 6 7 8 9 10; do OPTS+="$GS"; done

# $1 = file, $2 = title length, $3 = option value length: ten windows of three
# panes, every pane titled (and, with $3, publishing @agent_desc).
make_dump() {
  local title opt="" w p
  printf -v title '%*s' "$2" ''; title="${title// /t}"
  if [ "$3" -gt 0 ]; then printf -v opt '%*s' "$3" ''; opt="${opt// /o}"; fi
  {
    printf 'work%s1700080000%s10%sattached%s/home/u\n' "$US" "$US" "$US" "$US"
    printf '%s\n' "$RS"
    for w in 0 1 2 3 4 5 6 7 8 9; do
      printf 'work%s%s%swin%s%s%s%snvim%s/home/u%s3%s%s%s000\n' \
        "$US" "$w" "$US" "$w" "$US" "$([ "$w" = 0 ] && echo 1 || echo 0)" "$US" "$US" "$US" "$US" "$((1000 + w))" "$US"
    done
    printf '%s\n' "$RS"
    for w in 0 1 2 3 4 5 6 7 8 9; do
      for p in 0 1 2; do
        printf 'work%s%s%s%s%s%s%snvim%s/home/u%s%s%s3%s%%%s%s%s%s%s%s%s\n' \
          "$US" "$w" "$US" "$p" "$US" "$([ "$p" = 0 ] && echo 1 || echo 0)" "$US" "$US" "$US" \
          "$((2000 + w * 3 + p))" "$US" "$US" "$((w * 3 + p))" "$US" "$title" "$US" \
          "$GS" "$opt" "${OPTS:1}"   # @agent_state empty, @agent_desc, eight more
      done
    done
    printf '%s\n' "$RS"
    printf 'work%s0%s0%shost%shost\n' "$US" "$US" "$US" "$US"
    printf '%s\n' "$RS"
  } > "$1"
}

# $1 = dump, then VAR=value pairs -> READS: the read(2) calls of the whole
# --list (children too)
count_reads() {
  local dump="$1"; shift
  env -i HOME=/home/u PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_SHOW_FULL_COMMAND=off \
      INTERDIMUX_SHOW_GIT_BRANCH=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_TITLE=all \
      TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
      FZF_COLUMNS=200 INTERDIMUX_USE_RUST=off INTERDIMUX_DUMP_IN="$dump" "$@" \
      strace -f -qq -e trace=read -o "$TMPD/trace" bash "$SCRIPT" --list > "$TMPD/rows" 2> "$TMPD/err" || true
  READS=$(grep -c 'read(' "$TMPD/trace" || true)
}

if ! command -v strace >/dev/null 2>&1 || ! strace -f -qq -o /dev/null true 2>/dev/null; then
  echo "  (skipped: needs strace, and permission to trace a child)"
else
  # 30 panes; 10 vs 400 title characters, then 400 more in an option value.
  make_dump "$TMPD/short.dump" 10 0
  make_dump "$TMPD/long.dump" 400 0
  make_dump "$TMPD/opt.dump" 10 100
  count_reads "$TMPD/short.dump"; short="$READS"; cp "$TMPD/rows" "$TMPD/rows.short"
  count_reads "$TMPD/long.dump";  long="$READS";  cp "$TMPD/rows" "$TMPD/rows.long"
  count_reads "$TMPD/opt.dump";   opt="$READS";   cp "$TMPD/rows" "$TMPD/rows.opt"
  # The premise: each list rendered, 41 rows, with the titles (cut to 40) and
  # the option's description in them -- the long strings were really read.
  if [ "$(wc -l < "$TMPD/rows.short")" = 41 ] && [ "$(wc -l < "$TMPD/rows.long")" = 41 ] \
     && [ "$(grep -c 'tttttttttttttttttttttttttttttttttttttt…' "$TMPD/rows.long")" = 40 ] \
     && [ "$(grep -c 'ooooooooooooooooooooooooooooooooooooooo…' "$TMPD/rows.opt")" = 40 ]; then
    report "premise: the dumps render 41 rows each, long titles and options shown" pass
  else
    report "premise: the dumps render 41 rows each, long titles and options shown" fail
    ERRORS+="      $(head -3 "$TMPD/err")"$'\n'
  fi
  # 30 panes x 390 more characters is 11,700 bytes; read a byte at a time,
  # that was ~23,000 more calls.  Allow a little for anything incidental.
  d=$(( long - short ))
  if [ "$d" -lt 100 ]; then
    report "390 more title characters a pane: $d more read(2) calls (not ~23,000)" pass
  else
    report "390 more title characters a pane: $d more read(2) calls (not ~23,000)" fail
  fi
  d=$(( opt - short ))
  if [ "$d" -lt 100 ]; then
    report "100 characters of a published option a pane: $d more read(2) calls" pass
  else
    report "100 characters of a published option a pane: $d more read(2) calls" fail
  fi
  # @interdimux-hide filters the raw lines, titles and all, before either
  # renderer sees them -- the Rust core's lists pay for this loop too.
  count_reads "$TMPD/short.dump" INTERDIMUX_HIDE='scratch*'; short="$READS"
  count_reads "$TMPD/long.dump" INTERDIMUX_HIDE='scratch*';  long="$READS"
  d=$(( long - short ))
  if [ "$d" -lt 100 ] && [ "$(wc -l < "$TMPD/rows")" = 41 ]; then
    report "...and with @interdimux-hide set: $d more" pass
  else
    report "...and with @interdimux-hide set: $d more ($(wc -l < "$TMPD/rows") rows)" fail
  fi
fi

# --- the rows the shortcut must leave alone ---------------------------------
# One window each; the commands are what tmux reports (full commands off).
#   0 make   Claude's registry has a record for its pane (a wrapper script)
#   1 sleep  @agent_state approve, published for its pane
#   2 node   running codex by its script path, with codex's title
#   3 myagent  named by @interdimux-agents, with a title of its own
#   4 ssh    a title the ssh rules read
#   5 vim    a title no rule reads: the shortcut, and the command alone
{
  printf 'work%s1700080000%s6%sattached%s/home/u\n' "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
  i=0
  for c in "make -j8" "sleep 30" "node /opt/lib/codex/bin/codex" "myagent" "ssh web1" "vim notes"; do
    printf 'work%s%s%sw%s%s%s%s%s%s/home/u%s1%s%s%s000\n' "$US" "$i" "$US" "$i" "$US" "$([ $i = 0 ] && echo 1 || echo 0)" "$US" "$c" "$US" "$US" "$US" "$((3000 + i))" "$US"
    i=$((i + 1))
  done
  printf '%s\n' "$RS"
  i=0
  for c in "make -j8|host" "sleep 30|host" "node /opt/lib/codex/bin/codex|[ ! ] Action Required | Add tests | app" \
           "myagent|Refactoring the store" "ssh web1|deploy@web1: ~/src" "vim notes|notes - VIM"; do
    o="$OPTS"; [ "$i" = 1 ] && o="approve$OPTS"
    printf 'work%s%s%s0%s1%s%s%s/home/u%s%s%s1%s%%%s%s%s%s%s\n' "$US" "$i" "$US" "$US" "$US" "${c%%|*}" "$US" "$US" "$((3000 + i))" "$US" "$US" "$((20 + i))" "$US" "${c#*|}" "$US" "$o"
    i=$((i + 1))
  done
  printf '%s\n' "$RS"
  printf 'work%s0%s0%shost%shost\n' "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
  printf '%%20%s3000%sworking%s1700086000\n' "$US" "$US" "$US"
} > "$TMPD/gates.dump"
want=(
  "make -j8 working 6m"
  "sleep 30 approve"
  "codex approve Add tests"
  "myagent Refactoring the store"
  "ssh web1 deploy@web1: ~/src"
  "vim notes"
)
BIN="$SCRIPT_DIR/rust/target/release/imux"
renderers=(off); [ -x "$BIN" ] && renderers+=(on)
for r in "${renderers[@]}"; do
  label=bash; [ "$r" = on ] && label=rust
  env -i HOME=/home/u PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_SHOW_FULL_COMMAND=off \
      INTERDIMUX_SHOW_GIT_BRANCH=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_AGENTS=myagent \
      TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
      FZF_COLUMNS=200 INTERDIMUX_USE_RUST="$r" INTERDIMUX_DUMP_IN="$TMPD/gates.dump" \
      bash "$SCRIPT" --list 2> "$TMPD/err" | sed 's/\x1b\[[0-9;]*m//g' \
    | awk -F'\t' '$4 ~ /^W:/ { print $3 }' > "$TMPD/fields" || true
  i=0
  while IFS= read -r got; do
    if [ "$got" = "${want[i]-}" ]; then
      report "$label: '${want[i]}'" pass
    else
      report "$label: '${want[i]-}'" fail
      ERRORS+="      got: [$got]"$'\n'
    fi
    i=$((i + 1))
  done < "$TMPD/fields"
  if [ "$i" = "${#want[@]}" ] && [ ! -s "$TMPD/err" ]; then
    report "$label: all ${#want[@]} rows, nothing on stderr" pass
  else
    report "$label: all ${#want[@]} rows, nothing on stderr ($i rows)" fail
    ERRORS+="      $(head -3 "$TMPD/err")"$'\n'
  fi
done

# --- the callbacks never reach the agent layer --------------------------------
# A private server for the ones that ask tmux (the preview captures a pane).
SOCK="interdimux-rcost-test-$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
unset TMUX TMUX_PANE
tmux -f /dev/null -L "$SOCK" new-session -d -s rc -x 120 -y 30
tmux -L "$SOCK" new-window -d -t '=rc:' -n second
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=rc:0' -F '#{pane_id}')"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1 \
       XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CONFIG_HOME="$TMPD/config" \
       INTERDIMUX_USE_ZOXIDE=off FZF_COLUMNS=120
# $1 = label, $2 = what its output must contain (the callback did its job),
# then the arguments; env assignments go first, as `env` takes them.
traced() {
  local label="$1" expect="$2"; shift 2   # not `want`: an array of that name is above
  env "$@" > "$TMPD/cb.out" 2> "$TMPD/cb.trace" || true
  if ! grep -qF -- "$expect" "$TMPD/cb.out"; then
    report "$label: runs (its output has '$expect')" fail
    ERRORS+="      out: $(head -c 300 "$TMPD/cb.out")"$'\n'"      err: $(grep -v '^+' "$TMPD/cb.trace" | head -3)"$'\n'
  elif grep -q '^+ AGENT_KNOWN=' "$TMPD/cb.trace"; then
    report "$label: never reaches the agent layer" fail
  else
    report "$label: never reaches the agent layer" pass
  fi
}
traced "--preview (every cursor move)" "rc:1" \
  bash -x "$SCRIPT" --preview 'W:rc:1'
traced "--footer-for (every move and keystroke)" "enter" \
  bash -x "$SCRIPT" --footer-for 'W:rc:1'
traced "--footer-for with a query typed" "newproj" \
  FZF_QUERY=newproj FZF_MATCH_COUNT=2 bash -x "$SCRIPT" --footer-for 'W:rc:1'
traced "--describe-create (every keystroke with no match)" "newproj" \
  bash -x "$SCRIPT" --describe-create newproj
traced "--scope-prompt (ctrl-])" "name" \
  FZF_NTH=1 bash -x "$SCRIPT" --scope-prompt
traced "--session-name-for (the ctrl-o picker's badge)" "rc" \
  bash -x "$SCRIPT" --session-name-for "$(tmux -L "$SOCK" display-message -p -t '=rc:0' '#{pane_current_path}')"
# The witness is real: a list does reach it.
env bash -x "$SCRIPT" --list > "$TMPD/cb.out" 2> "$TMPD/cb.trace" || true
if grep -q '^+ AGENT_KNOWN=' "$TMPD/cb.trace" && grep -q $'\tW:rc:1$' "$TMPD/cb.out"; then
  report "premise: --list does run the agent layer, and the trace shows it" pass
else
  report "premise: --list does run the agent layer, and the trace shows it" fail
fi

echo
if [ -n "$ERRORS" ]; then printf '%s' "$ERRORS"; echo; fi
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
