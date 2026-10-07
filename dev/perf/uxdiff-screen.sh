# shellcheck shell=bash
# uxdiff-screen.sh -- sourced by uxdiff.sh: the SCREEN scenarios.
#
# An outer private server ($OSOCK, status off, tmux-256color) has one pane,
# whose command is a client attached to the fixture server's `host` session.
# Keys typed into that pane arrive at the fixture server through a real client,
# so prefix+f fires the real binding and display-popup / display-menu draw on
# the client -- i.e. into the outer pane, where capture-pane -e reads them back
# with their colours.  No fixed sleeps: every step polls for the screen it
# needs (changed, stable for several polls, and no fzf callback still running).

SETTLED="" SETTLE_NOTE="" SCR_IDLE="" FIXTURE_BROKEN=0
declare -i N_TIMEOUTS=0

scr_attach() { # W H
  printf 'set -g default-terminal tmux-256color\nset -g status off\nset -s escape-time 10\n' > "$RUN/outer.conf"
  tout -f "$RUN/outer.conf" new-session -d -s drv -x "$1" -y "$2" \
    "exec env -u TMUX '$TMUXBIN' -L '$SOCK' attach-session -t '=host'" || return 1
  fx_until 200 client_attached || return 1
  FX_CLIENT=$(tin list-clients -F '#{client_name}' | head -1)
  fx_until 200 client_size_is "$1" "$2" || return 1
  # what the host pane shows when nothing is open: healing restores this
  fx_until 200 fx_prompt_in "$FX_HOST_PANE"
  host_pane_text > "$RUN/host-pane.0"
  local re; re=$(printf '%s' "$RUN" | sed 's/[][\.*^$+?(){}|]/\\&/g')
  PLUGIN_RE="$re/plugin/"
  CB_RE="$re/plugin/scripts/interdimux\.sh --(preview|footer-for|list|describe-create|create-key|dirs-list|dirs-preview|dirs-hints|session-name-for|hint-ladder|scope-prompt|jobs-list|sched-list|doctor)( |$)"
}
# The host pane's text, independent of the client's size (trailing blanks dropped)
host_pane_text() {
  tin capture-pane -p -t "$FX_HOST_PANE" 2>/dev/null | perl -0pe 's/[ \t]+$//mg; s/\n+\z/\n/'
}
client_attached() { [ -n "$(tin list-clients -F '#{client_name}' 2>/dev/null)" ]; }
client_size_is() { [ "$(tin list-clients -F '#{client_width}x#{client_height}' 2>/dev/null | head -1)" = "$1x$2" ]; }
key_table_is() { [ "$(tin list-clients -F '#{client_key_table}' 2>/dev/null | head -1)" = "$1" ]; }

# The outer pane exactly: the cursor, then every cell with its SGR.  One tmux
# call for both, so they describe the same instant.
# Canonicalised (uxdiff-canon.pl): only the VISIBLE style of each cell counts,
# for every comparison -- stability, "changed", idle -- and for the captures.
cap_full() {
  tout display-message -p -t '=drv:' 'cursor=#{cursor_x},#{cursor_y} visible=#{cursor_flag}' \; \
       capture-pane -p -e -t '=drv:' 2>/dev/null | perl "$SELF_DIR/uxdiff-canon.pl"
}
busy() { pgrep -f -- "$CB_RE" >/dev/null 2>&1; }

# settle [-q] [-d REF] [-m ERE] [-n POLLS] [-t SECONDS]
#   until the screen differs from REF, its text matches ERE, it has not changed
#   for POLLS polls (80 ms apart) and no fzf callback of the plugin is running.
#   SETTLED = that screen.  On timeout SETTLE_NOTE says why (and it goes into
#   the capture, so a side that never settles cannot pass as identical; it
#   holds nothing volatile, so a retry that times out the same way reproduces
#   byte for byte), the scenario's later steps are skipped, and a warning goes
#   to stderr.  -q: a housekeeping wait (closing, resizing) -- none of that.
settle() {
  local ref="" marker="" n=5 to=12 o OPTIND=1 quiet=0
  while getopts 'qd:m:n:t:' o; do
    case "$o" in q) quiet=1 ;; d) ref="$OPTARG" ;; m) marker="$OPTARG" ;; n) n="$OPTARG" ;; t) to="$OPTARG" ;; *) return 2 ;; esac
  done
  local deadline cur prev="" same=0 changed=1 mk=1 txt
  deadline=$(( ${EPOCHREALTIME/./} + to * 1000000 ))
  [ -n "$ref" ] && changed=0
  [ -n "$marker" ] && mk=0
  SETTLE_NOTE=""
  while :; do
    cur=$(cap_full)
    if [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; prev="$cur"; fi
    [ "$changed" = 0 ] && [ "$cur" != "$ref" ] && changed=1
    # the marker is tested on the screen as it is NOW, not latched from a
    # frame that has since gone (a closing popup can show it on its way out)
    if [ -n "$marker" ]; then txt=$(plain <<< "$cur"); if [[ "$txt" =~ $marker ]]; then mk=1; else mk=0; fi; fi
    if [ "$changed" = 1 ] && [ "$mk" = 1 ] && [ "$same" -ge "$n" ] && ! busy; then
      SETTLED="$cur"; return 0
    fi
    if [ "${EPOCHREALTIME/./}" -ge "$deadline" ]; then
      SETTLED="$cur"
      SETTLE_NOTE="settle timeout after ${to}s (changed=$changed marker=$mk)"
      if [ "$quiet" = 0 ]; then
        SC_TIMEDOUT=1
        (( N_TIMEOUTS += 1 ))
        printf 'uxdiff: [%s %s] %s (stable for %d polls; a callback running: %s)\n' "$CUR_SIDE" \
          "${SC_FILE#"$OUT"/?/}" "$SETTLE_NOTE" "$same" "$(busy && echo yes || echo no)" >&2
      fi
      return 1
    fi
    sleep 0.08
  done
}

key() { tout send-keys -t '=drv:' "$@"; }
lit() { tout send-keys -t '=drv:' -l -- "$1"; }
# a real prefix key press: C-b, and only once the client is IN the prefix table
prefix() {
  key C-b
  fx_until 100 key_table_is prefix || true
  key "$1"
}
# step [-w] [settle options] -- KEYS... : press, then wait for the screen it
# makes -- one that differs from the screen before the keys, or, with -w (a key
# whose result may legitimately redraw the same screen, e.g. a reload), the
# plugin callback it starts to come and go.
step() {
  local -a sa=()
  local wcb=0
  while [ "$1" != -- ]; do
    if [ "$1" = -w ]; then wcb=1; else sa+=("$1"); fi
    shift
  done
  shift
  # Once a step has not settled the scenario is a DIFF whatever follows, and
  # its keys would land on an unknown screen: record the rest as skipped
  # rather than paying a timeout per step (a broken B stays fast to report).
  if [ "${SC_TIMEDOUT:-0}" = 1 ]; then
    SETTLED=$(cap_full); SETTLE_NOTE="skipped: an earlier step did not settle"
    return 1
  fi
  local before; before=$(cap_full)
  if [ "$1" = -l ]; then lit "$2"; elif [ "$1" = -p ]; then prefix "$2"; else key "$@"; fi
  if [ "$wcb" = 1 ]; then
    fx_until 40 busy || true
    settle ${sa[@]+"${sa[@]}"}
  else
    settle -d "$before" ${sa[@]+"${sa[@]}"}
  fi
}

shot() { # $1 = section title: append the settled screen to the scenario file
  {
    printf '### %s\n' "$1"
    [ -n "$SETTLE_NOTE" ] && printf '[uxdiff: %s]\n' "$SETTLE_NOTE"
    printf '%s\n' "$SETTLED"
  } | norm >> "$SC_FILE"
}
note() { printf '[uxdiff: %s]\n' "$*" | norm >> "$SC_FILE"; }

# --- per-scenario setup / teardown ------------------------------------------
fx_layout() {
  tin list-panes -a -F '#{session_id} #{session_name} #{window_id} #{window_index} #{window_name} zoom=#{window_zoomed_flag} active=#{window_active} #{pane_id} #{pane_index} pact=#{pane_active}' 2>&1
  tin list-clients -F 'client on #{client_session}' 2>&1
}
scr_begin() {
  SC_TIMEDOUT=0
  fx_bind_keys
  msg_mark
  [ "$(cap_full)" = "$SCR_IDLE" ] || { settle -q -n 3 -t 5; [ "$SETTLED" = "$SCR_IDLE" ] || note "the screen was not idle at the start"; }
}
close_overlays() { local keep="${SC_TIMEDOUT:-0}"; _close_overlays; SC_TIMEDOUT="$keep"; }
_close_overlays() {
  local i before
  # first let anything closing close by itself
  settle -q -n 3 -t 5
  for (( i = 0; i < 5; i++ )); do
    before=$(cap_full)
    [ "$before" = "$SCR_IDLE" ] && return 0
    key Escape
    settle -q -d "$before" -n 3 -t 5 || true
  done
  [ "$(cap_full)" = "$SCR_IDLE" ] && return 0
  tin display-popup -C -c "$FX_CLIENT" 2>/dev/null
  settle -q -n 3 -t 5
  [ "$SETTLED" = "$SCR_IDLE" ] || note "an overlay would not close"
}
wait_quiet() {
  local i
  for (( i = 0; i < 100; i++ )); do
    pgrep -f -- "$PLUGIN_RE" >/dev/null 2>&1 || return 0
    sleep 0.05
  done
  printf 'uxdiff: [%s %s] plugin processes outlived the scenario by 5 s; killed:\n' "$CUR_SIDE" "${SC_FILE#"$OUT"/?/}" >&2
  pgrep -af -- "$PLUGIN_RE" | norm | cut -c1-160 | sed 's/^/    /' >&2
  pkill -9 -f -- "$PLUGIN_RE" 2>/dev/null
  sleep 0.2
}
heal_host() {
  tin respawn-pane -k -c "$P_ALPHA" -t "$FX_HOST_PANE" 2>/dev/null
  tin clear-history -t "$FX_HOST_PANE" 2>/dev/null
  fx_until 200 fx_prompt_in "$FX_HOST_PANE"
  settle -q -n 5 -t 10
  SCR_IDLE="$SETTLED"
}
# Side effects a user can see, appended to the scenario's file: status-line
# messages on the attached client, and changes to errors.log (which Health reports) and to the
# recent-directory list.  tmux's message log lists the NEWEST entry first, and
# also logs every command a client sent and every key binding run (`key f:
# <the binding>`): those are implementation, so only `message:` lines count.
msg_mark() { MSG_N=$(tin show-messages 2>/dev/null | grep -c .); }
side_effects() {
  local msgs f all total
  all=$(tin show-messages 2>/dev/null)
  total=$(printf '%s\n' "$all" | grep -c .)
  msgs=""
  if [ "$total" -gt "$MSG_N" ]; then
    # only what reached the USER's client (its status line); a command client's
    # own errors (`client-<pid> message: can't find pane`) are logged too, but
    # nobody sees them
    msgs=$(printf '%s\n' "$all" | head -n "$(( total - MSG_N ))" | grep -F " $FX_CLIENT message: " \
           | sed -E 's/^[0-9]{2}:[0-9]{2}: [^ ]+ message: //' | tac)
  fi
  [ -z "$msgs" ] || { printf '### tmux messages\n%s\n' "$msgs" | norm >> "$SC_FILE"; }
  for f in .local/state/interdimux/errors.log .local/share/interdimux/recent_dirs; do
    if ! cmp -s "$FH/$f" "$RUN/snap/tree/$f"; then
      { printf '### %s changed\n' "$f"
        diff "$RUN/snap/tree/$f" "$FH/$f" | sed -E 's/^([<>] == )[0-9-]+ [0-9:]+/\1<TS>/'
      } | norm >> "$SC_FILE"
    fi
  done
}
scr_end() {
  close_overlays
  wait_quiet
  pkill -9 -f -- "^sleep-hold-$UXID( |$)" 2>/dev/null
  side_effects
  # the fixture must be as it was, or every later scenario is compromised
  fx_layout > "$RUN/layout.now"
  if ! cmp -s "$RUN/layout.0" "$RUN/layout.now"; then
    { printf '### FIXTURE CHANGED by this scenario\n'; diff "$RUN/layout.0" "$RUN/layout.now"; } | norm >> "$SC_FILE"
    # shellcheck disable=SC2034  # read by uxdiff.sh's run_scenario
    FIXTURE_BROKEN=1
  fi
  if ! host_pane_text | cmp -s - "$RUN/host-pane.0"; then
    note "a key reached the host pane's shell instead of an overlay (pane healed)"
    heal_host
  fi
}

# --- the scenarios ------------------------------------------------------------
# prefix+f, waiting for the navigator: its prompt is drawn and the list is in
open_nav() { step -m '❯' -- -p f; }

s_nav_initial() {
  scr_begin
  open_nav; shot "prefix+f"
  scr_end
}
s_nav_initial_env() { # $1 = VAR=value set in the server's global environment for the popup
  tin set-environment -g "${1%%=*}" "${1#*=}"
  s_nav_initial
  tin set-environment -gu "${1%%=*}"
}
# A user's option, set the way users set it (a tmux option: the binding
# forwards @interdimux-* into the popup), around a scenario.
s_with_opt() { # OPTION VALUE FUNC [ARGS...]
  local o="$1" v="$2"; shift 2
  tin set -g "$o" "$v"
  "$@"
  tin set -gu "$o"
}
s_nav_query() {
  scr_begin
  open_nav
  step -- -l infra; shot "typed 'infra'"
  step -- -l zzqx; shot "typed 'zzqx' too (no match: the create announcement)"
  step -- BSpace BSpace BSpace BSpace; shot "back to 'infra'"
  step -- C-u; shot "query cleared (C-u)"
  scr_end
}
s_nav_dimmed() {
  scr_begin
  open_nav
  step -- -l agents; shot "typed 'agents' (raw mode: the rest dimmed)"
  step -- Up; shot "Up: the cursor on a dimmed row"
  step -- C-x; shot "C-x on the dimmed row"
  step -- Down Down; shot "Down Down: back among the matches"
  scr_end
}
s_nav_preview() {
  scr_begin
  open_nav
  step -- C-_; shot "C-/ (preview shown)"
  step -- Down; shot "Down: the preview follows (a window row)"
  step -- Down Down Down; shot "a window with an agent"
  step -- C-_; shot "C-/ again (preview hidden)"
  scr_end
}
s_nav_scope() {
  scr_begin
  open_nav
  step -- C-]; shot "C-] once"
  step -- C-]; shot "C-] twice"
  step -- -l bash; shot "typed 'bash' in that scope"
  scr_end
}
s_dialog() { # $1 = the key (C-x kill, C-e rename, C-t send keys), $2 = query
  scr_begin
  open_nav
  step -- -l "$2"; shot "typed '$2'"
  step -- "$1"; shot "$1: the dialog"
  if [ "$1" != C-x ]; then
    step -- -l 'ab' ; shot "typed 'ab' into the dialog"
  fi
  step -- Escape; shot "Escape: back in the navigator"
  scr_end
}
s_dirs() {
  scr_begin
  open_nav
  step -- C-o; shot "C-o: the directory picker"
  step -- -l level; shot "typed 'level'"
  step -- C-f; shot "C-f: deep search"
  step -- C-r; shot "C-r: reset"
  step -- Escape; shot "Escape: the navigator resumes"
  scr_end
}
# The rename dialog's line editor: the keys every terminal sends (no
# ESC-prefixed meta chords, whose handling is being fixed this round).
s_rename_edit() {
  scr_begin
  open_nav
  step -- -l infra
  step -- C-e;               shot "C-e: the rename dialog, the name pre-filled"
  step -- C-u;               shot "C-u"
  step -- -l 'new name';     shot "typed 'new name'"
  step -- Left Left Left;    shot "Left x3"
  step -- -l X;              shot "typed X mid-word"
  step -- Home;              shot "Home"
  step -- End;               shot "End"
  step -- C-a;               shot "C-a"
  step -- Right Right;       shot "Right x2"
  step -- Delete;            shot "Delete"
  step -- C-e;               shot "C-e"
  step -- C-w;               shot "C-w"
  step -- BSpace BSpace;     shot "BSpace x2"
  step -- Escape;            shot "Escape: cancelled, back in the navigator"
  scr_end
}
open_dash() { # prefix+g; the menu (or the fallback popup) must be up
  step -- -p g
  [ "$SETTLED" != "$SCR_IDLE" ]
}
s_dashboard() {
  scr_begin
  open_dash; shot "prefix+g"
  scr_end
}
s_dash_item() { # $1 = menu key, $2 = title
  scr_begin
  if open_dash; then
    step -- "$1"; shot "$2"
    [ "$1" = h ] && { step -w -- C-r; shot "C-r: recheck"; }
  else
    shot "prefix+g drew nothing (so '$1' was not pressed)"
  fi
  scr_end
}
# The fzf fallback dashboard (a client shorter than the native menu): typing filters
s_dash_fallback_filter() {
  scr_begin
  if open_dash; then
    shot "prefix+g (fallback)"
    step -- -l he;   shot "typed 'he'"
    step -- BSpace BSpace; shot "query erased"
  else
    shot "prefix+g drew nothing"
  fi
  scr_end
}
# Each of the dashboard's picker modes, opened from the menu and closed again
s_dash_modes() {
  scr_begin
  local k
  for k in r i w z d t; do
    if [ "$SC_TIMEDOUT" = 1 ]; then
      SETTLED=$(cap_full); SETTLE_NOTE="skipped: an earlier step did not settle"
      shot "prefix+g then $k"
      continue
    fi
    if open_dash; then
      step -m '❯' -- "$k"; shot "prefix+g then $k"
    else
      shot "prefix+g drew nothing (so '$k' was not pressed)"
    fi
    close_overlays
    wait_quiet
  done
  scr_end
}
# Schedule: the target picker, its dialog, cancelled (the fake at is never reached)
s_schedule() {
  scr_begin
  if open_dash; then
    step -m '❯' -- a;  shot "prefix+g then a: pick what to schedule into"
    step -- -l infra;  shot "typed 'infra'"
    step -- Enter;     shot "Enter: the schedule dialog"
    step -- -l 5m;     shot "typed '5m'"
    step -- Escape;    shot "Escape: cancelled"
  else
    shot "prefix+g drew nothing"
  fi
  scr_end
}
s_health_seeded() {
  printf '%s' "$SEEDED_ERRLOG" > "$FH/.local/state/interdimux/errors.log"
  cp "$FH/.local/state/interdimux/errors.log" "$RUN/snap/tree/.local/state/interdimux/errors.log"
  s_dash_item h "Health, with a seeded errors.log"
  : > "$RUN/snap/tree/.local/state/interdimux/errors.log"
}
s_jobs() {
  # The empty-queue flash lasts 0.9 s; the fake sleep (first on the popup's
  # PATH for this scenario only) holds it on screen until it is captured.
  tin set-environment -g PATH "$RUN/holdbin:$FXPATH"
  scr_begin
  local before; before=$(cap_full)
  tin run-shell -b "TMUX_PANE=$FX_HOST_PANE INTERDIMUX_CLIENT=$FX_CLIENT bash '$SCRIPT' --launch jobs"
  settle -d "$before"; shot "--launch jobs (what the dashboard's Jobs runs): the empty queue"
  tin set-environment -g PATH "$FXPATH"
  tin display-popup -C -c "$FX_CLIENT" 2>/dev/null
  scr_end
}

fx_holdbin() {
  mkdir -p "$RUN/holdbin"
  cat > "$RUN/holdbin/sleep" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  0.*|[1-4]|[1-4].*) exec -a "sleep-hold-$UXID" /bin/sleep 120 ;;
esac
exec /bin/sleep "\$@"
EOF
  chmod +x "$RUN/holdbin/sleep"
}

scr_size() { # W H
  tout resize-window -t '=drv:' -x "$1" -y "$2"
  fx_until 200 client_size_is "$1" "$2" || echo "uxdiff: the client did not reach $1x$2" >&2
  settle -q -n 6 -t 10
  SCR_IDLE="$SETTLED"
}

screen_scenarios() {
  fx_holdbin
  local size w h p
  for size in 120x40 80x24 80x16; do
    w=${size%x*} h=${size#*x} p="$size"
    scr_size "$w" "$h"
    run_scenario screen "$p/nav-initial" s_nav_initial
    if [ "$size" = 80x16 ]; then
      # a client shorter than the native menu: prefix+g falls back to fzf
      run_scenario screen "$p/dashboard-fallback" s_dashboard
      run_scenario screen "$p/dashboard-fallback-filter" s_dash_fallback_filter
      continue
    fi
    [ "$size" = 120x40 ] && run_scenario screen "$p/nav-initial-bash-renderer" s_nav_initial_env INTERDIMUX_USE_RUST=off
    [ "$size" = 120x40 ] && run_scenario screen "$p/nav-initial-preview-on" s_with_opt @interdimux-show-preview on s_nav_initial
    run_scenario screen "$p/nav-query" s_nav_query
    [ "$size" = 120x40 ] && run_scenario screen "$p/nav-query-raw-off" s_with_opt @interdimux-raw off s_nav_query
    run_scenario screen "$p/nav-raw-dimmed" s_nav_dimmed
    run_scenario screen "$p/nav-preview" s_nav_preview
    [ "$size" = 120x40 ] && run_scenario screen "$p/nav-scope" s_nav_scope
    run_scenario screen "$p/kill-dialog" s_dialog C-x infra
    run_scenario screen "$p/rename-dialog" s_dialog C-e infra
    [ "$size" = 120x40 ] && run_scenario screen "$p/rename-dialog-editing" s_rename_edit
    run_scenario screen "$p/send-dialog" s_dialog C-t infra
    run_scenario screen "$p/dirs-picker" s_dirs
    run_scenario screen "$p/dashboard" s_dashboard
    [ "$size" = 120x40 ] && run_scenario screen "$p/dashboard-modes" s_dash_modes
    [ "$size" = 120x40 ] && run_scenario screen "$p/schedule-dialog" s_schedule
    run_scenario screen "$p/health" s_dash_item h "h: Health"
    [ "$size" = 120x40 ] && run_scenario screen "$p/health-errlog-seeded" s_health_seeded
    run_scenario screen "$p/jobs" s_jobs
    run_scenario screen "$p/agents" s_dash_item e "e: Agents"
  done
}
