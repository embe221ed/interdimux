#!/usr/bin/env python3
"""Explicit live Rex action checks against disposable sessions, never user panes.

Requires --run-live and --restore-session. The bundled helper is exercised over
JSON lines; this test never launches the native picker or drives macOS UI.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


MACOS = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rex_binary(explicit):
    if explicit:
        return str(Path(explicit).expanduser().resolve())
    found = os.environ.get("INTERDIMUX_REX_BIN") or shutil.which("rex")
    if found:
        return found
    for base in (Path("/Applications"), Path.home() / "Applications"):
        for name in ("Rex Beta.app", "Rex.app"):
            candidate = base / name / "Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
            if candidate.is_file():
                return str(candidate)
    raise RuntimeError("Rex CLI not found; pass --rex")


def local_app(client):
    info, principal = client.get("info") or {}, client.get("principal") or {}
    return (client.get("connection_state") != "lost" and info.get("kind") == "app"
            and info.get("platform") == "macos" and principal.get("kind") == "peer"
            and principal.get("transport") == "unix" and not principal.get("path"))


class Rex:
    def __init__(self, executable):
        self.executable = executable
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("REX_")}

    def command(self, *arguments):
        process = subprocess.run(
            [self.executable, "--autostart=false", "--color=never", "--timeout=10s", *arguments],
            env=self.environment, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15,
        )
        if process.returncode:
            raise RuntimeError(process.stderr.strip() or "Rex command failed")
        return json.loads(process.stdout) if process.stdout.strip() else {}

    def api(self, method, **arguments):
        return self.command("api", "call", method, json.dumps(arguments, ensure_ascii=False))

    def sessions(self):
        return self.api("session.list").get("sessions") or []

    def view(self, session):
        return self.api("session.view", session_id=session)

    def terminal(self, session, block, method, **arguments):
        return self.api("com.superlogical.terminal." + method, session_id=session, block_id=block, args=arguments)

    def select(self, client, session, window=None):
        selection = {"session_id": session}
        if window:
            selection["window_id"] = window
        return self.api("client.perform", client_id=client, action="session.select",
                        args=selection, origin="cli", timeout_ms=5000)


class Helper:
    def __init__(self, executable, environment, log):
        self.log = log.open("wb")
        self.process = subprocess.Popen(
            [str(executable), "macos-serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, env=environment, bufsize=0, start_new_session=True,
        )
        self.buffer = bytearray()
        self.serial = 0
        self.timings = []

    def request(self, request_type, expected="results", **fields):
        self.serial += 1
        started = time.perf_counter()
        body = dict(fields, type=request_type, id=self.serial)
        self.process.stdin.write((json.dumps(body, ensure_ascii=False) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 25
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError("Helper timed out: " + request_type)
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Helper closed stdout: " + request_type)
            self.buffer.extend(chunk)
            require(len(self.buffer) <= 8 * 1024 * 1024, "Helper response exceeded 8 MiB")
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        response = json.loads(line)
        elapsed = (time.perf_counter() - started) * 1000
        self.timings.append({"type": request_type, "operation": fields.get("operation"), "elapsed_ms": elapsed})
        require(response.get("id") == self.serial, "Helper replied with the wrong request ID")
        require(response.get("type") == expected,
                "Helper " + request_type + " failed: " + str(response.get("message", response.get("type"))))
        return response

    def stop(self):
        process = self.process
        if process.poll() is None:
            # This process group contains only our helper and its CLI children.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3)
        for stream in (process.stdin, process.stdout, self.log):
            stream.close()


def windows(view):
    return view.get("windows") or []


def panes(window):
    return [block for layer in window.get("layers") or [] for block in layer.get("blocks") or []]


def membership(view):
    return {block["block_id"]: window["window_id"] for window in windows(view) for block in panes(window)}


def selection_state(view):
    return (view.get("active_window_id"),
            [(item["window_id"], item.get("focused_block_id"), item.get("zoomed_block_id"))
             for item in windows(view)], membership(view))


def window(view, identity):
    matches = [item for item in windows(view) if item["window_id"] == identity]
    require(len(matches) == 1, "Expected exact window is missing: " + identity)
    return matches[0]


class LiveActions:
    def __init__(self, args, rex, client, scratch, output):
        self.args, self.rex, self.client = args, rex, client
        self.scratch, self.output = scratch, output
        self.token = uuid.uuid4().hex[:12]
        self.primary_label = "native-picker-live-" + self.token
        self.query_label = "native-picker-query-" + self.token
        self.project = scratch / ("native-picker-project-" + self.token)
        self.project.mkdir()
        (self.project / ".git").mkdir()
        self.nested_project = self.project / "nested 東京" / ("deep-project-" + self.token)
        self.nested_project.mkdir(parents=True)
        (self.nested_project / "Cargo.toml").write_text("# Disposable project-discovery marker\n")
        self.initial_ids = {entry["session_id"] for entry in rex.sessions()}
        self.owned = []
        self.helper = None
        self.checks = []
        self.started = time.perf_counter()
        require(args.restore_session in self.initial_ids, "--restore-session must be a currently existing full session ID")
        if args.restore_window:
            window(rex.view(args.restore_session), args.restore_window)

    def record(self, session):
        require(session not in self.initial_ids and session != self.args.restore_session,
                "Refusing to claim an existing/user session")
        if session not in self.owned:
            self.owned.append(session)
            self.save_manifest()

    def save_manifest(self):
        (self.output / "owned-sessions.json").write_text(json.dumps({
            "client_id": self.client, "restore_session": self.args.restore_session,
            "restore_window": self.args.restore_window, "owned_session_ids": self.owned,
            "unique_labels": [self.primary_label, self.project.name, self.query_label], "project": str(self.project),
        }, indent=2) + "\n")

    def recover_created(self):
        # Recover creation that committed just before a lost/timed-out response.
        # Exact fresh random labels are ours; never adopt any pre-existing ID.
        labels = {self.primary_label, self.project.name, self.query_label}
        for session in self.rex.sessions():
            if session.get("label") in labels and session["session_id"] not in self.initial_ids:
                self.record(session["session_id"])

    def passed(self, name):
        elapsed = (time.perf_counter() - self.started) * 1000
        self.checks.append({"check": name, "elapsed_ms": elapsed})
        print(f"PASS {name} ({elapsed:.0f} ms)", flush=True)
        self.started = time.perf_counter()

    def query(self, scope="all", refresh=False, query=None, search_field="all"):
        if refresh:
            self.helper.request("refresh")
        response = self.helper.request("query", query=self.primary_label if query is None else query,
                                       scope=scope, search_field=search_field)
        require(response.get("search_field") == search_field, "Query did not echo its search field")
        return {row["id"]: row for row in response["rows"]}

    def directory(self, response, path):
        matches = [row for row in response["rows"]
                   if row.get("kind") == "directory" and row.get("path") == str(path)]
        require(len(matches) == 1 and matches[0].get("id"), "Expected exact directory row is missing: " + str(path))
        return matches[0]

    def check_directories(self, session):
        before_ids = {entry["session_id"] for entry in self.rex.sessions()}
        before_view = selection_state(self.rex.view(session))
        roots = self.helper.request("directories", reset=True, query=self.project.name, search_field="path")
        require(roots.get("directories_loaded") and roots.get("directories_base") is None
                and not roots.get("directories_deep") and roots.get("search_field") == "path",
                "Project roots did not expose the expected browser state/search field")
        project = self.directory(roots, self.project)
        preview = self.helper.request("preview", expected="preview", target_id=project["id"], lines=80)
        require(preview.get("target_id") == project["id"] and str(self.project) in preview.get("text", ""),
                "Directory preview did not use the selected cached path")
        shallow = self.helper.request("directories", base_id=project["id"], query="", search_field="name")
        require(shallow.get("directories_base") == str(self.project) and not shallow.get("directories_deep")
                and shallow.get("search_field") == "name", "Browsing did not retain the selected base/field")
        self.directory(shallow, self.nested_project.parent)
        require(not any(row.get("path") == str(self.nested_project) for row in shallow["rows"]),
                "Shallow browsing unexpectedly scanned a grandchild")
        deep = self.helper.request("directories", deep=True, query=self.nested_project.name, search_field="name")
        require(deep.get("directories_base") == str(self.project) and deep.get("directories_deep"),
                "Explicit deep search lost its selected base")
        self.directory(deep, self.nested_project)
        parent = self.helper.request("directories", parent=True, query=self.project.name, search_field="path")
        require(parent.get("directories_base") == str(self.scratch) and not parent.get("directories_deep"),
                "Parent navigation did not return to the exact containing directory")
        require(self.directory(parent, self.project)["id"] == project["id"], "Directory identity changed across navigation")
        reset = self.helper.request("directories", reset=True, query=self.project.name, search_field="all")
        require(reset.get("directories_base") is None and not reset.get("directories_deep"),
                "Reset did not restore recent projects/roots")
        self.directory(reset, self.project)
        rows = self.query(query="")
        recent = [row for row in rows.values() if row.get("kind") == "directory"]
        require(len(recent) == 1 and recent[0].get("path") == str(self.project),
                "All must retain its warm recent project without adding deep-scan descendants")
        require(selection_state(self.rex.view(session)) == before_view,
                "Directory discovery or preview changed tab/pane focus, zoom, or membership")
        require({entry["session_id"] for entry in self.rex.sessions()} == before_ids,
                "Read-only project browsing or preview created a session")
        self.passed("project roots, shallow/deep browsing, parent/reset, stable IDs, and read-only directory preview")

    def action(self, operation, target=None, expected="action_done", **fields):
        # Every non-create target must still belong to a recorded owned session.
        identities = set(self.owned)
        for session in self.owned:
            view = self.rex.view(session)
            identities.update(item["window_id"] for item in windows(view))
            identities.update(membership(view))
        if target is not None:
            require(target in identities, "Refusing an action outside disposable sessions")
            fields["target_id"] = target
        if "destination_id" in fields:
            require(fields["destination_id"] in identities, "Refusing a swap outside disposable sessions")
        return self.helper.request("action", expected=expected, operation=operation, **fields)

    def shell_ready(self, session, block):
        shells = {"sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "pwsh"}
        deadline, last, stable = time.monotonic() + 8, None, 0
        while time.monotonic() < deadline:
            process = self.rex.terminal(session, block, "process")
            foreground = process.get("foreground") or {}
            name = foreground.get("name", "").rsplit("/", 1)[-1].lstrip("-")
            identity = (foreground.get("pid"), name)
            stable = stable + 1 if identity == last else 0
            last = identity
            if name in shells and stable >= 4:
                return process
            time.sleep(.1)
        raise RuntimeError("Disposable shell did not become ready; no input was sent")

    def run(self, helper_path):
        # Prove client actions work before making sessions: project creation and
        # zoom both select a Rex app. The explicit restore is the only user target.
        self.rex.select(self.client, self.args.restore_session, self.args.restore_window)
        self.save_manifest()
        made = self.rex.command("new", self.primary_label, "-c", str(self.scratch), "--json")
        session = made["session_id"]
        self.record(session)
        initial = self.rex.view(session)
        require(len(windows(initial)) == 1 and len(panes(windows(initial)[0])) == 1, "Fresh session must contain one tab/pane")
        tab_a = windows(initial)[0]["window_id"]
        pane_a = panes(windows(initial)[0])[0]["block_id"]
        self.shell_ready(session, pane_a)

        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("REX_", "INTERDIMUX_"))}
        for key, directory in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state")):
            path = self.scratch / directory
            path.mkdir()
            environment[key] = str(path)
        environment.update(INTERDIMUX_REX_BIN=self.rex.executable, INTERDIMUX_STARTUP_COMMAND="",
                           INTERDIMUX_HYDRATE="off", INTERDIMUX_USE_ZOXIDE="off",
                           INTERDIMUX_PROJECT_DIRS=str(self.scratch))
        # A private history file exercises first-open recents without changing
        # the user's history or depending on zoxide/project scanning.
        history = Path(environment["XDG_DATA_HOME"]) / "interdimux/recent_dirs"
        history.parent.mkdir(parents=True)
        history.write_text(str(self.project) + "\n")
        require(environment.get("HOME") == os.environ.get("HOME"), "The live test must preserve HOME")
        self.helper = Helper(helper_path, environment, self.output / "helper.stderr.log")
        self.helper.request("open", context={"client_id": self.client, "session_id": session,
                                           "window_id": tab_a, "block_id": pane_a})
        for scope in ("all", "window", "pane"):
            rows = self.query(scope)
            require(tab_a in rows and rows[tab_a].get("combined") and rows[tab_a].get("pane_id") == pane_a,
                    "Single-pane tab must be combined in " + scope + " scope")
            require(pane_a not in rows, "Combined pane must not have a duplicate row")
        self.passed("combined tab identity and All/Tabs/Panes scopes")

        renamed = "literal 'quote' \"double\" 東京 λ " + self.token
        self.action("rename", tab_a, value=renamed)
        require(window(self.rex.view(session), tab_a).get("label") == renamed, "Rename did not preserve literal quotes/Unicode")
        self.query(refresh=True)
        before = self.rex.view(session)
        refused = self.action("close", tab_a, expected="error")
        require("Confirm" in refused.get("message", ""), "Unconfirmed close was not explicitly rejected")
        after = self.rex.view(session)
        require(membership(after) == membership(before) and window(after, tab_a).get("label") == renamed,
                "Rejected close changed the disposable tab")
        self.passed("literal tab rename and unconfirmed close rejection")
        self.check_directories(session)

        new_name = "second-tab-" + self.token
        self.action("new-window", tab_a, value=new_name)
        view = self.rex.view(session)
        created = [item for item in windows(view) if item["window_id"] != tab_a]
        require(len(created) == 1 and created[0].get("label") == new_name, "New tab ignored its submitted name")
        tab_b = created[0]["window_id"]
        pane_b = panes(created[0])[0]["block_id"]
        # session.new_window returns while login may still be starting. The
        # first metadata snapshot can correctly contain no working directory.
        process = self.shell_ready(session, pane_b)
        cwd = (process.get("foreground") or {}).get("cwd") or (process.get("child") or {}).get("cwd")
        require(cwd and Path(cwd).resolve() == self.scratch, "New tab did not inherit the selected working directory")
        self.query(refresh=True)
        require(tab_b in self.query(scope="window", query=new_name, search_field="name"),
                "Name search did not find the exact named tab")
        require(not self.query(scope="window", query=new_name, search_field="path"),
                "Path search matched a tab's name")
        require(not self.query(scope="window", query=new_name, search_field="command"),
                "Command search matched a tab's name")
        require(tab_b in self.query(scope="window", query=self.scratch.name, search_field="path"),
                "Path search did not find the disposable tab's working directory")
        self.query()
        self.passed("independent Name, Path, and Command search fields")
        prior = membership(view)
        self.action("split-right", tab_a)
        view = self.rex.view(session)
        additions = set(membership(view)) - set(prior)
        require(len(additions) == 1, "Split right did not add exactly one pane")
        extra_a = additions.pop()
        require(membership(view)[extra_a] == tab_a, "Split right used the wrong tab")
        rows = self.query(refresh=True)
        require(not rows[tab_a].get("combined") and pane_a in rows and extra_a in rows, "Split tab did not expand into exact pane rows")
        prior = membership(view)
        self.action("split-down", tab_b)
        view = self.rex.view(session)
        additions = set(membership(view)) - set(prior)
        require(len(additions) == 1, "Split down did not add exactly one pane")
        extra_b = additions.pop()
        require(membership(view)[extra_b] == tab_b, "Split down used the wrong tab")
        self.query(refresh=True)
        self.passed("new tab name and right/down split expansion")

        order = [item["window_id"] for item in windows(view)]
        self.action("swap", tab_a, destination_id=tab_b)
        view = self.rex.view(session)
        require([item["window_id"] for item in windows(view)] == list(reversed(order)), "Tab swap did not preserve exact IDs/order")
        self.query(refresh=True)
        prior = membership(view)
        self.action("swap", pane_a, destination_id=pane_b)
        view = self.rex.view(session)
        expected = dict(prior)
        expected[pane_a], expected[pane_b] = prior[pane_b], prior[pane_a]
        require(membership(view) == expected, "Pane swap changed unexpected membership")
        self.query(refresh=True)
        self.passed("same-session tab and pane swaps preserve exact membership")

        self.shell_ready(session, pane_a)
        sentinel = "IMUX_NATIVE_SENTINEL_" + self.token
        self.action("send", pane_a, value="printf '%s\\n' '" + sentinel + "'")
        before_preview = selection_state(self.rex.view(session))
        deadline = time.monotonic() + 5
        while True:
            preview = self.helper.request("preview", expected="preview", target_id=pane_a, lines=200)
            require(preview.get("target_id") == pane_a and len(preview.get("text", "").splitlines()) <= 200,
                    "Read-only preview returned the wrong target or exceeded its line bound")
            if sentinel in [line.strip() for line in preview.get("text", "").splitlines()]:
                break
            require(time.monotonic() < deadline, "Preview never showed the executed printf sentinel")
            time.sleep(.1)
        other = self.action("preview", pane_b, lines=200)
        require(sentinel not in other.get("text", ""), "Exact-pane send reached another pane")
        require(selection_state(self.rex.view(session)) == before_preview,
                "Read-only terminal preview changed focus, zoom, or pane membership")
        self.passed("harmless exact-pane send, bounded read-only preview, and unchanged terminal selection")

        zoom_tab = membership(self.rex.view(session))[pane_a]
        self.action("zoom", pane_a)
        require(window(self.rex.view(session), zoom_tab).get("zoomed_block_id") == pane_a, "Zoom selected the wrong pane")
        self.action("zoom", pane_a)
        require(not window(self.rex.view(session), zoom_tab).get("zoomed_block_id"), "Second zoom did not restore the layout")
        self.passed("client selection and zoom toggle")

        # After the swap each tab has one original pane and its own new split.
        self.action("close", extra_a, confirmed=True)
        rows = self.query(refresh=True)
        require(rows[tab_a].get("combined") and rows[tab_a].get("pane_id") == pane_b,
                "Closing a split did not collapse its exact remaining pane")
        self.action("close", extra_b, confirmed=True)
        rows = self.query(refresh=True)
        require(rows[tab_b].get("combined") and rows[tab_b].get("pane_id") == pane_a,
                "Second tab did not collapse correctly")
        self.action("close", tab_b, confirmed=True)
        view = self.rex.view(session)
        require([item["window_id"] for item in windows(view)] == [tab_a]
                and membership(view) == {pane_b: tab_a}, "Combined-row close did not close exactly its tab")
        self.query(refresh=True)
        self.passed("confirmed pane/tab closes and single-pane recollapse")

        before_ids = {entry["session_id"] for entry in self.rex.sessions()}
        try:
            main_projects = self.helper.request("query", query=self.project.name, scope="all", search_field="all")
            recent_project = self.directory(main_projects, self.project)
            require(not recent_project.get("context_only") and not main_projects.get("can_create"),
                    "A recent project must be selectable directly from the main search")
            live_matches = [row["id"] for row in main_projects["rows"]
                            if row.get("kind") != "directory" and not row.get("context_only")]
            require(main_projects.get("preferred_id") in (live_matches or [recent_project["id"]]),
                    "Main search must prefer matching live targets before projects")
            self.helper.request("activate", expected="activated", target_id=recent_project["id"])
        finally:
            self.recover_created()
        after = self.rex.sessions()
        project_ids = [entry["session_id"] for entry in after if entry.get("label") == self.project.name
                       and entry["session_id"] not in before_ids]
        require(len(project_ids) == 1 and project_ids[0] in self.owned, "Project creation did not yield exactly one recorded owned session")
        project_id = project_ids[0]
        project_view = self.rex.view(project_id)
        require(len(windows(project_view)) == 1, "Project must start with one default tab")
        project_window = windows(project_view)[0]
        require(project_window.get("label") != "Terminal", "Project creation forcibly named its tab Terminal")
        process = self.shell_ready(project_id, panes(project_window)[0]["block_id"])
        cwd = (process.get("foreground") or {}).get("cwd") or (process.get("child") or {}).get("cwd")
        require(cwd and Path(cwd).resolve() == self.project, "Project shell started in the wrong directory")
        self.helper.request("refresh")
        before_reuse = {entry["session_id"] for entry in self.rex.sessions()}
        self.action("create-session", value=str(self.project))
        require({entry["session_id"] for entry in self.rex.sessions()} == before_reuse,
                "Reopening an existing project created another session")
        project_rows = self.helper.request("directories", reset=True, query=self.project.name, search_field="all")
        project_row = self.directory(project_rows, self.project)
        require(project_row.get("path") == str(self.project), "Refusing activation outside the disposable project")
        self.helper.request("activate", expected="activated", target_id=project_row["id"])
        require({entry["session_id"] for entry in self.rex.sessions()} == before_reuse,
                "Activating the exact project directory created a duplicate session")
        self.passed("main-search recent project activation, default tab title, create-action reuse, and exact directory reuse")

        # Query-only creation must be an explicit, exact current result choice,
        # never an editable client-supplied command or a stale query ID.
        before_query_ids = {entry["session_id"] for entry in self.rex.sessions()}
        old = self.helper.request("query", query=self.query_label + "-old", scope="all", search_field="name")
        fresh = self.helper.request("query", query=self.query_label, scope="all", search_field="name")
        require(old.get("can_create") and fresh.get("can_create")
                and old.get("preferred_id") != fresh.get("preferred_id")
                and fresh["rows"][0].get("kind") == "create",
                "Unmatched main query did not expose a generation-bound creation choice")
        self.helper.request("activate", expected="error", target_id=old["preferred_id"])
        require({entry["session_id"] for entry in self.rex.sessions()} == before_query_ids,
                "A stale create choice changed Rex sessions")
        try:
            self.helper.request("activate", expected="activated", target_id=fresh["preferred_id"])
        finally:
            self.recover_created()
        created = [entry["session_id"] for entry in self.rex.sessions()
                   if entry.get("label") == self.query_label and entry["session_id"] not in before_query_ids]
        require(len(created) == 1 and created[0] in self.owned,
                "Enter on the unmatched main query did not create exactly one owned session")
        after_query_ids = {entry["session_id"] for entry in self.rex.sessions()}
        self.helper.request("activate", expected="error", target_id=fresh["preferred_id"])
        require({entry["session_id"] for entry in self.rex.sessions()} == after_query_ids,
                "A consumed create choice created a duplicate session")
        self.helper.request("refresh")
        existing = self.helper.request("query", query=self.query_label, scope="all", search_field="name")
        require(not existing.get("can_create") and created[0] in {row["id"] for row in existing["rows"]},
                "A newly created session was not preferred to another creation choice")
        self.passed("main-search Enter creates once; stale and consumed create IDs cannot mutate sessions")

    def cleanup(self):
        errors = []
        if self.helper:
            try:
                self.helper.stop()
            except Exception as error:
                errors.append("helper shutdown: " + str(error))
        try:
            self.recover_created()
        except Exception as error:
            errors.append("recover created IDs: " + str(error))
        try:
            self.rex.select(self.client, self.args.restore_session, self.args.restore_window)
        except Exception as error:
            errors.append("restore explicit original session: " + str(error))
        for session in reversed(self.owned):
            try:
                require(session not in self.initial_ids and session != self.args.restore_session,
                        "Cleanup refused a non-owned session")
                existing = {entry["session_id"] for entry in self.rex.sessions()}
                if session in existing:
                    self.rex.api("session.destroy", session_id=session)
            except Exception as error:
                errors.append("cleanup " + session + ": " + str(error))
        try:
            remaining = set(self.owned) & {entry["session_id"] for entry in self.rex.sessions()}
            require(not remaining, "Owned sessions remain: " + ", ".join(sorted(remaining)))
        except Exception as error:
            errors.append(str(error))
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-live", action="store_true", help="explicitly create disposable sessions and exercise live actions")
    parser.add_argument("--restore-session", help="required full original session ID to select during cleanup")
    parser.add_argument("--restore-window", help="optional exact original window ID")
    parser.add_argument("--client", help="full local macOS app client ID; otherwise require exactly one")
    parser.add_argument("--rex", help="path to the installed Rex CLI")
    parser.add_argument("--helper", type=Path, default=MACOS / "build/Interdimux Picker.app/Contents/Helpers/imux")
    parser.add_argument("--output", type=Path, help="directory for timings, helper stderr, and owned-session manifest")
    args = parser.parse_args()
    if not args.run_live:
        parser.error("this test mutates disposable Rex sessions; pass --run-live explicitly")
    if not args.restore_session or not args.restore_session.startswith("session:"):
        parser.error("--restore-session must name the full original session ID")
    if sys.platform != "darwin":
        parser.error("live native picker checks require macOS")
    if os.environ.get("REX_SERVER"):
        parser.error("remote/custom REX_SERVER is unsupported; use the local default Rex server")
    helper_path = args.helper.expanduser().resolve()
    if not helper_path.is_file():
        parser.error("bundled helper is missing; run ./macos/build.sh first")
    rex = Rex(rex_binary(args.rex))
    clients = [item for item in rex.api("client.list", kinds=["app"]).get("clients") or [] if local_app(item)]
    if args.client:
        clients = [item for item in clients if item.get("client_id") == args.client]
    if len(clients) != 1:
        parser.error("choose one connected local macOS app with --client <full client ID>")
    output = (args.output or MACOS / "build" / ("live-actions-" + uuid.uuid4().hex[:12])).resolve()
    output.mkdir(parents=True, exist_ok=True)
    def interrupted(signum, frame):
        raise InterruptedError("Interrupted; cleaning up disposable sessions")
    signal.signal(signal.SIGTERM, interrupted)
    failure = None
    with tempfile.TemporaryDirectory(prefix="interdimux-native-live-") as directory:
        test = LiveActions(args, rex, clients[0]["client_id"], Path(directory).resolve(), output)
        try:
            test.run(helper_path)
        except (Exception, KeyboardInterrupt) as error:
            failure = str(error) or "Interrupted"
            print("FAIL " + failure, file=sys.stderr, flush=True)
        finally:
            cleanup_errors = test.cleanup()
            report = {"checks": test.checks, "helper": str(helper_path), "failure": failure,
                      "cleanup_errors": cleanup_errors, "restore_session": args.restore_session,
                      "owned_session_ids": test.owned, "requests": test.helper.timings if test.helper else []}
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            for error in cleanup_errors:
                print("CLEANUP ERROR " + error, file=sys.stderr)
    print("Report: " + str(output / "report.json"), flush=True)
    if failure or cleanup_errors:
        return 1
    print(f"PASS {len(test.checks)} live checks; owned sessions removed and explicit original session restored", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        print("Live picker test: " + str(error), file=sys.stderr)
        sys.exit(1)
