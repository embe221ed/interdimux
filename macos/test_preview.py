#!/usr/bin/env python3
"""Test the native preview scheduler deterministically, without AppKit or Rex."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift preview checks require macOS.")
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="interdimux-preview-tests-") as directory:
        binary = Path(directory) / "preview-tests"
        subprocess.run([
            "xcrun", "swiftc", str(root / "Sources/PickerPreviewGate.swift"),
            str(root / "Tests/PreviewGateTests.swift"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
