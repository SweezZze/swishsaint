// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import Combine
import Security

/// The fork's entry point into the official updater (seam `update`): the
/// official one is never allowed to run, or it would offer Vorssaint's own
/// releases and replace this app, features and all, with the official one.
enum ForkUpdate {
    /// Called first thing by the official `startAutomaticChecks()` and
    /// `check(manual:)`. Always takes over; starts or runs the fork's
    /// updater instead.
    static func takesOver(manual: Bool? = nil) -> Bool {
        switch manual {
        case nil: ForkUpdateService.shared.startAutomaticChecks()
        case false?: ForkUpdateService.shared.checkIfStale()
        case true?: ForkUpdateService.shared.check(reporting: true)
        }
        return true
    }
}

/// Finds, downloads and installs a newer build of the fork's app. See
/// `ForkUpdateSupport`.
///
/// A download replaces the running app only when it passes three checks:
/// its zip matches the SHA-256 published with it, it is the same app (same
/// bundle identifier), and its signature satisfies the running app's own
/// designated requirement, so only a build signed with the fork's
/// certificate can ever take its place. Keeping that signature is also what
/// lets macOS keep the Accessibility grant across updates.
final class ForkUpdateService: ObservableObject {
    static let shared = ForkUpdateService()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ForkUpdateSupport.Candidate)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    let currentBuild = ForkUpdateSupport.currentBuild(info: Bundle.main.infoDictionary)
    let upstreamVersion = ForkUpdateSupport.upstreamVersion(info: Bundle.main.infoDictionary)
    /// nil for a local build: it never updates itself.
    let repository = ForkUpdateSupport.repository(info: Bundle.main.infoDictionary)

    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    private init() {}

    var releasesPageURL: URL? { repository.map(ForkUpdateSupport.releasesPageURL(repository:)) }

    // MARK: - Checking

    /// At launch, then every few hours: a newer build is offered once.
    func startAutomaticChecks() {
        guard repository != nil, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.check(offering: true)
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(offering: true)
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// When the app comes forward or its panel opens, at most once an hour:
    /// the GitHub API allows 60 unauthenticated requests an hour.
    func checkIfStale() {
        guard repository != nil else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 60 * 60 { return }
        check(offering: true)
    }

    /// - Parameters:
    ///   - offering: true for the automatic checks, which ask in an alert
    ///     when a build the person has not postponed is out.
    ///   - reporting: true for the official "Check for Updates" command,
    ///     which always answers in an alert.
    func check(offering: Bool = false, reporting: Bool = false) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        guard let repository else {
            state = .failed(ForkUpdateStrings.current.localBuild)
            if reporting { report(ForkUpdateStrings.current.localBuild) }
            return
        }
        state = .checking
        lastChecked = Date()
        var request = URLRequest(url: ForkUpdateSupport.latestReleaseURL(repository: repository))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let candidate = (status == 200 ? data : nil)
                .flatMap { try? JSONDecoder().decode(ForkUpdateSupport.Release.self, from: $0) }
                .flatMap(ForkUpdateSupport.candidate(from:))
            DispatchQueue.main.async {
                guard let self else { return }
                let text = ForkUpdateStrings.current
                guard status == 200 || status == 404 else {
                    self.state = offering && !reporting ? .idle : .failed(text.checkFailed)
                    if reporting { self.report(text.checkFailed) }
                    return
                }
                guard let candidate, ForkUpdateSupport.isNewer(candidate, than: self.currentBuild) else {
                    self.state = .upToDate
                    if reporting { self.report(text.upToDate) }
                    return
                }
                self.state = .available(candidate)
                let postponed = UserDefaults.standard.integer(forKey: ForkDefaultsKey.updatePostponedBuild)
                if reporting || (offering && postponed != candidate.build) {
                    self.offer(candidate)
                }
            }
        }.resume()
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = ForkUpdateStrings.current.section
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func offer(_ candidate: ForkUpdateSupport.Candidate) {
        let text = ForkUpdateStrings.current
        let alert = NSAlert()
        alert.messageText = text.availableTitle
        alert.informativeText = candidate.notes.isEmpty
            ? text.availableBody
            : text.availableBody + "\n\n" + candidate.notes
        alert.addButton(withTitle: text.install)
        alert.addButton(withTitle: text.later)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            install(candidate)
        } else {
            UserDefaults.standard.set(candidate.build, forKey: ForkDefaultsKey.updatePostponedBuild)
        }
    }

    // MARK: - Installing

    func install(_ candidate: ForkUpdateSupport.Candidate) {
        guard repository != nil else { return }
        state = .downloading
        URLSession.shared.downloadTask(with: candidate.zipURL) { [weak self] location, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<URL, InstallError>
            if status == 200, let location {
                result = Self.prepare(downloadedZip: location, candidate: candidate)
            } else {
                result = .failure(.download)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let newApp):
                    self.state = .installing
                    self.replaceRunningApp(with: newApp)
                case .failure(let error):
                    self.state = .failed(error.message)
                }
            }
        }.resume()
    }

    enum InstallError: Error {
        case download, checksum, unpack, notThisApp, signature, location

        var message: String {
            let text = ForkUpdateStrings.current
            switch self {
            case .download: return text.downloadFailed
            case .checksum, .unpack: return text.damaged
            case .notThisApp, .signature: return text.untrusted
            case .location: return text.cannotReplace
            }
        }
    }

    /// Off the main thread: checks the zip, unpacks it and checks the app
    /// inside. Returns the app ready to move into place.
    private static func prepare(downloadedZip: URL,
                                candidate: ForkUpdateSupport.Candidate) -> Result<URL, InstallError> {
        guard let data = try? Data(contentsOf: downloadedZip),
              UpdateServiceSupport.sha256Matches(data, expectedHex: candidate.sha256)
        else { return .failure(.checksum) }

        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("fork-update-\(candidate.build)-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", downloadedZip.path, work.path]
        do { try unzip.run() } catch { return .failure(.unpack) }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let found = try? fileManager.contentsOfDirectory(at: work, includingPropertiesForKeys: nil),
              let newApp = found.first(where: { $0.pathExtension == "app" })
        else { return .failure(.unpack) }

        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return .failure(.notThisApp)
        }
        guard isSignedLikeThisApp(newApp) else { return .failure(.signature) }
        return .success(newApp)
    }

    /// Whether `app` satisfies the running app's designated requirement:
    /// same identifier, signed by the same certificate.
    static func isSignedLikeThisApp(_ app: URL) -> Bool {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var downloaded: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &downloaded) == errSecSuccess,
              let downloaded
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(downloaded, flags, requirement) == errSecSuccess
    }

    /// Quits, and lets a small script swap the bundles once this process is
    /// gone, then open the new one. The old bundle is kept until the new one
    /// is in place, and put back if the move fails.
    private func replaceRunningApp(with newApp: URL) {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed(InstallError.location.message)
            return
        }
        let script = """
        PID=\(ProcessInfo.processInfo.processIdentifier)
        NEW=\(Self.quoted(newApp.path))
        DEST=\(Self.quoted(destination.path))
        BACKUP="$DEST.update-old.$$"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        /usr/bin/xattr -cr "$NEW" 2>/dev/null
        if /bin/mv "$DEST" "$BACKUP" && /bin/mv "$NEW" "$DEST"; then
            /bin/rm -rf "$BACKUP"
        elif [ -d "$BACKUP" ] && [ ! -d "$DEST" ]; then
            /bin/mv "$BACKUP" "$DEST"
        fi
        /usr/bin/open "$DEST"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            state = .failed(InstallError.location.message)
            return
        }
        NSApp.terminate(nil)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
