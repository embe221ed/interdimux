#!/usr/bin/env python3
"""Exercise Swift pipe/reconnect handling with a fake helper; never opens UI."""
from pathlib import Path
import subprocess
import sys
import tempfile


HELPER = r'''
import json, os, sys, time
for line in sys.stdin:
    request = json.loads(line)
    kind = request['type']
    if kind == 'malformed':
        print('not JSON', flush=True)
    elif kind == 'hold-preview':
        while not os.path.exists(request['release']):
            time.sleep(.005)
        print(json.dumps({'id': request['id'], 'type': 'preview', 'text': 'captured'}), flush=True)
    elif kind == 'close-output':
        os.close(1)
        time.sleep(10)
    elif kind == 'large-fragment':
        result = json.dumps({'id': request['id'], 'type': 'results', 'query': '東京 🧑🏽‍💻' * 20000}, ensure_ascii=False).encode() + b'\n'
        for offset in range(0, len(result), 3071):
            os.write(1, result[offset:offset + 3071])
    else:
        result = json.dumps({'id': request['id'], 'type': 'results', 'query': '東京 🧑🏽‍💻'}, ensure_ascii=False) + '\n'
        if kind == 'fragment':
            encoded = result.encode()
            for offset in range(0, len(encoded), 7):
                os.write(1, encoded[offset:offset + 7])
                time.sleep(.001)
        else:
            sys.stdout.write(result)
            sys.stdout.flush()
'''

HARNESS = r'''
import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}
func wait(_ description: String, _ condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(3)
    while !condition(), Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    try require(condition(), "Timed out: " + description)
}
func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
}

func run() throws {
    let backend = PickerBackend(executable: URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { backend.stop() }
    var messages: [[String: Any]] = []
    var failures: [String] = []
    var assignedRequest = 0
    var sawUnassignedRequest = false
    backend.onMessage = { messages.append($0) }
    backend.onFailure = { message in
        if assignedRequest == 0 { sawUnassignedRequest = true }
        failures.append(message)
    }

    // A request after termination must fail after its ID has been assigned,
    // rather than leaving the app's activation guard permanently set.
    assignedRequest = backend.send("activate")
    try require(failures.isEmpty, "Failure callback ran before send returned")
    try wait("disconnected request failure") { failures.count == 1 }
    try require(!sawUnassignedRequest, "Failure preceded request assignment")

    // A queued failure from an old connection must not cancel a new request.
    failures.removeAll()
    assignedRequest = backend.send("query")
    try backend.start()
    let initial = backend.send("fragment")
    try wait("fragmented Unicode reply") { !messages.isEmpty }
    try require((messages[0]["id"] as? Int) == initial, "Wrong response after reconnect")
    try require((messages[0]["query"] as? String) == "東京 🧑🏽‍💻", "Split UTF-8 response was corrupted")
    settle()
    try require(failures.isEmpty, "Old disconnected-send failure reached new helper")

    messages.removeAll()
    let large = backend.send("large-fragment")
    let following = backend.send("fragment")
    try wait("large fragmented response and following frame") { messages.count == 2 }
    try require((messages[0]["id"] as? Int) == large, "Large response lost its request ID")
    try require((messages[0]["query"] as? String) == String(repeating: "東京 🧑🏽‍💻", count: 20000), "Large split response was corrupted")
    try require((messages[1]["id"] as? Int) == following, "Frame after large response was lost")

    // Block this run loop while the old child replies, then reconnect before
    // queued stdout/termination callbacks can run on the main queue.
    messages.removeAll()
    backend.send("query")
    Thread.sleep(forTimeInterval: 0.25)
    backend.stop()
    try backend.start()
    let latest = backend.send("query")
    try wait("new helper reply") { !messages.isEmpty }
    settle()
    try require(messages.count == 1 && (messages[0]["id"] as? Int) == latest,
                "Old helper response crossed the reconnect boundary")
    try require(failures.isEmpty, "Old helper shutdown invalidated the new helper")

    // Malformed output cannot strand a pending request; the helper is stopped
    // and reconnecting establishes an independent, healthy connection.
    backend.send("malformed")
    try wait("invalid response failure") { failures.count == 1 }
    try require(failures[0].contains("invalid response"), "Malformed response was silently ignored")
    settle()
    try require(failures.count == 1, "One broken connection emitted duplicate failures")
    failures.removeAll()
    messages.removeAll()
    try backend.start()
    let recovered = backend.send("query")
    try wait("recovered helper reply") { !messages.isEmpty }
    try require((messages[0]["id"] as? Int) == recovered, "Recovery returned a stale response")

    // EOF can occur while a child remains alive. Reconnect must not mistake
    // that disconnected process for a functioning helper.
    backend.send("close-output")
    try wait("closed stdout failure") { failures.count == 1 }
    failures.removeAll()
    messages.removeAll()
    try backend.start()
    let afterEOF = backend.send("query")
    try wait("reconnect after stdout EOF") { !messages.isEmpty }
    settle()
    try require((messages[0]["id"] as? Int) == afterEOF && failures.isEmpty,
                "Closed stdout left a stale helper or failure callback")

    // A capture blocked on Rex must not block the separate query channel.
    // Release it only after the main helper has answered, avoiding timing
    // assertions that would depend on machine load.
    let preview = PickerBackend(executable: URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { preview.stop() }
    let release = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: release) }
    var previewMessages: [[String: Any]] = []
    preview.onMessage = { previewMessages.append($0) }
    try preview.start()
    preview.send("hold-preview", fields: ["release": release.path])
    messages.removeAll()
    let independent = backend.send("query")
    try wait("query during blocked preview") { !messages.isEmpty }
    try require((messages[0]["id"] as? Int) == independent && previewMessages.isEmpty,
                "Preview capture blocked or crossed the query channel")
    try Data().write(to: release)
    try wait("released preview") { previewMessages.count == 1 }
    try require(previewMessages[0]["text"] as? String == "captured", "Preview channel failed after query")
    print("Swift backend checks passed: disconnected send, stale callbacks, fragmented UTF-8, malformed reply, live-child EOF, independent preview channel")
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
'''


def main():
    if sys.platform != "darwin":
        raise SystemExit("Swift backend checks require macOS.")
    source = Path(__file__).parent / "Sources" / "Backend.swift"
    with tempfile.TemporaryDirectory(prefix="interdimux-swift-backend-") as directory:
        root = Path(directory)
        helper = root / "fake-helper"
        helper.write_text("#!" + sys.executable + "\n" + HELPER)
        helper.chmod(0o700)
        main_source = root / "main.swift"
        main_source.write_text(HARNESS)
        binary = root / "backend-tests"
        subprocess.run(["xcrun", "swiftc", str(source), str(main_source), "-framework", "AppKit", "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(helper)], check=True, timeout=20)


if __name__ == "__main__":
    main()
