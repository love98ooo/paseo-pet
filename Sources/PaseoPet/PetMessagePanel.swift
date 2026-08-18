// Portions adapted from OpenPetsKit.
// MIT License — Copyright (c) 2026 OpenPets contributors.

import AppKit
import SwiftUI

struct PermissionNotification {
    let agentId: String
    let requestId: String
    let title: String
    let description: String?
    let kind: String
    let actions: [(id: String, label: String, behavior: String, variant: String?)]
}

enum SessionStatus: Int, Comparable {
    case waiting = 0, failed = 1, review = 2, running = 3, idle = 4

    static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    var indicator: PetBubbleIndicator {
        switch self {
        case .waiting: return .waiting
        case .failed: return .attention
        case .review: return .review
        case .running: return .working
        case .idle: return .none
        }
    }

}

struct SessionNotification: Identifiable {
    let id: String
    let agentId: String
    var title: String
    var subtitle: String?
    var status: SessionStatus
}

struct PetBubbleAction: Identifiable {
    enum Tone { case normal, primary, danger }

    let id: String
    let label: String
    var tone: Tone = .normal
    let handler: () -> Void
}

struct PetBubble {
    var title: String
    var detail: String?
    var indicator: PetBubbleIndicator
    var actions: [PetBubbleAction] = []
    var actionsRequireHover = true
    var detailLineLimit: Int? = 2
    var onActivate: (() -> Void)?
}

enum PetBubbleIndicator {
    case none, working, waiting, review, success, attention
}

struct PetMessage: Identifiable {
    var id: String { threadId }
    let threadId: String
    var bubble: PetBubble
}

struct PetMessageStack {
    static let visibleLimit = 4
    private(set) var orderedThreadIds: [String] = []
    private var bubblesByThreadId: [String: PetBubble] = [:]

    var activeMessages: [PetMessage] {
        orderedThreadIds.compactMap { id in
            bubblesByThreadId[id].map { PetMessage(threadId: id, bubble: $0) }
        }
    }
    var activeCount: Int { activeMessages.count }

    mutating func setBubble(_ bubble: PetBubble, threadId: String) {
        if bubblesByThreadId[threadId] == nil { orderedThreadIds.append(threadId) }
        bubblesByThreadId[threadId] = bubble
    }

    mutating func clearBubble(threadId: String) {
        bubblesByThreadId[threadId] = nil
        orderedThreadIds.removeAll { $0 == threadId }
    }

    func visibleMessages(limit: Int = visibleLimit) -> [PetMessage] {
        Array(activeMessages.suffix(max(0, limit)))
    }

}

struct OpenPetsMessageLayout {
    static let toggleDiameter: CGFloat = 34
    static let messageShadowOutset: CGFloat = 4
    static let verticalGap: CGFloat = 10
    static let messagePanelHorizontalOffset: CGFloat = 5
    static let messagePanelVerticalOffset: CGFloat = -10
    static let stackGap: CGFloat = 8
    static let toggleGapBelowCard: CGFloat = 4
    static let maxCardWidth: CGFloat = 260
    static let closeButtonSize = CGSize(width: 22, height: 22)
    static let closeButtonInset: CGFloat = 8
    static let empty = OpenPetsMessageLayout(containerSize: .zero, cardFrames: [], petFrame: .zero, toggleFrame: .zero)

    var containerSize: CGSize
    var cardFrames: [CGRect]
    var petFrame: CGRect
    var toggleFrame: CGRect

    private static func bounds(for frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { $0.union($1) }
    }

    static func closeButtonFrame(in cardFrame: CGRect) -> CGRect {
        CGRect(
            x: cardFrame.minX + closeButtonInset,
            y: cardFrame.maxY - closeButtonInset - closeButtonSize.height,
            width: closeButtonSize.width,
            height: closeButtonSize.height
        )
    }

    @MainActor
    static func makeMessagePanel(
        messages: [PetMessage],
        isCollapsed: Bool,
        petSize: CGSize,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        guard !messages.isEmpty else { return .empty }
        let cardSizes = isCollapsed ? [] : messages.map {
            OpenPetsBubbleContentView.size(for: $0.bubble, maxWidth: maxCardWidth, messageAreaHeight: messageAreaHeight)
        }
        let rightEdge = max(petSize.width, cardSizes.map(\.width).max() ?? 0, toggleDiameter)
        let petFrame = CGRect(x: rightEdge - petSize.width, y: 0, width: max(1, petSize.width), height: max(1, petSize.height))
        var cardFrames: [CGRect] = []
        var nextY = petFrame.maxY + verticalGap + messagePanelVerticalOffset
        for size in cardSizes {
            cardFrames.append(CGRect(x: rightEdge + messagePanelHorizontalOffset - size.width, y: nextY, width: size.width, height: size.height))
            nextY += size.height + stackGap
        }
        let toggleFrame = CGRect(
            x: rightEdge + messagePanelHorizontalOffset - toggleDiameter,
            y: petFrame.maxY + verticalGap + messagePanelVerticalOffset,
            width: toggleDiameter,
            height: toggleDiameter
        )
        for index in cardFrames.indices { cardFrames[index].origin.y += toggleDiameter + toggleGapBelowCard }
        let messageBounds = bounds(for: cardFrames + [toggleFrame]).insetBy(dx: -messageShadowOutset, dy: -messageShadowOutset)
        let offset = CGVector(dx: -messageBounds.minX, dy: -messageBounds.minY)
        return OpenPetsMessageLayout(
            containerSize: messageBounds.size,
            cardFrames: cardFrames.map { $0.offsetBy(dx: offset.dx, dy: offset.dy) },
            petFrame: petFrame.offsetBy(dx: offset.dx, dy: offset.dy),
            toggleFrame: toggleFrame.offsetBy(dx: offset.dx, dy: offset.dy)
        )
    }
}

@MainActor
final class PetMessagePanelView: NSView {
    var onDismissMessage: ((String) -> Void)?
    var onLayoutChanged: (() -> Void)?

    private let messageAreaHeight: CGFloat
    private let closedModeRevealDurationNanoseconds: UInt64
    private var petSize: CGSize
    private var messageStack = PetMessageStack()
    private var isMessageStackCollapsed = false
    private var isSurfacingClosedModeMessages = false
    private var closedModeRevealTask: Task<Void, Never>?
    private var closedModeRevealGeneration = 0
    private var currentLayout = OpenPetsMessageLayout.empty
    private lazy var hostingView = PassThroughHostingView(rootView: makeRootView(messages: [], layout: .empty))

    var hasVisibleMessages: Bool { messageStack.activeCount > 0 }

    init(petSize: CGSize, messageAreaHeight: CGFloat = 108, closedModeRevealDurationNanoseconds: UInt64 = 5_000_000_000) {
        self.petSize = petSize
        self.messageAreaHeight = messageAreaHeight
        self.closedModeRevealDurationNanoseconds = closedModeRevealDurationNanoseconds
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func layout() { super.layout(); hostingView.frame = bounds }

    func updatePetSize(_ size: CGSize) { petSize = size; relayoutMessages() }

    func setBubble(_ bubble: PetBubble, threadId: String) {
        let shouldSurface = isMessageStackCollapsed
        messageStack.setBubble(bubble, threadId: threadId)
        shouldSurface ? surfaceClosedModeMessagesTemporarily() : relayoutMessages()
    }

    func clearBubble(threadId: String) {
        messageStack.clearBubble(threadId: threadId)
        if messageStack.activeCount == 0 {
            isMessageStackCollapsed = false
            cancelClosedModeReveal()
        }
        relayoutMessages()
    }

    private var isEffectivelyCollapsed: Bool { isMessageStackCollapsed && !isSurfacingClosedModeMessages }

    private func relayoutMessages() {
        let messages = messageStack.visibleMessages()
        currentLayout = OpenPetsMessageLayout.makeMessagePanel(
            messages: messages,
            isCollapsed: isEffectivelyCollapsed,
            petSize: petSize,
            messageAreaHeight: messageAreaHeight
        )
        frame.size = currentLayout.containerSize
        hostingView.rootView = makeRootView(messages: messages, layout: currentLayout)
        hostingView.frame = bounds
        onLayoutChanged?()
    }

    private func makeRootView(messages: [PetMessage], layout: OpenPetsMessageLayout) -> OpenPetsMessageView {
        OpenPetsMessageView(
            messages: messages,
            isCollapsed: isEffectivelyCollapsed,
            activeMessageCount: messageStack.activeCount,
            layout: layout,
            messageAreaHeight: messageAreaHeight,
            onDismiss: { [weak self] in self?.onDismissMessage?($0) },
            onToggle: { [weak self] in self?.toggleMessageStackCollapsed() }
        )
    }

    private func toggleMessageStackCollapsed() {
        guard messageStack.activeCount > 0 else { return }
        isMessageStackCollapsed = !isEffectivelyCollapsed
        cancelClosedModeReveal()
        relayoutMessages()
    }

    private func surfaceClosedModeMessagesTemporarily() {
        closedModeRevealTask?.cancel()
        closedModeRevealGeneration += 1
        isSurfacingClosedModeMessages = true
        relayoutMessages()
        let generation = closedModeRevealGeneration
        closedModeRevealTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: self?.closedModeRevealDurationNanoseconds ?? 0) } catch { return }
            guard let self, self.isMessageStackCollapsed, self.closedModeRevealGeneration == generation else { return }
            self.isSurfacingClosedModeMessages = false
            self.closedModeRevealTask = nil
            self.relayoutMessages()
        }
    }

    private func cancelClosedModeReveal() {
        closedModeRevealTask?.cancel()
        closedModeRevealTask = nil
        closedModeRevealGeneration += 1
        isSurfacingClosedModeMessages = false
    }
}

private final class PassThroughHostingView: NSHostingView<OpenPetsMessageView> {}

private struct OpenPetsMessageView: View {
    let messages: [PetMessage]
    let isCollapsed: Bool
    let activeMessageCount: Int
    let layout: OpenPetsMessageLayout
    let messageAreaHeight: CGFloat
    let onDismiss: (String) -> Void
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !isCollapsed {
                ForEach(Array(zip(messages, layout.cardFrames)), id: \.0.threadId) { message, frame in
                    OpenPetsDismissibleBubbleView(message: message, messageAreaHeight: messageAreaHeight, onDismiss: onDismiss)
                        .position(position(for: frame))
                }
            }
            if !layout.toggleFrame.isEmpty { toggleButton.position(position(for: layout.toggleFrame)) }
        }
        .frame(width: layout.containerSize.width, height: layout.containerSize.height, alignment: .topLeading)
    }

    private func position(for frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: layout.containerSize.height - frame.midY)
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            ZStack {
                Circle().fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.96 : 0.98))
                Circle().stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.6 : 0.35), lineWidth: 1)
                if isCollapsed {
                    Text("\(min(max(activeMessageCount, 1), 99))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                } else {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: OpenPetsMessageLayout.toggleDiameter, height: OpenPetsMessageLayout.toggleDiameter)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Show messages" : "Hide messages")
    }
}

private struct OpenPetsDismissibleBubbleView: View {
    let message: PetMessage
    let messageAreaHeight: CGFloat
    let onDismiss: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        OpenPetsBubbleContentView(bubble: message.bubble, messageAreaHeight: messageAreaHeight, showsHoverActions: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                message.bubble.onActivate?()
            }
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button { onDismiss(message.threadId) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .background(Color(nsColor: colorScheme == .dark ? .black : .white).opacity(colorScheme == .dark ? 0.82 : 0.94))
                    .clipShape(Circle())
                    .overlay { Circle().stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.55 : 0.35), lineWidth: 1) }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.07), radius: 2, x: 0, y: 1)
                    .padding(.top, 8).padding(.leading, 8)
                    .transition(.offset(x: -6).combined(with: .opacity))
                    .accessibilityLabel("Dismiss \(message.bubble.title)")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering } }
    }
}

struct OpenPetsBubbleContentView: View {
    let bubble: PetBubble
    var messageAreaHeight: CGFloat = 108
    var showsHoverActions = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            bubbleContent
            let shown = bubble.actionsRequireHover ? (showsHoverActions ? bubble.actions : []) : bubble.actions
            if !shown.isEmpty { actionRow(shown).padding(.trailing, 8).padding(.bottom, 6) }
        }
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .animation(.easeOut(duration: 0.16), value: showsHoverActions)
    }

    private var bubbleSize: CGSize { Self.size(for: bubble, messageAreaHeight: messageAreaHeight) }

    private var bubbleContent: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bubble.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                if let detail = bubble.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12.5)).lineLimit(bubble.detailLineLimit).truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if bubble.indicator != .none { indicator.frame(width: 16, height: 16) }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 6)
        .padding(.bottom, bubble.actionsRequireHover || bubble.actions.isEmpty ? 0 : 26)
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .background(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.92 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.55 : 0.35), lineWidth: 1) }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 4, x: 0, y: 1)
    }

    private func actionRow(_ actions: [PetBubbleAction]) -> some View {
        HStack(spacing: 4) {
            ForEach(actions.prefix(3)) { action in
                Button { action.handler() } label: {
                    Text(action.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 7).frame(height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(action.tone == .danger ? Color.red : action.tone == .primary ? Color.accentColor : Color.primary)
                .background(Color(nsColor: colorScheme == .dark ? .black : .white).opacity(colorScheme == .dark ? 0.82 : 0.94))
                .clipShape(Capsule())
                .overlay { Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1) }
            }
        }
    }

    static func size(for bubble: PetBubble, maxWidth: CGFloat = 260, messageAreaHeight: CGFloat = 108) -> CGSize {
        let width = min(260, maxWidth)
        var height: CGFloat
        if let detail = bubble.detail, !detail.isEmpty {
            let font = NSFont.systemFont(ofSize: 12.5)
            let rect = NSString(string: detail).boundingRect(with: CGSize(width: width - 54, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let lines = min(bubble.detailLineLimit ?? Int.max, max(1, Int(ceil((rect.height - 0.5) / 15))))
            height = min(messageAreaHeight - 12, 56 + CGFloat(lines - 1) * 16)
        } else { height = min(messageAreaHeight - 12, 44) }
        if !bubble.actions.isEmpty && !bubble.actionsRequireHover { height += 26 }
        return CGSize(width: width, height: height)
    }

    @ViewBuilder private var indicator: some View {
        switch bubble.indicator {
        case .none: EmptyView()
        case .working: ProgressView().scaleEffect(0.5).opacity(0.7)
        case .waiting: statusIcon(color: .orange, symbol: "clock", size: 9)
        case .review: statusIcon(color: .purple, symbol: "eye", size: 8)
        case .success: statusIcon(color: .green, symbol: "checkmark", size: 9)
        case .attention: statusIcon(color: .red, symbol: "xmark", size: 9)
        }
    }

    private func statusIcon(color: Color, symbol: String, size: CGFloat) -> some View {
        ZStack { Circle().fill(color); Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(.white) }
    }
}
