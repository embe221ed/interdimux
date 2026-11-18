#!/usr/bin/env python3
"""Measure offscreen AppKit picker, dashboard, and preview layout and CPU painting."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--view-sources", type=Path, default=root / "Sources")
    parser.add_argument("--mode", choices=["reload", "note", "dashboard", "preview"], default="reload")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--compact", action="store_true", help="Use a 680 × 560 picker or dashboard window.")
    args = parser.parse_args()
    if args.compact and args.mode == "preview":
        parser.error("preview mode uses the preview column width")
    if args.runs < 1:
        parser.error("--runs must be positive")
    with tempfile.TemporaryDirectory(prefix="interdimux-render-bench-") as directory:
        binary = Path(directory) / "render-bench"
        names = ["Backend.swift", "TreeLayout.swift", "PickerView.swift", "PickerPreviewView.swift"]
        benchmark = "RenderBenchmark.swift"
        if args.mode in ("dashboard", "preview"):
            names += ["DashboardView.swift", "DashboardModel.swift", "PickerNavigation.swift"]
            benchmark = "SurfaceRenderBenchmark.swift"
        sources = []
        for name in names:
            path = args.view_sources / name
            # Older comparisons supplied only the two alternate picker views.
            if not path.exists() and name not in ("PickerView.swift", "PickerPreviewView.swift"):
                path = root / "Sources" / name
            sources.append(path)
        sources += [root / "Tests/RenderBenchmarkSupport.swift", root / "Tests" / benchmark]
        subprocess.run(["xcrun", "swiftc", "-O", "-whole-module-optimization", *map(str, sources),
                        "-framework", "AppKit", "-o", str(binary)], check=True)
        command = [str(binary), args.mode]
        if args.compact:
            command.append("--compact")
        reports = []
        for _ in range(args.runs):
            result = subprocess.run(command, check=True, timeout=30, capture_output=True, text=True)
            reports.append(json.loads(result.stdout))
        print(json.dumps(reports[0] if len(reports) == 1 else reports, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
