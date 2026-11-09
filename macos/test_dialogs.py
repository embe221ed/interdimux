#!/usr/bin/env python3
"""Exercise real offscreen confirmation sheets with app-local keyboard events."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift dialog checks require macOS.")
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="interdimux-dialog-tests-") as directory:
        binary = Path(directory) / "dialog-tests"
        subprocess.run([
            "xcrun", "swiftc", str(root / "Sources/PickerDialogs.swift"),
            str(root / "Tests/PickerDialogTests.swift"), "-framework", "AppKit", "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    main()
