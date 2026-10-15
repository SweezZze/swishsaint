// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// The groups the trackpad settings show, in reading order.
///
/// Not a table copied gesture by gesture: each catalog entry is sorted by a
/// rule (its target, its family, its shape), so a gesture added to the
/// catalog one day finds its place alone, and the test checking that every
/// gesture shows exactly once catches it if the rule no longer suffices.
enum ForkTrackpadGestureGroup: String, CaseIterable {
    /// One swipe, or the same one twice: halves, maximize, minimize.
    case titlebar
    /// The quarters: one diagonal, or two directions with a pause.
    case quarters
    /// Pinching out and in on a title bar, and pinching in twice.
    case pinch
    /// Two taps with two fingers on a title bar.
    case tap
    /// On a Dock icon: an app's, Finder's, a minimized window's, or the
    /// Trash.
    case dock

    static func of(_ entry: ForkTrackpadGestureCatalog.Entry) -> ForkTrackpadGestureGroup {
        if !entry.targets.contains(.titlebar) { return .dock }
        switch entry.family {
        case .pinch: return .pinch
        case .tap: return .tap
        case .swipe: break
        }
        if case let .swipes(steps) = entry.triggers[0],
           steps.contains(where: \.isDiagonal) || Set(steps).count > 1 {
            return .quarters
        }
        return .titlebar
    }

    /// The groups that have gestures, each with its gestures in catalog
    /// order.
    static func grouped(_ entries: [ForkTrackpadGestureCatalog.Entry] = ForkTrackpadGestureCatalog.entries)
        -> [(group: ForkTrackpadGestureGroup, entries: [ForkTrackpadGestureCatalog.Entry])] {
        allCases.compactMap { group in
            let members = entries.filter { of($0) == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// Whether a group's button switches everything on (all its gestures
    /// are off) or off (at least one is on).
    static func allDisabled(_ entries: [ForkTrackpadGestureCatalog.Entry],
                            in disabled: Set<ForkTrackpadGestureAction>) -> Bool {
        entries.allSatisfy { disabled.contains($0.action) }
    }

    /// A whole group switched on or off, leaving every other gesture alone.
    static func setting(_ entries: [ForkTrackpadGestureCatalog.Entry], enabled: Bool,
                        in disabled: Set<ForkTrackpadGestureAction>) -> Set<ForkTrackpadGestureAction> {
        let actions = Set(entries.map(\.action))
        return enabled ? disabled.subtracting(actions) : disabled.union(actions)
    }
}

/// The gestures switched off one by one, stored as their stable raw values.
enum ForkTrackpadDisabledGestures {
    static func actions(from storedValue: String) -> Set<ForkTrackpadGestureAction> {
        Set(storedValue.split(separator: ",")
            .compactMap { ForkTrackpadGestureAction(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Sorted, so equal sets always store the same string.
    static func storageValue(_ actions: Set<ForkTrackpadGestureAction>) -> String {
        actions.map(\.rawValue).sorted().joined(separator: ",")
    }

    static var current: Set<ForkTrackpadGestureAction> {
        actions(from: UserDefaults.standard.string(forKey: ForkDefaultsKey.disabledGestures) ?? "")
    }
}

extension ForkTrackpadGestureTrigger {
    /// What the fingers do, in arrows: "← ", "↓ ↓", "⤢" (pinch out)…
    var symbols: String {
        switch self {
        case let .swipes(steps):
            return steps.map(\.arrow).joined(separator: " ")
        case let .pinches(steps):
            return steps.map { $0 == .out ? "⤢" : "⤡" }.joined(separator: " ")
        case .doubleTap:
            return "••"
        }
    }
}

/// The name each gesture shows: the placement's own name where Window Layout
/// already has one, so a half reads the same under Keyboard and Trackpad.
enum ForkTrackpadGestureTitle {
    static func title(of action: ForkTrackpadGestureAction,
                      text: ForkTrackpadGestureStrings,
                      layoutText: WindowLayoutFeatureStrings) -> String {
        switch action {
        case .minimize: return text.actionMinimize
        case .close: return text.actionClose
        case .quitWindowApp: return text.actionQuitWindowApp
        case .centerReduced: return text.actionCenter
        case .quitApp: return text.actionQuitApp
        case .emptyTrash: return text.actionEmptyTrash
        case .showAppWindows: return text.actionShowAppWindows
        case .restoreMinimizedWindow: return text.actionRestoreMinimizedWindow
        case .closeMinimizedWindow: return text.actionCloseMinimizedWindow
        default: return action.layoutAction?.title(layoutText) ?? action.rawValue
        }
    }
}
