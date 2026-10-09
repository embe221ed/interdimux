#!/usr/bin/env bash
#
# The plugin's main paths, end to end, on whatever userland this machine has.
#
#   bash tests/smoke.sh                  (make smoke, in the dev image)
#   SMOKE_STRICT=1 bash tests/smoke.sh   a check that cannot run here fails
#
# CI runs it on real Macs, Intel and Apple Silicon (ci.yml, the macos job):
# BSD ps, sed, awk, date, find and at, no /proc, macOS's /bin/sh and its
# /bin/bash 3.2, a tmux built with utf8proc.  Nothing else runs the plugin
# there -- the suites cannot, leaning as they do on GNU tools, /proc and
# strace.  So this is written to what both userlands share: bash >= 4.3 for
# itself, and of the tools only what BSD and GNU agree on (no sed \x1b, no
# timeout(1), setsid or date -d, no awk length()).  On Linux, where the suites
# cover far more, running it mostly proves the smoke itself.
#
# Not a suite: run_all.sh runs tests/test_*.sh, so this is never totalled or
# skipped there.  It ends with the suites' "Results: N passed, M failed" all
# the same.  A check this machine cannot run (no bash 3.2, no at) says so, and
# under SMOKE_STRICT=1 -- the macOS job sets it -- that fails the run.
#
# Needs, first on PATH: tmux >= 3.6, fzf >= 0.74 and bash >= 4.3 (the tmux
# server it starts inherits PATH, and the plugin runs `bash` from there); a
# UTF-8 locale; and the Rust core built (cd rust && cargo build --release).
# Every tmux it runs is a private server (-L): never the one you are in.

set -uo pipefail

REPO=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT=$REPO/scripts/interdimux.sh
BIN=$REPO/rust/target/release/imux

BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' DIM=$'\033[2m' RST=$'\033[0m'
PASS=0 FAIL=0 NOTHERE=()
ok()  { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$GREEN" "$RST" "$1"; }
bad() {  # bad WHAT [DETAIL]
  FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$RED" "$RST" "$1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | head -n 20 | sed "s/^/      $DIM/; s/\$/$RST/"
}
nothere() { NOTHERE+=("$1"); printf '  %s-%s %s %s(not on this machine: %s)%s\n' "$YELLOW" "$RST" "$1" "$DIM" "$2" "$RST"; }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }
die() { printf '%ssmoke: %s%s\n' "$RED" "$*" "$RST" >&2; exit 2; }

# The colours off.  BSD sed reads no \x1b, so the ESC byte itself goes in.
ESC=$(printf '\033')
strip() { LC_ALL=C sed "s/$ESC\[[0-9;]*m//g"; }

# wait_for TENTHS COMMAND: poll until COMMAND succeeds (never a fixed sleep:
# a runner's speed varies by a factor of several).
wait_for() {
  local n=$1 i=0; shift
  while [ "$i" -lt "$n" ]; do eval "$*" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

# bounded SECS COMMAND...: COMMAND, killed after SECS (exit 124).  timeout(1)
# is GNU's; macOS has none.  It runs in a process group of its own (set -m),
# and the whole group goes: a grandchild left holding the output pipe would
# keep a $(...) waiting after its parent was killed.
bounded() {
  local secs=$1 pid i=0; shift
  set -m; "$@" & pid=$!; set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 10)) ]; then kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"
}

# --- preconditions ------------------------------------------------------------
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } \
  || die "needs bash >= 4.3 to run (this is $BASH_VERSION)"
for c in tmux fzf; do command -v "$c" >/dev/null 2>&1 || die "no $c on PATH"; done
# shellcheck disable=SC2016  # the PATH bash's own versions
[ "$(bash -c 'echo $(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] ))')" -ge 403 ] \
  || die "the bash first on PATH ($(command -v bash)) is older than 4.3: the plugin runs that one"
bar='│'
[ "${#bar}" = 1 ] || die "the locale is not UTF-8 (LANG=${LANG:-} LC_ALL=${LC_ALL:-}): bash counts bytes"
[ -x "$BIN" ] || die "no Rust core at $BIN: (cd rust && cargo build --release)"
tv=$(tmux -V | sed 's/^tmux //; s/[a-z-].*//')
[ "$(echo "$tv" | awk -F. '{ print $1 * 100 + $2 }')" -ge 306 ] || die "tmux $(tmux -V) is older than 3.6"

# --- a private world ----------------------------------------------------------
T=$(mktemp -d "${TMPDIR:-/tmp}/imux-smoke.XXXXXX") || die "mktemp failed"
T=$(CDPATH='' cd -- "$T" && pwd -P)
SOCK=imux-smoke-$$
OUTER=imux-smoke-$$-o
t() { tmux -L "$SOCK" "$@"; }
o() { tmux -L "$OUTER" "$@"; }
JOBS=()
cleanup() {
  local j
  for j in ${JOBS[@]+"${JOBS[@]}"}; do atrm "$j" 2>/dev/null || true; done
  o kill-server 2>/dev/null || true
  t kill-server 2>/dev/null || true
  # kill-server leaves the socket files (tmux 3.7)
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OUTER"
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$T/home" "$T/state" "$T/data/interdimux" "$T/config" "$T/cache" "$T/claude/sessions" "$T/codex" "$T/bin"
export HOME=$T/home XDG_STATE_HOME=$T/state XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config \
       XDG_CACHE_HOME=$T/cache CLAUDE_CONFIG_DIR=$T/claude CODEX_HOME=$T/codex
unset TMUX TMUX_PANE XDG_RUNTIME_DIR INTERDIMUX_USE_RUST INTERDIMUX_BIN INTERDIMUX_AT_DAEMON \
      INTERDIMUX_PROJECT_DIRS INTERDIMUX_FORCE_PS FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
export INTERDIMUX_USE_ZOXIDE=off FZF_COLUMNS=250
# Claude's registry: a Mac has no /proc, so a record's pid is believed on
# kill -0 alone.  Elsewhere the plugin also checks its start time in /proc;
# this has it skip that, as a Mac must, for the record the fixture writes.
[ "$(uname -s)" = Darwin ] || export INTERDIMUX_REGISTRY_NO_PROC=1

# The Rust core through a stand-in that logs each run, so a core that is
# refused (another protocol: exit 2), fails, or prints what the script cannot
# use (its first line not a row) cannot quietly hand every render to the bash
# renderer, which is what the script then does.  It logs the exit status, or
# "junk" for an exit 0 the script would throw away.
cat > "$T/bin/imux" <<EOF
#!/bin/sh
'$BIN' "\$@" > '$T/imux.last'
rc=\$?
cat '$T/imux.last'
shape=\$(head -n 1 '$T/imux.last' | awk -F'\t' '{ print (\$NF ~ /^[SWPD]:/) ? "row" : "junk" }')
if [ "\$rc" = 0 ] && [ "\$shape" != row ]; then echo junk; else echo "\$rc"; fi >> '$T/imux.runs'
exit "\$rc"
EOF
chmod +x "$T/bin/imux"
# And a ps that logs each run, first on PATH for the lists: the Rust core's
# native process backend (libproc on macOS, /proc on Linux) must need none.
mkdir -p "$T/psbin"
realps=$(command -v ps)
printf '#!/bin/sh
echo ps >> %s
exec %s "$@"
' "'$T/ps.runs'" "'$realps'" > "$T/psbin/ps"
chmod +x "$T/psbin/ps"
ps_runs() { [ -f "$T/ps.runs" ] && wc -l < "$T/ps.runs" | tr -d ' ' || echo 0; }
core_runs() { [ -f "$T/imux.runs" ] && wc -l < "$T/imux.runs" | tr -d ' ' || echo 0; }
core_failed_since() { tail -n "+$(( $1 + 1 ))" "$T/imux.runs" 2>/dev/null | grep -vx 0 | head -n 1; }

os=$(uname -s)
# shellcheck disable=SC2016  # the PATH bash's own $BASH_VERSION
section "smoke: $os $(uname -m)${DIM}  $(tmux -V), fzf $(fzf --version | awk '{ print $1 }'), bash $(bash -c 'echo $BASH_VERSION')$RST"
[ "$os" != Darwin ] || printf '  %smacOS %s%s\n' "$DIM" "$(sw_vers -productVersion 2>/dev/null)" "$RST"

# Fixtures: a git repo, project dirs, a symlinked spelling of one directory.
W=$T/work
mkdir -p "$W/repo" "$W/proj/alpha" "$W/proj/beta/gamma" "$W/proj/beta/.hidden/x" "$W/proj/web" "$W/proj/other"
touch "$W/proj/alpha/Cargo.toml"
git -C "$W/repo" init -q 2>/dev/null && git -C "$W/repo" checkout -q -b smoke-branch 2>/dev/null
git -C "$W/repo" -c user.name=smoke -c user.email=smoke@example.invalid commit -q --allow-empty -m 'smoke commit' 2>/dev/null
echo change > "$W/repo/f"
# The second spelling of $W: on macOS, $TMPDIR lives under /var, a symlink to
# /private/var, and tmux reports the physical path -- the case this is for.
# Elsewhere a symlink of our own stands in.
if [ "$os" = Darwin ] && [ "${T#/private}" != "$T" ] && [ "$(CDPATH='' cd -- "${T#/private}" 2>/dev/null && pwd -P)" = "$T" ]; then
  LW=${T#/private}/work
else
  ln -s "$W" "$T/lw"; LW=$T/lw
fi

# The server: panes run bash 5 from PATH, no rc files.
t -f /dev/null new-session -d -s main -x 200 -y 50 -c "$W" 'bash --norc --noprofile -i' || die "the tmux server did not start"
t set -g default-command 'bash --norc --noprofile -i'
t set -s escape-time 0
t set -g @interdimux-autobuild off
TMUX="$(t display -p '#{socket_path}'),$(t display -p '#{pid}'),0"
TMUX_PANE=$(t display -p -t main '#{pane_id}')
export TMUX TMUX_PANE
# alpha: a shell with a foreground job and a background one, in a window of
# two panes (so it lists its panes too)
t new-session -d -s alpha -c "$W"
t split-window -d -t alpha:0 -c "$W"
t send-keys -t alpha:0.0 'sleep 902 &' Enter 'sleep 901' Enter
t new-session -d -s gitrepo -c "$W/repo"
t new-session -d -s web -c "$W/proj/web"      # recent_dirs below spells it $LW
t new-session -d -s victim -c "$W"
# an agent: argv says claude, and Claude's own registry says it waits
t new-session -d -s agent -c "$W" "bash --norc --noprofile -c 'exec -a claude sleep 906'"
apid=$(t display -p -t agent '#{pane_pid}'); apane=$(t display -p -t agent '#{pane_id}'); awin=$(t display -p -t agent '#{window_id}')
wait_for 100 '[ "$(ps -ww -o args= -p "$apid" 2>/dev/null | awk "{ print \$1 }")" = claude ]' || bad "setup: the agent pane runs 'claude'"
printf '{"pid":%s,"kind":"interactive","tmux":"agent:%s.%s","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":%s000}' \
  "$apid" "$awin" "$apane" "$(date +%s)" > "$T/claude/sessions/$apid.json"
# a ghost: another claude pane, whose record names a pid that has exited
# (on a Mac, kill -0 is all that tells the two apart)
t new-session -d -s ghost -c "$W" "bash --norc --noprofile -c 'exec -a claude sleep 907'"
gpane=$(t display -p -t ghost '#{pane_id}'); gwin=$(t display -p -t ghost '#{window_id}')
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '{"pid":%s,"kind":"interactive","tmux":"ghost:%s.%s","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":%s000}' \
  "$dead" "$gwin" "$gpane" "$(date +%s)" > "$T/claude/sessions/$dead.json"
# the clock pinned, so no row's age can cross a minute between two renders
INTERDIMUX_NOW=$(date +%s); export INTERDIMUX_NOW
# where previously used directories are kept: one that has a session (spelt
# the other way), one that has not
printf '%s\n' "$LW/proj/web" "$LW/proj/other" > "$T/data/interdimux/recent_dirs"

# --- loading ------------------------------------------------------------------
section "loading"
out=$(bounded 120 t run-shell "$REPO/interdimux.tmux" 2>&1); rc=$?
keys=$(t list-keys -T prefix 2>&1)
if [ "$rc" = 0 ] && printf '%s' "$keys" | grep -F 'interdimux.sh' | grep -qF 'display-popup'; then
  ok "interdimux.tmux loads as TPM runs it: prefix keys open popups"
else
  bad "interdimux.tmux loads as TPM runs it" "rc=$rc $out
$(printf '%s\n' "$keys" | grep -i interdimux | head -3)"
fi

# --- the bash floor -----------------------------------------------------------
section "bash 3.2"
b32=""
# shellcheck disable=SC2016  # /bin/bash's own $BASH_VERSION
case $(/bin/bash -c 'echo $BASH_VERSION' 2>/dev/null) in 3.*) b32=/bin/bash ;; esac
[ -n "$b32" ] || [ ! -x "${INTERDIMUX_OLD_BASH_DIR:-/nonexistent}/3.2/bash" ] || b32=$INTERDIMUX_OLD_BASH_DIR/3.2/bash
if [ -n "$b32" ]; then
  # (outside tmux: inside, the refusal goes to the status line as well)
  out=$(env -u TMUX -u TMUX_PANE "$b32" "$SCRIPT" --list 2>"$T/b32.err" </dev/null); rc=$?
  # shellcheck disable=SC2016
  want="interdimux: bash >= 4.3 is required (found bash $("$b32" -c 'echo $BASH_VERSION'))"
  if [ "$rc" = 1 ] && [ -z "$out" ] && [ "$(cat "$T/b32.err")" = "$want" ]; then
    ok "$b32 is refused in one line"
  else
    bad "$b32 is refused in one line" "rc=$rc out=$out err=$(cat "$T/b32.err")"
  fi
else
  nothere "the bash 3.2 refusal" "no bash 3.2"
fi

# --- rows: every renderer, every process backend -----------------------------
section "rows"
# CONFIG is "" (the Rust core, its native process backend: libproc on macOS,
# /proc on Linux), INTERDIMUX_FORCE_PS=1 (the Rust core reading a ps table),
# INTERDIMUX_USE_RUST=off (the bash renderer: ps on macOS, /proc on Linux),
# and the bash renderer forced onto ps.
CONFIGS=("" "INTERDIMUX_FORCE_PS=1" "INTERDIMUX_USE_RUST=off" "INTERDIMUX_USE_RUST=off INTERDIMUX_FORCE_PS=1")
label() { case $1 in '') echo "Rust core" ;; *FORCE_PS*USE_RUST*|*USE_RUST*FORCE_PS*) echo "bash renderer, ps" ;;
                        *USE_RUST*) echo "bash renderer" ;; *) echo "Rust core, ps" ;; esac; }
list() {  # list CONFIG: the rows, plain, into $T/list.out; stderr into $T/list.err
  # shellcheck disable=SC2086  # CONFIG is VAR=value words
  PATH="$T/psbin:$PATH" bounded 60 env $1 INTERDIMUX_BIN="$T/bin/imux" bash "$SCRIPT" --list 2>"$T/list.err" | strip > "$T/list.out"
}
field() { awk -F'\t' -v s="$1" -v f="$2" '$4 == s { print $f; exit }' "$T/list.out"; }
first_specs=""
first_cmds=""
for cfg in "${CONFIGS[@]}"; do
  name=$(label "$cfg")
  before=$(core_runs) ps_before=$(ps_runs)
  # the command column settles as the shells start their jobs
  wait_for 100 'list "$cfg"; field W:alpha:0 3 | grep -q "sleep 901"'
  errs=$(cat "$T/list.err")
  shape=$(awk -F'\t' 'NF != 4 || $4 !~ /^[SWPD]:/' "$T/list.out")
  if [ -n "$errs" ]; then bad "$name: --list writes nothing to stderr" "$errs"
  elif [ ! -s "$T/list.out" ] || [ -n "$shape" ]; then bad "$name: --list rows are 4 fields, the last a spec" "$shape"
  else ok "$name: --list draws $(wc -l < "$T/list.out" | tr -d ' ') rows, stderr clean"; fi
  case $cfg in
    *USE_RUST=off*) [ "$(core_runs)" = "$before" ] || bad "$name: the core stays out of it" ;;
    *) if [ "$(core_runs)" -le "$before" ]; then bad "$name: the core drew them" "imux was never run: the rows are the bash renderer's"
       elif [ -n "$(core_failed_since "$before")" ]; then bad "$name: the core drew them" "imux exited $(core_failed_since "$before"): the rows are the bash renderer's"
       else ok "$name: the core drew them (it ran, exited 0, printed rows)"; fi ;;
  esac
  case $cfg in
    '') [ "$(ps_runs)" = "$ps_before" ] && ok "$name: its native process backend needed no ps ($( [ "$os" = Darwin ] && echo libproc || echo /proc))" \
          || bad "$name: its native process backend needs no ps" "ps ran $(( $(ps_runs) - ps_before )) times: the core fell back to a ps table" ;;
    INTERDIMUX_FORCE_PS=1) [ "$(ps_runs)" -gt "$ps_before" ] && ok "$name: it read a ps table, as forced" \
          || bad "$name: it reads a ps table when forced" "ps never ran" ;;
  esac
  c=$(field W:alpha:0 3)
  case $c in
    *'sleep 901'*) ok "$name: a shell's foreground job names its window (sleep 901, not the background sleep 902)" ;;
    *) bad "$name: a shell's foreground job names its window" "W:alpha:0 reads: $c" ;;
  esac
  field P:alpha:0:1 4 | grep -q . && ok "$name: a two-pane window lists its panes" || bad "$name: a two-pane window lists its panes"
  field W:gitrepo:0 2 | grep -q smoke-branch && ok "$name: the git badge reads the branch" \
    || bad "$name: the git badge reads the branch" "$(grep 'gitrepo' "$T/list.out")"
  c=$(field W:agent:0 3)
  case $c in
    *claude*approve*) ok "$name: the waiting claude pane says so (registry, no /proc needed)" ;;
    *) bad "$name: the waiting claude pane says so" "W:agent:0 reads: $c" ;;
  esac
  c=$(field W:ghost:0 3)
  case $c in
    *claude*approve*|'') bad "$name: a record whose pid has exited is not believed" "W:ghost:0 reads: $c" ;;
    *claude*) ok "$name: a record whose pid has exited is not believed" ;;
    *) bad "$name: the ghost pane is a claude pane" "W:ghost:0 reads: $c" ;;
  esac
  d=$(awk -F'\t' '$4 ~ /^D:/ { print $4 }' "$T/list.out")
  if printf '%s\n' "$d" | grep -q '/proj/other$' && ! printf '%s\n' "$d" | grep -q '/proj/web$'; then
    ok "$name: a recent dir with a session is not offered again, however it is spelt"
  else
    bad "$name: a recent dir with a session is not offered again" "D: rows: $d"
  fi
  specs=$(awk -F'\t' '{ print $4 }' "$T/list.out")
  cmds=$(awk -F'\t' '{ print $4 "\t" $3 }' "$T/list.out")
  if [ -z "$cfg" ]; then first_specs=$specs first_cmds=$cmds
  elif [ "$specs" != "$first_specs" ]; then bad "$name: the same rows as the Rust core" "$(diff <(printf '%s\n' "$first_specs") <(printf '%s\n' "$specs") | head -10)"
  elif [ "$cmds" != "$first_cmds" ]; then bad "$name: the same command column as the Rust core" "$(diff <(printf '%s\n' "$first_cmds") <(printf '%s\n' "$cmds") | head -10)"
  else ok "$name: the same rows and command column as the Rust core"; fi
done

# --- previews and agents ------------------------------------------------------
section "previews and agents"
list ""
n=0 failed=""
preview() { FZF_PREVIEW_COLUMNS=80 FZF_PREVIEW_LINES=30 bounded 30 bash "$SCRIPT" --preview "$1" 2>"$T/pv.err" | strip; }
for spec in $(awk -F'\t' '$4 ~ /^[SWP]:/ { print $4 }' "$T/list.out"); do
  out=$(preview "$spec")
  n=$((n + 1))
  # (a target it could not resolve still gets a header, of question marks)
  if [ -z "$out" ] || [ -s "$T/pv.err" ] || printf '%s\n' "$out" | head -n 1 | grep -qE '\? · \?| \? win'; then
    failed="$failed ${spec} ($(printf '%s\n' "$out" | head -n 1)$(head -c 200 "$T/pv.err"))"
  fi
done
[ -z "$failed" ] && ok "--preview resolves all $n tmux rows, stderr clean" || bad "--preview of every tmux row" "$failed"
preview P:alpha:0:0 | grep -q 'sleep 901' && ok "--preview of a pane shows its command" \
  || bad "--preview of a pane shows its command" "$(preview P:alpha:0:0 | head -5)"
preview W:gitrepo:0 | head -n 3 | grep -q '/repo' && ok "--preview of a window shows its directory" \
  || bad "--preview of a window shows its directory" "$(preview W:gitrepo:0 | head -5)"
out=$(bounded 30 bash "$SCRIPT" --dirs-preview "$W/repo" 2>"$T/dp.err" | strip)
if printf '%s' "$out" | grep -q 'Branch: smoke-branch' && printf '%s' "$out" | grep -q 'smoke commit' && [ ! -s "$T/dp.err" ]; then
  ok "--dirs-preview of a git repo: branch, last commit"
else
  bad "--dirs-preview of a git repo" "$out
$(cat "$T/dp.err")"
fi
out=$(bounded 30 bash "$SCRIPT" --agents 2>"$T/ag.err")
if printf '%s' "$out" | grep -qF "$apane" && printf '%s' "$out" | grep -qF "$gpane" && [ ! -s "$T/ag.err" ]; then
  ok "--agents: both claude panes"
else
  bad "--agents lists both claude panes" "$out
$(cat "$T/ag.err")"
fi
out=$(bounded 30 bash "$SCRIPT" --agents approve 2>"$T/ag.err")
if [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && printf '%s' "$out" | grep -qF "$apane" && [ ! -s "$T/ag.err" ]; then
  ok "--agents approve: only the live one waits; the dead pid's record is not believed"
else
  bad "--agents approve lists the live waiting pane only" "$out
$(cat "$T/ag.err")"
fi
unset INTERDIMUX_NOW

# --- the directory picker -----------------------------------------------------
section "directory picker ($(command -v fd >/dev/null 2>&1 && echo fd || { command -v fdfind >/dev/null 2>&1 && echo fdfind; } || echo find))"
dl() { INTERDIMUX_PROJECT_DIRS=$W/proj bounded 60 bash "$SCRIPT" --dirs-list "$@" 2>"$T/dl.err" | strip | awk -F'\t' '{ print $3 }'; }
out=$(dl)
if printf '%s\n' "$out" | grep -qx "$W/proj/alpha" && printf '%s\n' "$out" | grep -qx "$W/proj/beta" && [ ! -s "$T/dl.err" ]; then
  ok "--dirs-list: the project dirs"
else
  bad "--dirs-list: the project dirs" "$out
$(cat "$T/dl.err")"
fi
out=$(dl --deep GAM)
printf '%s\n' "$out" | grep -qx "$W/proj/beta/gamma" && [ ! -s "$T/dl.err" ] \
  && ok "--dirs-list --deep: a case-insensitive name search" || bad "--dirs-list --deep GAM finds beta/gamma" "$out"
out=$(dl --scan "$W/proj/beta")
if printf '%s\n' "$out" | grep -qx "$W/proj/beta/gamma" && ! printf '%s\n' "$out" | grep -q '\.hidden'; then
  ok "--dirs-list --scan: subdirectories, hidden ones left out"
else
  bad "--dirs-list --scan" "$out"
fi

# --- scheduling ---------------------------------------------------------------
section "scheduling"
runner=""
out=$(bounded 30 bash "$SCRIPT" --send-in 2 "$TMUX_PANE" 'echo SUBMIN-$((6*7))' 2>&1)
if printf '%s' "$out" | grep -q 'tmux timer' && wait_for 100 't capture-pane -p -t main | grep -q SUBMIN-42'; then
  ok "--send-in 2: tmux's timer (run by /bin/sh) types it, and the shell runs it"
else
  bad "--send-in 2 delivers keys" "$out"
fi
if command -v at >/dev/null 2>&1 && command -v atq >/dev/null 2>&1; then
  out=$(INTERDIMUX_AT_DAEMON=up bounded 30 bash "$SCRIPT" --send-at 'now + 3 hours' "$TMUX_PANE" 'echo SMOKE-AT' 2>"$T/at.err")
  jid=$(printf '%s' "$out" | sed -n 's/^interdimux: job \([0-9][0-9]*\) at .*/\1/p' | head -n 1)
  if [ -n "$jid" ] && [ ! -s "$T/at.err" ]; then
    JOBS+=("$jid"); ok "--send-at: at queued job $jid"
    body=$(at -c "$jid" 2>/dev/null)
    case $body in
      *"
# imux:v1 "*) atq -q i | awk '{ print $1 }' | grep -qx "$jid" && ok "...in queue i, with the plugin's job body" \
                    || bad "...in queue i" "$(atq 2>&1)" ;;
      *) bad "...with the plugin's job body" "$(printf '%s\n' "$body" | tail -5)" ;;
    esac
    out=$(bounded 30 bash "$SCRIPT" --sched-list 2>&1)
    if printf '%s\n' "$out" | grep -E "^$jid +20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] " | grep -q SMOKE-AT; then
      ok "--sched-list: the job, its time as YYYY-MM-DD HH:MM"
    else
      bad "--sched-list shows the job with its time" "$out"
    fi
    out=$(bounded 30 bash "$SCRIPT" --sched-cancel "$jid" 2>&1)
    if ! atq -q i | awk '{ print $1 }' | grep -qx "$jid"; then ok "--sched-cancel: gone from at's queue"; JOBS=()
    else bad "--sched-cancel removes the job" "$out"; fi
    bounded 30 bash "$SCRIPT" --sched-cancel 999999 >/dev/null 2>&1 && bad "--sched-cancel of a job that is not there fails" \
      || ok "--sched-cancel of a job that is not there fails"
  else
    bad "--send-at queues a job with at" "$out
$(cat "$T/at.err")"
  fi
  # The job-runner as the plugin sees it, against an oracle asked another way
  # than the plugin asks (it runs `launchctl print` as the user on a Mac, and
  # `pgrep -x atd` elsewhere).
  if [ "$os" = Darwin ]; then
    if sudo -n true 2>/dev/null; then
      sudo -n launchctl list com.apple.atrun >/dev/null 2>&1 && runner=up || runner=down
    elif [ -n "${GITHUB_ACTIONS:-}" ]; then
      runner=down   # GitHub's images ship atrun disabled
    fi
  else
    p=$(cat /run/atd.pid /var/run/atd.pid 2>/dev/null | head -n 1)
    if [ -n "$p" ]; then [ -d "/proc/$p" ] && runner=up || runner=down
    else pgrep -x atd >/dev/null 2>&1 && runner=up || runner=down; fi
  fi
  out=$(bounded 30 bash "$SCRIPT" --send-at 'now + 4 hours' "$TMUX_PANE" 'echo SMOKE-AT-2' 2>"$T/at.err")
  jid=$(printf '%s' "$out" | sed -n 's/^interdimux: job \([0-9][0-9]*\) at .*/\1/p' | head -n 1)
  [ -z "$jid" ] || JOBS+=("$jid")
  heads=$(grep -c "heads-up" "$T/at.err")
  if [ -z "$runner" ]; then
    nothere "--send-at's view of at's job-runner" "no way to ask launchctl as root"
  elif { [ "$runner" = down ] && [ "$heads" = 1 ]; } || { [ "$runner" = up ] && [ ! -s "$T/at.err" ]; }; then
    ok "--send-at knows at's job-runner is $runner"
  else
    bad "--send-at knows at's job-runner is $runner" "$(cat "$T/at.err")"
  fi
else
  nothere "--send-at and at's queue" "no at"
fi

# --- doctor -------------------------------------------------------------------
section "doctor"
out=$(INTERDIMUX_AT_DAEMON=up bounded 120 bash "$SCRIPT" --doctor 2>"$T/doc.err" | strip); rc=$?
if [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '✗' && ! printf '%s' "$out" | grep -q 'wrote to stderr' && [ ! -s "$T/doc.err" ]; then
  ok "--doctor: no problems ($(printf '%s\n' "$out" | grep -c '✓') checks pass, $(printf '%s\n' "$out" | grep -c '⚠') warnings)"
  printf '%s\n' "$out" | grep '⚠' | sed "s/^ */      $DIM/; s/\$/$RST/"
else
  bad "--doctor finds no problems" "rc=$rc
$(printf '%s\n' "$out" | grep -E '✗|⚠' | head -12)
$(cat "$T/doc.err")"
fi
out=$(bounded 120 bash "$SCRIPT" --doctor 2>/dev/null | strip)
if [ "$runner" = down ] && printf '%s' "$out" | grep -qF "✗ at's job-runner is not active" && [ "$(printf '%s\n' "$out" | grep -c '✗')" = 1 ]; then
  ok "--doctor's own probe: at's job-runner is not active, its only problem"
elif [ "$runner" = up ] && printf '%s' "$out" | grep -qF "✓ at's job-runner is active"; then
  ok "--doctor's own probe: at's job-runner is active"
elif [ -z "${runner:-}" ]; then
  nothere "--doctor's job-runner probe" "no at, or no way to ask launchctl as root"
else
  bad "--doctor's own probe agrees: at's job-runner is $runner" "$(printf '%s\n' "$out" | grep -E "job-runner|✗")"
fi

# --- the navigator, in a popup, on a real client ------------------------------
section "navigator"
# An outer server's pane is the terminal: a real client attaches there, and
# its screen is what capture-pane reads.  (TMUX set but empty marks the
# client UTF-8 whatever the locale.)
o -f /dev/null new-session -d -s drv -x 120 -y 40 "TMUX= TERM=xterm-256color tmux -L $SOCK attach -t main"
o set -g status off; o set -s escape-time 0
key() { o send-keys -t drv "$@"; }
cap() { o capture-pane -p -t drv 2>/dev/null; }
popup_up() { cap | grep -q '❯'; }
# The popup itself, by its border, as the suites test it.  fzf's prompt goes
# first: the popup stays up until its job has exited, ~5 ms later (80 ms
# under load), and a key sent then goes to that dying job, not to tmux -- a
# prefix+g lost there left no menu and no trace.  So the next key waits for
# this.
popup_open() { cap | grep -q '┌'; }
# query TEXT: type TEXT into the picker and wait until its prompt shows it,
# and the match count on that line (N/M) shows the filtering done -- the rows
# alone prove nothing, they show every name before any filtering, and an
# Enter that beats the matcher takes the row that was current before.  Keys
# sent while fzf is (re)starting can be lost, so it types again.
filtered() {  # filtered TEXT: the prompt line shows TEXT and fewer matches than rows
  cap | grep -F "❯ $1" | grep -oE '[0-9]+/[0-9]+' | tail -n 1 | awk -F/ '$1 > 0 && $1 < $2 { ok = 1 } END { exit !ok }'
}
query() {
  local _q=$1 tries=0   # (named: inside wait_for's eval, $1 is wait_for's)
  while [ "$tries" -lt 5 ]; do
    key C-u; key -l "$_q"
    wait_for 30 'filtered "$_q"' && return 0
    tries=$((tries + 1))
  done
  return 1
}
if ! wait_for 100 '[ -n "$(t list-clients 2>/dev/null)" ]'; then
  bad "a client attaches" "$(cap)"
else
  client=$(t list-clients -F '#{client_name}' | head -n 1)
  key C-b f
  if wait_for 200 'popup_up && cap | grep -q victim'; then
    ok "prefix+f opens the navigator, rows drawn"
    if query victim && key C-x && wait_for 100 'cap | grep -q "y confirm"'; then
      # The dialog drains what was typed before it was ready to read (on
      # purpose: a stray key must not confirm a kill), and "drawn" comes a
      # moment before "reading".  So answer until it is gone.
      tries=0
      while t has-session -t =victim 2>/dev/null && [ "$tries" -lt 20 ]; do
        key y; wait_for 5 '! t has-session -t =victim 2>/dev/null'; tries=$((tries + 1))
      done
      if ! t has-session -t =victim 2>/dev/null; then ok "ctrl-x, y: the kill dialog (a raw tty) kills the session"
      else bad "ctrl-x, y kills the session" "$(cap)"; fi
    else
      bad "ctrl-x opens the kill dialog" "$(cap)"
    fi
    wait_for 100 'popup_up'
    query gitrepo || bad "the navigator takes a query again after the kill" "$(cap)"
    key Enter
    if wait_for 100 '[ "$(t display -p -c "$client" "#{client_session}")" = gitrepo ] && ! popup_open'; then
      ok "typing a name and Enter switches the client there, the popup closes"
    else
      bad "Enter switches to the session typed" "client on $(t display -p -c "$client" '#{client_session}')
$(cap)"
    fi
  else
    bad "prefix+f opens the navigator" "$(cap)"
  fi
  key C-b f
  if wait_for 200 'popup_up'; then
    key Escape
    wait_for 100 '! popup_open' && ok "Esc closes the navigator's popup" || bad "Esc closes the navigator's popup" "$(cap)"
  else
    bad "prefix+f opens the navigator again" "$(cap)"
  fi
  key C-b g
  if wait_for 100 'cap | grep -qF " interdimux " && cap | grep -q Health'; then
    key Escape
    wait_for 50 '! cap | grep -q Health' && ok "prefix+g opens the dashboard, Esc closes it" \
      || bad "Esc closes the dashboard" "$(cap)"
  else
    bad "prefix+g opens the dashboard" "$(cap)"
  fi
  # a binding whose command failed shows "'...' returned N" in the pane
  ! cap | grep -q "' returned [0-9]" || bad "no binding failed" "$(cap | grep "' returned")"
fi
logged=$(cat "$XDG_STATE_HOME/interdimux/errors.log" 2>/dev/null)
msgs=$(t show-messages 2>/dev/null | grep 'interdimux:' | grep -v 'cancelled\|scheduled\|job ')
if [ -z "$logged" ] && [ -z "$msgs" ]; then ok "nothing went to errors.log or the status line"
else bad "nothing goes to errors.log or the status line" "$logged
$msgs"; fi

# ------------------------------------------------------------------------------
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ ${#NOTHERE[@]} -gt 0 ]; then
  printf 'not run here: %s\n' "${NOTHERE[*]}"
  [ "${SMOKE_STRICT:-0}" != 1 ] || { printf '%sSMOKE_STRICT=1: every check must run%s\n' "$RED" "$RST"; exit 1; }
fi
[ "$FAIL" = 0 ]
