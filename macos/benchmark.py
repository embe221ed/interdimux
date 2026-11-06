#!/usr/bin/env python3
"""Benchmark synthetic picker fixtures; native windows require explicit --ui.

The default run uses only the helper's JSON-lines protocol. Both paths always
pass --fixture, so no Rex collection or real target activation is possible.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import select
import signal
import statistics
import subprocess
import time


QUERIES = ["", "a", "ag", "agent", "src", "project", "zz-no-matches", "", "window", "pane", "λ", "東京"]
MACOS = Path(__file__).resolve().parent


def fixture_rows(size):
    rows = []
    session_id = window_id = None
    for index in range(size):
        # Each contiguous 20-row project has one session, four windows, and
        # fifteen panes. Preserve the corpus and search text while giving the
        # native tree real ancestors instead of unrelated flat fixture rows.
        kind = "session" if index % 20 == 0 else "window" if index % 5 == 1 else "pane"
        row_id = f"fixture:{kind}:{index}"
        if kind == "session":
            parent_id = None
            session_id, window_id = row_id, None
        elif kind == "window":
            parent_id = session_id
            window_id = row_id
        else:
            parent_id = window_id
        title = {"session": "project", "window": "window", "pane": "agent pane"}[kind] + f"-{index:05d}"
        if index % 4 == 0:
            title += " · 東京 λ 🧑🏽‍💻"
        if index % 9 == 0:
            title += " · a long descriptive workspace name with the distinguishing suffix"
        rows.append({
            "id": row_id, "parent_id": parent_id, "kind": kind, "title": title,
            "subtitle": f"project-{index // 20:04d} · window-{index // 5:04d} · codex --model development",
            "path": f"/Users/fixture/projects/workspace-{index // 20:04d}/packages/long-component-name/src/module-{index:05d}",
            "current": index == 0,
        })
    return rows


def summary(samples):
    ordered = sorted(samples)
    return {"median_ms": statistics.median(ordered),
            "p95_ms": ordered[max(0, math.ceil(len(ordered) * .95) - 1)],
            "sample_count": len(ordered)}


def stop_owned(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait(timeout=3)
            return
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)


class Protocol:
    def __init__(self, process):
        self.process = process
        self.buffer = bytearray()
        self.serial = 0

    def request(self, operation, **fields):
        self.serial += 1
        started = time.perf_counter()
        self.process.stdin.write((json.dumps(dict(fields, type=operation, id=self.serial), ensure_ascii=False) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 10
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError(f"Helper timed out handling {operation}")
            part = os.read(self.process.stdout.fileno(), 65536)
            if not part:
                raise RuntimeError(f"Helper closed stdout handling {operation}; inspect its stderr log")
            self.buffer.extend(part)
            if len(self.buffer) > 8 * 1024 * 1024:
                raise RuntimeError("Helper response exceeded 8 MiB")
        line, _, remaining = self.buffer.partition(b"\n")
        self.buffer = bytearray(remaining)
        response = json.loads(line)
        elapsed = (time.perf_counter() - started) * 1000
        if response.get("id") != self.serial:
            raise RuntimeError(f"Wrong response ID: {response!r}")
        if operation != "activate" and response.get("type") != "results":
            raise RuntimeError(f"Helper request failed: {response!r}")
        return response, elapsed


def helper_benchmark(helper, fixture, output, rounds):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("REX_")}
    environment["INTERDIMUX_REX_BIN"] = "/nonexistent/fixture-must-not-call-rex"
    samples, service_samples = [], []
    with output.open("wb") as errors:
        started = time.perf_counter()
        process = subprocess.Popen([str(helper), "macos-serve", "--fixture", str(fixture)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                   env=environment, bufsize=0, start_new_session=True)
        try:
            protocol = Protocol(process)
            opened, open_ms = protocol.request("open", context={})
            cold_ms = (time.perf_counter() - started) * 1000
            for query in QUERIES * rounds:
                response, elapsed = protocol.request("query", query=query, scope="all")
                if response.get("query") != query or response.get("scope") != "all":
                    raise RuntimeError("Query response does not describe the requested search")
                samples.append(elapsed)
                service_samples.append(response["elapsed_ms"])
            # Verify the fixture's safety contract in the same running helper.
            rejected, _ = protocol.request("activate", target_id=opened["rows"][0]["id"])
            if rejected.get("type") != "error" or "Fixture mode never activates" not in rejected.get("message", ""):
                raise RuntimeError(f"Fixture unexpectedly accepted activation: {rejected!r}")
            process.stdin.close()
            if process.wait(timeout=5) != 0:
                raise RuntimeError("Helper exited unsuccessfully; inspect its stderr log")
        finally:
            stop_owned(process)
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()
    warmup = len(QUERIES)
    return {
        "measurement": "Python request serialization, pipe round trip, Rust matching and JSON response decoding; no AppKit or rendering",
        "cold_process_start_to_first_results_ms": cold_ms,
        "open_round_trip_ms": open_ms,
        "open_helper_elapsed_ms": opened["elapsed_ms"],
        "query": summary(samples[warmup:]),
        "query_helper_elapsed": summary(service_samples[warmup:]),
        "samples_ms": samples,
        "helper_samples_ms": service_samples,
        "warmup_queries": warmup,
        "fixture_activation_rejected": True,
    }


def ui_benchmark(app, fixture, output):
    report = output.with_suffix(".ui.json")
    capture = output.with_suffix(".png")
    report.unlink(missing_ok=True)
    capture.unlink(missing_ok=True)
    executable = app / "Contents/MacOS/InterdimuxPicker"
    with output.with_suffix(".ui.log").open("wb") as log:
        process = subprocess.Popen([str(executable), "--fixture", str(fixture),
                                    "--benchmark-output", str(report), "--capture", str(capture)],
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            if process.wait(timeout=60) != 0:
                raise RuntimeError("Native benchmark failed; inspect its UI log")
        finally:
            stop_owned(process)
    if not report.is_file():
        raise RuntimeError("Native benchmark produced no report; inspect its UI log")
    result = json.loads(report.read_text())
    result["capture"] = str(capture)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=MACOS / "build/Interdimux Picker.app")
    parser.add_argument("--helper", type=Path, help="Override the helper for protocol measurements only")
    parser.add_argument("--output", type=Path, default=MACOS / "build/benchmarks")
    parser.add_argument("--sizes", type=int, nargs="+", default=[500, 5000])
    parser.add_argument("--rounds", type=int, default=10, help="Protocol query cycles; one cycle is discarded as warmup")
    parser.add_argument("--ui", action="store_true", help="Also open a fixture-only native window for each corpus size")
    args = parser.parse_args()
    if any(size < 1 for size in args.sizes) or args.rounds < 2:
        parser.error("sizes must be positive and rounds must be at least 2")
    app = args.app.resolve()
    helper = (args.helper or app / "Contents/Helpers/imux").resolve()
    if not helper.is_file():
        parser.error(f"Helper is missing: {helper}; run ./macos/build.sh first")
    if args.ui and platform.system() != "Darwin":
        parser.error("--ui requires macOS")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"platform": platform.platform(), "helper": str(helper),
              "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "query_sequence": QUERIES, "corpora": []}
    for size in args.sizes:
        fixture = output / f"fixture-{size}.json"
        fixture.write_text(json.dumps({"rows": fixture_rows(size)}, ensure_ascii=False), encoding="utf-8")
        entry = {"rows": size, "fixture": str(fixture),
                 "protocol": helper_benchmark(helper, fixture, output / f"helper-{size}.stderr.log", args.rounds)}
        if args.ui:
            entry["native_ui"] = ui_benchmark(app, fixture, output / f"native-{size}")
        report["corpora"].append(entry)
        print(json.dumps({"rows": size, "protocol": entry["protocol"]["query"],
                          "native_ui": {key: entry.get("native_ui", {}).get(key) for key in ("median_ms", "p95_ms")}
                          if args.ui else None}), flush=True)
    path = output / "report.json"
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Report: {path}")


if __name__ == "__main__":
    main()
