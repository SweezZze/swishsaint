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

    /// The pill's gauge follows the session's own pass, not a recovery's.
    func finalizerProgressed(_ progress: ForkMeetingFinalizer.Progress?) {
        if let progress, finalizing.contains(where: { Self.same($0, progress.folder) }) {
            presenter.setFinalizing(progress: progress.fraction)
        }
        refreshState()
    }

    private func finalized(_ outcome: ForkMeetingFinalizer.Outcome) {
        finalizing.removeAll { Self.same($0, outcome.folder) }
        log.notice("\(outcome.folder.lastPathComponent, privacy: .public): \(outcome.finalPass.rawValue, privacy: .public) \(outcome.note ?? "", privacy: .public)")
        if machine.phase == .idle, presenter.pillState == .finalizing {
            presenter.apply(.showPill(.hidden))
        }
        if outcome.succeeded {
            saved(outcome, recovered: false)
        } else {
            // The master stays, readable with its separate tracks; the next
            // launch tries once more.
            remember(.finalPassFailed)
            lastNotice = .failure(.finalPassFailed)
            presenter.notice(.failure(.finalPassFailed))
            presenter.apply(.notify(.failure(.finalPassFailed)))
            presenter.apply(.announce(.failure(.finalPassFailed)))
        }
        refreshState()
    }

    /// "Meeting saved · 52 min · 410 MB [Show in Finder]", in the island or
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
    }

    // MARK: - Launch

    /// What the last run left unfinished: final pass again, complete, or
    /// marked interrupted, as `ForkMeetingRecoveryPlan` says. Each meeting
    /// that plays again is said: "Meeting recovered · 37 min". Whether the
    /// feature is on or not: a meeting is never left behind.
    func recoverAtLaunch() {
        store.recoverAtLaunch(using: finalizer, extractAudio: defaults.bool(forKey: ForkDefaultsKey.meetingsExtractAudio),
                              titles: trackTitles) { [weak self] recoveries in
            self?.recovered(recoveries)
        }
    }

    private func recovered(_ recoveries: [ForkMeetingStore.Recovery]) {
        for recovery in recoveries {
            log.notice("launch: \(recovery.folder.lastPathComponent, privacy: .public) \(String(describing: recovery.action), privacy: .public) \(recovery.outcome?.finalPass.rawValue ?? "", privacy: .public)")
            guard recovery.isRecovered, let outcome = recovery.outcome else { continue }
            saved(outcome, recovered: true)
        }
        refreshState()
    }

    static func same(_ one: URL, _ other: URL) -> Bool {
        one.standardizedFileURL.path == other.standardizedFileURL.path
    }
}
