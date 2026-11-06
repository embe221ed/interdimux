#!/usr/bin/env python3
"""Compile and run native tree geometry regressions without opening AppKit UI."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift tree checks require macOS.")
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="interdimux-tree-tests-") as directory:
        binary = Path(directory) / "tree-tests"
        subprocess.run([
            "xcrun", "swiftc", str(root / "Sources/Backend.swift"),
            str(root / "Sources/TreeLayout.swift"), str(root / "Tests/TreeLayoutTests.swift"),
            "-framework", "AppKit", "-o", str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
