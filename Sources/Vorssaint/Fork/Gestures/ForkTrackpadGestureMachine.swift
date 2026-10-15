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
    mutating func handle(_ event: Event, at now: TimeInterval,
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
            handleTick(now: now, effects: &effects)
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
                move(&t, dx: dx, dy: dy, now: now)
                state = .swipe(t)
                show(preview(swipes: t.steps + [t.candidate].compactMap { $0 }, on: t.target),
                     effects: &effects)
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
                let steps = t.steps + [t.candidate].compactMap { $0 }
                if let action = enabledAction(swipes: steps, on: t.target) {
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
                abandon(pending: !t.steps.isEmpty || t.candidate != nil, reason: .interrupted,
                        effects: &effects)
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

    private func move(_ t: inout SwipeTracking, dx: Double, dy: Double, now: TimeInterval) {
        guard abs(dx) + abs(dy) >= configuration.scrollMovementEpsilon else { return }
        t.accX += dx
        t.accY += dy
        t.lastMovementAt = now
        t.candidate = max(abs(t.accX), abs(t.accY)) >= configuration.swipeThreshold
            ? Self.direction(dx: t.accX, dy: t.accY, diagonalRatio: configuration.diagonalRatio)
            : nil
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
        guard !steps.isEmpty else { return nil }
        return enabledAction(swipes: steps, on: target).map(Preview.action) ?? .unrecognized
    }

    // MARK: - Pinch

    private mutating func handleMagnify(_ magnitude: Double, phase: Phase?, now: TimeInterval,
                                        isOnTarget: () -> Target?, effects: inout [Effect]) -> Bool {
        // A host that did not wake the machine in time: the silence already
        // ended the previous session, so finish it before opening another.
        if let deadline = gapDeadline, now >= deadline {
            handleTick(now: deadline, effects: &effects)
        }
        if case let .pinchAwaitingSecond(pending) = state, now >= pending.deadline {
            handleTick(now: pending.deadline, effects: &effects)
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
            abandon(pending: !t.steps.isEmpty || t.candidate != nil, reason: .escape, effects: &effects)
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

    private mutating func handleTick(now: TimeInterval, effects: inout [Effect]) {
        switch state {
        case var .swipe(t):
            // Compared with the deadline written as `nextDeadline` writes it,
            // not with `now - lastMovementAt`: far from zero, rounding puts
            // the difference just under the delay at the deadline itself, and
            // a host woken right on time would never move on.
            if now >= t.lastMovementAt + configuration.cancelTimeout {
                abandon(pending: !t.steps.isEmpty || t.candidate != nil, reason: .stillness,
                        effects: &effects)
                state = .swipeCancelled
            } else if let candidate = t.candidate, now >= t.lastMovementAt + configuration.stepPause {
                t.steps.append(candidate)
                t.candidate = nil
                t.accX = 0
                t.accY = 0
                state = .swipe(t)
                effects.append(.haptic(.step))
                show(preview(swipes: t.steps, on: t.target), effects: &effects)
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
