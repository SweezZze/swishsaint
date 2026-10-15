// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// The fork's settings in the official settings backup (seam `backup`).
///
/// The official backup only carries the keys it knows, and its key list is
/// compiled by the official tests without the fork, so the fork does not
/// add to it. It adds its own settings to the file once the official app
/// has written it, under the same `settings` dictionary, and on import reads
/// them back from the file and writes them when the official settings are.
/// An official Vorssaint opening such a file simply ignores the extra keys.
enum ForkBackup {
    /// The fork settings to write in a backup: every registered one, at its
    /// current value (registered defaults included, like the official ones).
    static func currentSettings(_ defaults: UserDefaults = .standard) -> [String: Any] {
        var settings: [String: Any] = [:]
        for key in ForkDefaults.registered.keys {
            if let value = defaults.object(forKey: key) { settings[key] = value }
        }
        return settings
    }

    /// The fork settings a backup payload carries, old names included, each
    /// only if its value has the registered type: a tampered or foreign file
    /// writes nothing else.
    static func settings(inPayload payload: [String: Any]) -> [String: Any] {
        guard let settings = payload[SettingsBackupSupport.settingsKey] as? [String: Any] else { return [:] }
        var found: [String: Any] = [:]
        for (key, value) in settings where ForkDefaults.backupKeys.contains(key) {
            guard let expected = ForkDefaults.registered[ForkDefaults.legacyKeys[key] ?? key],
                  sameKind(value, expected)
            else { continue }
            found[key] = value
        }
        return found
    }

    /// The payload with the fork settings added to its `settings`.
    static func adding(_ fork: [String: Any], to payload: [String: Any]) -> [String: Any] {
        guard var settings = payload[SettingsBackupSupport.settingsKey] as? [String: Any] else { return payload }
        settings.merge(fork) { _, new in new }
        var result = payload
        result[SettingsBackupSupport.settingsKey] = settings
        return result
    }

    /// What an import writes: every fork setting cleared first, like the
    /// official import clears its own, then the backup's values. Old names
    /// are written as such; `ForkDefaults.register` moves them at relaunch.
    static func apply(_ fork: [String: Any], to defaults: UserDefaults) {
        for key in ForkDefaults.registered.keys { defaults.removeObject(forKey: key) }
        for (key, value) in fork { defaults.set(value, forKey: key) }
    }

    private static func sameKind(_ value: Any, _ expected: Any) -> Bool {
        switch expected {
        case is Bool: return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case is Int: return (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
        case is String: return value is String
        default: return false
        }
    }

    // MARK: - Seam entry points

    private static var remembered: [String: Any]?

    /// After the official export wrote the file.
    static func addForkSettings(toBackupAt url: URL) {
        guard let data = try? Data(contentsOf: url),
              let payload = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let updated = try? PropertyListSerialization.data(
                fromPropertyList: adding(currentSettings(), to: payload), format: .xml, options: 0)
        else { return }
        try? updated.write(to: url, options: .atomic)
    }

    /// When the official import reads the file.
    static func rememberForkSettings(inBackupAt url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let payload = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            remembered = nil
            return
        }
        remembered = settings(inPayload: payload)
    }

    /// Once the official import has written its settings, before relaunch.
    static func applyRememberedForkSettings() {
        guard let fork = remembered else { return }
        remembered = nil
        apply(fork, to: .standard)
    }
}
