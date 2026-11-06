#!/usr/bin/env python3
"""Check bounded wraparound selection and dashboard routing without a window."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="interdimux-navigation-") as directory:
    binary = Path(directory) / "navigation-tests"
    subprocess.run(["xcrun", "swiftc", str(root / "Sources/PickerNavigation.swift"),
                    str(root / "Tests/NavigationTests.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
