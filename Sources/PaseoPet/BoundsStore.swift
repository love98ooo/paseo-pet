import AppKit

@MainActor
enum BoundsStore {
    private static let key = "petWindowBounds"

    struct SavedBounds: Codable {
        let x: CGFloat
        let y: CGFloat
        let displayId: UInt32
    }

    static func save(window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        let bounds = SavedBounds(x: window.frame.origin.x, y: window.frame.origin.y, displayId: displayId)
        if let data = try? JSONEncoder().encode(bounds) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clamp(window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: max(area.minX, min(window.frame.minX, area.maxX - window.frame.width)),
            y: max(area.minY, min(window.frame.minY, area.maxY - window.frame.height))
        ))
    }

    static func restore(window: NSWindow) {
        guard let data = UserDefaults.standard.data(forKey: key),
              let bounds = try? JSONDecoder().decode(SavedBounds.self, from: data) else { return }

        let targetScreen = NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            return id == bounds.displayId
        } ?? NSScreen.main

        guard let screen = targetScreen else { return }
        let area = screen.visibleFrame
        let x = max(area.minX, min(bounds.x, area.maxX - window.frame.width))
        let y = max(area.minY, min(bounds.y, area.maxY - window.frame.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
