import AppKit

@MainActor
final class MessagePanelWindow: NSPanel {
    private weak var anchorWindow: PetWindow?
    private let panelView: PetMessagePanelView
    private var expiryItems: [String: DispatchWorkItem] = [:]
    private var permissionThreadsByAgent: [String: Set<String>] = [:]
    private var isPetHidden = false

    init(anchorWindow: PetWindow, petSize: CGSize) {
        self.anchorWindow = anchorWindow
        panelView = PetMessagePanelView(petSize: petSize)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        contentView = panelView
        panelView.onLayoutChanged = { [weak self] in self?.renderLayout() }
        panelView.onDismissMessage = { [weak self] id in self?.clearBubble(threadId: id) }
    }

    func setBubble(_ bubble: PetBubble, threadId: String, agentId: String? = nil, ttl: TimeInterval? = nil) {
        expiryItems[threadId]?.cancel()
        expiryItems[threadId] = nil
        if threadId.hasPrefix("perm-"), let agentId {
            permissionThreadsByAgent[agentId, default: []].insert(threadId)
        }
        panelView.setBubble(bubble, threadId: threadId)
        if let ttl {
            let item = DispatchWorkItem { [weak self] in self?.clearBubble(threadId: threadId) }
            expiryItems[threadId] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: item)
        }
    }

    func clearBubble(threadId: String) {
        expiryItems[threadId]?.cancel()
        expiryItems[threadId] = nil
        for agentId in permissionThreadsByAgent.keys {
            permissionThreadsByAgent[agentId]?.remove(threadId)
            if permissionThreadsByAgent[agentId]?.isEmpty == true { permissionThreadsByAgent[agentId] = nil }
        }
        panelView.clearBubble(threadId: threadId)
    }

    func clearAgent(_ agentId: String) {
        clearBubble(threadId: agentId)
        let permissionThreads = permissionThreadsByAgent.removeValue(forKey: agentId) ?? []
        for threadId in permissionThreads { clearBubble(threadId: threadId) }
    }

    func clearPermissions(for agentId: String) {
        let threads = permissionThreadsByAgent.removeValue(forKey: agentId) ?? []
        for threadId in threads { clearBubble(threadId: threadId) }
    }

    func updatePetSize(_ size: CGSize) { panelView.updatePetSize(size) }
    func beginPetDrag() { ignoresMouseEvents = true }
    func endPetDrag() { ignoresMouseEvents = false; reposition() }
    func showWithPet() { isPetHidden = false; renderLayout() }
    func hideWithPet() { isPetHidden = true; orderOut(nil) }
    func reposition() { renderLayout() }

    private func renderLayout() {
        guard !isPetHidden, let anchorWindow else { return }
        guard panelView.hasVisibleMessages else {
            orderOut(nil)
            return
        }
        let petAnchor = CGPoint(x: anchorWindow.frame.minX, y: anchorWindow.frame.maxY)
        let size = panelView.frame.size
        var origin = CGPoint(x: petAnchor.x + anchorWindow.frame.width - size.width, y: petAnchor.y)
        if let screen = anchorWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        setFrame(NSRect(origin: origin, size: size), display: false)
        orderFront(nil)
    }
}
