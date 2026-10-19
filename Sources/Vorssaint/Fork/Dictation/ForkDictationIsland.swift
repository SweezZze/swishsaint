// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// Dictation in Vorssaint's island, the way the microphone switch reports
/// there: its mark and the time on one side of the camera, the voice's level
/// on the other.
///
/// It borrows the microphone notice, the only one that draws a live level.
/// The same notice sent again only updates its reading in place and pushes
/// its dismissal back, so the presenter refreshes it while it should stay.
enum ForkDictationIsland {
    /// Whether the closed island can show the notice now. Open, dragged
    /// into, or holding capture controls, it is doing something else, and
    /// the bubble takes over.
    static var isAvailable: Bool {
        let island = NotchService.shared
        return NotchSupport.routes(.microphone) && island.showsSystemFeedback
            && !island.expanded && !island.dragPlaceholder && island.captureControls == nil
    }

    /// False when the island refused it: the caller falls back on the bubble.
    @discardableResult
    static func show(_ presentation: ForkDictationPresentation, level: Float, now: Date,
                     text: ForkDictationStrings) -> Bool {
        guard isAvailable, let notice = notice(for: presentation, level: level, now: now, text: text) else {
            return false
        }
        lastShown = notice
        return NotchService.shared.show(notice)
    }

    static func retract() {
        NotchService.shared.retractMicrophoneNotice()
    }

    /// The last notice dictation sent, to tell it from the microphone's own.
    private static var lastShown: NotchNotice?

    /// A click on the island's notice (seam `notch-dictation4`): the final
    /// step of a dictation kept in the history opens it in the island's
    /// Dictations tab. False for any other notice, which the island handles.
    static func activate(_ notice: NotchNotice) -> Bool {
        guard notice.event == .microphone, let shown = lastShown,
              notice.title == shown.title, notice.symbol == shown.symbol, notice.detail == shown.detail
        else { return false }
        return ForkDictationPresenter.shared.openHistoryFromIsland()
    }

    static func notice(for presentation: ForkDictationPresentation, level: Float, now: Date,
                       text: ForkDictationStrings) -> NotchNotice? {
        switch presentation {
        case .hidden:
            return nil
        case let .listening(handsFree, startedAt, _):
            // The time takes a fixed width, so the island does not resize at
            // each tick.
            return NotchNotice(event: .microphone, title: "",
                               detail: ForkDictationPresenter.clock(now.timeIntervalSince(startedAt)),
                               symbol: handsFree ? "waveform.badge.mic" : "waveform",
                               level: Double(min(1, max(0, level))))
        case .transcribing:
            return NotchNotice(event: .microphone, title: text.statusTranscribing, detail: "",
                               symbol: "ellipsis")
        case let .pasted(excerpt):
            return NotchNotice(event: .microphone, title: text.statusPasted, detail: excerpt,
                               symbol: "checkmark")
        case let .copied(excerpt):
            return NotchNotice(event: .microphone, title: text.statusCopied, detail: excerpt,
                               symbol: "doc.on.clipboard")
        case .keptInClipboard:
            return NotchNotice(event: .microphone, title: text.statusKeptInClipboard, detail: "",
                               symbol: "doc.on.clipboard")
        case .inHistoryOnly:
            return NotchNotice(event: .microphone, title: text.statusInHistoryOnly, detail: "",
                               symbol: "clock.arrow.circlepath")
        case let .nothingHeard(afterSilence):
            return NotchNotice(event: .microphone,
                               title: afterSilence ? text.statusNothingHeardSilence : text.statusNothingHeard,
                               detail: "", symbol: "waveform.slash")
        case .cancelled:
            return NotchNotice(event: .microphone, title: text.statusCancelled, detail: "", symbol: "xmark")
        case .busy:
            return NotchNotice(event: .microphone, title: text.statusBusy, detail: "", symbol: "hourglass")
        case let .failure(failure):
            return NotchNotice(event: .microphone, title: failure.summary(text), detail: "",
                               symbol: "exclamationmark.triangle.fill")
        }
    }
}
