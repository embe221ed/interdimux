# shellcheck shell=bash
# uxdiff-fixture.sh -- sourced by uxdiff.sh.  Builds the ONE deterministic
# fixture a run shares between worktree A and worktree B:
#
#   * a private tmux server ($SOCK, -f /dev/null, pinned default-command) with
#     sessions/windows/panes in fixture directories that are git repositories
#   * long and hostile session names, an ssh-like pane, fake agent panes (a
#     script named claude that sleeps, a codex-shaped node process), a zoomed
#     two-pane window, a Latin-1 byte path
#   * an isolated HOME / XDG_* / _ZO_DATA_DIR / TMPDIR, fake at/atq/atrm/batch
#     (the user's real at queue is never touched), INTERDIMUX_NOW pinned
#
# Nothing here ever talks to a tmux server other than $SOCK / $OSOCK.
# $TMUXBIN (uxdiff.sh: the tmux on PATH, resolved) is the only tmux it runs.

# Through env -i: tmux gives a pane created by an UNATTACHED client that
# client's PATH (spawn.c), and copies update-environment variables
# (SSH_CONNECTION, DISPLAY...) from it -- the user's shell must not leak in.
tin()  { env -i "${FXENV[@]}" "$TMUXBIN" -L "$SOCK" "$@"; }
tout() { env -i "${FXENV[@]}" "$TMUXBIN" -L "$OSOCK" "$@"; }

# Every process the harness runs gets exactly this environment (env -i).
FXENV=()

fx_env_init() {
  local fzfp fdp zop bashp
  fzfp=$(command -v fzf) fdp=$(command -v fd 2>/dev/null || true)
  # the dev image's zoxide is off the PATH (IMUX_PERF_ZOXIDE); uxdiff.sh has
  # warned, or refused, when there is none
  zop=${IMUX_PERF_ZOXIDE:-$(command -v zoxide 2>/dev/null || true)}
  [ -x "$zop" ] || zop=""
  bashp=$(command -v bash)
  mkdir -p "$RUN/toolbin" "$RUN/fakebin" "$RUN/agents/approve" "$RUN/agents/busy" \
           "$RUN/tmp" "$RUN/xdg-runtime" "$FH"
  chmod 700 "$RUN/xdg-runtime"
  # the tmux, fzf and bash this run uses, ahead of anything else on PATH
  ln -s "$TMUXBIN" "$RUN/toolbin/tmux"
  ln -s "$bashp" "$RUN/toolbin/bash"
  ln -s "$fzfp" "$RUN/toolbin/fzf"
  [ -n "$fdp" ] && ln -s "$fdp" "$RUN/toolbin/fd"
  [ -n "$zop" ] && ln -s "$zop" "$RUN/toolbin/zoxide"
  FXPATH="$RUN/fakebin:$RUN/toolbin:/usr/local/bin:/usr/bin:/bin"
  FXENV=(
    HOME="$FH" PATH="$FXPATH" USER="${USER:-fixture}" LOGNAME="${LOGNAME:-fixture}"
    SHELL=/bin/bash LANG=C.UTF-8 TZ=UTC TERM=tmux-256color COLORTERM=truecolor
    XDG_CONFIG_HOME="$FH/.config" XDG_DATA_HOME="$FH/.local/share"
    XDG_STATE_HOME="$FH/.local/state" XDG_CACHE_HOME="$FH/.cache"
    XDG_RUNTIME_DIR="$RUN/xdg-runtime" TMPDIR="$RUN/tmp"
    _ZO_DATA_DIR="$FH/.local/share/zoxide"
    INTERDIMUX_NOW="$FXNOW"
  )
}

# run a command in the fixture environment
fxrun() { env -i "${FXENV[@]}" "$@"; }

fx_fakes() {
  local fb="$RUN/fakebin"
  # at(1) and friends: an EMPTY queue, and a job body is recorded, never queued.
  cat > "$fb/at" <<EOF
#!/bin/sh
{ printf '== at %s\n' "\$*"; cat; } >> '$RUN/at-calls.log'
echo "uxdiff: fake at, nothing was queued" >&2
exit 1
EOF
  cp "$fb/at" "$fb/batch"
  printf '#!/bin/sh\nexit 0\n' > "$fb/atq"
  printf '#!/bin/sh\necho "== atrm $*" >> %q\nexit 1\n' "$RUN/at-calls.log" > "$fb/atrm"
  # Each fake prints a fixed, coloured screenful first (what the previews
  # capture), then sets its title, then becomes its final argv.
  # an ssh that never connects: argv `ssh box tail -f /var/log/x`, a remote-shell title
  cat > "$fb/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'Last login: Thu Jan  1 00:00:00 2026 from 10.0.0.1\n'
printf '\033[32m2026-01-01T00:00:01Z INFO \033[0m service started on :8080\n'
printf '\033[33m2026-01-01T00:00:02Z WARN \033[0m slow query (1.2 s): SELECT * FROM jobs\n'
printf '\033[1;31m2026-01-01T00:00:03Z ERROR\033[0m disk 91%% full on /var — rotating logs now, this line is long enough to be cut by any preview\n'
printf '\033]0;%s\007' 'deploy@box: /var/log'
exec perl -e '$0 = "ssh " . join(" ", @ARGV); sleep 7700001' -- "$@"
EOF
  cat > "$fb/nvim" <<'EOF'
#!/usr/bin/env bash
printf '\033[1m# infra\033[0m\n\nInfra: terraform and dashboards.\n'
printf '\033[34m~\033[0m\n\033[34m~\033[0m\n'
printf '\033[7m README.md [+]                       3,1   All \033[0m\n'
exec perl -e '$0 = "nvim " . join(" ", @ARGV); sleep 7700002' -- "$@"
EOF
  # Fake agents, shaped like tests/test_agents.sh: a script NAMED claude that
  # sets its title the way Claude does and then sleeps as `claude`.
  cat > "$RUN/agents/approve/claude" <<'EOF'
#!/usr/bin/env bash
printf '\033[38;5;174m╭───────────────────────────────────────────╮\033[0m\n'
printf '\033[38;5;174m│\033[0m \033[1m✻ Welcome to Claude Code!\033[0m                 \033[38;5;174m│\033[0m\n'
printf '\033[38;5;174m╰───────────────────────────────────────────╯\033[0m\n\n'
printf '> refactor the parser\n\n\033[32m●\033[0m Bash(rm -rf build/)\n'
printf '  Do you want to proceed?\n  \033[36m❯ 1. Yes\033[0m\n    2. No, and tell Claude what to do differently\n'
printf '\033]0;%s\007' '✳ Claude Code'
exec -a claude sleep 7700003
EOF
  cat > "$RUN/agents/busy/claude" <<'EOF'
#!/usr/bin/env bash
printf '> split the parser into a lexer and a parser\n\n'
printf '\033[38;5;174m✶ Refactoring…\033[0m \033[2m(esc to interrupt · 12s · ↓ 1.2k tokens)\033[0m\n'
printf '\033]0;%s\007' '⠐ Refactor the parser'
exec -a claude sleep 7700004
EOF
  cat > "$RUN/agents/codex" <<'EOF'
#!/usr/bin/env bash
printf '\033[1m▌ Add tests for the date parser\033[0m\n\n'
printf '\033[33m  Allow command?\033[0m  cargo test --all-features\n  \033[1my\033[0m yes   \033[1mn\033[0m no   \033[1ma\033[0m always\n'
printf '\033]0;%s\007' '[ ! ] Action Required | Add tests | proj'
exec perl -e '$0 = "node /opt/lib/node_modules/\@openai/codex/bin/codex resume"; sleep 7700005'
EOF
  cat > "$RUN/agents/titled" <<'EOF'
#!/usr/bin/env bash
printf 'Quarterly numbers\n  Q1  ¥1,234  名前\n  Q2  ¥2,345  ünïcödé\n\033[2m  (wide characters, dim)\033[0m\n'
printf '\033]0;%s\007' 'Quarterly numbers'
exec sleep 7700006
EOF
  chmod +x "$fb"/* "$RUN"/agents/*/claude "$RUN/agents/codex" "$RUN/agents/titled"
}

# git with a pinned identity and clock: same commit hashes on every run
fxgit() {
  env -i "${FXENV[@]}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
    git "$@"
}
fx_repo() { # dir branch [first README line]
  local d="$1" br="$2"
  mkdir -p "$d"
  fxgit -C "$d" init -q -b "$br" >/dev/null
  printf '# %s\n\n%s\n' "${d##*/}" "${3:-A fixture repository.}" > "$d/README.md"
  fxgit -C "$d" add -A
  fxgit -C "$d" commit -q -m "initial commit of ${d##*/}"
}

fx_dirs() {
  local P="$FH/projects"
  P_ALPHA="$P/alpha" P_BETA="$P/beta-rust" P_GAMMA="$P/gamma-node" P_INFRA="$P/infra"
  P_AGENTS="$P/agents-lab" P_SPACE="$P/spaced dir"
  P_LATIN1="$P/caf$(printf '\351')"            # a Latin-1 byte, not UTF-8
  P_UNI="$P/ünïcödé-名前"
  P_DEEP="$P/deep/level1/level2/level3/needle-target"
  P_HOSTILE="$P/it's #hash \$1"
  mkdir -p "$P" "$FH/notes" "$FH/.config" "$FH/.local/share/interdimux" \
           "$FH/.local/state/interdimux" "$FH/.local/share/zoxide" "$FH/.claude/sessions" "$FH/.cache"
  fx_repo "$P_ALPHA" main 'Alpha is the project the attached session lives in.'
  fx_repo "$P_BETA" dev 'Beta, a Rust crate.'
  printf '[package]\nname = "beta"\nversion = "0.1.0"\n' > "$P_BETA/Cargo.toml"
  fxgit -C "$P_BETA" add -A; fxgit -C "$P_BETA" commit -q -m 'cargo manifest'
  mkdir -p "$P_GAMMA"; printf '{ "name": "gamma" }\n' > "$P_GAMMA/package.json"
  fx_repo "$P_INFRA" 'feature/a-very-long-branch-name-for-truncation-tests' 'Infra: terraform and dashboards.'
  printf 'dirty\n' > "$P_INFRA/uncommitted.txt"; printf 'x\n' >> "$P_INFRA/README.md"
  fx_repo "$P_AGENTS" main 'Where the agents work.'
  fx_repo "$P_SPACE" main 'A directory name with a space in it.'
  mkdir -p "$P_LATIN1" "$P_UNI" "$P_DEEP" "$P_HOSTILE"
  printf 'plain dir\n' > "$P_UNI/README.txt"
  # A detached HEAD, which the preview and the git badge show as @<hash>
  fxgit -C "$P_SPACE" checkout -q --detach HEAD
  # recent directories (the ctrl-o picker's and the navigator's D rows)
  printf '%s\n' "$P_BETA" "$P_GAMMA" "$P_ALPHA" "$P_SPACE" "$P_UNI" "$FH/notes" \
    > "$FH/.local/share/interdimux/recent_dirs"
  # zoxide, isolated in _ZO_DATA_DIR
  if [ -x "$RUN/toolbin/zoxide" ]; then
    local d
    for d in "$P/deep/level1" "$P_GAMMA" "$P_HOSTILE" "$FH/notes"; do
      (cd "$d" && fxrun zoxide add "$d") >/dev/null 2>&1 || true
    done
  fi
  : > "$FH/.local/state/interdimux/errors.log"
}

# The Claude registry record for a fake claude pane, written the way Claude
# writes it (one line, no newline).  $1 pane id, $2 status, $3 waitingFor, $4 seconds before NOW
fx_claude_record() {
  local pane="$1" pid start
  pid=$(tin display-message -p -t "$pane" '#{pane_pid}')
  local -a st
  read -r -a st < "/proc/$pid/stat"
  start="${st[21]}"
  printf '{"pid":%s,"sessionId":"fixture","cwd":"%s","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"fx:@1.%s","name":"n","status":"%s","waitingFor":"%s","statusUpdatedAt":%s}' \
    "$pid" "$P_AGENTS" "$start" "$pane" "$2" "$3" "$(( (FXNOW - $4) * 1000 ))" \
    > "$FH/.claude/sessions/$pid.json"
}

# wait (bounded) until "$@" succeeds
fx_until() { local n="$1" i; shift; for (( i = 0; i < n; i++ )); do "$@" && return 0; sleep 0.05; done; return 1; }

fx_pane_cmd_is() { # pane, expected argv prefix
  local pid; pid=$(tin display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$pid/cmdline")" == "$2"* ]]
}
fx_title_is() { [ "$(tin display-message -p -t "$1" '#{pane_title}' 2>/dev/null)" = "$2" ]; }
fx_prompt_in() { tin capture-pane -p -t "$1" 2>/dev/null | grep -q 'bash-[0-9.]*\$'; }
fx_cwd_is() { [ "$(tin display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null)" = "$2" ]; }

fx_server() {
  local B='bash --norc --noprofile -i' try s0 n i
  # ONE tmux invocation, started just after a second boundary: the navigator's
  # MRU order sorts never-attached sessions by #{session_activity}, which has
  # one-second resolution -- sessions created across a boundary would order
  # differently from run to run.  (Within a run A and B share the fixture
  # either way; this makes the outputs comparable ACROSS runs too.)
  # tmux FORMAT-EXPANDS new-session -s and -c: '#' is doubled in both.
  local -a c=(
    start-server \;
    set -g default-command "$B" \; set -g default-terminal tmux-256color \;
    set -g exit-empty off \; set -as terminal-features ',tmux-256color:RGB' \;
    set -g status-right '"#{=21:pane_title}"' \;
    set-environment -g INTERDIMUX_NOW "$FXNOW" \;
    set -g history-limit 2000 \;
    set -s message-limit 100000 \;
    new-session -d -s host -n shell -x 120 -y 39 -c "$P_ALPHA" \;
    new-window -d -t '=host:' -n notes -c "$FH/notes" \;
    new-session -d -s infrastructure-monitoring -n logs -x 120 -y 39 -c "$P_INFRA" \
      "exec ssh box tail -f /var/log/x" \;
    new-window -d -t '=infrastructure-monitoring:' -n split -c "$P_INFRA" \;
    split-window -d -h -t '=infrastructure-monitoring:=1' -c "$P_INFRA" "exec nvim README.md" \;
    resize-pane -Z -t '=infrastructure-monitoring:=1.0' \;
    new-session -d -s agents-playground-sessions -n claude -x 120 -y 39 -c "$P_AGENTS" \
      "exec '$RUN/agents/approve/claude'" \;
    new-window -d -t '=agents-playground-sessions:' -n busy -c "$P_AGENTS" "exec '$RUN/agents/busy/claude'" \;
    new-window -d -t '=agents-playground-sessions:' -n codex -c "$P_AGENTS" "exec '$RUN/agents/codex'" \;
    new-window -d -t '=agents-playground-sessions:' -n titled -c "$P_AGENTS" "exec '$RUN/agents/titled'" \;
    new-session -d -s '$1' -n dollar -x 120 -y 39 -c "${P_HOSTILE//'#'/##}" \;
    new-session -d -s "it's \"quoted\" ##hash" -n 'w#in "q"' -x 120 -y 39 -c "$P_SPACE" \;
    new-session -d -s 'spaced name ünïcödé 名前' -n 'ünï 名' -x 120 -y 39 -c "$P_UNI" \;
    new-session -d -s latin1-path -n latin -x 120 -y 39 -c "$P_LATIN1" \;
    new-session -d -s beta-rust-long-session-name -n build -x 120 -y 39 -c "$P_BETA" \;
    new-window -d -t '=beta-rust-long-session-name:' -n test -c "$P_BETA"
  )
  for try in 1 2 3; do
    s0=$(date +%s); while [ "$(date +%s)" = "$s0" ]; do sleep 0.01; done
    env -i "${FXENV[@]}" "$TMUXBIN" -f /dev/null -L "$SOCK" "${c[@]}" || return 1
    n=$(tin list-sessions -F '#{session_activity}' 2>/dev/null | sort -u | grep -c .)
    [ "$n" = 1 ] && return 0
    [ "$try" = 3 ] && { echo "uxdiff: note: the fixture's sessions span $n seconds (order may differ from other runs)" >&2; return 0; }
    echo "uxdiff: the fixture's sessions straddled a second; rebuilding it" >&2
    tin kill-server >/dev/null 2>&1
    for (( i = 0; i < 100; i++ )); do server_dead "$SOCK" && break; sleep 0.05; done
    rm -f "/tmp/tmux-$(id -u)/$SOCK"
  done
}

# Wait for every pane to reach its final state: a shell at its prompt, a fake
# at its final argv and title, and tmux reporting the cwd it was started in.
fx_settle() {
  local p cmd ok=1
  while IFS=$'\t' read -r p cmd; do
    case "$cmd" in
      bash) fx_until 200 fx_prompt_in "$p" || { echo "uxdiff: pane $p never showed a prompt" >&2; ok=0; } ;;
    esac
  done < <(tin list-panes -a -F "#{pane_id}	#{pane_current_command}")
  fx_until 200 fx_pane_cmd_is '=infrastructure-monitoring:=0.0' 'ssh box tail -f /var/log/x' || { echo "uxdiff: ssh pane not settled" >&2; ok=0; }
  fx_until 200 fx_title_is '=infrastructure-monitoring:=0.0' 'deploy@box: /var/log' || ok=0
  fx_until 200 fx_pane_cmd_is '=infrastructure-monitoring:=1.1' 'nvim README.md' || { echo "uxdiff: nvim pane not settled" >&2; ok=0; }
  fx_until 200 fx_pane_cmd_is '=agents-playground-sessions:=0.0' 'claude 7700003' || { echo "uxdiff: claude pane not settled" >&2; ok=0; }
  fx_until 200 fx_title_is '=agents-playground-sessions:=0.0' '✳ Claude Code' || ok=0
  fx_until 200 fx_pane_cmd_is '=agents-playground-sessions:=1.0' 'claude 7700004' || ok=0
  fx_until 200 fx_title_is '=agents-playground-sessions:=1.0' '⠐ Refactor the parser' || ok=0
  fx_until 200 fx_pane_cmd_is '=agents-playground-sessions:=2.0' 'node /opt/lib' || ok=0
  fx_until 200 fx_title_is '=agents-playground-sessions:=2.0' '[ ! ] Action Required | Add tests | proj' || ok=0
  fx_until 200 fx_title_is '=agents-playground-sessions:=3.0' 'Quarterly numbers' || ok=0
  # tmux reads a pane's cwd from /proc at query time; wait until all agree
  while IFS=$'\t' read -r p cmd; do
    fx_until 200 eval "[ -n \"\$(tin display-message -p -t '$p' '#{pane_current_path}')\" ]" || ok=0
  done < <(tin list-panes -a -F "#{pane_id}	#{pane_current_command}")
  [ "$ok" = 1 ]
}

fx_registry() {
  local approve busy
  approve=$(tin display-message -p -t '=agents-playground-sessions:=0.0' '#{pane_id}')
  busy=$(tin display-message -p -t '=agents-playground-sessions:=1.0' '#{pane_id}')
  fx_claude_record "$approve" waiting 'permission prompt' 300
  fx_claude_record "$busy" busy '' 7300
  # a record for a dead pid that names the codex pane: never believed
  printf '{"pid":999999,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"1","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"fx:@1.%%9","name":"n","status":"busy","waitingFor":"","statusUpdatedAt":1}' \
    > "$FH/.claude/sessions/999999.json"
}

# Everything mutable the script may write, snapshotted once and restored
# before every scenario, so no scenario (and no side) sees another's leftovers.
STATE_DIRS=(".local/share" ".local/state" ".cache" ".config")
fx_snapshot() {
  mkdir -p "$RUN/snap"
  ( cd "$FH" && tar -cf "$RUN/snap/home-state.tar" "${STATE_DIRS[@]}" ) || return 1
  # the same, unpacked: what side_effects diffs the state against
  mkdir -p "$RUN/snap/tree" && tar -xf "$RUN/snap/home-state.tar" -C "$RUN/snap/tree"
}
fx_restore() {
  local d
  for d in "${STATE_DIRS[@]}"; do rm -rf "${FH:?}/$d"; done
  ( cd "$FH" && tar -xf "$RUN/snap/home-state.tar" ) || return 1
  # scratch files a navigator leaves behind (it removes its own on exit)
  find "$RUN/xdg-runtime" "$RUN/tmp" -mindepth 1 -delete 2>/dev/null || true
}

# Install THIS side's key bindings on the fixture server (as the plugin does).
fx_bind_keys() {
  ( cd "$FH" && exec env -i "${FXENV[@]}" TMUX="$FX_SOCKET_PATH,$FX_SERVER_PID,0" \
      setsid -w timeout 60 bash "$SCRIPT" --bind-keys ) </dev/null >"$RUN/bind-keys.log" 2>&1
}

fx_build() {
  fx_env_init && fx_fakes && fx_dirs || return 1
  fx_server || { echo "uxdiff: the fixture server did not start" >&2; return 1; }
  fx_settle || { echo "uxdiff: the fixture panes did not settle" >&2; return 1; }
  fx_registry
  # shellcheck disable=SC2034  # read by uxdiff-text.sh and uxdiff-screen.sh
  FX_HOST_PANE=$(tin display-message -p -t '=host:=0.0' '#{pane_id}')
  FX_SOCKET_PATH=$(tin display-message -p '#{socket_path}')
  FX_SERVER_PID=$(tin display-message -p '#{pid}')
  fx_snapshot
  # every pane pid, so cleanup can prove each one is gone
  tin list-panes -a -F '#{pane_pid}' > "$RUN/pane-pids"
}
