# shellcheck shell=bash
#
# interdimux-list.sh -- the navigator's list: what it is drawn from, fetched
# from tmux, and the Rust core's rows.  Part of scripts/interdimux.sh, which
# sources it; it is never run on its own.
#
# A file of its own so that what the list needs can come first for the list and
# for nothing else.  bash parses a script as it runs it, so a mode parses
# everything above its own dispatch: --list, on every ^r, ^/, resize and action,
# parsed ~400 KB of callbacks, pickers and dialogs to reach code that with the
# Rust core is all in here.  interdimux.sh sources this right after its option
# table and colours for --list and for the navigator, whose fast path and first
# list end the file, and above "Gather targets" for the modes below the
# callbacks, which draw rows or read the agent layer too.  The callbacks fzf
# runs while you type and move never parse it: they draw no row, and this is
# where the agent layer's ~6 KB of rules are (review R15,
# tests/test_render_cost.sh).  Review PERF-17.
#
# Everything here reads what interdimux.sh has set up by then -- the options
# (get_opt), US, CUR_T, AGENT_ON, VIEW, NOW_EPOCH, term_cols_r,
# live_preview_state_r, is_utf8 -- and nothing defined further down it.

# Rules: how what an app or a plugin tells tmux becomes a state word and a
# description on the row.  One rule per line, two kinds:
#
#   APPS     STATE  DESC  PATTERN     a pane TITLE rule
#   @OPTIONS STATE  DESC  PATTERN     a pane OPTION rule
#
# APPS     comma-separated command names the rule is for (the agent's name for
#          an agent row, argv0's basename otherwise), or * for any.  An empty
#          name in the list names nothing.
# @OPTIONS comma-separated tmux user options (with their @), read for every
#          pane in the one batched query.  Other agent plugins publish state
#          this way (tmux-agent-sidebar's @pane_status, tmux-agent-icons'
#          @claude_state, ...), and so can your own hooks: `tmux set -p -t
#          "$TMUX_PANE" @agent_state approve` needs no rule at all.
# STATE    the state word it asserts (approve input working idle done error),
#          or - for none.  Any other word is taken for - (tr_parse).
# DESC     - for none, = for the whole title (or value), anything else a
#          template in which $1..$9 are PATTERN's captures.
# PATTERN  the rest of the line: literal text, anchored at both ends, in which
#          each * captures (greedily, left to right).  A leading %spin matches
#          one braille spinner glyph (U+2800-28FF).
#
# A title rule is picked by the app, so a glyph means what THAT app means by
# it (✳ is Claude's constant mark but Qwen's "approve?").  The first title
# rule that matches decides; among option rules the first to give a state
# gives it, and the first to give a description gives that.  The state comes
# from Claude's own registry first, then the options, then the title.
#
# Lines of @interdimux-title-rules (a file, default
# ~/.config/interdimux/titles) come before these, so they override them.  A
# title no rule knows shows only under @interdimux-show-title all -- on an
# agent's row too: a shell that sets no title leaves the last program's title
# in the pane, and an agent that sets none (aider) would show that as its
# task.  So every agent whose own title should show has a rule here that
# matches it, even a bare `=  *`.  rust/src/titles.rs applies the same text:
# bash hands it over whole.
DEFAULT_TITLE_RULES='
# --- agents: titles ------------------------------------------------------
# Claude Code: `✳ <title>`; ◐/◑ or a spinner while busy outside a multiplexer
claude          -        -   ✳ Claude Code
claude          -        -   Claude Code
claude          working  $1  ◐ *
claude          working  $1  ◑ *
claude          working  $1  %spin *
claude          -        $1  ✳ *
# Codex: `<spinner> <thread> | <project>`; `[ ! ] Action Required | ...`
# blinking to `[ . ]` while an approval waits.  No spinner is not idle: the
# activity item can be switched off.
codex           approve  $1  [ ! ] Action Required | * | *
codex           approve  $1  [ . ] Action Required | * | *
codex           approve  -   [ ! ] Action Required*
codex           approve  -   [ . ] Action Required*
codex           approve  $1  ● [ ! ] Action Required | * | *
codex           approve  $1  ● [ . ] Action Required | * | *
codex           approve  -   ● [ ! ] Action Required*
codex           approve  -   ● [ . ] Action Required*
codex           working  $1  %spin * | *
codex           working  -   %spin *
codex           -        $1  * | *
codex           -        -   *
# gemini-cli (windowTitle.ts): a glyph, TWO spaces, a word, then (folder),
# padded to 80 columns; a thought, when shown, then (folder) if it fits
gemini          approve  -   ✋*
gemini          working  -   ✦  Working…*
gemini          working  $1  ✦  * (*)
gemini          working  $1  ✦ *
gemini          working  -   ⏲*
gemini          idle     -   ◇*
gemini          -        -   Gemini CLI*
# Qwen Code: ◐ working, ✳ waiting for approval (with a U+FE0E after either)
qwen            working  $1  ◐*
qwen            approve  $1  ✳*
qwen            -        -   Qwen - *
# Amp: `<spinner> <thread> - amp - <cwd>`
amp             approve  -   ◆ *
amp             working  $1  %spin * - amp - *
amp             idle     $1  * - amp - *
# opencode, Cursor, goose, crush, GitHub Copilot
opencode        -        $1  OC | *
opencode        -        -   OpenCode
# Cursor: its chat name, which has no mark of its own
cursor-agent    -        -   Cursor Agent
cursor-agent    -        =   *
goose           -        -   🪿*
crush           -        -   crush *
copilot         -        $1  * - GitHub Copilot
copilot         -        -   GitHub Copilot

# --- agents: state other plugins (or your hooks) publish as options ------
# the interdimux contract: set @agent_state to one of the words, @agent_desc to text
@agent_state          working  -  working
@agent_state          approve  -  approve
@agent_state          input    -  input
@agent_state          idle     -  idle
@agent_state          done     -  done
@agent_state          error    -  error
@agent_desc           -        =  *
# tmux-agent-sidebar
@pane_status          working  -  running
@pane_status          working  -  background
@pane_status          idle     -  idle
@pane_status          error    -  error
@pane_wait_reason     approve  -  permission_prompt
@pane_wait_reason     approve  -  elicitation_dialog
@pane_wait_reason     approve  -  permission_denied
@pane_status          input    -  waiting
# tmux-agent-icons
@claude_state,@codex_state,@opencode_state  working  -  working
@claude_state,@codex_state,@opencode_state  approve  -  waiting
@claude_state,@codex_state,@opencode_state  idle     -  idle
# tmux-claude-status
@claude_pane_status   working  -  running
@claude_pane_status   working  -  shells
@claude_pane_status   approve  -  question
@claude_pane_status   approve  -  plan
@claude_pane_status   done     -  done
@claude_pane_status   error    -  error
@claude_pane_status   idle     -  loop
# workmux (its default icons only)
@workmux_pane_status  working  -  🤖
@workmux_pane_status  approve  -  💬
@workmux_pane_status  done     -  ✅
# dmux: "look at me"
@dmux_attention       done     -  1
# Only PANE options are read by default.  tmux resolves a window option for
# every pane of the window, so a window-scoped state (@ccm_prev_state of
# tmux-ccm, @agent_status_state of tmux-agent-status, @workmux_status of
# workmux, @codex_attention of codex-tmux-notify) would show on the panes
# next to the agent too, and each option read costs every list ~0.35 ms per
# 100 panes.  The README has their rules, to add to your own file.

# --- apps that are a terminal somewhere else -----------------------------
# A shell on another host or in a container titles the pane with where it is,
# and nothing else on the row can say so: the directory is where the client
# was started, the command is `ssh web1` or `docker exec -it 3f2a bash`.  Only
# the shapes such titles have are read, so what an earlier program left in the
# title (a shell that sets none leaves it there) shows only if it has one, and
# a prompt of THIS host never shows (cmd_field drops it).
#
# mosh-client (the mosh script execs it) puts [mosh] before whatever the remote
# sets, and pops its own title on exit
mosh-client  -  $1  [mosh] *
# a prompt.  user@host: ~/path from the Debian and Ubuntu bashrc (TERM xterm*),
# user@host:~/path from Fedora /etc/bashrc (xterm*), Arch /etc/bash.bashrc
# (xterm*, tmux*) and oh-my-zsh (any TERM).  docker -t gives the container
# TERM=xterm but no USER, which Fedora and Arch print: @3f2a9c1b:/app.  screen
# passes its window title on.
ssh,autossh,et,docker,docker-compose,podman,nerdctl,kubectl,oc,lxc,incus,machinectl,toolbox,multipass,screen  -  =  *@*:*
# fish over ssh (fish_title, when SSH_TTY is set): [host] ~/p/dir, and
# [host] make ~/p/dir while a command runs
ssh,autossh,et  -  =  [*] *
# tmux there, with set-titles on and the default set-titles-string
# (#S:#I:#W - "#T"): session:index:window - "its pane title"
ssh,autossh,et,docker,docker-compose,podman,nerdctl,kubectl,oc,lxc,incus,machinectl,toolbox,multipass  -  =  *:*:* - "*"*
# a client of another tmux server here (tmux -L other attach), with set-titles
# on: its session:index:window.  The pane title after it is usually a prompt
# of this host, which would hide the whole title.
tmux  -  $1  * - "*"*
'

# One rule line split into its four fields (RULE_A RULE_S RULE_D RULE_P), the
# way the Rust core splits it: tabs and CRs are blanks, blanks separate the
# first three, and the pattern is the rest, trimmed.  Returns 1 for a
# comment, a blank line or a line with no pattern.
rule_fields() {
  # One regex, not ${l%%[! ]*} trims: those are quadratic in the line's length
  # in bash, and made loading the default rules cost ~18 ms.
  local l="${1//[$'\t\r']/ }" re='^ *([^ ]+) +([^ ]+) +([^ ]+) +(.*[^ ]) *$'
  [[ "$l" =~ $re ]] || return 1
  # shellcheck disable=SC2034  # what interdimux.sh reads of them too
  RULE_A="${BASH_REMATCH[1]}" RULE_S="${BASH_REMATCH[2]}" RULE_D="${BASH_REMATCH[3]}" RULE_P="${BASH_REMATCH[4]}"
  [[ "$RULE_A" != '#'* ]]
}

# The option names the default rules read, spelled out: deriving them from
# DEFAULT_TITLE_RULES costs ~5 ms of bash on every list, and they only change
# when the rules do.  tests/test_title_rules.sh checks this against the rules.
DEFAULT_STATE_OPTS=' agent_state agent_desc pane_status pane_wait_reason claude_state codex_state opencode_state claude_pane_status workmux_pane_status dmux_attention '

# The rule set this list uses, in TITLE_RULESET: the user's file, then the
# defaults.  Read once per list (no fork) and handed to the Rust core whole.
# STATE_OPTS: the option names the option rules read -- the defaults', and any
# the user's file adds (valid tmux option names only: they are spliced into
# the list-panes format).
#
# A line of the file that is not valid UTF-8 (is_utf8) is dropped here, and
# only that line: a Latin-1 comment in an otherwise good file is common, and
# the Rust core cannot hold such a byte at all -- handed the whole text, it
# read an EMPTY rule set, every built-in rule gone with it, while bash went on
# (review R02).  rust/src/agent.rs drops the same lines, should one ever reach
# it some other way; --doctor names them.  A NUL (a UTF-16 file) ends the
# text: bash cannot hold one, so what follows it is never read.
TITLE_RULESET="" STATE_OPTS="" CUR_HOST="" CUR_HOST_SHORT="" TITLE_RULES_USER=""
title_ruleset() {
  local f="${TITLE_RULES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/titles}" txt="" l o kept=""
  local -a lines=()
  STATE_OPTS="$DEFAULT_STATE_OPTS"
  if [ -f "$f" ] && [ -r "$f" ]; then
    { IFS= read -r -d '' txt < "$f"; } 2>/dev/null || :
  fi
  if ! is_utf8 "$txt"; then
    set -f; IFS=$'\n'; lines=($txt); unset IFS; set +f
    for l in ${lines[@]+"${lines[@]}"}; do is_utf8 "$l" && kept+="$l"$'\n'; done
    txt="$kept"
  fi
  # shellcheck disable=SC2034  # read in interdimux.sh
  TITLE_RULES_USER="$txt"   # the user's part alone (aw_can_r)
  TITLE_RULESET="$txt"$'\n'"$DEFAULT_TITLE_RULES"
  [[ "$txt" == *@* ]] || return 0
  set -f; IFS=$'\n'; lines=($txt); unset IFS; set +f
  for l in ${lines[@]+"${lines[@]}"}; do
    [[ "$l" == *@* ]] || continue
    rule_fields "$l" || continue
    [[ "$RULE_A" == @* ]] || continue
    set -f; IFS=,
    for o in $RULE_A; do
      o="${o#@}"
      case "$o" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
      [[ "$STATE_OPTS" == *" $o "* ]] || STATE_OPTS+="$o "
    done
    unset IFS; set +f
  done
}

# What ends each published option's value in a pane line: state_optfmt_r
# builds the format, option_rule_r (in interdimux.sh) reads the values.
GS=$'\x1d'

# The list-panes format that reads the published options, in REPLY: one value
# per name in STATE_OPTS, in order, each ended by GS, with a GS, RS, US or
# newline of its own rewritten to '?' and capped at 128 (an option can hold
# anything).  Shared by the navigator's batched query and the dashboard's count.
state_optfmt_r() {
  local on nl=$'\n' rs=$'\x1e'
  REPLY=""
  for on in $STATE_OPTS; do
    REPLY+="#{=128;s/[${GS}${rs}${US}${nl}]/?/:@$on}$GS"
  done
}

# Claude Code's session registry: one line per live, interactive session that
# runs in a tmux pane, `<%pane>US<sid>US<word>US<since>`, in CLAUDE_REG.
#
# Claude keeps ~/.claude/sessions/<pid>.json up to date as the session works:
# `status` busy / idle / waiting (with `waitingFor`: "permission prompt",
# "input needed", ...) / shell (a background task after the turn ended),
# `statusUpdatedAt` in ms, and `tmux`, the TMUX_PANE it started in.  It is an
# internal file, so it is read defensively, fork-free and once per list:
#
#   * only `<digits>.json`.  The directory also holds `<pid>.<hash>.key`
#     files, which are never opened;
#   * only a regular file (or a link to one), and only its first 65,536
#     characters: a FIFO there blocked the open(2) until a writer came --
#     every list, reload and prefix+g, in both renderers, hung (review R24).
#     A record is a few hundred bytes; a longer one fails the closing-brace
#     test below;
#   * written by truncating and rewriting, so a read can catch it empty or
#     half written: no closing brace, or a key missing, skips it for this paint;
#   * the pid must still be that process: /proc/<pid>/stat's start time equals
#     the record's procStart, so a reused pid is not believed.  Its session id
#     (field 6) is the pane's shell, and the renderers accept the record for a
#     row only when that equals the row's #{pane_pid} -- which also rejects a
#     %N that belongs to another tmux server.  Without /proc (macOS) it is only
#     `kill -0`, and the sid is left empty: unchecked, so a reused pid or
#     another server's %N is believed there (README says so).  The record's
#     `tmux` field is `session:@window.%pane`, with no socket in it to check.
#     INTERDIMUX_REGISTRY_NO_PROC=1 takes that path on Linux too: a test seam
#     (tests/test_agent_readme.sh), so the fallback runs where CI does.
#
# Never touched: `claude agents --json` (a 226 MB binary and a telemetry
# event per call) and .fleetview-heartbeat (it turns on classifier calls).
# Where it lives: @interdimux-claude-dir, else $CLAUDE_CONFIG_DIR, else
# ~/.claude.  A CLAUDE_CONFIG_DIR set only in a shell's rc is invisible to the
# popup, which starts from the tmux server's environment; hence the option.
CLAUDE_REG=""
claude_registry_r() {
  CLAUDE_REG=""
  [ "$AGENT_STATE" = on ] || return 0
  local dir="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/sessions"
  [ -d "$dir" ] || return 0
  local f stem j pid pst pane st wf upd word sid ng=0
  local -a files=() sf=()
  shopt -q nullglob && ng=1
  shopt -s nullglob
  files=("$dir"/*.json)
  [ "$ng" = 1 ] || shopt -u nullglob
  for f in ${files[@]+"${files[@]}"}; do
    stem="${f##*/}"; stem="${stem%.json}"
    case "$stem" in ''|*[!0-9]*) continue ;; esac
    [ -f "$f" ] || continue
    j=""
    { IFS= read -r -N 65536 j < "$f"; } 2>/dev/null || :
    [[ "$j" == *'}' ]] || continue
    # A glob where nothing is captured, and whether the pid still runs BEFORE
    # the other fields: bash compiles a [[ =~ ]] regex on every match (~30 µs
    # each here), and a record whose Claude has gone -- they stay behind after
    # a crash -- paid for all seven only to be dropped (review R15).  The
    # waiting reason is read only for a record that is waiting.
    [[ "$j" == *'"kind":"interactive"'* ]] || continue
    [[ "$j" =~ \"pid\":([0-9]+) ]] && pid="${BASH_REMATCH[1]}" || continue
    if [ -r /proc/self/stat ]; then
      [ -e "/proc/$pid/stat" ] || continue
    else
      kill -0 "$pid" 2>/dev/null || continue
    fi
    [[ "$j" =~ \"tmux\":\"[^\"]*(%[0-9]+)\" ]] && pane="${BASH_REMATCH[1]}" || continue
    [[ "$j" =~ \"status\":\"([a-z]+)\" ]] && st="${BASH_REMATCH[1]}" || continue
    upd=0; [[ "$j" =~ \"statusUpdatedAt\":([0-9]+) ]] && upd="${BASH_REMATCH[1]}"
    case "$st" in
      busy) word=working ;;
      idle|shell) word=idle ;;
      waiting)
        wf=""; [[ "$j" =~ \"waitingFor\":\"([^\"]*)\" ]] && wf="${BASH_REMATCH[1]}"
        case "$wf" in
          'permission prompt'|'worker request'|'sandbox request') word=approve ;;
          *) word=input ;;
        esac ;;
      *) continue ;;
    esac
    sid=""
    if [ -r /proc/self/stat ] && [ "${INTERDIMUX_REGISTRY_NO_PROC:-}" != 1 ]; then
      pst=""; [[ "$j" =~ \"procStart\":\"?([0-9]+) ]] && pst="${BASH_REMATCH[1]}"
      [ -n "$pst" ] || continue
      sf=()
      { IFS=$' \t\n' read -r -d '' -a sf < "/proc/$pid/stat"; } 2>/dev/null || :
      # comm ends at the LAST word holding a ')' (see proc_group_ids): field N
      # of stat is sf[last + N - 2].  The usual comm (one word) is one test.
      local i last=0
      if [[ "${sf[1]-}" == *')' && "${sf[*]:2:7}" != *')'* ]]; then
        last=1
      else
        for (( i = 1; i <= 9 && i < ${#sf[@]}; i++ )); do
          case "${sf[i]}" in *')'*) last=$i ;; esac
        done
      fi
      [ "$last" -gt 0 ] && [ "${sf[last+20]-}" = "$pst" ] || continue
      sid="${sf[last+4]}"
    fi
    CLAUDE_REG+="$pane$US$sid$US$word$US$(( upd / 1000 ))"$'\n'
  done
  CLAUDE_REG="${CLAUDE_REG%$'\n'}"
  return 0
}

# The list's input: the sessions, the windows, the panes and where the
# pressing client stands, in one tmux client (or from INTERDIMUX_DUMP_IN),
# with Claude's registry beside them and @interdimux-hide applied -- what
# both renderers draw.  Into sessions_raw, all_windows_raw, all_panes_raw,
# cur_raw, current_session, current_window and current_pane: gather_targets'
# locals, through dynamic scope, or the globals of --list's fast path, which
# its bash renderer takes over when the core does not draw them.  CUR_HOST,
# CUR_HOST_SHORT and CLAUDE_REG are globals either way.  Returns 1 when a
# dump cannot be read, having said so on stderr.
list_fetch() {
  local _hline

  # tmux gives each line of a list-* a 100 ms wall-clock budget and, when the
  # server is descheduled for that long in the middle of one, returns the line
  # CUT at the next '#{' (format.c, FORMAT_TIME_LIMIT) -- `s^_0^_zsh^_1^_zsh^_`,
  # with no error.  Rare (it takes a starved server), transient (the next reload
  # is whole), and both renderers keep such a line rather than drop the row; see
  # the grouping in gather_targets.  For the SESSION line that means the name
  # has to come FIRST: behind the timestamp, a cut line had no name at all, and
  # the session vanished along with every window and pane under it (shifting
  # --jump N onto the wrong session).
  local _sfmt _wfmt _pfmt _curfmt
  #
  # #{session_path} goes LAST, so a US inside it stays inside it (both renderers
  # split the line into at most five fields).  A newline or RS in it is
  # rewritten to '?' by tmux itself: the first would split the line and hand the
  # fragment after it the session-name position, the second would break the
  # section framing.  Such a path could never equal a directory row's path
  # anyway -- the recent list and zoxide are line-based.
  local _nl=$'\n' _rs=$'\x1e'
  _sfmt="#{session_name}${US}#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_windows}${US}#{?session_attached,attached,}${US}#{s/[${_nl}${_rs}]/?/:session_path}"
  _wfmt="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{window_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{window_panes}${US}#{pane_pid}${US}#{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag}"
  # The pane id, its title and the options agent plugins publish ride at the
  # END of a pane line (gather3), so a line cut in them keeps its row.  tmux
  # escapes every control character in a title, so it cannot carry a US, RS
  # or newline of its own.  An option can, so each value has them rewritten
  # (and is capped); the values are POSITIONAL, one per name in STATE_OPTS,
  # each ended by GS -- an unset option is an empty value.  Measured on 97
  # panes (tmux 3.7b, median of 40): a conditional per option
  # (`#{?@x,x=...,}`) cost 0.7 ms per option, this 0.35 ms, and a separate
  # `list-panes -f` over the options three times the base query.  The field
  # goes last, so nothing in it can move another.  A window row takes all
  # three from its active pane's line, so the window format is unchanged.  The
  # host names are what a pane's title is when no program set one (see
  # cmd_field).
  local _optfmt=""
  if [ "$AGENT_ON" = 1 ]; then
    title_ruleset
    state_optfmt_r; _optfmt="$REPLY"
  fi
  _pfmt="#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{pane_active}${US}#{pane_current_command}${US}#{pane_current_path}${US}#{pane_pid}${US}#{window_panes}${US}#{pane_id}${US}#{pane_title}${US}${_optfmt}"
  _curfmt="#S${US}#I${US}#P${US}#{host}${US}#{host_short}"

  # One tmux invocation instead of four.  A tmux client accepts a `;`-separated
  # command list, and each round-trip costs ~5-6 ms of connect/teardown on top
  # of the query itself — all of it ahead of the first emitted row.
  #
  # Sections are separated by RS (\x1e).  Note the ORDER: the only command here
  # that can fail is the current-target lookup (a stale $TMUX_PANE), and tmux
  # aborts the remainder of a command list on failure — so it goes LAST, where
  # it cannot swallow the bulk data.
  #
  # `exec`: bash runs a $(...) whose one command carries a redirection by
  # forking the substitution's subshell AND, inside it, the command -- a second
  # fork of the whole parsed script, ~0.7 ms, on every open and every reload.
  # exec'd, the subshell becomes tmux.  Its 2> is set up before the exec, so
  # stderr is as quiet as it was, and the status is tmux's either way.
  local _batched=0 _all RS=$'\x1e' _dump_reg=""
  local -a _parts=()
  if [ -n "${INTERDIMUX_DUMP_IN:-}" ]; then
    # Test seam: the four sections from a FILE instead of from tmux, framed
    # exactly as the batched query below returns them, plus optionally a fifth,
    # the Claude registry -- the framing `imux gather3` reads on stdin.  It is what lets the golden corpus
    # (rust/tests/corpus/*.dump) reach THIS renderer, the one every install
    # without cargo runs, with no server and no timing:
    # tests/test_corpus_parity.sh.  Same family as INTERDIMUX_NO_BATCH and
    # INTERDIMUX_NOW.
    #
    # A dump IS the batch, so it serves both fetch paths and neither one
    # queries tmux: a seam that fell through to a live server whenever the
    # file was unreadable or mis-framed would render some other list and pass.
    # So a bad dump renders nothing, loudly -- the Rust core exits 3 on the
    # same framing.  The trailing RS keeps an EMPTY last section a section:
    # word splitting drops a trailing empty field, and the corpus has an
    # empty server.
    if ! { _all=$(<"$INTERDIMUX_DUMP_IN"); } 2>/dev/null; then
      printf 'interdimux: INTERDIMUX_DUMP_IN: cannot read %s\n' "$INTERDIMUX_DUMP_IN" >&2
      return 1
    fi
    set -f; IFS="$RS"; _parts=($_all$RS); set +f; unset IFS
    # A fifth section is the Claude registry (CLAUDE_REG) that bash appends
    # before the handoff; a dump without one has none, and a dump never reads
    # the real ~/.claude.
    if [ "${#_parts[@]}" -ne 4 ] && [ "${#_parts[@]}" -ne 5 ]; then
      printf 'interdimux: INTERDIMUX_DUMP_IN: expected 4 or 5 sections, got %d\n' "${#_parts[@]}" >&2
      return 1
    fi
    _dump_reg="${_parts[4]-}"; _dump_reg="${_dump_reg#$'\n'}"; _dump_reg="${_dump_reg%$'\n'}"
    _batched=1
  elif [ -z "${INTERDIMUX_NO_BATCH:-}" ]; then
    _all=$(exec tmux \
      list-sessions -F "$_sfmt" \; \
      display-message -p "$RS" \; \
      list-windows -a -F "$_wfmt" \; \
      display-message -p "$RS" \; \
      list-panes -a -F "$_pfmt" \; \
      display-message -p "$RS" \; \
      display-message -p ${CUR_T[@]+"${CUR_T[@]}"} "$_curfmt" 2>/dev/null)
    # Split on RS by word-splitting, NOT by ${var#*pat}: the latter is
    # quadratic in the offset and costs hundreds of ms on a large dump.
    if [ -n "$_all" ]; then
      set -f; IFS="$RS"; _parts=($_all); set +f; unset IFS
    fi
    # Exactly four sections, or something inside a field carried an RS of its
    # own — a pane's cwd legitimately can (tmux only rejects RS in session and
    # window NAMES).  An extra field shifts every subsequent section, which
    # silently truncates a path AND drops the current-row marker, so fall back
    # to separate queries rather than render something subtly wrong.
    [ "${#_parts[@]}" -eq 4 ] && _batched=1
  fi

  if [ "$_batched" = 1 ]; then
    # display-message appends a newline before each RS, and each section after
    # the first therefore starts with one.
    sessions_raw="${_parts[0]%$'\n'}"
    all_windows_raw="${_parts[1]#$'\n'}"; all_windows_raw="${all_windows_raw%$'\n'}"
    all_panes_raw="${_parts[2]#$'\n'}";   all_panes_raw="${all_panes_raw%$'\n'}"
    cur_raw="${_parts[3]#$'\n'}"
  else
    # Current target: anchor to the pressing client, else to $TMUX_PANE (see
    # CUR_T) — a bare display-message in a clientless context silently
    # resolves to the most recently attached session.
    cur_raw=$(tmux display-message -p ${CUR_T[@]+"${CUR_T[@]}"} "$_curfmt")
    sessions_raw=$(tmux list-sessions -F "$_sfmt")
    all_windows_raw=$(tmux list-windows -a -F "$_wfmt")
    all_panes_raw=$(tmux list-panes -a -F "$_pfmt")
  fi
  # shellcheck disable=SC2034  # the renderers', in interdimux.sh
  IFS="$US" read -r current_session current_window current_pane CUR_HOST CUR_HOST_SHORT <<< "$cur_raw"

  # Claude's session registry, once per list, for both renderers (the Rust core
  # reads it as a fifth section).  A dump brings its own.
  if [ -n "${INTERDIMUX_DUMP_IN:-}" ]; then
    CLAUDE_REG="$_dump_reg"
  else
    claude_registry_r
  fi

  # @interdimux-hide 'scratch floax-*' — glob patterns, matched against session
  # names.  MRU ranks by recency, so a scratch popup you opened ten seconds ago
  # outranks the project you have been in all day; this is how you get it out of
  # the way without renaming anything.
  #
  # Filtered HERE, on the raw sections, so both renderers see the same list and
  # neither needs to know about the option.  Guarded on emptiness, so the
  # default config pays nothing at all.
  #
  # The CURRENT session is never hidden: the row marker, the header and MRU's
  # move-to-end all key off it, and a picker that cannot show you where you are
  # standing is worse than one that shows a scratch session.
  #
  # Hidden is not unreachable — typing an exact name still lands there. Nothing
  # matches, so find-or-create runs, and connect_dir switches to the existing
  # session rather than making a new one.
  if [ -n "${HIDE_PATTERNS:-}" ]; then
    # `for _hp in $HIDE_PATTERNS` needs the word splitting and would also get
    # PATHNAME EXPANSION, which is not a stylistic quibble: a pattern of
    # `floax-*` was expanded against the CWD before it was ever compared to a
    # session name, so in a directory containing `floax-notes` the tool tried to
    # hide a session called `floax-notes` and hid nothing at all — and in a
    # directory containing no match, bash left the word alone and it happened to
    # work.  The behaviour therefore depended on where the popup was opened from.
    # set -f for the whole block; the same idiom is used around the RS split
    # above.
    #
    # The lines by word splitting, not `while read` over a here-string: `read`
    # takes that a byte per read(2), and a pane line carries its title and its
    # published options (review R09).
    set -f
    local _hp _hname _hkeep _hout=""
    local -a _hls=()
    IFS=$'\n'; _hls=($sessions_raw); unset IFS
    for _hline in ${_hls[@]+"${_hls[@]}"}; do
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254  # the pattern is a glob by design
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done
    sessions_raw="${_hout%$'\n'}"

    # windows and panes carry the session name in field 1 too
    _hout=""
    IFS=$'\n'; _hls=($all_windows_raw); unset IFS
    for _hline in ${_hls[@]+"${_hls[@]}"}; do
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done
    all_windows_raw="${_hout%$'\n'}"

    _hout=""
    IFS=$'\n'; _hls=($all_panes_raw); unset IFS
    for _hline in ${_hls[@]+"${_hls[@]}"}; do
      _hname="${_hline%%"$US"*}"
      _hkeep=1
      if [ "$_hname" != "$current_session" ]; then
        for _hp in $HIDE_PATTERNS; do
          # shellcheck disable=SC2254
          case "$_hname" in $_hp) _hkeep=0; break ;; esac
        done
      fi
      [ "$_hkeep" = 1 ] && _hout+="$_hline"$'\n'
    done
    all_panes_raw="${_hout%$'\n'}"
    set +f
  fi
}

# The rows, drawn by the Rust core from what list_fetch fetched, on stdout.
# This is the part that was ~181 ms of in-process bash (measure_widths +
# grouping + emit); the binary does it in ~2 ms.  bash keeps the tmux plumbing
# so the socket handling lives in exactly one place, and keeps its own
# renderer (gather_targets, in interdimux.sh) as the fallback for anyone
# without the binary.
#
# The binary resolves full commands from /proc on Linux and from its own single
# `ps -A` snapshot on macOS/BSD (or when INTERDIMUX_FORCE_PS=1), so it renders
# correctly EVERYWHERE — it is preferred whenever it is present.  A binary that
# fails or prints nothing falls through to the bash renderer (the empty
# `_imux_out` guard), so preferring it can never turn into an empty picker.
#
# 0 when it drew the rows.  Otherwise nothing is printed and the bash
# renderer draws them: 2 when the core refused the protocol, which the caller
# reports (imux_refused, in interdimux.sh), 1 when it failed or printed
# something that is not a row list.
list_core() {
  # Pass every option EXPLICITLY rather than letting the binary re-derive
  # defaults from the environment.  bash is the single owner of config
  # resolution (env -> tmux option -> built-in default, see get_opt), and a
  # binary that re-implemented those defaults would silently disagree with the
  # fallback renderer whenever an option was left unset.
  #
  # The assignments live INSIDE the substitution on purpose: written as a
  # `VAR=v \ _imux_out=$(...)` prefix chain, bash parses the lot as a list of
  # assignments with NO command, so the binary would run without any of them.
  # Only the two VALUES that need a lookup are taken out, by the REPLY forms:
  # `$(term_cols)` and `$(live_preview_state)` in that list were a subshell
  # each, on every open and every reload (review PERF-05).  And the binary is
  # exec'd, as tmux is in list_fetch: the 2> and the heredoc made bash fork a
  # second time to run it.  The assignments reach an exec'd command's
  # environment just the same (bash 4.3 to 5.2).
  #
  # Its stderr is dropped.  Every failure falls back to the bash renderer
  # (gather_targets), which draws the right list, and the one failure worth
  # telling the user about is reported by imux_refused, once.  Left to reach the
  # navigator's stderr, a binary older than IMUX_PROTO printed its usage line
  # on every open and every reload, and each one became another entry in
  # errors.log and another status-line message.
  local _imux_rc=0 _imux_cols _imux_pv _imux_out _imux_row1 RS=$'\x1e'
  term_cols_r; _imux_cols="$REPLY"
  live_preview_state_r; _imux_pv="$REPLY"
  _imux_out=$(
    INTERDIMUX_COLS="$_imux_cols" \
    INTERDIMUX_NOW="$NOW_EPOCH" \
    INTERDIMUX_SHOW_FULL_COMMAND="$SHOW_FULL_COMMAND" \
    INTERDIMUX_SHOW_GIT_BRANCH="$SHOW_GIT_BRANCH" \
    INTERDIMUX_SHOW_PREVIEW="$_imux_pv" \
    INTERDIMUX_ORDER="$ORDER" \
    INTERDIMUX_SHOW_DIRS="$SHOW_DIRS" \
    INTERDIMUX_SESSION_RULE="$SESSION_RULE" \
    INTERDIMUX_DIRS_LIMIT="$DIRS_LIMIT" \
    INTERDIMUX_RECENT_LIMIT="$RECENT_LIMIT" \
    INTERDIMUX_USE_ZOXIDE="$USE_ZOXIDE" \
    INTERDIMUX_COLOR_ACCENT="$COLOR_ACCENT" \
    INTERDIMUX_COLOR_PATH="$COLOR_PATH" \
    INTERDIMUX_COLOR_GIT="$COLOR_GIT" \
    INTERDIMUX_COLOR_SSH="$COLOR_SSH" \
    INTERDIMUX_COLOR_EDITOR="$COLOR_EDITOR" \
    INTERDIMUX_COLOR_DANGER="$COLOR_DANGER" \
    INTERDIMUX_COLOR_TREE="$COLOR_TREE" \
    INTERDIMUX_COLOR_SEPARATOR="$COLOR_SEPARATOR" \
    INTERDIMUX_SHOW_TITLE="$SHOW_TITLE" \
    INTERDIMUX_TITLE_MAX="$TITLE_MAX" \
    INTERDIMUX_AGENTS="$AGENT_NAMES" \
    INTERDIMUX_AGENT_ARGS="$AGENT_ARGS" \
    INTERDIMUX_AGENT_STATE="$AGENT_STATE" \
    INTERDIMUX_AGENT_SEPARATOR="$AGENT_SEPARATOR" \
    INTERDIMUX_TITLE_RULESET="$TITLE_RULESET" \
    INTERDIMUX_STATE_OPTS="$STATE_OPTS" \
    INTERDIMUX_VIEW="$VIEW" \
    exec "$IMUX_BIN" "$IMUX_PROTO" 2>/dev/null <<IMUX_SECTIONS
${sessions_raw}
$RS
${all_windows_raw}
$RS
${all_panes_raw}
$RS
${cur_raw}
$RS
${CLAUDE_REG}
IMUX_SECTIONS
  ) || { _imux_rc=$?; _imux_out=""; }
  # Exit 2 is a subcommand the binary does not know: it was built from other
  # sources than this script, and speaks another version of the protocol.
  [ "$_imux_rc" != 2 ] || return 2
  # A failed or empty render must fall through to the bash renderer, never be
  # mistaken for "there is nothing to show".  Capturing buys a safe failure
  # mode, and holds every row until the binary exits: ~3 ms with directory
  # rows off, and with them on (the default) whatever of zoxide's own 5-10 ms
  # the render did not overlap -- the binary starts the query before its
  # first row and collects it at the directory rows (rust/src/dirs.rs).
  #
  # So must one that is not a row list at all.  INTERDIMUX_BIN accepts any
  # executable, and whatever a wrong one printed on exit 0 — `/bin/echo` prints
  # "gather" — used to become the entire picker.  The first row has to end in a
  # tab-separated S:/W:/P:/D: spec, the shape every row of both renderers has:
  # no fork, and nothing the real binary has to learn.
  _imux_row1="${_imux_out%%$'\n'*}"
  if [[ "$_imux_row1" == *$'\t'* && "${_imux_row1##*$'\t'}" == [SWPD]:* ]]; then
    printf '%s\n' "$_imux_out"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# --list's fast path (review PERF-17)
# ---------------------------------------------------------------------------
#
# --list sources this file right after interdimux.sh's options and colours,
# ahead of everything else there, and with the core its rows are drawn here:
# --list exits, and nothing more of interdimux.sh is parsed.  When the core
# does not draw them -- missing, refusing (exit 2) or failing -- the rest of
# interdimux.sh is parsed, down to --list's own dispatch, whose bash renderer
# draws what was fetched here (LIST_FETCHED holds what list_core returned, and
# the fetch is in this level's globals; see gather_targets): tmux is asked
# once, and a refusal is said once, as before.  Sourced by any other mode
# (above "Gather targets"), this is nothing but LIST_FETCHED's empty value.
# shellcheck disable=SC2034  # gather_targets reads it, in interdimux.sh
LIST_FETCHED=""
if [ "${1:-}" = "--list" ] && [ -n "$IMUX_BIN" ]; then
  set +e
  list_fetch || exit 0
  list_core && exit 0
  # shellcheck disable=SC2034  # as above
  LIST_FETCHED=$?
  set -e
fi

# ---------------------------------------------------------------------------
# The navigator's first list, started here (reviews PERF-16, PERF-17)
# ---------------------------------------------------------------------------
#
# The navigator sources this file right after interdimux.sh's options and
# colours, as --list does, and with the Rust core the list is this file and
# nothing else: nothing the navigator does from here on feeds it.  The rest of
# interdimux.sh is the callbacks and the bash renderer (~230 KB, parsed all the
# same, ~10 ms; the other modes, interdimux-modes.sh, it never parses), and then
# the navigator's own setup (~14 ms).  Fetched at the top of its loop, the
# list's 20 ms (small server) to 40 ms came after all of that, and the rows
# reached fzf 20-35 ms after its exec -- past the ~18 ms within which fzf 0.74
# paints them on its first step, so they were painted on its next, ~20 ms later.
# Started here, in a process substitution, the list is fetched while the rest is
# parsed, and fzf reads it from the fd when it starts.  It was started below the
# bash renderer, as early as a fork that may run it can be, and the large
# server's rows still came ~14 ms after fzf's exec, near that edge; from here
# they are there before it.
#
# The same list, from the same state.  The width is asked here (term_cols_r),
# so the navigator draws the bar for the width the list was laid out for, and
# stty is not run twice; the scratch files' names are the ones the navigator
# derives, the same way; its stderr goes to ERR_FILE, created here and not
# truncated by the navigator, which would erase what the list may have said
# already; MOUNTS_FILE is cleared here, before the core can write it; the
# preview state's file is written here, and the list reads the state back
# from it as it did from the one the navigator wrote -- with read -r, which
# trims it, so the list is laid out for the file's state, not the option's
# raw value.  Its environment lacks only what the navigator exports for fzf
# and its binds, which neither tmux nor the core reads.
#
# The core draws it, or nothing in this fork does: the bash renderer is
# further down interdimux.sh than it has parsed.  A core that refuses or fails
# hands the list to a --list, exec'd, at the width asked here (FZF_COLUMNS,
# which only term_cols_r reads there), which asks tmux and the core again,
# says the refusal, and draws the bash renderer's rows -- as every reload does
# then.
#
# Only on the Rust path (the bash renderer's list needs mounts_export), with a
# private XDG_RUNTIME_DIR (elsewhere the names come from mktemp), and from
# bash 4.4 on, whose `wait` can wait for a process substitution: the
# navigator waits for this one as it did for the pipeline's left side, so
# nothing it writes outlives the EXIT trap's rm.  Elsewhere the loop's first
# pass gathers as every later one does.  Sourced by any other mode, this is
# EARLY_FD's empty value and early_done, which does nothing then.
EARLY_FD="" EARLY_PID=""

# The early list's end: its pipe closed -- so a list nobody reads anymore dies
# of SIGPIPE rather than wait on a full pipe -- and its process waited for.
# Once fzf is done, and in the EXIT traps (an exit before fzf, a hangup).
early_done() {
  [ -n "$EARLY_FD" ] || return 0
  exec {EARLY_FD}<&-
  wait "$EARLY_PID" 2>/dev/null || :
  EARLY_FD="" EARLY_PID=""
}

if [ -z "${1:-}" ] && [ -n "$IMUX_BIN" ] && (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404 )) \
   && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
  RESUME_FILE="$XDG_RUNTIME_DIR/interdimux-resume.$$"
  ERR_FILE="${RESUME_FILE}.err"
  fzf_ge 53 && : > "$ERR_FILE" 2>/dev/null || ERR_FILE=""
  MOUNTS_FILE="${RESUME_FILE}.mounts"
  if [ -e "$MOUNTS_FILE" ] || [ -L "$MOUNTS_FILE" ]; then rm -f "$MOUNTS_FILE" 2>/dev/null || :; fi
  export INTERDIMUX_MOUNTS_FILE="$MOUNTS_FILE"
  PREVIEW_STATE_FILE="${RESUME_FILE}.preview"
  printf '%s' "$SHOW_PREVIEW" > "$PREVIEW_STATE_FILE" 2>/dev/null || PREVIEW_STATE_FILE=""
  export INTERDIMUX_PREVIEW_STATE="$PREVIEW_STATE_FILE"
  # until the navigator sets its own: an exit before that (a Ctrl-C while the
  # rest of the file is parsed) leaves nothing behind either
  trap 'early_done; rm -f ${ERR_FILE:+"$ERR_FILE"} ${PREVIEW_STATE_FILE:+"$PREVIEW_STATE_FILE"} "$MOUNTS_FILE"' EXIT
  term_cols_r
  exec {EARLY_FD}< <(
    set +e +o pipefail
    [ -z "$ERR_FILE" ] || exec 2>>"$ERR_FILE"
    list_fetch || exit
    list_core && exit
    term_cols_r
    FZF_COLUMNS="$REPLY" exec "$BASH" "$SCRIPT_PATH" --list
  )
  EARLY_PID=$!
fi
