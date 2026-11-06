#!/usr/bin/env python3
r"""Measure the native picker through real fzf PTYs, without connecting to Rex.

    python3 rust/tests/bench_native.py --baseline /tmp/before/imux \
        --candidate rust/target/release/imux --repetitions 20 --json /tmp/native.json

Requires Python 3, Unix PTYs, fzf 0.74+, and release imux binaries. Run on an
otherwise idle machine, after building both revisions. Results are informational:
no wall-clock threshold gates CI. Missing/incorrect frames are errors.

Each run gets a synthetic HOME, Git HEADs, Rex snapshot, private live-update
mailbox, and owned sleep processes (up to 32 distinct PIDs). No Rex server is
contacted, and fixture PIDs/data belong to this run. Process/Git enrichment uses
default settings; --enrichment metadata disables those two optional enrichments
to isolate rendering/controller costs.
The small case has 2 sessions / 4 windows / 12 panes; stress has 10 / 50 / 500,
including long Unicode labels. Baseline/candidate order alternates each round.

Timings end when actual PTY output has painted the required terminal cells and
completed any synchronized frame; they do not use query echo or HTTP acceptance
as paint proxies. Startup starts just before exec is released on a sized PTY;
query starts at the input write; live starts at atomic snapshot replacement;
resize starts at TIOCSWINSZ/SIGWINCH. Live latency includes the snapshot watcher,
but excludes Rex's separate event coalescing, native GUI creation and GPU paint.
The first live publication follows typing shortly after opening; the steady live
publication follows a completed update. Both preserve the filtered selection.
The terminal decoder is shared with the repository's PTY regression tests.
"""

import argparse
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import pty
import random
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.dont_write_bytecode = True
from terminal_screen import Cursor


CASES = {"small": (2, 2, 3), "stress": (10, 5, 10)}
METRICS = ("first_paint_ms", "query_paint_ms", "live_paint_ms", "steady_live_paint_ms", "resize_paint_ms")


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    started = time.perf_counter()
    temporary.replace(path)
    return started


def environment(root, fzf):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("INTERDIMUX_", "FZF_", "REX_", "IMUX_", "XDG_"))
           and key not in ("TMUX", "TMUX_PANE", "ESCDELAY", "TERM_PROGRAM",
                           "TERM_PROGRAM_VERSION", "COLORTERM", "NO_COLOR")}
    env.update(HOME=str(root), TERM="xterm-256color", SHELL="/bin/sh",
               XDG_DATA_HOME=str(root / "data"), XDG_CONFIG_HOME=str(root / "config"),
               XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
               INTERDIMUX_FZF_BIN=fzf, INTERDIMUX_REX_BIN=str(root / "no-rex"),
               INTERDIMUX_USE_ZOXIDE="off", INTERDIMUX_ORDER="index",
               INTERDIMUX_RAW="off", INTERDIMUX_PREVIEW="off", INTERDIMUX_THEME="terminal")
    # Deliberately stale inherited dimensions exercise the actual PTY grid.
    env.update(LINES="9", COLUMNS="20")
    return env


def fixture(root, case, pids):
    session_count, window_count, pane_count = CASES[case]
    data = {"version": 1, "host_id": "host:bench", "sessions": [],
            "views": {}, "metadata": {}, "errors": {}}
    serial = 0
    for session in range(session_count):
        sid = f"session:{session}"
        name = "frame-start" if session == 0 else f"project-{session:02}"
        data["sessions"].append({"session_id": sid, "label": name})
        view = {"active_window_id": f"window:{session}:0", "windows": []}
        data["views"][sid] = view
        project = root / f"projects/project-{session:02}"
        (project / ".git").mkdir(parents=True, exist_ok=True)
        (project / ".git/HEAD").write_text("ref: refs/heads/feature-benchmark\n")
        for window in range(window_count):
            wid = f"window:{session}:{window}"
            blocks = []
            view["windows"].append({"window_id": wid, "label": f"Editor-{window:02}",
                                    "focused_block_id": f"block:{serial}",
                                    "layers": [{"kind": "tiled", "blocks": blocks}]})
            for pane in range(pane_count):
                bid = f"block:{serial}"
                label = f"pane-{serial:04}"
                if case == "stress":
                    label += "-日本語-cafe\u0301-" + "long-label-" * 5
                blocks.append({"block_id": bid, "label": label, "host_id": "host:bench"})
                data["metadata"][bid] = {
                    "home": str(root), "foreground": {
                        "pid": pids[serial % len(pids)], "name": "sleep", "argv0": "sleep",
                        "cwd": str(project)}}
                serial += 1
    target = data["views"][sid]["windows"][-1]["layers"][0]["blocks"][-1]
    target["label"] = "needle-query"
    return data, target


def respond(fd, pending, data):
    pending += data
    end = 0
    for match in re.finditer(rb"\x1b\[([0-?]*[ -/]*)([@-~])", pending):
        parameters, final = match.groups()
        answer = None
        if final == b"n" and parameters == b"6":
            answer = b"\x1b[1;1R"
        elif final == b"c" and parameters.startswith(b">"):
            answer = b"\x1b[>84;0;0c"
        elif final == b"c" and parameters in (b"", b"0"):
            answer = b"\x1b[?1;2c"
        elif final == b"p" and re.fullmatch(rb"\?[0-9]+\$", parameters):
            answer = b"\x1b[" + parameters[:-1] + b";2$y"
        if answer:
            os.write(fd, answer)
        end = match.end()
    return pending[end:][-128:]


class Picker:
    def __init__(self, binary, root, env, timeout):
        self.root, self.timeout = root, timeout
        self.status = None
        self.pending = b""
        self.tail = bytearray()
        self.bytes = 0
        self.received_at = None
        self.screen = Cursor(28, 120)
        gate_read, gate_write = os.pipe()
        child, master = pty.fork()
        if child == 0:
            os.close(gate_write)
            os.read(gate_read, 1)
            os.close(gate_read)
            command = [str(binary), "pick", "--backend", "rex", "--client", "client:bench",
                       "--session", "session:0", "--window", "window:0:0", "--block", "block:0",
                       "--picker-block", "block:picker", "--snapshot", str(root / "snapshot.json"),
                       "--result", str(root / "result.json")]
            os.chdir(root)
            os.execve(binary, command, env)
        self.child, self.master = child, master
        os.close(gate_read)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 120, 0, 0))
        self.started = time.perf_counter()
        os.write(gate_write, b"x")
        os.close(gate_write)

    def pump(self, wait=.005):
        ready, _, _ = select.select([self.master], [], [], wait)
        if not ready:
            return False
        try:
            data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if not data:
            raise RuntimeError("picker exited before its expected frame: " + repr(bytes(self.tail)))
        self.received_at = time.perf_counter()
        self.bytes += len(data)
        self.tail.extend(data)
        del self.tail[:-4096]
        self.screen.feed(data, (self.received_at - self.started) * 1000)
        self.pending = respond(self.master, self.pending, data)
        return True

    def painted(self, label, predicate, started):
        while time.perf_counter() - started < self.timeout:
            if self.pump() and not self.screen.synchronized and predicate():
                # Timestamp receipt before decoding: Python's cell parser is
                # an observer, and its own work is not picker paint latency.
                return (self.received_at - started) * 1000
        raise RuntimeError(f"timeout waiting for {label}; screen={self.screen.visible()!r}")

    def settle(self, seconds):
        until = time.perf_counter() + seconds
        while time.perf_counter() < until:
            self.pump(min(.005, max(0, until - time.perf_counter())))

    def text(self):
        return "\n".join(self.screen.visible())

    def cancel(self):
        os.write(self.master, b"\x1b")
        until = time.perf_counter() + self.timeout
        while time.perf_counter() < until:
            child, status = os.waitpid(self.child, os.WNOHANG)
            if child:
                self.status = status
                break
            ready, _, _ = select.select([self.master], [], [], .005)
            if ready:
                try:
                    os.read(self.master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
        if self.status is None:
            raise RuntimeError("picker did not exit after Escape")
        if os.waitstatus_to_exitcode(self.status) != 0:
            raise RuntimeError("picker exited unsuccessfully: " + repr(bytes(self.tail)))
        result = json.loads((self.root / "result.json").read_text())
        if result.get("outcome") != "cancel":
            raise RuntimeError(f"unexpected picker result: {result!r}")

    def close(self):
        if self.status is None:
            try:
                os.killpg(self.child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # On macOS, waiting before closing a PTY can block terminal teardown.
        os.close(self.master)
        if self.status is None:
            try:
                os.waitpid(self.child, 0)
            except ChildProcessError:
                pass


def run(binary, fzf, case, timeout, round_number, enrichment):
    with tempfile.TemporaryDirectory(prefix="imux-bench-") as directory:
        root = Path(directory)
        env = environment(root, fzf)
        if enrichment == "metadata":
            env.update(INTERDIMUX_SHOW_FULL_COMMAND="off", INTERDIMUX_SHOW_GIT_BRANCH="off")
        processes = []
        picker = None
        try:
            count = math.prod(CASES[case])
            for _ in range(min(count, 32)):
                processes.append(subprocess.Popen(["/bin/sleep", "1200"], cwd=root, env=env,
                                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                                  stderr=subprocess.DEVNULL))
            snapshot, target = fixture(root, case, [process.pid for process in processes])
            atomic_json(root / "snapshot.json", snapshot)
            atomic_json(root / "live.json", {"version": 1})
            picker = Picker(binary, root, env, timeout)
            first = picker.painted("first paint", lambda: "frame-start" in picker.text()
                                   and "Enter switch" in picker.text(), picker.started)
            first_bytes = picker.bytes
            # Let the initial watcher observation settle; deterministic jitter
            # samples different phases of its 100ms clock across paired runs.
            picker.settle(.22 + random.Random(round_number).uniform(0, .09))
            started = time.perf_counter()
            os.write(picker.master, b"needle-query")
            query = picker.painted("filtered query result", lambda: "needle-query" in picker.text()
                                   and "frame-start" not in picker.text()
                                   and re.search(r"\b1/\d+\b", picker.text()) is not None, started)
            picker.settle(.22 + random.Random(round_number + 100).uniform(0, .09))
            target["label"] = "needle-query-live"
            started = atomic_json(root / "snapshot.json", snapshot)
            live = picker.painted("live snapshot result", lambda: "needle-query-live" in picker.text(), started)
            picker.settle(.15 + random.Random(round_number + 200).uniform(0, .09))
            target["label"] = "needle-query-next"
            started = atomic_json(root / "snapshot.json", snapshot)
            steady = picker.painted("steady live snapshot result", lambda: "needle-query-next" in picker.text(), started)
            # A resize is complete when the new grid bottom has the footer and
            # the controller has also repadded the target's columns. fzf paints
            # its own new grid before running the resize transform; counting
            # that first frame alone understates the visible update latency.
            picker.settle(.10)
            previous_row = next(line for line in picker.screen.visible() if "needle-query-next" in line)[:100]
            picker.screen.rows, picker.screen.columns = 34, 100
            picker.screen.anchors.clear()
            started = time.perf_counter()
            fcntl.ioctl(picker.master, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 100, 0, 0))
            os.killpg(picker.child, signal.SIGWINCH)
            resize = picker.painted("resized frame", lambda: "needle-query-next" in picker.text()
                                    and any("needle-query-next" in line and line != previous_row
                                            for line in picker.screen.visible())
                                    and any(anchor["row"] == 34 for anchor in picker.screen.anchors), started)
            total_bytes = picker.bytes
            picker.settle(.20)
            picker.cancel()
            return dict(first_paint_ms=first, query_paint_ms=query, live_paint_ms=live, steady_live_paint_ms=steady,
                        resize_paint_ms=resize, first_paint_bytes=first_bytes, total_bytes=total_bytes)
        finally:
            if picker:
                picker.close()
            for process in processes:
                process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def executable(value):
    resolved = shutil.which(value)
    if resolved is None:
        raise argparse.ArgumentTypeError(f"executable not found: {value}")
    return Path(resolved).resolve()


def summary(samples):
    return {metric: {"median": round(statistics.median(row[metric] for row in samples), 3),
                     "p95": round(sorted(row[metric] for row in samples)[math.ceil(.95 * len(samples)) - 1], 3)}
            for metric in (*METRICS, "first_paint_bytes", "total_bytes")}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", type=executable, help="before-change release binary")
    parser.add_argument("--candidate", type=executable, required=True, help="candidate release binary")
    parser.add_argument("--fzf", type=executable, default="fzf")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=8)
    parser.add_argument("--enrichment", choices=("local", "metadata"), default="local")
    parser.add_argument("--json", type=Path, help="write metadata, aggregate metrics, and raw samples")
    args = parser.parse_args()
    if args.repetitions < 1 or args.warmups < 0 or args.timeout <= 0:
        parser.error("repetitions and timeout must be positive; warmups cannot be negative")
    version = subprocess.check_output([str(args.fzf), "--version"], text=True).strip()
    numbers = re.match(r"(\d+)\.(\d+)", version)
    if numbers is None or tuple(map(int, numbers.groups())) < (0, 74):
        parser.error("fzf 0.74+ is required")
    binaries = {"candidate": args.candidate}
    if args.baseline:
        binaries = {"baseline": args.baseline, **binaries}
    report = {"metadata": {"platform": platform.platform(), "python": platform.python_version(),
                           "fzf": version, "grid": "28x120 -> 34x100", "warmups": args.warmups,
                           "enrichment": args.enrichment, "theme": "terminal",
                           "repetitions": args.repetitions, "p95_method": "nearest rank",
                           "binary": {key: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                                      for key, path in binaries.items()}}, "cases": {}}
    for case in args.cases:
        samples = {name: [] for name in binaries}
        for round_number in range(-args.warmups, args.repetitions):
            order = list(binaries.items())
            if round_number % 2:
                order.reverse()
            for name, binary in order:
                result = run(binary, str(args.fzf), case, args.timeout, round_number, args.enrichment)
                if round_number >= 0:
                    samples[name].append(result)
            progress = (f"warmup {round_number + args.warmups + 1}/{args.warmups}" if round_number < 0
                        else f"round {round_number + 1}/{args.repetitions}")
            print(f"{case}: {progress}",
                  file=sys.stderr, flush=True)
        report["cases"][case] = {name: {"summary": summary(values), "samples": values}
                                 for name, values in samples.items()}
        if args.json:
            args.json.write_text(json.dumps(report, indent=2) + "\n")
    print("case     binary     metric              median ms    p95 ms")
    for case, variants in report["cases"].items():
        for name, result in variants.items():
            for metric in METRICS:
                values = result["summary"][metric]
                print(f"{case:8} {name:10} {metric:19} {values['median']:9.3f} {values['p95']:9.3f}")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")
        print(f"Raw samples: {args.json}")


if __name__ == "__main__":
    main()
