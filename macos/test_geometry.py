#!/usr/bin/env python3
"""Compile and check native picker geometry without creating an app or window."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift geometry checks require macOS.")
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="interdimux-geometry-tests-") as directory:
        binary = Path(directory) / "geometry-tests"
        sources = ["Backend.swift", "TreeLayout.swift", "PickerView.swift", "PickerPreviewView.swift"]
        subprocess.run([
            "xcrun", "swiftc", *[str(root / "Sources" / source) for source in sources],
            str(root / "Tests/PickerGeometryTests.swift"), "-framework", "AppKit", "-o", str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
