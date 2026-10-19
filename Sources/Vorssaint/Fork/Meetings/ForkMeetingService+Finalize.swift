// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// A meeting saved: what the notice said, for whoever shows it again.
struct ForkMeetingSaved: Equatable {
    let folder: URL
    let seconds: TimeInterval?
    let bytes: Int64?
    /// Found unfinished at a launch, and playing again.
    let recovered: Bool
}

/// After the recording: the final pass, which lives outside the session (the
/// pill shows its gauge, then the saved notice), and the meetings a crash or
/// a quit left unfinished, recovered at launch.
extension ForkMeetingService {
    // MARK: - Final pass

    /// Once per session (the machine's word): the finalizer copies the
    /// picture, mixes the sound and writes `complete`.
    func beginFinalize(_ folder: URL) {
        finalizing.append(folder)
        finalizer.finalize(folder, extractAudio: defaults.bool(forKey: ForkDefaultsKey.meetingsExtractAudio),
                           titles: trackTitles) { [weak self] outcome in
            self?.finalized(outcome)
        }
    }

    /// The final file's audio tracks, named in the person's language.
    var trackTitles: ForkMeetingFinalizer.TrackTitles {
        let text = ForkMeetingStrings.current
        return ForkMeetingFinalizer.TrackTitles(mix: text.trackMix, meeting: text.trackMeeting,
                                                microphone: text.trackMicrophone)
    }

    /// The pill's gauge follows the session's own pass, not a recovery's,
    /// and only while it shows one: a next meeting may be recording.
    func finalizerProgressed(_ progress: ForkMeetingFinalizer.Progress?) {
        if let progress, finalizing.contains(where: { Self.same($0, progress.folder) }),
           presenter.pillState == .finalizing {
            presenter.setFinalizing(progress: progress.fraction)
        }
        refreshState()
    }

    /// The pill goes once no session's pass is left and no session runs
    /// (`refreshState`): two meetings in a row keep it until the second.
    private func finalized(_ outcome: ForkMeetingFinalizer.Outcome) {
        finalizing.removeAll { Self.same($0, outcome.folder) }
        log.notice("\(outcome.folder.lastPathComponent, privacy: .private): \(outcome.finalPass.rawValue, privacy: .public) \(outcome.note ?? "", privacy: .private)")
        if outcome.succeeded {
            saved(outcome, recovered: false)
            // Its transcript, when the setting asks for one (PR 6).
            ForkMeetingTranscriber.shared.meetingSaved(outcome.folder, recovered: false)
        } else {
            revealAfterFailure(outcome.folder, readable: outcome.seconds != nil)
        }
        refreshState()
    }

    /// A final pass that failed: the master, when it plays (`readable`),
    /// with its separate tracks, is shown under the meeting's name, and the
    /// failure says where the recording is. The pass is tried once more at
    /// the next launch (`ForkMeetingStore.revealMaster`).
    func revealAfterFailure(_ folder: URL, readable: Bool) {
        store.revealMaster(in: folder, readable: readable) { [weak self] revealed in
            guard let self else { return }
            let failure: ForkMeetingFailure
            switch revealed {
            case let .visible(video):
                self.lastFailedVideo = video
                failure = .finalPassFailed
            case let .hidden(master):
                self.lastFailedVideo = master
                failure = .masterHidden
            case .none:
                // Nothing playable: never "the video stays readable".
                self.lastFailedVideo = nil
                failure = .masterMissing
            case .elsewhere:
                self.lastFailedVideo = nil
                failure = .finalPassFailed
            }
            self.remember(failure)
            self.lastNotice = .failure(failure)
            self.presenter.notice(.failure(failure))
            self.presenter.apply(.notify(.failure(failure)))
            self.presenter.apply(.announce(.failure(failure)))
        }
    }

    /// "Meeting saved · 52 min · 410 MB [Show]", in the island or
    /// the bubble, and a notification when the app is behind. The finalizer
    /// already listed it in Recent captures.
    private func saved(_ outcome: ForkMeetingFinalizer.Outcome, recovered: Bool) {
        let bytes = (outcome.videoBytes ?? 0) + (outcome.audioBytes ?? 0)
        let seconds = outcome.seconds ?? 0
        let detail = ForkMeetingLiveText.savedDetail(seconds: seconds, bytes: bytes > 0 ? bytes : nil,
                                                     language: L10n.shared.language)
        lastNotice = recovered ? .recovered : .saved
        lastSaved = ForkMeetingSaved(folder: outcome.folder, seconds: outcome.seconds, bytes: bytes > 0 ? bytes : nil,
                                     recovered: recovered)
        presenter.showSaved(folder: outcome.folder, detail: detail, recovered: recovered)
        // A meeting recovered at launch did not end well: sent with a click
        // only. Nothing goes on its own with the feature off.
        if !recovered, isWanted { ForkMeetingExports.shared.meetingFinished(outcome.folder) }
    }

    /// An automatic export of this meeting failed, or could not start:
    /// "Export failed [Show]", the meeting's detail having the reason and
    /// its Retry.
    func exportFailed(_ folder: URL) {
        guard isWanted else { return }
        presenter.showExportFailed(folder: folder)
    }

    // MARK: - Launch

    /// What the last run left unfinished: final pass again, complete, or
    /// marked interrupted, as `ForkMeetingRecoveryPlan` says. Each meeting
    /// that plays again is said: "Meeting recovered · 37 min". Whether the
    /// feature is on or not: a meeting is never left behind.
    func recoverAtLaunch() {
        // What an export cut short by the last quit left behind.
        ForkMeetingExports.shared.removeLeftovers()
        store.recoverAtLaunch(using: finalizer, extractAudio: defaults.bool(forKey: ForkDefaultsKey.meetingsExtractAudio),
                              titles: trackTitles) { [weak self] recoveries in
            self?.recovered(recoveries)
        }
    }

    private func recovered(_ recoveries: [ForkMeetingStore.Recovery]) {
        for recovery in recoveries {
            log.notice("launch: \(recovery.folder.lastPathComponent, privacy: .private) \(String(describing: recovery.action), privacy: .public) \(recovery.outcome?.finalPass.rawValue ?? "", privacy: .public)")
            // A meeting whose pass failed again at launch is shown too.
            if let outcome = recovery.outcome, !outcome.succeeded {
                revealAfterFailure(recovery.folder, readable: outcome.seconds != nil)
                continue
            }
            guard recovery.isRecovered, let outcome = recovery.outcome else { continue }
            saved(outcome, recovered: true)
        }
        refreshState()
    }

    static func same(_ one: URL, _ other: URL) -> Bool {
        one.standardizedFileURL.path == other.standardizedFileURL.path
    }
}
