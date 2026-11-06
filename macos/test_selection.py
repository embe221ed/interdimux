#!/usr/bin/env python3
"""Check result selection on changing searches and same-query refreshes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="interdimux-selection-") as directory:
    binary = Path(directory) / "selection-tests"
    subprocess.run(["xcrun", "swiftc", str(root / "Sources/Backend.swift"),
                    str(root / "Sources/PickerSelection.swift"),
                    str(root / "Tests/SelectionTests.swift"), "-framework", "AppKit", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
