#!/usr/bin/env python3
"""Render actual picker views to PNG without opening or activating a window."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Native fixture rendering requires macOS.")
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=root / "Tests/fixtures/projects.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="interdimux-render-fixture-") as directory:
        binary = Path(directory) / "render-fixture"
        sources = ["Backend.swift", "TreeLayout.swift", "PickerView.swift", "PickerPreviewView.swift"]
        subprocess.run([
            "xcrun", "swiftc", *[str(root / "Sources" / source) for source in sources],
            str(root / "Tests/RenderFixture.swift"), "-framework", "AppKit", "-o", str(binary)
        ], check=True)
        subprocess.run([str(binary), str(args.fixture.resolve()), str(args.output.resolve())], check=True, timeout=30)


if __name__ == "__main__":
    main()
