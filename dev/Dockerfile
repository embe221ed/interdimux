# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# (BASE_IMAGE has no default on purpose: dev/versions.env is its only copy,
# and the check above is the warning that would otherwise say so.)
#
# The dev and test image: CI's runner, as a container, with every tool the 83
# suites ask for, so a strict run (IMUX_STRICT=1) skips nothing.  docs/DEVENV.md
# says how to use it; build it through dev/run.sh (`make image`), which passes
# every pin in dev/versions.env as a build argument, so no version is written
# down here.
#
# One Dockerfile for both architectures: linux/amd64 (this VPS, CI, and Docker
# on an Intel Mac) and linux/arm64 (Docker on an Apple Silicon Mac).
#
# Each build stage copies only its own installer and checksums, so moving one
# pin rebuilds that stage and the final one, nothing else.  The repository
# itself is NOT copied in: dev/run.sh mounts it read-only at run time.

ARG BASE_IMAGE

# --- what every stage has -----------------------------------------------------
FROM ${BASE_IMAGE} AS base
ENV DEBIAN_FRONTEND=noninteractive
# The archive's current noble packages, as CI's runner gets them: unpinned.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

FROM base AS build
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential autotools-dev \
      libevent-dev libncurses-dev bison pkg-config ncurses-base \
 && rm -rf /var/lib/apt/lists/*
COPY dev/install/lib.sh /dev-src/install/

# --- tmux, from source --------------------------------------------------------
FROM build AS tmux
ARG TMUX_VERSION
COPY dev/install/tmux.sh /dev-src/install/
COPY dev/checksums/tmux.sha256 /dev-src/checksums/
RUN bash /dev-src/install/tmux.sh /opt/tmux

# --- the old bashes test_bash_floor.sh runs -----------------------------------
FROM build AS bash-old
ARG OLD_BASH_VERSIONS
COPY dev/install/bash-old.sh /dev-src/install/
COPY dev/checksums/bash-old.sha256 /dev-src/checksums/
RUN bash /dev-src/install/bash-old.sh /opt/bash-old

# --- release binaries ---------------------------------------------------------
FROM base AS binaries
COPY dev/install/lib.sh /dev-src/install/
ARG FZF_VERSION
COPY dev/install/fzf.sh /dev-src/install/
COPY dev/checksums/fzf.sha256 /dev-src/checksums/
RUN bash /dev-src/install/fzf.sh /opt/bin
ARG OLD_FZF_VERSIONS
COPY dev/install/fzf-old.sh /dev-src/install/
COPY dev/checksums/fzf-old.sha256 /dev-src/checksums/
RUN bash /dev-src/install/fzf-old.sh /opt/fzf-old
ARG SHELLCHECK_VERSION
COPY dev/install/shellcheck.sh /dev-src/install/
COPY dev/checksums/shellcheck.sha256 /dev-src/checksums/
RUN bash /dev-src/install/shellcheck.sh /opt/bin
ARG ACTIONLINT_VERSION HADOLINT_VERSION LYCHEE_VERSION
COPY dev/install/linters.sh /dev-src/install/
COPY dev/checksums/actionlint.sha256 dev/checksums/hadolint.sha256 dev/checksums/lychee.sha256 /dev-src/checksums/
RUN bash /dev-src/install/linters.sh /opt/bin

# --- Rust: the pinned toolchain, the MSRV, and the crates, fetched ------------
FROM base AS rust
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ARG RUST_VERSION RUSTUP_INIT_VERSION
COPY dev/install/lib.sh dev/install/rust.sh /dev-src/install/
COPY dev/checksums/rustup.sha256 /dev-src/checksums/
COPY rust/Cargo.toml rust/Cargo.lock /crate/
RUN mkdir -p /crate/src && echo 'fn main() {}' > /crate/src/main.rs \
 && bash /dev-src/install/rust.sh /crate/Cargo.toml

# --- the image ----------------------------------------------------------------
FROM base AS dev
# What the suites run, and what the CI job installs on top of its runner image
# (ci.yml "Install dependencies"), plus what the runner has that the bare
# ubuntu image lacks (procps, git, zsh, python3, ...):
#   at          the Schedule/Jobs suites skip without at and atq
#   gawk        made THE awk below: mawk counts bytes, not cells
#   locales     en_US.UTF-8 below: the parity suite needs a second locale whose
#               collation differs from C's
#   strace      read/exec counts (render_cost, gather_batch, git_probe, dirs_list)
#   zsh         `zsh -f` and --with-shell='zsh -c' cases
#   build-essential  cargo's linker
#   ncurses-term     terminfo for an interactive shell's client
#   entr moreutils rsync jq tini  the dev loop (dev/cmd.sh) and PID 1
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      at bash coreutils dash diffutils fd-find findutils gawk git grep jq \
      libevent-core-2.1-7t64 locales mawk ncurses-base ncurses-bin ncurses-term \
      perl procps psmisc python3 sed strace tzdata util-linux zsh \
      build-essential entr less make moreutils rsync tini \
 && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8 \
 && update-alternatives --set awk /usr/bin/gawk \
 && userdel -r ubuntu \
 && useradd -m -u 1000 -s /bin/bash dev \
 && mkdir -p /work \
 && chown dev:dev /work

COPY --from=tmux /opt/tmux/ /usr/local/
COPY --from=binaries /opt/bin/ /usr/local/bin/
COPY --from=binaries /opt/fzf-old/ /opt/fzf-old/
COPY --from=bash-old /opt/bash-old/ /opt/bash-old/
COPY --from=rust --chown=dev:dev /usr/local/rustup/ /usr/local/rustup/
COPY --from=rust --chown=dev:dev /usr/local/cargo/ /usr/local/cargo/

# Only these INTERDIMUX_* may be set image-wide: test_bind_keys counts every
# other one that reaches a popup, and the suites' tmux servers inherit this
# environment.  INTERDIMUX_TEST_DOCKER=off as in CI: there is no docker here.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    INTERDIMUX_OLD_FZF_DIR=/opt/fzf-old \
    INTERDIMUX_OLD_BASH_DIR=/opt/bash-old \
    INTERDIMUX_TEST_DOCKER=off \
    RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo CARGO_NET_OFFLINE=true \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY dev/entrypoint.sh dev/cmd.sh /usr/local/lib/imux-dev/
WORKDIR /work
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/lib/imux-dev/entrypoint.sh"]
CMD ["shell"]
