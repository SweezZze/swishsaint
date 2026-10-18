// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingQualityTests {
    static func run(_ suite: TestSuite) {
        presets(suite)
        sizes(suite)
        disk(suite)
    }

    private static func size(_ width: Int, _ height: Int) -> ForkMeetingPixelSize {
        ForkMeetingPixelSize(width: width, height: height)
    }

    private static func presets(_ suite: TestSuite) {
        suite.expect(ForkMeetingQuality.light.videoBitRate == 600_000
                        && ForkMeetingQuality.standard.videoBitRate == 1_200_000
                        && ForkMeetingQuality.high.videoBitRate == 2_500_000,
                     "light, standard and high encode the picture at 0.6, 1.2 and 2.5 Mbit/s")
        suite.expect(ForkMeetingQuality.light.maximumLines == 720 && ForkMeetingQuality.standard.maximumLines == 1080
                        && ForkMeetingQuality.high.maximumLines == 1080,
                     "light writes at most 720 lines, the others 1080")
        suite.expect(ForkMeetingQuality.Rates.frameRate == 30 && ForkMeetingQuality.keyframeInterval == 60,
                     "every preset records 30 frames a second with a keyframe every two seconds")
        suite.expect(ForkMeetingQuality.Rates.mixAudio == 96_000 && ForkMeetingQuality.Rates.sourceAudio == 64_000
                        && ForkMeetingQuality.Rates.sourceTrackCount == 2,
                     "the sound is a 96 kbit/s mix and two 64 kbit/s sources")
        suite.expect(ForkMeetingQuality.Rates.audioSampleRate >= 48_000,
                     "the sources are sampled high enough for 64 kbit/s AAC, which 16 kHz mono cannot reach")
        suite.expect(ForkMeetingQuality.standard.totalBitRate == 1_200_000 + 96_000 + 2 * 64_000,
                     "the size estimate counts every track of the file, not only the picture")
        let perHour = ForkMeetingQuality.allCases.map(\.estimatedGigabytesPerHour)
        suite.expect(perHour == perHour.sorted() && Set(perHour).count == 3,
                     "each preset costs more disk than the one before")
        suite.expect((0.5...0.7).contains(ForkMeetingQuality.standard.estimatedGigabytesPerHour)
                        && (1.1...1.3).contains(ForkMeetingQuality.high.estimatedGigabytesPerHour),
                     "an hour costs about 0.6 GB in standard and 1.2 GB in high")
        suite.expect(ForkMeetingQuality(stored: "high") == .high && ForkMeetingQuality(stored: "") == .standard
                        && ForkMeetingQuality(stored: "ultra") == .standard && ForkMeetingQuality(stored: nil) == .standard,
                     "an empty or unknown setting records in standard")
    }

    private static func sizes(_ suite: TestSuite) {
        suite.expect(ForkMeetingQuality.standard.outputSize(source: size(2880, 1800)) == size(1728, 1080),
                     "a Retina window is scaled down to 1080 lines, its shape kept")
        suite.expect(ForkMeetingQuality.light.outputSize(source: size(2880, 1800)) == size(1152, 720),
                     "light scales the same window down to 720 lines")
        suite.expect(ForkMeetingQuality.standard.outputSize(source: size(1280, 720)) == size(1280, 720)
                        && ForkMeetingQuality.high.outputSize(source: size(800, 600)) == size(800, 600),
                     "a small window is never enlarged")
        suite.expect(ForkMeetingQuality.standard.outputSize(source: size(1001, 563)) == size(1000, 562),
                     "odd sides become even, which the encoders require")
        suite.expect(ForkMeetingQuality.standard.outputSize(source: size(5120, 1440)) == size(1920, 540),
                     "an ultra-wide display is bounded by its width, not stretched over three times the pixels")
        let portrait = ForkMeetingQuality.standard.outputSize(source: size(1080, 1920))
        suite.expect(portrait.height <= 1080 && portrait.width % 2 == 0 && portrait.width >= 600,
                     "a portrait window fits the same box")
        for quality in ForkMeetingQuality.allCases {
            for source in [size(3456, 2234), size(1512, 982), size(2560, 1440), size(997, 1333), size(3, 3)] {
                let output = quality.outputSize(source: source)
                let ratio = Double(source.width) / Double(source.height)
                let kept = Double(output.width) / Double(output.height)
                suite.expect(output.width % 2 == 0 && output.height % 2 == 0 && output.width > 0 && output.height > 0
                                && output.width <= max(2, source.width) && output.height <= max(2, source.height)
                                && output.width <= quality.maximumBox.width && output.height <= quality.maximumBox.height
                                && (source.width < 100 || abs(kept - ratio) / ratio < 0.01),
                             "\(quality) of \(source.width)×\(source.height): even, never larger, in the box, same shape")
            }
        }
        suite.expect(ForkMeetingQuality.standard.outputSize(source: size(0, 0)) == size(2, 2),
                     "a window reported without a size still gives a valid picture")
    }

    private static func disk(_ suite: TestSuite) {
        let giga: Int64 = 1_000_000_000
        suite.expect(ForkMeetingQuality.allCases.allSatisfy { ForkMeetingDisk.requiredToStart($0) == 2 * giga },
                     "with these rates, starting asks for two gigabytes free")
        suite.expect(ForkMeetingQuality.allCases.allSatisfy {
                        ForkMeetingDisk.requiredToStart($0) >= $0.estimatedBytesPerHour * 3 / 2
                     },
                     "starting asks for at least an hour and a half at the chosen quality")
        suite.expect(!ForkMeetingDisk.canStart(freeBytes: 1_900_000_000, quality: .standard)
                        && ForkMeetingDisk.canStart(freeBytes: 2 * giga, quality: .standard),
                     "below two gigabytes a meeting does not start")
        suite.expect(!ForkMeetingDisk.canStart(freeBytes: nil, quality: .light),
                     "free space that could not be read never counts as enough")
        suite.expect(ForkMeetingDisk.level(freeBytes: 3 * giga, quality: .standard) == .enough,
                     "plenty of room says nothing")
        let perSecond = ForkMeetingQuality.standard.bytesPerSecond
        let expected = Int((1_500_000_000 - 500_000_000) / perSecond / 60)
        suite.expect(ForkMeetingDisk.level(freeBytes: 1_500_000_000, quality: .standard) == .low(minutesLeft: expected)
                        && expected > 60,
                     "under two gigabytes the pill tells the minutes left before the stop")
        suite.expect(ForkMeetingDisk.level(freeBytes: 500_000_000, quality: .standard) == .low(minutesLeft: 0)
                        && ForkMeetingDisk.level(freeBytes: 499_999_999, quality: .standard) == .critical,
                     "under 500 MB the recording stops")
        suite.expect(ForkMeetingDisk.minutesLeft(freeBytes: 1_500_000_000, quality: .high)
                        < ForkMeetingDisk.minutesLeft(freeBytes: 1_500_000_000, quality: .light),
                     "the same space lasts longer at a lighter quality")
        suite.expect(ForkMeetingDisk.finalPassFits(freeBytes: 2 * giga, masterBytes: giga)
                        && !ForkMeetingDisk.finalPassFits(freeBytes: 1_500_000_000, masterBytes: giga),
                     "the final pass needs the master's size again, plus the stop floor; otherwise the master is the file")
        suite.expect(ForkMeetingDisk.checkInterval == 15, "the free space is read every fifteen seconds")
    }
}
