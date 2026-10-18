// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Waits for an asynchronous piece of work, but not for ever: what the app
/// does when it quits during a recording. The work runs elsewhere (the
/// writer's own queue) and calls `done`; the calling thread blocks until
/// then or until `timeout`, whichever comes first.
///
/// **Nothing the work does may need the waiting thread.** Called on the main
/// thread at `willTerminate`, a work that hops back to the main queue would
/// only resume once the wait is over: it would always take the full timeout,
/// for nothing. A fragmented master is readable at any moment, so a wait cut
/// short loses at most the last fragment, and the next launch recovers it.
enum ForkMeetingBoundedWait {
    /// What the app gives the writer to close its file when it quits.
    static let quitTimeout: TimeInterval = 3

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false
        let semaphore = DispatchSemaphore(value: 0)

        func signal() {
            lock.lock()
            let first = !signaled
            signaled = true
            lock.unlock()
            if first { semaphore.signal() }
        }
    }

    /// `true` when `work` called `done` in time. `done` may be called from
    /// any thread, late, or more than once: only the first call counts, and
    /// a late one is harmless.
    @discardableResult
    static func run(timeout: TimeInterval, _ work: (@escaping @Sendable () -> Void) -> Void) -> Bool {
        let once = Once()
        work { once.signal() }
        return once.semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }
}

/// What a reading of the free space means, while a meeting records.
enum ForkMeetingDiskSignal: Equatable {
    /// Under the warning floor: the pill shows the minutes left.
    case low(freeBytes: Int64)
    /// Under the stop floor: the recording stops while it still can.
    case critical

    /// `nil` when there is nothing to say: enough room, or **a reading that
    /// failed**. A failed reading is not a full disk (bran stopped meetings
    /// on a zero it made up, `CaptureSession.swift:445`), nor an empty one.
    static func reading(freeBytes: Int64?, quality: ForkMeetingQuality) -> ForkMeetingDiskSignal? {
        guard let freeBytes else { return nil }
        switch ForkMeetingDisk.level(freeBytes: freeBytes, quality: quality) {
        case .enough: return nil
        case .low: return .low(freeBytes: freeBytes)
        case .critical: return .critical
        }
    }
}

enum ForkMeetingFreeSpace {
    /// The free space of a volume from its two readings: the capacity "for
    /// important usage" (what macOS would free for a file the person
    /// asked for, purgeable space included) and the plain available one.
    ///
    /// The first is the right one but some volumes (network shares, some
    /// external formats) answer nothing or zero; the plain one then speaks.
    /// A full disk is a zero both agree on, or the plain one alone; a zero
    /// from the first alone may be a volume that does not know. When
    /// nothing answers the free space is unknown, `nil`, and never a zero:
    /// an unknown is not a full disk.
    static func resolve(important: Int64?, available: Int?) -> Int64? {
        if let important, important > 0 { return important }
        guard let available else { return nil }
        return Int64(max(0, available))
    }
}
