// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Linked windows: when a trackpad gesture has left two windows in the two
/// complementary halves of a screen, their shared edge can be dragged to
/// resize both at once, one shrinking while the other grows.
///
/// One handle per pair: an invisible, non-activating panel laid on the
/// shared edge (`ForkLinkedResizeHandle`). It takes the click itself, so
/// the app underneath never sees it: no active mouse tap, and no fight with
/// the native resize edge.
///
/// The pairs come from the halves Window Layout remembers, read every
/// `refreshInterval` while some screen has both halves of a pair
/// remembered, and not at all otherwise.
///
/// Escape during a drag puts both windows back; Command held (at the click
/// or on the way) unlinks them, so only the frontmost of the two follows.
final class ForkLinkedResizeService {
    static let shared = ForkLinkedResizeService()

    /// Short enough for the handle to follow a moved window without visible
    /// lag, and to come back quickly above an app that just raised its
    /// windows over it.
    static let refreshInterval: TimeInterval = 0.1

    private var enabled = false
    private var handles: [ForkLinkedResizeHandle] = []
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    /// Follows the setting, through `ForkGestures.sync`.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            WindowBackgroundCursor.setEnabled(true)
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refresh()
                // The app coming forward raises its windows over the handle
                // a moment after the notification: step back in just above,
                // so a click on the edge right away still reaches the handle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self?.refresh() }
            }
            halvesChanged()
        } else {
            stopTimer()
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            }
            activationObserver = nil
            for handle in handles {
                if handle.isDragging { handle.finishDrag() }
                handle.orderOut(nil)
            }
            handles = []
            WindowBackgroundCursor.setEnabled(false)
        }
    }

    /// Window Layout remembered a new half: a pair may exist now.
    func halvesChanged() {
        guard enabled else { return }
        refresh()
        guard timer == nil, ForkTrackpadWindowPlacer.shared.hasLinkCandidates else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard enabled else { return }
        if let dragging = handles.first(where: \.isDragging) {
            // The release never came (Command-Tab during the drag…): the
            // button is up, so the drag ends where it is.
            if NSEvent.pressedMouseButtons & 1 == 0 { dragging.finishDrag() }
            return
        }
        guard ForkTrackpadWindowPlacer.shared.hasLinkCandidates else {
            stopTimer()
            for handle in handles { handle.hide() }
            return
        }
        let pairs = ForkTrackpadWindowPlacer.shared.linkedWindowPairs()
        while handles.count < pairs.count { handles.append(ForkLinkedResizeHandle()) }
        let windows = pairs.isEmpty ? [] : ForkLinkedResizeOrder.Window.frontToBack()
        for (index, handle) in handles.enumerated() {
            if index < pairs.count {
                handle.show(pairs[index], among: windows)
            } else {
                handle.hide()
            }
        }
    }
}

/// A pair's handle: a non-activating, transparent panel on the shared edge.
private final class ForkLinkedResizeHandle: NSPanel {
    private(set) var pair: ForkLinkedWindowPair?
    private var session: ForkLinkedResize?
    private var dragStartPointer: CGFloat = 0
    private var appliedBorder: CGFloat = 0
    /// Command held during the drag: only `frontSide` follows the pointer.
    private var unlinked = false
    private var frontSide: ForkLinkedResize.Side = .first
    private var escapeMonitor: Any?
    private var assistiveModes: [EnhancedUserInterfaceSuspension] = []

    var isDragging: Bool { session != nil }

    var cursor: NSCursor {
        pair?.border.axis == .horizontal ? .resizeUpDown : .resizeLeftRight
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle, .transient]
        // A transparent window lets clicks through wherever nothing is
        // drawn: the cursor changed, yet the click reached the app below,
        // which resized itself alone. Saying so forces delivery.
        ignoresMouseEvents = false
        contentView = ForkLinkedResizeHandleView(handle: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Position and order

    func show(_ pair: ForkLinkedWindowPair, among windows: [ForkLinkedResizeOrder.Window]) {
        self.pair = pair
        let strip = pair.border.handleRect
        // Never shown yet, the panel has no window number.
        let number = windowNumber > 0 ? CGWindowID(windowNumber) : 0
        let placement = ForkLinkedResizeOrder.placement(handle: number, strip: strip,
                                                          first: pair.first.key.windowID,
                                                          second: pair.second.key.windowID,
                                                          in: windows)
        switch placement {
        case .hidden:
            hide()
        case .keep:
            place(strip)
        case let .above(number):
            place(strip)
            order(.above, relativeTo: Int(number))
        }
    }

    func hide() {
        pair = nil
        orderOut(nil)
    }

    private func place(_ axRect: CGRect) {
        let rect = NSRect(x: axRect.minX, y: Self.primaryTop - axRect.maxY,
                          width: axRect.width, height: axRect.height)
        if frame != rect { setFrame(rect, display: false) }
    }

    /// The top of the menu bar screen, where Accessibility's y is 0.
    private static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    // MARK: Drag

    /// The pointer along the edge's axis, in Accessibility coordinates.
    private func pointerAlongAxis() -> CGFloat {
        let pointer = NSEvent.mouseLocation
        return pair?.border.axis == .horizontal ? Self.primaryTop - pointer.y : pointer.x
    }

    func beginDrag() {
        guard let pair,
              let first = ForkLinkedResizeService.frame(of: pair.first.element),
              let second = ForkLinkedResizeService.frame(of: pair.second.element)
        else { return }
        let session = ForkLinkedResize(axis: pair.border.axis, first: first, second: second)
        self.session = session
        dragStartPointer = pointerAlongAxis()
        appliedBorder = session.startBorder
        unlinked = false
        frontSide = ForkLinkedResizeOrder.frontSide(first: pair.first.key.windowID,
                                                      second: pair.second.key.windowID,
                                                      in: ForkLinkedResizeOrder.Window.frontToBack())
        ForkTrackpadWindowPlacer.shared.linkedDragBegan(pair)
        // Suspended for the whole drag, not per write, like the pointer
        // gesture: the writes come at pointer speed.
        assistiveModes = [pair.first.element, pair.second.element]
            .compactMap(EnhancedUserInterfaceSuspension.suspend(forAppOf:))
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            self?.cancelDrag()
        }
    }

    func drag() {
        guard let session, let pair else { return }
        if !unlinked, NSEvent.modifierFlags.contains(.command) { unlinked = true }
        let proposed = session.startBorder + (pointerAlongAxis() - dragStartPointer)
        let border = session.clampedBorder(proposed)
        guard border != appliedBorder else { return }
        if unlinked {
            // Only the frontmost window: the other one stays where it is.
            guard writeFrames(session.frames(borderAt: border), of: pair, order: [frontSide]) else { return }
            appliedBorder = border
        } else {
            guard let settled = move(to: border, pair: pair, session: session) else { return }
            appliedBorder = settled
        }
        // The handle follows the edge, to stay under the pointer.
        var moved = pair.border
        moved.firstEnd = appliedBorder
        place(moved.handleRect)
    }

    /// Lays the edge, letting the shrinking window speak first:
    ///
    /// 1. its size alone, read back at once: if the app refuses (TextEdit's
    ///    minimum) or rounds (Terminal's grid), the edge follows what it took;
    /// 2. then its position, and the other window, straight at that edge;
    /// 3. the growing window may round in turn: the other one meets it once
    ///    more.
    ///
    /// No window is ever written at an edge about to be refused: the other
    /// window would follow the pointer over a blocked TextEdit and come
    /// back, trembling on every move.
    ///
    /// Returns the edge laid, or `nil` when a window stopped answering (the
    /// drag is over).
    private func move(to border: CGFloat, pair: ForkLinkedWindowPair,
                      session: ForkLinkedResize) -> CGFloat? {
        let order = ForkLinkedResize.writeOrder(from: appliedBorder, to: border)
        let (shrinking, growing) = (order[0], order[1])
        func window(_ side: ForkLinkedResize.Side) -> AXUIElement {
            side == .first ? pair.first.element : pair.second.element
        }
        func pick(_ frames: (first: CGRect, second: CGRect), _ side: ForkLinkedResize.Side) -> CGRect {
            side == .first ? frames.first : frames.second
        }

        let requested = session.frames(borderAt: border)
        guard ForkLinkedResizeService.setSize(pick(requested, shrinking).size, of: window(shrinking)),
              let taken = ForkLinkedResizeService.frame(of: window(shrinking))
        else {
            abort()
            return nil
        }
        var settled = session.settledBorder(
            requested: requested,
            actualFirst: shrinking == .first ? taken : requested.first,
            actualSecond: shrinking == .second ? taken : requested.second
        ) ?? border

        var target = session.frames(borderAt: settled)
        guard writeFrames(target, of: pair, order: [shrinking, growing]) else { return nil }

        guard let grown = ForkLinkedResizeService.frame(of: window(growing)) else {
            abort()
            return nil
        }
        if let resettled = session.settledBorder(
            requested: target,
            actualFirst: growing == .first ? grown : target.first,
            actualSecond: growing == .second ? grown : target.second
        ) {
            settled = resettled
            target = session.frames(borderAt: settled)
            guard writeFrames(target, of: pair, order: [shrinking, growing]) else { return nil }
        }
        return settled
    }

    /// Writes whole frames in the given order, size before position for a
    /// shrinking window. `false` (and the drag over) when a window stopped
    /// answering.
    private func writeFrames(_ frames: (first: CGRect, second: CGRect), of pair: ForkLinkedWindowPair,
                             order: [ForkLinkedResize.Side]) -> Bool {
        for side in order {
            let (window, after) = side == .first
                ? (pair.first.element, frames.first)
                : (pair.second.element, frames.second)
            let before = ForkLinkedResizeService.frame(of: window) ?? after
            let sizeFirst = ForkLinkedResize.resizesBeforeMoving(from: before, to: after)
            guard ForkLinkedResizeService.setFrame(after, of: window, sizeFirst: sizeFirst) else {
                abort()
                return false
            }
        }
        return true
    }

    /// Released: the frames read back become the pair's reference.
    func finishDrag() {
        guard session != nil, let pair else { return }
        drag()
        guard isDragging else { return } // stopped by the last write
        ForkTrackpadWindowPlacer.shared.linkedDragEnded([
            (pair.first, ForkLinkedResizeService.frame(of: pair.first.element)),
            (pair.second, ForkLinkedResizeService.frame(of: pair.second.element)),
        ])
        endDrag()
    }

    /// Escape: both windows go back to their frames from before the drag.
    func cancelDrag() {
        guard let session, let pair else { return }
        let original = (first: session.originalFirst, second: session.originalSecond)
        _ = writeFrames(original, of: pair,
                        order: ForkLinkedResize.writeOrder(from: appliedBorder, to: session.startBorder))
        guard isDragging else { return }
        ForkTrackpadWindowPlacer.shared.linkedDragEnded([
            (pair.first, ForkLinkedResizeService.frame(of: pair.first.element)),
            (pair.second, ForkLinkedResizeService.frame(of: pair.second.element)),
        ])
        endDrag()
    }

    /// A window closed (or no longer answering) during the drag: stop
    /// there, leave the other one where it is, and dissolve the pair.
    private func abort() {
        if let pair {
            ForkTrackpadWindowPlacer.shared.linkedDragEnded([
                (pair.first, ForkLinkedResizeService.frame(of: pair.first.element)),
                (pair.second, ForkLinkedResizeService.frame(of: pair.second.element)),
            ])
        }
        endDrag()
        hide()
    }

    private func endDrag() {
        session = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        for mode in assistiveModes { mode.resume() }
        assistiveModes = []
        if !frame.contains(NSEvent.mouseLocation) { NSCursor.arrow.set() }
    }
}

/// The handle's content: nothing to draw, only the pointer and the cursor.
private final class ForkLinkedResizeHandleView: NSView {
    private weak var handle: ForkLinkedResizeHandle?

    init(handle: ForkLinkedResizeHandle) {
        self.handle = handle
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The panel is never active: without this, the first click would only
    /// activate it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    private func showCursor() { handle?.cursor.set() }

    override func cursorUpdate(with event: NSEvent) { showCursor() }
    override func mouseEntered(with event: NSEvent) { showCursor() }
    override func mouseMoved(with event: NSEvent) { showCursor() }
    override func mouseExited(with event: NSEvent) {
        // During a drag the pointer runs ahead of the handle: keep the
        // resize cursor.
        if handle?.isDragging != true { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        // Command is read on the first move (`drag`), whether held at the
        // click or pressed on the way.
        showCursor()
        handle?.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        showCursor()
        handle?.drag()
    }

    override func mouseUp(with event: NSEvent) {
        handle?.finishDrag()
    }
}

// MARK: - Accessibility writes

extension ForkLinkedResizeService {
    /// Accessibility coordinates.
    static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// The size alone: the window keeps its origin.
    static func setSize(_ size: CGSize, of window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    /// A whole frame, size first for a shrinking window (see
    /// `ForkLinkedResize.resizesBeforeMoving`). `false` when the app
    /// answered with an error, a closed window most of the time.
    static func setFrame(_ frame: CGRect, of window: AXUIElement, sizeFirst: Bool) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let writes: [(CFString, AXValue)] = sizeFirst
            ? [(kAXSizeAttribute as CFString, sizeValue), (kAXPositionAttribute as CFString, positionValue)]
            : [(kAXPositionAttribute as CFString, positionValue), (kAXSizeAttribute as CFString, sizeValue)]
        return writes.allSatisfy { AXUIElementSetAttributeValue(window, $0.0, $0.1) == .success }
    }
}

/// Lets this background app set the cursor, which macOS otherwise ignores
/// until the app comes forward: the handle got its clicks and drags, but the
/// pointer stayed an arrow, the resize cursor never showed.
///
/// Private window server call, `CGSSetConnectionProperty(connection,
/// connection, "SetsCursorInBackground", true)`, looked up at run time like
/// `SymbolicHotKeys`: if a future macOS drops it, the cursor stops changing
/// and nothing else breaks. Only on while linked windows are.
private enum WindowBackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func setEnabled(_ enabled: Bool) {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let set = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        _ = set(connection, connection, "SetsCursorInBackground" as CFString,
                enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
