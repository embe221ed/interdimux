#!/usr/bin/env python3
"""Benchmark remote session switches or cold picker rows on a connected Rex Mac.

The helper receives the picker's JSON protocol. In switch mode an independent
Apple Event observer times the Mac's selected session. In cold mode each trial
starts a fresh helper and times its first local results and a verified remote row.
The timers exclude keyboard dispatch, Launch Services, and display painting.
"""
import argparse
from contextlib import ExitStack, contextmanager
import json
from pathlib import Path
import select
import statistics
import subprocess
import tempfile
import time
import uuid

from test_live_actions import MACOS, Helper, Rex, local_app, require, rex_binary


OSASCRIPT = "/usr/bin/osascript"
JS = 'function run(a){ObjC.import("AppKit"); const r=Application(Number(a[0]));'
FRONT = "Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)"
OBSERVE = JS + """
    if (r.currentSession.id() !== a[1]) throw Error("Original session changed");
    console.log("ready");
    const start = Number($.NSProcessInfo.processInfo.systemUptime);
    while (Number($.NSProcessInfo.processInfo.systemUptime)-start < 20) {
        const id = r.currentSession.id();
        const now = Number($.NSProcessInfo.processInfo.systemUptime);
        if (id === a[2]) return now.toString();
        if (id !== a[1]) throw Error("Session changed outside the trial");
        delay(0.015);
    }
    throw Error("Timed out observing the destination");
}"""


class RexApp:
    def __init__(self, pid):
        self.pid = str(pid)

    def script(self, body, *args):
        return json.loads(subprocess.check_output(
            [OSASCRIPT, "-l", "JavaScript", "-e", JS + body + "}", "--", self.pid, *map(str, args)],
            text=True, timeout=12))

    def view(self):
        return self.script("return JSON.stringify({id:r.currentSession.id(), front:" + FRONT + "});")

    def host_key(self, host):
        return self.script("""
            const list=r.hosts.whose({name:a[1]})();
            if(list.length!==1) throw Error("Host name is ambiguous");
            const h=list[0].properties();
            if(!h.connected || h.name!==a[1]) throw Error("Host unavailable");
            return JSON.stringify(h.id);
        """, host)

    def show_origin(self, previous, source):
        ok = self.script('if(r.currentSession.id()!==a[1] || ' + FRONT + '''!==Number(a[2]))
            throw Error("Rex view or foreground app changed outside the trial");
            r.show(r.sessions.byId(a[3]));
            return JSON.stringify(r.currentSession.id()===a[3]);
        ''', previous["id"], previous["front"], source)
        require(ok, "Rex did not select the disposable origin session")

    def timed_show(self, source, destination):
        return self.script("""
            if (r.currentSession.id()!==a[1]) throw Error("Rex view changed outside the trial");
            const session=r.sessions.byId(a[2]);
            const start=Number($.NSProcessInfo.processInfo.systemUptime);
            r.show(session);
            const finish=Number($.NSProcessInfo.processInfo.systemUptime);
            return JSON.stringify([start,finish]);
        """, source, destination)

    def restore(self, previous, owned):
        # Only restore a view still owned by this measurement. Preserve a different
        # application if the user switched to it while Rex was selected.
        return self.script("""
            const id=r.currentSession.id();
            if(!a.slice(3).includes(id)) return JSON.stringify(id===a[1]);
            const frontBefore=""" + FRONT + """;
            r.show(r.sessions.byId(a[1]));
            const restore=frontBefore===Number(a[0]) ? Number(a[2]) : frontBefore;
            if (restore!==Number(a[0]) && """ + FRONT + """===Number(a[0])) {
                const app=$.NSRunningApplication.runningApplicationWithProcessIdentifier(restore);
                if(app) app.activateWithOptions(0);
            }
            return JSON.stringify(r.currentSession.id()===a[1]);
        """, previous["id"], previous["front"], *owned)

    @contextmanager
    def observer(self, source, destination):
        with subprocess.Popen([OSASCRIPT, "-l", "JavaScript", "-e", OBSERVE, "--",
                               self.pid, source, destination], text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as watcher:
            try:
                readable, _, _ = select.select([watcher.stderr], [], [], 8)
                require(readable and watcher.stderr.readline().strip() == "ready",
                        "Rex selection changed or observer failed to start")
                yield watcher
            finally:
                if watcher.poll() is None:
                    watcher.kill()


class Remote:
    def __init__(self, rex, host):
        self.rex = rex
        self.owned = {}
        self.physical = next(entry["host"]["host_id"] for entry in rex.command("hosts", "list", "--json")["hosts"]
                             if entry["host"]["label"] == host)
        for socket in (Path.home() / "Library/Application Support/rex/ssh").glob("*.sock"):
            self.route = str(socket)
            try:
                if self.api("server.status")["host_id"] == self.physical:
                    return
            except RuntimeError:
                pass
        raise RuntimeError("No verified SSH forward for " + host)

    def command(self, *args):
        return self.rex.command("--server=" + self.route, *args)

    def api(self, method, **arguments):
        return self.command("api", "call", method, json.dumps(arguments))

    def new(self, label):
        session = self.command("new", label, "-c", "/tmp", "--window", "First",
                               "--shell=none", "--json", "--", "/bin/cat")["session_id"]
        self.owned[session] = label
        return session

    def view(self, session):
        require(session in self.owned, "Unknown test session")
        data = self.api("session.bootstrap", event_scope="session", attach_session_ids=[session])
        require(data["server_status"]["host_id"] == self.physical, "Remote host changed")
        return next(s["view"] for s in data["attached_sessions"] if s["session"]["session_id"] == session)

    def cleanup(self):
        for sid, label in self.owned.items():
            self.command("do", "-e", """
                local a=rex.args
                local reply,e=rex.call("session.bootstrap",{event_scope="session",attach_session_ids={a.sid}})
                assert(reply,tostring(e)); assert(reply.server_status.host_id==a.host,"Cleanup found another host")
                for _,entry in ipairs(reply.attached_sessions or {}) do
                    if entry.session.session_id==a.sid then
                        assert(entry.session.label==a.label,"Disposable session label changed")
                        local done,err=rex.call("session.destroy",{session_id=a.sid})
                        assert(done,tostring(err)); break
                    end
                end
                return true
            """, "--args", json.dumps({"sid": sid, "label": label, "host": self.physical}))
        require(not (self.owned.keys() & {s["session_id"] for s in self.api("session.list")["sessions"]}),
                "Disposable sessions still present")

    def reset_focus(self, session, blocks):
        self.command("do", "-e", """
            local a=rex.args
            local reply,e=rex.call("session.bootstrap",{event_scope="session",attach_session_ids={a.session}})
            assert(reply,tostring(e)); assert(reply.server_status.host_id==a.host)
            for _,block in ipairs(a.blocks) do
                local ok,err=rex.call("session.focus_block",{session_id=a.session,block_id=block})
                assert(ok,tostring(err))
            end
            return true
        """, "--args", json.dumps({"session": session, "host": self.physical, "blocks": blocks}))


def blocks(view):
    return {b["block_id"]: w["window_id"] for w in view["windows"]
            for layer in w["layers"] for b in layer["blocks"]}


def picker_target(helper, context, label, session, window, block, kind):
    helper.request("open", context=context)
    deadline = time.monotonic() + 35
    while True:
        helper.request("remote_update", expected="remote_update")
        result = helper.request("query", scope="all", query=label)
        for row in result["rows"]:
            if row.get("session_id") != session or row.get("stale"):
                continue
            if (row["kind"] == kind and (kind == "session" or row.get("window_id") == window)
                    and (kind != "pane" or row.get("block_id") == block)):
                return row["id"]
        require(time.monotonic() < deadline, "Picker did not publish exact " + kind)
        time.sleep(.04)


@contextmanager
def native_driver(directory, catalog=False):
    # A cold-row driver only accepts read-only catalog requests.
    operation = ('["hosts": RemoteSessionAutomation.boundedCatalog(RemoteSessionAutomation.readCatalog(request), '
                 'token: request["token"] as? UInt64 ?? 0)]' if catalog else 'RemoteSessionAutomation.reveal(request)')
    main = directory / "main.swift"
    main.write_text("""
import Foundation
while let line = readLine() {
    guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { exit(2) }
    let result: [String: Any] = OPERATION
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
    FileHandle.standardOutput.write(Data([10]))
}
""".replace("OPERATION", operation))
    binary = directory / "native-driver"
    subprocess.run(["xcrun", "swiftc", "-O", str(MACOS / "Sources/RemoteSessionAutomation.swift"),
                    str(main), "-framework", "AppKit", "-o", str(binary)], check=True)
    with subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as driver:
        try:
            yield driver
        finally:
            driver.stdin.close()
            if driver.poll() is None:
                driver.terminate()


def send_native(driver, request):
    driver.stdin.write(json.dumps(request) + "\n")
    driver.stdin.flush()


def read_native(driver):
    require(select.select([driver.stdout], [], [], 25)[0], "Native driver timed out")
    return json.loads(driver.stdout.readline())


def activate(helper, target, driver):
    if driver is None:
        helper.request("activate", expected="activated", target_id=target)
        return
    request = helper.request("activate", expected="reveal_remote", target_id=target, native_reveal=True)
    send_native(driver, request)
    helper.request("complete_remote_reveal", expected="activated", activation_id=request["id"], result=read_native(driver))


def app_client(rex, requested):
    clients = [c for c in rex.api("client.list", kinds=["app"])["clients"] if local_app(c)
               and (not requested or c["client_id"] == requested)]
    require(len(clients) == 1, "Select exactly one local Rex app with --client")
    return clients[0]


def run(args, helpers, rex, driver):
    client = app_client(rex, args.client)
    app = RexApp(client["principal"]["pid"])
    remote = Remote(rex, args.host)
    original = app.view()
    key = app.host_key(args.host)
    results = []
    token = "imux-latency-" + uuid.uuid4().hex[:12]
    try:
        source = remote.new(token + "-from")
        label = token + "-to"
        destination = remote.new(label)
        source_block, source_tab = next(iter(blocks(remote.view(source)).items()))
        first = next(iter(blocks(remote.view(destination))))
        remote.command("run", "-s", destination, "-c", "/tmp", "--label", "Second",
                       "--focus=false", "--shell=none", "--json", "--", "/bin/cat")
        tabs = blocks(remote.view(destination))
        other = next(block for block in tabs if block != first)
        remote.command("split", "-s", destination, "-b", other, "-c", "/tmp", "--label", "Split",
                       "--focus=false", "--shell=none", "--json", "--", "/bin/cat")
        pane = next(block for block in blocks(remote.view(destination)) if block not in tabs)
        source_id, destination_id = key + "/" + source, key + "/" + destination
        context = {"client_id": client["client_id"], "origin_server": args.host, "origin_session_id": source,
                   "origin_window_id": source_tab, "origin_block_id": source_block}
        arms = list(helpers) + (["rex-show"] if args.reference else [])
        for round_no in range(args.rounds):
            for arm in (arms if round_no % 2 == 0 else reversed(arms)):
                for kind in (("session",) if arm == "rex-show" else args.targets):
                    remote.reset_focus(destination, [other, first])
                    before = app.view()
                    require(before == original, "Rex selection or foreground app changed outside the trial")
                    try:
                        app.show_origin(before, source_id)
                        timing = {}
                        with app.observer(source_id, destination_id) as observer:
                            if arm == "rex-show":
                                start, finished = app.timed_show(source_id, destination_id)
                            else:
                                helper = helpers[arm]
                                opened = time.monotonic()
                                target = picker_target(helper, context, label, destination, tabs[other], pane, kind)
                                row_ready = time.monotonic()
                                if args.dwell_ms:
                                    time.sleep(args.dwell_ms / 1000)
                                start = time.monotonic()
                                activate(helper, target, driver if arm in args.resident and kind == "session" else None)
                                finished = time.monotonic()
                                timing = {"open_to_row_ms": round((row_ready - opened) * 1000, 2),
                                          "row_to_request_ms": round((start - row_ready) * 1000, 2)}
                            stamp, error = observer.communicate(timeout=21)
                            require(observer.returncode == 0, error or "Observer failed")
                        timing.update(app_selected_ms=round((float(stamp) - start) * 1000, 2),
                                      ack_ms=round((finished - start) * 1000, 2))
                        require(app.view()["id"] == destination_id, "Mac selected another session")
                        state = remote.view(destination)
                        if kind != "session":
                            require(state["active_window_id"] == tabs[other], "Remote selected another tab")
                        if kind == "pane":
                            chosen = next(w for w in state["windows"] if w["window_id"] == tabs[other])
                            require(chosen["focused_block_id"] == pane, "Remote selected another pane")
                        row = {"round": round_no + 1, "helper": arm, "target": kind, **timing}
                        print(json.dumps(row), flush=True)
                        results.append(row)
                    finally:
                        require(app.restore(before, [source_id, destination_id]),
                                "Rex selection changed externally, preserving it")
        for arm in arms:
            for kind in ("session", "window", "pane"):
                rows = [r for r in results if r["target"] == kind and r["helper"] == arm]
                if not rows:
                    continue
                print(json.dumps({"helper": arm, "target": kind, "trials": len(rows),
                                  **{k: statistics.median(r[k] for r in rows)
                                     for k in ("app_selected_ms", "ack_ms")}}), flush=True)
    finally:
        try:
            owned = [key + "/" + sid for sid in remote.owned]
            app.restore(original, owned)
        finally:
            remote.cleanup()


@contextmanager
def isolated_helper(rex, binary):
    with tempfile.TemporaryDirectory(prefix="imux-picker-helper-") as temp:
        directory = Path(temp)
        env = rex.environment.copy()
        for key in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
            path = directory / key
            path.mkdir()
            env[key] = str(path)
        helper = Helper(binary, env, directory / "helper.log")
        try:
            yield helper
        finally:
            helper.stop()


def measure_cold_rows(helper, context, host, physical, session, early_poll, driver=None):
    sid, label = session["session_id"], session["label"]
    target = f"remote:{physical}:{sid}"
    start = time.monotonic()
    result = helper.request("open", context=context, **({"native_catalog": True} if driver else {}))
    local_ms = (time.monotonic() - start) * 1000
    require(any(r["kind"] == "session" and not r.get("host") for r in result["rows"]),
            "First response is missing local session rows")
    delay = .05
    brief_polls = 6 if early_poll else 1
    next_poll = time.monotonic() + delay
    token = None
    offered = submitted_target = changed = False

    def start_catalog(message):
        nonlocal token, offered
        if driver and (offer := message.get("native_catalog")):
            require(not offered and offer["token"] > 0, "Unexpected duplicate or invalid catalog grant")
            send_native(driver, offer)
            token, offered = offer["token"], True

    start_catalog(result)
    while True:
        if any(r["id"] == target and r.get("host") == host and r.get("host_id") == physical
               and r.get("session_id") == sid and r["kind"] == "session" and not r.get("stale")
               and not r.get("context_only") for r in result["rows"]):
            sample = {"local_first_ms": round(local_ms, 2),
                      "remote_row_ms": round((time.monotonic() - start) * 1000, 2)}
            if driver:
                if token is not None:
                    read_native(driver)  # Drain the losing hint after recording the row time.
                sample.update(catalog_offered=offered, catalog_submitted_target=submitted_target,
                              catalog_changed=changed)
            return sample
        require(time.monotonic() - start < 20, "Timed out waiting for the verified remote session")
        remaining = max(0, next_poll - time.monotonic())
        pipes = [driver.stdout] if token is not None else []
        if select.select(pipes, [], [], remaining)[0]:
            hosts = read_native(driver)["hosts"]
            fields = {"token": token, "catalog": hosts}
            # Match the helper's input limit, including the Python sender's envelope.
            line = json.dumps(dict(fields, type="native_catalog", id=helper.serial + 1), ensure_ascii=False)
            if len(line.encode()) + 1 > 64 * 1024:
                fields["catalog"] = []
            submitted_target = any(h["label"] == host and h["host_id"] == physical
                                   and any(s["session_id"] == sid for s in h["sessions"]) for h in fields["catalog"])
            changed = helper.request("native_catalog", expected="native_catalog", **fields)["changed"]
            token = None
            if changed:
                result = helper.request("query", scope="session", query=label)
                start_catalog(result)
            continue
        change = helper.request("remote_update", expected="remote_update")
        start_catalog(change)
        if change["changed"]:
            result = helper.request("query", scope="session", query=label)
            start_catalog(result)
            brief_polls, delay = 1, .05
        elif brief_polls > 1:
            brief_polls -= 1
        else:
            delay = min(.2, delay * 2)
        next_poll = time.monotonic() + delay


def cold_rows(args, paths, rex, driver):
    client = app_client(rex, args.client)
    app = RexApp(client["principal"]["pid"])
    current = app.script("const s=r.currentSession.properties();"
                         "return JSON.stringify({id:s.id,remote:s.remote,host:s.hostName});")
    sid = current["id"].rsplit("/", 1)[-1]
    context = {"client_id": client["client_id"]}
    if current["remote"]:
        context.update(origin_server=current["host"], origin_session_id=sid)
    else:
        context["session_id"] = sid
    remote = Remote(rex, args.host)
    sessions = remote.api("session.list")["sessions"]
    require(sessions, "Choose a connected host with an existing session")
    arms = list(paths)
    records = {name: [] for name in arms}
    for round_no in range(args.rounds):
        offset = round_no % len(arms)
        for name in arms[offset:] + arms[:offset]:
            with isolated_helper(rex, paths[name]) as helper:
                sample = measure_cold_rows(helper, context, args.host, remote.physical,
                                           sessions[0], name in args.early_poll,
                                           driver if name in args.resident_catalog else None)
                records[name].append(sample)
                print(json.dumps({"helper": name, "round": round_no + 1, **sample}), flush=True)
    for name, samples in records.items():
        summary = {"helper": name, "trials": len(samples), "early_poll": name in args.early_poll,
                   **{k: statistics.median(s[k] for s in samples) for k in ("local_first_ms", "remote_row_ms")}}
        if name in args.resident_catalog:
            summary.update({k + "_trials": sum(s[k] for s in samples)
                            for k in ("catalog_offered", "catalog_submitted_target", "catalog_changed")})
        print(json.dumps(summary))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--run-live", action="store_true", help="switch the Mac app through disposable sessions")
    mode.add_argument("--cold-rows", action="store_true", help="read first local and remote rows from fresh helpers without switching sessions")
    parser.add_argument("--host", required=True, help="connected SSH host label")
    parser.add_argument("--client", help="exact local Mac app client ID")
    parser.add_argument("--helper", action="append", required=True, metavar="NAME=PATH", help="bundled imux helper")
    parser.add_argument("--resident", action="append", default=[], metavar="NAME",
                        help="use this checkout's resident Swift reveal for the named helper; repeat to compare supported builds")
    parser.add_argument("--resident-catalog", action="append", default=[], metavar="NAME",
                        help="read the verified Mac app catalog in the resident Swift driver for this cold-row helper")
    parser.add_argument("--targets", nargs="+", choices=("session", "window", "pane"),
                        help="live switch targets to exercise (default: session, window and pane)")
    parser.add_argument("--early-poll", action="append", default=[], metavar="NAME",
                        help="use the current picker's six initial 50 ms cold polls for this helper; others use the previous 50/100/200 ms cadence")
    parser.add_argument("--reference", action="store_true", help="also time Rex's direct session Show with a known exact ID")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--dwell-ms", type=int, default=0, help="additional delay after the target row appears")
    args = parser.parse_args()
    if args.rounds < 1 or args.dwell_ms < 0:
        parser.error("choose a positive round count and nonnegative dwell")
    if (args.cold_rows and (args.resident or args.reference or args.dwell_ms or args.targets)) or (args.run_live and (args.early_poll or args.resident_catalog)):
        parser.error("use --early-poll and --resident-catalog with --cold-rows and --targets, --resident, --reference or --dwell-ms with --run-live")
    if args.reference and args.targets and "session" not in args.targets:
        parser.error("--reference requires the session target")
    args.targets = args.targets or ("session", "window", "pane")
    paths = {}
    for value in args.helper:
        name, separator, path = value.partition("=")
        if not name or not separator or not path or name in paths or name == "rex-show":
            parser.error("each helper needs a unique NAME=PATH other than rex-show")
        paths[name] = Path(path).resolve()
    if not (set(args.resident) | set(args.early_poll) | set(args.resident_catalog)).issubset(paths):
        parser.error("--resident, --resident-catalog and --early-poll names must match a --helper")
    rex = Rex(rex_binary(None))
    with tempfile.TemporaryDirectory(prefix="imux-switch-") as directory, ExitStack() as stack:
        if args.cold_rows:
            driver = stack.enter_context(native_driver(Path(directory), catalog=True)) if args.resident_catalog else None
            cold_rows(args, paths, rex, driver)
            return
        helpers = {name: stack.enter_context(isolated_helper(rex, path)) for name, path in paths.items()}
        driver = stack.enter_context(native_driver(Path(directory))) if args.resident else None
        run(args, helpers, rex, driver)


if __name__ == "__main__":
    main()
