// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial
// Portions adapted from FluidAudio (Apache-2.0), https://github.com/FluidInference/FluidAudio

import Foundation

// The model-free half of Parakeet TDT 0.6B v3: the greedy token-and-duration
// loop, the 15 s windows of a long dictation and how they are stitched back,
// the script filter and the SentencePiece text. Everything here follows
// FluidAudio 0.15.5 step by step (TdtDecoderV3, ChunkProcessor, SequenceMatcher,
// TokenLanguageFilter), so the same audio gives the same text; the CoreML half
// lives in ForkParakeetEngine.

/// The fixed shape of the CoreML export.
enum ForkParakeetShape {
    static let sampleRate = 16_000
    /// One preprocessor window: 15 s.
    static let windowSamples = 240_000
    /// One encoder frame: 80 ms (hop 160 × subsampling 8).
    static let samplesPerFrame = 1_280
    static let melHop = 160
    static let encoderHidden = 1_024
    static let decoderHidden = 640
    static let decoderLayers = 2
    /// 8192 regular SentencePiece tokens, then the blank.
    static let blankId = 8_192
    /// The duration head's five bins, in frames.
    static let durationBins = [0, 1, 2, 3, 4]
    /// Below 0.3 s the model is not asked anything.
    static let minimumSamples = 4_800
    static let wordBoundary = "\u{2581}"

    static func frames(forSamples samples: Int) -> Int {
        (samples + samplesPerFrame - 1) / samplesPerFrame
    }
}

// MARK: - Joint steps

/// What the joint network says for one encoder frame.
struct ForkParakeetJointDecision: Equatable {
    var token: Int
    var probability: Float
    var durationBin: Int
    /// The 64 best tokens and their logits, only when the script filter asks.
    var topKIds: [Int] = []
    var topKLogits: [Float] = []
}

/// The two networks the TDT loop drives. The decoder keeps one LSTM state and
/// its last output; `joint` reads that output with an encoder frame.
protocol ForkParakeetJointStepping: AnyObject {
    /// Zeroes the LSTM state, before a new utterance or window.
    func resetDecoder() throws
    /// Feeds `token` to the LSTM; its output becomes the context of `joint`.
    func advanceDecoder(with token: Int) throws
    /// Runs the joint network on encoder frame `frame` (0-based).
    func joint(atFrame frame: Int, topK: Bool) throws -> ForkParakeetJointDecision
}

/// One emitted token: its id, the encoder frame it was read at (from the start
/// of the audio), its probability and the duration it predicted.
struct ForkParakeetToken: Equatable {
    var id: Int
    var frame: Int
    var confidence: Float
    var duration: Int
}

enum ForkParakeetDecodingError: Error, Equatable {
    case durationOutOfRange(Int)
}

// MARK: - Script filter

enum ForkParakeetScript: Equatable {
    case latin
    case cyrillic
    case greek
}

/// The languages Parakeet v3 was trained on, and the script each one is
/// written in. Parakeet detects the language by itself: a known language only
/// keeps tokens of the wrong alphabet out (Cyrillic in Polish, say), and keeps
/// a few English words out of other Latin languages.
enum ForkParakeetLanguages {
    static let scripts: [String: ForkParakeetScript] = [
        "en": .latin, "es": .latin, "fr": .latin, "de": .latin, "it": .latin, "pt": .latin,
        "ro": .latin, "nl": .latin, "da": .latin, "sv": .latin, "fi": .latin, "hu": .latin,
        "et": .latin, "lv": .latin, "lt": .latin, "mt": .latin, "pl": .latin, "cs": .latin,
        "sk": .latin, "sl": .latin, "hr": .latin, "bs": .latin,
        "ru": .cyrillic, "uk": .cyrillic, "be": .cyrillic, "bg": .cyrillic, "sr": .cyrillic,
        "el": .greek,
    ]

    /// The 25 languages of the model card.
    static let supported: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// "fr", "fr-FR" or "fr_CA" → "fr".
    static func baseCode(_ identifier: String) -> String {
        let lowered = identifier.lowercased()
        let end = lowered.firstIndex { $0 == "-" || $0 == "_" } ?? lowered.endIndex
        return String(lowered[..<end])
    }

    static func isSupported(_ identifier: String) -> Bool {
        supported.contains(baseCode(identifier))
    }
}

/// FluidAudio's per-step language filter: when the best token is in another
/// alphabet, the best top-K token in the right one replaces it; in a Latin
/// language other than English, a short list of English-only words is skipped
/// the same way.
struct ForkParakeetScriptFilter {
    let script: ForkParakeetScript
    let blocksEnglish: Bool
    let vocabulary: [Int: String]

    /// Space-prefixed English words that are next to impossible elsewhere.
    static let englishOnlyIds: Set<Int> = [
        506, 1502, 575, 1976, 2530, 1180, 3247, 1868, 1050, 7603, 1974, 5831, 1647, 3109,
        924, 4020, 4250, 1714, 4908, 4223, 6167, 2783, 4396, 3357, 4611, 3470, 6843, 4333,
        4980, 1491, 3592, 2681, 1960, 547, 2336, 750, 1842, 3285, 3629, 1103, 4384, 1535,
        4421, 5726,
    ]

    init?(languageCode: String?, vocabulary: [Int: String]) {
        guard let languageCode else { return nil }
        let code = ForkParakeetLanguages.baseCode(languageCode)
        guard let script = ForkParakeetLanguages.scripts[code] else { return nil }
        self.script = script
        self.blocksEnglish = script == .latin && code != "en"
        self.vocabulary = vocabulary
    }

    func apply(label: inout Int, score: inout Float, decision: ForkParakeetJointDecision) {
        let ids = decision.topKIds
        let logits = decision.topKLogits
        let blank = ForkParakeetShape.blankId
        if label != blank, !ids.isEmpty, let text = vocabulary[label],
           !Self.matches(text, script: script),
           let filtered = Self.bestTopK(ids: ids, logits: logits, vocabulary: vocabulary, script: script) {
            label = filtered.token
            score = ForkParakeetTdt.clamp(filtered.probability)
        }
        if blocksEnglish, !ids.isEmpty {
            skipEnglish(label: &label, score: &score, ids: ids, logits: logits)
        }
    }

    private func skipEnglish(label: inout Int, score: inout Float, ids: [Int], logits: [Float]) {
        let blank = ForkParakeetShape.blankId
        guard label != blank, Self.englishOnlyIds.contains(label) else { return }
        var bestIndex = -1
        var bestLogit = -Float.infinity
        for index in 0..<min(ids.count, logits.count) {
            let id = ids[index]
            guard id != blank, !Self.englishOnlyIds.contains(id) else { continue }
            if let text = vocabulary[id], Self.matches(text, script: .latin),
               bestIndex < 0 || logits[index] > bestLogit {
                bestLogit = logits[index]
                bestIndex = index
            }
        }
        guard bestIndex >= 0 else { return }
        label = ids[bestIndex]
        var maxLogit = -Float.infinity
        for logit in logits where logit > maxLogit { maxLogit = logit }
        var sum: Float = 0
        for logit in logits { sum += expf(logit - maxLogit) }
        score = sum > 0 ? expf(bestLogit - maxLogit) / sum : 0
    }

    static func matches(_ text: String, script: ForkParakeetScript) -> Bool {
        let cleaned = text.replacingOccurrences(of: ForkParakeetShape.wordBoundary, with: "")
        guard !cleaned.isEmpty else { return true }
        let scalars = cleaned.unicodeScalars
        func isAsciiLetter(_ value: UInt32) -> Bool {
            (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
        }
        switch script {
        case .latin:
            return scalars.allSatisfy {
                let value = $0.value
                return (value >= 0x0020 && value <= 0x007F) || (value >= 0x00A0 && value <= 0x024F)
                    || (value >= 0x0300 && value <= 0x036F) || (value >= 0x1E00 && value <= 0x1EFF)
            }
        case .cyrillic:
            return scalars.allSatisfy {
                let value = $0.value
                if value >= 0x0400 && value <= 0x04FF { return true }
                return value >= 0x0020 && value <= 0x007F && !isAsciiLetter(value)
            }
        case .greek:
            return scalars.allSatisfy {
                let value = $0.value
                if (value >= 0x0370 && value <= 0x03FF) || (value >= 0x1F00 && value <= 0x1FFF)
                    || (value >= 0x0300 && value <= 0x036F) { return true }
                return value >= 0x0020 && value <= 0x007F && !isAsciiLetter(value)
            }
        }
    }

    static func bestTopK(ids: [Int], logits: [Float], vocabulary: [Int: String],
                         script: ForkParakeetScript) -> (token: Int, probability: Float)? {
        let count = min(ids.count, logits.count)
        guard count > 0 else { return nil }
        var bestIndex = -1
        var bestLogit = -Float.infinity
        for index in 0..<count {
            guard let text = vocabulary[ids[index]], matches(text, script: script) else { continue }
            if bestIndex < 0 || logits[index] > bestLogit {
                bestLogit = logits[index]
                bestIndex = index
            }
        }
        guard bestIndex >= 0 else { return nil }
        var maxLogit = -Float.infinity
        for index in 0..<count where logits[index] > maxLogit { maxLogit = logits[index] }
        guard maxLogit.isFinite else { return (ids[bestIndex], 0) }
        var sum: Float = 0
        for index in 0..<count { sum += expf(logits[index] - maxLogit) }
        guard sum > 0 else { return (ids[bestIndex], 0) }
        return (ids[bestIndex], max(0, min(1, expf(logits[bestIndex] - maxLogit) / sum)))
    }
}

// MARK: - TDT loop

/// Greedy token-and-duration decoding of one window (TdtDecoderV3).
struct ForkParakeetTdt {
    var maxSymbolsPerStep = 10
    var maxTokensPerWindow = 150
    var consecutiveBlankLimit = 5
    var filter: ForkParakeetScriptFilter?

    static func clamp(_ probability: Float) -> Float {
        guard probability.isFinite else { return 0 }
        return max(0, min(1, probability))
    }

    /// - Parameters:
    ///   - encoderLength: the `encoder_length` the encoder reported.
    ///   - frameCount: frames that can be read (encoder length, at most the tensor's).
    ///   - audioFrames: frames that hold audio rather than padding.
    ///   - contextFrames: leading frames already decoded by the previous window.
    ///   - isLast: the last window also flushes the tokens pending at the end.
    ///   - frameOffset: the window's first frame, from the start of the audio.
    func decode(_ steps: ForkParakeetJointStepping, encoderLength: Int, frameCount: Int,
                audioFrames: Int, contextFrames: Int, isLast: Bool,
                frameOffset: Int) throws -> [ForkParakeetToken] {
        guard encoderLength > 1, frameCount > 0 else { return [] }
        let blank = ForkParakeetShape.blankId
        let wantsTopK = filter != nil

        var time = contextFrames
        let length = min(encoderLength, audioFrames)
        guard time < length else { return [] }
        let lastFrame = length - 1
        var safeTime = min(time, lastFrame)
        var active = true
        var labelTime = time

        try steps.resetDecoder()
        try steps.advanceDecoder(with: blank)

        var tokens: [ForkParakeetToken] = []
        var lastEmissionTime = -1
        var emissionsHere = 0
        var emitted = 0

        func judge(_ decision: ForkParakeetJointDecision) throws -> (label: Int, score: Float, duration: Int) {
            var label = decision.token
            var score = Self.clamp(decision.probability)
            filter?.apply(label: &label, score: &score, decision: decision)
            return (label, score, try Self.duration(decision.durationBin))
        }

        while active {
            var (label, score, duration) = try judge(try steps.joint(atFrame: safeTime, topK: wantsTopK))
            var isBlank = label == blank
            if !isBlank && duration == 0 && time == lastEmissionTime && emissionsHere >= 1 {
                duration = 1
            }
            if isBlank && duration == 0 {
                duration = 1
            }
            labelTime = time
            time += duration
            safeTime = min(time, lastFrame)
            active = time < length
            var skipping = active && isBlank

            // Silence: keep the decoder context and hop through blank frames.
            while skipping {
                labelTime = time
                (label, score, duration) = try judge(try steps.joint(atFrame: safeTime, topK: wantsTopK))
                isBlank = label == blank
                if isBlank && duration == 0 {
                    duration = 1
                }
                time += duration
                safeTime = min(time, lastFrame)
                active = time < length
                skipping = active && isBlank
            }

            if active && label != blank {
                emitted += 1
                if emitted > maxTokensPerWindow { break }
                tokens.append(ForkParakeetToken(id: label, frame: labelTime + frameOffset,
                                                confidence: score, duration: duration))
                try steps.advanceDecoder(with: label)
                if labelTime == lastEmissionTime {
                    emissionsHere += 1
                } else {
                    lastEmissionTime = labelTime
                    emissionsHere = 1
                }
                if emissionsHere >= maxSymbolsPerStep {
                    time = min(time + 1, lastFrame)
                    safeTime = min(time, lastFrame)
                    emissionsHere = 0
                    lastEmissionTime = -1
                }
            }
            active = time < length
        }

        guard isLast else { return tokens }

        // The end of the audio: a few more looks around the last frames.
        var extraSteps = 0
        var blanksInRow = 0
        var finalTime = time
        while extraSteps < maxSymbolsPerStep && blanksInRow < consecutiveBlankLimit {
            let candidates = [
                min(finalTime, frameCount - 1),
                min(length - 1, frameCount - 1),
                min(max(0, length - 2), frameCount - 1),
            ]
            let decision = try steps.joint(atFrame: candidates[extraSteps % candidates.count], topK: wantsTopK)
            let duration = try Self.duration(decision.durationBin)
            if decision.token == blank {
                blanksInRow += 1
            } else {
                blanksInRow = 0
                tokens.append(ForkParakeetToken(id: decision.token,
                                                frame: min(finalTime, length - 1) + frameOffset,
                                                confidence: Self.clamp(decision.probability),
                                                duration: duration))
                try steps.advanceDecoder(with: decision.token)
            }
            finalTime = min(finalTime + max(1, duration), length)
            extraSteps += 1
        }
        return tokens
    }

    static func duration(_ bin: Int) throws -> Int {
        guard ForkParakeetShape.durationBins.indices.contains(bin) else {
            throw ForkParakeetDecodingError.durationOutOfRange(bin)
        }
        return ForkParakeetShape.durationBins[bin]
    }
}

// MARK: - Windows

/// One 15 s window of a long dictation.
struct ForkParakeetWindow: Equatable {
    /// First sample sent to the model, context included.
    var start: Int
    /// One past the last sample.
    var end: Int
    /// Leading samples that only give the spectrogram its left edge.
    var contextSamples: Int
    var isLast: Bool

    var sampleCount: Int { end - start }
    var frameOffset: Int { (start + contextSamples) / ForkParakeetShape.samplesPerFrame }
    var contextFrames: Int { contextSamples / ForkParakeetShape.samplesPerFrame }
    var audioFrames: Int { ForkParakeetShape.frames(forSamples: sampleCount - contextSamples) }
}

enum ForkParakeetWindows {
    /// 1 frame of spectrogram context before each window after the first.
    static let contextSamples = ForkParakeetShape.samplesPerFrame
    /// Each window holds 186 frames (14.88 s) of new audio…
    static let chunkSamples: Int = {
        let raw = max(ForkParakeetShape.windowSamples - contextSamples - ForkParakeetShape.melHop,
                      ForkParakeetShape.samplesPerFrame)
        return raw / ForkParakeetShape.samplesPerFrame * ForkParakeetShape.samplesPerFrame
    }()
    /// …and overlaps the previous one by 2 s.
    static let overlapSeconds = 2.0
    static let overlapSamples: Int = {
        let requested = Int(overlapSeconds * Double(ForkParakeetShape.sampleRate))
        let capped = min(requested, chunkSamples / 2)
        return capped / ForkParakeetShape.samplesPerFrame * ForkParakeetShape.samplesPerFrame
    }()
    static let strideSamples: Int = {
        let raw = max(chunkSamples - overlapSamples, ForkParakeetShape.samplesPerFrame)
        return raw / ForkParakeetShape.samplesPerFrame * ForkParakeetShape.samplesPerFrame
    }()

    /// The windows of an audio longer than one model window.
    static func plan(totalSamples: Int) -> [ForkParakeetWindow] {
        var windows: [ForkParakeetWindow] = []
        var start = 0
        while start < totalSamples {
            let candidateEnd = start + chunkSamples
            let isLast = candidateEnd >= totalSamples
            let end = isLast ? totalSamples : candidateEnd
            if end <= start { break }
            let context = windows.isEmpty ? 0 : contextSamples
            windows.append(ForkParakeetWindow(start: start - context, end: end,
                                              contextSamples: context, isLast: isLast))
            if isLast { break }
            start += strideSamples
        }
        return windows
    }
}

// MARK: - Stitching windows

/// Merges the tokens of overlapping windows (ChunkProcessor.mergeChunks and
/// collapseSeamWordDuplicates).
struct ForkParakeetStitcher {
    let vocabulary: [Int: String]
    let spliceSafeIds: Set<Int>?
    let caseVariantIds: [Int: Int]?

    private let frameSeconds = Double(ForkParakeetShape.samplesPerFrame) / Double(ForkParakeetShape.sampleRate)
    private var overlapSeconds: Double { ForkParakeetWindows.overlapSeconds }

    init(vocabulary: [Int: String]) {
        self.vocabulary = vocabulary
        guard !vocabulary.isEmpty else {
            spliceSafeIds = nil
            caseVariantIds = nil
            return
        }
        var safe = Set<Int>()
        var groups: [String: [Int]] = [:]
        for id in vocabulary.keys.sorted() {
            let piece = vocabulary[id] ?? ""
            if Self.isSpliceSafe(piece) { safe.insert(id) }
            groups[piece.lowercased(), default: []].append(id)
        }
        var canonical: [Int: Int] = [:]
        for (folded, ids) in groups where ids.count > 1 {
            let chosen = ids.first { vocabulary[$0] == folded } ?? ids.min() ?? ids[0]
            for id in ids { canonical[id] = chosen }
        }
        spliceSafeIds = safe
        caseVariantIds = canonical.isEmpty ? nil : canonical
    }

    /// A piece that can start a splice: a word start, or pure punctuation.
    static func isSpliceSafe(_ piece: String) -> Bool {
        guard !piece.isEmpty else { return false }
        if startsWord(piece) { return true }
        return piece.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }

    static func startsWord(_ piece: String) -> Bool {
        piece.hasPrefix(ForkParakeetShape.wordBoundary) || piece.hasPrefix(" ")
    }

    func stitch(_ windows: [[ForkParakeetToken]]) -> [ForkParakeetToken] {
        guard var merged = windows.first else { return [] }
        if windows.count > 1 {
            for window in windows.dropFirst() {
                merged = merge(merged, window)
            }
            if merged.count > 1 { merged.sort { $0.frame < $1.frame } }
            return collapseSeamDuplicates(merged)
        }
        if merged.count > 1 { merged.sort { $0.frame < $1.frame } }
        return merged
    }

    private struct Indexed {
        let index: Int
        let token: ForkParakeetToken
        let start: Double
    }

    func merge(_ left: [ForkParakeetToken], _ right: [ForkParakeetToken]) -> [ForkParakeetToken] {
        guard let leftLast = left.last, let rightFirst = right.first else {
            return left.isEmpty ? right : left
        }
        let leftEnd = Double(leftLast.frame) * frameSeconds + frameSeconds
        let rightStart = Double(rightFirst.frame) * frameSeconds
        if leftEnd <= rightStart { return left + right }

        let overlapLeft: [Indexed] = left.enumerated().compactMap { offset, token in
            let start = Double(token.frame) * frameSeconds
            guard start + frameSeconds > rightStart - overlapSeconds else { return nil }
            return Indexed(index: offset, token: token, start: start)
        }
        let overlapRight: [Indexed] = right.enumerated().compactMap { offset, token in
            let start = Double(token.frame) * frameSeconds
            guard start < leftEnd + overlapSeconds else { return nil }
            return Indexed(index: offset, token: token, start: start)
        }
        guard overlapLeft.count >= 2 && overlapRight.count >= 2 else {
            return mergeByMidpoint(left, right, leftEnd: leftEnd, rightStart: rightStart)
        }

        let tolerance = overlapSeconds / 2
        let matches: (Indexed, Indexed) -> Bool = { l, r in
            sameToken(l.token.id, r.token.id) && abs(l.start - r.start) < tolerance
        }
        let minimumPairs = max(overlapLeft.count / 2, 1)
        let contiguous = Self.contiguousMatches(overlapLeft, overlapRight, matches)
        if contiguous.count >= minimumPairs {
            return mergeUsing(contiguous, overlapLeft, overlapRight, left, right)
        }
        let common = Self.longestCommonSubsequence(overlapLeft, overlapRight, matches)
        guard !common.isEmpty else {
            return mergeByMidpoint(left, right, leftEnd: leftEnd, rightStart: rightStart)
        }
        return mergeUsing(common, overlapLeft, overlapRight, left, right)
    }

    private func sameToken(_ left: Int, _ right: Int) -> Bool {
        if left == right { return true }
        guard let caseVariantIds, let lhs = caseVariantIds[left], let rhs = caseVariantIds[right] else {
            return false
        }
        return lhs == rhs
    }

    /// The longest run of consecutive matches (SequenceMatcher.findContiguousMatches).
    static func contiguousMatches<T>(_ left: [T], _ right: [T],
                                     _ matches: (T, T) -> Bool) -> [(Int, Int)] {
        var best: [(Int, Int)] = []
        for i in 0..<left.count {
            for j in 0..<right.count where matches(left[i], right[j]) {
                var current: [(Int, Int)] = []
                var k = i
                var l = j
                while k < left.count && l < right.count && matches(left[k], right[l]) {
                    current.append((k, l))
                    k += 1
                    l += 1
                }
                if current.count > best.count { best = current }
            }
        }
        return best
    }

    /// SequenceMatcher.findLongestCommonSubsequence, same tie-breaking.
    static func longestCommonSubsequence<T>(_ left: [T], _ right: [T],
                                            _ matches: (T, T) -> Bool) -> [(Int, Int)] {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in 1...left.count {
            for j in 1...right.count {
                if matches(left[i - 1], right[j - 1]) {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = left.count
        var j = right.count
        while i > 0 && j > 0 {
            if matches(left[i - 1], right[j - 1]) {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if table[i - 1][j] > table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    private func mergeUsing(_ pairs: [(Int, Int)], _ overlapLeft: [Indexed], _ overlapRight: [Indexed],
                            _ left: [ForkParakeetToken], _ right: [ForkParakeetToken]) -> [ForkParakeetToken] {
        let leftIndices = pairs.map { overlapLeft[$0.0].index }
        let rightIndices = pairs.map { overlapRight[$0.1].index }
        var result: [ForkParakeetToken] = []
        if let firstLeft = leftIndices.first, firstLeft > 0 {
            result.append(contentsOf: left[..<firstLeft])
        }
        for index in 0..<pairs.count {
            let leftIndex = leftIndices[index]
            let rightIndex = rightIndices[index]
            result.append(left[leftIndex])
            guard index < pairs.count - 1 else { continue }
            let nextLeft = leftIndices[index + 1]
            let nextRight = rightIndices[index + 1]
            let gapLeft = nextLeft > leftIndex + 1 ? Array(left[(leftIndex + 1)..<nextLeft]) : []
            let gapRight = nextRight > rightIndex + 1 ? Array(right[(rightIndex + 1)..<nextRight]) : []
            result.append(contentsOf: gapRight.count > gapLeft.count ? gapRight : gapLeft)
        }
        guard let lastRight = rightIndices.last, lastRight + 1 < right.count else { return result }
        let tail = right[(lastRight + 1)...]
        guard let safe = spliceSafeIds, let firstTail = tail.first, !safe.contains(firstTail.id) else {
            result.append(contentsOf: tail)
            return result
        }
        // The tail starts inside a word: take the whole word from one side.
        if let wordStart = Self.wordStart(in: right, endingAt: lastRight, safe: safe),
           Self.popLastWord(from: &result, safe: safe) {
            result.append(contentsOf: right[wordStart...])
            return result
        }
        if let lastLeft = leftIndices.last {
            var cursor = lastLeft + 1
            while cursor < left.count, !safe.contains(left[cursor].id) {
                result.append(left[cursor])
                cursor += 1
            }
        }
        if let resume = tail.firstIndex(where: { safe.contains($0.id) }) {
            result.append(contentsOf: tail[resume...])
        } else {
            result.append(contentsOf: tail)
        }
        return result
    }

    private static func wordStart(in tokens: [ForkParakeetToken], endingAt anchor: Int, safe: Set<Int>) -> Int? {
        var index = anchor
        while index >= 0 {
            if safe.contains(tokens[index].id) { return index }
            index -= 1
        }
        return nil
    }

    private static func popLastWord(from result: inout [ForkParakeetToken], safe: Set<Int>) -> Bool {
        var cursor = result.count - 1
        while cursor >= 0 {
            if safe.contains(result[cursor].id) {
                result.removeLast(result.count - cursor)
                return true
            }
            cursor -= 1
        }
        return false
    }

    private func mergeByMidpoint(_ left: [ForkParakeetToken], _ right: [ForkParakeetToken],
                                 leftEnd: Double, rightStart: Double) -> [ForkParakeetToken] {
        let cutoff = (leftEnd + rightStart) / 2
        var leftCut = left.firstIndex { Double($0.frame) * frameSeconds >= cutoff } ?? left.count
        var rightCut = right.firstIndex { Double($0.frame) * frameSeconds >= cutoff } ?? right.count
        if let safe = spliceSafeIds {
            if leftCut > 0 {
                while leftCut < left.count, !safe.contains(left[leftCut].id) { leftCut += 1 }
            }
            var scan = rightCut
            while scan < right.count, !safe.contains(right[scan].id) { scan += 1 }
            if scan < right.count { rightCut = scan }
        }
        return Array(left[..<leftCut]) + Array(right[rightCut...])
    }

    /// Drops a word repeated across a seam with another capitalization
    /// ("Meeting meeting"), keeping the lower-case one.
    func collapseSeamDuplicates(_ tokens: [ForkParakeetToken]) -> [ForkParakeetToken] {
        guard !vocabulary.isEmpty, tokens.count > 1 else { return tokens }
        let overlapFrames = Int((overlapSeconds / frameSeconds).rounded())

        struct Word {
            var tokens: [ForkParakeetToken]
            var core = ""
            var start: Int
            var endsSentence = false
        }
        var words: [Word] = []
        for token in tokens {
            if words.isEmpty || Self.startsWord(vocabulary[token.id] ?? "") {
                words.append(Word(tokens: [token], start: token.frame))
            } else {
                words[words.count - 1].tokens.append(token)
            }
        }
        let strippable = CharacterSet.punctuationCharacters.union(.whitespaces)
        for index in words.indices {
            var text = ""
            for token in words[index].tokens {
                let piece = vocabulary[token.id] ?? ""
                text += Self.startsWord(piece) ? String(piece.dropFirst()) : piece
            }
            words[index].core = text.trimmingCharacters(in: strippable)
            if let last = text.last { words[index].endsSentence = ".?!:".contains(last) }
        }

        var keep = [Bool](repeating: true, count: words.count)
        var lastKept = -1
        for index in words.indices {
            guard lastKept >= 0 else {
                lastKept = index
                continue
            }
            let previous = words[lastKept]
            let current = words[index]
            let isDuplicate = !previous.core.isEmpty && !current.core.isEmpty
                && previous.core != current.core
                && previous.core.lowercased() == current.core.lowercased()
                && current.core.first?.isLetter == true
                && !previous.endsSentence
                && current.start - previous.start <= overlapFrames
            guard isDuplicate else {
                lastKept = index
                continue
            }
            if current.core == current.core.lowercased(), previous.core != previous.core.lowercased() {
                keep[lastKept] = false
                lastKept = index
            } else {
                keep[index] = false
            }
        }
        var result: [ForkParakeetToken] = []
        result.reserveCapacity(tokens.count)
        for index in words.indices where keep[index] {
            result.append(contentsOf: words[index].tokens)
        }
        return result
    }
}

// MARK: - Text

enum ForkParakeetText {
    /// SentencePiece pieces to text: "▁" starts a word.
    static func text(of tokens: [ForkParakeetToken], vocabulary: [Int: String]) -> String {
        guard !tokens.isEmpty else { return "" }
        return tokens.compactMap { vocabulary[$0.id] }.filter { !$0.isEmpty }.joined()
            .replacingOccurrences(of: ForkParakeetShape.wordBoundary, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The mean token probability, kept within 0.1…1; 0.1 for an empty text.
    static func confidence(of tokens: [ForkParakeetToken], text: String) -> Float {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 0.1 }
        guard !tokens.isEmpty else { return 0.5 }
        let mean = tokens.reduce(Float(0)) { $0 + $1.confidence } / Float(tokens.count)
        return max(0.1, min(1, mean))
    }
}
