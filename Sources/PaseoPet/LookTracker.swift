import AppKit
import CoreGraphics

@MainActor
final class LookTracker {
    private let petWindow: PetWindow
    private let rows: Int
    private let onLook: (Int?) -> Void
    private var timer: DispatchSourceTimer?
    private let deadzone: CGFloat = 10

    init(petWindow: PetWindow, rows: Int, onLook: @escaping (Int?) -> Void) {
        self.petWindow = petWindow
        self.rows = rows
        self.onLook = onLook
    }

    func start() {
        guard rows >= 11 else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let mouseLocation = NSEvent.mouseLocation
        let windowFrame = petWindow.frame
        let centerX = windowFrame.midX
        let centerY = windowFrame.midY

        let dx = mouseLocation.x - centerX
        // macOS y is flipped (0 at bottom), so dy = mouseY - centerY is already "up is positive"
        let dy = mouseLocation.y - centerY

        if sqrt(dx * dx + dy * dy) <= deadzone {
            onLook(nil)
            return
        }

        // atan2(dx, dy) gives clockwise-from-north in macOS coords (y-up)
        let angle = (atan2(dx, dy) * (180.0 / .pi) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((angle / 22.5).rounded()) % 16
        onLook(index)
    }
}
