// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// The end of a session: the text delivered, the last one pasted again,
/// what is shown and heard.
extension ForkDictationService {
    func deliver(_ text: String, action: ForkDictationShortcut.Action) {
        lastDelivered = text
        pasteLastGeneration += 1
        let session = token
        paster.deliver(text, action: action, target: target, addsToHistory: addsToHistory) { [weak self] outcome in
            self?.ifCurrent(session) {
                self?.lastFailure = nil
                let recordID = self?.keepInHistory(text: text, outcome: ForkDictationRecord.Outcome(outcome),
                                                   failure: nil)
                self?.send(.delivered(outcome))
                if let recordID { self?.presenter.attach(recordID: recordID) }
            }
        }
    }

    /// Writes the session's record to the dictation history, with its
    /// audio, once: the kept capture is handed over and forgotten.
    /// Returns the record's id when the history kept it, so the bubble can
    /// open it.
    @discardableResult
    func keepInHistory(text: String, outcome: ForkDictationRecord.Outcome,
                       failure: ForkDictationFailure?) -> UUID? {
        guard let capture = keptCapture else { return nil }
        keptCapture = nil
        let raw = keptRawText ?? ""
        keptRawText = nil
        let archive = ForkDictationArchive.shared
        guard archive.isEnabled else { return nil }
        let record = ForkDictationRecord(
            duration: capture.duration,
            engine: engine?.kind.storedName ?? ForkDictationEngineKind.apple.storedName,
            language: language.isEmpty ? nil : language,
            rawText: raw,
            text: text,
            outcome: outcome,
            failure: failure.map { String(describing: $0) },
            targetBundleID: target?.bundleIdentifier,
            targetName: target?.localizedName,
            hasAudio: true,
            clipboardEntryID: outcome == .failed ? nil : paster.lastHistoryEntryID)
        archive.add(record, samples: capture.samples)
        return archive.records.first?.id == record.id ? record.id : nil
    }

    /// Writes the last dictation again, where the person is now. Outside any
    /// session: the machine stays at rest.
    func pasteLast() {
        guard let text = lastDelivered else {
            present(.nothingHeard(afterSilence: false))
            return
        }
        let excerpt = ForkDictationPresentation.excerpt(text)
        pasteLastGeneration += 1
        let generation = pasteLastGeneration
        paster.deliver(text, action: .paste, target: paster.captureTarget(), addsToHistory: false) { [weak self] outcome in
            guard let self, self.pasteLastGeneration == generation else { return }
            switch outcome {
            case .pasted: self.present(.pasted(excerpt: excerpt))
            case .copied: self.present(.copied(excerpt: excerpt))
            case .keptInClipboard: self.present(.keptInClipboard)
            case .inHistoryOnly: self.present(.inHistoryOnly)
            case .superseded: break
            }
        }
    }

    /// The dictation history panel, opened or closed by its shortcut.
    func toggleHistory() {
        ForkDictationHistoryPanel.shared.toggle()
    }

    private var addsToHistory: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationAddsToHistory)
    }

    func present(_ presentation: ForkDictationPresentation) {
        if case let .failure(failure) = presentation, failure.isLasting {
            if failure == .modelDamaged { modelReplaced = false }
            lastFailure = failure
        }
        presenter.show(presentation)
    }

    // MARK: Sounds

    func play(_ sound: ForkDictationSound) {
        guard UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationSounds) else { return }
        guard let player = sounds[sound] else {
            NSSound.beep()
            return
        }
        player.stop()
        player.play()
    }

    /// Loaded once, quiet: the dictation's sounds sit under the person's
    /// voice, not over it. A failure uses the system alert, at its own volume.
    static func loadSounds() -> [ForkDictationSound: NSSound] {
        let names: [ForkDictationSound: String] = [.start: "Tink", .stop: "Pop", .cancel: "Basso"]
        var sounds: [ForkDictationSound: NSSound] = [:]
        for (sound, name) in names {
            guard let player = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { continue }
            player.volume = soundVolume
            sounds[sound] = player
        }
        return sounds
    }
}

/// When a voice was last heard, written on the audio thread and read on
/// the main thread.
final class ForkDictationVoiceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime

    func reset() { heard() }

    func heard() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { last = now }
    }

    /// Seconds since a voice was last heard.
    var silence: TimeInterval {
        ProcessInfo.processInfo.systemUptime - lock.withLock { last }
    }
}

extension ForkDictationRecord.Outcome {
    init(_ outcome: ForkDictationDeliveryOutcome) {
        switch outcome {
        case .pasted: self = .pasted
        case .copied: self = .copied
        case .keptInClipboard, .superseded: self = .keptInClipboard
        case .inHistoryOnly: self = .inHistoryOnly
        }
    }
}
