// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// How a meeting is encoded, chosen before it starts. The writer compresses
/// at the final bit rate while it records: there is no second encode, so the
/// preset alone decides the size of the file on the disk.
///
/// A meeting is mostly faces and slides that sit still, so a low, steady
/// bit rate goes a long way; the frame rate stays at 30 for everyone, and the
/// presets only differ by picture size and bits.
enum ForkMeetingQuality: String, CaseIterable, Codable {
    /// Audio and faces: an archive more than a document.
    case light
    /// Slides stay readable.
    case standard
    /// Code demos and small print.
    case high

    static let fallback: ForkMeetingQuality = .standard

    /// The stored setting, or the default when it is empty or unknown.
    init(stored: String?) {
        self = ForkMeetingQuality(rawValue: stored ?? "") ?? .fallback
    }

    /// Every rate in one place. **Provisional**: spike S1 measures them on
    /// real meetings (readable slides, size per hour, CPU), and the numbers
    /// below are the plan's starting point, to change here and nowhere else.
    enum Rates {
        static let lightVideo = 600_000
        static let standardVideo = 1_200_000
        static let highVideo = 2_500_000
        /// The mixed track that every player plays.
        static let mixAudio = 96_000
        /// Each of the two source tracks kept beside it (the meeting, the
        /// microphone), mono: the transcript tells "Me" from "Others" with them.
        static let sourceAudio = 64_000
        static let sourceTrackCount = 2
        static let frameRate = 30
        /// A keyframe every two seconds: the fragments are two seconds long
        /// too, so a crash loses at most that, and seeking stays quick.
        static let keyframeSeconds = 2
        /// 64 kbit/s mono is out of reach below 48 kHz: AVAssetWriter does
        /// not resample, and AAC at 16 kHz mono tops out at 48 kbit/s.
        static let audioSampleRate = 48_000
    }

    var videoBitRate: Int {
        switch self {
        case .light: return Rates.lightVideo
        case .standard: return Rates.standardVideo
        case .high: return Rates.highVideo
        }
    }

    /// The tallest picture written, in pixels, for a landscape source.
    var maximumLines: Int {
        switch self {
        case .light: return 720
        case .standard, .high: return 1080
        }
    }

    /// The box the picture fits in: 16:9 at `maximumLines`. A wide source
    /// is bounded by its width instead, so an ultra-wide display does not
    /// spread the same bits over three times the pixels.
    var maximumBox: ForkMeetingPixelSize {
        ForkMeetingPixelSize(width: maximumLines * 16 / 9, height: maximumLines)
    }

    static var keyframeInterval: Int { Rates.frameRate * Rates.keyframeSeconds }

    /// Every track of the finished file: the picture, the mix and the two
    /// sources. An estimate: the encoder tends to stay under its target.
    var totalBitRate: Int {
        videoBitRate + Rates.mixAudio + Rates.sourceAudio * Rates.sourceTrackCount
    }

    var bytesPerSecond: Int64 { Int64(totalBitRate) / 8 }

    var estimatedBytesPerHour: Int64 { bytesPerSecond * 3600 }

    /// For the settings page: "~0.6 GB/h". Decimal gigabytes, as the Finder
    /// counts them.
    var estimatedGigabytesPerHour: Double { Double(estimatedBytesPerHour) / 1_000_000_000 }

    /// The size the writer encodes for a source of `source` pixels: the
    /// source's own shape, scaled down to fit `maximumBox` and never up,
    /// in even pixels because the encoders reject odd sides.
    func outputSize(source: ForkMeetingPixelSize) -> ForkMeetingPixelSize {
        let width = max(2, source.width)
        let height = max(2, source.height)
        let box = maximumBox
        let scale = min(1, Double(box.width) / Double(width), Double(box.height) / Double(height))
        return ForkMeetingPixelSize(width: Self.even(Double(width) * scale),
                                    height: Self.even(Double(height) * scale))
    }

    private static func even(_ value: Double) -> Int {
        let whole = max(2, Int(value.rounded(.down)))
        return whole - whole % 2
    }
}

/// A picture size in whole pixels. Integers rather than `CGSize`, so the
/// arithmetic here never meets a fraction.
struct ForkMeetingPixelSize: Equatable, Hashable {
    var width: Int
    var height: Int
}

/// What the free space of the meetings' volume allows. Refusing to start is
/// a much better failure than filling the disk mid-meeting, so both ends are
/// guarded, like the official recorder does with the same two floors.
enum ForkMeetingDisk {
    /// Below this, a meeting does not start.
    static let minimumFreeBytesToStart: Int64 = 2_000_000_000
    /// Below this, a running meeting warns, with the minutes left.
    static let warningFreeBytes: Int64 = 2_000_000_000
    /// Below this, a running meeting stops cleanly and keeps its file.
    static let minimumFreeBytesToContinue: Int64 = 500_000_000
    /// How often the free space is read while a meeting records.
    static let checkInterval: TimeInterval = 15

    /// The floor to start: two gigabytes, or an hour and a half at this
    /// quality if that is more, so an hour fits with room for the final pass.
    static func requiredToStart(_ quality: ForkMeetingQuality) -> Int64 {
        max(minimumFreeBytesToStart, quality.estimatedBytesPerHour * 3 / 2)
    }

    /// `nil` free space means the volume could not be read: that is never
    /// taken for "enough".
    static func canStart(freeBytes: Int64?, quality: ForkMeetingQuality) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes >= requiredToStart(quality)
    }

    enum Level: Equatable {
        case enough
        /// The recording goes on; `minutesLeft` before it would stop.
        case low(minutesLeft: Int)
        /// Stop now, while the file can still be closed properly.
        case critical
    }

    static func level(freeBytes: Int64, quality: ForkMeetingQuality) -> Level {
        if freeBytes < minimumFreeBytesToContinue { return .critical }
        if freeBytes < warningFreeBytes { return .low(minutesLeft: minutesLeft(freeBytes: freeBytes, quality: quality)) }
        return .enough
    }

    /// Whole minutes of recording before the stop floor, rounded down.
    static func minutesLeft(freeBytes: Int64, quality: ForkMeetingQuality) -> Int {
        let usable = max(0, freeBytes - minimumFreeBytesToContinue)
        return Int(usable / max(1, quality.bytesPerSecond) / 60)
    }

    /// Whether the final pass may write its copy beside the master: the
    /// master's size again, a tenth more for the mixed track, and the stop
    /// floor kept free. Otherwise the master itself becomes the file.
    static func finalPassFits(freeBytes: Int64, masterBytes: Int64) -> Bool {
        let master = max(0, masterBytes)
        return freeBytes >= master + master / 10 + minimumFreeBytesToContinue
    }
}
