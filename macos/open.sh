#!/bin/bash
set -euo pipefail
macos_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The launcher uses only the standard library. Prefer the system interpreter
# over potentially expensive shell/version-manager shims on the hotkey path.
python=/usr/bin/python3
if [[ ! -x "$python" ]]; then python=$(command -v python3); fi
exec "$python" - "$macos_dir" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from urllib.parse import urlencode, quote


def bundle(macos, parser, build_missing):
    app = macos / "build/Interdimux Picker.app"
    executable = app / "Contents/MacOS/InterdimuxPicker"
    helper = app / "Contents/Helpers/imux"
    stamp = app / "Contents/Resources/build-stamp"
    instruction = "quit the app with Cmd+Q, then run " + shlex.quote(str(macos / "build.sh"))
    if not executable.is_file() or not helper.is_file():
        if not build_missing:
            parser.error("build the native picker first: " + instruction)
        subprocess.run([str(macos / "build.sh")], check=True)
    else:
        root = macos.parent
        sources = [macos / "build.sh", macos / "Info.plist", root / "rust/Cargo.toml", root / "rust/Cargo.lock",
                   root / "integrations/rex_operations.lua", root / "scripts/interdimux-list.sh"]
        sources.extend((macos / "Sources").glob("*.swift"))
        sources.extend((root / "rust/src").rglob("*.rs"))
        sources.extend((root / "rust/src").rglob("*.lua"))
        sources.extend((root / "rust/vendor").rglob("*.rs"))
        sources.extend((root / "rust/vendor").rglob("Cargo.toml"))
        stamped = stamp.stat().st_mtime_ns if stamp.is_file() else 0
        if not stamped or any(path.stat().st_mtime_ns > stamped for path in sources if path.is_file()):
            parser.error("the app bundle is stale; " + instruction)
    return app


def main():
    macos = Path(sys.argv[1])
    parser = argparse.ArgumentParser(description="Open the experimental native Interdimux picker on this Mac.")
    for name in ("client", "session", "window", "block"):
        parser.add_argument("--" + name, default=os.environ.get("REX_" + name.upper()))
    parser.add_argument("--dashboard", action="store_true", help="open the native dashboard instead of the picker")
    parser.add_argument("--print-url", action="store_true", help="validate the target and print its URL without building or opening the app")
    parser.add_argument("--check-build", action="store_true", help="check that the bundle exists and is current, without contacting Rex or opening a window")
    args = parser.parse_args(sys.argv[2:])
    if sys.platform != "darwin":
        parser.error("the native picker requires macOS 13 or later")
    if args.check_build:
        bundle(macos, parser, build_missing=False)
        return
    if os.environ.get("REX_SERVER"):
        parser.error("remote/custom REX_SERVER launch is unsupported; use the local default Rex server")

    rex = os.environ.get("INTERDIMUX_REX_BIN") or shutil.which("rex")
    if not rex:
        for base in (Path("/Applications"), Path.home() / "Applications"):
            for name in ("Rex Beta.app", "Rex.app"):
                candidate = base / name / "Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
                if candidate.is_file():
                    rex = str(candidate)
                    break
            if rex:
                break
    if not rex:
        parser.error("cannot find Rex; set INTERDIMUX_REX_BIN to its CLI path")
    command = [rex, "--autostart=false", "--color=never", "--timeout=5s", "api", "call", "client.list", '{"kinds":["app"]}']
    listed = json.loads(subprocess.check_output(command, text=True, timeout=10))
    clients = []
    for client in listed.get("clients") or []:
        principal = client.get("principal") or {}
        if (client.get("connection_state") != "lost"
                and (client.get("info") or {}).get("platform") == "macos"
                and principal.get("kind") == "peer" and principal.get("transport") == "unix"
                and not principal.get("path")):
            clients.append(client)
    if args.client:
        clients = [client for client in clients if client.get("client_id") == args.client]
    if len(clients) != 1:
        parser.error("choose a connected local Rex app with --client <full app ID>; remote app launch is unsupported")
    context = {"client_id": clients[0]["client_id"]}
    for name in ("session", "window", "block"):
        value = getattr(args, name)
        if value:
            context[name + "_id"] = value
    host = "dashboard" if args.dashboard else "open"
    url = "interdimux-picker://" + host + "?" + urlencode(context, quote_via=quote, safe="")
    if args.print_url:
        print(url)
        return

    app = bundle(macos, parser, build_missing=True)
    # The nonactivating panel takes keyboard focus itself. Keep Rex frontmost
    # until URL delivery so the picker can remember where to return on Escape.
    subprocess.run(["/usr/bin/open", "-g", "-a", str(app), url], check=True)


try:
    main()
except (OSError, ValueError, subprocess.SubprocessError) as error:
    print("Interdimux native picker: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
