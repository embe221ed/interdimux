import AppKit

enum PickerGeometry {
    static func panelFrame(in visible: NSRect) -> NSRect {
        let width = max(0, min(1080, visible.width - 48))
        let height = max(0, min(760, visible.height - 60))
        let marginY = min(30, max(0, visible.height / 2))
        let centeredY = visible.midY - height / 2
        let preferredY = centeredY + min(45, max(0, visible.height * 0.04))
        let y = min(max(visible.minY + marginY, preferredY), visible.maxY - marginY - height)
        return NSRect(x: visible.midX - width / 2, y: y, width: width, height: height)
    }

    static func contentFrames(in bounds: NSRect, preview: Bool) -> (list: NSRect, preview: NSRect) {
        let width = max(0, bounds.width)
        let height = max(0, bounds.height)
        guard preview else {
            return (NSRect(x: 0, y: 0, width: width, height: height), .zero)
        }
        let previewWidth = min(min(400, max(280, width * 0.36)), max(0, width - 321))
        let listWidth = max(0, width - previewWidth)
        return (NSRect(x: 0, y: 0, width: listWidth, height: height),
                NSRect(x: listWidth, y: 0, width: previewWidth, height: height))
    }

    struct RowFrames {
        let symbol: NSRect
        let title: NSRect
        let path: NSRect
        let kind: NSRect
        let current: NSRect
    }

    static func rowFrames(width: CGFloat, depth: Int) -> RowFrames {
        let width = max(0, width)
        let right = max(0, width - (width < 600 ? 18 : 26))
        let center = 34 + CGFloat(max(0, depth)) * 22
        let textLeft = center + 17
        let deepestTextLeft: CGFloat = 34 + 2 * 22 + 17
        let gap: CGFloat = width < 600 ? 12 : 18
        let metadata: CGFloat = 83
        // Preserve useful identity space with an open preview. Paths retain
        // their suffix; at unusually small widths omit the path column before
        // consuming the identity with an ellipsis-only path.
        var pathWidth = max(0, min(340, width * 0.32, right - metadata - gap * 2 - deepestTextLeft - 150))
        if pathWidth < 48 { pathWidth = 0 }
        let pathLeft = right - metadata - gap - pathWidth
        let textWidth = max(0, pathLeft - gap - textLeft)
        func bounded(_ rect: NSRect) -> NSRect {
            let clipped = rect.intersection(NSRect(x: 0, y: 0, width: width, height: 38))
            return clipped.isNull ? .zero : clipped
        }
        return RowFrames(
            symbol: bounded(NSRect(x: center - 8, y: 11, width: 16, height: 16)),
            title: bounded(NSRect(x: textLeft, y: 10, width: textWidth, height: 18)),
            path: bounded(NSRect(x: max(0, pathLeft), y: 11, width: pathWidth, height: 16)),
            kind: bounded(NSRect(x: right - 62, y: 12, width: 62, height: 14)),
            current: bounded(NSRect(x: right - 71, y: 17, width: 4, height: 4))
        )
    }
}

private final class PreviewTextView: NSTextView {
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
}

final class PickerPreviewView: NSView {
    private let heading = label("PREVIEW", size: 9, weight: .semibold, color: Palette.faint)
    private let title = label("Select a target", size: 13, weight: .medium)
    private let detail = label("Terminal output and project details", size: 10.5, color: Palette.secondary)
    private let spinner = NSProgressIndicator()
    private let scroll = NSScrollView()
    private let text = PreviewTextView(frame: .zero)
    var onCancel: (() -> Void)? {
        didSet { text.onCancel = onCancel }
    }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        for view in [heading, title, detail, spinner, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        detail.lineBreakMode = .byTruncatingHead
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = Palette.text
        text.textContainerInset = NSSize(width: 16, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel("Preview text")
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 32)
        heading.frame = NSRect(x: 16, y: 14, width: max(0, width - 24), height: 14)
        spinner.frame = NSRect(x: max(0, bounds.width - 32), y: 13, width: 16, height: 16)
        title.frame = NSRect(x: 16, y: 34, width: width, height: 18)
        detail.frame = NSRect(x: 16, y: 57, width: width, height: 15)
        scroll.frame = NSRect(x: 1, y: 84, width: max(0, bounds.width - 1), height: max(0, bounds.height - 84))
        let contentWidth = max(0, scroll.contentSize.width)
        text.setFrameSize(NSSize(width: contentWidth, height: max(text.frame.height, scroll.contentSize.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 16, y: 83, width: max(0, bounds.width - 32), height: 1).fill()
    }

    func show(title: String, detail: String, text value: String, loading: Bool) {
        self.title.stringValue = title
        self.title.toolTip = title
        self.detail.stringValue = detail
        self.detail.toolTip = detail
        let output = loading && value.isEmpty ? "Loading preview…" : value
        if text.string != output {
            text.string = output
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        text.textColor = loading ? Palette.secondary : Palette.text
        text.setAccessibilityLabel("Preview of \(title)")
        if loading { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }
}
