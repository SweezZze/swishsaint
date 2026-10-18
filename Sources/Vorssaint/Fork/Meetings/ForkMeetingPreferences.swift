// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The shortcut that starts and stops a meeting recording: one combination,
/// stored as the official shortcuts are (`GlobalShortcut.storageValue`,
/// `"control+option+command:46"`), so a backup reads the same on every Mac.
/// Empty: none, the default.
enum ForkMeetingShortcut {
    /// The stored combination, or `nil` when there is none or it cannot be
    /// one: unreadable, a key alone, or a key that is never accepted. A
    /// combination something else answers to is kept: what is taken changes
    /// with the system and the other features, so `problem` is asked again
    /// each time the shortcut is installed.
    static func decode(_ stored: String) -> GlobalShortcut? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let shortcut = GlobalShortcut(storageValue: trimmed),
              problem(of: shortcut, isTaken: { _ in false }) == nil else { return nil }
        return shortcut
    }

    static func encode(_ shortcut: GlobalShortcut?) -> String {
        shortcut?.storageValue ?? ""
    }

    static func load(_ defaults: UserDefaults = .standard) -> GlobalShortcut? {
        decode(defaults.string(forKey: ForkDefaultsKey.meetingsShortcut) ?? "")
    }

    static func save(_ shortcut: GlobalShortcut?, _ defaults: UserDefaults = .standard) {
        defaults.set(encode(shortcut), forKey: ForkDefaultsKey.meetingsShortcut)
    }

    /// What keeps a combination from starting a recording, or `nil` when it
    /// can. `isTaken` says whether something else already answers to it; the
    /// checks inject their own.
    static func problem(of shortcut: GlobalShortcut,
                        isTaken: (GlobalShortcut) -> Bool = isTakenElsewhere) -> ForkMeetingShortcutProblem? {
        let modifiers = shortcut.modifiers.intersection(.validMask)
        // Escape gives up whatever is in front, with or without modifiers:
        // a recording must never start, or stop, in its place.
        if shortcut.keyCode == ForkDictationShortcuts.KeyCode.escape
            || (modifiers.isEmpty && ForkDictationShortcuts.KeyCode.typing.contains(shortcut.keyCode)) {
            return .reservedKey
        }
        if !modifiers.hasPrimaryModifier && !ForkDictationShortcuts.KeyCode.functionRow.contains(shortcut.keyCode) {
            return .needsModifier
        }
        return isTaken(shortcut) ? .conflict : nil
    }

    /// macOS, the apps' menus, an official feature, or one of dictation's
    /// combinations: the same checks as dictation's, plus dictation itself.
    static func isTakenElsewhere(_ shortcut: GlobalShortcut) -> Bool {
        ForkDictationShortcuts.isTakenElsewhere(shortcut) || usedByDictation(shortcut)
    }

    /// Only while dictation is on: a switched-off feature holds no key.
    static func usedByDictation(_ shortcut: GlobalShortcut,
                                enabled: Bool = UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationEnabled),
                                shortcuts: [ForkDictationShortcut] = ForkDictationShortcuts.load()) -> Bool {
        guard enabled else { return false }
        return shortcuts.contains { dictation in
            guard case let .combo(keyCode, raw) = dictation.key else { return false }
            return GlobalShortcut(keyCode: keyCode, modifiers: GlobalShortcutModifiers(rawValue: raw)) == shortcut
        }
    }
}

enum ForkMeetingShortcutProblem: Equatable {
    /// Escape, or Return, Tab, Space or Delete alone.
    case reservedKey
    /// A letter or a symbol without Command, Option or Control would be
    /// typed text.
    case needsModifier
    /// macOS, the apps (⌘C…), another Vorssaint feature or dictation answer
    /// to it.
    case conflict
}

/// Which microphone a meeting records (`fork.meetings.microphone`).
enum ForkMeetingMicrophoneChoice: Equatable, Hashable {
    /// The input the meeting app uses, else the system's.
    case meeting
    /// The system's input at the time.
    case system
    case builtIn
    /// A capture device's unique ID (the CoreAudio UID).
    case device(String)
    /// No microphone: the meeting alone.
    case off

    static let fallback: ForkMeetingMicrophoneChoice = .meeting

    /// The same words as dictation's for the choices they share.
    init(stored: String?) {
        switch stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" {
        case "", "meeting": self = .meeting
        case "system": self = .system
        case "builtin": self = .builtIn
        case "off": self = .off
        case let uid: self = .device(uid)
        }
    }

    var storageValue: String {
        switch self {
        case .meeting: return "meeting"
        case .system: return "system"
        case .builtIn: return "builtin"
        case let .device(uid): return uid
        case .off: return "off"
        }
    }

    /// What a recording uses on this Mac, given the unique IDs of the
    /// microphones plugged in. A device chosen elsewhere, or unplugged since,
    /// falls back to the meeting's microphone, never to nothing: a meeting
    /// recorded without a voice is lost. The choice itself stays stored, so
    /// the device is used again once it is back.
    func effective(available: [String]) -> ForkMeetingMicrophoneChoice {
        guard case let .device(uid) = self, !available.contains(uid) else { return self }
        return .fallback
    }
}

/// The text copied to announce a recording in the meeting's chat.
enum ForkMeetingAnnouncementText {
    /// The person's own text, or the default one in their language when
    /// theirs is empty: an empty setting follows a change of language.
    static func text(stored: String, strings: ForkMeetingStrings) -> String {
        let own = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? strings.announcementDefault : own
    }

    /// What to store for a text edited on the page: the default one, or
    /// nothing at all, becomes empty, so it keeps following the language.
    static func stored(edited: String, strings: ForkMeetingStrings) -> String {
        let own = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        return own == strings.announcementDefault ? "" : own
    }
}
