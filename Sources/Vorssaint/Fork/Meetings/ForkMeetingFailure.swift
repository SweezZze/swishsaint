// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Each way a meeting recording can fail, refuse to start or lose a part of
/// what it records. Every case says what to do: a message that only names the
/// problem is no better than silence, and one that hides it is worse.
enum ForkMeetingFailure: Error, Equatable {
    /// Screen Recording was never allowed: nothing can be filmed.
    case screenRecordingDenied
    /// Screen Recording was taken back during a meeting: it stopped, its file
    /// is kept.
    case screenRecordingRevoked
    /// The meeting records without a microphone.
    case microphoneDenied
    /// The app tap stays silent: the sound falls back to the whole Mac.
    case systemAudioUnavailable
    /// Not enough room to start; `requiredBytes` is the floor asked for.
    case diskFullAtStart(requiredBytes: Int64)
    /// The disk ran low during a meeting: it stopped cleanly, its file is kept.
    case diskFull
    /// macOS stopped the capture (its recording indicator, another reason it
    /// does not tell): the file is kept.
    case streamStopped
    /// The official screen recorder runs: a meeting does not start on top.
    case officialRecorderBusy
    /// The meetings folder is missing, read-only or on a volume that left.
    case folderUnavailable
    /// The capture did not start for a reason macOS did not explain.
    case captureFailed
    /// The file could not be closed properly: what was written stays, and
    /// is recovered at the next launch.
    case writerFailed
    /// The quick copy with the mixed sound failed: the recording stays
    /// readable as it is, with its separate tracks.
    case finalPassFailed
    /// A local build without the fork's permission texts: macOS shows the
    /// official ones.
    case localBuild
}

/// The button offered next to a failure.
enum ForkMeetingFailureAction: Equatable {
    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    case openScreenRecordingPrivacy
    case openMicrophonePrivacy
    /// System Settings › General › Storage.
    case openStorageSettings
    /// The Meetings page of Vorssaint's settings.
    case openMeetingsPage
    /// The meetings folder in the Finder.
    case openMeetingsFolder
}

extension ForkMeetingFailure {
    /// A few words, for the island, the pill and the bubble: 28 characters
    /// at most in every language.
    func summary(_ s: ForkMeetingStrings) -> String {
        switch self {
        case .screenRecordingDenied: return s.failScreenDenied
        case .screenRecordingRevoked: return s.failScreenRevoked
        case .microphoneDenied: return s.failMicrophoneDenied
        case .systemAudioUnavailable: return s.failSystemAudio
        case let .diskFullAtStart(requiredBytes): return s.failDiskAtStart(gigabytes: Self.gigabytes(requiredBytes))
        case .diskFull: return s.failDiskFull
        case .streamStopped: return s.failStreamStopped
        case .officialRecorderBusy: return s.failRecorderBusy
        case .folderUnavailable: return s.failFolder
        case .captureFailed: return s.failCapture
        case .writerFailed: return s.failWriter
        case .finalPassFailed: return s.failFinalPass
        case .localBuild: return s.failBuild
        }
    }

    /// What to do about it, in full sentences: the Meetings page and
    /// VoiceOver.
    func remedy(_ s: ForkMeetingStrings) -> String {
        switch self {
        case .screenRecordingDenied: return s.failScreenDeniedRemedy
        case .screenRecordingRevoked: return s.failScreenRevokedRemedy
        case .microphoneDenied: return s.failMicrophoneDeniedRemedy
        case .systemAudioUnavailable: return s.failSystemAudioRemedy
        case .diskFullAtStart: return s.failDiskAtStartRemedy
        case .diskFull: return s.failDiskFullRemedy
        case .streamStopped: return s.failStreamStoppedRemedy
        case .officialRecorderBusy: return s.failRecorderBusyRemedy
        case .folderUnavailable: return s.failFolderRemedy
        case .captureFailed: return s.failCaptureRemedy
        case .writerFailed: return s.failWriterRemedy
        case .finalPassFailed: return s.failFinalPassRemedy
        case .localBuild: return s.failBuildRemedy
        }
    }

    var action: ForkMeetingFailureAction? {
        switch self {
        case .screenRecordingDenied, .screenRecordingRevoked, .systemAudioUnavailable:
            return .openScreenRecordingPrivacy
        case .microphoneDenied: return .openMicrophonePrivacy
        case .diskFullAtStart, .diskFull: return .openStorageSettings
        case .folderUnavailable, .captureFailed: return .openMeetingsPage
        case .writerFailed, .finalPassFailed: return .openMeetingsFolder
        case .streamStopped, .officialRecorderBusy, .localBuild: return nil
        }
    }

    /// A cause that stays until the person acts on it, worth a banner on the
    /// Meetings page; it clears itself once the cause is gone. The others
    /// belong to one meeting and pass with it.
    var isLasting: Bool {
        switch self {
        case .screenRecordingDenied, .screenRecordingRevoked, .microphoneDenied, .systemAudioUnavailable,
             .folderUnavailable, .localBuild:
            return true
        case .diskFullAtStart, .diskFull, .streamStopped, .officialRecorderBusy, .captureFailed,
             .writerFailed, .finalPassFailed:
            return false
        }
    }

    /// Whole gigabytes, rounded up: "2 GB" asks for at least what is needed.
    static func gigabytes(_ bytes: Int64) -> Int {
        let giga: Int64 = 1_000_000_000
        return Int((max(0, bytes) + giga - 1) / giga)
    }

    /// Every case, for the checks that each one explains itself.
    static let all: [ForkMeetingFailure] = [
        .screenRecordingDenied, .screenRecordingRevoked, .microphoneDenied, .systemAudioUnavailable,
        .diskFullAtStart(requiredBytes: 2_000_000_000), .diskFull, .streamStopped, .officialRecorderBusy,
        .folderUnavailable, .captureFailed, .writerFailed, .finalPassFailed, .localBuild,
    ]
}
