import AppKit

final class QuickChatWindow: NSWindow, NSTextFieldDelegate {
    private let input = NSTextField()
    private var onSubmit: ((String) -> Void)?
    private weak var anchorWindow: PetWindow?

    init(anchorWindow: PetWindow, onSubmit: @escaping (String) -> Void) {
        self.anchorWindow = anchorWindow
        self.onSubmit = onSubmit
        let frame = NSRect(x: 0, y: 0, width: 260, height: 36)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 18

        input.frame = NSRect(x: 14, y: 6, width: 232, height: 24)
        input.placeholderString = "Start new chat"
        input.font = .systemFont(ofSize: 13)
        input.textColor = .white
        input.backgroundColor = .clear
        input.isBordered = false
        input.focusRingType = .none
        input.delegate = self
        container.addSubview(input)

        contentView = container
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        input.becomeFirstResponder()
    }

    func hide() {
        orderOut(nil)
        input.stringValue = ""
    }

    override var canBecomeKey: Bool { true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                onSubmit?(text)
                input.stringValue = ""
                hide()
            }
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    func reposition() {
        guard let anchor = anchorWindow else { return }
        let anchorFrame = anchor.frame
        var x = anchorFrame.midX - frame.width / 2
        var y = anchorFrame.minY - frame.height - 6
        if let screen = anchor.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            x = min(max(x, visible.minX), visible.maxX - frame.width)
            y = min(max(y, visible.minY), visible.maxY - frame.height)
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
