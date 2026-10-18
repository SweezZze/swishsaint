// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What the keyboard tells dictation, on the main thread.
enum ForkDictationKeyEvent: Equatable {
    case down(UUID)
    case up(UUID)
    case otherKey
    case escape
}

/// The keyboard tap behind the dictation shortcuts.
///
/// Active and at the head of the session, so it can keep two things from the
/// app in front, and only these: Escape while a dictation can still be given
/// up (its key up too), and a key combination bound to dictation (its
/// repeats and key up too). A modifier on its own is never taken away: right
/// Command is half of every two-handed shortcut.
///
/// A second tap, listen-only, sees clicks, the scroll wheel and the media
/// keys: ⌘-click in the Finder or fn with the volume key is a shortcut too,
/// never the start of a dictation.
///
/// The callbacks run on `PointerTapRunLoop`'s thread and only read the
/// event, consult the table under a lock and post to the main thread, and
/// only when the event matters: a tap that takes too long is switched off by
/// the system.
final class ForkDictationKeyTap: @unchecked Sendable {
    /// Marks the events dictation posts itself (its ⌘V), so this tap lets
    /// them through untouched. "Swis" in ASCII, then a format number.
    static let syntheticTag: Int64 = 0x5377_6973_0000_0001

    private static let escapeKeyCode = Int64(kVK_Escape)
    /// Device bits of the eight side-specific modifiers (IOLLEvent.h) and fn.
    private static let modifierBits: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000
        | CGEventFlags.maskSecondaryFn.rawValue
    private static let significantModifiers: UInt64 = CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
    /// NX_SYSDEFINED: media and brightness keys, fn's own companions.
    private static let systemDefined = CGEventType(rawValue: 14)

    private let handler: (ForkDictationKeyEvent) -> Void

    /// Everything below is shared with the tap thread.
    private let lock = NSLock()
    private var table = ForkDictationShortcutTable([])
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pointerTap: CFMachPort?
    private var pointerSource: CFRunLoopSource?
    private var escapeSwallowed = false
    private var otherKeysReported = false
    private var suspended = false
    private var lastFlags: UInt64 = 0
    /// Shortcuts held down: one press, one signal.
    private var heldModifiers: Set<UUID> = []
    private var heldCombos: [Int64: UUID] = [:]
    /// Keys whose key down was taken: their key up is taken too.
    private var consumedKeys: Set<Int64> = []

    /// `handler` is called on the main thread.
    init(handler: @escaping (ForkDictationKeyEvent) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Escape is taken from the app in front only while this is true: while
    /// listening or transcribing.
    var swallowsEscape: Bool {
        get { lock.withLock { escapeSwallowed } }
        set { lock.withLock { escapeSwallowed = newValue } }
    }

    /// Other keys are only worth a trip to the main thread while a shortcut
    /// is held or a dictation runs: otherwise every keystroke would make one.
    var reportsOtherKeys: Bool {
        get { lock.withLock { otherKeysReported } }
        set { lock.withLock { otherKeysReported = newValue } }
    }

    /// While true nothing is taken and nothing is reported: the settings are
    /// recording a shortcut, which must reach the recorder even when it is
    /// already bound to dictation.
    var isSuspended: Bool {
        get { lock.withLock { suspended } }
        set {
            lock.withLock {
                guard suspended != newValue else { return }
                suspended = newValue
                // What was held before is forgotten: its release must not
                // read as the end of a press nobody saw start.
                heldModifiers = []
                heldCombos = [:]
            }
        }
    }

    var isRunning: Bool { lock.withLock { tap != nil } }

    /// False when Accessibility is missing or the system refuses the tap.
    @discardableResult
    func start(table: ForkDictationShortcutTable) -> Bool {
        update(table: table)
        if isRunning { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ForkDictationKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.receive(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let pointerPort = makePointerTap()
        let pointerSource = pointerPort.flatMap { CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) }
        lock.withLock {
            tap = port
            self.source = source
            self.pointerTap = pointerPort
            self.pointerSource = pointerSource
            // The tap can start with a modifier already down (Accessibility
            // just granted, back with ⌘⇥): without this its release would
            // read as a press.
            lastFlags = CGEventSource.flagsState(.hidSystemState).rawValue
        }
        if let source { PointerTapRunLoop.add(source) }
        if let pointerSource { PointerTapRunLoop.add(pointerSource) }
        CGEvent.tapEnable(tap: port, enable: true)
        if let pointerPort { CGEvent.tapEnable(tap: pointerPort, enable: true) }
        return true
    }

    /// Listen-only: it never holds a click, so the pointer never waits on it.
    /// Without it dictation still works; ⌘-click would just start one.
    private func makePointerTap() -> CFMachPort? {
        var mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        if let systemDefined = Self.systemDefined { mask |= CGEventMask(1 << systemDefined.rawValue) }
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<ForkDictationKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                        .pointerEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    /// New shortcuts. One that disappears while held is released, so a
    /// hold-to-talk dictation never stays open.
    func update(table: ForkDictationShortcutTable) {
        let released = lock.withLock { () -> [UUID] in
            self.table = table
            let gone = heldModifiers.filter { table.shortcut($0) == nil }
                + heldCombos.values.filter { table.shortcut($0) == nil }
            heldModifiers.subtract(gone)
            heldCombos = heldCombos.filter { table.shortcut($0.value) != nil }
            return gone
        }
        for id in released { post(.up(id)) }
    }

    /// Really stops: the tap is switched off and its port invalidated.
    func stop() {
        let (port, source, pointerPort, pointerSource) = lock.withLock {
            () -> (CFMachPort?, CFRunLoopSource?, CFMachPort?, CFRunLoopSource?) in
            let current = (tap, self.source, pointerTap, self.pointerSource)
            tap = nil
            self.source = nil
            pointerTap = nil
            self.pointerSource = nil
            heldModifiers = []
            heldCombos = [:]
            consumedKeys = []
            escapeSwallowed = false
            otherKeysReported = false
            return current
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { PointerTapRunLoop.remove(source, invalidating: port) }
        if let pointerPort { CGEvent.tapEnable(tap: pointerPort, enable: false) }
        if let pointerSource { PointerTapRunLoop.remove(pointerSource, invalidating: pointerPort) }
    }

    // MARK: - Tap thread

    /// True takes the event away from the app in front.
    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            // Releases may have gone by while the tap was off (secure input
            // blinds it too): a shortcut still marked as held would keep a
            // hold-to-talk dictation open and swallow its next press.
            resynchronize(flags: CGEventSource.flagsState(.hidSystemState).rawValue, checksCombos: true)
            return false
        }
        // Our own ⌘V comes back through a session tap: let it pass first.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        switch type {
        case .flagsChanged:
            modifiersChanged(keyCode: keyCode, flags: flags)
            return false
        case .keyDown:
            return keyDown(keyCode: keyCode, flags: flags,
                           isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            return keyUp(keyCode: keyCode)
        default:
            return false
        }
    }

    private func modifiersChanged(keyCode: Int64, flags: UInt64) {
        var events: [ForkDictationKeyEvent] = []
        lock.withLock {
            defer { lastFlags = flags }
            guard !suspended else { return }
            events += releasedModifiers(flags: flags)
            if let change = table.modifierChange(keyCode: keyCode, flags: flags) {
                if change.isDown {
                    if heldModifiers.insert(change.id).inserted { events.append(.down(change.id)) }
                } else if heldModifiers.remove(change.id) != nil {
                    events.append(.up(change.id))
                }
                return
            }
            // Another modifier pressed while a shortcut is held: the start of
            // a key combination, not a dictation. Its release means nothing.
            let pressed = (flags & ~lastFlags) & Self.modifierBits
            if pressed != 0, reportsNow { events.append(.otherKey) }
        }
        events.forEach(post)
    }

    /// Lock held. Other keys count while the main thread asks for them, and
    /// also as soon as a shortcut is down: the main thread may not have
    /// caught up with the press yet, and a quick ⌘C must still read as one.
    private var reportsNow: Bool {
        otherKeysReported || !heldModifiers.isEmpty || !heldCombos.isEmpty
    }

    /// Lock held. Shortcuts marked as held whose key is no longer down.
    private func releasedModifiers(flags: UInt64) -> [ForkDictationKeyEvent] {
        let gone = heldModifiers.filter { id in
            guard case let .modifier(trigger)? = table.shortcut(id)?.key else { return true }
            return flags & trigger.downMask == 0
        }
        heldModifiers.subtract(gone)
        return gone.map { .up($0) }
    }

    /// After the tap was off: modifiers and combinations released meanwhile
    /// are released here too.
    private func resynchronize(flags: UInt64, checksCombos: Bool) {
        let events = lock.withLock { () -> [ForkDictationKeyEvent] in
            lastFlags = flags
            var events = releasedModifiers(flags: flags)
            if checksCombos {
                for (keyCode, id) in heldCombos
                where !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode)) {
                    heldCombos[keyCode] = nil
                    consumedKeys.remove(keyCode)
                    events.append(.up(id))
                }
            }
            return events
        }
        events.forEach(post)
    }

    /// A click, the wheel or a media key while a shortcut is held: the
    /// shortcut is part of something else. The wheel's momentum after a
    /// flick and the other system events (power, eject…) are no gesture of
    /// the person's.
    private func pointerEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ pointerTap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard lock.withLock({ reportsNow && !suspended }) else { return }
        if type == .scrollWheel {
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            guard ForkDictationOtherInput.scrollCounts(momentumPhase: momentum) else { return }
        } else if type == Self.systemDefined {
            guard let system = NSEvent(cgEvent: event),
                  ForkDictationOtherInput.systemKeyCounts(subtype: Int(system.subtype.rawValue),
                                                          data1: system.data1) else { return }
        }
        post(.otherKey)
    }

    private func keyDown(keyCode: Int64, flags: UInt64, isRepeat: Bool) -> Bool {
        var event: ForkDictationKeyEvent?
        let consumed = lock.withLock { () -> Bool in
            if isRepeat {
                // A repeat is no new press, but a key that is ours stays ours:
                // the app in front must not get one per repeat.
                return consumedKeys.contains(keyCode)
            }
            guard !suspended else { return false }
            // While a dictation can be given up, Escape is Escape whatever is
            // held: in hold-to-talk the trigger itself (⌘, ⌥…) is still down.
            if keyCode == Self.escapeKeyCode, escapeSwallowed || flags & Self.significantModifiers == 0 {
                guard escapeSwallowed || reportsNow else { return false }
                event = .escape
                guard escapeSwallowed else { return false }
                consumedKeys.insert(keyCode)
                return true
            }
            if let id = table.combo(keyCode: keyCode, flags: flags) {
                consumedKeys.insert(keyCode)
                if heldCombos[keyCode] == nil {
                    heldCombos[keyCode] = id
                    event = .down(id)
                }
                return true
            }
            if reportsNow { event = .otherKey }
            return false
        }
        if let event { post(event) }
        return consumed
    }

    private func keyUp(keyCode: Int64) -> Bool {
        var event: ForkDictationKeyEvent?
        let consumed = lock.withLock { () -> Bool in
            // The release follows its press, whatever modifiers are held now.
            if let id = heldCombos.removeValue(forKey: keyCode) { event = .up(id) }
            return consumedKeys.remove(keyCode) != nil
        }
        if let event { post(event) }
        return consumed
    }

    private func post(_ event: ForkDictationKeyEvent) {
        let handler = handler
        DispatchQueue.main.async { handler(event) }
    }
}
