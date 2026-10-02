#!/usr/bin/env bash
#
# How a popup closes: by itself on every normal way out, and NOT when what runs
# in it failed -- then it stays open, showing why, until a key.
#
# Every popup is opened -EE -k on tmux >= 3.6: tmux closes it by itself only
# when its command exits 0, and once the command has exited any key dismisses
# it.  With -E it closed on ANY exit, so "fzf is not installed", an unknown
# fzf option or a crash was written to a terminal that disappeared in the same
# instant, and prefix+f seemed to do nothing (UX-75, UX-04).  That only works
# if every normal path really does exit 0, so those are driven here too: the
# navigator's Esc and Enter, ^o and back, the --launch pickers, the jobs flash,
# Health and the dashboard's fzf fallback.
#
# And two ways the danger frame's repaint (popup_accent, a display-popup with
# no command) used to OPEN a popup running a shell and block in it:
#
#   * BUG-52  the popup closed under a waiting kill dialog (display-popup -C):
#             the orphaned dialog's cleanup repainted a popup that was gone
#   * BUG-53  --action kill run outside any popup, on a server with a client
#
# Real clients need real terminals: an outer server's pane runs `tmux attach`
# to the server under test, and what the client shows is read off that pane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-popexit-test-$$"
OUTER="${SOCK}-o"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-popexit.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  # the socket files too: tmux leaves them behind after kill-server
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OUTER"
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
I() { tmux -L "$SOCK" "$@"; }    # the server under test
O() { tmux -L "$OUTER" "$@"; }   # the one whose pane is its client
wait_for() { # $1 = a command that must succeed [, $2 = tenths of a second]
  local i
  for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux popup exit tests"
echo

if ! command -v fzf >/dev/null 2>&1; then
  echo "  (skipped: needs fzf)"; echo; echo "Results: 0 passed, 0 failed"; exit 0
fi
tv=0
[[ "$(tmux -V)" =~ ([0-9]+)\.([0-9]+) ]] && tv=$(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] ))
if [ "$tv" -lt 306 ]; then
  echo "  (skipped: -k needs tmux >= 3.6)"; echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# The popups start from the server's environment, so the server is started
# from a controlled one: a fake `at` (the jobs picker reads the queue), state
# and data under $TMPD, /bin/sh as the shell that runs popup commands (a user's
# zsh would read its rc files), and a UTF-8 locale for the frames.
mkdir -p "$TMPD/bin" "$TMPD/home" "$TMPD/nofzf" "$TMPD/stub" "$TMPD/data/interdimux" "$TMPD/proj"
# one directory for the ^o picker to list, so its prompt is the plain one
printf '%s\n' "$TMPD/proj" > "$TMPD/data/interdimux/recent_dirs"
for c in at atq atrm batch; do printf '#!/bin/sh\nexit 0\n' > "$TMPD/bin/$c"; chmod +x "$TMPD/bin/$c"; done
ln -s "$(command -v bash)" "$TMPD/nofzf/bash"
ln -s "$(command -v tmux)" "$TMPD/nofzf/tmux"
# An fzf that fails the way a bad @interdimux-fzf-opts makes the real one fail.
cat > "$TMPD/stub/fzf" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "0.74.0 (stub)"; exit 0 ;; esac
cat >/dev/null
echo 'stub-fzf: unknown option: --imux-bogus' >&2
exit 2
STUB
chmod +x "$TMPD/stub/fzf"
PATH0="$TMPD/bin:$PATH"

env -u TMUX -u TMUX_PANE -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
    PATH="$PATH0" HOME="$TMPD/home" SHELL=/bin/sh LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CACHE_HOME="$TMPD/cache" \
    XDG_CONFIG_HOME="$TMPD/config" \
  tmux -f /dev/null -L "$SOCK" new-session -d -s host -x 100 -y 30
I set -g default-command 'bash --norc --noprofile -i'
I set -g default-shell /bin/sh
I set -s escape-time 0
I respawn-pane -k -t '=host:' 'bash --norc --noprofile -i'
I new-session -d -s victim -x 100 -y 30
I set -g @interdimux-use-zoxide off
export TMUX="$(I display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(I list-panes -t '=host:' -F '#{pane_id}' | head -1)"
# the bindings, installed the way the plugin installs them
PATH="$PATH0" bash "$SCRIPT" --bind-keys

env SHELL=/bin/sh LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 100 -y 30 \
  "TMUX= LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux -L $SOCK attach -t host"
O set -g status off
O set -s escape-time 0
if ! wait_for '[ -n "$(I list-clients 2>/dev/null)" ]'; then
  report "setup: a client attaches" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; printf '%s' "$ERRORS"; exit 1
fi
CL=$(I list-clients -F '#{client_name}' | head -1)

cap()      { O capture-pane -t '=drv:' -p 2>/dev/null || true; }
popup_up() { cap | grep -q '┌'; }
shows()    { cap | grep -qF -- "$1"; }
# Inside the popup's frame, that is: an error is also put on the status line,
# which the client shows too.
in_popup() { cap | grep -F '│' | grep -qF -- "$1"; }
key()      { O send-keys -t '=drv:' "$@"; }
launch()   { # $@ = a mode and its arguments, run as the dashboard's run-shell would
  env INTERDIMUX_CLIENT="$CL" bash "$SCRIPT" "$@" >/dev/null 2>&1 &
}
# Open a popup with $2 (a key sequence, or "launch MODE" for what the
# dashboard's entries run) and wait for $3 on screen.
opens() { # $1 = label, $2 = how to open, $3 = text that shows it is up
  local label="$1" open="$2" up="$3"
  if popup_up; then I display-popup -C -c "$CL" 2>/dev/null || true; wait_for '! popup_up' 30 || true; fi
  case "$open" in
    launch\ *) launch ${open#launch } ;;
    *) key $open ;;
  esac
  wait_for 'shows "$up"' 150 && return 0
  report "$label: opens" fail
  ERRORS+="    screen: $(cap | grep -v '^ *$' | head -4 | tr '\n' '|')"$'\n'
  return 1
}
# One normal way out: open it, press the keys in $4 (space-separated; "-" for
# none; wait:TEXT and gone:TEXT poll for a screen, '%' standing for a blank),
# and the popup must then close by itself.
closes() { # $1 = label, $2 = how to open, $3 = text that shows it is up, $4 = keys
  local label="$1" keys="$4" k t
  opens "$1" "$2" "$3" || return 0
  if [ "$keys" != - ]; then
    for k in $keys; do
      t="${k#*:}"; t="${t//%/ }"
      case "$k" in
        wait:*) wait_for 'shows "$t"' 100 || true ;;
        gone:*) wait_for '! shows "$t"' 100 || true ;;
        *) key "$k" ;;
      esac
    done
  fi
  if wait_for '! popup_up' 100; then
    report "$label: the popup closes by itself" pass
  else
    report "$label: the popup closes by itself" fail
    ERRORS+="    screen: $(cap | grep -v '^ *$' | head -6 | tr '\n' '|')"$'\n'
    I display-popup -C -c "$CL" 2>/dev/null || true; wait_for '! popup_up' 30 || true
  fi
}

# --- every normal way out closes the popup, exactly as before ------------------------
closes "navigator, Esc"          "C-b f"         '❯'               Escape
closes "navigator, Enter"        "C-b f"         '❯'               Enter
I switch-client -c "$CL" -t '=host:' 2>/dev/null || true
closes "navigator, ^o then Esc twice" "C-b f"    '❯'               "C-o wait:new%session%❯ Escape gone:new%session%❯ wait:▸%victim Escape"
closes "--launch kill, Esc"      "launch --launch kill"   'kill ❯'   Escape
closes "--launch rename, Esc"    "launch --launch rename" 'rename ❯' Escape
closes "--launch dirs, Esc"      "launch --launch dirs"   'new session ❯' Escape
closes "--launch jobs, empty queue" "launch --launch jobs" 'Nothing is scheduled' -
closes "--launch doctor, Esc"    "launch --launch doctor" 'health ❯' Escape
# The dashboard's fzf fallback: the client is shorter than the native menu.
O resize-window -t '=drv:' -x 100 -y 14
wait_for '[ "$(I display-message -c "$CL" -p "#{client_height}" 2>/dev/null)" = 14 ]' 50 || true
closes "dashboard fallback, Esc" "launch --dashboard-launch" 'interdimux ❯' Escape
O resize-window -t '=drv:' -x 100 -y 30
wait_for '[ "$(I display-message -c "$CL" -p "#{client_height}" 2>/dev/null)" = 30 ]' 50 || true

# --- Ctrl-C is a cancel, never a failure ------------------------------------------
# Ctrl-C in a dialog is a SIGINT to every process on the popup's terminal (see
# the navigator's main loop): the dialog cancels on it, and the navigator, and
# the /bin/sh that runs the popup's command, must carry on, or the popup is
# held as a failure over the dead dialog once Esc or Enter ends fzf.
closes "navigator, ^x, Ctrl-C, then Esc" "C-b f" '❯' "C-x wait:Kill%session C-c gone:Kill%session Escape"
I has-session -t '=victim' 2>/dev/null \
  && report "...and the Ctrl-C killed nothing" pass \
  || report "...and the Ctrl-C killed nothing" fail
closes "navigator, ^e, Ctrl-C, then Enter" "C-b f" '❯' "victim wait:▸%victim C-e wait:Rename%session C-c gone:Rename%session Enter"
# ...and that Enter is still the navigator's: it switches
[ "$(I list-clients -F '#{client_name} #{session_name}' | awk -v c="$CL" '$1 == c { print $2 }')" = victim ] \
  && report "...and the Enter after it switches" pass \
  || report "...and the Enter after it switches" fail
I switch-client -c "$CL" -t '=host:' 2>/dev/null || true
# And Ctrl-C as the popup opens, before fzf has the terminal.  Deterministic
# with an fzf whose --version stalls, which the navigator asks when the binding
# baked no version: one made with no fzf in sight.
mkdir -p "$TMPD/slow"
cat > "$TMPD/slow/fzf" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in --version) : > '$TMPD/probing'; sleep 20 ;; esac
exec '$(command -v fzf)' "\$@"
STUB
chmod +x "$TMPD/slow/fzf"
PATH="$TMPD/nofzf" bash "$SCRIPT" --bind-keys
I set-environment -g PATH "$TMPD/slow:$PATH0"
rm -f "$TMPD/probing"
key C-b f
if wait_for '[ -e "$TMPD/probing" ]' 100; then
  key C-c
  if wait_for '! popup_up' 50; then
    report "Ctrl-C as the navigator starts: the popup closes by itself" pass
  else
    report "Ctrl-C as the navigator starts: the popup closes by itself" fail
    ERRORS+="    screen: $(cap | grep -v '^ *$' | head -6 | tr '\n' '|')"$'\n'
    I display-popup -C -c "$CL" 2>/dev/null || true; wait_for '! popup_up' 30 || true
  fi
else
  report "setup: the navigator asks the slow fzf its version" fail
  I display-popup -C -c "$CL" 2>/dev/null || true; wait_for '! popup_up' 30 || true
fi
I set-environment -g PATH "$PATH0"
PATH="$PATH0" bash "$SCRIPT" --bind-keys

# --- a failure stays on screen until a key ---------------------------------------
# "Stays" can only be shown as "has not gone": once the text is up and the
# picker behind it has exited, it must survive a bounded wait for it to go.
stays() { # $1 = label, $2 = text it must show [, $3 = a second text]
  local label="$1" text="$2" more="${3:-}"
  if ! wait_for 'in_popup "$text"' 150; then
    report "$label: the error is shown in the popup" fail
    ERRORS+="    screen: $(cap | grep -v '^ *$' | head -6 | tr '\n' '|')"$'\n'
    I display-popup -C -c "$CL" 2>/dev/null || true; wait_for '! popup_up' 30 || true
    return 0
  fi
  report "$label: the error is shown in the popup" pass
  if [ -n "$more" ]; then
    if wait_for 'in_popup "$more"' 20; then
      report "$label: ...and $more" pass
    else
      report "$label: ...and $more" fail
      ERRORS+="    screen: $(cap | grep -v '^ *$' | head -6 | tr '\n' '|')"$'\n'
    fi
  fi
  # the navigator has exited once nothing of it holds our socket
  wait_for '! pgrep -f "^bash $SCRIPT\$" >/dev/null 2>&1' 50 || true
  if wait_for '! in_popup "$text"' 15; then
    report "$label: ...and stays there" fail
  else
    report "$label: ...and stays there" pass
  fi
  key q
  if wait_for '! popup_up' 50; then
    report "$label: ...until a key closes it" pass
  else
    report "$label: ...until a key closes it" fail
    I display-popup -C -c "$CL" 2>/dev/null || true; wait_for '! popup_up' 30 || true
  fi
}

I set-environment -g PATH "$TMPD/stub:$PATH0"
key C-b f
stays "fzf fails (exit 2)" 'stub-fzf: unknown option: --imux-bogus' 'fzf exited with status 2'
I set-environment -g PATH "$TMPD/nofzf"
key C-b f
stays "fzf is not on the server's PATH" 'interdimux: fzf is not installed'
# The other two places a popup is opened: --launch, which every dashboard entry
# runs, and the dashboard's own fzf fallback on a client too short for its menu.
# Each opens its popup itself, so each is a flag that can be lost on its own.
I set-environment -g PATH "$TMPD/stub:$PATH0"
launch --launch switch
stays "--launch switch, fzf fails" 'stub-fzf: unknown option: --imux-bogus' 'fzf exited with status 2'
O resize-window -t '=drv:' -x 100 -y 14
wait_for '[ "$(I display-message -c "$CL" -p "#{client_height}" 2>/dev/null)" = 14 ]' 50 || true
I set-environment -g PATH "$TMPD/nofzf"
launch --dashboard-launch
stays "dashboard fallback, fzf not on the server's PATH" 'interdimux: fzf is not installed'
O resize-window -t '=drv:' -x 100 -y 30
wait_for '[ "$(I display-message -c "$CL" -p "#{client_height}" 2>/dev/null)" = 30 ]' 50 || true
I set-environment -g PATH "$PATH0"

# --- the danger frame's repaint never opens a popup of its own ------------------------
# How many processes are still running the kill dialog for this server.
dialogs() {
  local p n=0
  for p in $(pgrep -f 'interdimux.sh --action kill' 2>/dev/null || true); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q "^TMUX=.*/$SOCK," && n=$((n + 1))
  done
  printf '%s' "$n"
}
# BUG-52: open the kill dialog from the navigator, then close the popup under it
if opens "kill dialog" "C-b f" '❯'; then
  key C-x
  if wait_for 'shows "Kill session"' 100; then
    I display-popup -C -c "$CL"
    wait_for '[ "$(dialogs)" = 0 ] && ! popup_up' 100 || true
    if popup_up; then
      report "closing the popup under a kill dialog leaves no popup behind" fail
      ERRORS+="    screen: $(cap | grep -v '^ *$' | head -4 | tr '\n' '|')"$'\n'
      I display-popup -C -c "$CL" 2>/dev/null || true
    else
      report "closing the popup under a kill dialog leaves no popup behind" pass
    fi
    if [ -r "/proc/$$/environ" ]; then
      [ "$(dialogs)" = 0 ] \
        && report "...and the dialog does not linger" pass \
        || report "...and the dialog does not linger" fail
    fi
    I has-session -t '=victim' 2>/dev/null \
      && report "...and nothing was killed" pass \
      || report "...and nothing was killed" fail
  else
    report "setup: ^x opens the kill dialog" fail
  fi
fi
I display-popup -C -c "$CL" 2>/dev/null || true
wait_for '! popup_up' 30 || true

# Run --action kill on its own, its dialog answered "n", and it must neither
# hang nor put a popup on the client.  In a pane of the outer server, so that
# it has a terminal of its own the way a run-shell or a binding's command does
# -- the popup's terminal is not the only one /dev/tty can open.
# $1 = label, $2 = a command to run it under.
bare_kill() {
  local label="$1" pre="$2" rc
  printf 'n' > "$TMPD/answer"
  rm -f "$TMPD/rc"
  O new-session -d -s run -x 80 -y 20 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' INTERDIMUX_CLIENT='$CL' INTERDIMUX_TTY_IN='$TMPD/answer' \
         INTERDIMUX_TTY_OUT=/dev/null INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 \
         INTERDIMUX_TMUX_VNUM=307 timeout -k 2 8 $pre bash '$SCRIPT' --action kill S:victim \
         </dev/null >/dev/null 2>&1; echo \$? > '$TMPD/rc'; sleep 30"
  wait_for '[ -s "$TMPD/rc" ]' 150 || true
  rc=$(cat "$TMPD/rc" 2>/dev/null || echo none)
  O kill-session -t '=run' 2>/dev/null || true
  [ "$rc" = 0 ] \
    && report "$label: does not hang" pass \
    || report "$label: does not hang (rc=$rc)" fail
  if popup_up; then
    report "$label: ...and opens no popup on the client" fail
    I display-popup -C -c "$CL" 2>/dev/null || true
    wait_for '! popup_up' 30 || true
  else
    report "$label: ...and opens no popup on the client" pass
  fi
  I has-session -t '=victim' 2>/dev/null \
    && report "$label: ...and kills nothing on a no" pass \
    || report "$label: ...and kills nothing on a no" fail
}
# BUG-53: outside any popup -- a hand-written binding, run-shell: no title
bare_kill "--action kill outside a popup" "env -u INTERDIMUX_TITLE"
# BUG-52, deterministically: the title says "in a popup", but the terminal is
# gone, which is the orphaned dialog's state once its popup has closed (its
# controlling tty hung up).  setsid gives a process no terminal at all.
if command -v setsid >/dev/null 2>&1; then
  bare_kill "a dialog whose popup has closed" "env INTERDIMUX_TITLE=interdimux setsid"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
