// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

// The model-free half of a long transcription (a meeting's track): where the
// samples come from, the windows read one at a time, and the words with their
// times. The CoreML half is `ForkParakeetEngine.transcribeLong`.

/// Where a long transcription reads its audio: 16 kHz mono samples, in
/// order, a few seconds at a time. A meeting reads its "Meeting" or
/// "Microphone" track through AVAssetReader, which decodes the AAC and
/// resamples on the way.
protocol ForkParakeetSampleSource: AnyObject {
    /// Fills the start of `buffer` with the next samples and returns how many
    /// it wrote; 0 means the audio is over.
    func read(into buffer: UnsafeMutableBufferPointer<Float>) throws -> Int
}

/// One word and its place in the audio.
struct ForkParakeetWord: Equatable {
    /// The word with the punctuation that follows it ("Contoso," "4,2 %"),
    /// without the space before it.
    var text: String
    /// Seconds from the start of the audio.
    var start: TimeInterval
    var end: TimeInterval
    /// Mean probability of its tokens.
    var confidence: Float
}

/// What Parakeet heard in a long recording, word by word.
struct ForkParakeetTimedTranscript: Equatable {
    var words: [ForkParakeetWord]
    var audioDuration: TimeInterval
    var processingTime: TimeInterval
    var windowCount: Int

    var text: String { words.map(\.text).joined(separator: " ") }
}

extension ForkParakeetText {
    static let frameSeconds = Double(ForkParakeetShape.samplesPerFrame) / Double(ForkParakeetShape.sampleRate)

    /// Groups SentencePiece tokens into words.
    ///
    /// - A piece that starts with "▁", or with a plain space as in the
    ///   vocabulary file Parakeet ships, opens a word; any other piece (the
    ///   rest of a word, a comma, "%") extends the current one.
    /// - A piece of punctuation alone joins the word before it: French
    ///   spacing gives "semaine ?" as a space-led "?", which would otherwise
    ///   be a word of its own.
    /// - A word starts at its first token's frame and ends where its last
    ///   **spoken** token's predicted duration ends (one frame at least): the
    ///   final "." of a sentence often comes seconds later, after the silence,
    ///   and would stretch the word over it.
    static func words(of tokens: [ForkParakeetToken], vocabulary: [Int: String]) -> [ForkParakeetWord] {
        var words: [ForkParakeetWord] = []
        var text = ""
        var first: ForkParakeetToken?
        var lastSpoken: ForkParakeetToken?
        var confidenceSum: Float = 0
        var count = 0

        func isSpoken(_ text: String) -> Bool {
            text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }

        func close() {
            guard let first else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if !isSpoken(trimmed), !words.isEmpty {
                words[words.count - 1].text += (text.hasPrefix(" ") ? " " : "") + trimmed
                return
            }
            let last = lastSpoken ?? first
            words.append(ForkParakeetWord(text: trimmed,
                                          start: Double(first.frame) * frameSeconds,
                                          end: Double(last.frame + max(1, last.duration)) * frameSeconds,
                                          confidence: confidenceSum / Float(max(1, count))))
        }

        for token in tokens {
            guard let piece = vocabulary[token.id], !piece.isEmpty else { continue }
            if first == nil || ForkParakeetStitcher.startsWord(piece) {
                close()
                text = ""
                first = token
                lastSpoken = nil
                confidenceSum = 0
                count = 0
            }
            text += piece.replacingOccurrences(of: ForkParakeetShape.wordBoundary, with: " ")
            if isSpoken(piece) { lastSpoken = token }
            confidenceSum += token.confidence
            count += 1
        }
        close()
        return words
    }
}

/// Reads a sample source window by window: the windows of
/// `ForkParakeetWindows.plan`, without knowing the length in advance (an AAC
/// track's is only approximately known). Each window looks one sample past
/// its end to know whether it is the last. Only the current window, plus
/// what one read brings, stays in memory: about 1.2 MB, whatever the length.
struct ForkParakeetWindowReader {
    enum Step: Equatable {
        /// The whole audio fits in one model window: `count` samples, to be
        /// read with `samples(0, count)`.
        case whole(count: Int)
        case window(ForkParakeetWindow)
    }

    let source: ForkParakeetSampleSource
    let readSize: Int
    private(set) var buffer: [Float] = []
    /// The audio index of `buffer[0]`.
    private(set) var bufferStart = 0
    private(set) var samplesRead = 0
    /// The most samples held at once, for the checks.
    private(set) var peakBufferCount = 0
    private var ended = false
    private var finished = false
    private var produced = 0
    private var nextStart = 0
    private var scratch: [Float]

    init(source: ForkParakeetSampleSource, readSize: Int = 4 * ForkParakeetShape.sampleRate) {
        self.source = source
        self.readSize = max(1, readSize)
        scratch = [Float](repeating: 0, count: max(1, readSize))
    }

    private var available: Int { bufferStart + buffer.count }

    private mutating func fill(upTo sample: Int) throws {
        while !ended && available < sample {
            let count = try scratch.withUnsafeMutableBufferPointer { try source.read(into: $0) }
            if count <= 0 {
                ended = true
            } else {
                let kept = min(count, scratch.count)
                buffer.append(contentsOf: scratch[0..<kept])
                samplesRead += kept
                peakBufferCount = max(peakBufferCount, buffer.count)
            }
        }
    }

    private mutating func drop(before sample: Int) {
        let count = min(buffer.count, max(0, sample - bufferStart))
        guard count > 0 else { return }
        buffer.removeFirst(count)
        bufferStart += count
    }

    /// The next step, `nil` once the audio is over.
    mutating func next() throws -> Step? {
        guard !finished else { return nil }
        if produced == 0 {
            try fill(upTo: ForkParakeetShape.windowSamples + 1)
            if ended && available <= ForkParakeetShape.windowSamples {
                finished = true
                return .whole(count: available)
            }
        }
        let start = nextStart
        let context = produced == 0 ? 0 : ForkParakeetWindows.contextSamples
        // What the windows before needed goes before more is read.
        drop(before: start - context)
        let candidateEnd = start + ForkParakeetWindows.chunkSamples
        try fill(upTo: candidateEnd + 1)
        let isLast = ended && candidateEnd >= available
        let end = isLast ? available : candidateEnd
        guard end > start else {
            finished = true
            return nil
        }
        produced += 1
        if isLast { finished = true } else { nextStart += ForkParakeetWindows.strideSamples }
        return .window(ForkParakeetWindow(start: start - context, end: end, contextSamples: context, isLast: isLast))
    }

    /// The samples `from..<to` (audio indexes), which `next()` just made
    /// sure are held.
    func samples(_ from: Int, _ to: Int) -> ArraySlice<Float> {
        buffer[(from - bufferStart)..<(to - bufferStart)]
    }
}
