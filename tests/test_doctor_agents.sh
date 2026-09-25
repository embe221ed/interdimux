#!/usr/bin/env bash
#
# --doctor's agents section: which of the signals a coding agent sends reach
# tmux, and the one setting that fixes a missing one (review AGENT-14).
#
# Everything runs against a FAKE HOME: the section reads ~/.claude and ~/.codex,
# and the developer's real ones must never be read (or their values printed)
# by a test.  Each case builds the files it needs there, toggles the tmux side
# on a private server, and asserts the exact lines of the section.
#
# The files the section must never open -- ~/.codex/auth.json,
# ~/.claude/.credentials.json and the sessions/<pid>.<hash>.key files -- are
# FIFOs here.  Opening a FIFO for reading blocks until a writer comes, so a
# doctor that so much as opened one would hang, and the timeout says so.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
unset INTERDIMUX_USE_RUST
SOCK="interdimux-doctor-agents-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-doctor-agents.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  chmod -R u+rwX "$TMPD" 2>/dev/null || true
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
# $1 = name, $2 = haystack, $3 = needle: pass when the needle is in it.
has()   { case "$2" in *"$3"*) report "$1" pass ;; *) report "$1" fail; ERRORS+="      wanted: $3"$'\n'"      in:"$'\n'"$(printf '%s\n' "$2" | sed 's/^/        /')"$'\n' ;; esac; }
hasnt() { case "$2" in *"$3"*) report "$1" fail; ERRORS+="      did not want: $3"$'\n' ;; *) report "$1" pass ;; esac; }

echo "interdimux doctor agents tests"
echo

# The environment the server copies, pinned before it starts: --doctor reads
# the popups' environment, which is the server's.  Nothing an agent or a
# terminal might have left in the developer's shell may decide a case.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE TMUX TMUX_PANE XDG_CONFIG_HOME \
      CLAUDE_CONFIG_DIR CODEX_HOME CLAUDE_CODE_DISABLE_TERMINAL_TITLE \
      INTERDIMUX_CLAUDE_DIR INTERDIMUX_TITLE_RULES INTERDIMUX_AGENT_STATE \
      GHOSTTY_RESOURCES_DIR WEZTERM_VERSION ITERM_SESSION_ID ITERM_PROFILE \
      ITERM_PROFILE_NAME TERM_SESSION_ID KITTY_WINDOW_ID ALACRITTY_SOCKET \
      KONSOLE_VERSION GNOME_TERMINAL_SCREEN VTE_VERSION WT_SESSION
export HOME="$TMPD/home"
mkdir -p "$HOME"

tmux -f /dev/null -L "$SOCK" new-session -d -s agdoc -x 120 -y 40
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_AT_DAEMON=up

tm()      { tmux -L "$SOCK" "$@"; }
setopt()  { tm set -g "@interdimux-$1" "$2"; }
unsetopt() { tm set -gu "@interdimux-$1" 2>/dev/null || true; }
senv()    { tm set-environment -g "$1" "$2"; }
unsenv()  { tm set-environment -gu "$1" 2>/dev/null || true; }

# The report, colours stripped; RC holds its exit status.  Under a timeout: a
# doctor that opened one of the FIFOs would block for ever.
RC=0
doctor() {
  local out
  RC=0
  out=$(timeout 60 bash "$SCRIPT" --doctor 2>&1) || RC=$?
  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g'
}
# Just the agents section: from its heading to the next line that is not
# indented (a section heading, or the closing rule).
section() { awk '/^agents / { f = 1; next } /^[^ ]/ { f = 0 } f'; }
# Runs it in THIS shell (RC survives), the section in $out.  Every run is
# also checked for a "stderr" section: the unreadable files and the FIFOs
# below must not make a single check complain.
STDERR_HITS=""
ag() {
  doctor > "$TMPD/report"
  out=$(section < "$TMPD/report")
  if grep -q '^stderr ' "$TMPD/report"; then
    STDERR_HITS+="$(sed -n '/^stderr /,$p' "$TMPD/report" | head -6)"$'\n'
  fi
}

# Back to a known state: tmux's defaults for every option the section reads,
# none of the variables, no agent files.
reset() {
  tm set -g allow-set-title on
  tm setw -g monitor-bell on
  tm set -g bell-action any
  tm set -g allow-passthrough off
  tm set -g focus-events off
  tm set -g default-terminal tmux-256color
  local v
  for v in CLAUDE_CODE_DISABLE_TERMINAL_TITLE CLAUDE_CONFIG_DIR CODEX_HOME GHOSTTY_RESOURCES_DIR; do unsenv "$v"; done
  unsetopt title-rules; unsetopt claude-dir; unsetopt agent-state
  chmod -R u+rwX "$HOME" 2>/dev/null || true
  rm -rf "$HOME/.claude" "$HOME/.codex" "$HOME/.config"
}

bash "$SCRIPT" --bind-keys
reset

# --- nothing installed -------------------------------------------------------
ag
BASE_RC=$RC
[ "$BASE_RC" = 0 ] && report "baseline: a healthy install exits 0" pass \
                   || { report "baseline: a healthy install exits 0 (got $BASE_RC)" fail; ERRORS+="$(grep '✗' "$TMPD/report" || true)"$'\n'; }
has "tmux's defaults: titles reach tmux" "$out" "  ✓ tmux takes the titles programs set (allow-set-title on)"
has "tmux's defaults: a bell flags its window" "$out" "  ✓ a bell flags its window with ! (monitor-bell on)"
has "no title rules file: one dim line" "$out" "      title rules: none of your own (~/.config/interdimux/titles) — the built-in ones apply"
has "no plugin options set: one dim line" "$out" "      plugin options: no pane publishes an agent's state"
has "no ~/.claude: Claude is one skip line" "$out" "      Claude Code: no ~/.claude — skipped"
has "no ~/.codex: Codex is one skip line" "$out" "      Codex: no ~/.codex — skipped"
n=$(printf '%s\n' "$out" | grep -c 'Claude' || true)
[ "$n" = 1 ] && report "...and nothing else about Claude" pass || report "...and nothing else about Claude ($n lines)" fail

# --- tmux ------------------------------------------------------------------------
tm set -g allow-set-title off
ag
has "allow-set-title off is a warning" "$out" "  ⚠ allow-set-title is off — the titles agents set (what they are working on) never reach tmux"
has "...naming the fix" "$out" "      set -g allow-set-title on"
tm set -g allow-set-title on
# The effective value for THIS pane: an override on the pane counts.
tm set -p -t "$TMUX_PANE" allow-set-title off
ag
has "a pane's own allow-set-title off counts" "$out" "  ⚠ allow-set-title is off"
tm set -pu -t "$TMUX_PANE" allow-set-title

tm setw -g monitor-bell off
ag
has "monitor-bell off is a warning" "$out" "  ⚠ monitor-bell is off — an agent's bell never flags its window, so no row shows it waits on you"
has "...naming the fix" "$out" "      setw -g monitor-bell on"
tm setw -g monitor-bell on

# bell-action none is a note, not a warning, because the flag still appears.
# tmux is the authority for that: ring a bell in a background window and ask it.
tm set -g bell-action none
ag
has "bell-action none keeps the tick" "$out" "  ✓ a bell flags its window with ! (monitor-bell on)"
has "...with a note saying what it does stop" "$out" "      bell-action is none: the ! still appears, but tmux passes no bell on to your terminal"
tm new-window -d -t agdoc -n belltest
bell_tty=$(tm display-message -p -t '=agdoc:belltest' '#{pane_tty}')
printf '\a' > "$bell_tty"
flag=0
for _ in $(seq 1 100); do
  flag=$(tm display-message -p -t '=agdoc:belltest' '#{window_bell_flag}')
  [ "$flag" = 1 ] && break
  sleep 0.05
done
[ "$flag" = 1 ] && report "...and tmux does flag a bell under bell-action none (the note is true)" pass \
                || report "...and tmux does flag a bell under bell-action none (the note is true)" fail
tm kill-window -t '=agdoc:belltest'
tm set -g bell-action any

# --- your title rules ------------------------------------------------------------
mkdir -p "$HOME/.config/interdimux"
cat > "$HOME/.config/interdimux/titles" <<'EOF'
# a comment, and a blank line, are neither rules nor mistakes

lazygit   -        $1   lazygit - *
lazygit   -        $1
myagent   waiting  -    [?] *
@bad.name idle     -    x
@my_state approve  -    blocked
EOF
ag
has "your rules file: counted" "$out" "  ✓ your title rules: ~/.config/interdimux/titles holds 4 rules, read before the built-in ones"
has "a line that is not a rule is named by its number" "$out" "      line 4 is not a rule (APPS STATE DESC PATTERN), so it is skipped"
has "a STATE that is not a state word is named" "$out" "      line 5: its STATE is not one of approve input working idle done error, or -"
has "an option name tmux cannot be asked for is named" "$out" "      line 6: @bad.name is not an option name tmux can be asked for, so it is never read"
hasnt "the comment and the blank line are not flagged" "$out" "line 1"
hasnt "...(nor the blank line)" "$out" "line 2"
hasnt "...nor the good rules" "$out" "line 3"
chmod 000 "$HOME/.config/interdimux/titles"
ag
has "an unreadable rules file is a warning" "$out" "  ⚠ your title rules at ~/.config/interdimux/titles cannot be read — only the built-in ones apply"
chmod 644 "$HOME/.config/interdimux/titles"
setopt title-rules '~/nowhere/titles'
ag
has "@interdimux-title-rules naming no file is a warning" "$out" "  ⚠ @interdimux-title-rules names ~/nowhere/titles, which does not exist — only the built-in rules apply"
unsetopt title-rules

# --- what agent plugins publish ----------------------------------------------------
# Three panes: two carry tmux-agent-sidebar's options, one our own @agent_state,
# and the rules file above reads @my_state.  The first pane's window is linked
# into a second session too, so list-panes -a shows it twice: it is one pane.
tm new-window -d -t agdoc -n plug
tm split-window -d -t '=agdoc:plug'
tm split-window -d -t '=agdoc:plug'
mapfile -t PP < <(tm list-panes -t '=agdoc:plug' -F '#{pane_id}')
tm set -p -t "${PP[0]}" @pane_status 'SENTINEL-VALUE-1'
tm set -p -t "${PP[1]}" @pane_status running
tm set -p -t "${PP[1]}" @pane_wait_reason permission_prompt
tm set -p -t "${PP[2]}" @agent_state working
tm set -p -t "${PP[2]}" @my_state blocked
tm new-session -d -s agdoc2
tm link-window -s '=agdoc:plug' -t '=agdoc2:'
ag
has "published options: the panes that carry any" "$out" "  ✓ agent state is published on 3 panes, as options the list reads"
has "...tmux-agent-sidebar's, both names, on its two panes" "$out" "      tmux-agent-sidebar publishes @pane_status, @pane_wait_reason on 2 panes"
has "...ours" "$out" "      your hooks publish @agent_state on 1 pane"
has "...and one only your rules read" "$out" "      @my_state, which your title rules read, is set on 1 pane"
hasnt "no option's VALUE is shown" "$(cat "$TMPD/report")" "SENTINEL-VALUE"
setopt agent-state off
ag
has "agent-state off: said, since no row shows it then" "$out" "      @interdimux-agent-state is off, so no row shows any of it as a state"
unsetopt agent-state
tm kill-session -t '=agdoc2'
tm kill-window -t '=agdoc:plug'
rm -rf "$HOME/.config"

# --- Claude Code -------------------------------------------------------------------
mkdir -p "$HOME/.claude"
ag
has "~/.claude with no sessions dir: a note, not a warning" "$out" "      Claude Code: no session registry at ~/.claude/sessions — an older Claude writes none, and its rows then show no state"
has "auto on a TERM auto has no channel for: Claude sends nothing" "$out" "  ⚠ Claude sends no notifications here at all"
has "...saying why" "$out" "      preferredNotifChannel is not set (auto), and auto has no channel for the panes' TERM, tmux-256color"
has "...and the bell is the fix" "$out" "      to have it ring the bell, which tmux flags: \"preferredNotifChannel\": \"terminal_bell\" in ~/.claude/settings.json"

# auto, and the panes' TERM is xterm-ghostty: Ghostty's OSC 777, in passthrough.
tm set -g default-terminal xterm-ghostty
tm set -g allow-passthrough on
ag
has "auto + xterm-ghostty + passthrough on: a warning" "$out" "  ⚠ Claude's notifications go to Ghostty through tmux passthrough — tmux never sees them"
has "...saying how" "$out" "      preferredNotifChannel is not set (auto) and the panes' TERM is xterm-ghostty, so Claude sends OSC 777 wrapped for passthrough"
has "...that a background pane's alert is dropped" "$out" "      allow-passthrough is on: only a pane on screen gets through — a background agent's alert is dropped"
has "...the bell as the fix" "$out" "      to have tmux flag the window instead: \"preferredNotifChannel\": \"terminal_bell\" in ~/.claude/settings.json"
has "...and passthrough all, with its caveat" "$out" "      or: set -g allow-passthrough all — but then any hidden pane can write to your terminal"
tm set -g allow-passthrough off
ag
has "passthrough off: they reach nothing" "$out" "      allow-passthrough is off: tmux drops every one of them"
tm set -g allow-passthrough all
ag
has "passthrough all: they reach Ghostty, a tick" "$out" "  ✓ Claude's notifications reach Ghostty from every pane (allow-passthrough all), but tmux never sees them"
has "...but no row is flagged" "$out" "      no row gets a ! for them; \"preferredNotifChannel\": \"terminal_bell\" in ~/.claude/settings.json would give it one"
tm set -g allow-passthrough on

printf '{\n  "theme": "dark",\n  "preferredNotifChannel": "terminal_bell"\n}\n' > "$HOME/.claude/settings.json"
ag
has "terminal_bell: a tick" "$out" "  ✓ Claude rings the bell when it needs you (preferredNotifChannel is \"terminal_bell\") — tmux flags its window"
hasnt "...and no passthrough warning" "$out" "passthrough —"
printf '{"preferredNotifChannel":"kitty"}' > "$HOME/.claude/settings.json"
ag
has "an explicit kitty channel: OSC 99 in passthrough" "$out" "      preferredNotifChannel is \"kitty\", so Claude sends OSC 99 wrapped for passthrough"
printf '{"preferredNotifChannel":"notifications_disabled"}' > "$HOME/.claude/settings.json"
ag
has "notifications_disabled: a note" "$out" "      Claude Code: its notifications are turned off (preferredNotifChannel is \"notifications_disabled\")"
printf '{"preferredNotifChannel":"carrier_pigeon"}' > "$HOME/.claude/settings.json"
ag
has "a channel this does not know: unknown, not wrong" "$out" "      Claude Code: preferredNotifChannel in ~/.claude/settings.json holds a value this check does not know — unknown"
printf 'not json at all' > "$HOME/.claude/settings.json"
ag
has "settings.json that is not a JSON object: unknown" "$out" "      Claude Code: ~/.claude/settings.json could not be read — where its notifications go is unknown"
printf '{}' > "$HOME/.claude/settings.json"; chmod 000 "$HOME/.claude/settings.json"
ag
has "an unreadable settings.json: unknown" "$out" "      Claude Code: ~/.claude/settings.json could not be read — where its notifications go is unknown"
chmod 644 "$HOME/.claude/settings.json"
printf '{"hooks":{"Notification":[]}}' > "$HOME/.claude/settings.json"
ag
has "hooks in settings.json: a note" "$out" "      ~/.claude/settings.json defines hooks (not inspected here), which may deliver alerts of their own"
rm -f "$HOME/.claude/settings.json"
tm set -g default-terminal tmux-256color
tm set -g allow-passthrough off

# CLAUDE_CODE_DISABLE_TERMINAL_TITLE: a boolean to Claude (1/true/yes/on).
senv CLAUDE_CODE_DISABLE_TERMINAL_TITLE 1
ag
has "DISABLE_TERMINAL_TITLE in tmux's environment: a warning" "$out" "  ⚠ CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in tmux's environment — Claude sets no title, and names no session"
has "...naming how to unset it" "$out" "      tmux set-environment -gu CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
senv CLAUDE_CODE_DISABLE_TERMINAL_TITLE ' TRUE '
ag
has "...in any case, trimmed" "$out" "  ⚠ CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in tmux's environment"
senv CLAUDE_CODE_DISABLE_TERMINAL_TITLE 0
ag
hasnt "...but 0 is off to Claude: no warning" "$out" "DISABLE_TERMINAL_TITLE"
unsenv CLAUDE_CODE_DISABLE_TERMINAL_TITLE
printf '{"env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"}}' > "$HOME/.claude/settings.json"
ag
has "DISABLE_TERMINAL_TITLE in settings.json's env: a warning" "$out" "  ⚠ CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in ~/.claude/settings.json — Claude sets no title, and names no session"
rm -f "$HOME/.claude/settings.json"

# The registry.  A live record for a real pane (its pid, its start time from
# /proc), a dead one, a half-written one, an unreadable one, a file that is not
# <digits>.json, and the key file Claude keeps beside a record: a FIFO, so
# opening it would hang the doctor.  The credentials file likewise.
REG="$HOME/.claude/sessions"
mkdir -p "$REG"
tm new-window -d -t agdoc -n cl "exec sleep 600"
CL_PANE=$(tm display-message -p -t '=agdoc:cl' '#{pane_id}')
CL_PID=$(tm display-message -p -t '=agdoc:cl' '#{pane_pid}')
for _ in $(seq 1 100); do [ "$(cat "/proc/$CL_PID/comm" 2>/dev/null)" = sleep ] && break; sleep 0.05; done
read -r -a _st < "/proc/$CL_PID/stat"
CL_START="${_st[21]}"   # field 22; comm is `sleep`, no blank, so the index holds
printf '{"pid":%s,"sessionId":"x","procStart":"%s","kind":"interactive","tmux":"agdoc:@1.%s","status":"busy","statusUpdatedAt":1}' \
  "$CL_PID" "$CL_START" "$CL_PANE" > "$REG/$CL_PID.json"
printf '{"pid":999999,"procStart":"1","kind":"interactive","tmux":"agdoc:@1.%s","status":"idle"}' "$CL_PANE" > "$REG/999999.json"
printf '{"pid":5,"stat' > "$REG/5.json"
printf '{"pid":6,"status":"busy"}' > "$REG/6.json"; chmod 000 "$REG/6.json"
printf 'junk' > "$REG/notes.json"
mkfifo "$REG/$CL_PID.0123456789abcdef.key"
mkfifo "$HOME/.claude/.credentials.json"
ag
[ "$RC" != 124 ] && report "the key file and the credentials are never opened (no hang)" pass \
                 || report "the key file and the credentials are never opened (the doctor hung)" fail
has "the registry: records that parse" "$out" "  ✓ Claude's session registry is at ~/.claude/sessions — 2 records parse"
has "...which of them the list believes" "$out" "      1 is a live session in a pane here, whose row shows Claude's state"
has "...a half-written one is unknown" "$out" "      1 record there lacks what the list reads (a pid, a status) — unknown: the format may have changed"
has "...an unreadable one is unknown" "$out" "      1 record there could not be read — unknown"
setopt agent-state off
ag
has "agent-state off: the list does not read the registry" "$out" "      @interdimux-agent-state is off, so the list does not read it"
unsetopt agent-state
chmod 000 "$REG"
ag
has "an unreadable registry directory: unknown, not \"no session\"" "$out" "      Claude Code: its session registry at ~/.claude/sessions could not be read — unknown"
chmod 755 "$REG"
rm -f "$REG"/*.json
ag
has "an empty registry: no session running" "$out" "  ✓ Claude's session registry is at ~/.claude/sessions — no session is running now"
tm kill-window -t '=agdoc:cl'

# Where the directory comes from: the option, else the SERVER's
# CLAUDE_CONFIG_DIR (the popups' environment), else ~/.claude.
mkdir -p "$TMPD/cfgdir/sessions" "$TMPD/optdir/sessions"
senv CLAUDE_CONFIG_DIR "$TMPD/cfgdir"
ag
has "the server's CLAUDE_CONFIG_DIR is where Claude is looked for" "$out" "  ✓ Claude's session registry is at $TMPD/cfgdir/sessions"
setopt claude-dir "$TMPD/optdir"
ag
has "@interdimux-claude-dir wins over it" "$out" "  ✓ Claude's session registry is at $TMPD/optdir/sessions"
unsetopt claude-dir
unsenv CLAUDE_CONFIG_DIR
CLAUDE_CONFIG_DIR="$TMPD/cfgdir" ag
has "a CLAUDE_CONFIG_DIR only this shell has: said, with the option to set" "$out" "      this shell's CLAUDE_CONFIG_DIR is $TMPD/cfgdir, which the popups do not see: set -g @interdimux-claude-dir '$TMPD/cfgdir'"
reset

# --- Codex ---------------------------------------------------------------------------
mkdir -p "$HOME/.codex"
mkfifo "$HOME/.codex/auth.json"
ag
[ "$RC" != 124 ] && report "auth.json is never opened (no hang)" pass \
                 || report "auth.json is never opened (the doctor hung)" fail
has "focus-events off, condition unset: Codex never notifies" "$out" "  ⚠ Codex never notifies inside tmux — focus-events is off, so it never hears that its pane lost focus"
has "...both fixes named" "$out" "      set -g focus-events on — or in ~/.codex/config.toml, under [tui]: notification_condition = \"always\""
tm set -g focus-events on
ag
has "focus-events on, a TERM with no OSC 9: it rings the bell" "$out" "  ✓ Codex rings the bell when it needs you (focus-events on) — tmux flags its window"
tm set -g default-terminal xterm-ghostty
tm set -g allow-passthrough on
ag
has "focus-events on, xterm-ghostty: OSC 9 in passthrough" "$out" "  ⚠ Codex's notifications go to Ghostty through tmux passthrough — tmux never sees them"
has "...saying how" "$out" "      notification_method is not set (auto), so Codex sends OSC 9 wrapped for passthrough"
has "...with the bell as the fix" "$out" "      to have tmux flag the window instead: notification_method = \"bel\" under [tui] in ~/.codex/config.toml"
tm set -g default-terminal tmux-256color
senv GHOSTTY_RESOURCES_DIR /usr/share/ghostty
ag
has "GHOSTTY_RESOURCES_DIR in the panes' environment picks Ghostty too" "$out" "  ⚠ Codex's notifications go to Ghostty through tmux passthrough"
printf '[tui]\ntheme = "dark"\nnotification_method = "bel"  # ring\n' > "$HOME/.codex/config.toml"
ag
has "notification_method bel: a tick" "$out" "  ✓ Codex rings the bell when it needs you (focus-events on) — tmux flags its window"
unsenv GHOSTTY_RESOURCES_DIR
tm set -g focus-events off
printf '[tui]\nnotification_condition = "always"\n' > "$HOME/.codex/config.toml"
ag
has "notification_condition always: it notifies without focus-events" "$out" "  ✓ Codex rings the bell when it needs you (notification_condition \"always\") — tmux flags its window"
printf 'model = "x"\ntui.notification_condition = "always"\n' > "$HOME/.codex/config.toml"
ag
has "...a dotted tui.key at the top level counts" "$out" "  ✓ Codex rings the bell when it needs you (notification_condition \"always\")"
printf '[profiles.work]\nnotification_condition = "always"\n' > "$HOME/.codex/config.toml"
ag
has "...the same key in another table does not" "$out" "  ⚠ Codex never notifies inside tmux"
printf "[tui]\nnotifications = false\n" > "$HOME/.codex/config.toml"
ag
has "notifications = false: a note" "$out" "      Codex: its notifications are turned off ([tui] notifications = false)"
printf '[tui]\nnotification_condition = "sometimes"\n' > "$HOME/.codex/config.toml"
ag
has "a condition this does not know: unknown" "$out" "      Codex: notification_condition in ~/.codex/config.toml holds a value this check does not know — unknown"
chmod 000 "$HOME/.codex/config.toml"
ag
has "an unreadable config.toml: unknown" "$out" "      Codex: ~/.codex/config.toml could not be read — whether it notifies is unknown"
chmod 644 "$HOME/.codex/config.toml"
senv CODEX_HOME "$TMPD/codexhome"
ag
has "the server's CODEX_HOME is where Codex is looked for" "$out" "      Codex: no $TMPD/codexhome — skipped"
unsenv CODEX_HOME

# --- nothing on stderr ---------------------------------------------------------------
# Unreadable files, FIFOs, a half-written record, configs that are not what
# they should be: not one run above made a check write to stderr.
[ -z "$STDERR_HITS" ] && report "no run wrote to stderr" pass \
  || { report "no run wrote to stderr" fail; ERRORS+="$STDERR_HITS"; }

# --- advisory: the exit status is the picker's ---------------------------------------
# Every agent warning at once: none of them is a ✗, and the exit status stays
# what the rest of the report makes it.
reset
mkdir -p "$HOME/.claude" "$HOME/.codex"
tm set -g allow-set-title off
tm setw -g monitor-bell off
tm set -g default-terminal xterm-ghostty
tm set -g allow-passthrough on
senv CLAUDE_CODE_DISABLE_TERMINAL_TITLE 1
ag
n=$(printf '%s\n' "$out" | grep -c '⚠' || true)
[ "$n" -ge 5 ] && report "every agent warning at once ($n)" pass || report "every agent warning at once (only $n)" fail
hasnt "...none of them is a problem" "$out" "✗"
[ "$RC" = "$BASE_RC" ] && report "...and the exit status is unchanged ($RC)" pass \
                       || report "...and the exit status is unchanged (got $RC, baseline $BASE_RC)" fail
reset

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
