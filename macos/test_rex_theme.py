#!/usr/bin/env python3
"""Check Rex appearance/palette resolution and cross-file cache invalidation."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift theme checks require macOS.")
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="interdimux-theme-tests-") as directory:
        binary = Path(directory) / "theme-tests"
        subprocess.run(["xcrun", "swiftc", str(root / "Sources/RexTheme.swift"),
                        str(root / "Tests/RexThemeTests.swift"), "-framework", "AppKit",
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
