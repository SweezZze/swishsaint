// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import CoreGraphics
import Foundation

/// The keys a person holds through a gesture: one or more of ⌃ ⌥ ⇧ ⌘.
///
/// Matched exactly: with ⌥ for the grid and ⇧ for the stronger gestures,
/// holding ⌥⇧ is neither. So a combination never reaches two meanings at
/// once, and the two choices only have to differ.
struct ForkTrackpadModifierKeys: OptionSet, Hashable {
    let rawValue: Int

    static let control = ForkTrackpadModifierKeys(rawValue: 1 << 0)
    static let option = ForkTrackpadModifierKeys(rawValue: 1 << 1)
    static let shift = ForkTrackpadModifierKeys(rawValue: 1 << 2)
    static let command = ForkTrackpadModifierKeys(rawValue: 1 << 3)

    /// In the order macOS writes them in a shortcut.
    static let ordered: [(key: ForkTrackpadModifierKeys, symbol: String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    static let gridDefault: ForkTrackpadModifierKeys = .option
    static let strongerDefault: ForkTrackpadModifierKeys = .shift

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The keys among ⌃ ⌥ ⇧ ⌘ an event carries. Caps Lock and fn are left
    /// out: they never mean a gesture.
    init(flags: CGEventFlags) {
        var keys: ForkTrackpadModifierKeys = []
        if flags.contains(.maskControl) { keys.insert(.control) }
        if flags.contains(.maskAlternate) { keys.insert(.option) }
        if flags.contains(.maskShift) { keys.insert(.shift) }
        if flags.contains(.maskCommand) { keys.insert(.command) }
        self = keys
    }

    var symbols: String {
        Self.ordered.filter { contains($0.key) }.map(\.symbol).joined()
    }

    /// The grid's keys and the stronger gestures' keys, as stored. A choice
    /// that is empty, unknown, or the same as the other falls back to its
    /// default, so the two never collide.
    static func current(_ defaults: UserDefaults = .standard)
        -> (grid: ForkTrackpadModifierKeys, stronger: ForkTrackpadModifierKeys) {
        func read(_ key: String, _ fallback: ForkTrackpadModifierKeys) -> ForkTrackpadModifierKeys {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return valid(ForkTrackpadModifierKeys(rawValue: defaults.integer(forKey: key)), fallback: fallback)
        }
        let grid = read(ForkDefaultsKey.gridModifierKeys, gridDefault)
        let stronger = read(ForkDefaultsKey.strongerModifierKeys, strongerDefault)
        guard grid != stronger else { return (gridDefault, strongerDefault) }
        return (grid, stronger)
    }

    static func valid(_ keys: ForkTrackpadModifierKeys,
                      fallback: ForkTrackpadModifierKeys) -> ForkTrackpadModifierKeys {
        let known = keys.intersection([.control, .option, .shift, .command])
        return known.isEmpty ? fallback : known
    }
}
