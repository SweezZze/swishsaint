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

    /// The history's shortcut closes the island only when it already shows
    /// the Dictations tab, with nothing over it.
    static func togglesClosed(expanded: Bool, onClipboardPage: Bool, tab: ForkNotchDictationsTab,
                              covered: Bool) -> Bool {
        expanded && onClipboardPage && tab == .dictations && !covered
    }

    /// The tab once the island opens or closes: a closed island opens again
    /// on the clipboard, like the clipboard's pinned filter.
    static func tab(_ tab: ForkNotchDictationsTab, expanded: Bool) -> ForkNotchDictationsTab {
        expanded ? tab : .clipboard
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
}
