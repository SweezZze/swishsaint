// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Foundation

/// The Mac's events a meeting recording answers, gathered in one place and
/// all called back on the main thread: sleep and wake, the screen locked
/// and unlocked, displays changed, the disk running low, the app quitting.
///
/// - **Sleep**: nothing can keep a closed lid on battery awake
///   (`IOPMLib.h:1013-1023`), so the recording pauses at `willSleep` and
///   resumes or stops at `didWake`. Idle sleep, the display's included, is
///   held off while a meeting records, not paused (`hold`): a meeting listened
///   to without touching the Mac would otherwise turn the display off, then
///   lock the session, in a couple of minutes (decision "locked screen").
/// - **Lock**: `com.apple.screenIsLocked` and `…Unlocked`, undocumented but
///   what loginwindow sends (S5) and what the official app listens to. The
///   recording goes on; the machine notes the lock as a gap.
/// - **Displays**: one event per burst of changes (0.5 s), the capture then
///   follows the meeting's window.
/// - **Disk**: read every 15 s off the main thread while a meeting records;
///   a reading that fails says nothing (never a full disk made up).
/// - **Quit**: `willTerminate` is answered synchronously on the main thread,
///   so the handler may wait up to 3 s for the file to close with
///   `ForkMeetingBoundedWait`, provided nothing it waits for needs the main
///   thread.
///
/// `start` and `stop` may be called any number of times; after `stop`
/// nothing is observed, no timer runs, no activity is held, and no event
/// comes any more, a late one included.
final class ForkMeetingSystemEvents {
    enum Event: Equatable {
        case willSleep
        case didWake
        case locked
        case unlocked
        case displaysChanged
        case diskLow(freeBytes: Int64)
        /// Enough room again after `diskLow`.
        case diskEnough(freeBytes: Int64)
        case diskCritical
        /// Synchronous: the app ends right after the handler returns.
        case willTerminate
    }

    static let displaysSettle: TimeInterval = 0.5
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let onEvent: (Event) -> Void
    private let freeBytes: (URL) -> Int64?
    private let diskQueue = DispatchQueue(label: "fork.meetings.disk", qos: .utility)

    // Main thread state.
    private(set) var isRunning = false
    /// The screen is locked, as last said by the system.
    private(set) var isScreenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysWork: DispatchWorkItem?
    private var diskTimer: DispatchSourceTimer?
    /// Names the disk watch allowed to speak: a reading taken before
    /// `endRecording` is dropped when it lands.
    private var diskGeneration = 0
    /// This recording's readings. Disk queue only.
    private var diskWatch = ForkMeetingDiskWatch()
    private var activity: NSObjectProtocol?
    /// What `activity` holds.
    private var held = ForkMeetingServiceSupport.Awake.free

    /// - Parameters:
    ///   - onEvent: main thread, for every event.
    ///   - freeBytes: the free space of a folder's volume, called off the
    ///     main thread; `nil` when it cannot be read.
    init(freeBytes: @escaping (URL) -> Int64? = ForkMeetingStore.freeBytes(at:),
         onEvent: @escaping (Event) -> Void) {
        self.freeBytes = freeBytes
        self.onEvent = onEvent
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        diskTimer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Observing

    /// Main thread. Starts observing sleep, lock, displays and quit. A
    /// screen already locked is said at once, as `.locked`.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }
        isRunning = true

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.send(.willSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.send(.didWake) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Self.lockedNotification) { $0.setLocked(true) }
        observe(distributed, Self.unlockedNotification) { $0.setLocked(false) }

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
            $0.displaysChanged()
        }
        // No queue: called right where AppKit posts it, on the main thread,
        // before the app ends. An operation queue would only run it later.
        let terminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onEvent(.willTerminate)
        }
        observers.append((NotificationCenter.default, terminate))

        isScreenLocked = Self.screenIsLockedNow()
        if isScreenLocked {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.isScreenLocked else { return }
                self.onEvent(.locked)
            }
        }
    }

    /// Main thread. Stops everything, the recording's watch included.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        endRecording()
        guard isRunning else { return }
        isRunning = false
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        displaysWork?.cancel()
        displaysWork = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (ForkMeetingSystemEvents) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            handler(self)
        }
        observers.append((center, token))
    }

    private func send(_ event: Event) {
        guard isRunning else { return }
        onEvent(event)
    }

    /// Once per change: the system may say the same thing twice.
    private func setLocked(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        send(locked ? .locked : .unlocked)
    }

    /// One event per burst: plugging a display posts several changes.
    private func displaysChanged() {
        displaysWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.displaysWork = nil
            self?.send(.displaysChanged)
        }
        displaysWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displaysSettle, execute: work)
    }

    /// What the session says of the lock screen at this moment. The key is
    /// absent when the screen is unlocked (S5).
    static func screenIsLockedNow() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - While a meeting records

    /// Main thread. Reads the free space of `folder`'s volume every 15 s.
    /// Called again, it follows the new folder and quality. How awake the
    /// Mac stays meanwhile is `hold`'s.
    func beginRecording(folder: URL, quality: ForkMeetingQuality) {
        dispatchPrecondition(condition: .onQueue(.main))
        diskTimer?.cancel()
        diskGeneration += 1
        let generation = diskGeneration
        let freeBytes = self.freeBytes
        let timer = DispatchSource.makeTimerSource(queue: diskQueue)
        let interval = ForkMeetingDisk.checkInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        diskQueue.async { [weak self] in self?.diskWatch = ForkMeetingDiskWatch() }
        timer.setEventHandler { [weak self] in
            guard let self, let signal = self.diskWatch.reading(freeBytes: freeBytes(folder), quality: quality) else {
                return
            }
            DispatchQueue.main.async {
                guard self.diskGeneration == generation, self.diskTimer != nil else { return }
                switch signal {
                case let .low(free): self.onEvent(.diskLow(freeBytes: free))
                case let .enough(free): self.onEvent(.diskEnough(freeBytes: free))
                case .critical: self.onEvent(.diskCritical)
                }
            }
        }
        diskTimer = timer
        timer.resume()
    }

    /// Main thread. Lets the Mac sleep again and stops reading the disk.
    func endRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        diskGeneration += 1
        diskTimer?.cancel()
        diskTimer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        held = .free
    }

    var isRecording: Bool { diskTimer != nil }

    /// Main thread. Holds off idle sleep, the display's included, only
    /// while a meeting really records (`ForkMeetingServiceSupport.awake`):
    /// paused by the person, the Mac may turn its display off and lock,
    /// however long the pause.
    func hold(_ awake: ForkMeetingServiceSupport.Awake) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard awake != held else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        held = awake
        let options: ProcessInfo.ActivityOptions
        switch awake {
        case .free: return
        case .app: options = [.userInitiatedAllowingIdleSystemSleep]
        case .display: options = [.userInitiated, .idleDisplaySleepDisabled]
        }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Recording a meeting")
    }

    /// What is held now, for the recipe harness.
    var awake: ForkMeetingServiceSupport.Awake { held }
}
