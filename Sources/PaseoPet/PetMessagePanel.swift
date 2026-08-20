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
    static let messageShadowOutset: CGFloat = 8
    static let stackGap: CGFloat = 8
    static let backplateReveal: CGFloat = 8
    static let backplateWidthStep: CGFloat = 12
    static let maxCardWidth: CGFloat = 315
    static let closeButtonSize = CGSize(width: 20, height: 20)
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
        isCollapsed: Bool,
        isExpanded: Bool,
        isBelowPet: Bool,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        guard !messages.isEmpty, !isCollapsed else { return .empty }
        let renderedMessages = isExpanded ? messages : Array(messages.prefix(1))
        let bubbleSizes = renderedMessages.map {
            OpenPetsBubbleContentView.size(for: $0.bubble, maxWidth: maxCardWidth, messageAreaHeight: messageAreaHeight)
        }
        let width = bubbleSizes.map(\.width).max() ?? 0

        if !isExpanded, let size = bubbleSizes.first {
            let backplateCount = min(2, max(0, activeCount - 1))
            let frameSize = CGSize(
                width: size.width + messageShadowOutset * 2,
                height: size.height + messageShadowOutset * 2
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
                width: size.width + messageShadowOutset * 2,
                height: size.height + messageShadowOutset * 2
            ))
            nextY += size.height + stackGap
        }
        let height = cardFrames.last?.maxY ?? 0
        cardFrames = cardFrames.map {
            CGRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height)
        }
        return OpenPetsMessageLayout(
            containerSize: CGSize(width: width + messageShadowOutset * 2, height: height),
            cardFrames: cardFrames,
            backplateFrames: [],
            moreFrame: nil,
            moreCount: 0
        ).addingMore(count: max(0, activeCount - renderedMessages.count), isBelowPet: isBelowPet)
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
        let compact = makeMessagePanel(
            messages: messages,
            activeCount: 5,
            isCollapsed: false,
            isExpanded: false,
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
            isCollapsed: false,
            isExpanded: false,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(representedCompact.backplateFrames.count == 2)
        assert(representedCompact.moreFrame == nil)
        let single = makeMessagePanel(
            messages: Array(messages.prefix(1)),
            activeCount: 1,
            isCollapsed: false,
            isExpanded: false,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(single.cardFrames.count == 1)
        assert(single.backplateFrames.isEmpty)
        assert(single.moreFrame == nil)
        let expanded = makeMessagePanel(
            messages: messages,
            activeCount: 5,
            isCollapsed: false,
            isExpanded: true,
            isBelowPet: false,
            messageAreaHeight: 108
        )
        assert(expanded.cardFrames.count == messages.count)
        assert(expanded.backplateFrames.isEmpty)
        assert(expanded.moreCount == 2)
        assert(expanded.moreFrame != nil)
        assert(visualOrder(in: compact).first == visualOrder(in: expanded).first)
        assert(visualOrder(in: expanded) == messages.map(\.threadId))
        let compactBelow = makeMessagePanel(
            messages: messages,
            activeCount: 3,
            isCollapsed: false,
            isExpanded: false,
            isBelowPet: true,
            messageAreaHeight: 108
        )
        let expandedBelow = makeMessagePanel(
            messages: messages,
            activeCount: 3,
            isCollapsed: false,
            isExpanded: true,
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
    private var isMessageStackCollapsed = false
    private var isStackExpanded = false
    private var stackCollapseItem: DispatchWorkItem?
    private var isBelowPet = false
    private var currentLayout = OpenPetsMessageLayout.empty
    private lazy var hostingView = PassThroughHostingView(rootView: makeRootView(messages: [], layout: .empty, animatesLayout: false))

    var hasMessages: Bool { messageStack.activeCount > 0 }
    var showsMessageCards: Bool { hasMessages && !isMessageStackCollapsed }
    var activeMessageCount: Int { messageStack.activeCount }
    var highestIndicator: PetBubbleIndicator { messageStack.visibleMessages(limit: 1).first?.bubble.indicator ?? .none }
    var isCollapsed: Bool { isMessageStackCollapsed }

    init(petSize: CGSize, messageAreaHeight: CGFloat = 108) {
        self.messageAreaHeight = messageAreaHeight
        super.init(frame: .zero)
#if DEBUG
        PetMessageStack.assertPriorityOrdering()
        OpenPetsMessageLayout.assertStackingBehavior()
#endif
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
#if DEBUG
        assertHiddenStateSurvivesBubbleUpdate()
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
        if messageStack.activeCount < 2 { isStackExpanded = false }
        relayoutMessages()
    }

    private func relayoutMessages(notifyWindow: Bool = true, animatesLayout: Bool = true) {
        let messages = messageStack.visibleMessages()
        currentLayout = OpenPetsMessageLayout.makeMessagePanel(
            messages: messages,
            activeCount: messageStack.activeCount,
            isCollapsed: isMessageStackCollapsed,
            isExpanded: isStackExpanded,
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
        OpenPetsMessageView(
            messages: messages,
            layout: layout,
            messageAreaHeight: messageAreaHeight,
            animatesLayout: animatesLayout,
            onDismiss: { [weak self] in self?.onDismissMessage?($0) },
            onHoverChanged: { [weak self] in self?.setStackHovered($0) }
        )
    }

    func toggleMessageStackCollapsed() {
        guard messageStack.activeCount > 0 else { return }
        isMessageStackCollapsed.toggle()
        stackCollapseItem?.cancel()
        isStackExpanded = false
        relayoutMessages()
    }

    private func setStackHovered(_ hovered: Bool) {
        stackCollapseItem?.cancel()
        guard messageStack.activeCount > 1, !isMessageStackCollapsed else { return }
        if hovered {
            guard !isStackExpanded else { return }
            isStackExpanded = true
            relayoutMessages()
        } else if isStackExpanded {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isStackExpanded else { return }
                self.isStackExpanded = false
                self.relayoutMessages()
            }
            stackCollapseItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
    }

#if DEBUG
    private func assertHiddenStateSurvivesBubbleUpdate() {
        isMessageStackCollapsed = true
        setBubble(PetBubble(title: "debug", indicator: .working), threadId: "debug-hidden")
        assert(isMessageStackCollapsed && !showsMessageCards)
        messageStack.clearBubble(threadId: "debug-hidden")
        isMessageStackCollapsed = false
        relayoutMessages(notifyWindow: false, animatesLayout: false)
    }
#endif
}

private final class PassThroughHostingView: NSHostingView<OpenPetsMessageView> {
    var interactiveFrames: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        let layoutPoint = isFlipped ? NSPoint(x: point.x, y: bounds.height - point.y) : point
        guard interactiveFrames.contains(where: { $0.contains(layoutPoint) }) else { return nil }
        return super.hitTest(point)
    }
}

private struct OpenPetsMessageView: View {
    let messages: [PetMessage]
    let layout: OpenPetsMessageLayout
    let messageAreaHeight: CGFloat
    let animatesLayout: Bool
    let onDismiss: (String) -> Void
    let onHoverChanged: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.backplateFrames.enumerated()), id: \.offset) { _, frame in
                Color.clear
                    .frame(
                        width: frame.width - OpenPetsMessageLayout.messageShadowOutset * 2,
                        height: frame.height - OpenPetsMessageLayout.messageShadowOutset * 2
                    )
                    .codexGlass(in: RoundedRectangle(cornerRadius: 27, style: .continuous), isDark: colorScheme == .dark)
                    .padding(OpenPetsMessageLayout.messageShadowOutset)
                    .transition(.identity)
                    .position(position(for: frame))
            }
            ForEach(Array(zip(messages, layout.cardFrames)), id: \.0.threadId) { message, frame in
                OpenPetsDismissibleBubbleView(message: message, messageAreaHeight: messageAreaHeight, onDismiss: onDismiss)
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
                    .transition(.identity)
                    .position(position(for: frame))
            }
        }
        .frame(width: layout.containerSize.width, height: layout.containerSize.height, alignment: .topLeading)
        .animation(layoutAnimation, value: layout)
        .onHover(perform: onHoverChanged)
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
    let messageAreaHeight: CGFloat
    let onDismiss: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        OpenPetsBubbleContentView(bubble: message.bubble, messageAreaHeight: messageAreaHeight, showsHoverActions: isHovered)
            .padding(OpenPetsMessageLayout.messageShadowOutset)
            .contentShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            .onTapGesture { message.bubble.onActivate?() }
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button { onDismiss(message.threadId) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20, alignment: .center)
                    }
                    .buttonStyle(.plain)
                    .codexGlass(in: Circle(), isDark: colorScheme == .dark)
                    .offset(x: 2, y: 2)
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
            if !bubble.actionsRequireHover, !bubble.actions.isEmpty {
                permissionActionRow(bubble.actions).padding(.trailing, 12).padding(.bottom, 7)
            }
        }
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .animation(.easeOut(duration: 0.16), value: showsHoverActions)
    }

    private var bubbleSize: CGSize { Self.size(for: bubble, messageAreaHeight: messageAreaHeight) }

    private var bubbleContent: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bubble.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = bubble.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(bubble.detailLineLimit)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            trailingContent
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .padding(.bottom, bubble.actionsRequireHover || bubble.actions.isEmpty ? 0 : 30)
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .codexGlass(in: RoundedRectangle(cornerRadius: 27, style: .continuous), isDark: colorScheme == .dark)
    }

    @ViewBuilder private var trailingContent: some View {
        if bubble.actionsRequireHover, showsHoverActions, hoverControlCount > 0 {
            HStack(spacing: 10) {
                if let activate = bubble.onActivate {
                    circleButton(symbol: "arrow.uturn.backward", accessibilityLabel: "Reply", action: activate)
                }
                ForEach(bubble.actions.prefix(2)) { action in
                    circleButton(
                        symbol: action.id == "stop" ? "stop.fill" : "ellipsis",
                        accessibilityLabel: action.label,
                        action: action.handler
                    )
                }
                if bubble.indicator == .review || bubble.indicator == .success {
                    indicator.frame(width: 28, height: 28)
                }
            }
            .transition(.opacity)
        } else if bubble.indicator != .none {
            indicator.frame(width: 28, height: 28)
        }
    }

    private func circleButton(symbol: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28, alignment: .center)
        }
        .buttonStyle(.plain)
        .codexGlass(in: Circle(), isDark: colorScheme == .dark)
        .accessibilityLabel(accessibilityLabel)
    }

    private var hoverControlCount: Int {
        (bubble.onActivate == nil ? 0 : 1)
            + min(bubble.actions.count, 2)
            + ((bubble.indicator == .review || bubble.indicator == .success) ? 1 : 0)
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

    static func size(for bubble: PetBubble, maxWidth: CGFloat = 315, messageAreaHeight: CGFloat = 108) -> CGSize {
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 12.5)
        let titleWidth = ceil(NSString(string: bubble.title).size(withAttributes: [.font: titleFont]).width)
        let detailWidth = bubble.detail.map { ceil(NSString(string: $0).size(withAttributes: [.font: detailFont]).width) } ?? 0
        let trailingWidth: CGFloat
        let hoverControlCount = (bubble.onActivate == nil ? 0 : 1)
            + min(bubble.actions.count, 2)
            + ((bubble.indicator == .review || bubble.indicator == .success) ? 1 : 0)
        if bubble.actionsRequireHover, hoverControlCount > 0 {
            trailingWidth = CGFloat(hoverControlCount * 28 + max(0, hoverControlCount - 1) * 10 + 10)
        } else {
            trailingWidth = bubble.indicator == .none ? 0 : 38
        }
        let width = min(maxWidth, max(200, max(titleWidth, min(detailWidth, maxWidth - 44 - trailingWidth)) + 44 + trailingWidth))
        var height: CGFloat = 54
        if let detail = bubble.detail, !detail.isEmpty {
            let rect = NSString(string: detail).boundingRect(
                with: CGSize(width: max(1, width - 44 - trailingWidth), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: detailFont]
            )
            let lines = min(bubble.detailLineLimit ?? Int.max, max(1, Int(ceil((rect.height - 0.5) / 15))))
            height += CGFloat(lines - 1) * 15
        }
        if !bubble.actions.isEmpty && !bubble.actionsRequireHover { height += 30 }
        height = min(messageAreaHeight, height)
        return CGSize(width: width, height: height)
    }

    @ViewBuilder private var indicator: some View {
        switch bubble.indicator {
        case .none: EmptyView()
        case .working: ProgressView().controlSize(.small).opacity(0.72)
        case .waiting: statusIcon(color: .orange.opacity(0.82), symbol: "clock", size: 12)
        case .review, .success: statusIcon(color: .green.opacity(0.84), symbol: "checkmark", size: 13)
        case .attention: statusIcon(color: .red.opacity(0.82), symbol: "xmark", size: 12)
        }
    }

    private func statusIcon(color: Color, symbol: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }
}

extension View {
    @ViewBuilder
    func codexGlass<S: Shape>(in shape: S, isDark: Bool) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(
                (isDark ? Color(nsColor: .windowBackgroundColor).opacity(0.90) : Color.white.opacity(0.90))
                    .background(.ultraThinMaterial)
            )
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(isDark ? 0.12 : 0.30), lineWidth: 0.75))
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 8, x: 0, y: 3)
        }
    }
}
