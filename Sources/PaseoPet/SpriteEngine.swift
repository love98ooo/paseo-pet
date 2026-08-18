import AppKit

struct SpriteFrame {
    let col: Int
    let row: Int
    let durationMs: Int
}

struct AnimationSequence {
    let frames: [SpriteFrame]
    let loopStartIndex: Int?
}

enum PetState: String, CaseIterable {
    case idle, running, waiting, failed, waving, jumping, review
    case runningRight = "running-right"
    case runningLeft = "running-left"
}

@MainActor
final class SpriteEngine {
    private static let cols = 8
    private static let idleDurations = [280, 110, 110, 140, 140, 320]
    private static let slowMultiplier = 6

    private static let rowDefs: [PetState: (row: Int, frames: Int, dur: Int, lastDur: Int)] = [
        .runningRight: (1, 8, 120, 220),
        .runningLeft:  (2, 8, 120, 220),
        .waving:       (3, 4, 140, 280),
        .jumping:      (4, 5, 140, 280),
        .failed:       (5, 8, 140, 240),
        .waiting:      (6, 6, 150, 260),
        .running:      (7, 6, 120, 220),
        .review:       (8, 6, 150, 280),
    ]

    let rows: Int
    private(set) var currentState: PetState = .idle
    private(set) var lookAngleIndex: Int?
    private(set) var isHovered = false
    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var sequence: AnimationSequence
    private var frameIndex = 0
    private var timer: Timer?
    var onFrame: ((Int, Int, Int) -> Void)? // (col, row, totalRows)

    init(rows: Int) {
        self.rows = rows
        self.sequence = Self.idleSequence() // init uses static; start() will re-evaluate with reduced motion
    }

    func start() {
        sequence = sequenceFor(state: currentState)
        emitCurrentFrame()
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setState(_ state: PetState) {
        guard state != currentState || lookAngleIndex != nil else { return }
        currentState = state
        lookAngleIndex = nil
        frameIndex = 0
        sequence = sequenceFor(state: state)
        emitCurrentFrame()
        scheduleNext()
    }

    private static let lookEnabledStates: Set<PetState> = [.idle, .running, .waving]

    func setLookDirection(_ angleIndex: Int?) {
        guard rows >= 11 else { return }
        guard Self.lookEnabledStates.contains(currentState) else { return }
        guard angleIndex != lookAngleIndex else { return }
        lookAngleIndex = angleIndex

        if let idx = angleIndex {
            timer?.invalidate()
            timer = nil
            let row = 9 + idx / 8
            let col = idx % 8
            onFrame?(col, row, rows)
        } else {
            // Resume current state animation
            frameIndex = 0
            sequence = sequenceFor(state: currentState)
            emitCurrentFrame()
            scheduleNext()
        }
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        guard transientState == nil else { return }
        if hovered {
            lookAngleIndex = nil
            frameIndex = 0
            sequence = sequenceFor(state: .jumping)
            emitCurrentFrame()
            scheduleNext()
        } else {
            frameIndex = 0
            sequence = sequenceFor(state: currentState)
            emitCurrentFrame()
            scheduleNext()
        }
    }

    func setDragDirection(_ dx: CGFloat) {
        if dx >= 4 {
            setTransientState(.runningRight)
        } else if dx <= -4 {
            setTransientState(.runningLeft)
        }
    }

    func clearDragState() {
        setTransientState(nil)
    }

    private var transientState: PetState?

    private func setTransientState(_ state: PetState?) {
        guard state != transientState else { return }
        transientState = state
        if let s = state {
            lookAngleIndex = nil
            frameIndex = 0
            sequence = sequenceFor(state: s)
            emitCurrentFrame()
            scheduleNext()
        } else {
            // Return to current base state
            lookAngleIndex = nil
            frameIndex = 0
            sequence = sequenceFor(state: currentState)
            emitCurrentFrame()
            scheduleNext()
        }
    }

    // MARK: - Private

    private func emitCurrentFrame() {
        let frame = sequence.frames[frameIndex]
        onFrame?(frame.col, frame.row, rows)
    }

    private func scheduleNext() {
        timer?.invalidate()
        let frame = sequence.frames[frameIndex]
        timer = Timer.scheduledTimer(withTimeInterval: Double(frame.durationMs) / 1_000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advance()
            }
        }
    }

    private func advance() {
        frameIndex += 1
        if frameIndex >= sequence.frames.count {
            if let loopStart = sequence.loopStartIndex {
                frameIndex = loopStart
            } else {
                frameIndex = sequence.frames.count - 1
                return
            }
        }
        emitCurrentFrame()
        scheduleNext()
    }

    // MARK: - Sequence builders

    private static func idleSequence() -> AnimationSequence {
        let frames = idleDurations.enumerated().map { (i, dur) in
            SpriteFrame(col: i, row: 0, durationMs: dur)
        }
        return AnimationSequence(frames: frames, loopStartIndex: 0)
    }

    private static func slowIdleFrames() -> [SpriteFrame] {
        idleDurations.enumerated().map { (i, dur) in
            SpriteFrame(col: i, row: 0, durationMs: dur * slowMultiplier)
        }
    }

    private func sequenceFor(state: PetState) -> AnimationSequence {
        if reducedMotion {
            let row = Self.rowDefs[state]?.row ?? 0
            return AnimationSequence(frames: [SpriteFrame(col: 0, row: row, durationMs: 1000)], loopStartIndex: 0)
        }
        if state == .idle { return Self.idleSequence() }
        guard let def = Self.rowDefs[state] else { return Self.idleSequence() }

        let stateFrames = (0..<def.frames).map { i in
            SpriteFrame(col: i, row: def.row, durationMs: i == def.frames - 1 ? def.lastDur : def.dur)
        }
        let repeated = stateFrames + stateFrames + stateFrames
        let slowIdle = Self.slowIdleFrames()
        return AnimationSequence(frames: repeated + slowIdle, loopStartIndex: repeated.count)
    }
}
