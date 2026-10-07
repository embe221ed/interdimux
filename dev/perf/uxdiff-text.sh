# shellcheck shell=bash
# shellcheck disable=SC2088  # literal ~ in queries is deliberate: it is what a user types
# uxdiff-text.sh -- sourced by uxdiff.sh: the TEXT scenarios.
#
# Each runs the plugin script (through the shared $RUN/plugin symlink, so A
# and B have the same path) in the fixture environment, with the environment a
# popup child gets from the prefix+f binding (CB_ENV), under setsid so that no
# width fallback can read the caller's terminal, and appends a normalised
# section (stdout, stderr, exit status) to $SC_FILE.

CB_ENV=() COLD_ENV=()
cb_env_init() {
  local fv tv
  fv=$(fxrun fzf --version 2>/dev/null); fv="${fv%% *}"
  FZF_MINOR_V=$(printf '%s' "$fv" | cut -d. -f2)
  [ "$(printf '%s' "$fv" | cut -d. -f1)" = 0 ] || FZF_MINOR_V=999
  tv=$("$TMUXBIN" -V); [[ "$tv" =~ ([0-9]+)\.([0-9]+) ]] && TVNUM=$(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] ))
  local tmuxv="$FX_SOCKET_PATH,$FX_SERVER_PID,0"
  # what the baked prefix+f binding hands a popup (see --bind-keys)
  CB_ENV=(TMUX="$tmuxv" TMUX_PANE="$FX_HOST_PANE" INTERDIMUX_CLIENT="$FX_CLIENT"
          INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR="$FZF_MINOR_V" INTERDIMUX_TMUX_VNUM="$TVNUM")
  # a user typing the command in a pane of the server: everything read cold
  COLD_ENV=(TMUX="$tmuxv" TMUX_PANE="$FX_HOST_PANE")
}

# tx TITLE [-c] [-n] [VAR=val ...] -- ARGS...
#   -c  cold: the environment of a shell in a pane, not of a popup child
#   -n  no tmux at all (TMUX unset)
tx() {
  local title="$1"; shift
  local -a base=("${CB_ENV[@]}") ev=()
  while :; do
    case "${1:-}" in
      -c) base=("${COLD_ENV[@]}"); shift ;;
      -n) base=(); shift ;;
      *) break ;;
    esac
  done
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  local o="$RUN/tx.out" e="$RUN/tx.err" rc
  ( cd "$FH" && exec env -i "${FXENV[@]}" ${base[@]+"${base[@]}"} ${ev[@]+"${ev[@]}"} \
      setsid -w timeout 30 bash "$SCRIPT" "$@" ) </dev/null >"$o" 2>"$e"
  rc=$?
  {
    printf '### %s\n' "$title"
    printf '$'; printf ' %q' ${ev[@]+"${ev[@]}"} "$@"; printf '\n'
    cat "$o"
    printf '\n'
    if [ -s "$e" ]; then printf -- '--- stderr\n'; cat "$e"; printf '\n'; fi
    printf -- '--- rc=%s\n\n' "$rc"
  } | norm >> "$SC_FILE"
}

# The rows' specs (the last tab field) of side's --list, for the per-row scenarios
list_specs() {
  ( cd "$FH" && exec env -i "${FXENV[@]}" "${CB_ENV[@]}" FZF_COLUMNS=120 \
      setsid -w timeout 60 bash "$SCRIPT" --list ) </dev/null 2>/dev/null | awk -F'\t' '{print $NF}'
}

# --- --list -------------------------------------------------------------------
t_list() { # $1 = on|off (the Rust core), $2 = raw on|off
  local c pv
  for c in 80 94 120 160 200; do
    for pv in hidden shown; do
      if [ "$pv" = shown ]; then
        tx "cols=$c preview=$pv" INTERDIMUX_USE_RUST="$1" INTERDIMUX_RAW="$2" \
          INTERDIMUX_SHOW_PREVIEW=on FZF_COLUMNS="$c" FZF_PREVIEW_COLUMNS=$(( c / 2 - 1 )) -- --list
      else
        tx "cols=$c preview=$pv" INTERDIMUX_USE_RUST="$1" INTERDIMUX_RAW="$2" \
          INTERDIMUX_SHOW_PREVIEW=off FZF_COLUMNS="$c" -- --list
      fi
    done
  done
}
t_list_misc() { # $1 = on|off
  # cold: typed in a pane, options read from tmux, width from the (absent) tty
  tx "cold, no FZF_COLUMNS" -c INTERDIMUX_USE_RUST="$1" -- --list
  # launch time: no fzf yet, width from the tty, the preview from the option
  tx "launch-time width, preview option on" INTERDIMUX_USE_RUST="$1" INTERDIMUX_SHOW_PREVIEW=on -- --list
  tx "agents view" INTERDIMUX_USE_RUST="$1" INTERDIMUX_VIEW=agents FZF_COLUMNS=120 -- --list
  local m
  for m in kill rename zoom swap detach send; do
    tx "mode=$m" INTERDIMUX_USE_RUST="$1" INTERDIMUX_MODE="$m" FZF_COLUMNS=120 -- --list
  done
  # non-default options that change the rows
  tx "order=index show-dirs=off" INTERDIMUX_USE_RUST="$1" INTERDIMUX_ORDER=index INTERDIMUX_SHOW_DIRS=off FZF_COLUMNS=120 -- --list
  tx "show-full-command=off show-git-branch=off" INTERDIMUX_USE_RUST="$1" INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off FZF_COLUMNS=160 -- --list
  tx "show-title=all agent-args=on" INTERDIMUX_USE_RUST="$1" INTERDIMUX_SHOW_TITLE=all INTERDIMUX_AGENT_ARGS=on FZF_COLUMNS=160 -- --list
  tx "hide=agents-* session-rule=off" INTERDIMUX_USE_RUST="$1" 'INTERDIMUX_HIDE=agents-*' INTERDIMUX_SESSION_RULE=off FZF_COLUMNS=120 -- --list
  tx "colours overridden" INTERDIMUX_USE_RUST="$1" INTERDIMUX_COLOR_ACCENT=33 INTERDIMUX_COLOR_TREE=0 INTERDIMUX_COLOR_PATH=81 FZF_COLUMNS=120 -- --list
}

# --- --preview ----------------------------------------------------------------
t_preview() { # $1 = row type S|W|P|D
  local spec
  while IFS= read -r spec; do
    [ "${spec%%:*}" = "$1" ] || continue
    tx "preview $spec" FZF_PREVIEW_COLUMNS=58 FZF_COLUMNS=120 FZF_PREVIEW_LINES=30 -- --preview "$spec"
  done < <(list_specs)
  # a row that no longer exists
  case "$1" in
    S) tx "preview of a gone session" FZF_PREVIEW_COLUMNS=58 -- --preview 'S:no-such-session' ;;
    W) tx "preview of a gone window"  FZF_PREVIEW_COLUMNS=58 -- --preview 'W:host:9' ;;
    P) tx "preview of a gone pane"    FZF_PREVIEW_COLUMNS=58 -- --preview 'P:host:0:7' ;;
    D) tx "preview of a gone dir"     FZF_PREVIEW_COLUMNS=58 -- --preview "D:$FH/projects/gone" ;;
  esac
}

# --- the hint bar and the other fzf callbacks ----------------------------------
# One representative row of each kind, as fzf hands {-1}.
pick_spec() { # $1 = type, $2 = substring
  list_specs | awk -v t="$1:" -v s="$2" 'index($0, t) == 1 && index($0, s) { print; exit }'
}
t_footer() { # $1 = row type, $2 = a substring picking the row
  local spec c
  spec=$(pick_spec "$1" "$2")
  [ -n "$spec" ] || { printf '### no %s row matching %s in the list\n' "$1" "$2" >> "$SC_FILE"; return 0; }
  for c in 60 80 120 200; do
    tx "$spec empty query cols=$c" FZF_COLUMNS="$c" FZF_MATCH_COUNT=27 FZF_TOTAL_COUNT=27 FZF_QUERY= -- --footer-for "$spec"
    tx "$spec empty query cols=$c preview" FZF_COLUMNS="$c" FZF_PREVIEW_COLUMNS=$(( c / 2 - 1 )) FZF_MATCH_COUNT=27 FZF_TOTAL_COUNT=27 FZF_QUERY= -- --footer-for "$spec"
  done
  for c in 80 120; do
    tx "$spec matching query cols=$c" FZF_COLUMNS="$c" FZF_MATCH_COUNT=3 FZF_TOTAL_COUNT=27 FZF_QUERY=infra -- --footer-for "$spec"
    tx "$spec path-ish query cols=$c" FZF_COLUMNS="$c" FZF_MATCH_COUNT=2 FZF_TOTAL_COUNT=27 FZF_QUERY="projects/gamma" -- --footer-for "$spec"
    tx "$spec zero-match query cols=$c" FZF_COLUMNS="$c" FZF_MATCH_COUNT=0 FZF_TOTAL_COUNT=27 FZF_QUERY=zzqx -- --footer-for "$spec"
    tx "$spec zero-match existing dir cols=$c" FZF_COLUMNS="$c" FZF_MATCH_COUNT=0 FZF_TOTAL_COUNT=27 FZF_QUERY="~/projects/beta-rust" -- --footer-for "$spec"
  done
  tx "$spec raw dimmed row" FZF_COLUMNS=120 FZF_MATCH_COUNT=5 FZF_TOTAL_COUNT=27 FZF_QUERY=agents FZF_RAW=0 FZF_CURRENT_ITEM=x -- --footer-for "$spec"
  tx "$spec old fzf (0.62)" INTERDIMUX_FZF_MINOR=62 FZF_COLUMNS=120 FZF_MATCH_COUNT=3 FZF_QUERY=infra -- --footer-for "$spec"
}
t_hint_ladder() {
  local t
  for t in S W P D X; do
    tx "ladder $t" -- --hint-ladder "$t"
    tx "ladder $t (preview on)" INTERDIMUX_SHOW_PREVIEW=on -- --hint-ladder "$t"
  done
}
t_scope_prompt() {
  local n
  for n in '' 1 2 3 1,2,3 1,3 2,3; do tx "FZF_NTH=$n" FZF_NTH="$n" -- --scope-prompt; done
}
t_session_name_for() {
  local P="$FH/projects" d
  for d in "$P/alpha" "$P/beta-rust" "$P/gamma-node" "$P/spaced dir" "$P_LATIN1" "$P_UNI" \
           "$P_HOSTILE" "$P/deep/level1" "$P_DEEP" "$FH" "$FH/notes" / "$P/does-not-exist" "$P/alpha/"; do
    tx "name for $d" -- --session-name-for "$d"
  done
}
t_describe_create() {
  local q
  for q in '' 'newthing' 'beta' 'beta-rust' 'gamma-node' '~/projects/alpha' 'projects/gamma' 'level1' \
           'zzqx' "it's" '$1' 'name with space' '/' '~' "$FH/notes" '名前' '#hash' "'" '!' '  '; do
    tx "describe [$q]" FZF_COLUMNS=120 -- --describe-create "$q"
  done
}
t_create_key() {
  local q
  for q in '' 'newthing' 'beta' "'" '!' '  ' '$1' 'host'; do
    tx "create-key [$q]" FZF_QUERY="$q" -- --create-key
  done
}

# --- the directory picker ----------------------------------------------------
t_dirs_list() {
  local c
  for c in 80 160; do
    tx "default cols=$c" FZF_COLUMNS="$c" -- --dirs-list
    tx "deep, empty query cols=$c" FZF_COLUMNS="$c" -- --dirs-list --deep ''
    tx "deep 'needle' cols=$c" FZF_COLUMNS="$c" -- --dirs-list --deep needle
    tx "deep 'level2' cols=$c" FZF_COLUMNS="$c" -- --dirs-list --deep level2
    tx "deep path 'projects/deep/lev' cols=$c" FZF_COLUMNS="$c" -- --dirs-list --deep projects/deep/lev
    tx "deep '~/projects' cols=$c" FZF_COLUMNS="$c" -- --dirs-list --deep '~/projects'
    tx "deep zero-match cols=$c" FZF_COLUMNS="$c" -- --dirs-list --deep zzqx
    tx "scan '' cols=$c" FZF_COLUMNS="$c" -- --dirs-list --scan ''
  done
  tx "project dirs set, zoxide off" INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_PROJECT_DIRS="$FH/projects/deep:$FH/notes" FZF_COLUMNS=120 -- --dirs-list
}
t_dirs_preview() {
  local spec
  while IFS= read -r spec; do
    tx "dirs-preview $spec" FZF_PREVIEW_COLUMNS=38 -- --dirs-preview "$spec"
  done < <(cd "$FH" && env -i "${FXENV[@]}" "${CB_ENV[@]}" FZF_COLUMNS=120 setsid -w timeout 60 bash "$SCRIPT" --dirs-list </dev/null 2>/dev/null | awk -F'\t' '{print $NF}')
  tx "dirs-preview of a gone dir" -- --dirs-preview "$FH/projects/gone"
}
t_dirs_hints() {
  local c
  for c in 40 64 100 160; do
    tx "default cols=$c" FZF_COLUMNS="$c" -- --dirs-hints
    tx "deep cols=$c" FZF_COLUMNS="$c" -- --dirs-hints deep needle
    tx "browse cols=$c" FZF_COLUMNS="$c" -- --dirs-hints browse '~/projects'
  done
}

# --- --doctor ----------------------------------------------------------------
SEEDED_ERRLOG='== 2026-01-01 00:00:00 navigator stderr
fzf: unknown option: --bogus-flag
== 2026-01-02 12:30:00 rust core refused gather2
interdimux: the Rust core at /opt/imux is from another version of interdimux (it does not speak gather3), so the list uses the slower bash renderer; rebuild it
'
t_doctor() { # $1 = empty|seeded
  [ "$1" = seeded ] && printf '%s' "$SEEDED_ERRLOG" > "$FH/.local/state/interdimux/errors.log"
  fx_bind_keys      # this side's own bindings, which the report checks
  local c
  for c in 44 80 100 140; do
    tx "doctor cols=$c" FZF_COLUMNS="$c" -- --doctor
  done
  tx "doctor, cold (typed in a pane)" -c -- --doctor
  fx_restore
}

# --- usage -------------------------------------------------------------------
t_cli() {
  tx "--help" -n -- --help
  tx "-h" -n -- -h
  tx "--version" -n -- --version
  tx "unknown mode" -- --bogus
  tx "outside tmux" -n -- --list
  tx "--connect-dir without a dir" -- --connect-dir
  tx "--connect-dir missing dir" -- --connect-dir "$FH/projects/does-not-exist"
  # a status-line message (recorded by side_effects), and nothing switched
  tx "--jump 99 (no such session)" -- --jump 99
  tx "--jump 0" -- --jump 0
  tx "--jump abc" -- --jump abc
  tx "--jobs-list (empty queue)" -- --jobs-list
  tx "--sched-list (empty queue)" -- --sched-list
}

# --- --bind-keys' effect, on a server of its own ----------------------------
bk_dump() {
  local s="$BKSOCK"
  printf '### list-keys\n'
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" list-keys 2>&1
  printf '### show-options -g\n'
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" show-options -g 2>&1
  printf '### show-options -s\n'
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" show-options -s 2>&1
  printf '### show-options -gw\n'
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" show-options -gw 2>&1
  printf '### show-environment -g\n'
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" show-environment -g 2>&1
}
t_bind_keys() { # $1 = default|custom
  local s="$BKSOCK" path i
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" kill-server >/dev/null 2>&1
  for (( i = 0; i < 100; i++ )); do server_dead "$s" && break; sleep 0.05; done
  env -i "${FXENV[@]}" "$TMUXBIN" -f /dev/null -L "$s" new-session -d -s bk -x 100 -y 30 'exec sleep 7700009' \
    || { echo "### could not start the bind-keys server" >> "$SC_FILE"; return 0; }
  if [ "$1" = custom ]; then
    env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" set -g @interdimux-key F \; set -g @interdimux-dashboard-key G \; \
      set -g @interdimux-jump-keys 'M-1 M-2 M-3' \; set -g @interdimux-popup-width 90% \; set -g @interdimux-popup-height 60
  fi
  path=$(env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" display-message -p '#{socket_path}')
  local o="$RUN/tx.out" e="$RUN/tx.err" rc
  ( cd "$FH" && exec env -i "${FXENV[@]}" TMUX="$path,1,0" setsid -w timeout 60 bash "$SCRIPT" --bind-keys ) \
    </dev/null >"$o" 2>"$e"
  rc=$?
  { printf '### --bind-keys (%s) rc=%s\n' "$1" "$rc"; cat "$o" "$e"; bk_dump; } | norm >> "$SC_FILE"
  env -i "${FXENV[@]}" "$TMUXBIN" -L "$s" kill-server >/dev/null 2>&1
  for (( i = 0; i < 100; i++ )); do server_dead "$s" && break; sleep 0.05; done
  server_dead "$s" && rm -f "/tmp/tmux-$(id -u)/$s"
}

text_scenarios() {
  cb_env_init
  # every text scenario starts from the pristine state
  local r
  for r in on off; do
    local rn=rust; [ "$r" = off ] && rn=bash
    run_scenario text "list-$rn-raw-on"  t_list "$r" on
    run_scenario text "list-$rn-raw-off" t_list "$r" off
    run_scenario text "list-$rn-misc"    t_list_misc "$r"
  done
  run_scenario text preview-S t_preview S
  run_scenario text preview-W t_preview W
  run_scenario text preview-P t_preview P
  run_scenario text preview-D t_preview D
  run_scenario text footer-for-S t_footer S 'S:infrastructure'
  run_scenario text footer-for-W t_footer W 'W:infrastructure-monitoring:0'
  run_scenario text footer-for-W-agent t_footer W 'W:agents-playground-sessions:0'
  run_scenario text footer-for-P t_footer P 'P:infrastructure-monitoring:1:1'
  run_scenario text footer-for-D t_footer D 'gamma-node'
  run_scenario text hint-ladder t_hint_ladder
  run_scenario text scope-prompt t_scope_prompt
  run_scenario text session-name-for t_session_name_for
  run_scenario text describe-create t_describe_create
  run_scenario text create-key t_create_key
  run_scenario text dirs-list t_dirs_list
  run_scenario text dirs-preview t_dirs_preview
  run_scenario text dirs-hints t_dirs_hints
  run_scenario text doctor-errlog-empty t_doctor empty
  run_scenario text doctor-errlog-seeded t_doctor seeded
  run_scenario text cli-usage t_cli
  run_scenario text bind-keys-default t_bind_keys default
  run_scenario text bind-keys-custom t_bind_keys custom
}
