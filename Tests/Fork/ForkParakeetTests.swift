// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkParakeetTests {
    static func run(_ suite: TestSuite) {
        tdt(suite)
        scriptFilter(suite)
        text(suite)
        windows(suite)
        stitching(suite)
        vocabulary(suite)
    }

    /// A joint network that answers from a script, frame by frame, and blanks
    /// four frames ahead once a frame's script is used up.
    private final class ScriptedSteps: ForkParakeetJointStepping {
        var script: [Int: [ForkParakeetJointDecision]]
        var fed: [Int] = []
        var resets = 0

        init(_ script: [Int: [ForkParakeetJointDecision]]) {
            self.script = script
        }

        func resetDecoder() throws { resets += 1 }

        func advanceDecoder(with token: Int) throws { fed.append(token) }

        func joint(atFrame frame: Int, topK: Bool) throws -> ForkParakeetJointDecision {
            if var answers = script[frame], !answers.isEmpty {
                let answer = answers.removeFirst()
                script[frame] = answers
                return answer
            }
            return step(ForkParakeetShape.blankId, bin: 4)
        }
    }

    private static func step(_ token: Int, bin: Int, probability: Float = 0.9) -> ForkParakeetJointDecision {
        ForkParakeetJointDecision(token: token, probability: probability, durationBin: bin)
    }

    private static func tdt(_ suite: TestSuite) {
        let blank = ForkParakeetShape.blankId
        let steps = ScriptedSteps([
            0: [step(10, bin: 1)],
            1: [step(blank, bin: 2)],
            3: [step(11, bin: 0), step(12, bin: 2)],
        ])
        let tokens = (try? ForkParakeetTdt().decode(steps, encoderLength: 10, frameCount: 10, audioFrames: 10,
                                                    contextFrames: 0, isLast: false, frameOffset: 0)) ?? []
        suite.expect(tokens.map(\.id) == [10, 11, 12] && tokens.map(\.frame) == [0, 3, 3],
                     "tokens are read where the durations lead, blanks are skipped")
        suite.expect(steps.fed == [blank, 10, 11, 12] && steps.resets == 1,
                     "the decoder starts from the blank and learns each token once")

        let shifted = (try? ForkParakeetTdt().decode(ScriptedSteps([0: [step(10, bin: 1)]]), encoderLength: 10,
                                                     frameCount: 10, audioFrames: 10, contextFrames: 0,
                                                     isLast: false, frameOffset: 161)) ?? []
        suite.expect(shifted.map(\.frame) == [161],
                     "a later window counts its frames from the start of the audio")

        let stuck = (try? ForkParakeetTdt().decode(ScriptedSteps([0: [step(20, bin: 0), step(21, bin: 0)]]),
                                                   encoderLength: 10, frameCount: 10, audioFrames: 10,
                                                   contextFrames: 0, isLast: false, frameOffset: 0)) ?? []
        suite.expect(stuck.map(\.id) == [20, 21] && stuck.map(\.duration) == [0, 1],
                     "a second token on the same frame moves the reading on by one frame")

        let flushed = (try? ForkParakeetTdt().decode(ScriptedSteps([2: [step(30, bin: 1)]]), encoderLength: 3,
                                                     frameCount: 3, audioFrames: 3, contextFrames: 0,
                                                     isLast: true, frameOffset: 0)) ?? []
        suite.expect(flushed.map(\.id) == [30] && flushed.map(\.frame) == [2],
                     "the last window looks again at its last frames for a pending token")

        let padding = (try? ForkParakeetTdt().decode(ScriptedSteps([5: [step(40, bin: 1)]]), encoderLength: 10,
                                                     frameCount: 10, audioFrames: 4, contextFrames: 0,
                                                     isLast: false, frameOffset: 0)) ?? []
        suite.expect(padding.isEmpty, "the padding after the audio is never read")

        suite.expect((try? ForkParakeetTdt().decode(ScriptedSteps([:]), encoderLength: 1, frameCount: 1,
                                                    audioFrames: 1, contextFrames: 0, isLast: true,
                                                    frameOffset: 0))?.isEmpty == true,
                     "a single frame is too short to decode")
        suite.expect((try? ForkParakeetTdt().decode(ScriptedSteps([0: [step(1, bin: 9)]]), encoderLength: 10,
                                                    frameCount: 10, audioFrames: 10, contextFrames: 0,
                                                    isLast: false, frameOffset: 0)) == nil,
                     "a duration bin the model does not have is an error")
    }

    private static func scriptFilter(_ suite: TestSuite) {
        let vocabulary = [1: "\u{2581}привет", 2: "\u{2581}bonjour", 506: "\u{2581}the", 4: "\u{2581}le"]
        let french = ForkParakeetScriptFilter(languageCode: "fr-FR", vocabulary: vocabulary)
        var label = 1
        var score: Float = 0.9
        french?.apply(label: &label, score: &score,
                      decision: ForkParakeetJointDecision(token: 1, probability: 0.9, durationBin: 1,
                                                          topKIds: [1, 2], topKLogits: [5, 4]))
        suite.expect(label == 2 && score > 0 && score < 0.5,
                     "in French a Cyrillic token gives way to the best Latin one")

        label = 506
        french?.apply(label: &label, score: &score,
                      decision: ForkParakeetJointDecision(token: 506, probability: 0.9, durationBin: 1,
                                                          topKIds: [506, 4], topKLogits: [3, 2]))
        suite.expect(label == 4, "in French an English-only word gives way to the next best one")

        let english = ForkParakeetScriptFilter(languageCode: "en", vocabulary: vocabulary)
        label = 506
        english?.apply(label: &label, score: &score,
                       decision: ForkParakeetJointDecision(token: 506, probability: 0.9, durationBin: 1,
                                                           topKIds: [506, 4], topKLogits: [3, 2]))
        suite.expect(label == 506, "in English, English words stay")

        suite.expect(ForkParakeetScriptFilter(languageCode: nil, vocabulary: vocabulary) == nil
                        && ForkParakeetScriptFilter(languageCode: "ja-JP", vocabulary: vocabulary) == nil,
                     "no language, or one Parakeet does not know, filters nothing")
        suite.expect(ForkParakeetLanguages.isSupported("fr_CA") && ForkParakeetLanguages.isSupported("uk")
                        && !ForkParakeetLanguages.isSupported("ja") && ForkParakeetLanguages.supported.count == 25,
                     "Parakeet knows its 25 European languages and no other")
    }

    private static func text(_ suite: TestSuite) {
        let vocabulary = [0: "\u{2581}Bon", 1: "jour", 2: ",", 3: "\u{2581}ça", 4: "\u{2581}va", 5: "\u{2581}?"]
        let tokens = (0...5).map { ForkParakeetToken(id: $0, frame: $0, confidence: 0.8, duration: 1) }
        suite.expect(ForkParakeetText.text(of: tokens, vocabulary: vocabulary) == "Bonjour, ça va ?",
                     "word pieces join, and ▁ starts a new word")
        suite.expect(ForkParakeetText.text(of: [ForkParakeetToken(id: ForkParakeetShape.blankId, frame: 0,
                                                                  confidence: 1, duration: 1)],
                                           vocabulary: vocabulary) == "",
                     "a token without a piece writes nothing")
        suite.expect(abs(ForkParakeetText.confidence(of: tokens, text: "Bonjour") - 0.8) < 0.0001
                        && ForkParakeetText.confidence(of: [], text: " ") == 0.1,
                     "confidence is the mean token probability, low when nothing was heard")
    }

    private static func windows(_ suite: TestSuite) {
        let total = 40 * ForkParakeetShape.sampleRate
        let plan = ForkParakeetWindows.plan(totalSamples: total)
        suite.expect(plan.count == 3 && plan.last?.isLast == true && plan.last?.end == total
                        && plan.dropLast().allSatisfy { !$0.isLast },
                     "40 s are read in three windows, the last one up to the end")
        suite.expect(plan.allSatisfy { $0.sampleCount <= ForkParakeetShape.windowSamples },
                     "no window is longer than what the model takes")
        suite.expect(plan.map(\.frameOffset) == [0, 161, 322] && plan.map(\.contextFrames) == [0, 1, 1],
                     "each window after the first starts 161 frames later, with one frame of context")
        let overlaps = zip(plan, plan.dropFirst()).map { $0.end - ($1.start + $1.contextSamples) }
        suite.expect(overlaps.allSatisfy { $0 == 2 * ForkParakeetShape.sampleRate },
                     "consecutive windows share 2 s of audio")
        suite.expect(ForkParakeetWindows.plan(totalSamples: 10).count == 1,
                     "a short audio is one window")
    }

    private static func stitching(_ suite: TestSuite) {
        let vocabulary = [1: "\u{2581}un", 2: "\u{2581}deux", 3: "\u{2581}trois", 4: "\u{2581}quatre",
                          5: "\u{2581}cinq", 6: "\u{2581}six", 7: "\u{2581}Meeting", 8: "\u{2581}meeting"]
        func token(_ id: Int, _ frame: Int) -> ForkParakeetToken {
            ForkParakeetToken(id: id, frame: frame, confidence: 0.9, duration: 1)
        }
        let stitcher = ForkParakeetStitcher(vocabulary: vocabulary)
        let left = [token(1, 150), token(2, 160), token(3, 170), token(4, 180)]
        let right = [token(3, 170), token(4, 180), token(5, 190), token(6, 200)]
        let merged = stitcher.stitch([left, right])
        suite.expect(ForkParakeetText.text(of: merged, vocabulary: vocabulary) == "un deux trois quatre cinq six",
                     "the words both windows heard are kept once")
        suite.expect(stitcher.stitch([left, []]) == left && stitcher.stitch([[], right]) == right,
                     "an empty window adds nothing")
        let apart = stitcher.stitch([[token(1, 10)], [token(2, 400)]])
        suite.expect(apart.map(\.id) == [1, 2], "windows that do not touch are put end to end")
        suite.expect(stitcher.collapseSeamDuplicates([token(7, 100), token(8, 110)]).map(\.id) == [8],
                     "a word repeated at a seam with a capital is kept once, in lower case")
        suite.expect(stitcher.collapseSeamDuplicates([token(7, 100), token(8, 400)]).count == 2,
                     "the same word said twice far apart stays twice")
        suite.expect(ForkParakeetStitcher.isSpliceSafe("\u{2581}mot") && ForkParakeetStitcher.isSpliceSafe(",")
                        && !ForkParakeetStitcher.isSpliceSafe("jour"),
                     "a splice starts at a word or a punctuation mark, never inside a word")
    }

    private static func vocabulary(_ suite: TestSuite) {
        let dictionary = try? ForkParakeetVocabulary(data: Data(#"{"0": "<unk>", "8191": "▁x"}"#.utf8))
        suite.expect(dictionary?.count == 2 && dictionary?.pieces[8191] == "\u{2581}x",
                     "the vocabulary file maps ids to pieces")
        let array = try? ForkParakeetVocabulary(data: Data(#"["a", "b"]"#.utf8))
        suite.expect(array?.pieces[1] == "b", "a plain list is read by position")
        suite.expect((try? ForkParakeetVocabulary(data: Data("42".utf8))) == nil,
                     "anything else is refused")
    }
}
