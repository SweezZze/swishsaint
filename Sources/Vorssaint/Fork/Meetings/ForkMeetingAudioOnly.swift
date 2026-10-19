// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

// MARK: Finish C

/// "Sound only": a meeting recorded without its picture.
///
/// - **No stream, no Screen Recording.** The meeting's sound comes from its
///   app's tap (or the whole Mac's), the microphone from its device: nothing
///   is filmed, so nothing asks to record the screen. Before macOS 14.4 there
///   is no tap, and the stream that would stand in for it is not started
///   either: the meeting track then stays silent, as the start says.
/// - **The same file, minus its picture.** The master is the same fragmented
///   MP4 (`.recording.mp4`), two-second fragments, the meeting then the
///   microphone; the final pass adds the same mix, and writes `<name>.m4a`
///   instead of `<name>.mp4`. No separate M4A is made: the final file is one.
/// - **The same guarantees**: a `kill -9` loses at most the last fragment, the
///   next launch recovers the master into the `.m4a`, a final pass that cannot
///   copy for room renames the master instead (an MP4 and an M4A are the same
///   container).
/// - `meeting.json` says it with `capture.target: "audioOnly"`; an older
///   `meeting.json` (window, display, or no capture at all) reads as before.
enum ForkMeetingAudioOnly {
    /// The Command Bar's "Record a Meeting" asks for Screen Recording only
    /// for a picture to film, not yet allowed, and before a recording runs.
    static func needsScreenRecording(filmsPicture: Bool, allowed: Bool, running: Bool) -> Bool {
        filmsPicture && !allowed && !running
    }

    /// The finished `.m4a`: the mix and the two sources, as a video's
    /// sound. An estimate, like `ForkMeetingQuality.totalBitRate`.
    static var totalBitRate: Int {
        ForkMeetingQuality.Rates.mixAudio + ForkMeetingQuality.Rates.sourceAudio * ForkMeetingQuality.Rates.sourceTrackCount
    }

    static var bytesPerSecond: Int64 { Int64(totalBitRate) / 8 }

    static var estimatedBytesPerHour: Int64 { bytesPerSecond * 3600 }

    /// For the settings page: "~0.1 GB/h", in decimal gigabytes like the
    /// quality presets.
    static var estimatedGigabytesPerHour: Double { Double(estimatedBytesPerHour) / 1_000_000_000 }

    /// What hears the meeting without a picture: a tap only. The stream,
    /// which a refused tap falls back on when something is filmed, never
    /// runs here: what would need it hears nothing.
    static func sound(_ chosen: ForkMeetingSoundSource) -> ForkMeetingSoundSource {
        chosen == .stream ? .none : chosen
    }
}

extension ForkMeetingCaptureTarget {
    /// Something is filmed: Screen Recording is needed, and the final file
    /// is a video.
    var filmsPicture: Bool { self != .audioOnly }

    /// The other choice the offer gives for one meeting: sound only when
    /// the setting films, the meeting's window when it is sound only.
    var alternative: ForkMeetingCaptureTarget { self == .audioOnly ? .window : .audioOnly }
}

extension ForkMeetingCaptureSettings {
    /// What a second of this meeting weighs once finished.
    var bytesPerSecond: Int64 {
        target.filmsPicture ? quality.bytesPerSecond : ForkMeetingAudioOnly.bytesPerSecond
    }
}

extension ForkMeetingDisk {
    /// `level(freeBytes:quality:)`, the minutes left counted at what this
    /// meeting really writes: a meeting without picture lasts much longer
    /// on the same room.
    static func level(freeBytes: Int64, settings: ForkMeetingCaptureSettings) -> Level {
        guard case .low = level(freeBytes: freeBytes, quality: settings.quality) else {
            return level(freeBytes: freeBytes, quality: settings.quality)
        }
        return .low(minutesLeft: minutesLeft(freeBytes: freeBytes, bytesPerSecond: settings.bytesPerSecond))
    }

    static func minutesLeft(freeBytes: Int64, bytesPerSecond: Int64) -> Int {
        let usable = max(0, freeBytes - minimumFreeBytesToContinue)
        return Int(usable / max(1, bytesPerSecond) / 60)
    }
}

extension ForkMeetingSidecar {
    /// Recorded without picture: its final file is the `.m4a`.
    var isAudioOnly: Bool { capture?.target == .audioOnly }
}

extension ForkMeetingFolder {
    /// The final file's extension: a video's, or the M4A's without picture.
    static func finalExtension(audioOnly: Bool) -> String {
        audioOnly ? audioExtension : videoExtension
    }
}

extension ForkMeetingFolder.Contents {
    /// The meeting's own final file: its video, or, recorded without
    /// picture, its `.m4a`. Never a video's M4A in place of the video: that
    /// is a copy of its mix, and a meeting whose video is gone is not
    /// complete because of it.
    func media(audioOnly: Bool) -> String? {
        audioOnly ? audio : video
    }
}

extension ForkMeetingOfferText {
    /// Whether the offer's menu may record this one meeting otherwise than
    /// the setting (`ForkMeetingCaptureTarget.alternative`): while nothing
    /// greys the offer out, or only the missing Screen Recording, which a
    /// meeting without picture does not need.
    static func recordsOtherwise(_ offer: ForkMeetingOffer, as other: ForkMeetingCaptureTarget) -> Bool {
        guard let blocked = offer.blocked else { return true }
        return blocked == .screenRecordingDenied && !other.filmsPicture
    }
}
