// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

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
/// The callback runs on `PointerTapRunLoop`'s thread and only reads the
/// event, consults the table under a lock and posts to the main thread, and
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

    private let handler: (ForkDictationKeyEvent) -> Void

    /// Everything below is shared with the tap thread.
    private let lock = NSLock()
    private var table = ForkDictationShortcutTable([])
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var escapeSwallowed = false
    private var otherKeysReported = false
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
        lock.withLock {
            tap = port
            self.source = source
            // The tap can start with a modifier already down (Accessibility
            // just granted, back with ⌘⇥): without this its release would
            // read as a press.
            lastFlags = CGEventSource.flagsState(.hidSystemState).rawValue
        }
        if let source { PointerTapRunLoop.add(source) }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
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
        let (port, source) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let current = (tap, self.source)
            tap = nil
            self.source = nil
            heldModifiers = []
            heldCombos = [:]
            consumedKeys = []
            escapeSwallowed = false
            otherKeysReported = false
            return current
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { PointerTapRunLoop.remove(source, invalidating: port) }
    }

    // MARK: - Tap thread

    /// True takes the event away from the app in front.
    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
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
            if pressed != 0, otherKeysReported { events.append(.otherKey) }
        }
        events.forEach(post)
    }

    private func keyDown(keyCode: Int64, flags: UInt64, isRepeat: Bool) -> Bool {
        var event: ForkDictationKeyEvent?
        let consumed = lock.withLock { () -> Bool in
            if isRepeat {
                // A repeat is no new press, but a key that is ours stays ours:
                // the app in front must not get one per repeat.
                return consumedKeys.contains(keyCode)
            }
            if keyCode == Self.escapeKeyCode, flags & Self.significantModifiers == 0 {
                guard escapeSwallowed || otherKeysReported else { return false }
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
            if otherKeysReported { event = .otherKey }
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
