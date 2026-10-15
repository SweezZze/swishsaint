// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Hector Passerat

import AppKit
import ApplicationServices

/// Places the window a trackpad gesture started on, which may sit behind
/// others: the gesture acts where the pointer was, not on the focused window.
///
/// The official Window Layout service only places the focused window, and
/// keeps its placement machinery private. This is its own, kept small: the
/// rectangles come from the official `WindowLayoutGeometry`, so a half looks
/// the same from a shortcut and from a gesture (gaps and margins included),
/// and the frame is written the same way (anchored to its edge, checked,
/// tried again while the app settles, put back if refused).
///
/// It also remembers which window a gesture sent to which half, so the
/// facing half meets it (`ForkLayoutComplement`), and hands those pairs to
/// the linked-edge handles (`ForkLinkedResizeService`).
final class ForkTrackpadWindowPlacer {
    static let shared = ForkTrackpadWindowPlacer()

    private let frameTolerance = WindowLayoutGeometry.frameTolerance
    /// Same leniency as the official service: an app that rounds its size
    /// still counts as placed when its anchored edges are where asked.
    private let anchorTolerance: CGFloat = 36

    // Which window a gesture sent to which half. Bumped per window by every
    // gesture, so a newer one retires the read-backs still pending for the older.
    private var halfMemory = ForkLayoutHalfMemory<ForkLayoutHalfWindow>()
    private var halfRefitGenerations: [WindowLayoutWindowKey: Int] = [:]
    // Until when a freshly placed half may still be on its way there.
    private var halfSettleDeadlines: [WindowLayoutWindowKey: TimeInterval] = [:]
    private var settleTimers: [CGWindowID: Timer] = [:]
    private var suspensions: [CGWindowID: EnhancedUserInterfaceSuspension] = [:]

    private init() {}

    /// Forgets everything once the gestures stop: nothing is left to settle
    /// or to link.
    func reset() {
        for timer in settleTimers.values { timer.invalidate() }
        settleTimers.removeAll()
        for suspension in suspensions.values { suspension.resume() }
        suspensions.removeAll()
        halfMemory.removeAll()
        halfRefitGenerations.removeAll()
        halfSettleDeadlines.removeAll()
    }

    // MARK: - Gestures

    /// Applies a finished title bar gesture. A window it places is brought
    /// forward, or one sent to a half or full screen behind another would
    /// stay hidden there.
    @discardableResult
    func apply(_ action: ForkTrackpadGestureAction, to window: AXUIElement) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var pid = pid_t(0)
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated
        else { return false }
        AXUIElementSetMessagingTimeout(window, 0.35)

        switch action {
        case .minimize:
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                kCFBooleanTrue) == .success
        case .close:
            // The red button, pressed: the app decides, so an unsaved
            // document opens its sheet instead of losing its changes.
            guard let button = elementAttribute(window, kAXCloseButtonAttribute as String) else { return false }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        case .quitApp, .quitWindowApp:
            // Like ⌘Q: the app may ask to save, or refuse.
            return app.terminate()
        case .emptyTrash, .showAppWindows, .restoreMinimizedWindow, .closeMinimizedWindow:
            // Dock gestures: the gesture service carries them out itself,
            // and never hands them a window.
            return false
        case .centerReduced:
            guard let target = target(from: window, app: app, capability: .frame),
                  let screen = bestScreen(for: target.frame)
            else { return false }
            forgetHalf(target.key)
            bringForward(target.window, of: app)
            let rect = ForkTrackpadCenter.rect(in: screen.visibleFrame,
                                               scale: ForkTrackpadTuning.centerSize.current).integral
            // `.center` keeps whatever size the app accepts centered on the
            // requested rect, and judges the result the same way.
            return setFrame(axFrame(fromAppKit: rect), targetRect: rect,
                            screenVisibleFrame: screen.visibleFrame, action: .center,
                            on: target.window, windowID: target.key.windowID)
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
             .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
             .maximize, .toggleFullScreen:
            guard let layoutAction = action.layoutAction,
                  let target = target(from: window, app: app, capability: layoutAction.targetCapability)
            else { return false }
            bringForward(target.window, of: app)
            if layoutAction == .fullScreen {
                forgetHalf(target.key)
                return toggleFullScreen(target.window)
            }
            guard let screen = bestScreen(for: target.frame) else { return false }
            if let half = ForkLayoutHalf(layoutAction) {
                return applyHalf(half, to: target, visibleFrame: screen.visibleFrame)
            }
            forgetHalf(target.key)
            let rect = placementRect(for: layoutAction, current: target.frame,
                                     visibleFrame: screen.visibleFrame)
            return setFrame(axFrame(fromAppKit: rect), targetRect: rect,
                            screenVisibleFrame: screen.visibleFrame, action: layoutAction,
                            on: target.window, windowID: target.key.windowID)
        }
    }

    /// The same raise as the official pointer gesture's "raise window" option.
    private func bringForward(_ window: AXUIElement, of app: NSRunningApplication) {
        _ = app.activate(options: [])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// The native full screen the green button gives, toggled through the
    /// same attribute the button writes.
    private func toggleFullScreen(_ window: AXUIElement) -> Bool {
        cancelSettle(for: window)
        let isFullScreen = boolAttribute(window, "AXFullScreen")
        let flipped = (isFullScreen ? kCFBooleanFalse : kCFBooleanTrue) as CFTypeRef
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, flipped) == .success
    }

    // MARK: - Complementary halves

    /// Sends the window to `half`, fitted to the real edge of the window a
    /// gesture left in the facing half, then checks twice once the app has
    /// settled that the facing window still meets it.
    private func applyHalf(_ half: ForkLayoutHalf, to target: Target, visibleFrame: NSRect) -> Bool {
        let layoutFrame = WindowLayoutGeometry.screenGapFrame(visibleFrame,
                                                              screenGap: WindowLayoutGaps.screenGap)
        let theoretical = placementRect(for: half.action, current: target.frame, visibleFrame: visibleFrame)
        let neighbour = validHalfOccupant(of: half.complement, layoutFrame: layoutFrame,
                                          excluding: target.key)
        let rect = ForkLayoutComplement.rect(for: half, theoretical: theoretical,
                                             layoutFrame: layoutFrame,
                                             windowGap: WindowLayoutGaps.windowGap,
                                             neighbour: neighbour?.frame).integral
        forgetHalf(target.key)
        guard setFrame(axFrame(fromAppKit: rect), targetRect: rect, screenVisibleFrame: visibleFrame,
                       action: half.action, on: target.window, windowID: target.key.windowID)
        else { return false }
        let window = ForkLayoutHalfWindow(key: target.key, element: target.window)
        let settled = frame(of: target.window).map(appKitFrame(fromAX:)) ?? rect
        recordHalf(window, in: half, layoutFrame: layoutFrame, frame: settled)
        ForkLinkedResizeService.shared.halvesChanged()
        let generation = halfRefitGenerations[target.key, default: 0]
        for delay in Self.halfRefitDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refitHalfNeighbour(of: window, generation: generation, visibleFrame: visibleFrame)
            }
        }
        return true
    }

    /// Past the settle attempts (0.15 s and 0.3 s), and once more for the
    /// apps that adjust themselves later.
    private static let halfRefitDelays: [TimeInterval] = [0.4, 1.0]

    /// Past the last read-back: by then a half that does not hold its place
    /// has left it for good.
    private static let halfSettleWindow: TimeInterval = 1.5

    private func recordHalf(_ window: ForkLayoutHalfWindow, in half: ForkLayoutHalf,
                            layoutFrame: CGRect, frame: CGRect) {
        halfMemory.record(window, in: half, layoutFrame: layoutFrame, frame: frame)
        halfSettleDeadlines[window.key] = ProcessInfo.processInfo.systemUptime + Self.halfSettleWindow
    }

    private func forgetHalf(_ key: WindowLayoutWindowKey) {
        halfSettleDeadlines.removeValue(forKey: key)
        if let entry = halfMemory.entries.first(where: { $0.window.key == key }) {
            halfMemory.forget(entry.window)
        }
        halfRefitGenerations[key, default: 0] &+= 1
    }

    /// Reads back where `window` settled, remembers that frame, and moves
    /// the facing window so the two meet. The facing window only has its
    /// frame read back afterwards, never a refit of its own: two apps that
    /// each round their size cannot push each other back and forth.
    private func refitHalfNeighbour(of window: ForkLayoutHalfWindow, generation: Int,
                                    visibleFrame: NSRect) {
        guard halfRefitGenerations[window.key, default: 0] == generation,
              let entry = halfMemory.entry(for: window),
              let read = frame(of: window.element)
        else { return }
        let actual = appKitFrame(fromAX: read)
        guard ForkLayoutComplement.isAnchored(actual, in: entry.half, of: entry.layoutFrame) else {
            // Refused and put back, or already moved away: no half to meet.
            forgetHalf(window.key)
            return
        }
        halfMemory.update(window, frame: actual)
        let otherHalf = entry.half.complement
        guard let other = validHalfOccupant(of: otherHalf, layoutFrame: entry.layoutFrame,
                                            excluding: window.key)
        else { return }
        let theoretical = placementRect(for: otherHalf.action, current: axFrame(fromAppKit: other.frame),
                                        visibleFrame: visibleFrame)
        guard let rect = ForkLayoutComplement.refitRect(for: otherHalf, current: other.frame,
                                                        theoretical: theoretical,
                                                        layoutFrame: entry.layoutFrame,
                                                        windowGap: WindowLayoutGaps.windowGap,
                                                        neighbour: actual)?.integral,
              setFrame(axFrame(fromAppKit: rect), targetRect: rect, screenVisibleFrame: visibleFrame,
                       action: otherHalf.action, on: other.window.element,
                       windowID: other.window.key.windowID)
        else { return }
        let settled = frame(of: other.window.element).map(appKitFrame(fromAX:)) ?? rect
        recordHalf(other.window, in: otherHalf, layoutFrame: entry.layoutFrame, frame: settled)
        let otherGeneration = halfRefitGenerations[other.window.key, default: 0]
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.halfRefitDelays[0]) { [weak self] in
            guard let self,
                  self.halfRefitGenerations[other.window.key, default: 0] == otherGeneration,
                  let read = self.frame(of: other.window.element)
            else { return }
            self.halfMemory.update(other.window, frame: self.appKitFrame(fromAX: read))
        }
    }

    /// The window remembered in `half` and its current frame, if it still
    /// holds that half: same frame as recorded, on screen, neither minimized
    /// nor in full screen. One that no longer counts is forgotten.
    private func validHalfOccupant(of half: ForkLayoutHalf, layoutFrame: CGRect,
                                   excluding key: WindowLayoutWindowKey)
        -> (window: ForkLayoutHalfWindow, frame: CGRect)? {
        guard let entry = halfMemory.occupant(of: half, layoutFrame: layoutFrame),
              entry.window.key != key
        else { return nil }
        let element = entry.window.element
        AXUIElementSetMessagingTimeout(element, 0.35)
        // The frame first: a window moved away, the usual case, skips the
        // other reads.
        let actual = frame(of: element).map(appKitFrame(fromAX:))
        guard ForkLayoutHalfMemory<ForkLayoutHalfWindow>.isStillPlaced(recorded: entry.frame, actual: actual),
              let actual,
              !boolAttribute(element, kAXMinimizedAttribute as String),
              !boolAttribute(element, "AXFullScreen"),
              Self.onScreenWindowIDs()?.contains(entry.window.key.windowID) == true
        else {
            forgetHalf(entry.window.key)
            return nil
        }
        return (entry.window, actual)
    }

    // MARK: - Linked windows

    /// Whether some layout frame has both halves of a pair remembered: until
    /// then the linked-resize handles need no Accessibility read at all.
    var hasLinkCandidates: Bool { !halfMemory.complementaryPairs().isEmpty }

    /// The pairs whose shared edge can be dragged, read now, in
    /// Accessibility coordinates: both halves still held (loosely, see
    /// `ForkLinkedPair.anchorTolerance`), one window gap apart, resizable,
    /// neither minimized nor in full screen.
    ///
    /// A window found off its half, closed, minimized or in full screen
    /// leaves it, once past its settling time: otherwise a pair dissolved by
    /// hand would keep these reads going for good.
    func linkedWindowPairs() -> [ForkLinkedWindowPair] {
        let windowGap = WindowLayoutGaps.windowGap
        let now = ProcessInfo.processInfo.systemUptime
        return halfMemory.complementaryPairs().compactMap { candidate in
            let axis: ForkLinkAxis = candidate.first.half == .left ? .vertical : .horizontal
            let first = heldFrame(candidate.first)
            let second = heldFrame(candidate.second)
            for (entry, frame) in [(candidate.first, first), (candidate.second, second)]
            where frame == nil && now >= halfSettleDeadlines[entry.window.key, default: 0] {
                forgetHalf(entry.window.key)
            }
            guard let first, let second,
                  let border = ForkLinkedPair.border(between: first, and: second, axis: axis,
                                                     windowGap: windowGap),
                  canSetFrame(on: candidate.first.window.element),
                  canSetFrame(on: candidate.second.window.element)
            else { return nil }
            return ForkLinkedWindowPair(first: candidate.first.window, second: candidate.second.window,
                                        firstFrame: first, secondFrame: second, border: border)
        }
    }

    private func heldFrame(_ entry: ForkLayoutHalfMemory<ForkLayoutHalfWindow>.Entry) -> CGRect? {
        let element = entry.window.element
        // Read ten times a second while a pair exists: a hung app must not
        // hold the main thread for long.
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let read = frame(of: element),
              ForkLayoutComplement.isAnchored(appKitFrame(fromAX: read), in: entry.half,
                                              of: entry.layoutFrame,
                                              tolerance: ForkLinkedPair.anchorTolerance),
              !boolAttribute(element, kAXMinimizedAttribute as String),
              !boolAttribute(element, "AXFullScreen")
        else { return nil }
        return CGRect(origin: read.origin, size: read.size)
    }

    /// A drag of the shared edge begins: read-backs still pending from the
    /// placement must not refit either window under the pointer.
    func linkedDragBegan(_ pair: ForkLinkedWindowPair) {
        for key in [pair.first.key, pair.second.key] { halfRefitGenerations[key, default: 0] &+= 1 }
    }

    /// The frames the drag left (Accessibility coordinates) become the
    /// pair's reference, so it stays linked; a window that no longer
    /// answers (`nil`) leaves its half.
    func linkedDragEnded(_ frames: [(window: ForkLayoutHalfWindow, frame: CGRect?)]) {
        for (window, frame) in frames {
            if let frame {
                halfMemory.update(window, frame: appKitFrame(fromAX: WindowLayoutFrame(origin: frame.origin,
                                                                                     size: frame.size)))
            } else {
                forgetHalf(window.key)
            }
        }
    }

    // MARK: - Writing a frame

    private struct Target {
        let window: AXUIElement
        let key: WindowLayoutWindowKey
        let frame: WindowLayoutFrame
    }

    /// The same checks as the official service: a real window, on screen,
    /// not minimized nor floating, not tiny, and able to take the change.
    private func target(from window: AXUIElement, app: NSRunningApplication,
                        capability: WindowLayoutTargetCapability) -> Target? {
        guard stringAttribute(window, kAXRoleAttribute as String) == (kAXWindowRole as String),
              !boolAttribute(window, kAXMinimizedAttribute as String),
              stringAttribute(window, kAXSubroleAttribute as String) != "AXFloatingWindow",
              let windowID = AXWindowResolver.windowID(for: window),
              Self.onScreenWindowIDs()?.contains(windowID) == true,
              let frame = frame(of: window),
              frame.size.width > 80,
              frame.size.height > 80
        else { return nil }
        let isFullScreen = boolAttribute(window, "AXFullScreen")
        guard capability == .fullScreen || !isFullScreen else { return nil }
        switch capability {
        case .position: guard isSettable(window, kAXPositionAttribute as String) else { return nil }
        case .frame: guard canSetFrame(on: window) else { return nil }
        case .fullScreen: guard isSettable(window, "AXFullScreen") else { return nil }
        }
        let key = WindowLayoutWindowKey(processID: app.processIdentifier,
                                        processLaunchTime: app.launchDate?.timeIntervalSinceReferenceDate ?? 0,
                                        windowID: windowID)
        return Target(window: window, key: key, frame: frame)
    }

    /// The official rectangle for `action`: gaps and margins included.
    private func placementRect(for action: WindowLayoutAction, current: WindowLayoutFrame,
                               visibleFrame: NSRect) -> NSRect {
        WindowLayoutGeometry.rect(for: action,
                                  current: appKitFrame(fromAX: current),
                                  visibleFrame: visibleFrame,
                                  windowGap: WindowLayoutGaps.windowGap,
                                  screenGap: WindowLayoutGaps.screenGap,
                                  marginPercent: WindowLayoutMargin.percent).integral
    }

    /// Writes the frame. Some apps commit a resize with a short delay, so a
    /// first refusal is not final: the frame is tried again twice, 0.15 s
    /// apart, and only then put back. Returns false only when the window
    /// cannot be written at all.
    private func setFrame(_ frame: WindowLayoutFrame, targetRect: NSRect, screenVisibleFrame: NSRect,
                          action: WindowLayoutAction, on window: AXUIElement,
                          windowID: CGWindowID) -> Bool {
        cancelSettle(for: windowID)
        suspensions.removeValue(forKey: windowID)?.resume()
        // Apps with the assistive "enhanced interface" on animate every
        // write; it is paused while the frame is set, as the official does.
        suspensions[windowID] = EnhancedUserInterfaceSuspension.suspend(forAppOf: window)
        let original = self.frame(of: window)
        if attempt(frame, targetRect: targetRect, action: action, on: window) {
            suspensions.removeValue(forKey: windowID)?.resume()
            return true
        }
        scheduleSettle(Settle(window: window, windowID: windowID, frame: frame, targetRect: targetRect,
                              screenVisibleFrame: screenVisibleFrame, action: action, original: original),
                       attempt: 0)
        return true
    }

    private struct Settle {
        let window: AXUIElement
        let windowID: CGWindowID
        let frame: WindowLayoutFrame
        let targetRect: NSRect
        let screenVisibleFrame: NSRect
        let action: WindowLayoutAction
        let original: WindowLayoutFrame?
    }

    private func scheduleSettle(_ settle: Settle, attempt: Int) {
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.settleTimers[settle.windowID] = nil
            self.continueSettle(settle, attempt: attempt)
        }
        settleTimers[settle.windowID] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func continueSettle(_ settle: Settle, attempt: Int) {
        if let actual = frame(of: settle.window),
           actual.isClose(to: settle.frame, tolerance: frameTolerance)
            || accepted(actual: actual, targetRect: settle.targetRect, action: settle.action) {
            concludeSettle(settle, success: true)
            return
        }
        if self.attempt(settle.frame, targetRect: settle.targetRect, action: settle.action, on: settle.window) {
            concludeSettle(settle, success: true)
            return
        }
        if attempt == 0 {
            scheduleSettle(settle, attempt: 1)
            return
        }
        if let original = settle.original, Self.usesMaximizeFallback(settle.action) {
            // An ungapped scratch frame that coaxes a stubborn window into
            // resizing; the gapped target is tried right after.
            let maxRect = WindowLayoutGeometry.rect(for: .maximize, current: appKitFrame(fromAX: original),
                                                    visibleFrame: settle.screenVisibleFrame)
            write(axFrame(fromAppKit: maxRect), on: settle.window)
            if self.attempt(settle.frame, targetRect: settle.targetRect, action: settle.action,
                            on: settle.window) {
                concludeSettle(settle, success: true)
                return
            }
        }
        concludeSettle(settle, success: false)
    }

    /// A refusal this late puts the window back where it was.
    private func concludeSettle(_ settle: Settle, success: Bool) {
        suspensions.removeValue(forKey: settle.windowID)?.resume()
        if !success, let original = settle.original {
            write(original, on: settle.window)
        }
    }

    private func cancelSettle(for windowID: CGWindowID) {
        settleTimers.removeValue(forKey: windowID)?.invalidate()
    }

    private func cancelSettle(for window: AXUIElement) {
        if let windowID = AXWindowResolver.windowID(for: window) { cancelSettle(for: windowID) }
    }

    private static func usesMaximizeFallback(_ action: WindowLayoutAction) -> Bool {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
             .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    private func attempt(_ frame: WindowLayoutFrame, targetRect: NSRect, action: WindowLayoutAction,
                         on window: AXUIElement) -> Bool {
        let visibleFrame = bestScreen(for: frame)?.visibleFrame ?? targetRect
        for _ in 0..<3 {
            writeAnchored(frame, targetRect: targetRect, visibleFrame: visibleFrame, action: action, on: window)
            guard let actual = self.frame(of: window) else { continue }
            if actual.isClose(to: frame, tolerance: frameTolerance)
                || accepted(actual: actual, targetRect: targetRect, action: action) {
                return true
            }
        }
        return false
    }

    private func accepted(actual: WindowLayoutFrame, targetRect: NSRect, action: WindowLayoutAction) -> Bool {
        WindowLayoutGeometry.accepts(actualRect: appKitFrame(fromAX: actual), targetRect: targetRect,
                                     action: action, anchorTolerance: anchorTolerance)
    }

    private func write(_ frame: WindowLayoutFrame, on window: AXUIElement) {
        setSize(frame.size, on: window)
        setPosition(frame.origin, on: window)
        setSize(frame.size, on: window)
        setPosition(frame.origin, on: window)
    }

    /// Size, then the position that keeps the window against its anchored
    /// edge for the size the app really took: an app with a minimum width
    /// sent to the right half still touches the right edge.
    private func writeAnchored(_ frame: WindowLayoutFrame, targetRect: NSRect, visibleFrame: NSRect,
                               action: WindowLayoutAction, on window: AXUIElement) {
        func anchored(_ size: CGSize) -> CGPoint {
            axFrame(fromAppKit: WindowLayoutGeometry.anchoredRect(for: action, targetRect: targetRect,
                                                                  actualSize: size,
                                                                  visibleFrame: visibleFrame)).origin
        }
        setPosition(anchored(frame.size), on: window)
        setSize(frame.size, on: window)
        let acceptedSize = self.frame(of: window)?.size ?? frame.size
        setPosition(anchored(acceptedSize), on: window)
        setSize(frame.size, on: window)
        setPosition(anchored(self.frame(of: window)?.size ?? acceptedSize), on: window)
    }

    // MARK: - Accessibility and screens

    static func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return Set(windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    private func bestScreen(for frame: WindowLayoutFrame) -> NSScreen? {
        let rect = appKitFrame(fromAX: frame)
        let screens = NSScreen.screens
        return screens.max { lhs, rhs in
            Self.area(lhs.frame.intersection(rect)) < Self.area(rhs.frame.intersection(rect))
        } ?? NSScreen.main ?? screens.first
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private var menuBarScreenTopY: CGFloat {
        let menuBarScreen = NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
        return (menuBarScreen ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    }

    private func axFrame(fromAppKit rect: NSRect) -> WindowLayoutFrame {
        WindowLayoutFrame(origin: CGPoint(x: rect.minX, y: menuBarScreenTopY - rect.maxY), size: rect.size)
    }

    private func appKitFrame(fromAX frame: WindowLayoutFrame) -> NSRect {
        NSRect(x: frame.origin.x, y: menuBarScreenTopY - frame.origin.y - frame.size.height,
               width: frame.size.width, height: frame.size.height)
    }

    private func frame(of element: AXUIElement) -> WindowLayoutFrame? {
        guard let origin: CGPoint = axValue(element, kAXPositionAttribute as String, .cgPoint),
              let size: CGSize = axValue(element, kAXSizeAttribute as String, .cgSize),
              size.width > 0, size.height > 0
        else { return nil }
        return WindowLayoutFrame(origin: origin, size: size)
    }

    private func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(axValue, type, pointer) else { return nil }
        return pointer.pointee
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func canSetFrame(on window: AXUIElement) -> Bool {
        isSettable(window, kAXPositionAttribute as String) && isSettable(window, kAXSizeAttribute as String)
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}

/// A window remembered in a half, compared by its key: the element is only
/// kept to move it again.
struct ForkLayoutHalfWindow: Equatable {
    let key: WindowLayoutWindowKey
    let element: AXUIElement

    static func == (lhs: ForkLayoutHalfWindow, rhs: ForkLayoutHalfWindow) -> Bool {
        lhs.key == rhs.key
    }
}

/// Two linked windows as the handles see them: the left (or top) one
/// first, frames in Accessibility coordinates.
struct ForkLinkedWindowPair {
    let first: ForkLayoutHalfWindow
    let second: ForkLayoutHalfWindow
    let firstFrame: CGRect
    let secondFrame: CGRect
    let border: ForkLinkedBorder
}
