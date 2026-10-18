// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CoreGraphics
import Foundation

/// One way to start a dictation: a key, how it is pressed, what happens to
/// the text, and the language to listen for. A person may keep several, say
/// right Command to paste in their own language and right Option for
/// English.
struct ForkDictationShortcut: Codable, Equatable, Identifiable {
    enum Key: Codable, Equatable, Hashable {
        /// A modifier pressed alone, one side only, or fn.
        case modifier(ForkDictationTrigger)
        /// A virtual key code with `GlobalShortcutModifiers` raw value.
        case combo(keyCode: Int64, modifiers: Int)
    }

    enum Mode: String, Codable, CaseIterable {
        /// Held: dictates until the release. Tapped: hands-free.
        case hybrid
        /// Dictates only while held.
        case hold
        /// Each press starts or stops.
        case toggle
    }

    enum Action: String, Codable, CaseIterable {
        /// Writes the text where the person was typing.
        case paste
        /// Leaves the text on the clipboard.
        case copy
        /// Writes the last dictation again, without listening.
        case pasteLast
        /// Opens or closes the dictation history, without listening.
        case openHistory

        /// Acts at once, without listening: no arming, no gesture.
        var isInstant: Bool {
            self == .pasteLast || self == .openHistory
        }
    }

    var id: UUID
    var key: Key
    var mode: Mode
    var action: Action
    /// BCP 47; nil follows the dictation's language.
    var language: String?

    init(id: UUID = UUID(), key: Key, mode: Mode = .hybrid, action: Action = .paste, language: String? = nil) {
        self.id = id
        self.key = key
        self.mode = mode
        self.action = action
        self.language = language
    }

    static let maximumCount = 6

    /// The first shortcut's identifier never changes, so a press seen before
    /// the shortcuts are read again still finds its release.
    static let defaultID = UUID(uuidString: "F0F0D1C7-0000-4000-8000-000000000001")!

    static let `default` = ForkDictationShortcut(id: defaultID, key: .modifier(.fallback))

    /// How long a modifier must stay down, alone, before the microphone
    /// opens: Command+C pressed quickly never lights the microphone.
    static let modifierArmingDelay: TimeInterval = 0.15

    var armingDelay: TimeInterval {
        guard !action.isInstant, case let .modifier(trigger) = key, !trigger.armsImmediately else { return 0 }
        return Self.modifierArmingDelay
    }
}

enum ForkDictationShortcutProblem: Equatable {
    /// Another shortcut, earlier in the list, already uses this key.
    case duplicate
    /// A letter or a symbol without Command, Option or Control would be
    /// typed text.
    case needsModifier
    /// Escape cancels, and Return, Tab, Space or Delete alone are typing.
    case reservedKey
    /// macOS, the apps (⌘C, ⌘Tab…) or another Vorssaint feature answer to
    /// this combination: taking it would break them everywhere.
    case conflict
}

enum ForkDictationShortcuts {
    /// What the stored value of `fork.dictation.shortcuts` holds. Empty, or
    /// unreadable, it falls back to the single key chosen before shortcuts
    /// could be several (`fork.dictation.trigger`). Never empty.
    static func decode(stored: String, legacyTrigger: String) -> [ForkDictationShortcut] {
        if let data = stored.data(using: .utf8), !stored.isEmpty,
           let decoded = try? JSONDecoder().decode([ForkDictationShortcut].self, from: data),
           !decoded.isEmpty {
            return Array(decoded.prefix(ForkDictationShortcut.maximumCount))
        }
        var shortcut = ForkDictationShortcut.default
        shortcut.key = .modifier(ForkDictationTrigger(rawValue: legacyTrigger) ?? .fallback)
        return [shortcut]
    }

    static func encode(_ shortcuts: [ForkDictationShortcut]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(shortcuts.prefix(ForkDictationShortcut.maximumCount))) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func load(_ defaults: UserDefaults = .standard) -> [ForkDictationShortcut] {
        decode(stored: defaults.string(forKey: ForkDefaultsKey.dictationShortcuts) ?? "",
               legacyTrigger: defaults.string(forKey: ForkDefaultsKey.dictationTrigger) ?? "")
    }

    static func save(_ shortcuts: [ForkDictationShortcut], _ defaults: UserDefaults = .standard) {
        defaults.set(encode(shortcuts), forKey: ForkDefaultsKey.dictationShortcuts)
    }

    /// What is wrong with each shortcut that cannot be used, by identifier.
    /// A shortcut absent from the result works. `isTaken` says whether
    /// something else already answers to a combination; the checks inject
    /// their own.
    static func problems(_ shortcuts: [ForkDictationShortcut],
                         isTaken: (GlobalShortcut) -> Bool = isTakenElsewhere)
        -> [UUID: ForkDictationShortcutProblem] {
        var result: [UUID: ForkDictationShortcutProblem] = [:]
        var seen = Set<ForkDictationShortcut.Key>()
        for shortcut in shortcuts {
            if let problem = problem(of: shortcut.key, isTaken: isTaken) {
                result[shortcut.id] = problem
            } else if !seen.insert(normalized(shortcut.key)).inserted {
                result[shortcut.id] = .duplicate
            }
        }
        return result
    }

    /// A combination macOS, the apps or Vorssaint already use: a system
    /// shortcut, a feature's own, or Command (with or without Shift) and a
    /// key that types, which every app's menus answer to.
    static func isTakenElsewhere(_ shortcut: GlobalShortcut) -> Bool {
        isAppMenuShortcut(shortcut)
            || shortcut.conflictsWithSystemShortcut(for: nil)
            || GlobalShortcutRole.conflict(for: shortcut, excluding: nil) != nil
    }

    static func isAppMenuShortcut(_ shortcut: GlobalShortcut) -> Bool {
        let modifiers = shortcut.modifiers.intersection(.validMask)
        return modifiers.contains(.command)
            && modifiers.subtracting([.command, .shift]).isEmpty
            && KeyCode.typingKeys.contains(shortcut.keyCode)
    }

    private static func problem(of key: ForkDictationShortcut.Key,
                                isTaken: (GlobalShortcut) -> Bool) -> ForkDictationShortcutProblem? {
        guard case let .combo(keyCode, raw) = key else { return nil }
        let modifiers = GlobalShortcutModifiers(rawValue: raw).intersection(.validMask)
        if keyCode == KeyCode.escape || (modifiers.isEmpty && KeyCode.typing.contains(keyCode)) {
            return .reservedKey
        }
        if !modifiers.hasPrimaryModifier && !KeyCode.functionRow.contains(keyCode) {
            return .needsModifier
        }
        if isTaken(GlobalShortcut(keyCode: keyCode, modifiers: modifiers)) {
            return .conflict
        }
        return nil
    }

    private static func normalized(_ key: ForkDictationShortcut.Key) -> ForkDictationShortcut.Key {
        guard case let .combo(keyCode, raw) = key else { return key }
        return .combo(keyCode: keyCode, modifiers: GlobalShortcutModifiers(rawValue: raw).intersection(.validMask).rawValue)
    }

    enum KeyCode {
        static let escape: Int64 = 53
        /// Return, Tab, Space, Delete, keypad Enter, forward Delete.
        static let typing: Set<Int64> = [36, 48, 49, 51, 76, 117]
        /// Letters, digits, punctuation, Return, Tab, Space and the grave
        /// accent on an ANSI keyboard: the keys app menus pair with Command.
        static let typingKeys: Set<Int64> = Set(0...50)
        /// F1 to F20: safe without a modifier, typing nothing.
        static let functionRow: Set<Int64> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
            103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        ]
    }
}

/// The shortcuts that work, ready for the event tap: built once on the main
/// thread, then only read from the tap's thread.
struct ForkDictationShortcutTable {
    private let modifiers: [(id: UUID, trigger: ForkDictationTrigger)]
    private let combos: [Int64: [(id: UUID, modifiers: GlobalShortcutModifiers)]]
    private let byID: [UUID: ForkDictationShortcut]

    /// Shortcuts with a problem are left out: the tap never holds back a
    /// key that is not truly the dictation's.
    init(_ shortcuts: [ForkDictationShortcut],
         isTaken: (GlobalShortcut) -> Bool = ForkDictationShortcuts.isTakenElsewhere) {
        let problems = ForkDictationShortcuts.problems(shortcuts, isTaken: isTaken)
        var modifiers: [(id: UUID, trigger: ForkDictationTrigger)] = []
        var combos: [Int64: [(id: UUID, modifiers: GlobalShortcutModifiers)]] = [:]
        var byID: [UUID: ForkDictationShortcut] = [:]
        for shortcut in shortcuts.prefix(ForkDictationShortcut.maximumCount) where problems[shortcut.id] == nil {
            byID[shortcut.id] = shortcut
            switch shortcut.key {
            case let .modifier(trigger):
                modifiers.append((shortcut.id, trigger))
            case let .combo(keyCode, raw):
                combos[keyCode, default: []].append((shortcut.id, GlobalShortcutModifiers(rawValue: raw)
                    .intersection(.validMask)))
            }
        }
        self.modifiers = modifiers
        self.combos = combos
        self.byID = byID
    }

    var isEmpty: Bool { byID.isEmpty }

    var shortcuts: [ForkDictationShortcut] { Array(byID.values) }

    /// The key codes worth a look from the tap; every other key goes by.
    var keyCodes: Set<Int64> {
        Set(modifiers.map { $0.trigger.keyCode }).union(combos.keys)
    }

    func shortcut(_ id: UUID) -> ForkDictationShortcut? { byID[id] }

    /// For a flagsChanged event: the modifier shortcut pressed (true) or
    /// released (false), nil when the key is not one of them.
    func modifierChange(keyCode: Int64, flags: UInt64) -> (id: UUID, isDown: Bool)? {
        for entry in modifiers {
            if let down = entry.trigger.isDown(keyCode: keyCode, flags: flags) { return (entry.id, down) }
        }
        return nil
    }

    /// For a keyDown or keyUp event: the combination with exactly these
    /// modifiers. Caps Lock, fn and the keypad flag never count.
    func combo(keyCode: Int64, flags: UInt64) -> UUID? {
        guard let candidates = combos[keyCode] else { return nil }
        let held = GlobalShortcutModifiers(cgFlags: CGEventFlags(rawValue: flags))
        return candidates.first { $0.modifiers == held }?.id
    }
}
