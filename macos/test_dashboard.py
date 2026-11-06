#!/usr/bin/env python3
"""Check native dashboard behavior and optionally render offscreen fixture PNGs."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="interdimux-dashboard-tests-") as directory:
        binary = Path(directory) / "dashboard-tests"
        sources = sorted(path for path in (root / "Sources").glob("*.swift") if path.name != "main.swift")
        subprocess.run(["xcrun", "swiftc", *map(str, sources), str(root / "Tests/DashboardTests.swift"),
                        "-framework", "AppKit", "-o", str(binary)], check=True)
        subprocess.run([str(binary), *([str(args.capture.resolve())] if args.capture else [])], check=True, timeout=20)


if __name__ == "__main__":
    main()
