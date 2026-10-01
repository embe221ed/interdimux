#!/usr/bin/env bash
#
# A path on a filesystem whose stat() can block is never probed before the
# first paint.
#
# Every row can cost filesystem probes before anything is drawn: the git badge
# walks <dir>/.git up to /, a directory row's type badge is up to 11 marker
# tests, a recent/zoxide directory is checked for existence -- and bash captures
# the renderer's whole output, so nothing paints until the last one returns.  On
# a stalled NFS/CIFS/sshfs mount each probe blocks for the mount's timeout
# (measured with a FUSE filesystem whose lookups stall 1 s: one such directory
# in the recent list took --list from 0.1 s to 11 s, a pane in it to 2 s).
#
# A hung mount cannot be built here without root, so the mount table is the
# seam: INTERDIMUX_MOUNTINFO points both renderers at a copy of
# /proc/self/mountinfo with a few lines appended that declare fixture
# directories to be NFS / gocryptfs mounts.  The directories are real and local,
# so the oracle is what a probe WOULD have found: each carries a Cargo.toml and
# a .git/HEAD, so a badge on a "remote" row means it was probed, and a row for
# a directory that does not exist means it was not stat()ed.  The same fixture
# without the seam is the control.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-remote-test-$$"
# The long name is on purpose: see the premise check after row().
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-remote-a-directory-name-this-long-on-purpose-so-that-every-list-this-suite-reads-is-longer-than-one-4KiB-pipe-block-see-the-premise-check-after-row.XXXXXX")" && pwd -P)"
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

echo "interdimux remote-mount tests"
echo

if [ ! -r /proc/self/mountinfo ]; then
  echo "  (skipped: no /proc/self/mountinfo on this system -- nothing is classified there)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# a project: a Cargo.toml and a git branch named after it
mkproj() { mkdir -p "$1/.git"; : > "$1/Cargo.toml"; printf 'ref: refs/heads/%s\n' "$2" > "$1/.git/HEAD"; }
mkproj "$TMPD/nas/proj"     nasbranch
mkproj "$TMPD/nas/work"     naswork
mkproj "$TMPD/local/proj"   localbranch
mkproj "$TMPD/local/work"   localwork
mkproj "$TMPD/vault/proj"   vaultbranch
mkproj "$TMPD/home/proj"    homebranch
mkproj "$TMPD/local/zdir"   zoxidebranch
# A $HOME that is a symlink onto an NFS mount (/home/u -> /gpfs/home/u, as on
# some clusters): tmux reports a pane's cwd resolved, so the pane "in ~/proj"
# is in gpfs/u/proj.
mkproj "$TMPD/gpfs/u/proj"  gpfsproj
mkproj "$TMPD/gpfs/u/other" gpfsother
ln -s "$TMPD/gpfs/u" "$TMPD/linkhome"
# 9p: WSL2's Windows drives (drvfs, over fd) and a real network share (over tcp)
mkproj "$TMPD/wsl/c/work"   drvfswork
mkproj "$TMPD/wsl/c/proj"   drvfsproj
mkproj "$TMPD/net9p/proj"   net9pproj
# A repository whose root is on NFS, with a local tmpfs mounted inside it: the
# git walk from inside the tmpfs must stop at the NFS level, and one that finds
# its own repository first keeps its badge.
mkproj "$TMPD/nfsrepo"      nfsrepobranch
mkdir -p "$TMPD/nfsrepo/scratch/work"
mkproj "$TMPD/nfsrepo/scratch/own" ownbranch
# Mount points with a blank, a tab and a newline in them, each FOLLOWED BY A
# DIGIT: mountinfo writes them \040, \011, \012 -- see the cases below.
mkproj "$TMPD/nas 1/proj"          nas1branch
mkproj "$TMPD/nas 1/work"          nas1work
mkproj "$TMPD/tab"$'\t'"5/proj"      tab5branch
mkproj "$TMPD/nl"$'\n'"1/proj"       nl1branch
mkdir -p "$TMPD/data/interdimux" "$TMPD/bin" "$TMPD/fzfbin" "$TMPD/run"
chmod 700 "$TMPD/run"
printf '%s\n' "$TMPD/nas/proj" "$TMPD/nas/gone" "$TMPD/local/proj" "$TMPD/vault/proj" "$TMPD/home/proj" \
  "$TMPD/gpfs/u/other" "$TMPD/wsl/c/proj" "$TMPD/net9p/proj" > "$TMPD/data/interdimux/recent_dirs"

MI="$TMPD/mountinfo"
{
  cat /proc/self/mountinfo
  echo "900 1 0:900 / $TMPD/nas rw,relatime shared:900 - nfs4 srv:/nas rw"
  echo "901 1 0:901 / $TMPD/vault rw,nosuid shared:901 - fuse.gocryptfs $TMPD/.vault rw"
  echo "902 1 0:902 / $TMPD/home rw,relatime shared:902 - nfs4 srv:/home rw"
  echo "903 1 0:903 / $TMPD/gpfs rw,relatime shared:903 - nfs4 srv:/gpfs rw"
  # verbatim from a WSL2 host, but for the path
  echo "904 1 0:904 / $TMPD/wsl/c rw,noatime - 9p drvfs rw,dirsync,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/,mmap,access=client,msize=65536,trans=fd,rfd=5,wfd=5"
  echo "905 1 0:905 / $TMPD/net9p rw,relatime - 9p 10.0.0.1 rw,access=user,trans=tcp,port=564"
  echo "906 1 0:906 / $TMPD/nfsrepo rw,relatime shared:906 - nfs4 srv:/repo rw"
  echo "907 906 0:907 / $TMPD/nfsrepo/scratch rw shared:907 - tmpfs tmpfs rw"
  echo "908 1 0:908 / $TMPD/nas\\0401 rw,relatime shared:908 - nfs4 srv:/nas1 rw"
  echo "909 1 0:909 / $TMPD/tab\\0115 rw,relatime shared:909 - cifs //srv/tab rw"
  echo "910 1 0:910 / $TMPD/nl\\0121 rw,relatime shared:910 - nfs4 srv:/nl1 rw"
} > "$MI"

tmux -f /dev/null -L "$SOCK" new-session -d -s bench -x 200 -y 50 -c "$TMPD/home" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s naspane -x 200 -y 50 -c "$TMPD/nas/work" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s locpane -x 200 -y 50 -c "$TMPD/local/work" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s gpane -x 200 -y 50 -c "$TMPD/gpfs/u/proj" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s wslpane -x 200 -y 50 -c "$TMPD/wsl/c/work" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s nestpane -x 200 -y 50 -c "$TMPD/nfsrepo/scratch/work" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s ownpane -x 200 -y 50 -c "$TMPD/nfsrepo/scratch/own" 'sleep 99999'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=bench:0' -F '#{pane_id}' | head -1)"
export HOME="$TMPD/home" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on
export INTERDIMUX_DIRS_LIMIT=20 INTERDIMUX_PROJECT_DIRS="$TMPD/nowhere"
# wide enough that the git-badge column is on (it is off at 80 columns)
export FZF_COLUMNS=200 INTERDIMUX_NOW="$(date +%s)"
for _d in nas/work gpfs/u/proj wsl/c/work nfsrepo/scratch/work nfsrepo/scratch/own; do
  wait_for "the panes' cwds ($_d)" sh -c "tmux -L '$SOCK' list-panes -a -F '#{pane_current_path}' | grep -qx '$TMPD/$_d'"
done

renderers="off"
[ -x "$BIN" ] && renderers="on off"

# The --list row whose spec is $2, ANSI stripped; $1 = on|off.  LIST_ENV holds
# the extra environment (the seam, or nothing).
#
# awk reads to the END rather than `exit`ing at the match.  sed writes a pipe in
# 4 KiB blocks, so once the list is longer than one, a reader that quits after
# the first block leaves sed's next write with nobody to read it: SIGPIPE (141)
# -- or, where SIGPIPE is ignored as in CI, EPIPE and exit 4 -- which pipefail
# hands to `got=$(row ...)`, and set -e then ended the whole suite with no
# Results line.  Every $TMPD path makes the list longer, so it bit only under
# a long TMPDIR; the scratch directory's own long name makes it bite here
# always, which the premise check below asserts.
row() { env $LIST_ENV INTERDIMUX_USE_RUST="$1" bash "$SCRIPT" --list 2>/dev/null \
          | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' -v s="$2" '!f && $4 == s { print; f = 1 }'; }

# Premise: the list outgrows one pipe block, so row() above is read in the
# regime where an early-exiting reader kills the suite.  If the fixture ever
# shrinks below it, that guard would stop guarding: say so.
for e in "" "INTERDIMUX_MOUNTINFO=$MI"; do
  n=$(env $e bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
  label=$([ -n "$e" ] && echo "the seam's table" || echo "the real table")
  [ "$n" -gt 4096 ] && report "premise: the list outgrows one 4 KiB pipe block ($label: $n bytes)" pass \
                    || report "premise: the list outgrows one 4 KiB pipe block ($label: $n bytes)" fail
done

# $1 = a row: does it carry the git badge ‹$2› AND the Rust type badge?
badged() {
  case "$1" in *"‹$2›"*) ;; *) return 1 ;; esac
  case "$1" in *Rust*) return 0 ;; esac
  return 1
}

for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)

  LIST_ENV=""   # control: the real mount table, where all of $TMPD is local
  got=$(row "$r" "D:$TMPD/nas/proj")
  badged "$got" nasbranch && report "$label control: a local dir row carries its git and type badges" pass \
                          || report "$label control: a local dir row carries its git and type badges (got: $got)" fail
  got=$(row "$r" "D:$TMPD/nas/gone")
  [ -z "$got" ] && report "$label control: a recent dir that does not exist is not offered" pass \
                || report "$label control: a recent dir that does not exist is not offered (got: $got)" fail

  LIST_ENV="INTERDIMUX_MOUNTINFO=$MI"
  got=$(row "$r" "D:$TMPD/nas/proj")
  if [ -n "$got" ] && ! printf '%s' "$got" | grep -q -e '‹' -e 'Rust'; then
    report "$label: a dir row on an NFS mount is drawn without probing it (no badges)" pass
  else
    report "$label: a dir row on an NFS mount is drawn without probing it (no badges) (got: $got)" fail
  fi
  got=$(row "$r" "D:$TMPD/nas/gone")
  [ -n "$got" ] && report "$label: a recent dir on an NFS mount is offered without an existence check" pass \
                || report "$label: a recent dir on an NFS mount is offered without an existence check" fail
  got=$(row "$r" "W:naspane:0")
  if [ -n "$got" ] && ! printf '%s' "$got" | grep -q '‹'; then
    report "$label: a pane on an NFS mount gets no git walk" pass
  else
    report "$label: a pane on an NFS mount gets no git walk (got: $got)" fail
  fi
  got=$(row "$r" "W:locpane:0")
  case "$got" in *"‹localwork›"*) report "$label: a pane on a local disk still gets its git badge" pass ;;
                 *) report "$label: a pane on a local disk still gets its git badge (got: $got)" fail ;; esac
  got=$(row "$r" "D:$TMPD/local/proj")
  badged "$got" localbranch && report "$label: a local dir row keeps its badges" pass \
                            || report "$label: a local dir row keeps its badges (got: $got)" fail
  got=$(row "$r" "D:$TMPD/vault/proj")
  badged "$got" vaultbranch && report "$label: a local-backed FUSE fs (gocryptfs) keeps its badges" pass \
                            || report "$label: a local-backed FUSE fs (gocryptfs) keeps its badges (got: $got)" fail
  got=$(row "$r" "D:$TMPD/home/proj")
  badged "$got" homebranch && report "$label: the filesystem \$HOME is on keeps its badges, NFS or not" pass \
                           || report "$label: the filesystem \$HOME is on keeps its badges, NFS or not (got: $got)" fail
done

# Both renderers classify alike: the whole list is byte-identical.
if [ -x "$BIN" ]; then
  a=$(INTERDIMUX_MOUNTINFO="$MI" INTERDIMUX_USE_RUST=on  bash "$SCRIPT" --list 2>/dev/null)
  b=$(INTERDIMUX_MOUNTINFO="$MI" INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ] && report "both renderers draw the same list under the mount table" pass \
                                 || report "both renderers draw the same list under the mount table" fail
fi

# The ctrl-o picker: the same rows, through load_recent_dirs / detect_project_type.
dl=$(INTERDIMUX_MOUNTINFO="$MI" bash "$SCRIPT" --dirs-list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
nas=$(printf '%s\n' "$dl" | awk -F'\t' -v d="$TMPD/nas/proj" '$3 == d')
loc=$(printf '%s\n' "$dl" | awk -F'\t' -v d="$TMPD/local/proj" '$3 == d')
if [ -n "$nas" ] && [ "$(printf '%s' "$nas" | cut -f2)" = "" ] && [ "$(printf '%s' "$loc" | cut -f2)" = "Rust" ]; then
  report "--dirs-list: no type probe on the NFS row, the local one is typed" pass
else
  report "--dirs-list: no type probe on the NFS row, the local one is typed (nas: $nas / local: $loc)" fail
fi

# $HOME is a symlink onto an NFS mount (review #25).  The exemption went to the
# mount covering the literal $HOME string -- the local root here -- so the NFS
# mount the panes are really on stayed skipped and every pane in the home lost
# its badge.
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  LIST_ENV="INTERDIMUX_MOUNTINFO=$MI HOME=$TMPD/linkhome"
  got=$(row "$r" "W:gpane:0")
  case "$got" in *"‹gpfsproj›"*) report "$label: a pane in a \$HOME that is a symlink onto NFS keeps its git badge" pass ;;
                 *) report "$label: a pane in a \$HOME that is a symlink onto NFS keeps its git badge (got: $got)" fail ;; esac
  got=$(row "$r" "D:$TMPD/gpfs/u/other")
  badged "$got" gpfsother && report "$label: a recent dir there keeps its git and type badges" pass \
                          || report "$label: a recent dir there keeps its git and type badges (got: $got)" fail
  got=$(row "$r" "D:$TMPD/nas/proj")
  if [ -n "$got" ] && ! printf '%s' "$got" | grep -q -e '‹' -e 'Rust'; then
    report "$label: ... and another NFS mount is still skipped" pass
  else
    report "$label: ... and another NFS mount is still skipped (got: $got)" fail
  fi
done
dl=$(HOME="$TMPD/linkhome" INTERDIMUX_MOUNTINFO="$MI" bash "$SCRIPT" --dirs-list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
got=$(printf '%s\n' "$dl" | awk -F'\t' -v d="$TMPD/gpfs/u/other" '$3 == d { print $2 }')
[ "$got" = Rust ] && report "--dirs-list: a dir in a symlinked NFS \$HOME is typed" pass \
                 || report "--dirs-list: a dir in a symlinked NFS \$HOME is typed (got: '$got')" fail

# 9p by its transport (review #27).  WSL2's Windows drives are 9p over fd
# (drvfs): the local disk, slow per stat but never a hung server -- every
# project on /mnt/c had lost its badges.  9p over tcp is a network share.
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  LIST_ENV="INTERDIMUX_MOUNTINFO=$MI"
  got=$(row "$r" "W:wslpane:0")
  case "$got" in *"‹drvfswork›"*) report "$label: a pane on WSL2's drvfs (9p over fd) keeps its git badge" pass ;;
                 *) report "$label: a pane on WSL2's drvfs (9p over fd) keeps its git badge (got: $got)" fail ;; esac
  got=$(row "$r" "D:$TMPD/wsl/c/proj")
  badged "$got" drvfsproj && report "$label: a dir row on drvfs keeps its git and type badges" pass \
                          || report "$label: a dir row on drvfs keeps its git and type badges (got: $got)" fail
  got=$(row "$r" "D:$TMPD/net9p/proj")
  if [ -n "$got" ] && ! printf '%s' "$got" | grep -q -e '‹' -e 'Rust'; then
    report "$label: a dir row on 9p over tcp is not probed" pass
  else
    report "$label: a dir row on 9p over tcp is not probed (got: $got)" fail
  fi
done

# The git walk from inside a local mount that sits in an NFS tree stops at the
# NFS level.  (The walk asks at each level only while it is below some
# blocking mount point; "is the START on one" alone would answer no here, and
# the walk would go on to probe the NFS repository above.)
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  LIST_ENV=""   # control: on the real table the walk does reach the repository
  got=$(row "$r" "W:nestpane:0")
  case "$got" in *"‹nfsrepobranch›"*) report "$label control: the walk from the nested dir reaches the repository above" pass ;;
                 *) report "$label control: the walk from the nested dir reaches the repository above (got: $got)" fail ;; esac
  LIST_ENV="INTERDIMUX_MOUNTINFO=$MI"
  got=$(row "$r" "W:nestpane:0")
  if [ -n "$got" ] && ! printf '%s' "$got" | grep -q '‹'; then
    report "$label: from a local mount inside NFS, the git walk stops at the NFS level" pass
  else
    report "$label: from a local mount inside NFS, the git walk stops at the NFS level (got: $got)" fail
  fi
  got=$(row "$r" "W:ownpane:0")
  case "$got" in *"‹ownbranch›"*) report "$label: ... and a repository inside the local mount keeps its badge" pass ;;
                 *) report "$label: ... and a repository inside the local mount keeps its badge (got: $got)" fail ;; esac
done

# A mount point's blank, tab or newline is escaped in mountinfo as \040, \011
# or \012: a backslash and EXACTLY three octal digits.  bash decoded them with
# printf %b, whose \0 takes up to three MORE, so `nas\0401` (`nas 1`) became
# `nas` and the byte 0x01, `tab\0115` became `tabM` -- mount points no path is
# ever on.  Everything under such an NFS/CIFS mount was then probed, by the bash
# renderer and by ctrl-o whatever drew the navigator; the Rust core took three
# digits and skipped it (review A05).  The fixture's escapes are the kernel's.
mkdir -p "$TMPD/data1/interdimux"
printf '%s\n' "$TMPD/nas 1/work" "$TMPD/nas 1/gone" > "$TMPD/data1/interdimux/recent_dirs"
tmux -L "$SOCK" new-session -d -s nas1pane -x 200 -y 50 -c "$TMPD/nas 1/proj" 'sleep 99999'
tmux -L "$SOCK" new-session -d -s tabpane -x 200 -y 50 -c "$TMPD/tab"$'\t'"5/proj" 'sleep 99999'
for _s in nas1pane tabpane; do
  wait_for "the $_s pane's cwd" sh -c "tmux -L '$SOCK' list-panes -t '=$_s:' -F '#{pane_current_path}' | grep -q proj"
done
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  LIST_ENV="XDG_DATA_HOME=$TMPD/data1"   # control: every one of them is probed on the real table
  got=$(row "$r" "W:nas1pane:0")
  case "$got" in *"‹nas1branch›"*) report "$label control: a pane in 'nas 1' is probed on a local disk" pass ;;
                 *) report "$label control: a pane in 'nas 1' is probed on a local disk (got: $got)" fail ;; esac
  LIST_ENV="INTERDIMUX_MOUNTINFO=$MI XDG_DATA_HOME=$TMPD/data1"
  for _s in nas1pane tabpane; do
    got=$(row "$r" "W:$_s:0")
    if [ -n "$got" ] && ! printf '%s' "$got" | grep -q '‹'; then
      report "$label: a pane on a network mount escaped as \\ooo plus a digit ($_s) gets no git walk" pass
    else
      report "$label: a pane on a network mount escaped as \\ooo plus a digit ($_s) gets no git walk (got: $got)" fail
    fi
  done
  got=$(row "$r" "D:$TMPD/nas 1/gone")
  [ -n "$got" ] && report "$label: ...a recent dir there is offered without an existence check" pass \
                || report "$label: ...a recent dir there is offered without an existence check" fail
  got=$(row "$r" "D:$TMPD/nas 1/work")
  if [ -n "$got" ] && ! printf '%s' "$got" | grep -q -e '‹' -e 'Rust'; then
    report "$label: ...and a dir row there is not probed" pass
  else
    report "$label: ...and a dir row there is not probed (got: $got)" fail
  fi
done
dl=$(XDG_DATA_HOME="$TMPD/data1" INTERDIMUX_MOUNTINFO="$MI" bash "$SCRIPT" --dirs-list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
got=$(printf '%s\n' "$dl" | awk -F'\t' -v a="$TMPD/nas 1/work" -v b="$TMPD/nas 1/gone" '$3 == a || $3 == b { printf "[%s]", $2 }')
[ "$got" = "[][]" ] && report "--dirs-list: under 'nas 1', nothing is type-probed or stat'ed" pass \
                   || report "--dirs-list: under 'nas 1', nothing is type-probed or stat'ed (got: $got)" fail

# Classified once per picker, not once per callback (review #30): the ctrl-o
# picker, and the navigator when bash draws the list, read the mount table
# before fzf starts, and every callback fzf runs inherits their answer.  Each
# parse had been 2-25 ms on every preview cursor move and every reload.
#
# The oracle is behavioural: a stand-in fzf REWRITES the table on disk -- the
# NFS line gone -- and then runs the callbacks the way fzf would, as its own
# children.  One that re-read the table would now probe the "NFS" directory
# and badge it; one that inherited the picker's answer does not.  The control
# runs the same callback outside any picker, after the rewrite.
cat /proc/self/mountinfo > "$TMPD/mi-plain"
cat > "$TMPD/fzfbin/fzf" <<FZF
#!/bin/sh
cat > /dev/null
cp "$TMPD/mi-plain" "$TMPD/mi-live"
bash "$SCRIPT" --dirs-preview "$TMPD/nas/proj" > "$TMPD/cb-preview" 2>&1
bash "$SCRIPT" --dirs-preview "$TMPD/nl
1/proj" > "$TMPD/cb-preview-nl" 2>&1
bash "$SCRIPT" --dirs-list > "$TMPD/cb-dirs" 2>&1
bash "$SCRIPT" --list > "$TMPD/cb-list" 2>&1
exit 130
FZF
chmod +x "$TMPD/fzfbin/fzf"
# (read to the end, as row() does, for the same reason)
cb_row() { sed 's/\x1b\[[0-9;]*m//g' "$TMPD/$1" 2>/dev/null | awk -F'\t' -v c="$2" -v s="$3" '!f && $c == s { print; f = 1 }'; }

cp "$MI" "$TMPD/mi-live"; rm -f "$TMPD"/cb-*
# (--dirs exits 1 on a cancel, which is what the stand-in reports)
PATH="$TMPD/fzfbin:$PATH" INTERDIMUX_MOUNTINFO="$TMPD/mi-live" XDG_RUNTIME_DIR="$TMPD/run" \
  bash "$SCRIPT" --dirs </dev/null >/dev/null 2>&1 || :
[ -s "$TMPD/cb-preview" ] && ! grep -q 'Type:' "$TMPD/cb-preview" \
  && report "ctrl-o picker: a preview classifies with the table the picker read" pass \
  || report "ctrl-o picker: a preview classifies with the table the picker read (got: $(head -5 "$TMPD/cb-preview" 2>/dev/null | tr '\n' ' '))" fail
got=$(cb_row cb-dirs 3 "$TMPD/nas/proj")
[ -n "$got" ] && [ "$(printf '%s' "$got" | cut -f2)" = "" ] \
  && report "ctrl-o picker: a reload classifies with the table the picker read" pass \
  || report "ctrl-o picker: a reload classifies with the table the picker read (got: $got)" fail
# a newline in a mount point crosses the hand-off as \012, and was decoded there
# with the same %b: `nl\0121` came back `nlQ`
[ -s "$TMPD/cb-preview-nl" ] && ! grep -q 'Type:' "$TMPD/cb-preview-nl" \
  && report "ctrl-o picker: ...a mount point with a newline and a digit in it too" pass \
  || report "ctrl-o picker: ...a mount point with a newline and a digit in it too (got: $(head -5 "$TMPD/cb-preview-nl" 2>/dev/null | tr '\n' ' '))" fail
ctl=$(INTERDIMUX_MOUNTINFO="$TMPD/mi-live" bash "$SCRIPT" --dirs-preview "$TMPD/nas/proj" 2>&1)
case "$ctl" in *"Type:"*) report "control: outside a picker, the rewritten table is what counts" pass ;;
               *) report "control: outside a picker, the rewritten table is what counts (got: $ctl)" fail ;; esac

cp "$MI" "$TMPD/mi-live"; rm -f "$TMPD"/cb-*
PATH="$TMPD/fzfbin:$PATH" INTERDIMUX_MOUNTINFO="$TMPD/mi-live" XDG_RUNTIME_DIR="$TMPD/run" \
  INTERDIMUX_USE_RUST=off bash "$SCRIPT" </dev/null >/dev/null 2>&1 || :
got=$(cb_row cb-list 4 "D:$TMPD/nas/proj")
if [ -n "$got" ] && ! printf '%s' "$got" | grep -q -e '‹' -e 'Rust'; then
  report "navigator (bash renderer): a --list reload classifies with the table the navigator read" pass
else
  report "navigator (bash renderer): a --list reload classifies with the table the navigator read (got: $got)" fail
fi
[ -s "$TMPD/cb-preview" ] && ! grep -q 'Type:' "$TMPD/cb-preview" \
  && report "navigator (bash renderer): so does a directory row's preview" pass \
  || report "navigator (bash renderer): so does a directory row's preview (got: $(head -5 "$TMPD/cb-preview" 2>/dev/null | tr '\n' ' '))" fail

# ...and when the Rust core draws the navigator's list (review B08).  bash does
# not classify up front there -- it would put a parse before the first frame --
# so a directory row's preview, and Enter on a directory row, each parsed the
# table again.  The core, which reads it anyway, now leaves its answer in a file
# the navigator names.  Same oracle: the table on disk loses its NFS line once
# the list is drawn.  The preview must not probe the "NFS" directory, and
# Enter's rewrite of the recent list must keep the entry there that does not
# exist -- a stat it skipped, where one that re-read the table prunes it.
if [ -x "$BIN" ]; then
  mkdir -p "$TMPD/fzfnav"
  cat > "$TMPD/fzfnav/fzf" <<FZF
#!/bin/sh
cat > /dev/null
if [ -n "\${INTERDIMUX_MOUNTS_FILE:-}" ]; then cp "\$INTERDIMUX_MOUNTS_FILE" "$TMPD/cb-handoff"
else printf '%s' "\${INTERDIMUX_MOUNTS-unset}" > "$TMPD/cb-handoff"; fi
cp "$TMPD/mi-plain" "$TMPD/mi-live"
bash "$SCRIPT" --preview "D:$TMPD/nas/proj" > "$TMPD/cb-navpreview" 2>&1
printf '\n%s\n' "x	x	x	D:$TMPD/local/work"
exit 0
FZF
  chmod +x "$TMPD/fzfnav/fzf"
  cp "$TMPD/data/interdimux/recent_dirs" "$TMPD/recent.saved"
  for r in on off; do
    cp "$MI" "$TMPD/mi-live"; rm -f "$TMPD"/cb-*
    cp "$TMPD/recent.saved" "$TMPD/data/interdimux/recent_dirs"
    PATH="$TMPD/fzfnav:$PATH" INTERDIMUX_MOUNTINFO="$TMPD/mi-live" XDG_RUNTIME_DIR="$TMPD/run" \
      INTERDIMUX_USE_RUST="$r" bash "$SCRIPT" </dev/null >/dev/null 2>&1 || :
    label=$([ "$r" = on ] && echo "Rust core" || echo "bash renderer")
    grep -v '^$' "$TMPD/cb-handoff" 2>/dev/null | LC_ALL=C sort > "$TMPD/handoff.$r" || :
    [ -s "$TMPD/cb-navpreview" ] && ! grep -q 'Type:' "$TMPD/cb-navpreview" \
      && report "navigator ($label): a directory row's preview classifies with the table the list was drawn with" pass \
      || report "navigator ($label): a directory row's preview classifies with the table the list was drawn with (got: $(head -5 "$TMPD/cb-navpreview" 2>/dev/null | tr '\n' ' '))" fail
    if head -1 "$TMPD/data/interdimux/recent_dirs" | grep -qxF "$TMPD/local/work" \
       && grep -qxF "$TMPD/nas/gone" "$TMPD/data/interdimux/recent_dirs"; then
      report "navigator ($label): Enter on a directory row stats nothing on the mount the list skipped" pass
    else
      report "navigator ($label): Enter on a directory row stats nothing on the mount the list skipped (recent: $(tr '\n' ' ' < "$TMPD/data/interdimux/recent_dirs"))" fail
    fi
  done
  # the core's classification is bash's own, line for line (as sets: each is
  # written in its map's order): the blocking points, and a local mount in one
  if [ -s "$TMPD/handoff.on" ] && cmp -s "$TMPD/handoff.on" "$TMPD/handoff.off"; then
    report "the core hands over the same classification bash exports ($(wc -l < "$TMPD/handoff.on") mount points)" pass
  else
    report "the core hands over the same classification bash exports" fail
    ERRORS+="$(diff "$TMPD/handoff.off" "$TMPD/handoff.on" | head -6 || true)"$'\n'
  fi
  ls "$TMPD/run"/interdimux-resume.* >/dev/null 2>&1 \
    && report "the navigator leaves no scratch file behind (the mounts file included)" fail \
    || report "the navigator leaves no scratch file behind (the mounts file included)" pass
  cp "$TMPD/recent.saved" "$TMPD/data/interdimux/recent_dirs"

  # The file is named after the navigator's PID, so the one a SIGKILLed
  # navigator left is met again only once that PID is reused -- and the core
  # must not start out with it.  rm runs only when a builtin test finds
  # something there (an exec on the way to the first frame, review PERF-19),
  # and a dangling symlink is something too.  The probe is a stand-in core that
  # looks before it runs the real one (nothing writes the file before the core
  # does); a shell that knows its PID plants the leftover and execs the
  # navigator, which keeps that PID.  The stand-in fzf cancels.
  mkdir -p "$TMPD/fzfcancel"
  printf '#!/bin/sh\ncat > /dev/null\nexit 130\n' > "$TMPD/fzfcancel/fzf"
  printf '#!/bin/sh\nif [ -e "$INTERDIMUX_MOUNTS_FILE" ] || [ -L "$INTERDIMUX_MOUNTS_FILE" ]; then s=left; else s=gone; fi\necho "$s $INTERDIMUX_MOUNTS_FILE" >> "%s/core-saw"\nexec "%s" "$@"\n' \
    "$TMPD" "$BIN" > "$TMPD/core-probe"
  chmod +x "$TMPD/fzfcancel/fzf" "$TMPD/core-probe"
  for kind in file symlink; do
    rm -f "$TMPD/core-saw" "$TMPD/planted"
    PATH="$TMPD/fzfcancel:$PATH" INTERDIMUX_MOUNTINFO="$MI" XDG_RUNTIME_DIR="$TMPD/run" \
      INTERDIMUX_USE_RUST=on INTERDIMUX_BIN="$TMPD/core-probe" bash -c '
        m="$XDG_RUNTIME_DIR/interdimux-resume.$$.mounts"
        case "$1" in
          file) printf "%s\n" "/ 1" > "$m" ;;
          *)    ln -s "$XDG_RUNTIME_DIR/nowhere" "$m" ;;
        esac
        printf "%s" "$m" > "$2/planted"
        exec bash "$3"' _ "$kind" "$TMPD" "$SCRIPT" </dev/null >/dev/null 2>&1 || :
    got=$(head -1 "$TMPD/core-saw" 2>/dev/null || true)
    if [ -s "$TMPD/planted" ] && [ "$got" = "gone $(cat "$TMPD/planted")" ]; then
      report "navigator (Rust core): a mounts file left by a navigator with its PID is gone before the list ($kind)" pass
    else
      report "navigator (Rust core): a mounts file left by a navigator with its PID is gone before the list ($kind; got: ${got:-no list})" fail
    fi
  done
  rm -f "$TMPD"/run/interdimux-resume.*
fi

# zoxide stats every entry of its database unless told --all; a zoxide that
# does not know the flag still gets asked the plain way.
printf '#!/bin/sh\necho "$*" >> "%s/zargs"\nprintf "%%s\\n" "%s/local/zdir"\n' "$TMPD" "$TMPD" > "$TMPD/bin/zoxide"
chmod +x "$TMPD/bin/zoxide"
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  rm -f "$TMPD/zargs"
  PATH="$TMPD/bin:$PATH" INTERDIMUX_USE_ZOXIDE=on INTERDIMUX_USE_RUST="$r" bash "$SCRIPT" --list >/dev/null 2>&1
  case "$(cat "$TMPD/zargs" 2>/dev/null)" in
    *"--list --all"*) report "$label: zoxide is queried with --all (it stats nothing)" pass ;;
    *) report "$label: zoxide is queried with --all (got: $(cat "$TMPD/zargs" 2>/dev/null))" fail ;;
  esac
done
printf '#!/bin/sh\ncase "$*" in *--all*) exit 2 ;; esac\nprintf "%%s\\n" "%s/local/zdir"\n' "$TMPD" > "$TMPD/bin/zoxide"
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  got=$(PATH="$TMPD/bin:$PATH" INTERDIMUX_USE_ZOXIDE=on INTERDIMUX_USE_RUST="$r" bash "$SCRIPT" --list 2>/dev/null | cut -f4)
  case "$got" in *"D:$TMPD/local/zdir"*) report "$label: a zoxide without --all still contributes its dirs" pass ;;
                 *) report "$label: a zoxide without --all still contributes its dirs" fail ;; esac
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
