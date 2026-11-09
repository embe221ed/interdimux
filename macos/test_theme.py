#!/usr/bin/env python3
"""Check and optionally render theme changes on existing native picker views."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift theme checks require macOS.")
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Keep dark, light and custom theme PNGs here")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="interdimux-theme-tests-") as directory:
        binary = Path(directory) / "theme-tests"
        sources = ["Backend.swift", "TreeLayout.swift", "PickerView.swift", "PickerPreviewView.swift",
                   "DashboardModel.swift", "DashboardView.swift"]
        subprocess.run([
            "xcrun", "swiftc", *[str(root / "Sources" / source) for source in sources],
            str(root / "Tests/ThemeTests.swift"), "-framework", "AppKit", "-o", str(binary)
        ], check=True)
        command = [str(binary)]
        if args.output:
            command.append(str(args.output.resolve()))
        subprocess.run(command, check=True, timeout=20)


if __name__ == "__main__":
    main()
