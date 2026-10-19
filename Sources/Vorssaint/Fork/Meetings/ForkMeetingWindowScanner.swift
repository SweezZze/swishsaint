// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import CoreGraphics

/// Reads the titles of the meeting providers' windows every 3 s, on every
/// Space, minimized and hidden ones included (`.optionAll`): a meeting is
/// never asked to be in front.
///
/// Only while the feature runs, and only while Screen Recording is allowed:
/// without it macOS gives every other app's title empty, so there is nothing
/// to read (the microphone of the meeting apps still counts, PR 3). The
/// permission is asked of macOS once a minute at most.
///
/// The list is cut down before any title is read: layer 0, another process
/// than ours, an app the provider table knows (a browser, or one of its web
/// apps, whose bundle `com.google.Chrome.app.<id>` is reported as is: the
/// resolver brings it back to its browser).
///
/// Utility serial queue; each reading is handed to the main thread, even an
/// unchanged one: the resolver counts readings. The permission gone, an
/// empty reading says so once (`titlesUnreadable`): the meetings it showed
/// end, and their offer goes.
final class ForkMeetingWindowScanner {
    static let interval: TimeInterval = 3
    /// How long the Screen Recording answer is trusted.
    static let permissionLifetime: TimeInterval = 60

    /// What the readings cost, for the logs and the recipe.
    struct Cost: Equatable {
        var readings = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0
        /// Windows in the last list, and those kept.
        var listed = 0
        var kept = 0

        var meanMilliseconds: Double { readings == 0 ? 0 : totalMilliseconds / Double(readings) }
    }

    private let queue = DispatchQueue(label: "fork.meetings.windows", qos: .utility)
    private let table: ForkMeetingProviderTable
    private let ownPID: pid_t
    private let onReading: (_ windows: [ForkMeetingWindowSignal], _ titlesUnreadable: Bool) -> Void

    // Queue only.
    private var timer: DispatchSourceTimer?
    private var allowed = false
    private var allowedReadAt: TimeInterval?
    /// Each window owner's bundle (`nil`: not an app), for the processes of
    /// the last list.
    private var bundles: [pid_t: String?] = [:]
    /// The empty reading that says the titles went has been handed over.
    private var saidBlind = false

    private let lock = NSLock()
    private var cost = Cost()

    /// `onReading` runs on the main thread.
    init(table: ForkMeetingProviderTable = .current, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         onReading: @escaping (_ windows: [ForkMeetingWindowSignal], _ titlesUnreadable: Bool) -> Void) {
        self.table = table
        self.ownPID = ownPID
        self.onReading = onReading
    }

    deinit {
        timer?.cancel()
    }

    /// Reads now, then every 3 s.
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(300))
            source.setEventHandler { [weak self] in self?.read() }
            timer = source
            source.resume()
        }
    }

    /// Nothing is read any more; what was learned is forgotten.
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            bundles = [:]
            allowedReadAt = nil
            saidBlind = false
        }
    }

    /// Screen Recording may have changed: asked again at the next reading.
    func permissionChanged() {
        queue.async { [self] in allowedReadAt = nil }
    }

    var measuredCost: Cost { lock.withLock { cost } }

    // MARK: - Reading

    private func screenRecordingAllowed() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let readAt = allowedReadAt, now - readAt < Self.permissionLifetime { return allowed }
        allowed = CGPreflightScreenCaptureAccess()
        allowedReadAt = now
        return allowed
    }

    private func read() {
        guard screenRecordingAllowed() else {
            // The titles went: said once, then nothing is read.
            if !saidBlind {
                saidBlind = true
                bundles = [:]
                deliver([], titlesUnreadable: true)
            }
            return
        }
        saidBlind = false
        let began = DispatchTime.now().uptimeNanoseconds
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) else {
            deliver([])
            return
        }
        // Left as Foundation objects: only the windows kept are looked into.
        let windows = list as NSArray
        var signals: [ForkMeetingWindowSignal] = []
        var seen = Set<pid_t>()
        for case let info as NSDictionary in windows {
            guard (info[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let owner = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value, owner != ownPID else { continue }
            seen.insert(owner)
            guard let bundle = bundle(of: owner), table.watchesWindows(of: bundle),
                  let title = info[kCGWindowName] as? String, !title.isEmpty,
                  let number = (info[kCGWindowNumber] as? NSNumber)?.uint32Value else { continue }
            let onScreen = (info[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
            signals.append(ForkMeetingWindowSignal(bundle: bundle, pid: owner, title: title, onScreen: onScreen,
                                                   windowID: number))
        }
        bundles = bundles.filter { seen.contains($0.key) }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        lock.withLock {
            cost.readings += 1
            cost.totalMilliseconds += milliseconds
            cost.maxMilliseconds = max(cost.maxMilliseconds, milliseconds)
            cost.listed = windows.count
            cost.kept = signals.count
        }
        deliver(signals)
    }

    /// Once per process, as long as it owns windows.
    private func bundle(of pid: pid_t) -> String? {
        if let known = bundles[pid] { return known }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundles[pid] = .some(bundle)
        return bundle
    }

    private func deliver(_ signals: [ForkMeetingWindowSignal], titlesUnreadable: Bool = false) {
        DispatchQueue.main.async { [weak self] in self?.onReading(signals, titlesUnreadable) }
    }
}
