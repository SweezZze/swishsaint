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
///   appends the result to `meeting.json` through the store's queue, found
///   again by its id if its folder moved meanwhile.
/// - A meeting being recorded or finished is never sent, and one that did
///   not end well never on its own (`ForkMeetingExportEligibility`).
/// - **On its own, only what the page wrote**: the Keychain keeps the
///   fingerprint of the list the page saved; a list rewritten elsewhere
///   sends nothing on its own until the page confirms it. Nothing goes on
///   its own with the feature off, and what waited is dropped when it turns
///   off.
/// - An automatic send that fails, or cannot start, is written in the
///   meeting's history with its Retry, and said in a short notice.
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
    /// The list read is not the one the page last wrote: the page asks to
    /// look at it, and nothing goes on its own meanwhile.
    @Published private(set) var listChanged = false

    let defaults: UserDefaults
    let store: ForkMeetingStore
    let keychain: ForkMeetingKeychain
    /// The webhook's view of certificates: the system's, always, in the
    /// app (the recipe harness alone gives its own).
    var trust: ForkWebhookExporter.Trust = .system
    /// The folders this app records or finishes now.
    private let writing: () -> Set<String>
    /// The Meetings feature, read at the moment of each automatic send.
    private let wanted: () -> Bool
    /// An automatic send failed for this meeting: the notice.
    private let failed: (URL) -> Void
    let queue = DispatchQueue(label: "fork.meetings.export", qos: .utility)
    private let log = Logger(subsystem: "fork.meetings", category: "export")
    /// Bumped when the feature turns off: the automatic sends still waiting
    /// on the queue see it and go no further. Under `generationLock`; kept
    /// apart from any instance, so turning the feature off never makes one.
    private static var generationValue = 0
    private static let generationLock = NSLock()
    private static var generation: Int { generationLock.withLock { generationValue } }

    init(defaults: UserDefaults = .standard, store: ForkMeetingStore = .shared,
         keychain: ForkMeetingKeychain = .shared,
         writing: @escaping () -> Set<String> = { ForkMeetingService.shared.writingFolders },
         wanted: @escaping () -> Bool = { ForkMeetingService.isWanted },
         failed: @escaping (URL) -> Void = { ForkMeetingService.shared.exportFailed($0) }) {
        self.defaults = defaults
        self.store = store
        self.keychain = keychain
        self.writing = writing
        self.wanted = wanted
        self.failed = failed
        reload()
    }

    var hasExporters: Bool { !configs.isEmpty }

    /// The exporters ready to send, in their order: the only ones the
    /// library names (§7.1).
    var configured: [ForkMeetingExporterConfig] {
        ForkMeetingExporterList.configured(configs, hasSecret: savedSecrets.contains)
    }

    static func key(_ folder: URL, _ target: String) -> String { folder.standardizedFileURL.path + "\n" + target }

    // MARK: - Registry

    /// The list as stored. No Keychain data is read here: launch reads none.
    func reload() {
        configs = ForkMeetingExporterList.decode(defaults.string(forKey: ForkDefaultsKey.meetingsExporters))
        refreshSecrets()
    }

    /// Only the page writes the list: its fingerprint goes to the Keychain
    /// with it.
    private func store(_ configs: [ForkMeetingExporterConfig]) {
        let stored = ForkMeetingExporterList.encode(configs)
        defaults.set(stored, forKey: ForkDefaultsKey.meetingsExporters)
        self.configs = configs
        saveFingerprint(stored)
        refreshSecrets()
    }

    private func saveFingerprint(_ stored: String) {
        if ForkMeetingExporterList.decode(stored).isEmpty {
            keychain.delete(ForkMeetingKeychain.fingerprintAccount)
            listChanged = false
        } else {
            let saved = keychain.save(Data(ForkMeetingExporterList.fingerprint(stored).utf8),
                                      account: ForkMeetingKeychain.fingerprintAccount)
            listChanged = !saved
        }
    }

    /// Whether the list read is the page's: at the page's display, and
    /// before anything goes on its own.
    @discardableResult
    func verifyList() -> Bool {
        let stored = defaults.string(forKey: ForkDefaultsKey.meetingsExporters)
        let matches: Bool
        if ForkMeetingExporterList.decode(stored).isEmpty {
            matches = true
        } else if case let .found(data) = keychain.read(ForkMeetingKeychain.fingerprintAccount) {
            matches = ForkMeetingExporterList.matches(stored, fingerprint: String(decoding: data, as: UTF8.self))
        } else {
            matches = false
        }
        if configs != ForkMeetingExporterList.decode(stored) { reload() }
        listChanged = !matches
        return matches
    }

    /// The page's "Confirm": the list as it is now becomes the page's.
    func confirmList() {
        reload()
        saveFingerprint(defaults.string(forKey: ForkDefaultsKey.meetingsExporters) ?? "")
    }

    /// At the page's display: the Keychain may have changed behind it.
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

    /// Changes what holds no secret: the mode, the options, the folder.
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

    /// Removes the exporter and its own secret.
    func remove(_ id: String) {
        guard let config = config(id) else { return }
        if let account = config.secretAccount { keychain.delete(account) }
        store(configs.filter { $0.id != id })
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
        if let old = config.origin, old != origin.name, let oldAccount = config.secretAccount, keychain.exists(oldAccount) {
            guard confirmed else { return .confirmHostChange(old: old) }
            keychain.delete(oldAccount)
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
        readiness(config) == nil
    }

    /// What keeps the exporter from sending, as far as the page knows.
    func readiness(_ config: ForkMeetingExporterConfig) -> ForkMeetingExportFailure? {
        config.readiness(hasSecret: savedSecrets.contains)
    }

    // MARK: - Sending

    /// The library's "Export To", and Retry: a click, so a meeting that did
    /// not end well goes too.
    func export(_ folder: URL, to target: String) {
        guard let config = config(target) else { return }
        enqueue(folder, config, automatic: false, failure: nil)
    }

    /// A meeting finalized: every automatic exporter gets it, when it ended
    /// well; one that cannot send (not set up, its origin changed, the list
    /// rewritten elsewhere) gets a failure in the meeting's history, and the
    /// notice. Called by the service after the saved notice, never for a
    /// meeting recovered at launch, and never with the feature off.
    func meetingFinished(_ folder: URL) {
        guard wanted() else { return }
        let automatic = configs.filter { $0.mode == .automatic }
        guard !automatic.isEmpty else { return }
        refreshSecrets()
        let matches = verifyList()
        for config in automatic {
            switch ForkMeetingAutomaticExport.plan(mode: config.mode, featureOn: true, listMatches: matches,
                                                   readiness: readiness(config)) {
            case .none: break
            case .send: enqueue(folder, config, automatic: true, failure: nil)
            case let .fail(failure): enqueue(folder, config, automatic: true, failure: failure)
            }
        }
    }

    /// The feature turned off: what waits to go on its own does not.
    static func featureTurnedOff() {
        generationLock.withLock { generationValue += 1 }
    }

    /// A send of this meeting runs or waits: the library neither renames
    /// nor trashes it meanwhile.
    func isSending(_ folder: URL) -> Bool {
        let prefix = folder.standardizedFileURL.path + "\n"
        return pending.contains { $0.hasPrefix(prefix) }
    }

    /// The folders a send reads now or will, by standardized path.
    var sendingFolders: Set<String> {
        Set(pending.compactMap { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) })
    }

    private func enqueue(_ folder: URL, _ config: ForkMeetingExporterConfig, automatic: Bool,
                         failure: ForkMeetingExportFailure?) {
        let key = Self.key(folder, config.id)
        guard !pending.contains(key) else { return }
        pending.insert(key)
        refusals[key] = nil
        let live = writing().contains(folder.standardizedFileURL.path)
        let exporter = exporter(config)
        let job = Self.generation
        queue.async { [self] in
            let outcome = send(folder, exporter: exporter, live: live, automatic: automatic, failure: failure,
                               generation: job)
            DispatchQueue.main.async { [self] in
                pending.remove(key)
                switch outcome {
                case .skipped: break
                case let .refused(failure): refusals[key] = failure
                case let .recorded(at, exports, didFail):
                    publish(at, exports)
                    if automatic, didFail { failedOnItsOwn(at) }
                }
            }
        }
    }

    /// One notice per meeting, however many of its exporters failed at once.
    private var noticed: Set<String> = []

    private func failedOnItsOwn(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard noticed.insert(path).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.noticed.remove(path) }
        failed(folder)
    }

    enum SendOutcome {
        /// Automatic, and the meeting needs a click, or the feature went
        /// off: nothing written.
        case skipped
        /// Refused before anything began, and not written: the meeting is
        /// being written, or its `meeting.json` cannot be.
        case refused(ForkMeetingExportFailure)
        /// Done or failed, and appended in the folder where the meeting
        /// is now: its exports as written, and whether this one failed.
        case recorded(URL, [ForkMeetingSidecar.Export], failed: Bool)
    }

    /// Export queue. The whole send of one meeting to one exporter.
    /// - `failure`: why an automatic exporter cannot send, written as is.
    /// - `generation`: the feature's, when it was asked.
    func send(_ folder: URL, exporter: ForkMeetingExporter, live: Bool, automatic: Bool,
              failure planned: ForkMeetingExportFailure? = nil, generation job: Int? = nil) -> SendOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        if automatic {
            guard job.map({ $0 == Self.generation }) ?? true, wanted() else {
                log.notice("automatic export dropped: the feature is off")
                return .skipped
            }
        }
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
            .appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            if let planned { throw planned }
            try exporter.check()
            let package = try Self.blocking { try await Self.prepare(folder, sidecar: meeting, staging: staging) }
            let receipt = try Self.blocking { try await exporter.export(package, progress: { _ in }) }
            record = ForkMeetingExportHistory.record(receipt)
            log.notice("exported to \(exporter.kind.rawValue, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        } catch {
            let failure = error as? ForkMeetingExportFailure ?? .writeFailed
            record = ForkMeetingExportHistory.record(failure, target: exporter.id, kind: exporter.kind, at: Date())
            log.error("export to \(exporter.kind.rawValue, privacy: .public) failed: \(failure.code, privacy: .public) \(failure.httpStatus ?? 0, privacy: .public)")
        }
        // Moved in the Finder meanwhile: written where the meeting is now.
        let here = Self.folder(of: meeting.id, near: folder, root: store.root()) ?? folder
        var patch = ForkMeetingSidecarPatch()
        patch.export = record
        guard store.write(patch, in: here), case let .success(written) = store.sidecar(in: here) else {
            return .refused(.unreadable)
        }
        return .recorded(here, written.exports ?? [], failed: record.status == ForkMeetingExportHistory.Status.failed.rawValue)
    }

    /// The meeting's folder: `folder` while its `meeting.json` still has
    /// this id, else the folder of the meetings folder that has it.
    static func folder(of id: UUID?, near folder: URL, root: URL) -> URL? {
        func holds(_ candidate: URL) -> Bool {
            guard let id, case let .success(sidecar) = ForkMeetingSidecar.read(
                at: candidate.appendingPathComponent(ForkMeetingFolder.sidecarName)) else { return false }
            return sidecar.id == id
        }
        if holds(folder) { return folder }
        guard id != nil, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        return names.lazy.filter { !$0.hasPrefix(".") }
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .first(where: holds)
    }

    /// The staged M4As' names in the temporary folder.
    static let stagingPrefix = "fork.meetings.export-"

    /// What a send cut short by a quit left: the webhook's bodies and the
    /// staged M4As in the temporary folder, the drafts in each drop folder.
    /// At launch, on the queue, so never under a send.
    func removeLeftovers() {
        let folders = configs.compactMap { config -> URL? in
            guard config.kind == .dropFolder else { return nil }
            return ForkDropFolderExporter(config: config, libraryRoot: store.root()).destination
        }
        queue.async {
            let manager = FileManager.default
            let temporary = manager.temporaryDirectory
            for name in (try? manager.contentsOfDirectory(atPath: temporary.path)) ?? []
            where (name.hasPrefix(ForkWebhookExporter.bodyPrefix) && name.hasSuffix(".body"))
                || name.hasPrefix(Self.stagingPrefix) {
                try? manager.removeItem(at: temporary.appendingPathComponent(name))
            }
            folders.forEach(ForkDropFolderExporter.removeDrafts)
        }
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
            } catch {
                throw ForkMeetingExportFailure.temporarySpace
            }
            do {
                let made = staging.appendingPathComponent("\(name).\(ForkMeetingFolder.audioExtension)")
                try await ForkMeetingLibraryMedia.exportAudio(route, folder: folder, to: made)
                audio = made
            } catch {
                // The video is there: a staging that fails is this Mac's
                // disk, not the meeting.
                throw Self.isOutOfSpace(error) ? ForkMeetingExportFailure.temporarySpace : ForkMeetingExportFailure.noAudio
            }
        }
        let transcript = ForkMeetingExportDocument.transcript(in: names, folderName: name).map { folder.appendingPathComponent($0) }
        return ForkMeetingExportPackage(folderName: name, sidecar: sidecar, audio: audio, transcript: transcript)
    }

    /// No room left, as Foundation, POSIX or AVFoundation says it.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        // AVFoundation's "disk full" (AVError.diskFull).
        if error.domain == "AVFoundationErrorDomain", error.code == -11807 { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isOutOfSpace) ?? false
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
