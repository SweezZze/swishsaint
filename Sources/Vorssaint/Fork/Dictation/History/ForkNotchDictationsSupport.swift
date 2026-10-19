// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// The two tabs of the island's clipboard page once dictation is on.
enum ForkNotchDictationsTab: Equatable {
    case clipboard
    case dictations
}

/// Where the dictation history opens.
enum ForkNotchDictationsRoute: Equatable {
    /// The Dictations tab of the island's clipboard page.
    case island
    /// The small floating window that shows the same page.
    case window
}

/// What a key does on the Dictations tab: the clipboard page's own keys,
/// plus Space to listen.
enum ForkNotchDictationsKey: Equatable {
    case clipboard(NotchClipboardKey)
    /// Plays or stops the highlighted dictation.
    case listen
}

/// What a click on Copy shows: the tick once the text is on the clipboard,
/// the system beep when it is not, as the clipboard page does.
enum ForkNotchDictationsCopyFeedback: Equatable {
    case tick
    case beep
    /// A newer delivery took over: nothing to say about this one.
    case none
}

/// Which engines can transcribe a dictation again.
struct ForkNotchDictationsRetranscription: Equatable {
    var parakeet: Bool
    var apple: Bool

    var any: Bool { parakeet || apple }
}

/// The rules of the Dictations tab, apart from the views so they can be tested.
enum ForkNotchDictationsSupport {
    /// The island shows the history when it is on and keeps its clipboard
    /// page, as the official clipboard asks of it; otherwise the window does.
    static func route(islandEnabled: Bool, clipboardPageShown: Bool, dictationEnabled: Bool,
                      acceptsInteraction: Bool) -> ForkNotchDictationsRoute {
        islandEnabled && clipboardPageShown && dictationEnabled && acceptsInteraction ? .island : .window
    }

    /// The island's Dictations button: while dictation is on and the island
    /// keeps the clipboard page its tab lives on, as the Mixer button needs
    /// the Mixer page.
    static func controlAvailable(dictationEnabled: Bool, clipboardPageShown: Bool) -> Bool {
        dictationEnabled && clipboardPageShown
    }

    /// Whether the island shows its clipboard page, open and with nothing
    /// over it: where the Dictations tab can be seen.
    static func showsClipboardPage(expanded: Bool, onClipboardPage: Bool, covered: Bool) -> Bool {
        expanded && onClipboardPage && !covered
    }

    /// The history's shortcut closes the island only when it already shows
    /// the Dictations tab, with nothing over it.
    static func togglesClosed(expanded: Bool, onClipboardPage: Bool, tab: ForkNotchDictationsTab,
                              covered: Bool) -> Bool {
        tab == .dictations && showsClipboardPage(expanded: expanded, onClipboardPage: onClipboardPage, covered: covered)
    }

    /// The tab once the island opens or closes: a closed island opens again
    /// on the clipboard, like the clipboard's pinned filter.
    static func tab(_ tab: ForkNotchDictationsTab, expanded: Bool) -> ForkNotchDictationsTab {
        expanded ? tab : .clipboard
    }

    /// The clipboard's own shortcut and menu while the island keeps the
    /// Dictations tab: they show the clipboard. The shortcut's toggle, with
    /// the tab in view, switches in place (`handled`), where the official
    /// route would close the island; otherwise the official route opens the
    /// page, now on the clipboard. A clipboard that opens in its own window
    /// is left to it.
    static func clipboardRoute(tab: ForkNotchDictationsTab, toggle: Bool, tabInView: Bool,
                               routesToIsland: Bool) -> (tab: ForkNotchDictationsTab, handled: Bool) {
        guard routesToIsland, tab == .dictations else { return (tab, false) }
        return (.clipboard, toggle && tabInView)
    }

    /// The clipboard page's keys first. Space listens while nothing is typed
    /// in the search; once a search has words, it is one more character.
    static func key(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                    composing: Bool, query: String) -> ForkNotchDictationsKey? {
        if let key = NotchSupport.clipboardKey(keyCode: keyCode, characters: characters,
                                               modifiers: modifiers, composing: composing) {
            return .clipboard(key)
        }
        guard keyCode == 49, !composing,
              modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .listen
    }

    /// The dictations the tab lists: pinned first, then newest first; a
    /// search lists its matches newest first. The filter keeps pinned ones.
    static func entries(_ records: [ForkDictationRecord], query: String, pinnedOnly: Bool,
                        calendar: Calendar = .current) -> [ForkDictationRecord] {
        ForkDictationHistoryListing.ordered(ForkDictationHistoryListing.sections(records, query: query,
                                                                                calendar: calendar))
            .filter { !pinnedOnly || $0.isPinned }
    }

    /// ⌘1 to ⌘9 name the first nine places, while the island has the keyboard.
    static func shortcutLabel(place: Int, hasKeyboard: Bool) -> String? {
        place >= 0 && place < 9 && hasKeyboard ? "⌘\(place + 1)" : nil
    }

    /// One transcription at a time, from audio still kept, with an engine
    /// this Mac has.
    static func retranscription(hasAudio: Bool, busy: Bool, parakeetInstalled: Bool,
                                appleUsable: Bool) -> ForkNotchDictationsRetranscription {
        let possible = hasAudio && !busy
        return ForkNotchDictationsRetranscription(parakeet: possible && parakeetInstalled,
                                                  apple: possible && appleUsable)
    }

    /// The tick only for a copy that reached the clipboard.
    static func copyFeedback(_ outcome: ForkDictationDeliveryOutcome) -> ForkNotchDictationsCopyFeedback {
        switch outcome {
        case .copied: return .tick
        case .superseded: return .none
        case .pasted, .keptInClipboard, .inHistoryOnly: return .beep
        }
    }

    /// What "Clear unpinned" deletes.
    static func clearable(_ records: [ForkDictationRecord]) -> [UUID] {
        records.filter { !$0.isPinned }.map(\.id)
    }

    /// A dictation opened from its bubble shows even under the pinned filter.
    static func keepsPinnedFilter(_ pinnedOnly: Bool, revealing record: ForkDictationRecord?) -> Bool {
        pinnedOnly && record?.isPinned != false
    }

    /// The app a paste goes back to: another app, a regular one, still running.
    static func isPasteTarget(bundleID: String?, ownBundleID: String?, regular: Bool, terminated: Bool) -> Bool {
        bundleID != ownBundleID && regular && !terminated
    }

    /// The engine's name, as the Dictation page writes it.
    static func engineName(_ stored: String, text: ForkDictationStrings) -> String {
        stored == "apple" ? text.engineApple : text.parakeetTitle
    }

    /// A dictation with no text: the transcription failed.
    static func isFailed(_ record: ForkDictationRecord) -> Bool {
        record.text.isEmpty
    }

    /// A card's text before it opens: lines and tabs read as spaces, cut
    /// where the clipboard page cuts an entry (`ClipboardHistoryEntry.preview`).
    static func preview(_ text: String) -> String {
        let prefix = text.prefix(ClipboardHistoryEditing.previewCharacters)
        let collapsed = prefix
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = collapsed.isEmpty ? String(prefix) : collapsed
        return prefix.endIndex == text.endIndex ? visible : visible + "…"
    }

    /// The failure kept with a dictation (`ForkDictationRecord.failure`,
    /// written with `String(describing:)`), nil when it cannot be read back.
    static func failure(stored: String?) -> ForkDictationFailure? {
        guard let stored else { return nil }
        if let failure = storableFailures.first(where: { String(describing: $0) == stored }) { return failure }
        guard stored.hasPrefix("secureInput(") else { return nil }
        // secureInput(app: Optional("Terminal")) or secureInput(app: nil).
        guard let open = stored.range(of: "Optional(\""),
              let close = stored.range(of: "\")", options: .backwards), open.upperBound <= close.lowerBound
        else { return .secureInput(app: nil) }
        let app = stored[open.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return .secureInput(app: app)
    }

    /// One of each failure a dictation can keep, `secureInput` without its app.
    static var storableFailures: [ForkDictationFailure] {
        var failures: [ForkDictationFailure] = []
        var next = failure(after: nil)
        while let failure = next {
            failures.append(failure)
            next = self.failure(after: failure)
        }
        return failures
    }

    /// Walks the failures one by one. The switch names every case, so the
    /// compiler asks for a new one here.
    private static func failure(after failure: ForkDictationFailure?) -> ForkDictationFailure? {
        switch failure {
        case nil: return .accessibilityMissing
        case .accessibilityMissing?: return .microphoneDenied
        case .microphoneDenied?: return .microphoneMutedInVorssaint
        case .microphoneMutedInVorssaint?: return .microphoneSilent
        case .microphoneSilent?: return .captureFailed
        case .captureFailed?: return .secureInput(app: nil)
        case .secureInput?: return .speechDenied
        case .speechDenied?: return .speechUnavailableInBuild
        case .speechUnavailableInBuild?: return .languageUnavailable
        case .languageUnavailable?: return .modelMissing
        case .modelMissing?: return .modelDamaged
        case .modelDamaged?: return .transcriptionFailed
        case .transcriptionFailed?: return nil
        }
    }
}
