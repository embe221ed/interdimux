import AppKit

enum PickerDialogs {
    static func prompt(on panel: NSWindow, title: String, message: String, value: String,
                       placeholder: String, submit: String, completion: @escaping (String?) -> Void) {
        let alert = makeAlert(on: panel, title: title, message: message)
        alert.addButton(withTitle: submit).keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 26))
        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isEditable = true
        field.isSelectable = true
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: panel) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        // The field editor exists only once the sheet has been presented.
        // Keep literal commands intact, including straight quotes and dashes.
        DispatchQueue.main.async {
            guard alert.window.sheetParent === panel else { return }
            alert.window.makeFirstResponder(field)
            field.selectText(nil)
            if let editor = field.currentEditor() as? NSTextView {
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
            }
        }
    }

    static func confirm(on panel: NSWindow, title: String, message: String, submit: String,
                        completion: @escaping (Bool) -> Void) {
        let alert = makeAlert(on: panel, title: title, message: message)
        alert.alertStyle = .warning
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let destructive = alert.addButton(withTitle: submit)
        destructive.keyEquivalent = ""
        destructive.hasDestructiveAction = true
        begin(alert, on: panel, dismiss: cancel, returnDismisses: true) { response in
            completion(response == .alertSecondButtonReturn)
        }
    }

    static func directory(on panel: NSWindow, completion: @escaping (String?) -> Void) {
        let chooser = NSOpenPanel()
        chooser.appearance = panel.effectiveAppearance
        chooser.title = "Open Project Directory"
        chooser.prompt = "Open Project"
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false
        chooser.canCreateDirectories = false
        chooser.resolvesAliases = true
        chooser.beginSheetModal(for: panel) { response in
            completion(response == .OK ? chooser.url?.path : nil)
        }
    }

    static func preview(on panel: NSWindow, title: String, text: String,
                        completion: @escaping () -> Void) {
        let alert = makeAlert(on: panel, title: title, message: "")
        let close = alert.addButton(withTitle: "Close")
        close.keyEquivalent = "\r"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        alert.accessoryView = scroll
        begin(alert, on: panel, dismiss: close) { _ in completion() }
    }

    private static func makeAlert(on panel: NSWindow, title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.window.appearance = panel.effectiveAppearance
        return alert
    }

    private static func begin(_ alert: NSAlert, on panel: NSWindow, dismiss: NSButton,
                              returnDismisses: Bool = false,
                              completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let window = alert.window
        // A button has only one key equivalent. Explicitly reserve Escape for
        // dismissal and, for destructive confirmation, Return/keypad Enter too
        // even if keyboard navigation moved focus to the destructive button.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak dismiss] event in
            guard let window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  event.keyCode == 53 || (returnDismisses && (event.keyCode == 36 || event.keyCode == 76)) else {
                return event
            }
            dismiss?.performClick(nil)
            return nil
        }
        alert.beginSheetModal(for: panel) { response in
            if let monitor { NSEvent.removeMonitor(monitor) }
            completion(response)
        }
    }
}
