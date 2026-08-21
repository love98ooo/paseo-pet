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
        case .review: return .success
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

enum PetBubbleIndicator: Equatable {
    case none, working, waiting, review, success, attention

    var priority: Int {
        switch self {
        case .waiting: return 0
        case .attention: return 1
        case .review, .success: return 2
        case .working: return 3
        case .none: return 4
        }
    }
}

enum MessageStackMode: Int {
    case collapsed = 1
    case stacked = 2
    case expanded = 3

    var afterInteractionButton: MessageStackMode {
        self == .stacked ? .collapsed : .stacked
    }

#if DEBUG
    static func assertInteractionButtonTransitions() {
        assert(MessageStackMode.collapsed.afterInteractionButton == .stacked)
        assert(MessageStackMode.stacked.afterInteractionButton == .collapsed)
        assert(MessageStackMode.expanded.afterInteractionButton == .stacked)
    }
#endif
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
        Array(activeMessages.enumerated()
            .sorted {
                let lhs = $0.element.bubble.indicator.priority
                let rhs = $1.element.bubble.indicator.priority
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            .prefix(max(0, limit))
            .map(\.element))
    }

#if DEBUG
    static func assertPriorityOrdering() {
        func bubble(_ indicator: PetBubbleIndicator) -> PetBubble {
            PetBubble(title: "test", indicator: indicator)
        }
        var stack = PetMessageStack()
        stack.setBubble(bubble(.working), threadId: "running-a")
        stack.setBubble(bubble(.waiting), threadId: "waiting")
        stack.setBubble(bubble(.success), threadId: "review")
        stack.setBubble(bubble(.working), threadId: "running-b")
        assert(stack.visibleMessages().map(\.threadId) == ["waiting", "review", "running-a", "running-b"])
    }
#endif
}

struct OpenPetsMessageLayout: Equatable {
    static let cardOutset: CGFloat = 4
    static let stackGap: CGFloat = 8
    static let backplateReveal: CGFloat = 5
    static let backplateWidthStep: CGFloat = 10
    static let stackedCardWidth: CGFloat = 270
    static let expandedCardWidth: CGFloat = 270
    static let cornerRadius: CGFloat = 27
    static let moreOutset: CGFloat = 4
    static let empty = OpenPetsMessageLayout(
        containerSize: .zero,
        cardFrames: [],
        backplateFrames: [],
        moreFrame: nil,
        moreCount: 0
    )

    var containerSize: CGSize
    var cardFrames: [CGRect]
    var backplateFrames: [CGRect]
    var moreFrame: CGRect?
    var moreCount: Int

    @MainActor
    static func makeMessagePanel(
        messages: [PetMessage],
        activeCount: Int,
        mode: MessageStackMode,
        isBelowPet: Bool,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        guard !messages.isEmpty, mode != .collapsed else { return .empty }
        let renderedMessages = mode == .expanded ? messages : Array(messages.prefix(1))
        let presentation: OpenPetsBubbleContentView.Presentation = mode == .expanded ? .expanded : .stacked
        let maxWidth = mode == .expanded ? expandedCardWidth : stackedCardWidth
        let bubbleSizes = renderedMessages.map {
            OpenPetsBubbleContentView.size(
                for: $0.bubble,
                presentation: presentation,
                maxWidth: maxWidth,
                messageAreaHeight: messageAreaHeight
            )
        }
        let width = bubbleSizes.map(\.width).max() ?? 0

        if mode == .stacked, let size = bubbleSizes.first {
            let backplateCount = min(2, max(0, activeCount - 1))
            let frameSize = CGSize(
                width: size.width + cardOutset * 2,
                height: size.height + cardOutset * 2
            )
            let depth = CGFloat(backplateCount) * backplateReveal
            let cardFrame = CGRect(
                x: 0,
                y: isBelowPet ? 0 : depth,
                width: frameSize.width,
                height: frameSize.height
            )
            let backplateFrames = stride(from: backplateCount, through: 1, by: -1).map { level in
                let plateWidth = frameSize.width - CGFloat(level) * backplateWidthStep
                return CGRect(
                    x: (frameSize.width - plateWidth) / 2,
                    y: isBelowPet
                        ? CGFloat(level) * backplateReveal
                        : CGFloat(backplateCount - level) * backplateReveal,
                    width: plateWidth,
                    height: frameSize.height
                )
            }
            return OpenPetsMessageLayout(
                containerSize: CGSize(width: frameSize.width, height: frameSize.height + depth),
                cardFrames: [cardFrame],
                backplateFrames: backplateFrames,
                moreFrame: nil,
                moreCount: 0
            ).addingMore(count: max(0, activeCount - 1 - backplateCount), isBelowPet: isBelowPet)
        }

        var cardFrames: [CGRect] = []
        var nextY: CGFloat = 0
        for size in bubbleSizes {
            cardFrames.append(CGRect(
                x: (width - size.width) / 2,
                y: nextY,
                width: size.width + cardOutset * 2,
                height: size.height + cardOutset * 2
            ))
            nextY += size.height + stackGap
        }
        let height = cardFrames.last?.maxY ?? 0
        cardFrames = cardFrames.map {
            CGRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height)
        }
        return OpenPetsMessageLayout(
            containerSize: CGSize(width: width + cardOutset * 2, height: height),
            cardFrames: cardFrames,
            backplateFrames: [],
            moreFrame: nil,
            moreCount: 0
        )
    }

    private func addingMore(count: Int, isBelowPet: Bool) -> OpenPetsMessageLayout {
        guard count > 0 else { return self }
        let text = "+\(count) more" as NSString
        let textWidth = ceil(text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        let frameSize = CGSize(width: max(56, textWidth + 20), height: 28)
        var result = self
        if isBelowPet {
            result.cardFrames = result.cardFrames.map { $0.offsetBy(dx: 0, dy: frameSize.height) }
            result.backplateFrames = result.backplateFrames.map { $0.offsetBy(dx: 0, dy: frameSize.height) }
            result.moreFrame = CGRect(x: result.containerSize.width - frameSize.width, y: 0, width: frameSize.width, height: frameSize.height)
        } else {
            result.moreFrame = CGRect(
                x: result.containerSize.width - frameSize.width,
                y: result.containerSize.height,
                width: frameSize.width,
                height: frameSize.height
            )
        }
        result.containerSize.height += frameSize.height
        result.moreCount = count
        return result
    }

#if DEBUG
    @MainActor
    static func assertStackingBehavior() {
        let messages = (0..<3).map {
            PetMessage(threadId: "session-\($0)", bubble: PetBubble(title: "Session \($0)", indicator: .working))
        }
        func visualOrder(in layout: OpenPetsMessageLayout) -> [String] {
            zip(messages, layout.cardFrames)
                .sorted { $0.1.midY > $1.1.midY }
                .map { $0.0.threadId }
        }
        let collapsed = makeMessagePanel(
            messages: messages,
            activeCount: 5,
            mode: .collapsed,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(collapsed == .empty)
        let compact = makeMessagePanel(
            messages: messages,
            activeCount: 5,
            mode: .stacked,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(compact.cardFrames.count == 1)
        assert(compact.backplateFrames.count == 2)
        assert(compact.moreCount == 2)
        assert(compact.moreFrame != nil)
        let representedCompact = makeMessagePanel(
            messages: messages,
            activeCount: 3,
            mode: .stacked,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(representedCompact.backplateFrames.count == 2)
        assert(representedCompact.moreFrame == nil)
        let single = makeMessagePanel(
            messages: Array(messages.prefix(1)),
            activeCount: 1,
            mode: .stacked,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(single.cardFrames.count == 1)
        assert(single.backplateFrames.isEmpty)
        assert(single.moreFrame == nil)
        let expanded = makeMessagePanel(
            messages: messages,
            activeCount: 5,
            mode: .expanded,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(expanded.cardFrames.count == messages.count)
        assert(expanded.backplateFrames.isEmpty)
        assert(expanded.moreCount == 0)
        assert(expanded.moreFrame == nil)
        assert(visualOrder(in: compact).first == visualOrder(in: expanded).first)
        assert(visualOrder(in: expanded) == messages.map(\.threadId))
        let compactBelow = makeMessagePanel(
            messages: messages,
            activeCount: 3,
            mode: .stacked,
            isBelowPet: true,
            messageAreaHeight: 108
        )
        let expandedBelow = makeMessagePanel(
            messages: messages,
            activeCount: 3,
            mode: .expanded,
            isBelowPet: true,
            messageAreaHeight: 108
        )
        assert(visualOrder(in: compactBelow).first == visualOrder(in: expandedBelow).first)
        assert(visualOrder(in: expandedBelow) == messages.map(\.threadId))
    }
#endif
}

@MainActor
final class PetMessagePanelView: NSView {
    var onDismissMessage: ((String) -> Void)?
    var onLayoutChanged: (() -> Void)?

    private let messageAreaHeight: CGFloat
    private var messageStack = PetMessageStack()
    private var stackMode: MessageStackMode = .stacked
    private var isBelowPet = false
    private var currentLayout = OpenPetsMessageLayout.empty
    private lazy var hostingView = PassThroughHostingView(rootView: makeRootView(messages: [], layout: .empty, animatesLayout: false))

    var hasMessages: Bool { messageStack.activeCount > 0 }
    var showsMessageCards: Bool { hasMessages && stackMode != .collapsed }
    var activeMessageCount: Int { messageStack.activeCount }
    var highestIndicator: PetBubbleIndicator { messageStack.visibleMessages(limit: 1).first?.bubble.indicator ?? .none }
    var mode: MessageStackMode { stackMode }

    init(petSize: CGSize, messageAreaHeight: CGFloat = 108) {
        self.messageAreaHeight = messageAreaHeight
        super.init(frame: .zero)
#if DEBUG
        MessageStackMode.assertInteractionButtonTransitions()
        PetMessageStack.assertPriorityOrdering()
        OpenPetsMessageLayout.assertStackingBehavior()
#endif
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
#if DEBUG
        assertHiddenStateSurvivesBubbleUpdate()
        assertStackModeBehavior()
#endif
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func layout() { super.layout(); hostingView.frame = bounds }

    func updatePetSize(_ size: CGSize) {}

    func setIsBelowPet(_ value: Bool) {
        guard isBelowPet != value else { return }
        isBelowPet = value
        relayoutMessages(notifyWindow: false, animatesLayout: false)
    }

    func setBubble(_ bubble: PetBubble, threadId: String) {
        messageStack.setBubble(bubble, threadId: threadId)
        relayoutMessages()
    }

    func clearBubble(threadId: String) {
        messageStack.clearBubble(threadId: threadId)
        if messageStack.activeCount < 2, stackMode == .expanded { stackMode = .stacked }
        if messageStack.activeCount == 0 { stackMode = .stacked }
        relayoutMessages()
    }

    private func relayoutMessages(notifyWindow: Bool = true, animatesLayout: Bool = true) {
        let messages = messageStack.visibleMessages()
        currentLayout = OpenPetsMessageLayout.makeMessagePanel(
            messages: messages,
            activeCount: messageStack.activeCount,
            mode: stackMode,
            isBelowPet: isBelowPet,
            messageAreaHeight: messageAreaHeight
        )
        frame.size = currentLayout.containerSize
        hostingView.rootView = makeRootView(messages: messages, layout: currentLayout, animatesLayout: animatesLayout)
        hostingView.interactiveFrames = currentLayout.cardFrames
            + currentLayout.backplateFrames
            + (currentLayout.moreFrame.map { [$0] } ?? [])
        hostingView.frame = bounds
        if notifyWindow { onLayoutChanged?() }
    }

    private func makeRootView(messages: [PetMessage], layout: OpenPetsMessageLayout, animatesLayout: Bool) -> OpenPetsMessageView {
        let canExpand = stackMode == .stacked && messageStack.activeCount > 1
        return OpenPetsMessageView(
            messages: messages,
            layout: layout,
            mode: stackMode,
            messageAreaHeight: messageAreaHeight,
            animatesLayout: animatesLayout,
            onDismiss: { [weak self] in self?.onDismissMessage?($0) },
            onExpand: canExpand ? { [weak self] in self?.expandStack() } : nil
        )
    }

    func advanceStackModeFromInteractionButton() {
        guard messageStack.activeCount > 0 else { return }
        stackMode = stackMode.afterInteractionButton
        relayoutMessages()
    }

    private func expandStack() {
        guard stackMode == .stacked, messageStack.activeCount > 1 else { return }
        stackMode = .expanded
        relayoutMessages()
    }

#if DEBUG
    private func assertHiddenStateSurvivesBubbleUpdate() {
        stackMode = .collapsed
        setBubble(PetBubble(title: "debug", indicator: .working), threadId: "debug-hidden")
        assert(stackMode == .collapsed && !showsMessageCards)
        messageStack.clearBubble(threadId: "debug-hidden")
        stackMode = .stacked
        relayoutMessages(notifyWindow: false, animatesLayout: false)
    }

    private func assertStackModeBehavior() {
        setBubble(PetBubble(title: "first", indicator: .working), threadId: "debug-first")
        expandStack()
        assert(stackMode == .stacked)
        setBubble(PetBubble(title: "second", indicator: .working), threadId: "debug-second")
        expandStack()
        assert(stackMode == .expanded)
        clearBubble(threadId: "debug-second")
        assert(stackMode == .stacked)
        clearBubble(threadId: "debug-first")
    }
#endif
}

private final class PassThroughHostingView: NSHostingView<OpenPetsMessageView> {
    var interactiveFrames: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveFrames.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point)
    }
}

private struct OpenPetsMessageView: View {
    let messages: [PetMessage]
    let layout: OpenPetsMessageLayout
    let mode: MessageStackMode
    let messageAreaHeight: CGFloat
    let animatesLayout: Bool
    let onDismiss: (String) -> Void
    let onExpand: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.backplateFrames.enumerated()), id: \.offset) { level, frame in
                Color.clear
                    .frame(
                        width: frame.width - OpenPetsMessageLayout.cardOutset * 2,
                        height: frame.height - OpenPetsMessageLayout.cardOutset * 2
                    )
                    .codexGlass(
                        in: RoundedRectangle(cornerRadius: OpenPetsMessageLayout.cornerRadius, style: .continuous),
                        isDark: colorScheme == .dark
                    )
                    .opacity(level == 0 ? 0.56 : 0.78)
                    .padding(OpenPetsMessageLayout.cardOutset)
                    .contentShape(Rectangle())
                    .onTapGesture { onExpand?() }
                    .transition(.identity)
                    .position(position(for: frame))
            }
            ForEach(Array(zip(messages, layout.cardFrames)), id: \.0.threadId) { message, frame in
                OpenPetsDismissibleBubbleView(
                    message: message,
                    presentation: mode == .expanded ? .expanded : .stacked,
                    messageAreaHeight: messageAreaHeight,
                    onDismiss: onDismiss,
                    onTap: onExpand ?? { message.bubble.onActivate?() }
                )
                .transition(.identity)
                .position(position(for: frame))
            }
            if let frame = layout.moreFrame, layout.moreCount > 0 {
                Text("+\(layout.moreCount) more")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: frame.width - OpenPetsMessageLayout.moreOutset * 2,
                        height: frame.height - OpenPetsMessageLayout.moreOutset * 2
                    )
                    .codexGlass(in: Capsule(), isDark: colorScheme == .dark)
                    .padding(OpenPetsMessageLayout.moreOutset)
                    .contentShape(Rectangle())
                    .onTapGesture { onExpand?() }
                    .transition(.identity)
                    .position(position(for: frame))
            }
        }
        .frame(width: layout.containerSize.width, height: layout.containerSize.height, alignment: .topLeading)
        .animation(layoutAnimation, value: layout)
    }

    private func position(for frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: layout.containerSize.height - frame.midY)
    }

    private var layoutAnimation: Animation? {
        animatesLayout && !reduceMotion
            ? .timingCurve(0.4, 0, 0.6, 1, duration: 0.22)
            : nil
    }

}

private struct OpenPetsDismissibleBubbleView: View {
    let message: PetMessage
    let presentation: OpenPetsBubbleContentView.Presentation
    let messageAreaHeight: CGFloat
    let onDismiss: (String) -> Void
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        OpenPetsBubbleContentView(
            bubble: message.bubble,
            presentation: presentation,
            messageAreaHeight: messageAreaHeight,
            showsHoverActions: isHovered
        )
        .padding(OpenPetsMessageLayout.cardOutset)
        .contentShape(RoundedRectangle(cornerRadius: OpenPetsMessageLayout.cornerRadius, style: .continuous))
        .onTapGesture(perform: onTap)
        .overlay(alignment: .topLeading) {
            if isHovered {
                OpenPetsHoverButton(
                    symbol: "xmark",
                    accessibilityLabel: "Dismiss \(message.bubble.title)",
                    size: 20,
                    action: { onDismiss(message.threadId) }
                )
                .offset(x: 2, y: 2)
                .transition(.offset(x: -6).combined(with: .opacity))
            }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering } }
    }
}

struct OpenPetsBubbleContentView: View {
    enum Presentation { case stacked, expanded }

    let bubble: PetBubble
    var presentation: Presentation = .stacked
    var messageAreaHeight: CGFloat = 108
    var showsHoverActions = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        bubbleContent
            .overlay(alignment: .trailing) {
                if bubble.actionsRequireHover, showsHoverActions, hoverControlCount > 0 {
                    hoverActionRow.padding(.trailing, 14)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !bubble.actionsRequireHover, !bubble.actions.isEmpty {
                    permissionActionRow(bubble.actions).padding(.trailing, 10).padding(.bottom, 5)
                }
            }
            .frame(width: bubbleSize.width, height: bubbleSize.height)
            .animation(.easeOut(duration: 0.16), value: showsHoverActions)
    }

    private var bubbleSize: CGSize {
        Self.size(
            for: bubble,
            presentation: presentation,
            maxWidth: presentation == .expanded ? OpenPetsMessageLayout.expandedCardWidth : OpenPetsMessageLayout.stackedCardWidth,
            messageAreaHeight: messageAreaHeight
        )
    }

    private var bubbleContent: some View {
        HStack(alignment: .center, spacing: 8) {
            messageText
            Spacer(minLength: 0)
            trailingContent
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.bottom, bubble.actionsRequireHover || bubble.actions.isEmpty ? 0 : 28)
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .codexGlass(
            in: RoundedRectangle(cornerRadius: OpenPetsMessageLayout.cornerRadius, style: .continuous),
            isDark: colorScheme == .dark
        )
    }

    private var messageText: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bubble.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail = bubble.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    @ViewBuilder private var trailingContent: some View {
        switch bubble.indicator {
        case .none, .working:
            EmptyView()
        default:
            indicator.frame(width: 24, height: 24)
        }
    }

    private var hoverActionRow: some View {
        HStack(spacing: 6) {
            if let activate = bubble.onActivate {
                OpenPetsHoverButton(symbol: "arrow.uturn.backward", accessibilityLabel: "Reply", action: activate)
            }
            ForEach(bubble.actions.prefix(2)) { action in
                OpenPetsHoverButton(
                    symbol: action.id == "stop" ? "stop.fill" : "ellipsis",
                    accessibilityLabel: action.label,
                    action: action.handler
                )
            }
        }
        .transition(.opacity)
    }

    private var hoverControlCount: Int {
        (bubble.onActivate == nil ? 0 : 1) + min(bubble.actions.count, 2)
    }

    private func permissionActionRow(_ actions: [PetBubbleAction]) -> some View {
        HStack(spacing: 6) {
            ForEach(actions.prefix(3)) { action in
                Button { action.handler() } label: {
                    Text(action.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(action.tone == .danger ? Color.red : action.tone == .primary ? Color.accentColor : Color.primary)
                .codexGlass(in: Capsule(), isDark: colorScheme == .dark)
            }
        }
    }

    static func size(
        for bubble: PetBubble,
        presentation: Presentation = .stacked,
        maxWidth: CGFloat = OpenPetsMessageLayout.stackedCardWidth,
        messageAreaHeight: CGFloat = 108
    ) -> CGSize {
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 13)
        let titleWidth = ceil(NSString(string: bubble.title).size(withAttributes: [.font: titleFont]).width)
        let detailWidth = bubble.detail.map { ceil(NSString(string: $0).size(withAttributes: [.font: detailFont]).width) } ?? 0
        let contentWidth = max(titleWidth, detailWidth)
        let indicatorWidth: CGFloat = switch bubble.indicator {
        case .none, .working: 0
        default: 34
        }
        let width = min(maxWidth, max(220, contentWidth + 32 + indicatorWidth))
        var height: CGFloat = detailWidth > 0 ? 54 : 46
        if !bubble.actions.isEmpty && !bubble.actionsRequireHover { height += 28 }
        return CGSize(width: width, height: min(messageAreaHeight, height))
    }

    @ViewBuilder private var indicator: some View {
        switch bubble.indicator {
        case .none: EmptyView()
        case .working: EmptyView()
        case .waiting: statusIcon(color: .orange.opacity(0.82), symbol: "clock", size: 10)
        case .review, .success: statusIcon(color: .green.opacity(0.84), symbol: "checkmark", size: 11)
        case .attention: statusIcon(color: .red.opacity(0.82), symbol: "xmark", size: 10)
        }
    }

    private func statusIcon(color: Color, symbol: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
    }
}

private struct OpenPetsHoverButton: View {
    let symbol: String
    let accessibilityLabel: String
    var size: CGFloat = 30
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size == 20 ? 9 : 12, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .codexGlass(in: Circle(), isDark: colorScheme == .dark)
                .overlay {
                    Circle().fill(Color.primary.opacity(isHovered ? 0.12 : 0))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

extension View {
    func codexGlass<S: Shape>(in shape: S, isDark: Bool) -> some View {
        background(.ultraThinMaterial)
            .background(
                (isDark
                    ? Color(red: 0.15, green: 0.13, blue: 0.12)
                    : Color(red: 1.00, green: 0.975, blue: 0.94))
                    .opacity(0.55)
            )
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(isDark ? 0.10 : 0.42), lineWidth: 0.5))
    }
}
