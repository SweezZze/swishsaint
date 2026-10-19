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
        /// A build to install once the meeting recording or finishing is
        /// saved (installing quits the app): no failure, said as a wait.
        case waitingForMeeting
    }

    @Published private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    let currentBuild = ForkUpdateSupport.currentBuild(info: Bundle.main.infoDictionary)
    let upstreamVersion = ForkUpdateSupport.upstreamVersion(info: Bundle.main.infoDictionary)
    /// nil for a local build: it never updates itself.
    let repository = ForkUpdateSupport.repository(info: Bundle.main.infoDictionary)

    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?
    /// A build met while a meeting records or finishes: offered, or
    /// installed if the person already chose to, once the meeting is safe.
    /// Installing quits the app, which would cut the recording.
    private var afterMeeting: (candidate: ForkUpdateSupport.Candidate, install: Bool)?
    private var meetingObserver: NSObjectProtocol?

    private init() {}

    var releasesPageURL: URL? { repository.map(ForkUpdateSupport.releasesPageURL(repository:)) }

    // MARK: - Checking

    /// At launch, then every few hours: a newer build is offered once.
    func startAutomaticChecks() {
        guard repository != nil, timer == nil else { return }
        noteLaunch()
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
    ///   - offering: true for the automatic checks, which open the update
    ///     window when a build the person has not postponed is out.
    ///   - reporting: true for the official "Check for Updates" command,
    ///     which always answers: with the update window when a build is
    ///     out, even one postponed, in an alert otherwise.
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
        Self.fetchReleases(repository: repository, installed: currentBuild) { [weak self] releases in
            DispatchQueue.main.async {
                guard let self else { return }
                let text = ForkUpdateStrings.current
                guard let releases else {
                    self.state = offering && !reporting ? .idle : .failed(text.checkFailed)
                    if reporting { self.report(text.checkFailed) }
                    return
                }
                guard let candidate = ForkUpdateSupport.newestCandidate(in: releases),
                      ForkUpdateSupport.isNewer(candidate, than: self.currentBuild) else {
                    self.state = .upToDate
                    if reporting { self.report(text.upToDate) }
                    return
                }
                self.remember(ForkUpdateNotes.summary(releases: releases, installed: self.currentBuild,
                                                      candidate: candidate.build,
                                                      installedUpstream: self.upstreamVersion))
                self.state = .available(candidate)
                let postponed = UserDefaults.standard.integer(forKey: ForkDefaultsKey.updatePostponedBuild)
                if reporting || (offering && postponed != candidate.build) {
                    // A window in the middle of a meeting would take the
                    // keyboard from the call: asked once it is over.
                    if reporting {
                        self.offer(candidate, asked: true)
                    } else if ForkMeetingActivity.isBusy {
                        self.waitForMeeting(candidate, install: false)
                    } else {
                        self.offerWhenFree(candidate)
                    }
                }
            }
        }
    }

    /// Off the main thread: the releases since the installed build, newest
    /// first, in one request most of the time; `/releases/latest` alone
    /// when the list cannot be read, as before the update window gathered
    /// notes. nil when GitHub could not be asked at all.
    private static func fetchReleases(repository: String, installed: Int?, page: Int = 1,
                                      found: [ForkUpdateSupport.Release] = [],
                                      completion: @escaping ([ForkUpdateSupport.Release]?) -> Void) {
        get(ForkUpdateSupport.releasesURL(repository: repository, page: page)) { status, data in
            if status == 200, let data,
               let releases = try? JSONDecoder().decode([ForkUpdateSupport.Release].self, from: data) {
                if ForkUpdateSupport.needsNextPage(releases, pageNumber: page, installed: installed) {
                    fetchReleases(repository: repository, installed: installed, page: page + 1,
                                  found: found + releases, completion: completion)
                } else {
                    completion(found + releases)
                }
                return
            }
            // A later page that fails still leaves the newest builds.
            guard page == 1 else {
                completion(found)
                return
            }
            get(ForkUpdateSupport.latestReleaseURL(repository: repository)) { status, data in
                switch status {
                case 200:
                    let release = data.flatMap { try? JSONDecoder().decode(ForkUpdateSupport.Release.self, from: $0) }
                    completion(release.map { [$0] } ?? [])
                case 404:
                    completion([])
                default:
                    completion(nil)
                }
            }
        }
    }

    private static func get(_ url: URL, completion: @escaping (Int, Data?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }.resume()
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = ForkUpdateStrings.current.section
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// From the Settings: the update window again, even for a build
    /// postponed.
    func showNotes(of candidate: ForkUpdateSupport.Candidate) {
        offer(candidate, asked: true)
    }

    /// An offer nobody asked for: after the onboarding, What's New, the
    /// official intros, any alert and the notes of the update just
    /// installed, never on top of them. Dropped if the build was postponed
    /// or replaced in the meantime, or is already on screen.
    private func offerWhenFree(_ candidate: ForkUpdateSupport.Candidate) {
        guard !ForkUpdateNotesWindow.shared.isShowing(build: candidate.build, mode: .available) else { return }
        presentWhenFree("offer") { [weak self] in
            guard let self, self.state == .available(candidate),
                  UserDefaults.standard.integer(forKey: ForkDefaultsKey.updatePostponedBuild) != candidate.build
            else { return }
            self.offer(candidate)
        }
    }

    /// The window with the notes of every build since the installed one.
    /// "Later" (or closing it) postpones this build until a newer one is
    /// out; installing from it counts its notes as read, so they are not
    /// shown again after the relaunch.
    private func offer(_ candidate: ForkUpdateSupport.Candidate, asked: Bool = false) {
        ForkUpdateNotesWindow.shared.show(
            notes(for: candidate), mode: .available, bringForward: asked,
            onInstall: { [weak self] in
                UserDefaults.standard.set(candidate.build, forKey: ForkDefaultsKey.updateNotesSeenBuild)
                self?.install(candidate)
            },
            onDismiss: {
                UserDefaults.standard.set(candidate.build, forKey: ForkDefaultsKey.updatePostponedBuild)
            })
    }

    // MARK: - Notes

    /// The notes of the build on offer, gathered by the last check.
    private(set) var offeredNotes: ForkUpdateNotes.Summary?

    /// Kept on this Mac too: the window after the relaunch shows them again
    /// without asking GitHub.
    private func remember(_ notes: ForkUpdateNotes.Summary) {
        offeredNotes = notes
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: ForkDefaultsKey.updateNotesCache)
        }
    }

    private func notes(for candidate: ForkUpdateSupport.Candidate) -> ForkUpdateNotes.Summary {
        if let offeredNotes, offeredNotes.build == candidate.build { return offeredNotes }
        return ForkUpdateNotes.Summary(build: candidate.build, upstream: nil, upstreamChanged: false, authors: [],
                                       other: ForkUpdateNotes.fallbackItems(in: candidate.notes), includedBuilds: 1)
    }

    // MARK: - After an update

    /// The build the app ran before this one, while the notes of the update
    /// just installed wait to be shown.
    private var installedSince: Int?

    /// At launch: a build newer than the one that ran last on this Mac is
    /// an update just installed. Its notes are shown once, unless they were
    /// read in the update window before installing. The build counts as
    /// run only once that is done, so a quit before still shows them.
    private func noteLaunch() {
        let defaults = UserDefaults.standard
        guard let current = currentBuild else { return }
        let last = defaults.object(forKey: ForkDefaultsKey.updateLastRunBuild) as? Int
        guard let last, current > last,
              defaults.integer(forKey: ForkDefaultsKey.updateNotesSeenBuild) < current else {
            defaults.set(current, forKey: ForkDefaultsKey.updateLastRunBuild)
            return
        }
        installedSince = last
        // After the official launch windows have had their turn to open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.showInstalledNotesWhenFree()
        }
    }

    /// Main thread. Waits for the onboarding, the official What's New and
    /// update intros, any alert and a meeting: one window at a time.
    private func showInstalledNotesWhenFree() {
        guard let since = installedSince, let current = currentBuild, let repository else { return }
        installedSince = nil
        presentWhenFree("installed") { [weak self] in
            guard let self else { return }
            if let data = UserDefaults.standard.data(forKey: ForkDefaultsKey.updateNotesCache),
               let cached = try? JSONDecoder().decode(ForkUpdateNotes.Summary.self, from: data),
               cached.build == current {
                self.showInstalled(cached)
                return
            }
            Self.fetchReleases(repository: repository, installed: since) { [weak self] releases in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Offline: tried again at the next launch.
                    guard let releases else { return }
                    self.showInstalled(ForkUpdateNotes.summary(releases: releases, installed: since,
                                                               candidate: current,
                                                               installedUpstream: self.upstreamVersion))
                }
            }
        }
    }

    private func showInstalled(_ notes: ForkUpdateNotes.Summary) {
        let build = notes.build
        let markSeen = {
            UserDefaults.standard.set(build, forKey: ForkDefaultsKey.updateLastRunBuild)
            UserDefaults.standard.set(build, forKey: ForkDefaultsKey.updateNotesSeenBuild)
        }
        // Nothing an author wrote: the official window says the rest.
        guard notes.hasNotes else {
            markSeen()
            return
        }
        // An offer opened while the notes were fetched: they come after it.
        guard Self.launchWindowsAreDone else {
            presentWhenFree("installed") { [weak self] in self?.showInstalled(notes) }
            return
        }
        ForkUpdateNotesWindow.shared.show(notes, mode: .installed, onDismiss: markSeen)
    }

    // MARK: - One window at a time

    /// What waits to open on its own, first come first shown: the notes of
    /// the update just installed, an offer. One entry per kind, the latest.
    private var waitingToPresent: [(kind: String, present: () -> Void)] = []
    private var launchWindowObservers: [NSObjectProtocol] = []
    private var launchWindowRecheck = false

    private func presentWhenFree(_ kind: String, _ present: @escaping () -> Void) {
        if let index = waitingToPresent.firstIndex(where: { $0.kind == kind }) {
            waitingToPresent[index].present = present
        } else {
            waitingToPresent.append((kind, present))
        }
        presentNextIfFree()
    }

    private func presentNextIfFree() {
        guard !waitingToPresent.isEmpty else {
            stopWaitingForLaunchWindows()
            return
        }
        guard Self.launchWindowsAreDone else {
            waitForLaunchWindows()
            return
        }
        let next = waitingToPresent.removeFirst()
        next.present()
        if waitingToPresent.isEmpty {
            stopWaitingForLaunchWindows()
        } else {
            waitForLaunchWindows()
        }
    }

    /// Nothing else is asking for the person's attention: the onboarding,
    /// What's New and the official update intros are done, no alert is up,
    /// no meeting records, and no update window is open.
    private static var launchWindowsAreDone: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.hasOnboarded),
              defaults.string(forKey: DefaultsKey.whatsNewPendingVersion) == nil,
              NSApp.modalWindow == nil,
              !ForkMeetingActivity.isBusy,
              !ForkUpdateNotesWindow.shared.isOpen
        else { return false }
        return !ForkUpdateNotesWindow.officialIntroIsOpen
    }

    /// Looks again whenever one of those may have ended. A closing window
    /// is given a moment, so the official window that follows it opens first.
    private func waitForLaunchWindows() {
        guard launchWindowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let recheck: (Notification) -> Void = { [weak self] notification in
            guard let self, !self.launchWindowRecheck else { return }
            self.launchWindowRecheck = true
            let delay: TimeInterval = notification.name == NSWindow.willCloseNotification ? 0.6 : 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.launchWindowRecheck = false
                self?.presentNextIfFree()
            }
        }
        launchWindowObservers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main, using: recheck),
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: recheck),
            center.addObserver(forName: ForkMeetingActivity.didBecomeIdle, object: nil, queue: .main, using: recheck),
        ]
    }

    private func stopWaitingForLaunchWindows() {
        launchWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        launchWindowObservers = []
    }

    // MARK: - Installing

    func install(_ candidate: ForkUpdateSupport.Candidate) {
        guard repository != nil else { return }
        // The Settings button and the window's can both be clicked: one
        // download at a time.
        switch state {
        case .downloading, .installing: return
        default: break
        }
        // Its question is answered, wherever it was.
        ForkUpdateNotesWindow.shared.closeForInstall()
        guard !ForkMeetingActivity.isBusy else {
            waitForMeeting(candidate, install: true)
            return
        }
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
                    // A meeting may have started during the download.
                    guard !ForkMeetingActivity.isBusy else {
                        try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent())
                        self.waitForMeeting(candidate, install: true)
                        return
                    }
                    self.state = .installing
                    self.replaceRunningApp(with: newApp)
                case .failure(let error):
                    self.state = .failed(error.message)
                }
            }
        }.resume()
    }

    // MARK: - After the meeting

    /// Main thread. Keeps the build for when the meeting is safe: recorded,
    /// and its final pass done. An install asked for is never downgraded to
    /// an offer by a later check.
    private func waitForMeeting(_ candidate: ForkUpdateSupport.Candidate, install: Bool) {
        let installs = install || afterMeeting?.install == true
        afterMeeting = (candidate, installs)
        state = installs ? .waitingForMeeting : .available(candidate)
        if meetingObserver == nil {
            meetingObserver = NotificationCenter.default.addObserver(
                forName: ForkMeetingActivity.didBecomeIdle, object: nil, queue: .main
            ) { [weak self] _ in
                self?.meetingEnded()
            }
        }
        // The meeting may have ended between the check and the observer.
        DispatchQueue.main.async { [weak self] in self?.meetingEnded() }
    }

    private func meetingEnded() {
        guard !ForkMeetingActivity.isBusy, let pending = afterMeeting else { return }
        afterMeeting = nil
        if let meetingObserver {
            NotificationCenter.default.removeObserver(meetingObserver)
            self.meetingObserver = nil
        }
        if pending.install {
            install(pending.candidate)
        } else if UserDefaults.standard.integer(forKey: ForkDefaultsKey.updatePostponedBuild) != pending.candidate.build {
            offerWhenFree(pending.candidate)
        }
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
