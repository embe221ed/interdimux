#!/usr/bin/env python3
"""Launcher checks with synthetic clients and mocked processes; never opens UI."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

SOURCE = (Path(__file__).parent / "open.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
CODE = compile(SOURCE, "open.sh embedded Python", "exec")


def app(client_id="client:local"):
    return {"client_id": client_id, "info": {"platform": "macos"},
            "principal": {"kind": "peer", "transport": "unix"}}


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="interdimux launch '")
        self.addCleanup(self.temp.cleanup)
        self.macos = Path(self.temp.name) / "macos"
        self.macos.mkdir()

    def launch(self, args=(), clients=None, env=None, platform="darwin"):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", ["open.sh", str(self.macos), *args]), \
                patch.object(sys, "platform", platform), \
                patch.dict(os.environ, env or {}, clear=True), \
                patch("shutil.which", return_value="/fake/rex"), \
                patch("subprocess.check_output", return_value=json.dumps({"clients": clients if clients is not None else [app()]})) as query, \
                patch("subprocess.run") as run, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = 0
            try:
                exec(CODE, {})
            except SystemExit as error:
                status = error.code
            return status, output.getvalue(), errors.getvalue(), query.call_args_list, run.call_args_list

    def built(self):
        bundle = self.macos / "build/Interdimux Picker.app/Contents"
        for name in ("MacOS/InterdimuxPicker", "Helpers/imux", "Resources/build-stamp"):
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        return bundle

    def test_context_is_url_encoded_without_shell_interpolation(self):
        hostile = "session:a & b/é?$(touch nope)#fragment"
        status, out, _, _, calls = self.launch(["--client", "client:local", "--session", hostile, "--window", "window:+", "--block", "block:[]", "--print-url"])
        self.assertEqual(status, 0)
        self.assertEqual(parse_qs(urlsplit(out.strip()).query), {"client_id": ["client:local"], "session_id": [hostile], "window_id": ["window:+"], "block_id": ["block:[]"]})
        self.assertFalse(calls)

    def test_standalone_launch_discovers_only_the_app(self):
        status, out, _, _, _ = self.launch(["--print-url"])
        self.assertEqual(status, 0)
        self.assertEqual(parse_qs(urlsplit(out.strip()).query), {"client_id": ["client:local"]})

    def test_dashboard_preserves_encoded_context_and_explicit_app(self):
        hostile = "session:a & b/é?$(touch nope)#fragment"
        status, out, _, queries, calls = self.launch(["--dashboard", "--client", "client:local",
            "--session", hostile, "--window", "window:+", "--block", "block:[]", "--print-url"])
        self.assertEqual(status, 0)
        url = urlsplit(out.strip())
        self.assertEqual(url.netloc, "dashboard")
        self.assertEqual(parse_qs(url.query), {"client_id": ["client:local"], "session_id": [hostile],
                                            "window_id": ["window:+"], "block_id": ["block:[]"]})
        self.assertEqual(len(queries), 1)
        self.assertFalse(calls)

    def test_dashboard_launch_uses_same_bundle_and_local_guard(self):
        bundle = self.built()
        status, _, _, _, calls = self.launch(["--dashboard"])
        self.assertEqual(status, 0)
        self.assertEqual(calls[0].args[0], ["/usr/bin/open", "-g", "-a", str(bundle.parent),
                                          "interdimux-picker://dashboard?client_id=client%3Alocal"])
        remote = app(); remote["principal"]["path"] = ["remote"]
        status, _, error, _, calls = self.launch(["--dashboard"], [remote])
        self.assertEqual(status, 2)
        self.assertIn("local Rex app", error)
        self.assertFalse(calls)

    def test_ambiguous_remote_and_nonmac_clients_fail(self):
        remote = app(); remote["principal"]["path"] = ["login-server"]
        ios = app(); ios["info"]["platform"] = "ios"
        lost = app(); lost["connection_state"] = "lost"
        for clients in ([], [app(), app("client:other")], [remote], [ios], [lost]):
            with self.subTest(clients=clients):
                status, _, error, _, calls = self.launch(["--print-url"], clients)
                self.assertEqual(status, 2)
                self.assertIn("local Rex app", error)
                self.assertFalse(calls)

    def test_existing_bundle_preserves_origin_while_launching_exact_app(self):
        bundle = self.built()
        status, _, _, _, calls = self.launch()
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[0], ["/usr/bin/open", "-g", "-a", str(bundle.parent), "interdimux-picker://open?client_id=client%3Alocal"])

    def test_missing_bundle_builds_once_before_open(self):
        status, _, _, _, calls = self.launch()
        self.assertEqual(status, 0)
        self.assertEqual(calls[0].args[0], [str(self.macos / "build.sh")])
        self.assertEqual(calls[1].args[0][0], "/usr/bin/open")

    def test_check_build_never_contacts_rex_or_opens_ui(self):
        status, _, _, queries, calls = self.launch(["--check-build"])
        self.assertEqual(status, 2)
        self.assertFalse(queries or calls)
        self.built()
        status, _, _, queries, calls = self.launch(["--check-build"])
        self.assertEqual(status, 0)
        self.assertFalse(queries or calls)

    def test_stale_sources_report_rebuild_instead_of_launching(self):
        bundle = self.built()
        source = self.macos / "Info.plist"
        source.touch()
        stamp = bundle / "Resources/build-stamp"
        os.utime(stamp, ns=(1, 1))
        status, _, error, _, calls = self.launch()
        self.assertEqual(status, 2)
        self.assertIn("bundle is stale", error)
        self.assertIn("build.sh", error)
        self.assertFalse(calls)

    def test_nonmac_and_custom_server_fail_before_rpc(self):
        for kwargs in ({"platform": "linux"}, {"env": {"REX_SERVER": "remote"}}):
            status, _, _, queries, calls = self.launch(**kwargs)
            self.assertEqual(status, 2)
            self.assertFalse(queries or calls)

    def test_changed_vendored_matcher_requires_rebuild(self):
        bundle = self.built()
        source = self.macos.parent / "rust/vendor/nucleo-matcher/src/exact.rs"
        source.parent.mkdir(parents=True)
        source.write_text("// changed matcher\n")
        stamp = bundle / "Resources/build-stamp"
        newer = stamp.stat().st_mtime_ns + 1_000_000
        os.utime(source, ns=(newer, newer))
        status, _, error, queries, calls = self.launch(["--check-build"])
        self.assertEqual(status, 2)
        self.assertIn("bundle is stale", error)
        self.assertFalse(queries or calls)


if __name__ == "__main__":
    unittest.main()
