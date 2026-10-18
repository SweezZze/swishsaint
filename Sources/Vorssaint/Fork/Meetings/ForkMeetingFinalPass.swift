// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the final pass decides, apart from the AVFoundation that carries it
/// out (`ForkMeetingFinalizer`).
///
/// The master the writer leaves (`.recording.mp4`) holds the picture and the
/// two sources, the meeting's sound then the microphone, in that order. The
/// final file keeps all of it untouched and adds one track every player
/// plays:
///
/// ```
/// master  video · meeting · microphone
/// final   video (copied) · Mix (AAC, enabled) · meeting · microphone (copied, disabled, named)
/// ```
///
/// - The sources are told apart **by their order**: an `.mp4` drops the
///   content identifier of a track (spike S1), and order is what the writer
///   controls.
/// - The copy is written beside the master and replaces nothing until it is
///   verified; the master goes only after.
enum ForkMeetingFinalPass {
    enum Route: Equatable {
        /// The copy with the mixed track, written to a draft.
        case copy
        /// No room for the copy: the master itself becomes the final file,
        /// with its separate tracks (`finalPass: skipped-disk`).
        case promoteMaster
    }

    /// An unknown free space is neither enough nor too little: the copy is
    /// tried, on a draft that cannot harm the master, and a copy that then
    /// fails for want of room still falls back to the master.
    static func route(freeBytes: Int64?, masterBytes: Int64) -> Route {
        guard let freeBytes else { return .copy }
        return ForkMeetingDisk.finalPassFits(freeBytes: freeBytes, masterBytes: masterBytes) ? .copy : .promoteMaster
    }

    /// What a source track is, from its place among the master's audio
    /// tracks.
    enum SourceRole: Equatable {
        case meeting
        case microphone
        /// Beyond the two the writer makes: kept, never mixed.
        case extra
    }

    static func role(at index: Int) -> SourceRole {
        switch index {
        case 0: return .meeting
        case 1: return .microphone
        default: return .extra
        }
    }

    struct Layout: Equatable {
        /// Places, among the master's audio tracks, of the ones summed into
        /// the mix. Empty: a silent master, and no mix.
        var mixed: [Int]
        /// Every audio track of the master, copied after the mix, disabled.
        var copied: [SourceRole]

        var hasMix: Bool { !mixed.isEmpty }
    }

    /// The final file's audio for a master with `audioTracks` sources. One
    /// source (no microphone) still gets its mix, so every final file reads
    /// the same way: picture, mix, then the sources.
    static func layout(audioTracks: Int) -> Layout {
        let count = max(0, audioTracks)
        return Layout(mixed: Array(0..<min(count, 2)), copied: (0..<count).map(role(at:)))
    }

    /// Each source's volume in the mix. Two voices summed at full volume
    /// clip as soon as both speak loud; at 0.7 (−3 dB) each, two voices
    /// peaking at −3 dBFS at the same instant still fit, and a single voice
    /// loses little. Spike S1 measured no clipping either way: a value to
    /// confirm on real meetings.
    static func mixVolume(sources: Int) -> Float {
        sources > 1 ? 0.7 : 1
    }

    /// Whether a copy (or a promoted master) holds the whole meeting: it
    /// opens, and plays at least `ForkMeetingRecoveryPlan.completeShare` of
    /// the master. Only then may the master go.
    static func isWhole(seconds: Double?, masterSeconds: Double?) -> Bool {
        guard let seconds, seconds.isFinite, seconds > 0 else { return false }
        guard let masterSeconds, masterSeconds.isFinite, masterSeconds > 0 else { return true }
        return seconds >= masterSeconds * ForkMeetingRecoveryPlan.completeShare
    }

    /// The share of the progress the copy takes when an M4A follows: the
    /// M4A is a copy of one audio track, about a tenth of a second per hour.
    static let copyShare = 0.95

    /// The progress of a whole job, 0…1, for the pill's gauge.
    static func progress(copy: Double, audio: Double = 0, extractsAudio: Bool) -> Double {
        let copied = min(max(copy, 0), 1)
        guard extractsAudio else { return copied }
        return copied * copyShare + min(max(audio, 0), 1) * (1 - copyShare)
    }

    /// A step worth publishing: a whole percent more, or the end. The gauge
    /// needs no more, and the main thread gets a hundred updates per job
    /// rather than one per frame.
    static func shouldPublish(_ value: Double, last: Double?) -> Bool {
        guard let last else { return true }
        return value >= 1 ? last < 1 : value - last >= 0.01
    }
}
