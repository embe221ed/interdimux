# The dev environment (docs/DEVENV.md): every target runs dev/run.sh, which
# builds the dev image when dev/ changed and runs the command in a container.
# GNU make 3.81 or newer -- macOS's own make is fine.
#
#   make test [T='raw sched'] [R=rust|bash]  the suites (those whose names match T)
#   make smoke                 tests/smoke.sh: what CI runs on real Macs
#   make ci [R=rust|bash]      CI's tests job: both renderer legs, strict
#   make ci-sigpipe [R=...]    the same with SIGPIPE ignored, as on GitHub
#   make versions              every pinned tool, present and at its pin
#   make lint                  shellcheck, actionlint, hadolint, lychee
#   make check-macos           type-check the Rust core for both macOS targets
#   make msrv                  build and test the Rust core on its rust-version
#   make bench [ARGS='-n 10 HEAD~1']   tests/bench.sh
#   make perfbench [REF=main] [ARGS='-n 10 -s list,footer']
#                              dev/perf/bench.sh: is this checkout slower than REF?
#   make uxdiff [REF=main] [ARGS=-q]   dev/perf/uxdiff.sh: does it look different?
#   make watch [T=...]         re-run suites whenever a file changes
#   make shell                 a shell in the container
#   make image                 (re)build the image
#   make pin                   after editing dev/versions.env: record checksums
#   make clean                 remove the dev images, and this checkout's volumes
#   make clean-volumes         remove the volumes of checkouts that are gone
#
#   PLATFORM=linux/arm64       the Apple Silicon image (emulated off one)
#   CPUSET=2-3                 pin the container to those CPUs
#   LOCK=/tmp/imux-perf.lock   take turns with every run naming the same file

# Given on the command line or exported as dev/run.sh's own IMUX_* names.
PLATFORM ?= $(IMUX_PLATFORM)
R ?= $(IMUX_RENDERER)
CPUSET ?= $(IMUX_CPUSET)
LOCK ?= $(IMUX_LOCK)
REF ?= main
RUN = IMUX_PLATFORM='$(PLATFORM)' IMUX_RENDERER='$(R)' IMUX_CPUSET='$(CPUSET)' IMUX_LOCK='$(LOCK)' sh dev/run.sh

.PHONY: help test smoke ci ci-sigpipe versions lint check-macos msrv bench perfbench uxdiff watch shell image pin clean clean-volumes

help:
	@sed -n 's/^#   //p' Makefile

test:
	@$(RUN) test $(T)
smoke:
	@$(RUN) smoke
ci:
	@$(RUN) ci
ci-sigpipe:
	@$(RUN) ci-sigpipe
versions:
	@$(RUN) versions
lint:
	@$(RUN) lint
check-macos:
	@$(RUN) check-macos
msrv:
	@$(RUN) msrv
bench:
	@$(RUN) bench $(ARGS)
perfbench:
	@$(RUN) perfbench '$(REF)' $(ARGS)
uxdiff:
	@$(RUN) uxdiff '$(REF)' $(ARGS)
watch:
	@$(RUN) watch $(T)
shell:
	@$(RUN) shell
image:
	@$(RUN) image
pin:
	@$(RUN) pin
clean:
	@$(RUN) clean
clean-volumes:
	@$(RUN) clean-volumes
