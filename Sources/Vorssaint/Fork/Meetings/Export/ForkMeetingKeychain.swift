// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
import os
import Security

/// The exporters' secrets, in the login Keychain and nowhere else: never in
/// the preferences, the settings backup, a log or the page once saved.
///
/// - One service of the fork's own (`<bundle id>.meetings`), one account per
///   secret (`webhook@<host>`): an address rewritten in the preferences
///   finds no secret under its own host.
/// - This Mac only, readable once the session is unlocked, never synced
///   with iCloud.
/// - **Read late**: the page asks only whether a secret exists (its
///   attributes, without its data); the data is read at the moment of a
///   send, never at launch.
struct ForkMeetingKeychain {
    let service: String

    static let shared = ForkMeetingKeychain(service: (Bundle.main.bundleIdentifier ?? "swishsaint") + ".meetings")
    private static let log = Logger(subsystem: "fork.meetings", category: "keychain")

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Whether a secret is saved for `account`, without reading it.
    func exists(_ account: String) -> Bool {
        var query = query(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The secret itself: only at the moment of a send.
    func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            if status != errSecItemNotFound { Self.log.error("read refused: \(status, privacy: .public)") }
            return nil
        }
        return data
    }

    /// Saves or replaces the secret; `false` when the Keychain refused, or
    /// the secret did not read back as written.
    @discardableResult
    func save(_ secret: Data, account: String) -> Bool {
        guard !secret.isEmpty else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Self.log.error("save refused: \(status, privacy: .public)")
            return false
        }
        return read(account) == secret
    }

    /// Erases the secret; `true` when none is left.
    @discardableResult
    func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
