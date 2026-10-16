// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// A trackpad window gesture, from the first finger down to the last one up,
/// as a pure value.
///
/// ```
///   idle ──began (on target)──▶ swipe ──ended──▶ commit ──▶ swallowingMomentum ──momentum ends──▶ idle
///     │                           │  ▲
///     │                           │  └─ still ≥ stepPause: step validated (haptic)
///     │                           └─ Escape, or still ≥ cancelTimeout ──▶ swipeCancelled (until the lift)
///     └─began (off target)──▶ nothing: everything passes until the next began
/// ```
///
/// Pinches follow the same pattern (`pinch`, `pinchCancelled`,
/// `pinchPassThrough`); their end comes from the phase when the event carries
/// one, from a `pinchSessionGap` silence otherwise. A pinch never chains steps
/// with the fingers down. A pinch that has a double (pinch in → pinch in twice)
/// goes through `pinchAwaitingSecond` for `doublePinchInterval` before acting.
/// The double tap acts at once.
///
/// Three rules carry the rest:
///
/// 1. The action fires on the lift, never before. That is what allows ↓ alone
///    (minimize) and ↓ then → (bottom right quarter): acting during the
///    gesture, ↓ would already have minimized the window.
/// 2. The target is decided once, when the gesture begins, by `isOnTarget`.
///    The host runs its Accessibility hit test there, which is costly, so it
///    is asked once per gesture. A gesture with no enabled action on its
///    target is not captured. The whole gesture, momentum included, is then
///    swallowed or passed as one block: an app that received half a scroll
///    could stay stuck in the middle of one.
/// 3. Pauses produce no events: still fingers send nothing. The machine
///    exposes `nextDeadline`, and the host wakes it with `.tick` at that time.
///
/// Nothing here touches AppKit, real time or a thread: the host provides the
/// clock, and every case replays in tests.
struct ForkTrackpadGestureMachine {
    typealias Action = ForkTrackpadGestureAction
    typealias Target = ForkTrackpadGestureTarget

    struct Configuration: Equatable {
        var swipeEnabled = true
        var pinchEnabled = true
        /// Gestures switched off one by one. A disabled gesture shows neither
        /// a preview nor an action: its sequence reads as an unknown one. The
        /// rest of its family still works (↓ off, ↓↓ and ↓ then → still work).
        /// When a whole family is off on a target, it is not captured there.
        var disabledActions: Set<Action> = []
        /// Accumulated scroll, over one step, past which a swipe direction
        /// becomes a candidate.
        var swipeThreshold: Double = 5
        /// A movement reads as a diagonal when its minor axis reaches this
        /// share of its major axis. tan 30°: from 30° to 60° it is a diagonal,
        /// closer to an axis it is a half. Above 1, no diagonals at all.
        var diagonalRatio: Double = 0.577
        /// The same for pinches, in magnification relative to the step.
        var pinchThreshold: Double = 0.02
        /// Stillness that validates the current step, so another one can
        /// follow without lifting the fingers. Only ↑↑, ↓↓ and changes of mind
        /// need it now that diagonals give quarters in one movement.
        var stepPause: TimeInterval = 0.15
        /// Stillness that cancels the gesture.
        var cancelTimeout: TimeInterval = 0.8
        /// Silence that stands for "fingers lifted" on a pinch without phase.
        var pinchSessionGap: TimeInterval = 0.15
        /// After a pinch that has a double, the time left to start the second
        /// one, counted from the lift. The first only acts afterwards, so
        /// closing waits that long. Two natural pinches in a row were measured
        /// 0.30 s apart.
        var doublePinchInterval: TimeInterval = 0.4
        /// False: the machine follows gestures but lets every event through,
        /// so the host can use a listen-only tap.
        var blocksEvents = false
        /// Below these, an event is not a movement: it delays neither the
        /// step validation nor the cancellation.
        var scrollMovementEpsilon: Double = 0.1
        var pinchMovementEpsilon: Double = 0.002
        /// Once a quarter has combined two axes, how far back toward the
        /// centre an axis must ease, relative to `swipeThreshold`, before it
        /// lets go to neutral: smaller than entering an extreme, so the zone
        /// does not flicker right at the boundary.
        var combinedReleaseShare: Double = 0.5
    }

    /// Trackpad gesture phases, without AppKit. For a scroll, `phase` is `nil`
    /// during momentum and for a mouse wheel; `momentum` is `nil` while the
    /// fingers are down.
    enum Phase: Equatable {
        case mayBegin, began, changed, ended, cancelled
    }

    enum Event: Equatable {
        case scroll(phase: Phase?, momentum: Phase?, dx: Double, dy: Double)
        /// `cumulative`: magnification since the pinch began, positive when
        /// spreading. `phase`: `nil` when the host does not know it.
        case magnify(cumulative: Double, phase: Phase?)
        /// Two fingers touched twice: macOS's smart zoom, sent only while
        /// Trackpad › Smart zoom is on (the default).
        case smartMagnify
        case escape
        case tick
    }

    enum Disposition: Equatable {
        case pass, swallow
    }

    enum Preview: Equatable {
        case action(Action)
        /// A sequence that matches nothing: the lift will do nothing, and the
        /// preview says so rather than disappearing.
        case unrecognized
    }

    enum Haptic: Equatable {
        case step, cancel
    }

    enum CancelReason: Equatable {
        /// Still for longer than `cancelTimeout`.
        case stillness
        case escape
        /// The system interrupted the gesture (phase `cancelled`).
        case interrupted
    }

    enum Effect: Equatable {
        case showPreview(Preview)
        case hidePreview
        case haptic(Haptic)
        case commit(Action)
        case cancelled(CancelReason)
    }

    struct Output: Equatable {
        var disposition: Disposition
        var effects: [Effect]
    }

    var configuration: Configuration

    private var state: State = .idle
    private var shownPreview: Preview?

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    // MARK: - State

    private struct SwipeTracking: Equatable {
        var target: Target
        var steps: [ForkTrackpadSwipeDirection] = []
        var candidate: ForkTrackpadSwipeDirection?
        var accX: Double = 0
        var accY: Double = 0
        var lastMovementAt: TimeInterval
        /// False while the gesture was only armed by `mayBegin` (fingers down,
        /// not moved yet): the `began` that follows continues this gesture
        /// instead of opening another one.
        var hasBegun: Bool
        /// Set the moment a quarter first forms (see
        /// `ForkTrackpadGestureSequence.combinedZones`); from then on each
        /// axis is tracked on its own, continuously, in place of more steps.
        /// Mutually exclusive with `grid`: whichever the grid modifier's
        /// state said at that same moment.
        var combined: CombinedTracking?
        /// Set instead of `combined`, at that same moment, when the grid
        /// modifier was held then: the same continuous tracking, with a
        /// second stop on the horizontal for two thirds, and sixths where
        /// it meets a vertical half.
        var grid: GridTracking?
    }

    /// Two axis zones, each tracked on its own once a quarter has formed:
    /// a reversal flips only the axis that reverses, and easing an axis back
    /// toward the middle lets it go to neutral, both without needing a pause.
    /// `horizontal`/`vertical` start at whatever formed the quarter and only
    /// change from there, which is why this is not simply recomputed from
    /// `accX`/`accY` alone: the same accumulated position means something
    /// different depending on which side it was last reached from.
    private struct CombinedTracking: Equatable {
        var horizontal: ForkTrackpadSwipeDirection?
        var vertical: ForkTrackpadSwipeDirection?
        var accX: Double = 0
        var accY: Double = 0
    }

    /// One edge and how far out from it: one stop for a third, two for two
    /// thirds.
    private struct GridEdge: Equatable {
        var edge: ForkTrackpadSwipeDirection
        var span: Int
    }

    /// One stop of the horizontal's own ladder (point 3): which column the
    /// window starts at (0 = left, 1 = centre, 2 = right) and how many
    /// columns wide it is (1 or 2). The same ladder applies whether or not
    /// a vertical half has confined it to a row; only what `resolveGrid`
    /// reads each stop as differs.
    private struct GridColumn: Equatable {
        var column: Int
        var span: Int
    }

    /// The grid modifier's own version of `CombinedTracking`: both axes also
    /// remember how far out they are (one stop for a third or a half, two
    /// for two thirds or the centre sixth).
    private struct GridTracking: Equatable {
        var horizontal: GridColumn?
        var vertical: GridEdge?
        var accX: Double = 0
        var accY: Double = 0
        /// Where `accX` stood the moment the ladder last moved: seeded at
        /// the threshold that first committed it, like `accX` itself, and
        /// from there on kept only by `gridRowStep`.
        var horizontalBase: Double = 0
    }

    private struct PinchTracking: Equatable {
        var target: Target
        var steps: [ForkTrackpadPinchDirection] = []
        var candidate: ForkTrackpadPinchDirection?
        var stepBase: Double = 0
        /// The magnification, relative to the step, of largest amplitude. It
        /// decides, not the last one: while relaxing, fingers often bring the
        /// magnification back under the threshold just before the lift.
        var stepPeak: Double = 0
        var lastMagnitude: Double = 0
        var lastMovementAt: TimeInterval
        var lastEventAt: TimeInterval
        var usesPhase: Bool
        /// The second pinch of a double: it waits for no other.
        var isSecond = false
        /// Its fallback: the first pinch's action, which fires if the second
        /// leads nowhere. `nil` when that action is off.
        var fallback: Action?
    }

    /// A lifted pinch whose action waits to see whether a second one follows.
    private struct PendingPinch: Equatable {
        var target: Target
        var steps: [ForkTrackpadPinchDirection]
        /// `nil` when the single action is off: pinching in once then does
        /// nothing, but twice still quits.
        var action: Action?
        var deadline: TimeInterval
        var usesPhase: Bool
    }

    private enum State: Equatable {
        case idle
        case swipe(SwipeTracking)
        case swipeCancelled
        case swallowingMomentum
        case pinch(PinchTracking)
        case pinchCancelled(lastEventAt: TimeInterval, usesPhase: Bool)
        case pinchPassThrough(lastEventAt: TimeInterval, usesPhase: Bool)
        case pinchAwaitingSecond(PendingPinch)
    }

    /// Whether a gesture is being followed (and so, when blocking, swallowed).
    var isTracking: Bool {
        switch state {
        case .swipe, .pinch: return true
        default: return false
        }
    }

    /// The next time the host must send `.tick`, `nil` when nothing waits.
    var nextDeadline: TimeInterval? {
        switch state {
        case let .swipe(t):
            var deadline = t.lastMovementAt + configuration.cancelTimeout
            if t.candidate != nil {
                deadline = min(deadline, t.lastMovementAt + configuration.stepPause)
            }
            return deadline
        case let .pinch(p):
            var deadline = p.lastMovementAt + configuration.cancelTimeout
            if !p.usesPhase {
                deadline = min(deadline, p.lastEventAt + configuration.pinchSessionGap)
            }
            return deadline
        case let .pinchCancelled(lastEventAt, usesPhase),
             let .pinchPassThrough(lastEventAt, usesPhase):
            return usesPhase ? nil : lastEventAt + configuration.pinchSessionGap
        case let .pinchAwaitingSecond(pending):
            return pending.deadline
        case .idle, .swipeCancelled, .swallowingMomentum:
            return nil
        }
    }

    /// Drops any gesture in progress, without action or haptic feedback.
    ///
    /// For a host whose tap macOS just disabled: events were lost, so the
    /// gesture in progress has no reliable end any more. Returns the effect
    /// that hides the preview if one was shown.
    mutating func reset() -> [Effect] {
        var effects: [Effect] = []
        show(nil, effects: &effects)
        state = .idle
        return effects
    }

    // MARK: - Input

    /// `isOnTarget` is only called when a gesture begins, never during one. It
    /// returns the kind of target under the pointer, or `nil` for none.
    mutating func handle(_ event: Event, at now: TimeInterval, gridModifierHeld: Bool = false,
                         isOnTarget: () -> Target?) -> Output {
        var effects: [Effect] = []
        let captured: Bool

        switch event {
        case let .scroll(phase, momentum, dx, dy):
            captured = handleScroll(phase: phase, momentum: momentum, dx: dx, dy: dy,
                                    now: now, isOnTarget: isOnTarget, effects: &effects)
        case let .magnify(cumulative, phase):
            captured = handleMagnify(cumulative, phase: phase, now: now,
                                     isOnTarget: isOnTarget, effects: &effects)
        case .smartMagnify:
            captured = handleSmartMagnify(isOnTarget: isOnTarget, effects: &effects)
        case .escape:
            captured = handleEscape(effects: &effects)
        case .tick:
            handleTick(now: now, gridModifierHeld: gridModifierHeld, effects: &effects)
            captured = false
        }

        let blocks = captured && configuration.blocksEvents
        return Output(disposition: blocks ? .swallow : .pass, effects: effects)
    }

    // MARK: - Swipe

    private mutating func handleScroll(phase: Phase?, momentum: Phase?, dx: Double, dy: Double,
                                       now: TimeInterval, isOnTarget: () -> Target?,
                                       effects: inout [Effect]) -> Bool {
        // A swipe while a second pinch is awaited: the first acts at once, and
        // this event is not followed. Following it would need a hit test in
        // the same call, and the pinch's action would then go to the new
        // target.
        if case let .pinchAwaitingSecond(pending) = state {
            settle(pending, effects: &effects)
            return false
        }

        // The momentum after a captured gesture is swallowed too: otherwise
        // the freshly placed window would scroll on its own right after.
        if let momentum {
            guard case .swallowingMomentum = state else { return false }
            if momentum == .ended || momentum == .cancelled { state = .idle }
            return true
        }

        // Neither phase nor momentum: a mouse wheel. Never a gesture.
        guard let phase else { return false }

        switch phase {
        case .mayBegin, .began:
            if phase == .began, case var .swipe(t) = state, !t.hasBegun {
                // Armed by `mayBegin`: the same gesture is starting.
                t.hasBegun = true
                state = .swipe(t)
                return true
            }
            // A new gesture. Whatever was left of a previous one (lost
            // phases) is dropped without action.
            show(nil, effects: &effects)
            guard configuration.swipeEnabled,
                  ForkTrackpadGestureCatalog.hasEnabledAction(.swipe, disabled: configuration.disabledActions),
                  let target = isOnTarget(),
                  ForkTrackpadGestureSequence.accepts(.swipe, on: target,
                                                        disabled: configuration.disabledActions)
            else {
                state = .idle
                return false
            }
            state = .swipe(SwipeTracking(target: target, lastMovementAt: now, hasBegun: phase == .began))
            return true

        case .changed:
            switch state {
            case var .swipe(t):
                // Compared by the action it names, not the raw tracking it
                // comes from: a vertical half pushed from a third to two
                // thirds (see `GridTracking`) changes how far out the
                // vertical stands without changing which corner sixth that
                // names, and that must not buzz on its own.
                let previousAction = rawAction(for: t)
                move(&t, dx: dx, dy: dy, now: now)
                if rawAction(for: t) != previousAction {
                    // A quarter (or a grid zone) already stood, and an axis
                    // just flipped or let go: the same little confirmation a
                    // paused step gives, without needing a pause now that
                    // nothing waits for one.
                    effects.append(.haptic(.step))
                }
                state = .swipe(t)
                if let update = preview(for: t) { show(update, effects: &effects) }
                return true
            case .swipeCancelled:
                return true
            default:
                return false
            }

        case .ended:
            switch state {
            case let .swipe(t):
                show(nil, effects: &effects)
                if let action = action(for: t) {
                    effects.append(.commit(action))
                }
                state = .swallowingMomentum
                return true
            case .swipeCancelled:
                state = .swallowingMomentum
                return true
            default:
                return false
            }

        case .cancelled:
            // The system interrupted the gesture: never an action, and no
            // momentum to wait for.
            switch state {
            case let .swipe(t):
                abandon(pending: !t.steps.isEmpty || t.candidate != nil || t.combined != nil
                            || t.grid != nil, reason: .interrupted, effects: &effects)
                state = .idle
                return true
            case .swipeCancelled:
                state = .idle
                return true
            default:
                return false
            }
        }
    }

    /// Which of `t.grid`/`t.combined` moves (set once, in `handleTick`, by
    /// whether the grid modifier was held the moment the first quarter or
    /// grid zone formed) decides how this reads the movement; this itself
    /// takes no view of the modifier's current state.
    private func move(_ t: inout SwipeTracking, dx: Double, dy: Double, now: TimeInterval) {
        guard abs(dx) + abs(dy) >= configuration.scrollMovementEpsilon else { return }
        t.lastMovementAt = now
        let enter = configuration.swipeThreshold
        let release = enter * configuration.combinedReleaseShare
        if var grid = t.grid {
            grid.accX += dx
            grid.accY += dy
            grid.vertical = Self.gridEdgeAndSpan(current: grid.vertical, accumulated: grid.accY,
                                                 enter: enter, release: release, negative: .up, positive: .down)
            // The same ladder slides the horizontal whether or not a row is
            // chosen: `resolveGrid` is what reads a stop as a third, two
            // thirds or the centre third with no vertical held, and as a
            // sixth or two sixths within a row once one is. Tracking it
            // this way, always, also means a vertical letting go and
            // recommitting mid-slide (hand wobble) never loses the
            // horizontal's own place: there is only ever the one ladder.
            grid.horizontal = Self.gridRowStep(current: grid.horizontal, base: &grid.horizontalBase,
                                               accumulated: grid.accX, enter: enter)
            t.grid = grid
            return
        }
        if var combined = t.combined {
            combined.accX += dx
            combined.accY += dy
            combined.horizontal = Self.axisZone(current: combined.horizontal, accumulated: combined.accX,
                                                enter: enter, release: release, negative: .left, positive: .right)
            combined.vertical = Self.axisZone(current: combined.vertical, accumulated: combined.accY,
                                              enter: enter, release: release, negative: .up, positive: .down)
            t.combined = combined
            return
        }
        t.accX += dx
        t.accY += dy
        t.candidate = max(abs(t.accX), abs(t.accY)) >= configuration.swipeThreshold
            ? Self.direction(dx: t.accX, dy: t.accY, diagonalRatio: configuration.diagonalRatio)
            : nil
    }

    /// Where one axis sits, given where it already was. Already at an
    /// extreme, it stays there until the movement either reverses past the
    /// full threshold the other way, flipping straight across, or eases back
    /// under the release threshold, letting go to neutral; starting neutral,
    /// it only ever enters at the full threshold, never through the easier
    /// release band, so it cannot talk itself into a quarter by trembling.
    private static func axisZone(current: ForkTrackpadSwipeDirection?, accumulated: Double,
                                 enter: Double, release: Double,
                                 negative: ForkTrackpadSwipeDirection,
                                 positive: ForkTrackpadSwipeDirection) -> ForkTrackpadSwipeDirection? {
        if accumulated <= -enter { return negative }
        if accumulated >= enter { return positive }
        if current != nil, abs(accumulated) <= release { return nil }
        return current
    }

    /// Where a newly combined axis starts its own continuous accumulator:
    /// at the threshold that formed it, in the direction it formed it, not
    /// at zero — the fingers really are out that far, and starting at zero
    /// would read as having already eased back to the middle.
    private static func seedAccumulator(for zone: ForkTrackpadSwipeDirection?,
                                        negative: ForkTrackpadSwipeDirection, enter: Double) -> Double {
        guard let zone else { return 0 }
        return zone == negative ? -enter : enter
    }

    /// The grid modifier's vertical tracking: the same hysteresis as
    /// `axisZone`, with a second, further-out stage at twice the threshold —
    /// pushed further the *same* way, no horizontal ever having joined it —
    /// for the centre sixth instead of the plain half. Flipping straight to
    /// the other edge (even from the centre sixth) and letting go to
    /// neutral both work exactly as they do for a plain half; the only
    /// addition is the stop in between, reached and left the same way.
    /// Pushing further is the only way to name this stop: nothing reads a
    /// swipe as "towards the middle" for a second axis to confirm it the
    /// way a horizontal and a vertical confirm a corner together.
    private static func gridEdgeAndSpan(current: GridEdge?, accumulated: Double,
                                        enter: Double, release: Double,
                                        negative: ForkTrackpadSwipeDirection,
                                        positive: ForkTrackpadSwipeDirection) -> GridEdge? {
        if accumulated <= -enter * 2 { return GridEdge(edge: negative, span: 2) }
        if accumulated >= enter * 2 { return GridEdge(edge: positive, span: 2) }
        if accumulated <= -enter { return GridEdge(edge: negative, span: 1) }
        if accumulated >= enter { return GridEdge(edge: positive, span: 1) }
        if current != nil, abs(accumulated) <= release { return nil }
        return current
    }

    /// The horizontal's own five stops, in order from the left edge to the
    /// right: an edge alone, that edge grown by one column, the centre
    /// column alone, the far edge grown by one column, the far edge alone.
    /// `resolveGrid` reads these as a third, two thirds and the centre third
    /// with no row chosen, or a sixth and two sixths within one once a
    /// vertical half confines it there.
    private static let rowLadder: [GridColumn] = [
        GridColumn(column: 0, span: 1),
        GridColumn(column: 0, span: 2),
        GridColumn(column: 1, span: 1),
        GridColumn(column: 1, span: 2),
        GridColumn(column: 2, span: 1),
    ]

    /// Slides across the horizontal's own ladder (point 3): entering a
    /// third works like any other half, crossing the threshold to commit
    /// it; from there, as long as the push keeps going the same way, each
    /// further `enter` out from wherever the ladder last moved advances one
    /// more stop, in order — through the centre, on to the growth and edge
    /// beyond it — never skipping past the edge stops at either end. Pushing
    /// hard back the original way retraces the stops just as it came,
    /// landing straight on the near edge however far it has to walk back;
    /// reversing a long way past the far edge does the same the other way.
    /// `base` moves with the ladder, so every step is measured from the one
    /// before it, not from the gesture's own start, the same way a freshly
    /// combined axis is seeded at the threshold that formed it rather than
    /// at zero. Unlike a plain half, this never lets go to nothing once
    /// committed: there is always some stop held until the fingers lift or
    /// the gesture is cancelled.
    private static func gridRowStep(current: GridColumn?, base: inout Double,
                                    accumulated: Double, enter: Double) -> GridColumn? {
        var index: Int
        if let current, let found = rowLadder.firstIndex(of: current) {
            index = found
        } else if accumulated <= -enter {
            index = 0
            base = -enter
        } else if accumulated >= enter {
            index = rowLadder.count - 1
            base = enter
        } else {
            return nil
        }
        while accumulated - base >= enter, index < rowLadder.count - 1 {
            index += 1
            base += enter
        }
        while accumulated - base <= -enter, index > 0 {
            index -= 1
            base -= enter
        }
        return rowLadder[index]
    }

    /// What the preview should become; `nil` leaves it exactly as it is.
    /// Nothing held on the relevant axes is not a reason to blank the panel
    /// or ask a question nobody meant to ask — only a target switched off in
    /// settings does that, with `.unrecognized`.
    private func preview(for t: SwipeTracking) -> Preview? {
        guard let raw = rawAction(for: t) else {
            guard t.grid == nil, t.combined == nil else { return nil }
            return preview(swipes: t.steps + [t.candidate].compactMap { $0 }, on: t.target)
        }
        return enabled(raw).map(Preview.action) ?? .unrecognized
    }

    private func action(for t: SwipeTracking) -> Action? {
        if let raw = rawAction(for: t) { return enabled(raw) }
        guard t.grid == nil, t.combined == nil else { return nil }
        return enabledAction(swipes: t.steps + [t.candidate].compactMap { $0 }, on: t.target)
    }

    /// The unfiltered action `t.grid` or `t.combined` names, before settings
    /// decide whether it is actually enabled; `nil` either while forming
    /// (ask the chain instead) or while held but naming nothing (hold the
    /// preview as it is, see `preview(for:)`).
    private func rawAction(for t: SwipeTracking) -> Action? {
        if let grid = t.grid {
            return ForkTrackpadGestureSequence.resolveGrid(
                horizontal: grid.horizontal.map { (column: $0.column, span: $0.span) },
                vertical: grid.vertical.map { (edge: $0.edge, span: $0.span) })
        }
        if let combined = t.combined {
            return ForkTrackpadGestureSequence.resolve(horizontal: combined.horizontal, vertical: combined.vertical)
        }
        return nil
    }

    /// Scroll wheel sign conventions, checked on a trackpad: `dx < 0` is left,
    /// `dy > 0` is down.
    ///
    /// Read from the step's accumulated movement, not the last event: a
    /// diagonal can start straight and corrects itself as it goes.
    static func direction(dx: Double, dy: Double, diagonalRatio: Double) -> ForkTrackpadSwipeDirection {
        let horizontal: ForkTrackpadSwipeDirection = dx < 0 ? .left : .right
        let vertical: ForkTrackpadSwipeDirection = dy > 0 ? .down : .up
        let major = max(abs(dx), abs(dy))
        if major > 0, min(abs(dx), abs(dy)) >= diagonalRatio * major {
            switch (horizontal, vertical) {
            case (.left, .up): return .upLeft
            case (.right, .up): return .upRight
            case (.left, _): return .downLeft
            default: return .downRight
            }
        }
        return abs(dx) > abs(dy) ? horizontal : vertical
    }

    private func preview(swipes steps: [ForkTrackpadSwipeDirection], on target: Target) -> Preview? {
        guard !steps.isEmpty,
              let raw = ForkTrackpadGestureSequence.resolve(swipes: steps, on: target)
        else { return nil }
        return enabled(raw).map(Preview.action) ?? .unrecognized
    }

    // MARK: - Pinch

    private mutating func handleMagnify(_ magnitude: Double, phase: Phase?, now: TimeInterval,
                                        isOnTarget: () -> Target?, effects: inout [Effect]) -> Bool {
        // A host that did not wake the machine in time: the silence already
        // ended the previous session, so finish it before opening another.
        if let deadline = gapDeadline, now >= deadline {
            // Only a pinch is ever waiting here: the grid modifier plays no
            // part in it.
            handleTick(now: deadline, gridModifierHeld: false, effects: &effects)
        }
        if case let .pinchAwaitingSecond(pending) = state, now >= pending.deadline {
            handleTick(now: pending.deadline, gridModifierHeld: false, effects: &effects)
        }

        let lifted = phase == .ended || phase == .cancelled

        switch state {
        case var .pinch(p):
            p.lastEventAt = now
            if phase != nil { p.usesPhase = true }
            if lifted {
                if phase == .ended {
                    finishPinch(p, now: now, effects: &effects)
                } else {
                    abandon(pending: !p.steps.isEmpty || p.candidate != nil, reason: .interrupted,
                            effects: &effects)
                    state = .idle
                }
                return true
            }
            move(&p, magnitude: magnitude, now: now)
            state = .pinch(p)
            show(preview(p), effects: &effects)
            return true

        case let .pinchAwaitingSecond(pending):
            // The second pinch, on the same target: no new hit test.
            guard !lifted else { return true }
            var p = PinchTracking(target: pending.target, steps: pending.steps,
                                  lastMovementAt: now, lastEventAt: now,
                                  usesPhase: pending.usesPhase || phase != nil,
                                  isSecond: true, fallback: pending.action)
            move(&p, magnitude: magnitude, now: now)
            state = .pinch(p)
            show(preview(p), effects: &effects)
            return true

        case let .pinchCancelled(_, usesPhase):
            state = lifted ? .idle : .pinchCancelled(lastEventAt: now, usesPhase: usesPhase || phase != nil)
            return true

        case let .pinchPassThrough(_, usesPhase):
            state = lifted ? .idle : .pinchPassThrough(lastEventAt: now, usesPhase: usesPhase || phase != nil)
            return false

        default:
            // A pinch begins. A lone end (lost phases) starts nothing.
            guard !lifted else { return false }
            guard configuration.pinchEnabled,
                  ForkTrackpadGestureCatalog.hasEnabledAction(.pinch, disabled: configuration.disabledActions),
                  let target = isOnTarget(),
                  ForkTrackpadGestureSequence.accepts(.pinch, on: target,
                                                        disabled: configuration.disabledActions)
            else {
                state = .pinchPassThrough(lastEventAt: now, usesPhase: phase != nil)
                return false
            }
            var p = PinchTracking(target: target, lastMovementAt: now, lastEventAt: now,
                                  usesPhase: phase != nil)
            move(&p, magnitude: magnitude, now: now)
            state = .pinch(p)
            show(preview(p), effects: &effects)
            return true
        }
    }

    private func move(_ p: inout PinchTracking, magnitude: Double, now: TimeInterval) {
        let delta = abs(magnitude - p.lastMagnitude)
        p.lastMagnitude = magnitude
        guard delta >= configuration.pinchMovementEpsilon else { return }
        p.lastMovementAt = now
        let relative = magnitude - p.stepBase
        if abs(relative) > abs(p.stepPeak) { p.stepPeak = relative }
        p.candidate = abs(p.stepPeak) >= configuration.pinchThreshold
            ? (p.stepPeak > 0 ? .out : .in)
            : nil
    }

    /// The lift of a pinch. When it has an enabled double (pinch in, then in
    /// again), its action waits `doublePinchInterval` with the preview shown;
    /// otherwise it fires at once.
    private mutating func finishPinch(_ p: PinchTracking, now: TimeInterval, effects: inout [Effect]) {
        let steps = p.steps + [p.candidate].compactMap { $0 }
        let action = enabledAction(pinches: steps, on: p.target) ?? p.fallback
        if !p.isSecond, !steps.isEmpty, enabledAction(pinches: steps + steps, on: p.target) != nil {
            state = .pinchAwaitingSecond(PendingPinch(target: p.target, steps: steps, action: action,
                                                      deadline: now + configuration.doublePinchInterval,
                                                      usesPhase: p.usesPhase))
            return
        }
        show(nil, effects: &effects)
        if let action { effects.append(.commit(action)) }
        state = .idle
    }

    /// The wait is over (or interrupted): the first pinch's action.
    private mutating func settle(_ pending: PendingPinch, effects: inout [Effect]) {
        show(nil, effects: &effects)
        if let action = pending.action { effects.append(.commit(action)) }
        state = .idle
    }

    /// The table minus disabled gestures, used for the preview and for the
    /// action alike, so a disabled gesture never announces itself.
    private func enabledAction(swipes steps: [ForkTrackpadSwipeDirection], on target: Target) -> Action? {
        ForkTrackpadGestureSequence.resolve(swipes: steps, on: target).flatMap(enabled)
    }

    private func enabledAction(horizontal: ForkTrackpadSwipeDirection?,
                               vertical: ForkTrackpadSwipeDirection?) -> Action? {
        ForkTrackpadGestureSequence.resolve(horizontal: horizontal, vertical: vertical).flatMap(enabled)
    }

    private func enabledAction(pinches steps: [ForkTrackpadPinchDirection], on target: Target) -> Action? {
        ForkTrackpadGestureSequence.resolve(pinches: steps, on: target).flatMap(enabled)
    }

    private func enabled(_ action: Action) -> Action? {
        configuration.disabledActions.contains(action) ? nil : action
    }

    /// During the second pinch of a double, whatever leads nowhere shows the
    /// first pinch's action: that is the one that will fire.
    private func preview(_ p: PinchTracking) -> Preview? {
        let steps = p.steps + [p.candidate].compactMap { $0 }
        if let action = enabledAction(pinches: steps, on: p.target) ?? p.fallback { return .action(action) }
        return steps.isEmpty ? nil : .unrecognized
    }

    // MARK: - Double tap

    /// An immediate action: a double tap has no steps and no lift to wait for.
    private mutating func handleSmartMagnify(isOnTarget: () -> Target?, effects: inout [Effect]) -> Bool {
        if case let .pinchAwaitingSecond(pending) = state {
            settle(pending, effects: &effects)
            return false
        }
        guard !isTracking,
              ForkTrackpadGestureCatalog.hasEnabledAction(.tap, disabled: configuration.disabledActions),
              let target = isOnTarget(),
              let action = ForkTrackpadGestureSequence.resolveDoubleTap(on: target).flatMap(enabled)
        else { return false }
        effects.append(.commit(action))
        return true
    }

    /// The deadline of the silence that ends a pinch, for the states that
    /// have one.
    private var gapDeadline: TimeInterval? {
        switch state {
        case let .pinch(p) where !p.usesPhase:
            return p.lastEventAt + configuration.pinchSessionGap
        case let .pinchCancelled(lastEventAt, false), let .pinchPassThrough(lastEventAt, false):
            return lastEventAt + configuration.pinchSessionGap
        default:
            return nil
        }
    }

    // MARK: - Escape and time

    private mutating func handleEscape(effects: inout [Effect]) -> Bool {
        switch state {
        case let .swipe(t):
            abandon(pending: !t.steps.isEmpty || t.candidate != nil || t.combined != nil
                        || t.grid != nil, reason: .escape, effects: &effects)
            state = .swipeCancelled
            return true
        case let .pinch(p):
            abandon(pending: !p.steps.isEmpty || p.candidate != nil, reason: .escape, effects: &effects)
            state = .pinchCancelled(lastEventAt: p.lastEventAt, usesPhase: p.usesPhase)
            return true
        default:
            return false
        }
    }

    private mutating func handleTick(now: TimeInterval, gridModifierHeld: Bool, effects: inout [Effect]) {
        switch state {
        case var .swipe(t):
            // Compared with the deadline written as `nextDeadline` writes it,
            // not with `now - lastMovementAt`: far from zero, rounding puts
            // the difference just under the delay at the deadline itself, and
            // a host woken right on time would never move on.
            if now >= t.lastMovementAt + configuration.cancelTimeout {
                abandon(pending: !t.steps.isEmpty || t.candidate != nil || t.combined != nil
                            || t.grid != nil, reason: .stillness, effects: &effects)
                state = .swipeCancelled
            } else if let candidate = t.candidate, now >= t.lastMovementAt + configuration.stepPause {
                t.steps.append(candidate)
                t.candidate = nil
                t.accX = 0
                t.accY = 0
                // Quarters only ever exist on a title bar: a Dock icon's own
                // sequences (chaining windows) stay exact-match, one step
                // deep, and must never seed this continuous tracking. Which
                // of grid or plain tracking takes over, and when, is decided
                // once, now, by the grid modifier's state at this very
                // moment: the grid is held with one axis alone already (a
                // third needs no vertical step to reach), while the plain
                // half or quarter still waits for both, exactly as before.
                if t.target == .titlebar {
                    let enter = configuration.swipeThreshold
                    let chain = ForkTrackpadGestureSequence.Chain(t.steps)
                    if gridModifierHeld, t.grid == nil, chain.horizontal != nil || chain.vertical != nil {
                        let seededAccX = Self.seedAccumulator(for: chain.horizontal, negative: .left, enter: enter)
                        t.grid = GridTracking(
                            horizontal: chain.horizontal.map { GridColumn(column: $0 == .left ? 0 : 2, span: 1) },
                            vertical: chain.vertical.map { GridEdge(edge: $0, span: 1) },
                            accX: seededAccX,
                            accY: Self.seedAccumulator(for: chain.vertical, negative: .up, enter: enter),
                            horizontalBase: seededAccX)
                    } else if !gridModifierHeld, let zones = ForkTrackpadGestureSequence.combinedZones(t.steps) {
                        t.combined = CombinedTracking(
                            horizontal: zones.horizontal, vertical: zones.vertical,
                            accX: Self.seedAccumulator(for: zones.horizontal, negative: .left, enter: enter),
                            accY: Self.seedAccumulator(for: zones.vertical, negative: .up, enter: enter))
                    }
                }
                state = .swipe(t)
                effects.append(.haptic(.step))
                if let update = preview(for: t) { show(update, effects: &effects) }
            }

        case let .pinch(p):
            // Without phase, the silence is the lift. A pinch never chains
            // steps with the fingers down: no action needs it, and relaxing
            // after pinching in spreads the fingers a little, so "in then out"
            // would no longer close anything.
            if !p.usesPhase, now >= p.lastEventAt + configuration.pinchSessionGap {
                finishPinch(p, now: now, effects: &effects)
                return
            }
            if now >= p.lastMovementAt + configuration.cancelTimeout {
                abandon(pending: !p.steps.isEmpty || p.candidate != nil, reason: .stillness,
                        effects: &effects)
                state = .pinchCancelled(lastEventAt: p.lastEventAt, usesPhase: p.usesPhase)
            }

        case let .pinchAwaitingSecond(pending):
            if now >= pending.deadline { settle(pending, effects: &effects) }

        case let .pinchCancelled(lastEventAt, false), let .pinchPassThrough(lastEventAt, false):
            if now >= lastEventAt + configuration.pinchSessionGap { state = .idle }

        default:
            break
        }
    }

    // MARK: - Effects

    /// Cancels without acting. The haptic and `.cancelled` only fire when
    /// there was something to cancel: resting two fingers on a title bar and
    /// lifting them is not a failed gesture.
    private mutating func abandon(pending: Bool, reason: CancelReason, effects: inout [Effect]) {
        show(nil, effects: &effects)
        guard pending else { return }
        effects.append(.haptic(.cancel))
        effects.append(.cancelled(reason))
    }

    /// Emits changes only: the preview is redrawn only when what it shows
    /// changes.
    private mutating func show(_ preview: Preview?, effects: inout [Effect]) {
        guard preview != shownPreview else { return }
        shownPreview = preview
        effects.append(preview.map(Effect.showPreview) ?? .hidePreview)
    }
}
