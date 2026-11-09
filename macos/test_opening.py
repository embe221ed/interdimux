#!/usr/bin/env python3
"""Exercise the real opening controller offscreen with a local transport stub."""
from pathlib import Path
import subprocess
import sys
import tempfile


BACKEND = '''
final class PickerBackend {
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var serial = 0
    var isRunning = true
    func start() throws {}
    @discardableResult func send(_ type: String, fields: [String: Any] = [:]) -> Int {
        serial += 1
        return serial
    }
    func stop() {}
}
'''


def run(controller_source=None):
    if sys.platform != "darwin":
        raise SystemExit("Swift opening checks require macOS.")
    root = Path(__file__).resolve().parent
    source = controller_source if controller_source is not None else (root / "Sources/main.swift").read_text()
    marker = "\nlet app = NSApplication.shared"
    assert marker in source
    # Compile the actual controller's open/receive/table paths. Expose its state
    # to this test and suppress window presentation; never send system events.
    source = source.split(marker, 1)[0].replace("private ", "")
    source = source.replace("panel.makeKeyAndOrderFront(nil)", "panel.orderOut(nil)")
    item_source = (root / "Sources/Backend.swift").read_text().split("/// One local process", 1)[0]
    with tempfile.TemporaryDirectory(prefix="interdimux-opening-tests-") as directory:
        work = Path(directory)
        controller = work / "Controller.swift"
        controller.write_text(source)
        backend = work / "Backend.swift"
        backend.write_text(item_source + BACKEND)
        sources = [path for path in sorted((root / "Sources").glob("*.swift"))
                   if path.name not in ("main.swift", "Backend.swift")]
        binary = work / "opening-tests"
        subprocess.run(["xcrun", "swiftc", str(controller), str(backend),
                        *map(str, sources), str(root / "Tests/OpeningTests.swift"),
                        "-framework", "AppKit", "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    run()
