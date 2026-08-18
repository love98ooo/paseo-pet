import AppKit
import QuartzCore

final class SpriteView: NSView {
    private let spriteLayer = CALayer()
    private var totalRows: Int = 9
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(spriteLayer)
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .nearest
        updateTrackingArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        spriteLayer.frame = bounds
        updateTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    private func updateTrackingArea() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func loadSpritesheet(path: String, rows: Int) {
        totalRows = rows
        guard let image = NSImage(contentsOfFile: path) else { return }
        spriteLayer.contents = image
        let flippedY = CGFloat(rows - 1) / CGFloat(rows)
        spriteLayer.contentsRect = CGRect(x: 0, y: flippedY, width: 1.0 / 8.0, height: 1.0 / CGFloat(rows))
    }

    func showFrame(col: Int, row: Int, rows: Int) {
        totalRows = rows
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // CALayer contentsRect Y is bottom-up; spritesheet row 0 is at the top of the image
        let flippedY = CGFloat(totalRows - 1 - row) / CGFloat(totalRows)
        spriteLayer.contentsRect = CGRect(
            x: CGFloat(col) / 8.0,
            y: flippedY,
            width: 1.0 / 8.0,
            height: 1.0 / CGFloat(totalRows)
        )
        CATransaction.commit()
    }
}
