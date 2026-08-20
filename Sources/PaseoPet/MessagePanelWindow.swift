import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class MessagePanelWindow: NSPanel {
    private enum Placement { case above, below }

    private static let cardGap: CGFloat = 8
    private static let badgeGap: CGFloat = 8
    private static let badgeDiameter: CGFloat = 24
    private static let accessoryOutset: CGFloat = 4
    private static let placementHysteresis: CGFloat = 12

    private weak var anchorWindow: PetWindow?
    private let panelView: PetMessagePanelView
    private let badgePanel: NSPanel
    private var badgeHostingView: NSHostingView<PetBadgeView>!
    private var expiryItems: [String: DispatchWorkItem] = [:]
    private var permissionThreadsByAgent: [String: Set<String>] = [:]
    private var isPetHidden = false
    private var placement: Placement = .above

    var onDismissMessage: ((String) -> Void)?

    init(anchorWindow: PetWindow, petSize: CGSize) {
        self.anchorWindow = anchorWindow
        panelView = PetMessagePanelView(petSize: petSize)
        badgePanel = Self.makeAccessoryPanel()
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        Self.configureOverlayPanel(self)
        contentView = panelView

        badgeHostingView = NSHostingView(rootView: makeBadgeView())
        badgeHostingView.frame = NSRect(origin: .zero, size: Self.badgeWindowSize)
        badgePanel.contentView = badgeHostingView

        panelView.onLayoutChanged = { [weak self] in self?.renderLayout() }
        panelView.onDismissMessage = { [weak self] id in
            guard let self else { return }
            if let onDismissMessage { onDismissMessage(id) } else { clearBubble(threadId: id) }
        }
#if DEBUG
        Self.assertPlacementBehavior()
#endif
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

    func updatePetSize(_ size: CGSize) { panelView.updatePetSize(size); renderLayout() }

    func beginPetDrag() {
        ignoresMouseEvents = true
        badgePanel.ignoresMouseEvents = true
    }

    func endPetDrag() {
        ignoresMouseEvents = false
        badgePanel.ignoresMouseEvents = false
        reposition()
    }

    func showWithPet() { isPetHidden = false; renderLayout() }

    func hideWithPet() {
        isPetHidden = true
        orderOut(nil)
        badgePanel.orderOut(nil)
    }

    func reposition() { renderLayout() }

    private func renderLayout() {
        guard !isPetHidden, let anchorWindow else { return }
        let petFrame = anchorWindow.frame
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8)
            ?? NSRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)

        guard panelView.showsMessageCards else {
            orderOut(nil)
            updateBadge(petFrame: petFrame)
            return
        }

        let previousPlacement = placement
        placement = Self.preferredPlacement(
            current: previousPlacement,
            petFrame: petFrame,
            panelHeight: panelView.frame.height,
            visibleFrame: visible
        )
        panelView.setIsBelowPet(placement == .below)
        let targetFrame = Self.targetPanelFrame(
            placement: placement,
            petFrame: petFrame,
            panelSize: panelView.frame.size,
            visibleFrame: visible
        )
        let shouldAnimate = Self.shouldAnimateFrameChange(
            isVisible: isVisible,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            from: previousPlacement,
            to: placement,
            currentFrame: frame,
            targetFrame: targetFrame
        )
        badgeHostingView.rootView = makeBadgeView()
        let targetBadgeFrame = badgeWindowFrame(for: petFrame, panelFrame: targetFrame)
        badgePanel.orderFront(nil)
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
                animator().setFrame(targetFrame, display: false)
                if placement == .below {
                    badgePanel.animator().setFrame(targetBadgeFrame, display: false)
                }
            }
            if placement != .below { badgePanel.setFrame(targetBadgeFrame, display: false) }
        } else {
            setFrame(targetFrame, display: false)
            badgePanel.setFrame(targetBadgeFrame, display: false)
        }
        orderFront(nil)
    }

    private func updateBadge(petFrame: NSRect) {
        guard panelView.hasMessages else {
            badgePanel.orderOut(nil)
            return
        }
        badgeHostingView.rootView = makeBadgeView()
        badgePanel.setFrame(badgeWindowFrame(for: petFrame), display: false)
        badgePanel.orderFront(nil)
    }

    private func makeBadgeView() -> PetBadgeView {
        PetBadgeView(
            isCollapsed: panelView.isCollapsed,
            count: panelView.activeMessageCount,
            indicator: panelView.highestIndicator,
            pointsUp: placement == .below,
            onToggle: { [weak self] in self?.panelView.toggleMessageStackCollapsed() }
        )
    }

    private func badgeVisibleFrame(for petFrame: NSRect, panelFrame: NSRect? = nil) -> NSRect {
        let panelFrame = panelFrame ?? frame
        let y = placement == .below && panelView.showsMessageCards
            ? panelFrame.minY - Self.badgeGap - Self.badgeDiameter
            : petFrame.minY - Self.badgeGap - Self.badgeDiameter
        return NSRect(
            x: petFrame.midX - Self.badgeDiameter / 2,
            y: y,
            width: Self.badgeDiameter,
            height: Self.badgeDiameter
        )
    }

    private func badgeWindowFrame(for petFrame: NSRect, panelFrame: NSRect? = nil) -> NSRect {
        badgeVisibleFrame(for: petFrame, panelFrame: panelFrame).insetBy(dx: -Self.accessoryOutset, dy: -Self.accessoryOutset)
    }

    private static var badgeWindowSize: CGSize {
        CGSize(width: badgeDiameter + accessoryOutset * 2, height: badgeDiameter + accessoryOutset * 2)
    }

    private static func preferredPlacement(
        current: Placement,
        petFrame: NSRect,
        panelHeight: CGFloat,
        visibleFrame: NSRect
    ) -> Placement {
        let availableAbove = visibleFrame.maxY - petFrame.maxY - cardGap
        let requiredAbove = panelHeight + (current == .below ? placementHysteresis : 0)
        return availableAbove >= requiredAbove ? .above : .below
    }

    private static func targetPanelFrame(
        placement: Placement,
        petFrame: NSRect,
        panelSize: CGSize,
        visibleFrame: NSRect
    ) -> NSRect {
        var origin = CGPoint(x: petFrame.midX - panelSize.width / 2, y: 0)
        switch placement {
        case .above: origin.y = petFrame.maxY + cardGap
        case .below: origin.y = petFrame.minY - cardGap - panelSize.height
        }
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        return NSRect(origin: origin, size: panelSize)
    }

    private static func shouldAnimateFrameChange(
        isVisible: Bool,
        reduceMotion: Bool,
        from: Placement,
        to: Placement,
        currentFrame: NSRect,
        targetFrame: NSRect
    ) -> Bool {
        guard isVisible, !reduceMotion, from == to else { return false }
        return abs(currentFrame.width - targetFrame.width) > 0.5
            || abs(currentFrame.height - targetFrame.height) > 0.5
    }

    private static func makeAccessoryPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureOverlayPanel(panel)
        return panel
    }

    private static func configureOverlayPanel(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
    }

#if DEBUG
    private static func assertPlacementBehavior() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        assert(preferredPlacement(current: .above, petFrame: NSRect(x: 800, y: 100, width: 100, height: 100), panelHeight: 200, visibleFrame: visible) == .above)
        assert(preferredPlacement(current: .above, petFrame: NSRect(x: 800, y: 650, width: 100, height: 100), panelHeight: 200, visibleFrame: visible) == .below)
        let thresholdPet = NSRect(x: 800, y: 492, width: 100, height: 100)
        assert(preferredPlacement(current: .above, petFrame: thresholdPet, panelHeight: 200, visibleFrame: visible) == .above)
        assert(preferredPlacement(current: .below, petFrame: thresholdPet, panelHeight: 200, visibleFrame: visible) == .below)
        assert(preferredPlacement(current: .below, petFrame: thresholdPet.offsetBy(dx: 0, dy: -placementHysteresis), panelHeight: 200, visibleFrame: visible) == .above)
        let pet = NSRect(x: 400, y: 300, width: 100, height: 100)
        let above = targetPanelFrame(placement: .above, petFrame: pet, panelSize: CGSize(width: 240, height: 80), visibleFrame: visible)
        let below = targetPanelFrame(placement: .below, petFrame: pet, panelSize: CGSize(width: 240, height: 80), visibleFrame: visible)
        assert(above.minY == pet.maxY + cardGap)
        assert(below.maxY == pet.minY - cardGap)
        assert(shouldAnimateFrameChange(isVisible: true, reduceMotion: false, from: .above, to: .above, currentFrame: above, targetFrame: above.insetBy(dx: -10, dy: -10)))
        assert(!shouldAnimateFrameChange(isVisible: true, reduceMotion: false, from: .above, to: .below, currentFrame: above, targetFrame: below))
        assert(!shouldAnimateFrameChange(isVisible: true, reduceMotion: false, from: .above, to: .above, currentFrame: above, targetFrame: above.offsetBy(dx: 10, dy: 10)))
    }
#endif
}

private struct PetBadgeView: View {
    let isCollapsed: Bool
    let count: Int
    let indicator: PetBubbleIndicator
    let pointsUp: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                if isCollapsed, let color = countColor { Circle().fill(color) }
                if isCollapsed {
                    Text("\(min(max(count, 1), 99))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(countColor == nil ? Color.primary : Color.black.opacity(0.82))
                } else {
                    Image(systemName: pointsUp ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24, alignment: .center)
            .codexGlass(in: Circle(), isDark: colorScheme == .dark)
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel(isCollapsed ? "Show messages" : "Hide messages")
    }

    private var countColor: Color? {
        switch indicator {
        case .review, .success: return .green.opacity(0.72)
        case .attention: return .red.opacity(0.72)
        case .none, .working, .waiting: return nil
        }
    }
}
