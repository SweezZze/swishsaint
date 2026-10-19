// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
import os
import Security

/// The exporters' secrets, in the login Keychain and nowhere else: never in
/// the preferences, the settings backup, a log or the page once saved.
///
/// - One service of the fork's own (`<bundle id>.meetings`), one account per
///   secret (`webhook@<host[:port]>#<exporter id>`): an address rewritten in
///   the preferences finds no secret under its own host.
/// - Readable once the session is unlocked, on this Mac and in its backups
///   (a Time Machine copy of the login Keychain), never synced with iCloud.
/// - **Read late**: the page asks only whether a secret exists (its
///   attributes, without its data); the data is read at the moment of a
///   send, never at launch.
/// - **Bounded**: a Keychain that does not answer (a dialog nobody sees, a
///   locked keychain) fails after `timeout` instead of holding the sends.
/// - It also keeps the fingerprint of the exporters' list the page wrote
///   (`fingerprintAccount`): another process may rewrite the preferences,
///   not this item.
struct ForkMeetingKeychain {
    let service: String
    var timeout: TimeInterval = 60

    static let shared = ForkMeetingKeychain(service: (Bundle.main.bundleIdentifier ?? "swishsaint") + ".meetings")
    static let fingerprintAccount = "exporters"
    private static let log = Logger(subsystem: "fork.meetings", category: "keychain")

    /// A read: the data, nothing saved, or a Keychain that refused or did
    /// not answer in time.
    enum Read: Equatable {
        case found(Data)
        case missing
        case failed
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Runs one Keychain call on a queue of its own and waits `timeout` for
    /// it; `nil` when it did not come back.
    private func bounded<Value>(_ call: @escaping () -> Value) -> Value? {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let value = call()
            box.lock.withLock { box.value = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            Self.log.error("no answer in \(Int(timeout), privacy: .public) s")
            return nil
        }
        return box.lock.withLock { box.value }
    }

    private final class Box<Value>: @unchecked Sendable {
        let lock = NSLock()
        var value: Value?
    }

    /// Whether a secret is saved for `account`, without reading it.
    func exists(_ account: String) -> Bool {
        var query = query(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let dictionary = query as CFDictionary
        return bounded { SecItemCopyMatching(dictionary, nil) } == errSecSuccess
    }

    /// The secret itself: only at the moment of a send.
    func read(_ account: String) -> Read {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let dictionary = query as CFDictionary
        let answer: (OSStatus, Data?)? = bounded {
            var result: AnyObject?
            let status = SecItemCopyMatching(dictionary, &result)
            return (status, result as? Data)
        }
        guard let (status, data) = answer else { return .failed }
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data, !data.isEmpty else {
            Self.log.error("read refused: \(status, privacy: .public)")
            return .failed
        }
        return .found(data)
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
        let match = query(account) as CFDictionary
        var item = query(account)
        item.merge(attributes) { $1 }
        let added = item as CFDictionary
        let changes = attributes as CFDictionary
        let status: OSStatus? = bounded {
            var status = SecItemUpdate(match, changes)
            if status == errSecItemNotFound { status = SecItemAdd(added, nil) }
            return status
        }
        guard status == errSecSuccess else {
            Self.log.error("save refused: \(status ?? errSecNotAvailable, privacy: .public)")
            return false
        }
        return read(account) == .found(secret)
    }

    /// Erases the secret; `true` when none is left.
    @discardableResult
    func delete(_ account: String) -> Bool {
        let dictionary = query(account) as CFDictionary
        let status = bounded { SecItemDelete(dictionary) }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
