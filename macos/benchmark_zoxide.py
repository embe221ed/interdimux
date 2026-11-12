#!/usr/bin/env python3
"""Measure lazy project loading with private Rex/zoxide shims and synthetic paths.

This is a headless protocol benchmark, not an AppKit or real Rex benchmark.
It never calls the installed Rex/zoxide commands, creates project sessions, or
modifies the user's database. Only its temporary fixtures are written.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

from benchmark import MACOS, Protocol, stop_owned, summary


CONTEXT = {"client_id": "client:benchmark", "session_id": "session:benchmark",
           "window_id": "window:benchmark", "block_id": "block:benchmark"}
CACHED_QUERIES = ["'retained-project-24", "'BenchmarkSession"]


def query_fields(query):
    return {"query": query, "scope": "all", "search_field": "all", "allow_create": False}


class Case:
    def __init__(self, helper, size, mode):
        self.directory = tempfile.TemporaryDirectory(prefix="imux-zoxide-benchmark-")
        self.root = Path(self.directory.name).resolve()
        self.process = None
        self.errors = None
        for name in ("home", "data/interdimux", "empty-root"):
            (self.root / name).mkdir(parents=True)
        history = "".join(f"/benchmark/retained/retained-project-{index:02}\n" for index in range(25))
        (self.root / "data/interdimux/recent_dirs").write_text(history)
        inventory = "".join(f"/benchmark/zoxide/zoxide-project-{index:05}\n" for index in range(size))
        (self.root / "zoxide-output").write_text(inventory)
        snapshot = {"version": 1, "host_id": "local", "local_host_id": "local",
                    "sessions": [{"session_id": "session:benchmark", "label": "BenchmarkSession"}],
                    "views": {"session:benchmark": {"active_window_id": "window:benchmark", "windows": [{
                        "window_id": "window:benchmark", "label": "Terminal", "focused_block_id": "block:benchmark",
                        "layers": [{"blocks": [{"block_id": "block:benchmark",
                                                   "creator_name": "com.superlogical.terminal", "host_id": "local"}]}]}]}},
                    "metadata": {"block:benchmark": {"foreground": {"name": "sh", "cwd": "/benchmark/current"}}}}
        envelope = {"clients": {"clients": [{"client_id": "client:benchmark",
                    "info": {"kind": "app", "platform": "macos"},
                    "principal": {"kind": "peer", "transport": "unix"}}]}, "snapshot": snapshot}
        (self.root / "snapshot.json").write_text(json.dumps(envelope))
        rex = self.root / "rex"
        rex.write_text('''#!/bin/sh
source=$(/bin/cat)
case "$source" in *"local clients="*) ;; *) exit 2 ;; esac
case "$source" in *"local snapshot="*) ;; *) exit 2 ;; esac
printf 'snapshot\\n' >> "$IMUX_BENCHMARK_ROOT/rex-calls"
exec /bin/cat "$IMUX_BENCHMARK_ROOT/snapshot.json"
''')
        zoxide = self.root / "zoxide"
        zoxide.write_text('''#!/bin/sh
if [ "$#" -ne 3 ] || [ "$1" != query ] || [ "$2" != --list ] || [ "$3" != --all ]; then exit 2; fi
printf 'list\\n' >> "$IMUX_BENCHMARK_ROOT/zoxide-calls"
printf '%s\\n' "$$" >> "$IMUX_BENCHMARK_ROOT/zoxide-pids"
if [ "$IMUX_BENCHMARK_MODE" = stall ]; then exec /bin/sleep 30; fi
exec /bin/cat "$IMUX_BENCHMARK_ROOT/zoxide-output"
''')
        rex.chmod(0o700)
        zoxide.chmod(0o700)
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(self.root / "home"),
                       "XDG_DATA_HOME": str(self.root / "data"), "XDG_STATE_HOME": str(self.root / "state"),
                       "XDG_CONFIG_HOME": str(self.root / "config"), "INTERDIMUX_REX_BIN": str(rex),
                       "INTERDIMUX_ZOXIDE_BIN": str(zoxide), "INTERDIMUX_USE_ZOXIDE": "on",
                       "INTERDIMUX_SHOW_DIRS": "on", "INTERDIMUX_DIRS_LIMIT": "15",
                       "INTERDIMUX_PROJECT_DIRS": str(self.root / "empty-root"), "INTERDIMUX_HYDRATE": "off",
                       "IMUX_BENCHMARK_ROOT": str(self.root), "IMUX_BENCHMARK_MODE": mode}
        # Newly written scripts can incur macOS first-execution checks longer
        # than the intentionally short production budget. Warm only the owned
        # shims before measurement, then clear their logs.
        warm = dict(environment, IMUX_BENCHMARK_MODE="success")
        subprocess.run([str(zoxide), "query", "--list", "--all"], env=warm,
                       stdout=subprocess.DEVNULL, check=True, timeout=5)
        subprocess.run([str(rex)], input=b"local clients=\nlocal snapshot=\n", env=warm,
                       stdout=subprocess.DEVNULL, check=True, timeout=5)
        for name in ("zoxide-calls", "zoxide-pids", "rex-calls"):
            (self.root / name).unlink(missing_ok=True)
        self.errors = (self.root / "helper.stderr").open("wb")
        started = time.perf_counter()
        try:
            self.process = subprocess.Popen([str(helper), "macos-serve"], env=environment,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=self.errors, bufsize=0, start_new_session=True)
            self.protocol = Protocol(self.process)
            opened, self.open_ms = self.protocol.request("open", context=CONTEXT)
            self.start_to_results_ms = (time.perf_counter() - started) * 1000
            if self.calls("zoxide") or len([row for row in opened["rows"] if row["kind"] == "directory"]) != 15:
                raise RuntimeError("Initial open eagerly loaded zoxide or changed the suggestion cap")
        except Exception:
            self.close()
            raise

    def calls(self, command):
        path = self.root / f"{command}-calls"
        return len(path.read_text().splitlines()) if path.exists() else 0

    def close(self):
        if self.process is not None:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                stop_owned(self.process)
            self.process.stdout.close()
        # Optional children have their own process groups. Normal shutdown
        # reaps them; clean up the owned group too if a benchmark assertion fails.
        pid_file = self.root / "zoxide-pids"
        if pid_file.exists():
            for value in pid_file.read_text().splitlines():
                try:
                    os.killpg(int(value), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if self.errors is not None:
            self.errors.close()
        self.directory.cleanup()


def measured_queries(case, queries, count):
    samples, service = [], []
    for index in range(count + 10):
        response, elapsed = case.protocol.request("query", **query_fields(queries[index % len(queries)]))
        if response["matched"] == 0:
            raise RuntimeError("A synthetic cached query unexpectedly missed")
        if index >= 10:
            samples.append(elapsed)
            service.append(response["elapsed_ms"])
    return {"round_trip": summary(samples), "helper": summary(service), "samples_ms": samples}


def successful_round(helper, size, query_count, poll_ms):
    case = Case(helper, size, "success")
    try:
        before = measured_queries(case, CACHED_QUERIES, query_count)
        if case.calls("zoxide"):
            raise RuntimeError("Cached hits started optional loading")
        target = f"'zoxide-project-{size - 1:05}"
        missed, _ = case.protocol.request("query", **query_fields(target))
        if not missed.get("projects_needed") or case.calls("zoxide"):
            raise RuntimeError("Miss did not preserve the lazy loading boundary")
        started = time.perf_counter()
        loading, dispatch_ms = case.protocol.request("load_projects", **query_fields(target))
        response = loading
        deadline = time.monotonic() + 5
        while response.get("projects_loading"):
            if time.monotonic() > deadline:
                raise RuntimeError("Optional inventory did not complete")
            time.sleep(poll_ms / 1000)
            response, _ = case.protocol.request("query", **query_fields(target))
        load_ms = (time.perf_counter() - started) * 1000
        if response["matched"] != 1 or case.calls("zoxide") != 1:
            raise RuntimeError("Full low-ranked synthetic inventory was not cached exactly once")
        after = measured_queries(case, CACHED_QUERIES, query_count)
        projects = measured_queries(case, [target, f"zxdprj{size - 1:05}", "zoxide-project"], query_count)
        if case.calls("zoxide") != 1 or case.calls("rex") != 1:
            raise RuntimeError("Cached queries unexpectedly repeated external work")
        reopened, reopen_ms = case.protocol.request("open", context=CONTEXT)
        cached, _ = case.protocol.request("query", **query_fields(target))
        if cached["matched"] != 1 or case.calls("zoxide") != 1 or case.calls("rex") != 2:
            raise RuntimeError("Reopening discarded or reloaded the completed inventory")
        if len([row for row in reopened["rows"] if row["kind"] == "directory"]) != 15:
            raise RuntimeError("Reopening expanded blank-query suggestions")
        return {"open_round_trip_ms": case.open_ms, "process_start_to_results_ms": case.start_to_results_ms,
                "zoxide_calls_on_open": 0, "cached_hit_before_inventory": before,
                "load_dispatch_ms": dispatch_ms, "load_to_first_match_ms": load_ms,
                "cached_hit_after_inventory": after, "inventory_search": projects,
                "reopen_with_cached_inventory_ms": reopen_ms,
                "final_zoxide_calls": 1, "final_rex_calls": 2}
    finally:
        case.close()


def stalled_round(helper, query_count):
    case = Case(helper, 446, "stall")
    try:
        started = time.perf_counter()
        response, dispatch_ms = case.protocol.request("load_projects", **query_fields("unmatched-zoxide-project"))
        samples, service = [], []
        deadline = time.monotonic() + 3
        while response.get("projects_loading"):
            if time.monotonic() > deadline:
                raise RuntimeError("Stalled optional worker retained loading indefinitely")
            hit, elapsed = case.protocol.request("query", **query_fields(CACHED_QUERIES[len(samples) % 2]))
            if hit["matched"] == 0:
                raise RuntimeError("Optional stall hid a cached result")
            samples.append(elapsed)
            service.append(hit["elapsed_ms"])
            response, _ = case.protocol.request("query", **query_fields("unmatched-zoxide-project"))
            if response.get("projects_loading"):
                time.sleep(0.002)
        elapsed_ms = (time.perf_counter() - started) * 1000
        if case.calls("zoxide") != 1 or response.get("projects_needed") or not samples:
            raise RuntimeError("Stalled inventory retried, did not run, or blocked all cached queries")
        if case.root.joinpath("zoxide-pids").exists():
            for value in case.root.joinpath("zoxide-pids").read_text().splitlines():
                try:
                    os.kill(int(value), 0)
                except ProcessLookupError:
                    continue
                raise RuntimeError("Timed-out optional child was not reaped")
        after = measured_queries(case, CACHED_QUERIES, query_count)
        return {"dispatch_ms": dispatch_ms, "load_until_failure_observed_ms": elapsed_ms,
                "cached_hits_during_stall": {"round_trip": summary(samples), "helper": summary(service),
                                            "samples_ms": samples}, "cached_hits_after_stall": after,
                "final_zoxide_calls": case.calls("zoxide")}
    finally:
        case.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, default=MACOS.parent / "rust/target/release/imux")
    parser.add_argument("--output", type=Path, default=MACOS / "build/zoxide-performance.json")
    parser.add_argument("--sizes", type=int, nargs="+", default=[446, 5000])
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--queries", type=int, default=120)
    parser.add_argument("--poll-ms", type=float, default=5)
    parser.add_argument("--label", default="current")
    args = parser.parse_args()
    if any(size < 1 or size > 15000 for size in args.sizes) or args.rounds < 1 or args.queries < 10 or args.poll_ms <= 0:
        parser.error("sizes must be 1–15000, rounds positive, queries at least 10, poll-ms positive")
    helper = args.helper.resolve()
    if not helper.is_file():
        parser.error("Helper is missing; build the release helper with macos-picker first")
    report = {"label": args.label, "platform": platform.platform(),
              "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "measurement": "Python serialization/JSON decoding, pipe round trip, release Rust matching and owned synthetic shims; no real Rex, real zoxide database, AppKit, rendering, or UI debounce",
              "poll_interval_ms": args.poll_ms, "warmup_queries_per_phase": 10,
              "queries_per_phase": args.queries, "search_field": "all", "corpora": [], "stalled_worker": []}
    for size in args.sizes:
        rounds = [successful_round(helper, size, args.queries, args.poll_ms) for _ in range(args.rounds)]
        report["corpora"].append({"inventory_entries": size, "rounds": rounds})
        print(json.dumps({"entries": size,
                          "cached_hit_before_ms": [run["cached_hit_before_inventory"]["round_trip"] for run in rounds],
                          "cached_hit_after_ms": [run["cached_hit_after_inventory"]["round_trip"] for run in rounds],
                          "load_to_match_ms": [run["load_to_first_match_ms"] for run in rounds]}), flush=True)
    report["stalled_worker"] = [stalled_round(helper, args.queries) for _ in range(args.rounds)]
    if hashlib.sha256(helper.read_bytes()).hexdigest() != report["helper_sha256"]:
        raise RuntimeError("Helper changed during measurement; rerun after the build finishes")
    print(json.dumps({"stalled_worker": [
        {"dispatch_ms": run["dispatch_ms"], "observed_failure_ms": run["load_until_failure_observed_ms"],
         "cached_hit_round_trip": run["cached_hits_during_stall"]["round_trip"]}
        for run in report["stalled_worker"]]}), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {args.output}")


if __name__ == "__main__":
    main()
