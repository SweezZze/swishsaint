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
///    500 ms to start, else it is given up and never lands late (the text
///    is then only in the history).
/// 5. ⌘V carries `ForkDictationKeyTap.syntheticTag`, so dictation's own tap
///    lets it through.
/// 6. The previous clipboard comes back 0.6 s later, only if nobody copied
///    in between, for this Mac only too. It is read while the person speaks
///    (`prepareSnapshot`), not at the paste: a big image or a promised file
///    can take longer to read than the write may wait. Above 32 MB it is
///    not kept, and a flavor that cannot be read is left out, not the rest.
/// 7. The text enters the clipboard history before any of this, so a paste
///    that fails loses nothing.
final class ForkDictationPaster {
    static let shared = ForkDictationPaster()

    private static let logger = Logger(subsystem: "fork.dictation", category: "paste")
    private static let writeDeadline: TimeInterval = 0.5
    private static let restoreDelay: TimeInterval = 0.6
    private static let activationWait: TimeInterval = 0.15
    /// Beyond this the previous clipboard is not kept, so not given back.
    private static let snapshotBudget = 32 * 1024 * 1024

    private struct PendingRestore {
        let snapshot: [NSPasteboardItem]
        let changeCount: Int
    }

    /// The clipboard as it was, read ahead of the paste. Only touched on the
    /// pasteboard lane, which runs the read before the write that uses it.
    private final class SnapshotBox: @unchecked Sendable {
        var changeCount = -1
        /// Nil: too big to keep, nothing to give back.
        var items: [NSPasteboardItem]?
        var isRead = false
    }

    private var pendingRestore: PendingRestore?
    private var restoreWork: DispatchWorkItem?
    private var snapshotBox: SnapshotBox?
    private var generation = 0
    /// The clipboard history entry the last delivery added, if any.
    private(set) var lastHistoryEntryID: UUID?

    /// Adds the text to the clipboard history (which applies its own
    /// settings) and finds the entry it now sits in: a text already there
    /// keeps its entry, moved to the top.
    private static func recordInHistory(_ text: String) -> UUID? {
        let history = ClipboardHistoryService.shared
        history.forkRecordText(text, source: Bundle.main.bundleIdentifier)
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.entries.first { $0.kind == .text && $0.text == kept }?.id
    }

    /// The app in front, remembered when the shortcut is pressed.
    func captureTarget() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    /// Reads the clipboard the next paste gives back, now, off the main
    /// thread. Called once the microphone is open: a shortcut that never
    /// becomes a dictation (⌘C) never reads the clipboard.
    func prepareSnapshot() {
        precondition(Thread.isMainThread)
        let box = SnapshotBox()
        snapshotBox = box
        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            box.changeCount = pasteboard.changeCount
            box.items = Self.snapshot(of: pasteboard)
            box.isRead = true
        }
    }

    /// Forgets a clipboard read for a dictation that ended without a paste
    /// (cancelled, nothing heard, failed): a later paste must not give back
    /// a clipboard older than the person's latest copy.
    func dropSnapshot() {
        precondition(Thread.isMainThread)
        snapshotBox = nil
    }

    func deliver(_ text: String, action: ForkDictationShortcut.Action, target: NSRunningApplication?,
                 addsToHistory: Bool, completion: @escaping (ForkDictationDeliveryOutcome) -> Void) {
        precondition(Thread.isMainThread)
        let inHistory = addsToHistory && ClipboardHistoryService.shared.isRunning
        // The app is the source shown next to the entry; the dictation
        // history keeps the entry's id to point back to it.
        lastHistoryEntryID = addsToHistory ? Self.recordInHistory(text) : nil

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
        let prepared = snapshotBox
        snapshotBox = nil

        GeneralPasteboardAccess.shared.async(timeout: Self.writeDeadline, { isExpired -> (Int, [NSPasteboardItem]?)? in
            let pasteboard = NSPasteboard.general
            var snapshot: [NSPasteboardItem]?
            if !copyOnly {
                let changeCount = pasteboard.changeCount
                if let previous, changeCount == previous.changeCount {
                    snapshot = previous.snapshot
                } else if let prepared, prepared.isRead, changeCount == prepared.changeCount {
                    snapshot = prepared.items
                } else {
                    // Nobody read it ahead, or the person copied something
                    // while speaking: that copy is the one to give back.
                    snapshot = Self.snapshot(of: pasteboard)
                }
            }
            // Given up at the deadline: never write late.
            guard !isExpired() else { return nil }
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            guard pasteboard.setString(text, forType: .string) else { return nil }
            return (pasteboard.changeCount, snapshot)
        }, then: { [weak self] written in
            guard let self else { return }
            guard self.generation == generation else {
                completion(.superseded)
                return
            }
            guard let written else {
                Self.logger.error("paste: the clipboard did not answer in time")
                if inHistory {
                    completion(.inHistoryOnly)
                } else {
                    // Nowhere else to find it: better late on the clipboard than lost.
                    self.writeLate(text, completion: completion)
                }
                return
            }
            let (changeCount, snapshot) = written
            if copyOnly {
                completion(.copied)
                return
            }
            guard willTry, let target, !target.isTerminated, !Self.isSecureInputActive else {
                completion(.keptInClipboard)
                return
            }
            self.bringForward(target, waited: 0) { isFront in
                guard self.generation == generation else {
                    completion(.superseded)
                    return
                }
                guard isFront, !Self.isSecureInputActive else {
                    completion(.keptInClipboard)
                    return
                }
                self.pasteWhenModifiersReleased(attempt: 0, changeCount: changeCount,
                                                generation: generation) { pasted in
                    guard pasted else {
                        completion(self.generation == generation ? .keptInClipboard : .superseded)
                        return
                    }
                    if let snapshot { self.scheduleRestore(snapshot, changeCount: changeCount) }
                    completion(.pasted)
                }
            }
        }, didFinish: { written in
            // The write's real outcome, even when the deadline already
            // answered: the history must not record it again, ever.
            if let written { ClipboardHistoryService.shared.ignoreNextChange(upTo: written.0) }
        })
    }

    /// Without a deadline, after one was missed.
    private func writeLate(_ text: String, completion: @escaping (ForkDictationDeliveryOutcome) -> Void) {
        GeneralPasteboardAccess.shared.async({ () -> Int? in
            let pasteboard = NSPasteboard.general
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            return pasteboard.setString(text, forType: .string) ? pasteboard.changeCount : nil
        }) { changeCount in
            if let changeCount { ClipboardHistoryService.shared.ignoreNextChange(upTo: changeCount) }
            completion(.keptInClipboard)
        }
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
        if waited == 0 {
            // macOS 14 activation is cooperative: the app in front has to
            // hand over, and a menu bar app is rarely the one in front.
            ActivationHandoff.yield(to: target)
            target.activate()
        }
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
                // Given back for this Mac only: it already reached the
                // person's other devices when it was first copied.
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                if !pending.snapshot.isEmpty { pasteboard.writeObjects(pending.snapshot) }
                return pasteboard.changeCount
            }) { restored in
                if let restored { ClipboardHistoryService.shared.ignoreNextChange(upTo: restored) }
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    /// What can be read back of the clipboard, flavor by flavor: a file
    /// promise that cannot be read is left out, the text and images next to
    /// it are kept. Nil above the budget: nothing is given back then.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var snapshot: [NSPasteboardItem] = []
        var bytes = 0
        for item in items {
            let copy = NSPasteboardItem()
            var kept = false
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                bytes += data.count
                guard bytes <= snapshotBudget else { return nil }
                kept = copy.setData(data, forType: type) || kept
            }
            if kept { snapshot.append(copy) }
        }
        return snapshot
    }
}
