// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
import os

/// The exporters of this Mac and the sends: the registry the Meetings page
/// edits, the library's "Export To" and Retry, and the automatic send after
/// a meeting is finalized.
///
/// - **One serial utility queue sends**, one meeting to one exporter at a
///   time, in the order asked: an hour of audio to a NAS and a webhook never
///   fight for the disk.
/// - Each send gathers the meeting first (`prepare`): its `meeting.json`,
///   its M4A (the folder's own, or one made from the video into a private
///   temporary folder), its transcript; then hands it to the exporter, then
///   appends the result to `meeting.json` through the store's queue.
/// - A meeting being recorded or finished is never sent, and one that did
///   not end well never on its own (`ForkMeetingExportEligibility`).
/// - Nothing secret is published, logged or kept here: the Keychain is read
///   by the webhook at the moment it signs.
///
/// Main thread, except the work on `queue`.
final class ForkMeetingExports: ObservableObject {
    static let shared = ForkMeetingExports()

    /// The exporters, in the order they were added.
    @Published private(set) var configs: [ForkMeetingExporterConfig] = []
    /// The sends running or waiting, by `key(folder, target)`.
    @Published private(set) var pending: Set<String> = []
    /// The latest result of each exporter for each meeting folder (its
    /// standardized path), read back from `meeting.json`.
    @Published private(set) var results: [String: [String: ForkMeetingExportHistory.Result]] = [:]
    /// Why a send was refused before it began (a meeting being written),
    /// by `key(folder, target)`: said beside the exporter, not written.
    @Published private(set) var refusals: [String: ForkMeetingExportFailure] = [:]
    /// Which Keychain accounts hold a secret, asked without reading it.
    @Published private(set) var savedSecrets: Set<String> = []
    /// The last "Send a test" of each webhook: its status, or why it failed.
    @Published private(set) var tests: [String: Result<Int, ForkMeetingExportFailure>] = [:]
    @Published private(set) var testing: Set<String> = []

    let defaults: UserDefaults
    let store: ForkMeetingStore
    let keychain: ForkMeetingKeychain
    /// The webhook's view of certificates: the system's, always, in the
    /// app (the recipe harness alone gives its own).
    var trust: ForkWebhookExporter.Trust = .system
    /// The folders this app records or finishes now.
    private let writing: () -> Set<String>
    let queue = DispatchQueue(label: "fork.meetings.export", qos: .utility)
    private let log = Logger(subsystem: "fork.meetings", category: "export")

    init(defaults: UserDefaults = .standard, store: ForkMeetingStore = .shared,
         keychain: ForkMeetingKeychain = .shared,
         writing: @escaping () -> Set<String> = { ForkMeetingService.shared.writingFolders }) {
        self.defaults = defaults
        self.store = store
        self.keychain = keychain
        self.writing = writing
        reload()
    }

    var hasExporters: Bool { !configs.isEmpty }

    static func key(_ folder: URL, _ target: String) -> String { folder.standardizedFileURL.path + "\n" + target }

    // MARK: - Registry

    func reload() {
        configs = ForkMeetingExporterList.decode(defaults.string(forKey: ForkDefaultsKey.meetingsExporters))
        refreshSecrets()
    }

    private func store(_ configs: [ForkMeetingExporterConfig]) {
        defaults.set(ForkMeetingExporterList.encode(configs), forKey: ForkDefaultsKey.meetingsExporters)
        self.configs = configs
        refreshSecrets()
    }

    func refreshSecrets() {
        savedSecrets = Set(configs.compactMap(\.secretAccount).filter(keychain.exists))
    }

    func config(_ id: String) -> ForkMeetingExporterConfig? { configs.first { $0.id == id } }

    func exporter(_ config: ForkMeetingExporterConfig) -> ForkMeetingExporter {
        switch config.kind {
        case .dropFolder:
            return ForkDropFolderExporter(config: config, libraryRoot: store.root())
        case .webhook:
            return webhook(config)
        }
    }

    private func webhook(_ config: ForkMeetingExporterConfig) -> ForkWebhookExporter {
        let keychain = self.keychain
        return ForkWebhookExporter(config: config, secret: { keychain.read($0) }, hasSecret: { keychain.exists($0) },
                                   trust: trust)
    }

    /// A new exporter, manual and empty: the page fills it.
    @discardableResult
    func add(_ kind: ForkMeetingExportKind) -> String {
        let config = ForkMeetingExporterConfig(kind: kind)
        store(configs + [config])
        return config.id
    }

    /// Changes what holds no secret: the mode, the Meet code, the folder.
    func update(_ config: ForkMeetingExporterConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        var next = configs
        var kept = config
        // The address and its origin change only through `saveWebhook`.
        kept.address = configs[index].address
        kept.origin = configs[index].origin
        next[index] = kept
        store(next)
    }

    /// Removes the exporter, and its secret when no other exporter sends to
    /// the same origin.
    func remove(_ id: String) {
        guard let config = config(id) else { return }
        let rest = configs.filter { $0.id != id }
        if let account = config.secretAccount, !rest.contains(where: { $0.secretAccount == account }) {
            keychain.delete(account)
        }
        store(rest)
    }

    enum AddressChange: Equatable {
        case saved
        /// The host changes while a secret is saved for the old one: asked
        /// first, since the old secret is erased.
        case confirmHostChange(old: String)
        case refused(ForkMeetingOriginPolicy.Refusal)
        /// The Keychain refused the secret: the address is saved, the
        /// secret is not.
        case secretNotSaved
    }

    /// Saves a webhook's address, freezing its origin, and its new secret
    /// when one was typed (written once, here, then forgotten by the page).
    /// A change of host erases the old host's secret, once `confirmed`.
    func saveWebhook(_ id: String, address: String, secret: String, confirmed: Bool) -> AddressChange {
        guard let index = configs.firstIndex(where: { $0.id == id }), configs[index].kind == .webhook else { return .saved }
        let verdict = ForkMeetingOriginPolicy.destination(address)
        guard case let .approved(url, origin) = verdict else { return .refused(verdict.refusal ?? .unreadable) }
        var config = configs[index]
        if let old = config.origin, old != origin.name, let oldAccount = config.secretAccount {
            let shared = configs.contains { $0.id != id && $0.secretAccount == oldAccount }
            if !shared, keychain.exists(oldAccount) {
                guard confirmed else { return .confirmHostChange(old: old) }
                keychain.delete(oldAccount)
            }
        }
        config.address = url.absoluteString
        config.origin = origin.name
        var next = configs
        next[index] = config
        store(next)
        let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, let account = config.secretAccount {
            let saved = keychain.save(Data(typed.utf8), account: account)
            refreshSecrets()
            if !saved { return .secretNotSaved }
        }
        return .saved
    }

    func hasSecret(_ config: ForkMeetingExporterConfig) -> Bool {
        config.secretAccount.map(savedSecrets.contains) ?? false
    }

    /// Ready to send: a folder chosen, or an address approved with its
    /// secret.
    func isConfigured(_ config: ForkMeetingExporterConfig) -> Bool {
        switch config.kind {
        case .dropFolder: return ForkDropFolderExporter(config: config, libraryRoot: store.root()).isConfigured
        case .webhook: return (try? webhook(config).approvedTarget()) != nil && hasSecret(config)
        }
    }

    // MARK: - Sending

    /// The library's "Export To", and Retry: a click, so a meeting that did
    /// not end well goes too.
    func export(_ folder: URL, to target: String) {
        guard let config = config(target) else { return }
        enqueue(folder, config, automatic: false)
    }

    /// A meeting finalized: every automatic exporter set up gets it, when
    /// it ended well. Called by the service after the saved notice, never
    /// for a meeting recovered at launch.
    func meetingFinished(_ folder: URL) {
        for config in configs where config.mode == .automatic && isConfigured(config) {
            enqueue(folder, config, automatic: true)
        }
    }

    private func enqueue(_ folder: URL, _ config: ForkMeetingExporterConfig, automatic: Bool) {
        let key = Self.key(folder, config.id)
        guard !pending.contains(key) else { return }
        pending.insert(key)
        refusals[key] = nil
        let live = writing().contains(folder.standardizedFileURL.path)
        let exporter = exporter(config)
        queue.async { [self] in
            let outcome = send(folder, exporter: exporter, live: live, automatic: automatic)
            DispatchQueue.main.async { [self] in
                pending.remove(key)
                switch outcome {
                case .skipped: break
                case let .refused(failure): refusals[key] = failure
                case let .recorded(exports): publish(folder, exports)
                }
            }
        }
    }

    enum SendOutcome {
        /// Automatic, and the meeting needs a click: nothing written.
        case skipped
        /// Refused before anything began, and not written: the meeting is
        /// being written, or its `meeting.json` cannot be.
        case refused(ForkMeetingExportFailure)
        /// Done or failed, and appended: the meeting's exports as written.
        case recorded([ForkMeetingSidecar.Export])
    }

    /// Export queue. The whole send of one meeting to one exporter.
    func send(_ folder: URL, exporter: ForkMeetingExporter, live: Bool, automatic: Bool) -> SendOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        let sidecar = store.sidecar(in: folder)
        let isLive = live || store.isClaimedHere(folder)
        switch ForkMeetingExportEligibility.verdict(sidecar, live: isLive, automatic: automatic, target: exporter.id) {
        case .needsClick:
            log.notice("automatic export left for a click: \(folder.lastPathComponent, privacy: .private)")
            return .skipped
        case let .refused(failure):
            return .refused(failure)
        case .allowed:
            break
        }
        guard case let .success(meeting) = sidecar else { return .refused(.unreadable) }
        let started = Date()
        let record: ForkMeetingSidecar.Export
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork.meetings.export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let package = try Self.blocking { try await Self.prepare(folder, sidecar: meeting, staging: staging) }
            let receipt = try Self.blocking { try await exporter.export(package, progress: { _ in }) }
            record = ForkMeetingExportHistory.record(receipt)
            log.notice("exported to \(exporter.kind.rawValue, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        } catch {
            let failure = error as? ForkMeetingExportFailure ?? .writeFailed
            record = ForkMeetingExportHistory.record(failure, target: exporter.id, kind: exporter.kind, at: Date())
            log.error("export to \(exporter.kind.rawValue, privacy: .public) failed: \(failure.code, privacy: .public) \(failure.httpStatus ?? 0, privacy: .public)")
        }
        var patch = ForkMeetingSidecarPatch()
        patch.export = record
        guard store.write(patch, in: folder), case let .success(written) = store.sidecar(in: folder) else {
            return .refused(.unreadable)
        }
        return .recorded(written.exports ?? [])
    }

    /// What a meeting sends, gathered from its folder. Its M4A is the
    /// folder's own when there is one (read in place), else made from its
    /// video into `staging`.
    static func prepare(_ folder: URL, sidecar: ForkMeetingSidecar, staging: URL) async throws -> ForkMeetingExportPackage {
        let manager = FileManager.default
        let name = folder.lastPathComponent
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { throw ForkMeetingExportFailure.unreadable }
        let contents = ForkMeetingFolder.contents(of: names, folderName: name)
        guard let entry = ForkMeetingLibraryEntry(folderName: name, sidecar: .success(sidecar), contents: contents) else {
            throw ForkMeetingExportFailure.unreadable
        }
        var probe: ForkMeetingProbeCache.Probe?
        if entry.audio == nil, let playable = entry.playable {
            probe = await ForkMeetingLibraryProbes.shared.probe(folder.appendingPathComponent(playable))
        }
        let audio: URL
        switch ForkMeetingAudioExport.route(entry, probe: probe) {
        case .failure(.meetingInProgress):
            throw ForkMeetingExportFailure.inProgress
        case .failure(.noAudio):
            throw ForkMeetingExportFailure.noAudio
        case let .success(.copy(file)):
            audio = folder.appendingPathComponent(file)
        case let .success(route):
            do {
                try manager.createDirectory(at: staging, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: ForkMeetingStore.folderPermissions])
                let made = staging.appendingPathComponent("\(name).\(ForkMeetingFolder.audioExtension)")
                try await ForkMeetingLibraryMedia.exportAudio(route, folder: folder, to: made)
                audio = made
            } catch {
                throw ForkMeetingExportFailure.noAudio
            }
        }
        let transcript = ForkMeetingExportDocument.transcript(in: names, folderName: name).map { folder.appendingPathComponent($0) }
        return ForkMeetingExportPackage(folderName: name, sidecar: sidecar, audio: audio, transcript: transcript)
    }

    // MARK: - Results

    /// Reads the meeting's exports again, for its detail.
    func refreshResults(_ folder: URL) {
        queue.async { [self] in
            guard case let .success(sidecar) = store.sidecar(in: folder) else { return }
            DispatchQueue.main.async { [self] in publish(folder, sidecar.exports ?? []) }
        }
    }

    private func publish(_ folder: URL, _ exports: [ForkMeetingSidecar.Export]) {
        var latest: [String: ForkMeetingExportHistory.Result] = [:]
        for config in configs {
            latest[config.id] = ForkMeetingExportHistory.lastResult(exports, target: config.id)
        }
        results[folder.standardizedFileURL.path] = latest
    }

    func result(_ folder: URL, _ target: String) -> ForkMeetingExportHistory.Result? {
        results[folder.standardizedFileURL.path]?[target]
    }

    // MARK: - Test

    /// The page's "Send a test" for a webhook saved.
    func sendTest(_ id: String) {
        guard let config = config(id), config.kind == .webhook, !testing.contains(id) else { return }
        testing.insert(id)
        tests[id] = nil
        let exporter = webhook(config)
        queue.async { [self] in
            let result: Result<Int, ForkMeetingExportFailure>
            do {
                result = .success(try Self.blocking { try await exporter.sendTest() })
            } catch {
                result = .failure(error as? ForkMeetingExportFailure ?? .network)
            }
            DispatchQueue.main.async { [self] in
                testing.remove(id)
                tests[id] = result
            }
        }
    }

    // MARK: - Waiting on the queue

    private final class Box<Value>: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<Value, Error>?
    }

    /// Runs an async job and waits for it on the export queue: one send at a
    /// time, whatever the job awaits inside.
    static func blocking<Value>(_ job: @escaping () async throws -> Value) throws -> Value {
        let box = Box<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            let result: Result<Value, Error>
            do { result = .success(try await job()) } catch { result = .failure(error) }
            box.lock.withLock { box.result = result }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.lock.withLock { box.result! }.get()
    }
}
