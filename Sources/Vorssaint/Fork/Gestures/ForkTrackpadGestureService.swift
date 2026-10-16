// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Two-finger gestures on a window's title bar: swipes place it, pinches take
/// it to full screen, close it or quit its app, a double tap centers it. A
/// pinch in on the Dock icon of a running app quits that app.
///
/// ```
///  pointer input thread                       main thread
///  ────────────────────                       ───────────
///  listen-only tap ─▶ decode ─▶ async ──────▶ ForkTrackpadGestureMachine ─▶ effects
///  (scroll, gesture)   no AX                   │  Dock or title bar hit test (AX), once per gesture
///                                              ├─ preview panel
///                                              └─ timer at nextDeadline ─▶ .tick
/// ```
///
/// The tap only listens: nothing is swallowed, so the app under the pointer
/// also sees the start of the swipe. It is served by `PointerTapRunLoop` and
/// does no Accessibility work there. The hit test runs on the main thread:
/// asked from any other thread, an Accessibility question about one of this
/// app's own windows is answered on the asking thread, and AppKit then
/// rebuilds its views off the main thread.
final class ForkTrackpadGestureService {
    static let shared = ForkTrackpadGestureService()

    /// Title bars drawn by hand (Chrome) read as plain groups: the band from
    /// the top of the window that still counts as a title bar. Tuned in
    /// settings, read on every sync like the rest.
    private var titlebarBandHeight = ForkTrackpadTuning.titlebarBand.defaultValue
    private var previewEnabled = true
    private var hapticsEnabled = true
    /// A toolbar is a few levels up from the element hit; past this, the
    /// pointer is inside content.
    private static let maxHitTestDepth = 25
    private static let hitTestTimeout: Float = 0.1

    /// A decoded event on its way to the main thread.
    private struct Input {
        var event: ForkTrackpadGestureMachine.Event
        var time: TimeInterval
        /// Where the event happened, in Accessibility coordinates. Only the
        /// event that opens a gesture uses it, for the hit test.
        var location: CGPoint
        /// The keys held when this event was read. Matched on the main
        /// thread against the stronger gestures' keys (a gesture's modified
        /// meaning, decided fresh at every step and at the commit alike) and
        /// the grid's (in place of the plain half or quarter).
        var heldKeys: ForkTrackpadModifierKeys
    }

    /// What the gesture in progress started on. The action goes there even if
    /// the pointer has moved since.
    private enum Target {
        /// `frame` in Accessibility coordinates, for the preview's screen.
        case window(AXUIElement, frame: CGRect)
        case dockApp(pid_t)
        case dockTrash
        case dockFinder(pid_t)
        /// The thumbnail's own Dock item, and the window it stands for when
        /// exactly one minimized window bears its title.
        case dockMinimizedWindow(item: AXUIElement, window: (element: AXUIElement, pid: pid_t)?)
    }

    // Main thread only.
    private var machine = ForkTrackpadGestureMachine()
    private var clock = ForkTrackpadGestureClock()
    private var target: Target?
    /// Where the gesture in progress began, for the light on the pointer.
    private var gestureOrigin = CGPoint.zero
    /// The keys each held meaning needs, as chosen in settings.
    private var strongerKeys = ForkTrackpadModifierKeys.strongerDefault
    private var gridKeys = ForkTrackpadModifierKeys.gridDefault
    /// The stronger keys, as of the last event: a gesture's stronger meaning, read fresh
    /// for every preview step and for the commit alike.
    private var modifierHeld = false
    /// The grid keys, as of the last event: the grid modifier the machine itself
    /// needs, to decide which continuous tracking a swipe takes up the
    /// moment it first combines.
    private var gridModifierHeld = false
    /// The window last chained to on an app's Dock icon, so the next swipe
    /// in either direction knows where it left off.
    private var chainedWindow: [pid_t: CGWindowID] = [:]
    private var deadlineTimer: Timer?
    private var scheduledDeadline: TimeInterval?
    private(set) var isRunning = false

    // Shared with the pointer input thread.
    private let tapStateLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        // Read on every sync, so a gesture switched off in settings is off
        // for the very next one.
        machine.configuration.disabledActions = ForkTrackpadDisabledGestures.current
        ForkTrackpadTuning.apply(to: &machine.configuration)
        titlebarBandHeight = ForkTrackpadTuning.titlebarBand.current
        previewEnabled = UserDefaults.standard.bool(forKey: ForkDefaultsKey.previewEnabled)
        hapticsEnabled = UserDefaults.standard.bool(forKey: ForkDefaultsKey.hapticsEnabled)
        (gridKeys, strongerKeys) = ForkTrackpadModifierKeys.current()
        if let port = tapStateLock.withLock({ tap }) {
            CGEvent.tapEnable(tap: port, enable: true)
            isRunning = true
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1) << CGEventMask(ForkTrackpadEventDecoding.gestureEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let service = Unmanaged<ForkTrackpadGestureService>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    service.observe(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isRunning = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapStateLock.withLock {
            self.tap = tap
            runLoopSource = source
        }
        if let source {
            PointerTapRunLoop.add(source)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        let (port, source) = tapStateLock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let current = (tap, runLoopSource)
            tap = nil
            runLoopSource = nil
            return current
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            PointerTapRunLoop.remove(source, invalidating: port)
        }
        // Events already on their way still arrive; they find the machine
        // reset and a gesture that never began.
        resetGesture()
        chainedWindow.removeAll()
        isRunning = false
    }

    // MARK: - Pointer input thread

    /// Decodes and hands over. Never touches Accessibility or the machine.
    private func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Events were lost: the gesture in progress has no reliable end
            // any more. Re-armed unless this session was switched away from.
            if SessionActivity.shared.isActive, let port = tapStateLock.withLock({ tap }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            DispatchQueue.main.async { [weak self] in self?.resetGesture() }
            return
        }
        let time = Double(EventTimestamp.nanoseconds(of: event)) / 1_000_000_000
        // `NSEvent(cgEvent:)` leaves autoreleased objects behind, and this
        // thread's run loop drains no pool of its own.
        let decoded: ForkTrackpadGestureMachine.Event? = autoreleasepool {
            if type == .scrollWheel {
                return Self.decodeScroll(event)
            }
            if type.rawValue == ForkTrackpadEventDecoding.gestureEventType {
                return Self.decodeGesture(event)
            }
            return nil
        }
        guard let decoded else { return }
        let input = Input(event: decoded, time: time, location: event.location,
                          heldKeys: ForkTrackpadModifierKeys(flags: event.flags))
        DispatchQueue.main.async { [weak self] in self?.handle(input) }
    }

    private static func decodeScroll(_ event: CGEvent) -> ForkTrackpadGestureMachine.Event? {
        guard let scroll = NSEvent(cgEvent: event) else { return nil }
        let delta = ForkTrackpadEventDecoding.scrollDelta(
            dx: Double(scroll.deltaX), dy: Double(scroll.deltaY),
            directionInvertedFromDevice: scroll.isDirectionInvertedFromDevice)
        return .scroll(phase: ForkTrackpadEventDecoding.phase(appKitRawValue: scroll.phase.rawValue),
                       momentum: ForkTrackpadEventDecoding.phase(appKitRawValue: scroll.momentumPhase.rawValue),
                       dx: delta.dx, dy: delta.dy)
    }

    private static func decodeGesture(_ event: CGEvent) -> ForkTrackpadGestureMachine.Event? {
        let subtypeField = unsafeBitCast(ForkTrackpadEventDecoding.gestureSubtypeField, to: CGEventField.self)
        switch ForkTrackpadEventDecoding.gestureKind(subtype: event.getIntegerValueField(subtypeField)) {
        case .smartMagnify:
            // No phase read here: `NSEvent.phase` raises on event types that
            // have none.
            return .smartMagnify
        case .magnify:
            let field = unsafeBitCast(ForkTrackpadEventDecoding.magnificationField, to: CGEventField.self)
            // Without a phase the machine falls back on a short silence for
            // the lift.
            let phase = NSEvent(cgEvent: event).flatMap {
                ForkTrackpadEventDecoding.phase(appKitRawValue: $0.phase.rawValue)
            }
            return .magnify(cumulative: event.getDoubleValueField(field), phase: phase)
        case nil:
            return nil
        }
    }

    // MARK: - Main thread

    private func handle(_ input: Input) {
        guard isRunning else { return }
        modifierHeld = input.heldKeys == strongerKeys
        gridModifierHeld = input.heldKeys == gridKeys
        let now = clock.time(for: input.time)
        let output = machine.handle(input.event, at: now, gridModifierHeld: gridModifierHeld) { [self] in
            gestureOrigin = input.location
            let dockHit = Self.dockItem(at: input.location)
            switch dockHit?.verdict {
            case .app(let app)?:
                target = .dockApp(app.pid)
                return .dockApp
            case .trash?:
                target = .dockTrash
                return .dockTrash
            case .finder(let finder)?:
                target = .dockFinder(finder.pid)
                return .dockFinder
            case .minimizedWindow(let title)?:
                guard let item = dockHit?.item else { break }
                target = .dockMinimizedWindow(item: item, window: Self.minimizedWindow(titled: title))
                return .dockMinimizedWindow
            default:
                break
            }
            if let (window, frame) = Self.titlebarWindow(at: input.location, bandHeight: titlebarBandHeight) {
                target = .window(window, frame: frame)
                return .titlebar
            }
            target = nil
            return nil
        }
        perform(output.effects)
        scheduleDeadline()
    }

    private func tick() {
        deadlineTimer = nil
        scheduledDeadline = nil
        guard isRunning else { return }
        let now = clock.time(for: ProcessInfo.processInfo.systemUptime)
        perform(machine.handle(.tick, at: now, gridModifierHeld: gridModifierHeld) { nil }.effects)
        scheduleDeadline()
    }

    /// Moved only when the deadline comes earlier: during a swipe every event
    /// pushes it back, and a timer that fires early just sends a `.tick`
    /// without effect, then sets itself on the new deadline.
    private func scheduleDeadline() {
        guard let deadline = machine.nextDeadline else {
            deadlineTimer?.invalidate()
            deadlineTimer = nil
            scheduledDeadline = nil
            return
        }
        if let scheduledDeadline, scheduledDeadline <= deadline { return }
        deadlineTimer?.invalidate()
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tick() }
        // Common modes: a pinch still ends while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
        scheduledDeadline = deadline
    }

    private func resetGesture() {
        perform(machine.reset())
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
        target = nil
    }

    private func perform(_ effects: [ForkTrackpadGestureMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .commit(let rawAction):
                let action = ForkTrackpadModifierRemap.action(for: rawAction, modifierHeld: modifierHeld,
                                                              disabled: machine.configuration.disabledActions)
                switch (target, action) {
                case (.dockApp(let pid)?, .quitApp):
                    Self.quitDockApp(pid: pid)
                case (.dockTrash?, .emptyTrash):
                    Self.emptyTrash()
                case (.dockApp(let pid)?, .showAppWindows), (.dockFinder(let pid)?, .showAppWindows):
                    Self.showAppWindows(pid: pid)
                case (.dockApp(let pid)?, .showNextWindow), (.dockFinder(let pid)?, .showNextWindow):
                    showAdjacentWindow(pid: pid, forward: true)
                case (.dockApp(let pid)?, .showPreviousWindow), (.dockFinder(let pid)?, .showPreviousWindow):
                    showAdjacentWindow(pid: pid, forward: false)
                case (.dockMinimizedWindow(let item, _)?, .restoreMinimizedWindow):
                    // A click on the thumbnail: the Dock brings that window back.
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                case (.dockMinimizedWindow(_, let window?)?, .closeMinimizedWindow):
                    Self.closeMinimizedWindow(window.element)
                case (.window(let window, _)?, _) where action.isWindowAction:
                    ForkTrackpadWindowPlacer.shared.apply(action, to: window)
                default:
                    // The table pairs each action with its kind of target, so
                    // this is never reached.
                    break
                }
            case .haptic(.step):
                guard hapticsEnabled else { break }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            case .haptic(.cancel):
                guard hapticsEnabled else { break }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            case .showPreview(let preview):
                // Hiding stays unconditional: a preview shown before the
                // switch went off still goes away.
                guard previewEnabled else { break }
                showPreview(preview)
            case .hidePreview:
                ForkTrackpadGesturePreview.shared.hide()
            case .cancelled:
                break
            }
        }
    }

    private var isOnWindow: Bool {
        if case .window? = target { return true }
        return false
    }

    private func showPreview(_ rawPreview: ForkTrackpadGestureMachine.Preview) {
        // The preview announces the gesture's held-modifier meaning too, so
        // it never shows one thing and acts on another.
        let preview: ForkTrackpadGestureMachine.Preview
        if case .action(let action) = rawPreview {
            preview = .action(ForkTrackpadModifierRemap.action(for: action, modifierHeld: modifierHeld,
                                                                disabled: machine.configuration.disabledActions))
        } else {
            preview = rawPreview
        }
        // On a title bar a "?" says the lift will do nothing. On the Dock,
        // where a sideways scroll is no attempt at a gesture, it would only
        // get in the way: nothing shows until the gesture means something.
        if preview == .unrecognized, !isOnWindow {
            ForkTrackpadGesturePreview.shared.hide()
            return
        }
        var targetFrame: CGRect?
        var pid: pid_t?
        switch target {
        case .dockApp(let appPID)?:
            pid = appPID
        case .dockTrash?:
            break
        case .dockFinder(let finderPID)?:
            pid = finderPID
        case .dockMinimizedWindow(_, let window)?:
            pid = window?.pid
        case .window(let window, let frame)?:
            targetFrame = frame
            var windowPID = pid_t(0)
            if preview == .action(.quitWindowApp), AXUIElementGetPid(window, &windowPID) == .success {
                pid = windowPID
            }
        case nil:
            break
        }
        ForkTrackpadGesturePreview.shared.show(ForkTrackpadPreviewContent(preview,
                                                                              centerScale: ForkTrackpadTuning.centerSize.current),
                                                 targetFrame: targetFrame,
                                                 pointer: gestureOrigin,
                                                 appIcon: preview == .action(.emptyTrash)
                                                    ? NSImage(named: NSImage.trashFullName)
                                                    : pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon })
    }

    // MARK: - Dock

    /// Quits like ⌘Q or Quit in the icon's menu: `terminate()`, never a force
    /// quit, so the app may ask to save or refuse. The Dock hit test already
    /// left out this app and the protected ones; checked again right before
    /// the step that cannot be undone, so it never rests on one check alone.
    /// The app Accessibility finds under `point`: what settles whether a
    /// window drawn over the Dock, which may be an overlay passing input
    /// through (a screenshot session's, for one), really keeps the pointer
    /// from it. The same question the official Dock click service asks, which
    /// keeps its own copy private. The system-wide element is asked without a
    /// timeout of its own, since one set there would apply to everything this
    /// process asks.
    static func accessibilityProcessID(at point: CGPoint) -> pid_t? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(point.x), Float(point.y),
                                               &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private static func quitDockApp(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              !ForkTrackpadDock.protectedBundleIdentifiers.contains(app.bundleIdentifier ?? "")
        else { return }
        app.terminate()
    }

    /// Finder's own Empty Trash, ⇧⌘⌫, the command behind Empty Trash in the
    /// Trash's Dock menu: Finder asks first as it always does (unless the
    /// person turned that warning off in Finder's settings), empties every
    /// volume's Trash, and nothing is deleted behind its back. Finder comes
    /// forward first so its question does not open behind the current app.
    private static func emptyTrash() {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: ForkTrackpadDock.finderBundleIdentifier).first
        else { return }
        _ = finder.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + emptyTrashActivationDelay) {
            guard !finder.isTerminated else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: CGKeyCode(kVK_Delete), keyDown: isDown)
                else { continue }
                event.flags = ForkTrackpadDock.emptyTrashFlags
                // Straight to Finder: no other app, nor this one's own
                // keyboard taps, ever sees the shortcut.
                event.postToPid(finder.processIdentifier)
            }
        }
    }

    /// What a click on an app's Dock icon does, and a little more: every
    /// minimized window of the app comes back, not only the last one, and a
    /// hidden app shows again. With nothing to bring back, opening the
    /// running app sends it the same reopen event a Dock click sends: it
    /// brings its windows forward, or opens a new one when it has none.
    private static func showAppWindows(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated
        else { return }
        running.unhide()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let minimized = (elements(app, kAXWindowsAttribute) ?? []).filter {
            bool($0, kAXMinimizedAttribute) == true
        }
        for window in minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // Reopening while windows are still unminimizing could open one more.
        guard minimized.isEmpty, let url = running.bundleURL else {
            _ = running.activate(options: [])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Brings the window after (or before) the app's current one to the
    /// front, cycling past the last back to the first: swiping the same way
    /// again on its Dock icon keeps stepping through them. A minimized
    /// window never counts, so chaining never un-minimizes one by surprise:
    /// with only one left visible, that one simply comes forward; with none
    /// at all, every minimized window comes back, exactly as `showAppWindows`
    /// would, since there is then nothing of its own left to chain to.
    ///
    /// Ordered by window ID, not by which one macOS currently shows in
    /// front: raising a window to the front is itself what every step does,
    /// so that order changes under this very gesture. The window ID does
    /// not, and `chainedWindow` remembers the one last raised, so forward
    /// and back always mean the same thing from one swipe to the next.
    private func showAdjacentWindow(pid: pid_t, forward: Bool) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated
        else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let windows = (Self.elements(app, kAXWindowsAttribute) ?? []).filter {
            Self.bool($0, kAXMinimizedAttribute) != true
        }
        let ordered = windows.compactMap { window in
            AXWindowResolver.windowID(for: window).map { (id: $0, element: window) }
        }.sorted { $0.id < $1.id }
        guard ordered.count > 1 else {
            guard let only = ordered.first else {
                Self.showAppWindows(pid: pid)
                return
            }
            chainedWindow[pid] = only.id
            running.unhide()
            _ = running.activate(options: [])
            AXUIElementPerformAction(only.element, kAXRaiseAction as CFString)
            return
        }
        let currentIndex = chainedWindow[pid].flatMap { id in ordered.firstIndex { $0.id == id } }
        let nextIndex = ForkTrackpadWindowChain.nextIndex(current: currentIndex, count: ordered.count,
                                                          forward: forward)
        let next = ordered[nextIndex]
        chainedWindow[pid] = next.id
        running.unhide()
        _ = running.activate(options: [])
        AXUIElementPerformAction(next.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(next.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(next.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// The minimized window a thumbnail's title names, among the windows of
    /// every regular app: see `ForkTrackpadDock.minimizedWindow`. Only
    /// asked when a gesture starts on a thumbnail.
    private static func minimizedWindow(titled title: String?) -> (element: AXUIElement, pid: pid_t)? {
        guard let title, !title.isEmpty else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var candidates: [ForkTrackpadDock.MinimizedWindow] = []
        var elementsByCandidate: [AXUIElement] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID && !app.isTerminated {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, hitTestTimeout)
            for (index, window) in (elements(element, kAXWindowsAttribute) ?? []).enumerated()
            where bool(window, kAXMinimizedAttribute) == true {
                candidates.append(.init(pid: app.processIdentifier, index: index,
                                        title: string(window, kAXTitleAttribute)))
                elementsByCandidate.append(window)
            }
        }
        guard let match = ForkTrackpadDock.minimizedWindow(titled: title, among: candidates),
              let position = candidates.firstIndex(of: match)
        else { return nil }
        return (elementsByCandidate[position], match.pid)
    }

    /// The window's red button, pressed even while minimized: the app
    /// decides, so an unsaved document still asks, and the app stays open.
    /// Checked again right before: still minimized, else it is no longer the
    /// thumbnail the gesture was made on.
    private static func closeMinimizedWindow(_ window: AXUIElement) {
        guard bool(window, kAXMinimizedAttribute) == true,
              let button = element(window, kAXCloseButtonAttribute)
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// Long enough for Finder to come forward before its alert opens.
    private static let emptyTrashActivationDelay: TimeInterval = 0.15

    /// The Dock item under `point`, when a gesture may act on it: a running
    /// app, Finder, the Trash or a minimized window's thumbnail.
    ///
    /// A geometric gate first, so the Dock is only asked about points in its
    /// strip, and only while it is on screen: with auto-hide, its layer-20
    /// window leaves the on-screen list once it has slid away. The icon is
    /// then matched along the Dock's long axis (see `ForkTrackpadDock`).
    private static func dockItem(at point: CGPoint) -> (verdict: ForkTrackpadDock.Verdict, item: AXUIElement)? {
        guard isInsideDockStrip(point),
              let dock = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == "com.apple.dock"
              })
        else { return nil }
        let dockPID = dock.processIdentifier
        // A window drawn over the Dock is settled by Accessibility, as Dock
        // clicks are: one that really covers it keeps the gesture, an overlay
        // that lets input through (a screenshot session's full-screen window)
        // does not take the Dock away.
        guard DockClickSupport.dockOwnsPoint(point,
                                             windows: WindowServerSupport.onScreenWindows(),
                                             dockProcessID: dockPID,
                                             dockLayer: Int(CGWindowLevelForKey(.dockWindow)),
                                             ownProcessID: getpid(),
                                             accessibilityHitProcessID: {
                                                 Self.accessibilityProcessID(at: point)
                                             })
        else { return nil }

        let dockElement = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockElement, hitTestTimeout)
        guard let lists = elements(dockElement, kAXChildrenAttribute) else { return nil }
        for list in lists where string(list, kAXRoleAttribute) == "AXList" {
            AXUIElementSetMessagingTimeout(list, hitTestTimeout)
            guard let listFrame = frame(of: list),
                  let items = elements(list, kAXChildrenAttribute)
            else { continue }
            items.forEach { AXUIElementSetMessagingTimeout($0, hitTestTimeout) }
            guard let index = ForkTrackpadDock.itemIndex(at: point, itemFrames: items.map(frame(of:)),
                                                           listFrame: listFrame)
            else { continue }
            let item = items[index]
            let url = self.url(item, kAXURLAttribute)
            let verdict = ForkTrackpadDock.evaluate(
                item: ForkTrackpadAXNode(role: string(item, kAXRoleAttribute),
                                           subrole: string(item, kAXSubroleAttribute)),
                isRunning: bool(item, "AXIsApplicationRunning") ?? false,
                itemURL: url,
                itemBundleIdentifier: url.flatMap { Bundle(url: $0)?.bundleIdentifier },
                itemTitle: string(item, kAXTitleAttribute),
                runningApps: NSWorkspace.shared.runningApplications.map {
                    ForkTrackpadRunningApp(pid: $0.processIdentifier, bundleURL: $0.bundleURL,
                                             bundleIdentifier: $0.bundleIdentifier)
                },
                ownPID: ProcessInfo.processInfo.processIdentifier)
            switch verdict {
            case .app, .trash, .finder, .minimizedWindow: return (verdict, item)
            case .notAnAppItem, .notRunning, .ownApp, .protectedApp: return nil
            }
        }
        return nil
    }

    /// In Accessibility coordinates, like the event's location.
    private static func isInsideDockStrip(_ point: CGPoint) -> Bool {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.maxY else { return false }
        func axRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.contains { screen in
            DockClickSupport.dockStripContains(point, screenFrame: axRect(screen.frame),
                                               visibleFrame: axRect(screen.visibleFrame))
        }
    }

    // MARK: - Title bar hit test

    /// The window whose title bar is at `point`, with its frame, or `nil`.
    /// Main thread only; see the type's documentation.
    private static func titlebarWindow(at point: CGPoint, bandHeight: Double) -> (AXUIElement, CGRect)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let pid = ForkTrackpadWindowStack.owner(at: point, in: onScreenWindows(), ownPID: ownPID),
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              app.activationPolicy == .regular,
              !WindowLayoutIgnoredApps.shared.contains(bundleID: app.bundleIdentifier,
                                                       executablePath: app.executableURL?.path)
        else { return nil }

        // Asked of that app alone, so a hung one costs a tenth of a second
        // and the timeout stays its own.
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, hitTestTimeout)
        var rawHit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &rawHit) == .success,
              let hit = rawHit
        else { return nil }
        AXUIElementSetMessagingTimeout(hit, hitTestTimeout)

        var path: [ForkTrackpadAXNode] = []
        var current = hit
        for _ in 0..<maxHitTestDepth {
            let node = ForkTrackpadAXNode(role: string(current, kAXRoleAttribute),
                                            subrole: string(current, kAXSubroleAttribute))
            if node.role == kAXWindowRole as String {
                guard let frame = frame(of: current) else { return nil }
                let verdict = ForkTrackpadTitlebar.evaluate(path: path, window: node,
                                                              windowFrame: frame, point: point,
                                                              bandHeight: bandHeight)
                return verdict == .titlebar ? (current, frame) : nil
            }
            path.append(node)
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            // A timeout belongs to one element reference, not to the app.
            AXUIElementSetMessagingTimeout(parent, hitTestTimeout)
            current = parent
        }
        return nil
    }

    /// Front to back. Reads the window server only, never an app.
    private static func onScreenWindows() -> [ForkTrackpadWindowStack.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return ForkTrackpadWindowStack.Window(
                pid: pid,
                bounds: bounds,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFURLGetTypeID()
        else { return nil }
        return (value as! CFURL) as URL
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// In Accessibility coordinates: origin at the top left of the main
    /// screen, like an event's location.
    private static func frame(of window: AXUIElement) -> CGRect? {
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
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}
