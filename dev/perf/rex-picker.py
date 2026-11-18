#!/usr/bin/env python3
"""Compare two release macos-serve helpers on identical synthetic Rex catalogs.

Example: python3 dev/perf/rex-picker.py --baseline /tmp/before/imux \
    --candidate /tmp/after/imux --json /tmp/picker-perf.json
Measures process startup and JSON-lines round trips. Alternates run order,
warms each process, and checks query results for parity between both binaries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "macos"))
from benchmark import Protocol, QUERIES, fixture_rows, stop_owned, summary


def run(helper, fixture, directory, cycles):
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(directory),
        "INTERDIMUX_REX_BIN": str(directory / "no-rex"),
    }
    started = time.perf_counter()
    process = subprocess.Popen(
        [str(helper), "macos-serve", "--fixture", str(fixture)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0,
        env=environment, start_new_session=True,
    )
    try:
        protocol = Protocol(process)
        opened, _ = protocol.request("open", context={})
        startup = (time.perf_counter() - started) * 1000
        expected = []
        samples = []
        for cycle in range(cycles + 1):
            for query in QUERIES:
                response, elapsed = protocol.request(
                    "query", query=query, scope="all", allow_create=False,
                )
                if cycle:
                    samples.append(elapsed)
                else:
                    expected.append(response)
        process.stdin.close()
        if process.wait(timeout=5):
            raise RuntimeError("Helper exited unsuccessfully")
    finally:
        stop_owned(process)
        process.stdout.close()
        process.stdin.close()
    # Keep correctness checking outside the measured sequence. Omit timings
    # only. Titles, order, matches, scopes, actions and selected IDs must agree.
    digest = hashlib.sha256()
    for response in [opened, *expected]:
        for key in ("elapsed_ms", "open_timing_ms"):
            response.pop(key, None)
        digest.update(json.dumps(response, sort_keys=True).encode())
    return {"startup_ms": startup, "samples_ms": samples, "response_digest": digest.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--json", type=Path, help="output metadata, summaries and raw samples")
    parser.add_argument("--sizes", type=int, nargs="+", default=[50, 500, 5000, 10000])
    parser.add_argument("--trials", type=int, default=4)
    parser.add_argument("--cycles", type=int, default=5)
    args = parser.parse_args()
    if min(*args.sizes, args.trials, args.cycles) < 1:
        parser.error("sizes, trials and cycles must be positive")
    helpers = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    for path in helpers.values():
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f"Helper is missing or not executable: {path}")
    report = {"platform": platform.platform(), "python": platform.python_version(),
              "sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in helpers.items()},
              "queries": QUERIES, "cycles": args.cycles, "trials": args.trials, "cases": {}}
    with tempfile.TemporaryDirectory(prefix="imux-picker-comparison-") as temp:
        directory = Path(temp)
        fixture = directory / "fixture.json"
        for size in args.sizes:
            fixture.write_text(json.dumps({"rows": fixture_rows(size)}, ensure_ascii=False), encoding="utf-8")
            runs = {name: [] for name in helpers}
            for trial in range(args.trials):
                names = list(helpers)
                if trial % 2:
                    names.reverse()
                for name in names:
                    runs[name].append(run(helpers[name], fixture, directory, args.cycles))
                if runs[names[0]][-1]["response_digest"] != runs[names[1]][-1]["response_digest"]:
                    raise RuntimeError(f"Picker responses differ at {size} rows, trial {trial + 1}")
            case = {}
            for name, results in runs.items():
                samples = [ms for result in results for ms in result["samples_ms"]]
                case[name] = {"queries": summary(samples), "startup": summary([r["startup_ms"] for r in results]),
                              "by_query": {query: summary([ms for i, ms in enumerate(samples)
                                                         if QUERIES[i % len(QUERIES)] == query])
                                           for query in dict.fromkeys(QUERIES)},
                              "runs": results}
                print(f"{size:5} rows {name:9} {case[name]['queries']}", flush=True)
            report["cases"][str(size)] = case
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
