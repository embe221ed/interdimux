#!/usr/bin/env python3
"""Compile the controller's real response router and test it without AppKit/UI."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift response-routing checks require macOS.")
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="interdimux-response-tests-") as directory:
        binary = Path(directory) / "response-tests"
        subprocess.run([
            "xcrun", "swiftc", str(root / "Sources/PickerResponseRouting.swift"),
            str(root / "Tests/ResponseRoutingTests.swift"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
