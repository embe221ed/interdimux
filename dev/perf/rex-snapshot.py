#!/usr/bin/env python3
"""Measure Rex CLI + production snapshot collection on a disposable Unix server.

Run with python3 dev/perf/rex-snapshot.py. Each sample includes a new CLI and
connection. The server and its synthetic panes stay hot between samples.
"""
import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
COLLECTOR = ROOT / "rust/src/rex_snapshot.lua"


def run(root, sizes, samples, delay_ms):
    socket = root / "server.sock"
    endpoint = "unix://" + str(socket)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("REX_", "INTERDIMUX_"))}
    config = root / "init.lua"
    config.touch()
    with (root / "server.log").open("w") as log:
        server = subprocess.Popen([
            "rex", "server", "run", "--listen", endpoint, "--state-dir", str(root / "state"),
            "--config", str(config), "--max-windows", str(max(sizes)), "--restore=false",
        ], env=env, stdout=subprocess.DEVNULL, stderr=log)

    def script(code):
        raw = subprocess.check_output([
            "rex", "--autostart=false", "-S", endpoint, "do", "-e", code, "--json",
        ], env=env, timeout=45)
        return json.loads(raw)

    try:
        for _ in range(200):
            if server.poll() is not None:
                raise RuntimeError((root / "server.log").read_text())
            if socket.exists():
                break
            time.sleep(.025)
        # One long-lived direct child per pane, without shell initialization.
        new_window = """rex.layout.block { flavor = "com.superlogical.terminal.shell",
            options = { shell = "none", command = { "/bin/cat" }, login = false } }"""
        sid = script('return assert(rex.call("session.create", { label = "bench" }))')["session_id"]
        count = 0
        for size in sizes:
            script(f"""
                local sid = {json.dumps(sid)}
                assert(rex.session.attach {{ session_id = sid }})
                for i = 1, {size - count} do
                    local window = assert(rex.session.new_window {{
                        session_id = sid, focus = false, layout = {new_window}
                    }})
                    assert(rex.session.disown_block {{ session_id = sid, block_ids = window.block_ids }})
                end
                return true
            """)
            count = size
            for catalog in [False, True]:
                # Instrument only collector RPCs. The artificial delay simulates
                # serial transport latency. It is additional to local IPC.
                lua = f"""
                    local api = rex
                    local calls = 0
                    local function wrap(method)
                        return function(...)
                            calls = calls + 1
                            if {delay_ms} > 0 then api.sleep({delay_ms / 1000}) end
                            return method(...)
                        end
                    end
                    rex = {{ call = wrap(api.call), session = {{ view = wrap(api.session.view) }},
                        args = {{ sessions_only = {str(catalog).lower()} }} }}
                    local snapshot = dofile({json.dumps(str(COLLECTOR))})
                    local n = 0
                    for _ in pairs(snapshot.metadata) do n = n + 1 end
                    assert(not next(snapshot.errors) and not next(snapshot.incomplete_metadata))
                    return {{ sessions = #snapshot.sessions, metadata = n, calls = calls }}
                """
                times = []
                for i in range(1 + samples):
                    start = time.perf_counter()
                    result = script(lua)
                    elapsed = (time.perf_counter() - start) * 1000
                    assert result["sessions"] == 1 and result["metadata"] == (0 if catalog else size), result
                    if i:
                        times.append(elapsed)
                print(json.dumps({"panes": size, "path": "session list" if catalog else "full snapshot",
                                  "delay_per_rpc_ms": delay_ms, "rpcs": result["calls"],
                                  "samples": samples, "median_ms": round(statistics.median(times), 2),
                                  "p95_ms": round(sorted(times)[math.ceil(.95*samples)-1], 2)}), flush=True)
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", type=int, nargs="+", default=[1, 10, 100])
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--rpc-delay-ms", type=float, default=0, help="simulated delay per collector RPC")
    args = parser.parse_args()
    if not 0 <= args.rpc_delay_ms <= 10:
        parser.error("use an RPC delay from 0 to 10 ms")
    if not (args.samples > 0 and args.sizes == sorted(set(args.sizes)) and 0 < args.sizes[0] <= args.sizes[-1] <= 500):
        parser.error("use positive samples and increasing unique sizes from 1 to 500")
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="imux-rex-") as tmp:
        run(Path(tmp), args.sizes, args.samples, args.rpc_delay_ms)
