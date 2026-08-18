import AppKit

final class PetWindow: NSWindow {
    let spriteView: SpriteView
    var onDragStart: (() -> Void)?
    var onDragDelta: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClick: (() -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    private var lastDragX: CGFloat = 0
    private var lastDragY: CGFloat = 0
    private var didDrag = false
    // Codex drag physics: samples within a 160ms window, velocity clamped 320–1600 px/s
    private struct DragSample { let x: CGFloat; let y: CGFloat; let time: TimeInterval }
    private var dragSamples: [DragSample] = []

    init() {
        let frame = NSRect(x: 0, y: 0, width: 192, height: 208)
        spriteView = SpriteView(frame: frame)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hasShadow = false
        contentView = spriteView

        BoundsStore.restore(window: self)
        if self.frame.origin == .zero {
            if let screen = NSScreen.main {
                let area = screen.visibleFrame
                // Default: top-right corner (Codex "top-end" placement)
                setFrameOrigin(NSPoint(
                    x: area.maxX - frame.width - 16,
                    y: area.maxY - frame.height - 16
                ))
            }
        }
    }

    func loadPet(_ pet: PetEntry) {
        spriteView.loadSpritesheet(path: pet.spritesheetPath, rows: pet.rows)
    }

    override func mouseDown(with event: NSEvent) {
        onDragStart?()
        let loc = NSEvent.mouseLocation
        lastDragX = loc.x
        lastDragY = loc.y
        didDrag = false
        dragSamples = [DragSample(x: loc.x, y: loc.y, time: ProcessInfo.processInfo.systemUptime)]
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let dx = loc.x - lastDragX
        let dy = loc.y - lastDragY
        lastDragX = loc.x
        lastDragY = loc.y
        dragSamples.append(DragSample(x: loc.x, y: loc.y, time: now))
        // Codex: keep only samples within the last 160ms
        dragSamples.removeAll { now - $0.time > 0.160 }
        if abs(dx) >= 4 || abs(dy) >= 4 { didDrag = true }
        if didDrag {
            setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        }
        onDragDelta?(dx)
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
        BoundsStore.save(window: self)
        if didDrag {
            applySpringRelease()
        } else {
            onClick?()
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }

    // Codex orb physics: velocity from last two samples ≥4px apart within the 160ms window,
    // clamped to 1600 px/s, sub-320 px/s treated as no release impulse (×3 on dispatch).
    private func releaseVelocity() -> (x: CGFloat, y: CGFloat)? {
        guard let last = dragSamples.last else { return nil }
        // Find the most recent earlier sample at least 4px away from the last one
        var anchor: DragSample?
        for s in dragSamples.dropLast().reversed() {
            if abs(last.x - s.x) >= 4 || abs(last.y - s.y) >= 4 {
                anchor = s
                break
            }
        }
        guard let a = anchor else { return nil }
        let dt = CGFloat(max(last.time - a.time, 0.008))
        var vx = (last.x - a.x) / dt
        var vy = (last.y - a.y) / dt
        let speed = sqrt(vx * vx + vy * vy)
        guard speed >= 320 else { return nil }
        if speed > 1600 {
            let scale: CGFloat = 1600 / speed
            vx *= scale
            vy *= scale
        }
        return (x: vx, y: vy)
    }

    private func applySpringRelease() {
        guard let v = releaseVelocity() else { return }
        let vx = v.x * 3
        let vy = v.y * 3
        let speed = sqrt(vx * vx + vy * vy)

        let overshoot: CGFloat = min(speed * 0.02, 24)
        let dirX = vx / speed
        let dirY = vy / speed
        let origin = frame.origin
        let bounceTarget = NSPoint(x: origin.x + dirX * overshoot, y: origin.y + dirY * overshoot)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrameOrigin(bounceTarget)
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.animator().setFrameOrigin(origin)
                })
            }
        })
    }
}
