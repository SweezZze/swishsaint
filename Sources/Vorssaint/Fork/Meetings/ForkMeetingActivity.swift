// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Whether a meeting is being recorded or finished, for what must not get in
/// its way: the fork's updater, which quits the app to replace it.
///
/// Two sources, kept apart so neither can clear the other: the service says
/// when a recording runs, the finalizer counts the final passes it holds. A
/// meeting is safe once both are done, and only then `didBecomeIdle` is
/// posted, on the main thread.
///
/// Static and under a lock rather than an object to observe: the updater
/// reads it from wherever it is, and must not depend on the meeting service
/// being built.
enum ForkMeetingActivity {
    /// Posted on the main thread when the last recording or final pass ends.
    static let didBecomeIdle = Notification.Name("fork.meetings.activity.idle")

    struct Tally: Equatable {
        var recording = false
        var finalizing = 0

        var isBusy: Bool { recording || finalizing > 0 }
    }

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var tally = Tally()
    }

    private static let shared = Shared()

    static var isBusy: Bool { tally.isBusy }

    static var tally: Tally {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.tally
    }

    /// The service: a recording started (or is starting), or ended.
    static func setRecording(_ recording: Bool) {
        change { $0.recording = recording }
    }

    /// The finalizer: one more final pass queued.
    static func beginFinalizing() {
        change { $0.finalizing += 1 }
    }

    /// The finalizer: a final pass ended, however it ended.
    static func endFinalizing() {
        change { $0.finalizing = max(0, $0.finalizing - 1) }
    }

    private static func change(_ body: (inout Tally) -> Void) {
        shared.lock.lock()
        let wasBusy = shared.tally.isBusy
        body(&shared.tally)
        let becameIdle = wasBusy && !shared.tally.isBusy
        shared.lock.unlock()
        guard becameIdle else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didBecomeIdle, object: nil)
        }
    }
}
