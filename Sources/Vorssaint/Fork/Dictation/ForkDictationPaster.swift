// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Carbon.HIToolbox
import IOKit
import os

/// Puts a dictation where the person was.
///
/// Its own paste rather than `TransientPaste`, for what dictation needs on
/// top of it:
///
/// 1. The target is the app in front when the shortcut was pressed. It is
///    brought back before ⌘V, and the text stays on the clipboard rather
///    than landing in whatever app is in front by then.
/// 2. Secure input is checked before the write and again before ⌘V: macOS
///    drops synthetic keystrokes while a password field holds it.
/// 3. Written for this Mac only (`.currentHostOnly`): a dictation must not
///    reach the iPhone through Universal Clipboard.
/// 4. Every pasteboard access runs on the app's shared lane; the write has
///    500 ms to start, else it is given up and never lands late.
/// 5. ⌘V carries `ForkDictationKeyTap.syntheticTag`, so dictation's own tap
///    lets it through.
/// 6. The previous clipboard comes back 0.6 s later, only if nobody copied
///    in between.
/// 7. The text enters the clipboard history before any of this, so a paste
///    that fails loses nothing.
final class ForkDictationPaster {
    static let shared = ForkDictationPaster()

    private static let logger = Logger(subsystem: "fork.dictation", category: "paste")
    private static let writeDeadline: TimeInterval = 0.5
    private static let restoreDelay: TimeInterval = 0.6
    private static let activationWait: TimeInterval = 0.15

    private struct PendingRestore {
        let snapshot: [NSPasteboardItem]
        let changeCount: Int
    }

    private var pendingRestore: PendingRestore?
    private var restoreWork: DispatchWorkItem?
    private var generation = 0

    /// The app in front, remembered when the shortcut is pressed.
    func captureTarget() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func deliver(_ text: String, action: ForkDictationShortcut.Action, target: NSRunningApplication?,
                 addsToHistory: Bool, completion: @escaping (ForkDictationDeliveryOutcome) -> Void) {
        precondition(Thread.isMainThread)
        if addsToHistory { ClipboardHistoryService.shared.forkRecordText(text) }

        generation &+= 1
        let generation = generation
        let copyOnly = action == .copy
        let willTry = !copyOnly && target.map { !$0.isTerminated } == true && !Self.isSecureInputActive

        // A previous paste still waiting to give the clipboard back: its
        // snapshot is the person's real clipboard, ours only sits on top.
        let previous = pendingRestore
        restoreWork?.cancel()
        restoreWork = nil
        pendingRestore = nil

        GeneralPasteboardAccess.shared.async(timeout: Self.writeDeadline, { isExpired -> (Int, [NSPasteboardItem]?)? in
            let pasteboard = NSPasteboard.general
            var snapshot: [NSPasteboardItem]?
            if !copyOnly {
                if let previous, pasteboard.changeCount == previous.changeCount {
                    snapshot = previous.snapshot
                } else {
                    snapshot = Self.snapshot(of: pasteboard)
                }
            }
            // Given up at the deadline: never write late.
            guard !isExpired() else { return nil }
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            guard pasteboard.setString(text, forType: .string) else { return nil }
            return (pasteboard.changeCount, snapshot)
        }, then: { [weak self] written in
            // Superseded or given up: the caller still hears back once.
            guard let self, self.generation == generation, let written else {
                if written == nil { Self.logger.error("paste: the clipboard did not answer in time") }
                completion(.keptInClipboard)
                return
            }
            let (changeCount, snapshot) = written
            // Already in the history, or left out of it on purpose.
            ClipboardHistoryService.shared.ignoreNextChange(upTo: changeCount)
            if copyOnly {
                completion(.copied)
                return
            }
            guard willTry, let target, !target.isTerminated, !Self.isSecureInputActive else {
                completion(.keptInClipboard)
                return
            }
            self.bringForward(target, waited: 0) { isFront in
                guard self.generation == generation, isFront, !Self.isSecureInputActive else {
                    completion(.keptInClipboard)
                    return
                }
                self.pasteWhenModifiersReleased(attempt: 0, changeCount: changeCount,
                                                generation: generation) { pasted in
                    guard pasted else {
                        completion(.keptInClipboard)
                        return
                    }
                    if let snapshot { self.scheduleRestore(snapshot, changeCount: changeCount) }
                    completion(.pasted)
                }
            }
        })
    }

    // MARK: - Secure input

    /// While on, macOS drops synthetic keystrokes and blinds event taps.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// The app holding secure input, nil when it cannot be named.
    static func secureInputHolderName() -> String? {
        let enabled = isSecureInputActive
        let holder = SecureInputSupport.holder(
            isEnabled: enabled,
            read: enabled ? recordedHolder() : .noHolder,
            runningApp: { pid in
                guard let app = ResponsibleProcess.regularAppOwner(of: pid) else { return nil }
                return (ResponsibleProcess.displayName(pid: app.processIdentifier, fallback: ""),
                        app.processIdentifier)
            },
            isProcessAlive: { pid in kill(pid, 0) == 0 || errno == EPERM })
        if case let .app(name, _) = holder { return name }
        return nil
    }

    /// The session's secure input holder, as the window server records it
    /// (the same read as `SecureInputMonitor`, which keeps its own private).
    private static func recordedHolder() -> SecureInputSupport.RegistryRead {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard entry != MACH_PORT_NULL else { return .unavailable }
        defer { IOObjectRelease(entry) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            entry, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return .unavailable }
        let uid = getuid()
        guard let session = sessions.first(where: {
            ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid
        }) else { return .unavailable }
        guard let number = session["kCGSSessionSecureInputPID"] as? NSNumber,
              number.int32Value > 0 else { return .noHolder }
        return .holder(number.int32Value)
    }

    // MARK: - Steps

    /// Brings the target back if another app came in front meanwhile. macOS
    /// 14 may refuse a cooperative activation: then the text stays on the
    /// clipboard rather than being pasted in the wrong place.
    private func bringForward(_ target: NSRunningApplication, waited: TimeInterval,
                              completion: @escaping (Bool) -> Void) {
        if target.isActive || NSWorkspace.shared.frontmostApplication == target {
            completion(true)
            return
        }
        if waited == 0 { target.activate() }
        guard waited < Self.activationWait else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            self.bringForward(target, waited: waited + 0.015, completion: completion)
        }
    }

    /// ⌘V once the person has let go of every modifier, else the app would
    /// read ⌘⌥V or ⇧⌘V. Then only if the clipboard still holds the dictation.
    private func pasteWhenModifiersReleased(attempt: Int, changeCount: Int, generation: Int,
                                            completion: @escaping (Bool) -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        guard held.isEmpty || attempt >= 100 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                self.pasteWhenModifiersReleased(attempt: attempt + 1, changeCount: changeCount,
                                                generation: generation, completion: completion)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            GeneralPasteboardAccess.shared.async({ NSPasteboard.general.changeCount == changeCount }) { isCurrent in
                guard isCurrent, self.generation == generation, !Self.isSecureInputActive else {
                    completion(false)
                    return
                }
                Self.postCommandV(completion: completion)
            }
        }
    }

    private static func postCommandV(completion: @escaping (Bool) -> Void) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            completion(false)
            return
        }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: ForkDictationKeyTap.syntheticTag)
        }
        down.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            up.post(tap: .cghidEventTap)
            completion(true)
        }
    }

    private func scheduleRestore(_ snapshot: [NSPasteboardItem], changeCount: Int) {
        pendingRestore = PendingRestore(snapshot: snapshot, changeCount: changeCount)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingRestore, pending.changeCount == changeCount else { return }
            self.pendingRestore = nil
            self.restoreWork = nil
            GeneralPasteboardAccess.shared.async({ () -> Int? in
                let pasteboard = NSPasteboard.general
                // Someone copied since: their copy wins.
                guard pasteboard.changeCount == changeCount else { return nil }
                pasteboard.clearContents()
                if !pending.snapshot.isEmpty { pasteboard.writeObjects(pending.snapshot) }
                return pasteboard.changeCount
            }) { restored in
                if let restored { ClipboardHistoryService.shared.ignoreNextChange(upTo: restored) }
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    /// Nil when a flavor cannot be read back: nothing is restored then,
    /// rather than half of what was there.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else {
            return pasteboard.types?.isEmpty == false ? nil : []
        }
        var snapshot: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                copy.setData(data, forType: type)
            }
            snapshot.append(copy)
        }
        return snapshot
    }
}
