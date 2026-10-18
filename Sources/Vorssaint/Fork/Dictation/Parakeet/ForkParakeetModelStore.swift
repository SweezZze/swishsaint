// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Combine
import Darwin
import Foundation

enum ForkParakeetStoreError: Error, Equatable {
    /// The connection failed or Hugging Face answered with an error. What
    /// was downloaded is kept for the next attempt.
    case network
    /// Not enough free space to start: `needed` bytes are required.
    case diskFull(needed: Int64)
    /// A downloaded file is not the file of the pinned revision. It is
    /// deleted, the next attempt downloads it again.
    case checksum(file: String)
    case cancelled
    /// The model folder could not be created, written or moved.
    case io
}

/// Installs, checks and removes the Parakeet model the dictation runs on
/// this Mac. See `ForkParakeetManifest` for the files.
///
/// Nothing is ever downloaded without `install()`: the person asks for it on
/// the Dictation page. An install first looks at FluidAudio's cache, where
/// apps built on FluidAudio keep the same model: when every file there is the
/// pinned one, they are cloned (APFS copy-on-write, no byte downloaded and
/// none written twice). Otherwise each file is downloaded from Hugging Face
/// into a `.partial` folder, resumed with a `Range` request after a cut or a
/// cancel, checked against its SHA-256, and the folder is renamed into place
/// only once complete, so the model folder is either absent or whole.
///
/// The model belongs to this Mac: no setting records it, the settings backup
/// never carries it, and a restore on another Mac shows it as not installed.
final class ForkParakeetModelStore: ObservableObject {
    typealias Manifest = ForkParakeetManifest

    static let shared = ForkParakeetModelStore()

    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double, received: Int64, total: Int64)
        /// Checking checksums: a cache before cloning it, or a large file
        /// right after its download.
        case verifying
        case installed(size: Int64)
        case failed(ForkParakeetStoreError)
    }

    @Published private(set) var state: State = .notInstalled
    /// What an interrupted download left for the next `install()`.
    @Published private(set) var resumableBytes: Int64 = 0

    /// `<container>/Models`, nil outside a real bundle.
    let modelsDirectory: URL?
    let fluidAudioCache: URL?
    let files: [Manifest.File]

    /// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`.
    static var defaultFluidAudioCache: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(Manifest.folderName, isDirectory: true)
    }

    private let work = DispatchQueue(label: "fork.dictation.parakeet-store", qos: .utility)
    private let lock = NSLock()
    /// Bumped by `install()`, `cancel()` and `delete()`: work started for an
    /// older token finishes without touching the state. Read off the main
    /// thread, hence the lock.
    private var token = 0
    private var download: ForkParakeetDownload?
    private var busy = false

    private convenience init() {
        self.init(modelsDirectory: PrivateFileStore.containerURL?.appendingPathComponent("Models", isDirectory: true),
                  fluidAudioCache: Self.defaultFluidAudioCache)
    }

    init(modelsDirectory: URL?, fluidAudioCache: URL?, files: [Manifest.File] = Manifest.files) {
        self.modelsDirectory = modelsDirectory
        self.fluidAudioCache = fluidAudioCache
        self.files = files
        refresh()
    }

    /// The complete model folder.
    var directory: URL? {
        modelsDirectory?.appendingPathComponent(Manifest.folderName, isDirectory: true)
    }

    /// The folder a download fills before it is renamed into `directory`.
    var stagingDirectory: URL? {
        modelsDirectory?.appendingPathComponent(Manifest.folderName + ".partial", isDirectory: true)
    }

    /// The folder to load the models from, nil until installed.
    var installedDirectory: URL? {
        if case .installed = state { return directory }
        return nil
    }

    var isBusy: Bool { busy }

    var totalBytes: Int64 { Manifest.totalBytes(of: files) }

    /// Whether FluidAudio's cache holds every file at the right size, so an
    /// install will most likely download nothing. Sizes only: cheap enough
    /// for the settings page.
    var canCloneFromFluidAudioCache: Bool {
        guard let fluidAudioCache else { return false }
        return Manifest.missing(files, in: fluidAudioCache, checksum: false).isEmpty
    }

    // MARK: - State

    /// Reads the state from the disk: installed when every file is present
    /// at its size. Checksums are verified when a file arrives, not here, so
    /// this stays a few `stat` calls, fine at launch and when the page opens.
    func refresh() {
        guard !busy else { return }
        resumableBytes = stagedBytes()
        if let directory, Manifest.missing(files, in: directory, checksum: false).isEmpty {
            state = .installed(size: totalBytes)
        } else if case .failed = state {
            // Keep the last failure on screen until the next attempt.
        } else {
            state = .notInstalled
        }
    }

    private func stagedBytes() -> Int64 {
        guard let staging = stagingDirectory else { return 0 }
        return files.reduce(0) { sum, file in
            let size = Manifest.location(of: file, in: staging).flatMap(Manifest.sizeOfFile(at:)) ?? 0
            return sum + min(size, file.size)
        }
    }

    // MARK: - Installing

    func install() {
        guard !busy else { return }
        if case .installed = state { return }
        guard let modelsDirectory, let directory, let staging = stagingDirectory else {
            state = .failed(.io)
            return
        }
        let current = nextToken()
        busy = true
        state = .verifying
        let files = self.files
        let cache = fluidAudioCache
        work.async { [weak self] in
            guard let self else { return }
            guard PrivateFileStore.createDirectory(at: modelsDirectory) else {
                return self.finish(current, .failure(.io))
            }
            if let cache, Manifest.missing(files, in: cache, checksum: false).isEmpty,
               Manifest.missing(files, in: cache, checksum: true).isEmpty,
               self.isCurrent(current),
               Self.clone(files, from: cache, into: staging) {
                // Cancelled while cloning: the clone goes, nothing is installed.
                guard self.isCurrent(current) else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                return self.finish(current, Self.promote(staging, to: directory))
            }
            guard self.isCurrent(current) else { return }

            let remaining = files.reduce(Int64(0)) { sum, file in
                let staged = Manifest.location(of: file, in: staging).flatMap(Manifest.sizeOfFile(at:)) ?? 0
                return sum + max(0, file.size - min(staged, file.size))
            }
            let needed = Manifest.requiredFreeBytes(toDownload: remaining)
            if let available = Self.availableBytes(near: modelsDirectory), available < needed {
                return self.finish(current, .failure(.diskFull(needed: needed)))
            }
            DispatchQueue.main.async { [weak self] in
                self?.startDownload(current, files: files, staging: staging, directory: directory)
            }
        }
    }

    private func startDownload(_ current: Int, files: [Manifest.File], staging: URL, directory: URL) {
        guard isCurrent(current) else { return }
        let total = Manifest.totalBytes(of: files)
        state = .downloading(progress: 0, received: 0, total: total)
        let download = ForkParakeetDownload(files: files, staging: staging, report: { [weak self] phase in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(current) else { return }
                switch phase {
                case .received(let received):
                    let progress = total > 0 ? min(1, Double(received) / Double(total)) : 0
                    self.state = .downloading(progress: progress, received: received, total: total)
                case .verifying:
                    self.state = .verifying
                }
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // On `work`, like `delete`: a model deleted as its last file
                // arrives is never put back.
                self.work.async {
                    guard self.isCurrent(current) else { return }
                    self.finish(current, Self.promote(staging, to: directory))
                }
            case .failure(let error):
                self.finish(current, .failure(error))
            }
        })
        self.download = download
        download.start()
    }

    /// Stops a download and keeps what it fetched; the next `install()`
    /// resumes it. The state goes back to not installed, not to an error.
    func cancel() {
        guard busy else { return }
        _ = nextToken()
        download?.cancel()
        download = nil
        busy = false
        state = .notInstalled
        resumableBytes = stagedBytes()
    }

    /// Removes the model and any partial download.
    func delete() {
        delete(then: nil)
    }

    /// Removes the model, then downloads it again: for a model whose files
    /// no longer load.
    func reinstall() {
        delete { [weak self] in self?.install() }
    }

    private func delete(then next: (() -> Void)?) {
        _ = nextToken()
        download?.cancel()
        download = nil
        busy = true
        let targets = [directory, stagingDirectory].compactMap { $0 }
        work.async { [weak self] in
            for target in targets { try? FileManager.default.removeItem(at: target) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.state = .notInstalled
                self.refresh()
                next?()
            }
        }
    }

    private func finish(_ current: Int, _ result: Result<Void, ForkParakeetStoreError>) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            self.download = nil
            self.busy = false
            switch result {
            case .success:
                self.state = .installed(size: self.totalBytes)
                self.resumableBytes = 0
            case .failure(.cancelled):
                self.state = .notInstalled
                self.resumableBytes = self.stagedBytes()
            case .failure(let error):
                self.state = .failed(error)
                self.resumableBytes = self.stagedBytes()
            }
        }
    }

    private func nextToken() -> Int {
        lock.lock()
        defer { lock.unlock() }
        token += 1
        return token
    }

    private func isCurrent(_ candidate: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == candidate
    }

    // MARK: - Disk

    /// Clones each file of `cache` into `staging`. `COPYFILE_CLONE` makes an
    /// APFS copy-on-write clone and falls back to a plain copy elsewhere.
    private static func clone(_ files: [Manifest.File], from cache: URL, into staging: URL) -> Bool {
        let manager = FileManager.default
        for file in files {
            guard let source = Manifest.location(of: file, in: cache),
                  let target = Manifest.location(of: file, in: staging),
                  (try? manager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)) != nil
            else { return false }
            try? manager.removeItem(at: target)
            guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0,
                  Manifest.sizeOfFile(at: target) == file.size
            else { return false }
        }
        return true
    }

    /// Renames the complete `staging` folder into `directory`, replacing an
    /// older one, and makes it owner-only like the rest of the container.
    private static func promote(_ staging: URL, to directory: URL) -> Result<Void, ForkParakeetStoreError> {
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        guard (try? manager.moveItem(at: staging, to: directory)) != nil else { return .failure(.io) }
        PrivateFileStore.createDirectory(at: directory)
        return .success(())
    }

    /// Free space on the volume holding `url` (or its nearest existing
    /// parent), as macOS counts it for a download the person asked for.
    private static func availableBytes(near url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Downloads the files of a manifest one after the other into a staging
/// folder. Every callback runs on one serial queue, which owns all the
/// mutable state below; `cancel()` only sets a flag and queues the cancel.
private final class ForkParakeetDownload: NSObject, URLSessionDataDelegate {
    typealias Manifest = ForkParakeetManifest

    enum Phase {
        case received(Int64)
        case verifying
    }

    private let files: [Manifest.File]
    private let staging: URL
    private let report: (Phase) -> Void
    private let completion: (Result<Void, ForkParakeetStoreError>) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var session: URLSession?

    private let lock = NSLock()
    private var cancelled = false

    private var index = 0
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    /// Bytes of the current file on disk.
    private var offset: Int64 = 0
    /// Bytes of the files already complete.
    private var completedBytes: Int64 = 0
    private var failure: ForkParakeetStoreError?
    private var finished = false
    private var lastReport = Date.distantPast

    init(files: [Manifest.File], staging: URL,
         report: @escaping (Phase) -> Void,
         completion: @escaping (Result<Void, ForkParakeetStoreError>) -> Void) {
        self.files = files
        self.staging = staging
        self.report = report
        self.completion = completion
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Developer"
        configuration.httpAdditionalHeaders = ["User-Agent": "Vorssaint/\(version)"]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        queue.addOperation { [self] in next() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.addOperation { [self] in task?.cancel() }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Files

    private func next() {
        guard !finished else { return }
        if isCancelled { return finish(.failure(.cancelled)) }
        guard index < files.count else { return finish(.success(())) }
        let file = files[index]
        guard let target = Manifest.location(of: file, in: staging),
              let url = Manifest.downloadURL(for: file),
              let session
        else { return finish(.failure(.io)) }
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)) != nil
        else { return finish(.failure(.io)) }

        var existing = Manifest.sizeOfFile(at: target) ?? 0
        if existing == file.size {
            if file.size > Self.verifyingThreshold { report(.verifying) }
            if Manifest.sha256Hex(ofFileAt: target) == file.sha256.lowercased() {
                completedBytes += file.size
                index += 1
                return next()
            }
            existing = 0
        }
        if existing == 0 || existing > file.size {
            try? manager.removeItem(at: target)
            existing = 0
            guard manager.createFile(atPath: target.path, contents: nil) else { return finish(.failure(.io)) }
        }
        guard let handle = try? FileHandle(forWritingTo: target),
              (try? handle.seekToEnd()) != nil
        else { return finish(.failure(.io)) }
        self.handle = handle
        offset = existing
        failure = nil
        report(.received(completedBytes + offset))

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    /// Files above this size show "verifying" while their checksum runs.
    private static let verifyingThreshold: Int64 = 16 << 20

    private func finish(_ result: Result<Void, ForkParakeetStoreError>) {
        guard !finished else { return }
        finished = true
        try? handle?.close()
        handle = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 206, offset > 0,
           let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
           range.hasPrefix("bytes \(offset)-") {
            completionHandler(.allow)
        } else if status == 200 {
            // The server sent the whole file: start it over.
            guard (try? handle?.truncate(atOffset: 0)) != nil else {
                failure = .io
                return completionHandler(.cancel)
            }
            offset = 0
            completionHandler(.allow)
        } else {
            if status == 416 { try? handle?.truncate(atOffset: 0) }
            failure = .network
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !isCancelled, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .io
            dataTask.cancel()
            return
        }
        offset += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.1 {
            lastReport = now
            report(.received(completedBytes + offset))
        }
    }

    /// Hugging Face redirects large files to its CDN: the `Range` of a
    /// resumed download has to follow the redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        try? handle?.close()
        handle = nil
        self.task = nil
        if isCancelled { return finish(.failure(.cancelled)) }
        if let failure { return finish(.failure(failure)) }
        let file = files[index]
        guard error == nil, offset == file.size else {
            if offset > file.size, let target = Manifest.location(of: file, in: staging) {
                try? FileManager.default.removeItem(at: target)
            }
            return finish(.failure(.network))
        }
        guard let target = Manifest.location(of: file, in: staging) else { return finish(.failure(.io)) }
        if file.size > Self.verifyingThreshold { report(.verifying) }
        guard Manifest.sha256Hex(ofFileAt: target) == file.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: target)
            return finish(.failure(.checksum(file: file.path)))
        }
        completedBytes += file.size
        index += 1
        next()
    }
}
