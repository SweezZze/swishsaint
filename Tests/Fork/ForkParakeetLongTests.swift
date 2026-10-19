// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// A long recording read window by window, and its words with their times
/// (`ForkParakeetLong.swift`): what lets an hour be transcribed in 50 MB.
enum ForkParakeetLongTests {
    static func run(_ suite: TestSuite) {
        reader(suite)
        readerSamples(suite)
        words(suite)
    }

    /// Feeds a fixed array in reads of varying size.
    private final class Source: ForkParakeetSampleSource {
        /// Each sample is its own index: a window's samples tell where they came from.
        static let ramp: [Float] = (0..<(2 * 60 * 16_000)).map { Float($0) }
        let count: Int
        let sizes: [Int]
        var position = 0
        var turn = 0

        init(count: Int, sizes: [Int]) {
            self.count = min(count, Self.ramp.count)
            self.sizes = sizes
        }

        func read(into buffer: UnsafeMutableBufferPointer<Float>) throws -> Int {
            let size = min(buffer.count, sizes[turn % sizes.count], count - position)
            turn += 1
            guard size > 0, let target = buffer.baseAddress else { return 0 }
            Self.ramp.withUnsafeBufferPointer { ramp in
                if let base = ramp.baseAddress { target.update(from: base + position, count: size) }
            }
            position += size
            return size
        }
    }

    private static func steps(count: Int, sizes: [Int], readSize: Int = 64_000) -> [ForkParakeetWindowReader.Step] {
        var reader = ForkParakeetWindowReader(source: Source(count: count, sizes: sizes), readSize: readSize)
        var steps: [ForkParakeetWindowReader.Step] = []
        while let step = try? reader.next() { steps.append(step) }
        return steps
    }

    /// What `transcribe(_ samples:)` does with the same audio: one window
    /// up to 15 s, else the plan.
    private static func expected(count: Int) -> [ForkParakeetWindowReader.Step] {
        if count <= ForkParakeetShape.windowSamples { return [.whole(count: count)] }
        return ForkParakeetWindows.plan(totalSamples: count).map { .window($0) }
    }

    private static func reader(_ suite: TestSuite) {
        let window = ForkParakeetShape.windowSamples
        let chunk = ForkParakeetWindows.chunkSamples
        let stride = ForkParakeetWindows.strideSamples
        var lengths = [0, 1, 4_799, 4_800, chunk - 1, chunk, chunk + 1, window - 1, window, window + 1,
                       chunk + stride, chunk + stride + 1, 2 * stride + chunk, 445_440, 60 * 16_000, 120 * 16_000]
        // A fixed draw of 40 lengths up to two minutes, the same at every run.
        var seed: UInt64 = 0x5EED
        for _ in 0..<40 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            lengths.append(Int(seed >> 33) % (120 * 16_000))
        }
        var mismatches: [String] = []
        for length in lengths {
            for sizes in [[64_000], [300_000], [4_096, 17, 100_003], [238_080]] {
                if steps(count: length, sizes: sizes) != expected(count: length) {
                    mismatches.append("\(length) by \(sizes)")
                }
            }
        }
        for length in [0, 1, 4_799, 4_800, window, window + 1] {
            if steps(count: length, sizes: [1], readSize: 1) != expected(count: length) {
                mismatches.append("\(length) one at a time")
            }
        }
        suite.expect(mismatches.isEmpty,
                     "reading as it goes, without the length, gives exactly the windows of the whole array: \(mismatches)")

        var reader = ForkParakeetWindowReader(source: Source(count: 45 * 16_000, sizes: [64_000]))
        var count = 0
        while (try? reader.next()) != nil { count += 1 }
        suite.expect(reader.peakBufferCount <= window + 1 + 64_000,
                     "only one window and one read are ever held, however long the audio")
        suite.expect(reader.samplesRead == 45 * 16_000 && count == expected(count: reader.samplesRead).count,
                     "every sample is read once, and the reader says how many")
    }

    private static func readerSamples(_ suite: TestSuite) {
        var reader = ForkParakeetWindowReader(source: Source(count: 50 * 16_000, sizes: [7_777, 64_000]))
        var right = true
        var windows = 0
        while let step = try? reader.next() {
            switch step {
            case let .window(window):
                let slice = reader.samples(window.start, window.end)
                right = right && slice.count == window.sampleCount && slice.first == Float(window.start)
                    && slice.last == Float(window.end - 1)
                windows += 1
            case .whole:
                right = false
            }
        }
        suite.expect(right && windows == 4, "each window hands the model its own samples, context included")

        var short = ForkParakeetWindowReader(source: Source(count: 3 * 16_000, sizes: [1_000]))
        if case let .whole(count)? = try? short.next() {
            suite.expect(count == 48_000 && short.samples(0, count).last == 47_999 && (try? short.next()) == nil,
                         "three seconds are read whole, as a dictation is")
        } else {
            suite.expect(false, "three seconds are read whole, as a dictation is")
        }
    }

    private static func words(_ suite: TestSuite) {
        // The shipped vocabulary starts words with a plain space; the
        // SentencePiece one with "▁". Both open a word.
        let vocabulary = [1: " Bon", 2: "jour", 3: ",", 4: "\u{2581}la", 5: " semaine", 6: " ?", 7: " Con", 8: "to",
                          9: "so", 10: ".", 11: " 4", 12: ",2", 13: " %"]
        func token(_ id: Int, _ frame: Int, _ duration: Int = 1, _ confidence: Float = 0.9) -> ForkParakeetToken {
            ForkParakeetToken(id: id, frame: frame, confidence: confidence, duration: duration)
        }
        let tokens = [token(1, 10), token(2, 12, 2), token(3, 14, 0), token(4, 20), token(5, 22, 3), token(6, 26)]
        let heard = ForkParakeetText.words(of: tokens, vocabulary: vocabulary)
        suite.expect(heard.map(\.text) == ["Bonjour,", "la", "semaine ?"],
                     "pieces join into words, a space or ▁ opens one, and punctuation alone joins the word before")
        suite.expect(heard.map(\.text).joined(separator: " ") == ForkParakeetText.text(of: tokens, vocabulary: vocabulary),
                     "the words read back as the dictation's text")
        let frame = ForkParakeetText.frameSeconds
        suite.expect(abs(heard[0].start - 10 * frame) < 1e-9 && abs(heard[0].end - 14 * frame) < 1e-9,
                     "a word starts at its first token and ends where its last spoken one does, the comma aside")
        suite.expect(abs(heard[2].end - 25 * frame) < 1e-9,
                     "a question mark heard later does not stretch the word")

        // "Contoso." with its full stop 3 s later, after the silence.
        let late = ForkParakeetText.words(of: [token(7, 100), token(8, 101), token(9, 102, 2), token(10, 140, 4)],
                                          vocabulary: vocabulary)
        suite.expect(late.count == 1 && late[0].text == "Contoso." && abs(late[0].end - 104 * frame) < 1e-9,
                     "a sentence's last word ends on its last spoken token, not on the full stop after the silence")
        let zero = ForkParakeetText.words(of: [token(11, 50, 0), token(12, 51, 0), token(13, 52, 0)], vocabulary: vocabulary)
        suite.expect(zero.map(\.text) == ["4,2 %"] && zero[0].end > zero[0].start,
                     "a word whose tokens predicted no duration still lasts a frame")
        suite.expect(abs(ForkParakeetText.words(of: [token(1, 0, 1, 0.5), token(2, 1, 1, 1)], vocabulary: vocabulary)[0]
                            .confidence - 0.75) < 1e-6,
                     "a word's confidence is its tokens' mean")
        suite.expect(ForkParakeetText.words(of: [], vocabulary: vocabulary).isEmpty
                        && ForkParakeetText.words(of: [token(ForkParakeetShape.blankId, 0)], vocabulary: vocabulary).isEmpty,
                     "nothing heard gives no words")
        let leading = ForkParakeetText.words(of: [token(6, 0), token(1, 2), token(2, 3)], vocabulary: vocabulary)
        suite.expect(leading.map(\.text) == ["?", "Bonjour"],
                     "punctuation with no word before it stays, rather than vanish")
        let transcript = ForkParakeetTimedTranscript(words: heard, audioDuration: 2, processingTime: 0.1, windowCount: 1)
        suite.expect(transcript.text == "Bonjour, la semaine ?", "a timed transcript reads as its words")
    }
}
