#!/usr/bin/env python3
"""Measure native row transitions and CPU painting without presenting a window."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--view-sources", type=Path, default=root / "Sources")
    parser.add_argument("--mode", choices=["reload", "note"], default="reload")
    parser.add_argument("--runs", type=int, default=1)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    with tempfile.TemporaryDirectory(prefix="interdimux-render-bench-") as directory:
        binary = Path(directory) / "render-bench"
        sources = [root / "Sources/Backend.swift", root / "Sources/TreeLayout.swift",
                   args.view_sources / "PickerView.swift", args.view_sources / "PickerPreviewView.swift",
                   root / "Tests/RenderBenchmark.swift"]
        subprocess.run(["xcrun", "swiftc", "-O", *map(str, sources), "-framework", "AppKit", "-o", str(binary)], check=True)
        reports = []
        for _ in range(args.runs):
            result = subprocess.run([str(binary), args.mode], check=True, timeout=30, capture_output=True, text=True)
            reports.append(json.loads(result.stdout))
        print(json.dumps(reports[0] if len(reports) == 1 else reports, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
