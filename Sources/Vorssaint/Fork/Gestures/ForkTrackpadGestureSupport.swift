// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import CoreGraphics
import Foundation

/// What a trackpad gesture started on. Decided once, when the gesture begins,
/// and kept until the fingers lift: it picks the table of actions.
enum ForkTrackpadGestureTarget: Equatable {
    /// The title bar (or toolbar) of a window.
    case titlebar
    /// The icon of a running app in the Dock.
    case dockApp
    /// The Trash in the Dock.
    case dockTrash
    /// Finder's icon in the Dock: never quit, but its windows can be called
    /// back.
    case dockFinder
    /// A minimized window's thumbnail, next to the Trash.
    case dockMinimizedWindow
}

/// What a finished gesture asks its target to do.
///
/// The raw values are stable identifiers: preferences store the gestures a
/// person switched off. Renaming a case is free; changing a raw value silently
/// turns a gesture back on for whoever had switched it off.
enum ForkTrackpadGestureAction: String, CaseIterable, Equatable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf

    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    /// Fill the screen, staying on the same Space.
    case maximize
    case minimize
    /// Native full screen: the green button, a Space of its own.
    case toggleFullScreen
    /// The red button, as a click: the app stays in charge, so an unsaved
    /// document opens its sheet and nothing is lost.
    case close
    /// Centered at an adjustable share of the screen, from a two-finger
    /// double tap.
    case centerReduced

    /// Quit the app of the Dock icon under the pointer, like ⌘Q: the app
    /// decides, save prompts included, and may refuse.
    case quitApp
    /// Quit the app of the window under the pointer, from its title bar
    /// (pinch in twice). Separate from `quitApp` so each can be switched off
    /// on its own.
    case quitWindowApp
    /// Empty the Trash, from its Dock icon: Finder's own Empty Trash, so
    /// Finder asks first as it always does.
    case emptyTrash
    /// Bring an app's windows back, from its Dock icon: every minimized one,
    /// a hidden app shown again, and what a click does otherwise (a new
    /// window when it has none).
    case showAppWindows
    /// Reopen a minimized window, from its thumbnail in the Dock: what a
    /// click on the thumbnail does.
    case restoreMinimizedWindow
    /// Close a minimized window from its thumbnail, as its red button would:
    /// the app stays open and may still ask to save.
    case closeMinimizedWindow
    /// From an app's Dock icon, swiping right: its next window comes to the
    /// front, cycling past its last back to its first.
    case showNextWindow
    /// The same, swiping left, to its previous window.
    case showPreviousWindow

    /// A held modifier's stronger reach of `minimize`: every window of the
    /// app, not only the one the gesture began on.
    case minimizeAllWindows
    /// A held modifier's stronger reach of `maximize`: the official margin
    /// maximize, filling the screen short of its margin rather than all
    /// the way.
    case marginMaximize
    /// A held modifier's other reach of `leftHalf`: the window moves to the
    /// display before this one instead of this display's left half.
    case moveToPreviousDisplay
    /// The same, after `rightHalf`, to the display after this one.
    case moveToNextDisplay
    /// A held modifier's other reach of `centerReduced`: undoes the window's
    /// last trackpad placement instead of centering it.
    case restorePlacement

    /// The placement the window layout engine already knows, when there is
    /// one. The other actions act on the window or the app directly.
    var layoutAction: WindowLayoutAction? {
        switch self {
        case .leftHalf: return .leftHalf
        case .rightHalf: return .rightHalf
        case .topHalf: return .topHalf
        case .bottomHalf: return .bottomHalf
        case .topLeftQuarter: return .topLeft
        case .topRightQuarter: return .topRight
        case .bottomLeftQuarter: return .bottomLeft
        case .bottomRightQuarter: return .bottomRight
        case .maximize: return .maximize
        case .toggleFullScreen: return .fullScreen
        case .marginMaximize: return .marginMaximize
        case .moveToPreviousDisplay: return .previousDisplay
        case .moveToNextDisplay: return .nextDisplay
        case .minimize, .close, .centerReduced, .quitApp, .quitWindowApp, .emptyTrash,
             .showAppWindows, .restoreMinimizedWindow, .closeMinimizedWindow,
             .showNextWindow, .showPreviousWindow,
             .minimizeAllWindows, .restorePlacement: return nil
        }
    }

    /// Whether a gesture with this action can only ever begin on a window's
    /// title bar: every action but the ones the Dock already carries out by
    /// itself, which a window must never receive.
    var isWindowAction: Bool {
        switch self {
        case .quitApp, .emptyTrash, .showAppWindows, .restoreMinimizedWindow, .closeMinimizedWindow,
             .showNextWindow, .showPreviousWindow:
            return false
        default:
            return true
        }
    }
}

/// What a modifier held through a gesture turns its plain action into: a
/// second, stronger meaning for the same swipe, pinch or tap, decided once
/// the gesture commits (or, for a preview, at every step). The base gesture's
/// own on/off switch in settings already governs both: a modifier never
/// revives an action switched off on its own, and `quitWindowApp` keeps its
/// own switch even though a held modifier can also reach it from `close`.
enum ForkTrackpadModifierRemap {
    static func action(for action: ForkTrackpadGestureAction, modifierHeld: Bool,
                       disabled: Set<ForkTrackpadGestureAction> = []) -> ForkTrackpadGestureAction {
        guard modifierHeld else { return action }
        let remapped: ForkTrackpadGestureAction
        switch action {
        case .minimize: remapped = .minimizeAllWindows
        case .maximize: remapped = .marginMaximize
        case .close: remapped = .quitWindowApp
        case .leftHalf: remapped = .moveToPreviousDisplay
        case .rightHalf: remapped = .moveToNextDisplay
        case .centerReduced: remapped = .restorePlacement
        default: return action
        }
        return disabled.contains(remapped) ? action : remapped
    }
}

enum ForkTrackpadSwipeDirection: Equatable {
    case left
    case right
    case up
    case down

    /// Diagonals set both axes in one movement: the quarter, without a pause
    /// between ↑ and →.
    case upLeft
    case upRight
    case downLeft
    case downRight

    /// The horizontal component, `nil` for ↑ and ↓.
    var horizontal: ForkTrackpadSwipeDirection? {
        switch self {
        case .left, .upLeft, .downLeft: return .left
        case .right, .upRight, .downRight: return .right
        case .up, .down: return nil
        }
    }

    /// The vertical component, `nil` for ← and →.
    var vertical: ForkTrackpadSwipeDirection? {
        switch self {
        case .up, .upLeft, .upRight: return .up
        case .down, .downLeft, .downRight: return .down
        case .left, .right: return nil
        }
    }

    var isDiagonal: Bool { horizontal != nil && vertical != nil }

    var arrow: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .upLeft: return "↖"
        case .upRight: return "↗"
        case .downLeft: return "↙"
        case .downRight: return "↘"
        }
    }
}

enum ForkTrackpadPinchDirection: Equatable {
    /// Fingers spreading apart.
    case out
    /// Fingers closing together.
    case `in`
}

enum ForkTrackpadGestureFamily: Equatable {
    case swipe
    case pinch
    /// Two fingertips touching twice, without sliding.
    case tap
}

/// What triggers an action: the steps of one gesture.
enum ForkTrackpadGestureTrigger: Equatable {
    /// Steps of one swipe, fingers kept down, a short pause between two.
    case swipes([ForkTrackpadSwipeDirection])
    /// Whole pinches, fingers lifted between two.
    case pinches([ForkTrackpadPinchDirection])
    /// macOS's "smart zoom" double tap.
    case doubleTap

    var family: ForkTrackpadGestureFamily {
        switch self {
        case .swipes: return .swipe
        case .pinches: return .pinch
        case .doubleTap: return .tap
        }
    }
}

/// Every gesture: its action, its target and what triggers it.
///
/// This is what settings show and switch off one by one. Tests check that each
/// trigger listed here resolves to its action, so the catalog and
/// `ForkTrackpadGestureSequence` cannot drift apart unnoticed.
enum ForkTrackpadGestureCatalog {
    struct Entry: Equatable {
        let action: ForkTrackpadGestureAction
        /// Where the gesture works. Several for one gesture on a few kinds of
        /// Dock icon: bringing windows back works on any app's, Finder's
        /// included, while a pinch on Finder's still does nothing.
        let targets: Set<ForkTrackpadGestureTarget>
        /// The first one is the form to show; the others reach the same
        /// action. For a quarter: the diagonal first, then both two-step
        /// orders.
        let triggers: [ForkTrackpadGestureTrigger]

        init(action: ForkTrackpadGestureAction, target: ForkTrackpadGestureTarget,
             triggers: [ForkTrackpadGestureTrigger]) {
            self.init(action: action, targets: [target], triggers: triggers)
        }

        init(action: ForkTrackpadGestureAction, targets: Set<ForkTrackpadGestureTarget>,
             triggers: [ForkTrackpadGestureTrigger]) {
            self.action = action
            self.targets = targets
            self.triggers = triggers
        }

        var family: ForkTrackpadGestureFamily { triggers[0].family }
    }

    /// In the order settings present them.
    static let entries: [Entry] = [
        Entry(action: .leftHalf, target: .titlebar, triggers: [.swipes([.left])]),
        Entry(action: .rightHalf, target: .titlebar, triggers: [.swipes([.right])]),
        Entry(action: .maximize, target: .titlebar, triggers: [.swipes([.up])]),
        Entry(action: .minimize, target: .titlebar, triggers: [.swipes([.down])]),
        Entry(action: .topHalf, target: .titlebar, triggers: [.swipes([.up, .up])]),
        Entry(action: .bottomHalf, target: .titlebar, triggers: [.swipes([.down, .down])]),
        Entry(action: .topLeftQuarter, target: .titlebar,
              triggers: [.swipes([.upLeft]), .swipes([.up, .left]), .swipes([.left, .up])]),
        Entry(action: .topRightQuarter, target: .titlebar,
              triggers: [.swipes([.upRight]), .swipes([.up, .right]), .swipes([.right, .up])]),
        Entry(action: .bottomLeftQuarter, target: .titlebar,
              triggers: [.swipes([.downLeft]), .swipes([.down, .left]), .swipes([.left, .down])]),
        Entry(action: .bottomRightQuarter, target: .titlebar,
              triggers: [.swipes([.downRight]), .swipes([.down, .right]), .swipes([.right, .down])]),
        Entry(action: .toggleFullScreen, target: .titlebar, triggers: [.pinches([.out])]),
        Entry(action: .close, target: .titlebar, triggers: [.pinches([.in])]),
        Entry(action: .quitWindowApp, target: .titlebar, triggers: [.pinches([.in, .in])]),
        Entry(action: .centerReduced, target: .titlebar, triggers: [.doubleTap]),
        Entry(action: .quitApp, target: .dockApp, triggers: [.pinches([.in])]),
        Entry(action: .emptyTrash, target: .dockTrash, triggers: [.pinches([.in])]),
        Entry(action: .showAppWindows, targets: [.dockApp, .dockFinder], triggers: [.swipes([.up])]),
        Entry(action: .showNextWindow, targets: [.dockApp, .dockFinder], triggers: [.swipes([.right])]),
        Entry(action: .showPreviousWindow, targets: [.dockApp, .dockFinder], triggers: [.swipes([.left])]),
        Entry(action: .restoreMinimizedWindow, target: .dockMinimizedWindow, triggers: [.swipes([.up])]),
        Entry(action: .closeMinimizedWindow, target: .dockMinimizedWindow, triggers: [.pinches([.in])]),
    ]

    static func entry(for action: ForkTrackpadGestureAction) -> Entry? {
        entries.first { $0.action == action }
    }

    /// Whether a family still has at least one enabled action on a target, or
    /// on any target when `target` is `nil`. When it has none, the gesture is
    /// not captured at all and stays with the app or the Dock.
    static func hasEnabledAction(_ family: ForkTrackpadGestureFamily,
                                 on target: ForkTrackpadGestureTarget? = nil,
                                 disabled: Set<ForkTrackpadGestureAction>) -> Bool {
        entries.contains { entry in
            entry.family == family
                && (target == nil || entry.targets.contains(target!))
                && !disabled.contains(entry.action)
        }
    }
}

/// Translates the steps of a gesture into an action, per target.
///
/// Kept apart from the state machine so the catalog can grow without touching
/// the mechanics: the machine says "the person did ↓ then →", this table says
/// "bottom right quarter".
enum ForkTrackpadGestureSequence {
    /// The state of a chain of swipe steps, replayed step by step.
    ///
    /// Two axes, each with its current direction, and `hasCombined`: true as
    /// soon as both axes were set together, and never reset. That flag, not
    /// the current axes, is what tells a real quarter the person changes their
    /// mind about from a single axis going back and forth (↑↓), which stays
    /// without action.
    struct Chain: Equatable {
        var horizontal: ForkTrackpadSwipeDirection?
        var vertical: ForkTrackpadSwipeDirection?
        var hasCombined = false
        /// The previous step, to find two identical vertical steps in a row:
        /// a horizontal step between them breaks the pair.
        private var lastStep: ForkTrackpadSwipeDirection?

        init(_ steps: [ForkTrackpadSwipeDirection]) {
            for step in steps { apply(step) }
        }

        private mutating func apply(_ step: ForkTrackpadSwipeDirection) {
            switch step {
            case .left, .right:
                // Reversing the horizontal on a real quarter erases the
                // vertical: ↑ → ← gives the left half, not the top left
                // quarter. The vertical always combines: the latest ↑ or ↓
                // wins without touching the horizontal.
                if hasCombined, let current = horizontal, current != step {
                    vertical = nil
                }
                horizontal = step
            case .up, .down:
                vertical = step
                // Two ↑ (or two ↓) in a row go back to that half, even over a
                // quarter already built. Vertical only: ←← and →→ change
                // nothing.
                if lastStep == step { horizontal = nil }
            case .upLeft, .upRight, .downLeft, .downRight:
                // A diagonal sets the quarter at once, whatever came before,
                // and then counts as a built quarter: ← or → the other way
                // gives the half, ↑ or ↓ changes the row, and the half needs
                // two ↑ (or ↓) — the diagonal is not the first of the two.
                horizontal = step.horizontal
                vertical = step.vertical
            }
            lastStep = step
            if horizontal != nil, vertical != nil { hasCombined = true }
        }
    }

    /// Whether a family has at least one enabled action on this target.
    /// Otherwise the gesture is not captured and stays with the app.
    static func accepts(_ family: ForkTrackpadGestureFamily,
                        on target: ForkTrackpadGestureTarget,
                        disabled: Set<ForkTrackpadGestureAction> = []) -> Bool {
        ForkTrackpadGestureCatalog.hasEnabledAction(family, on: target, disabled: disabled)
    }

    /// `nil` for a chain that matches nothing: the preview says so, and the
    /// lift does nothing. The chain is unlimited: the person can change their
    /// mind as often as they like before lifting.
    static func resolve(swipes steps: [ForkTrackpadSwipeDirection],
                        on target: ForkTrackpadGestureTarget = .titlebar) -> ForkTrackpadGestureAction? {
        // Out of the Dock, the way a window comes up from it.
        switch target {
        case .dockApp, .dockFinder:
            switch steps {
            case [.up]: return .showAppWindows
            case [.right]: return .showNextWindow
            case [.left]: return .showPreviousWindow
            default: return nil
            }
        case .dockMinimizedWindow: return steps == [.up] ? .restoreMinimizedWindow : nil
        case .dockTrash: return nil
        case .titlebar: break
        }

        let chain = Chain(steps)

        // Never combined: a single axis, from the exact table and nothing
        // else. ↑↓ or ←→ stay without action so that ↑↑ and ↓↓ keep meaning
        // halves.
        guard chain.hasCombined else {
            switch steps {
            case [.left]: return .leftHalf
            case [.right]: return .rightHalf
            case [.up]: return .maximize
            case [.down]: return .minimize
            case [.up, .up]: return .topHalf
            case [.down, .down]: return .bottomHalf
            default: return nil
            }
        }

        // Combined: the current direction of each axis. Quarters work in
        // either order; a single axis left after an erasure is a half.
        switch (chain.horizontal, chain.vertical) {
        case (.left?, .up?): return .topLeftQuarter
        case (.right?, .up?): return .topRightQuarter
        case (.left?, .down?): return .bottomLeftQuarter
        case (.right?, .down?): return .bottomRightQuarter
        case (.left?, nil): return .leftHalf
        case (.right?, nil): return .rightHalf
        case (nil, .up?): return .topHalf
        case (nil, .down?): return .bottomHalf
        default: return nil
        }
    }

    /// Each step is a whole pinch, fingers lifted between two: `[.in, .in]` is
    /// pinch in, lift, pinch in again within the double-pinch interval.
    static func resolve(pinches steps: [ForkTrackpadPinchDirection],
                        on target: ForkTrackpadGestureTarget = .titlebar) -> ForkTrackpadGestureAction? {
        switch (target, steps) {
        case (.titlebar, [.out]): return .toggleFullScreen
        // As in Swish: pinching in closes, pinching in twice quits the app.
        case (.titlebar, [.in]): return .close
        case (.titlebar, [.in, .in]): return .quitWindowApp
        case (.dockApp, [.in]): return .quitApp
        // The same move as quitting an app: what a pinch in means on the Dock.
        case (.dockTrash, [.in]): return .emptyTrash
        // Closing a window, in the Dock as on its title bar.
        case (.dockMinimizedWindow, [.in]): return .closeMinimizedWindow
        default: return nil
        }
    }

    static func resolveDoubleTap(on target: ForkTrackpadGestureTarget = .titlebar) -> ForkTrackpadGestureAction? {
        target == .titlebar ? .centerReduced : nil
    }
}

/// What Accessibility says about an element, reduced to what the title bar
/// decision needs. The strings are Accessibility's own (`"AXToolbar"`,
/// `"AXStandardWindow"`…), so the decision stays testable without AppKit.
struct ForkTrackpadAXNode: Equatable {
    var role: String?
    var subrole: String?

    init(role: String?, subrole: String? = nil) {
        self.role = role
        self.subrole = subrole
    }
}

/// Whether the pointer is on a title bar: the decision, without the
/// Accessibility queries that feed it.
///
/// Three rules, in this order:
///
/// 1. Only real windows: standard or dialog, or without a subrole, which some
///    apps leave empty. Not floating panels nor system windows.
/// 2. Never on something that scrolls or takes input: a scroll area, a text
///    field, a slider, web content… anywhere on the path. A swipe on Safari's
///    address bar or on Firefox's scrolling tab strip stays with the app.
///    This rule matters most once events are swallowed: getting it wrong
///    steals a scroll.
/// 3. Title bar when the path goes through a toolbar, which can be taller than
///    the band (Finder, Mail), or else when the pointer is within the top
///    `bandHeight` points of the window. The band covers title bars drawn by
///    hand (Chrome), which Accessibility describes as plain groups.
///
/// Known limit: in Electron apps the title bar is web content, so gestures
/// only catch on the space the app leaves free, sometimes nowhere. Accepting
/// text-less web groups in the band was tried and dropped: a conversation that
/// scrolls right under a 48 pt header is also a plain `AXGroup`, and only its
/// CSS class tells it apart.
enum ForkTrackpadTitlebar {
    enum Verdict: Equatable {
        case titlebar
        case unsupportedWindow(subrole: String?)
        case excludedElement(role: String)
        case outsideBand
    }

    static let acceptedWindowSubroles: Set<String?> = [nil, "AXStandardWindow", "AXDialog"]

    static let excludedRoles: Set<String> = [
        "AXScrollArea", "AXScrollBar", "AXSlider", "AXIncrementor",
        "AXTextField", "AXTextArea", "AXComboBox",
        "AXWebArea", "AXPopover",
        "AXTable", "AXOutline", "AXList", "AXBrowser",
    ]

    /// - Parameters:
    ///   - path: from the element under the pointer up to the window's direct
    ///     child. Empty when the element hit is the window itself.
    ///   - windowFrame: in Accessibility coordinates (origin at the top left).
    ///   - point: the pointer, in the same coordinates.
    static func evaluate(path: [ForkTrackpadAXNode],
                         window: ForkTrackpadAXNode,
                         windowFrame: CGRect,
                         point: CGPoint,
                         bandHeight: Double) -> Verdict {
        guard acceptedWindowSubroles.contains(window.subrole) else {
            return .unsupportedWindow(subrole: window.subrole)
        }
        if let excluded = path.compactMap(\.role).first(where: excludedRoles.contains) {
            return .excludedElement(role: excluded)
        }
        if path.contains(where: { $0.role == "AXToolbar" }) {
            return .titlebar
        }
        let withinWidth = point.x >= windowFrame.minX && point.x <= windowFrame.maxX
        // Origin at the top: the top of the window is `minY`.
        let withinBand = point.y >= windowFrame.minY && point.y <= windowFrame.minY + bandHeight
        return withinWidth && withinBand ? .titlebar : .outsideBand
    }
}

/// What the event tap reads from an event, turned into the machine's terms.
/// Pure, so the decoding can be checked without a trackpad.
///
/// The gesture event is not public API. It was decoded by hand on macOS 26
/// from isolated, announced gestures, and nothing guarantees it stays the same
/// from one macOS version to the next:
///
/// - multitouch gestures arrive as Quartz event type 29, absent from
///   `CGEventType`;
/// - field 110 tells them apart: 8 is a pinch (magnify), 22 is the "smart
///   zoom" two-finger double tap, a single event with no right click after it;
/// - field 113 carries a pinch's magnification since it began, as a double:
///   positive when spreading, negative when closing;
/// - the phase of a pinch (began, changed, ended) is read through `NSEvent`,
///   which reports it as a magnify event.
enum ForkTrackpadEventDecoding {
    static let gestureEventType: UInt32 = 29
    static let gestureSubtypeField: UInt32 = 110
    static let magnifySubtype: Int64 = 8
    static let smartMagnifySubtype: Int64 = 22
    static let magnificationField: UInt32 = 113

    /// What a gesture event is, from its subtype. `nil` for the gestures the
    /// machine does not follow (rotation, the system's swipes…).
    enum GestureKind: Equatable {
        case magnify
        case smartMagnify
    }

    static func gestureKind(subtype: Int64) -> GestureKind? {
        switch subtype {
        case magnifySubtype: return .magnify
        case smartMagnifySubtype: return .smartMagnify
        default: return nil
        }
    }

    /// `NSEvent.Phase` raw values, so this stays testable without AppKit.
    enum AppKitPhase {
        static let began: UInt = 0x1
        static let stationary: UInt = 0x2
        static let changed: UInt = 0x4
        static let ended: UInt = 0x8
        static let cancelled: UInt = 0x10
        static let mayBegin: UInt = 0x20
    }

    /// An event carries a single phase. `stationary` (fingers down, not
    /// moving) becomes a `changed` without movement, which the machine does
    /// not count as one. No phase (a wheel, or momentum) is `nil`.
    static func phase(appKitRawValue raw: UInt) -> ForkTrackpadGestureMachine.Phase? {
        if raw & AppKitPhase.mayBegin != 0 { return .mayBegin }
        if raw & AppKitPhase.began != 0 { return .began }
        if raw & (AppKitPhase.changed | AppKitPhase.stationary) != 0 { return .changed }
        if raw & AppKitPhase.ended != 0 { return .ended }
        if raw & AppKitPhase.cancelled != 0 { return .cancelled }
        return nil
    }

    /// The scroll deltas in the machine's convention (`dx < 0` left, `dy > 0`
    /// down), whatever the Natural scrolling setting.
    ///
    /// The machine's thresholds and signs were measured with Natural scrolling
    /// on, the default, where `NSEvent` reports the direction as inverted from
    /// the device. With it off, the deltas arrive the other way round and are
    /// turned back, so a swipe to the left stays a swipe to the left.
    static func scrollDelta(dx: Double, dy: Double,
                            directionInvertedFromDevice: Bool) -> (dx: Double, dy: Double) {
        directionInvertedFromDevice ? (dx, dy) : (-dx, -dy)
    }
}

/// Time as the machine sees it: event timestamps, never going back.
///
/// Events are stamped where the tap sees them, then wait their turn on the
/// main thread, where the deadline timer also fires. A timer that fires while
/// older events still wait would otherwise make time run backwards for them.
struct ForkTrackpadGestureClock: Equatable {
    private(set) var latest: TimeInterval = 0

    mutating func time(for timestamp: TimeInterval) -> TimeInterval {
        latest = max(latest, timestamp)
        return latest
    }
}

/// Where the two-finger double tap puts a window: centered on its screen's
/// usable area, at a share of its width and height.
enum ForkTrackpadCenter {
    static let defaultScale = 0.6
    /// Below 10 % a window is a postage stamp; above 100 % it would spill.
    static let scaleRange: ClosedRange<Double> = 0.1...1

    static func rect(in visibleFrame: CGRect, scale: Double = defaultScale) -> CGRect {
        let clamped = min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
        let width = visibleFrame.width * clamped
        let height = visibleFrame.height * clamped
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.midY - height / 2,
                      width: width,
                      height: height)
    }
}

/// Which app owns the window under a point, from the window server's stack
/// alone, without asking any app.
///
/// The title bar hit test then asks that one app, with a short timeout. Asking
/// the system-wide element instead would wait on whatever app is under the
/// pointer for the default timeout, and a timeout set on the system-wide
/// element becomes the default for every question this process asks (#938).
enum ForkTrackpadWindowStack {
    struct Window: Equatable {
        var pid: pid_t
        /// Global coordinates, origin at the top left: those of the window
        /// list, of Accessibility and of an event's location.
        var bounds: CGRect
        var alpha: Double
        /// `kCGWindowLayer`: 0 for an ordinary app window.
        var layer: Int
    }

    /// The pid to ask, or `nil` when no other app's window is on top at
    /// `point`. `windows` runs from front to back.
    ///
    /// Other apps' windows only count at layer 0. The Dock keeps a transparent,
    /// screen-sized window at layer 20 that Accessibility sees through;
    /// counting it would put the Dock on top of everything. This app's own
    /// windows count at any layer (panels, the notch, the menu bar), and
    /// there is nothing of ours to arrange.
    ///
    /// A fully transparent window does not count.
    static func owner(at point: CGPoint, in windows: [Window], ownPID: pid_t) -> pid_t? {
        let top = windows.first { window in
            window.alpha > 0
                && window.bounds.contains(point)
                && (window.pid == ownPID || window.layer == 0)
        }
        guard let top, top.pid != ownPID else { return nil }
        return top.pid
    }
}

/// A running app, reduced to what tells a Dock icon's app apart. The host
/// fills it from `NSWorkspace.runningApplications`.
struct ForkTrackpadRunningApp: Equatable {
    var pid: pid_t
    var bundleURL: URL?
    var bundleIdentifier: String?
}

/// Whether the pointer is on the Dock icon of an app a pinch may quit: the
/// decision, without the Accessibility queries that feed it.
///
/// Icons are `AXDockItem`s with one subrole per kind (`AXApplicationDockItem`,
/// `AXFolderDockItem`, `AXTrashDockItem`, `AXMinimizedWindowDockItem`,
/// `AXSeparatorDockItem`…). Only the icons of running apps are targets.
enum ForkTrackpadDock {
    enum Verdict: Equatable {
        case app(ForkTrackpadRunningApp)
        case trash
        /// Finder, which is never quit but whose windows can be called back.
        case finder(ForkTrackpadRunningApp)
        /// A minimized window's thumbnail, with the title the Dock gives it:
        /// the only thing it says about which window it stands for.
        case minimizedWindow(title: String?)
        /// A folder, a minimized window, a separator…
        case notAnAppItem(subrole: String?)
        /// The kept icon of an app that is not running, or a running app that
        /// cannot be told apart from another.
        case notRunning
        /// This app, which a pinch on its own icon must never quit.
        case ownApp
        /// An app the Dock itself offers no Quit for.
        case protectedApp(bundleIdentifier: String)
    }

    static let finderBundleIdentifier = "com.apple.finder"

    /// A minimized window as read from its app, for matching a thumbnail.
    struct MinimizedWindow: Equatable {
        let pid: pid_t
        /// Its place in the app's window list.
        let index: Int
        let title: String?
    }

    /// The one minimized window a thumbnail's title names. Never a guess:
    /// no title, or two minimized windows with the same one (two untitled
    /// documents), give `nil`, and the thumbnail is not closed.
    static func minimizedWindow(titled title: String?, among windows: [MinimizedWindow]) -> MinimizedWindow? {
        guard let title, !title.isEmpty else { return nil }
        let matches = windows.filter { $0.title == title }
        return matches.count == 1 ? matches[0] : nil
    }
    static let protectedBundleIdentifiers: Set<String> = [finderBundleIdentifier]
    /// Empty Trash in Finder is ⇧⌘⌫, with its confirmation; ⌥ would skip it.
    static let emptyTrashFlags: CGEventFlags = [.maskCommand, .maskShift]

    /// - Parameters:
    ///   - item: the `AXDockItem` under the pointer.
    ///   - isRunning: the icon's `AXIsApplicationRunning`.
    ///   - itemURL: the icon's `AXURL`, the `.app` it stands for.
    ///   - itemBundleIdentifier: read from that `.app`, when the host could.
    static func evaluate(item: ForkTrackpadAXNode,
                         isRunning: Bool,
                         itemURL: URL?,
                         itemBundleIdentifier: String?,
                         itemTitle: String? = nil,
                         runningApps: [ForkTrackpadRunningApp],
                         ownPID: pid_t) -> Verdict {
        if item.role == "AXDockItem", item.subrole == "AXTrashDockItem" { return .trash }
        if item.role == "AXDockItem", item.subrole == "AXMinimizedWindowDockItem" {
            return .minimizedWindow(title: itemTitle)
        }
        guard item.role == "AXDockItem", item.subrole == "AXApplicationDockItem" else {
            return .notAnAppItem(subrole: item.subrole)
        }
        guard isRunning,
              let app = runningApp(forItemURL: itemURL, bundleIdentifier: itemBundleIdentifier,
                                   among: runningApps)
        else { return .notRunning }
        guard app.pid != ownPID else { return .ownApp }
        if app.bundleIdentifier == finderBundleIdentifier { return .finder(app) }
        if let identifier = app.bundleIdentifier, protectedBundleIdentifiers.contains(identifier) {
            return .protectedApp(bundleIdentifier: identifier)
        }
        return .app(app)
    }

    /// The running app an icon stands for. By URL first: the only key that
    /// tells two copies of one app apart, and that works for an app without
    /// an identifier. By identifier next, because paths do not always agree
    /// (`/Applications/TextEdit.app` against
    /// `/System/Applications/TextEdit.app`). Never a guess: two candidates for
    /// the same key give `nil`, since quitting cannot be undone.
    static func runningApp(forItemURL url: URL?,
                           bundleIdentifier: String?,
                           among apps: [ForkTrackpadRunningApp]) -> ForkTrackpadRunningApp? {
        if let url {
            let path = url.standardizedFileURL.path
            let byURL = apps.filter { $0.bundleURL?.standardizedFileURL.path == path }
            if byURL.count == 1 { return byURL[0] }
            if byURL.count > 1 { return nil }
        }
        if let bundleIdentifier {
            let byIdentifier = apps.filter { $0.bundleIdentifier == bundleIdentifier }
            if byIdentifier.count == 1 { return byIdentifier[0] }
        }
        return nil
    }

    /// The icon under `point`, matched along the Dock's long axis only.
    /// Accessibility reports the Dock's frames shifted on the short axis (about
    /// 72 pt on macOS 27), while the long axis stays truthful; the host bounds
    /// the short axis first with the Dock strip. `nil` frames are icons whose
    /// frame could not be read.
    static func itemIndex(at point: CGPoint, itemFrames: [CGRect?], listFrame: CGRect) -> Int? {
        let horizontal = listFrame.width >= listFrame.height
        return itemFrames.firstIndex { frame in
            guard let frame else { return false }
            return horizontal
                ? point.x >= frame.minX && point.x < frame.maxX
                : point.y >= frame.minY && point.y < frame.maxY
        }
    }
}

/// The three window buttons of macOS, as the preview redraws them.
enum ForkTrackpadTrafficLight: Equatable {
    case close, minimize, fullScreen
}

/// What the preview draws for what the machine announces, without AppKit.
///
/// A zone comes from the same geometry as the placement itself, applied to a
/// reference screen and brought down to one: the preview cannot show anything
/// other than what the lift will do.
enum ForkTrackpadPreviewContent: Equatable {
    /// The target zone in a unit screen (0…1, origin at the top left).
    case zone(CGRect)
    /// A traffic light: red closes, yellow minimizes, green goes full screen.
    case light(ForkTrackpadTrafficLight)
    /// The red light with the app's icon in its corner: quitting an app, not
    /// closing a window.
    case quitApp
    /// The red light with the Trash in its corner.
    case emptyTrash
    /// The app's icon alone: its windows are coming back.
    case showApp
    /// A system symbol, drawn plain like the question mark: an action with
    /// neither a zone nor a traffic light of its own.
    case symbol(String)
    /// A sequence without action: the lift will do nothing.
    case unrecognized

    init(_ preview: ForkTrackpadGestureMachine.Preview, centerScale: Double = ForkTrackpadCenter.defaultScale) {
        guard case .action(let action) = preview else {
            self = .unrecognized
            return
        }
        // 1,000 points brought down to 1: the geometry works in whole points.
        let side = 1000.0
        let reference = CGRect(x: 0, y: 0, width: side, height: side)
        // A sliver at the edge the window is leaving through, since the
        // official geometry for moving to another display only ever hands
        // back the window's own, unchanged, current rectangle.
        let edgeShare = 0.08
        let rect: CGRect
        switch action {
        case .minimize, .minimizeAllWindows:
            self = .light(.minimize)
            return
        case .toggleFullScreen:
            self = .light(.fullScreen)
            return
        case .close:
            self = .light(.close)
            return
        case .quitApp, .quitWindowApp:
            self = .quitApp
            return
        case .emptyTrash:
            self = .emptyTrash
            return
        case .showAppWindows, .restoreMinimizedWindow, .showNextWindow, .showPreviousWindow:
            self = .showApp
            return
        case .closeMinimizedWindow:
            self = .light(.close)
            return
        case .restorePlacement:
            self = .symbol("arrow.uturn.backward")
            return
        case .centerReduced:
            rect = ForkTrackpadCenter.rect(in: reference, scale: centerScale)
        case .moveToPreviousDisplay:
            rect = CGRect(x: 0, y: 0, width: side * edgeShare, height: side)
        case .moveToNextDisplay:
            rect = CGRect(x: side * (1 - edgeShare), y: 0, width: side * edgeShare, height: side)
        default:
            guard let layoutAction = action.layoutAction else {
                self = .unrecognized
                return
            }
            rect = WindowLayoutGeometry.rect(for: layoutAction, current: reference, visibleFrame: reference)
        }
        // The geometry is AppKit's, origin at the bottom left.
        self = .zone(CGRect(x: rect.minX / side, y: (side - rect.maxY) / side,
                            width: rect.width / side, height: rect.height / side))
    }

    /// Traffic lights sit on the pointer, like the button the gesture stands
    /// for; zones and symbols need the room of a panel centered on the screen.
    var isAtPointer: Bool {
        switch self {
        case .light, .quitApp, .emptyTrash, .showApp: return true
        case .zone, .symbol, .unrecognized: return false
        }
    }
}

/// Where the preview panel goes, in Accessibility coordinates (origin at the
/// top left).
enum ForkTrackpadPreviewPlacement {
    /// The target's screen: the one holding most of the target window, or,
    /// with no window (a Dock icon), the pointer's.
    static func screenIndex(targetFrame: CGRect?, pointer: CGPoint, screens: [CGRect]) -> Int? {
        if let targetFrame {
            let areas = screens.map { screen -> CGFloat in
                let overlap = screen.intersection(targetFrame)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
                return best
            }
        }
        return screens.firstIndex { $0.contains(pointer) }
    }

    static func frame(size: CGSize, centeredIn visible: CGRect) -> CGRect {
        CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    static func frame(size: CGSize, centeredOn pointer: CGPoint) -> CGRect {
        CGRect(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2,
               width: size.width, height: size.height)
    }
}
