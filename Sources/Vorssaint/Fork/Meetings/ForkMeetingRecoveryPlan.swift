// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What a launch does with a meeting folder left unfinished: a crash, a
/// quit, a final pass cut short. The store gathers the facts (the sidecar,
/// and how long its master and final files play), this decides, the store
/// acts.
///
/// | found | action |
/// |---|---|
/// | the final file whole (≥ 99 % of the master) | complete; the master goes |
/// | a readable master of a second or more | final pass again, drafts dropped |
/// | neither | marked interrupted, everything kept |
///
/// **Nothing is ever removed unless what it holds is safe elsewhere**: the
/// master only once a final file at least as long is verified, a draft only
/// when the master or a whole final file can replace it. A sidecar that does
/// not decode, or comes from a later version, is left alone.
enum ForkMeetingRecoveryPlan {
    /// A master shorter than this holds nothing worth a final pass.
    static let minimumMasterSeconds: TimeInterval = 1
    /// The final file must play at least this share of the master before the
    /// master may go: a final pass cut short leaves a shorter file.
    static let completeShare = 0.99

    /// How long a file plays; `nil` duration when it does not open.
    struct Media: Equatable {
        var duration: TimeInterval?

        var isReadable: Bool { duration != nil }
    }

    struct Facts: Equatable {
        var sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>
        /// `nil`: no master in the folder.
        var master: Media?
        /// `nil`: no final video in the folder.
        var final: Media?
        /// A draft of the final pass is in the folder.
        var hasDrafts = false
    }

    enum Action: Equatable {
        /// Nothing to do, or nothing that can safely be done.
        case leave
        /// Run the final pass from the master: `recovered` when the meeting
        /// never closed (a crash, a quit), not when only its final pass was
        /// cut short.
        case finalize(stopReason: ForkMeetingStopReason, recovered: Bool, discardDrafts: Bool)
        /// The final file is there and whole.
        case complete(removeMaster: Bool, discardDrafts: Bool)
        /// Nothing readable to recover: flagged in the library, kept.
        case markInterrupted(stopReason: ForkMeetingStopReason)
    }

    /// Whether the folder is worth probing at all: probing a video costs, and
    /// most folders are simply complete.
    static func needsInspection(_ sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
                                contents: ForkMeetingFolder.Contents) -> Bool {
        guard case let .success(meeting) = sidecar, meeting.isRewritable else { return false }
        let leftovers = contents.hasMaster || contents.hasVideoDraft || contents.hasAudioDraft
        switch meeting.state {
        case .recording?, .finalizing?: return true
        case .interrupted?, .complete?: return leftovers
        case nil: return false
        }
    }

    static func plan(_ facts: Facts) -> Action {
        guard case let .success(meeting) = facts.sidecar, meeting.isRewritable,
              let state = meeting.state else { return .leave }

        let masterSeconds = facts.master?.duration
        let finalIsWhole: Bool = {
            guard let finalSeconds = facts.final?.duration, finalSeconds > 0 else { return false }
            guard let master = facts.master else { return true }
            guard let masterSeconds = master.duration else { return true }
            return finalSeconds >= masterSeconds * completeShare
        }()
        // The master goes only when its length was measured and the final
        // file matches it.
        let masterCanGo = facts.master?.isReadable == true && finalIsWhole

        if finalIsWhole {
            if state == .complete && !masterCanGo && !facts.hasDrafts { return .leave }
            return .complete(removeMaster: masterCanGo, discardDrafts: facts.hasDrafts)
        }
        if state == .complete { return .leave }

        if let masterSeconds, masterSeconds >= minimumMasterSeconds {
            return .finalize(stopReason: meeting.stopReason ?? .crash,
                             recovered: state != .finalizing,
                             discardDrafts: facts.hasDrafts)
        }
        if state == .interrupted { return .leave }
        return .markInterrupted(stopReason: meeting.stopReason ?? .crash)
    }

    /// What the sidecar says once the action is under way. The final pass
    /// itself writes `complete` when it succeeds. No end time is invented:
    /// the meeting's length is the master's.
    static func patch(for action: Action, facts: Facts) -> ForkMeetingSidecarPatch? {
        switch action {
        case .leave:
            return nil
        case let .finalize(stopReason, recovered, _):
            var patch = ForkMeetingSidecarPatch(state: .finalizing, stopReason: stopReason)
            if recovered { patch.recovered = true }
            if case let .success(meeting) = facts.sidecar, let seconds = facts.master?.duration,
               seconds > (meeting.recordedSeconds ?? 0) {
                patch.recordedSeconds = seconds
            }
            return patch
        case .complete:
            var patch = ForkMeetingSidecarPatch(state: .complete)
            if case let .success(meeting) = facts.sidecar, meeting.finalPass == nil { patch.finalPass = .done }
            return patch
        case let .markInterrupted(stopReason):
            return ForkMeetingSidecarPatch(state: .interrupted, stopReason: stopReason)
        }
    }
}
