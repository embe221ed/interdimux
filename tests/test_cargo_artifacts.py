#!/usr/bin/env python3
"""Build tiny real Cargo fixtures through both helper build entry points."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
CARGO = shutil.which("cargo")


@unittest.skipUnless(CARGO, "cargo is required for artifact build checks")
class CargoArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="interdimux-artifacts-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.rust = self.root / "rust"
        self.shims = self.root / "bin"
        (self.rust / "src").mkdir(parents=True)
        (self.root / "macos/Sources").mkdir(parents=True)
        self.shims.mkdir()
        shutil.copy2(REPO / "interdimux.tmux", self.root)
        shutil.copy2(REPO / "macos/build.sh", self.root / "macos/build.sh")
        (self.root / "macos/Info.plist").write_text("stub plist\n")
        (self.root / "macos/Sources/main.swift").write_text("// stubbed Swift build\n")
        (self.rust / "Cargo.toml").write_text(
            '[package]\nname="imux"\nversion="0.0.0"\nedition="2021"\n'
            '[features]\nmacos-picker=[]\n'
        )
        (self.rust / "src/main.rs").write_text('fn main() { println!("NEW_HELPER"); }\n')
        self.env = os.environ.copy()
        for name in ["CARGO_BUILD_TARGET", "CARGO_TARGET_DIR", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS",
                     "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER", "INTERDIMUX_BIN", "INTERDIMUX_USE_RUST"]:
            self.env.pop(name, None)
        self.env["PATH"] = str(self.shims) + os.pathsep + self.env["PATH"]
        self.env["XDG_STATE_HOME"] = str(self.root / "state")
        self.env["CARGO_TARGET_DIR"] = str(self.root / "unrelated-target")
        self.host = next(line[6:] for line in self.command([CARGO, "--version", "--verbose"]).stdout.splitlines()
                         if line.startswith("host: "))
        self.command([CARGO, "generate-lockfile", "--offline", "--manifest-path", str(self.rust / "Cargo.toml")])
        self.binary = self.rust / "target/release/imux"
        # Only Swift/plist and platform gating are stubbed. Cargo compiles the
        # actual helper fixture, including config/environment target handling.
        self.script("uname", '#!/bin/sh\nif [ "$1" = -s ]; then echo Darwin; else /usr/bin/uname "$@"; fi\n')
        self.script("xcrun", '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n'
                    '  if [ "$1" = -o ]; then shift; printf "#!/bin/sh\\nexit 0\\n" > "$1"; chmod +x "$1"; exit; fi\n'
                    '  shift\ndone\nexit 1\n')
        self.script("plutil", "#!/bin/sh\nexit 0\n")
        self.script("tmux", "#!/bin/sh\nexit 0\n")

    def script(self, name, source):
        path = self.shims / name
        path.write_text(source)
        path.chmod(0o700)

    def command(self, args, check=True):
        return subprocess.run(args, cwd=self.root, env=self.env, text=True,
                              capture_output=True, check=check, timeout=60)

    def build(self, entry):
        path = self.root / ("macos/build.sh" if entry == "native" else "interdimux.tmux")
        return self.command(["bash", str(path)] + ([] if entry == "native" else ["--autobuild"]), check=False)

    def stale_binary(self):
        self.binary.parent.mkdir(parents=True, exist_ok=True)
        self.binary.write_text("#!/bin/sh\necho OLD_HELPER\n")
        self.binary.chmod(0o700)
        os.utime(self.binary, (1, 1))

    def check_build(self, entry, target_source, stale):
        config = self.root / ".cargo/config.toml"
        config.parent.mkdir(exist_ok=True)
        config.write_text("[build]\ntarget=" + repr(self.host) + "\n")
        if target_source == "environment":
            config.unlink()
            self.env["CARGO_BUILD_TARGET"] = self.host
        elif target_source == "foreign":
            config.write_text('[build]\ntarget="not-a-real-config-target"\n')
            self.env["CARGO_BUILD_TARGET"] = "not-a-real-environment-target"
        if stale:
            self.stale_binary()
        result = self.build(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        published = self.root / "macos/build/Interdimux Picker.app/Contents/Helpers/imux" if entry == "native" else self.binary
        self.assertTrue(published.is_file(), result.stdout + result.stderr)
        self.assertEqual(self.command([str(published)]).stdout.strip(), "NEW_HELPER")
        self.assertEqual(self.command([str(self.binary)]).stdout.strip(), "NEW_HELPER")
        self.assertTrue((self.rust / "target" / self.host / "release/imux").is_file())
        self.assertFalse((self.root / "unrelated-target").exists())
        if entry == "autobuild":
            log = (self.root / "state/interdimux/build.log").read_text()
            self.assertTrue(log.endswith("== ok\n"), log)
            self.assertFalse((self.rust / "target/.interdimux-autobuild.failed").exists())

    def test_explicit_host_artifact_replaces_stale_or_missing_default(self):
        # Each case gets an independent Cargo target directory, so an artifact
        # from a preceding successful case cannot hide a wrong output lookup.
        for entry in ["native", "autobuild"]:
            for target_source in ["config", "environment", "foreign"]:
                for stale in [False, True]:
                    with self.subTest(entry=entry, target_source=target_source, stale=stale):
                        fixture = CargoArtifactTests()
                        fixture.setUp()
                        try:
                            fixture.check_build(entry, target_source, stale)
                        finally:
                            fixture.doCleanups()

    def test_missing_host_artifact_does_not_refresh_previous_binary(self):
        for entry in ["native", "autobuild"]:
            with self.subTest(entry=entry):
                self.stale_binary()
                self.script("cargo", '#!/bin/sh\nif [ "$1" = --version ]; then exec ' +
                            "'" + CARGO.replace("'", "'\\''") + "'" + ' "$@"; fi\nexit 0\n')
                before = self.binary.stat().st_mtime_ns
                result = self.build(entry)
                self.assertEqual(self.command([str(self.binary)]).stdout.strip(), "OLD_HELPER")
                self.assertEqual(self.binary.stat().st_mtime_ns, before)
                if entry == "native":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((self.root / "macos/build/Interdimux Picker.app").exists())
                else:
                    log = (self.root / "state/interdimux/build.log").read_text()
                    self.assertIn("== failed", log)
                    self.assertNotIn("== ok", log)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CargoArtifactTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failures = len(result.failures) + len(result.errors)
    passed = max(0, result.testsRun - failures - len(result.skipped))
    print(f"Results: {passed} passed, {failures} failed")
    for _, reason in result.skipped:
        print(f"  (skipped: {reason})")
    raise SystemExit(not result.wasSuccessful())
