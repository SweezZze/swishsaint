// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The Mac's events, turned into the machine's: sleep and wake, the screen
/// locked, the displays, the disk, and the app quitting.
extension ForkMeetingService {
    /// Watched while the feature is on, and until a meeting stopped by its
    /// turning off has closed its file: a quit in between must still be
    /// caught.
    func syncSystemEvents() {
        let wanted = isWanted || machine.isBusy
        if wanted, !systemEvents.isRunning {
            systemEvents.start()
        } else if !wanted, systemEvents.isRunning {
            systemEvents.stop()
            watchedToken = nil
        }
    }

    func systemEvent(_ event: ForkMeetingSystemEvents.Event) {
        switch event {
        case .willSleep: send(.willSleep)
        case .didWake: send(.didWake)
        case .locked: send(.locked)
        case .unlocked: send(.unlocked)
        case .displaysChanged:
            // The pill and the bubble follow the meeting's display.
            if machine.activeSession != nil, let display = Self.displayID(of: filmedWindow), context.displayID != display {
                context.displayID = display
                presenter.update(context)
            }
            send(.displayChanged)
        case let .diskLow(freeBytes), let .diskEnough(freeBytes): send(.diskLow(freeBytes: freeBytes))
        case .diskCritical: send(.diskCritical)
        case .willTerminate: terminate()
        }
    }

    /// `willTerminate`, on the main thread, the app ending right after. The
    /// machine writes `interrupted` (and `quit`) first, synchronously; then
    /// the file gets three seconds to close, waited for on this thread
    /// without anything needing it (`ForkMeetingRecorder.stopBlocking`).
    /// Past that, the fragments already written are the next launch's to
    /// recover. A meeting finishing is left as it is: its final pass starts
    /// again at the next launch.
    func terminate() {
        guard !terminating else { return }
        terminating = true
        quitDeadline = Date().addingTimeInterval(ForkMeetingBoundedWait.quitTimeout)
        let began = Date()
        send(.appWillTerminate)
        // A stop already under way when the app quit (the person's Stop, a
        // failure): its file gets the same bound.
        for (token, recorder) in recorders {
            let left = quitDeadline.timeIntervalSinceNow
            guard left > 0, let result = recorder.stopBlocking(timeout: left) else { continue }
            stopped(token, result: result, recorded: isStopping(token))
        }
        let unclosed = recorders.count
        let waited = Int((Date().timeIntervalSince(began) * 1000).rounded())
        log.notice("quit: \(waited) ms, \(unclosed) file(s) left to the next launch")
    }
}
