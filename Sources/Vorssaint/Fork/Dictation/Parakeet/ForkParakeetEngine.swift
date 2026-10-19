// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial
// Portions adapted from FluidAudio (Apache-2.0), https://github.com/FluidInference/FluidAudio

import CoreML
import Foundation

/// What Parakeet heard.
struct ForkParakeetTranscript: Equatable {
    var text: String
    /// Mean token probability, 0.1…1.
    var confidence: Float
    var audioDuration: TimeInterval
    var processingTime: TimeInterval

    var isEmpty: Bool { text.isEmpty }
}

enum ForkParakeetError: Error, Equatable {
    case notLoaded
    case missingModel(String)
    case unexpectedOutput(String)
    /// A long transcription stopped by its `progress`.
    case cancelled
}

/// Parakeet TDT 0.6B v3 on CoreML: preprocessor (CPU), then encoder, decoder
/// and joint networks (Neural Engine), driven by ForkParakeetTdt.
///
/// Every model call runs on one private serial queue. The blocking methods
/// (`load`, `warmUp`, `transcribe`) must not be called from the main thread;
/// the completion variants hop to that queue and answer on the main queue.
final class ForkParakeetEngine: @unchecked Sendable {
    static let preprocessorFile = "Preprocessor.mlmodelc"
    static let encoderFile = "Encoder.mlmodelc"
    static let decoderFile = "Decoder.mlmodelc"
    static let jointFile = "JointDecisionv3.mlmodelc"
    static let modelFiles = [preprocessorFile, encoderFile, decoderFile, jointFile]

    private let queue: DispatchQueue
    private let lock = NSLock()
    // Only touched on `queue`.
    private var models: Models?
    // Mirrors `models != nil` for other threads; guarded by `lock`.
    private var loadedDirectory: URL?

    /// The dictation runs at `.userInitiated`. A meeting's transcript loads
    /// an instance of its own at `.utility`: it never waits behind a
    /// dictation, and no dictation ever waits behind it.
    init(qos: DispatchQoS = .userInitiated) {
        let label = qos == .userInitiated ? "vorssaint.fork.dictation.parakeet" : "vorssaint.fork.parakeet.long"
        queue = DispatchQueue(label: label, qos: qos)
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedDirectory != nil
    }

    // MARK: Loading

    /// Loads the models of `directory`. The first load on a Mac also compiles
    /// the encoder for its Neural Engine, which takes a few seconds.
    func load(from directory: URL) throws {
        try queue.sync { try loadOnQueue(from: directory) }
    }

    /// Loads, then runs one second of silence so the first dictation does not
    /// pay for the Neural Engine's first run either.
    func prepare(from directory: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            var failure: Error?
            do {
                try self.loadOnQueue(from: directory)
                _ = try self.transcribeOnQueue([Float](repeating: 0, count: ForkParakeetShape.sampleRate),
                                               languageCode: nil)
            } catch {
                failure = error
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    func warmUp() throws {
        _ = try transcribe([Float](repeating: 0, count: ForkParakeetShape.sampleRate))
    }

    /// Frees the models (about 0.5 GB). A transcription in progress ends first.
    func unload() {
        queue.async {
            self.models = nil
            self.setLoadedDirectory(nil)
        }
    }

    private func loadOnQueue(from directory: URL) throws {
        if models?.directory == directory { return }
        models = nil
        setLoadedDirectory(nil)
        for file in Self.modelFiles where !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(file).path) {
            throw ForkParakeetError.missingModel(file)
        }
        let vocabulary = try ForkParakeetVocabulary.load(from: directory)

        func model(_ file: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(contentsOf: directory.appendingPathComponent(file), configuration: configuration)
        }
        // The preprocessor is all CPU work anyway; the rest belongs on the ANE.
        models = Models(
            directory: directory,
            preprocessor: try model(Self.preprocessorFile, .cpuOnly),
            encoder: try model(Self.encoderFile, .cpuAndNeuralEngine),
            decoder: try model(Self.decoderFile, .cpuAndNeuralEngine),
            joint: try model(Self.jointFile, .cpuAndNeuralEngine),
            vocabulary: vocabulary,
            stitcher: ForkParakeetStitcher(vocabulary: vocabulary.pieces),
            audio: try MLMultiArray(shape: [1, NSNumber(value: ForkParakeetShape.windowSamples)],
                                    dataType: .float32))
        setLoadedDirectory(directory)
    }

    private func setLoadedDirectory(_ directory: URL?) {
        lock.lock()
        loadedDirectory = directory
        lock.unlock()
    }

    // MARK: Transcribing

    /// Transcribes 16 kHz mono samples. `languageCode` ("fr", "de-CH"…) only
    /// filters the alphabet: Parakeet finds the language itself. Under 0.3 s
    /// of audio the text is empty.
    func transcribe(_ samples: [Float], languageCode: String? = nil) throws -> ForkParakeetTranscript {
        try queue.sync { try transcribeOnQueue(samples, languageCode: languageCode) }
    }

    func transcribe(_ samples: [Float], languageCode: String?,
                    completion: @escaping (Result<ForkParakeetTranscript, Error>) -> Void) {
        queue.async {
            let result = Result { try self.transcribeOnQueue(samples, languageCode: languageCode) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func transcribeOnQueue(_ samples: [Float], languageCode: String?) throws -> ForkParakeetTranscript {
        guard let models else { throw ForkParakeetError.notLoaded }
        let started = Date()
        let duration = Double(samples.count) / Double(ForkParakeetShape.sampleRate)
        guard samples.count >= ForkParakeetShape.minimumSamples else {
            return ForkParakeetTranscript(text: "", confidence: 0.1, audioDuration: duration,
                                          processingTime: Date().timeIntervalSince(started))
        }
        var tdt = ForkParakeetTdt()
        tdt.filter = ForkParakeetScriptFilter(languageCode: languageCode, vocabulary: models.vocabulary.pieces)
        let steps = try ForkParakeetCoreMLSteps(decoder: models.decoder, joint: models.joint)

        let tokens: [ForkParakeetToken]
        if samples.count <= ForkParakeetShape.windowSamples {
            // One window: the audio is padded to a whole frame, then to 15 s.
            let aligned = ForkParakeetShape.frames(forSamples: samples.count) * ForkParakeetShape.samplesPerFrame
            let length = aligned <= ForkParakeetShape.windowSamples ? aligned : samples.count
            let encoded = try encode(samples[...], audioLength: length, models: models)
            steps.encoded = encoded
            tokens = try tdt.decode(steps, encoderLength: encoded.length, frameCount: encoded.readableFrames,
                                    audioFrames: ForkParakeetShape.frames(forSamples: length),
                                    contextFrames: 0, isLast: true, frameOffset: 0)
        } else {
            var windows: [[ForkParakeetToken]] = []
            for window in ForkParakeetWindows.plan(totalSamples: samples.count) {
                let encoded = try encode(samples[window.start..<window.end], audioLength: window.sampleCount,
                                         models: models)
                guard encoded.length > 0 else {
                    windows.append([])
                    continue
                }
                steps.encoded = encoded
                windows.append(try tdt.decode(steps, encoderLength: encoded.length,
                                              frameCount: encoded.readableFrames,
                                              audioFrames: window.audioFrames,
                                              contextFrames: window.contextFrames,
                                              isLast: window.isLast, frameOffset: window.frameOffset))
            }
            tokens = models.stitcher.stitch(windows)
        }

        let raw = ForkParakeetText.text(of: tokens, vocabulary: models.vocabulary.pieces)
        return ForkParakeetTranscript(text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                      confidence: ForkParakeetText.confidence(of: tokens, text: raw),
                                      audioDuration: duration,
                                      processingTime: Date().timeIntervalSince(started))
    }

    // MARK: Long recordings

    /// Transcribes a long recording (a meeting's track) read from `source`
    /// window by window, so an hour never sits in memory as one array: the
    /// reader holds one 15 s window and the source a few seconds more. Same
    /// windows, same decoding and same stitching as `transcribe`, so the same
    /// audio gives the same text, plus each word's time.
    ///
    /// `progress` gets the seconds read so far before each window, on the
    /// engine's queue, and returns false to stop with
    /// `ForkParakeetError.cancelled`. Blocks: never on the main thread.
    func transcribeLong(_ source: ForkParakeetSampleSource, languageCode: String? = nil,
                        progress: (TimeInterval) -> Bool = { _ in true }) throws -> ForkParakeetTimedTranscript {
        try queue.sync { try transcribeLongOnQueue(source, languageCode: languageCode, progress: progress) }
    }

    private func transcribeLongOnQueue(_ source: ForkParakeetSampleSource, languageCode: String?,
                                       progress: (TimeInterval) -> Bool) throws -> ForkParakeetTimedTranscript {
        guard let models else { throw ForkParakeetError.notLoaded }
        let started = Date()
        let rate = Double(ForkParakeetShape.sampleRate)
        var tdt = ForkParakeetTdt()
        tdt.filter = ForkParakeetScriptFilter(languageCode: languageCode, vocabulary: models.vocabulary.pieces)
        let steps = try ForkParakeetCoreMLSteps(decoder: models.decoder, joint: models.joint)
        var reader = ForkParakeetWindowReader(source: source)

        var windows: [[ForkParakeetToken]] = []
        var whole: [ForkParakeetToken]?
        while let step = try reader.next() {
            guard progress(Double(reader.samplesRead) / rate) else { throw ForkParakeetError.cancelled }
            switch step {
            case let .whole(count):
                // Short audio: exactly the one-window path of `transcribe`.
                guard count >= ForkParakeetShape.minimumSamples else {
                    whole = []
                    continue
                }
                let aligned = ForkParakeetShape.frames(forSamples: count) * ForkParakeetShape.samplesPerFrame
                let length = aligned <= ForkParakeetShape.windowSamples ? aligned : count
                let encoded = try encode(reader.samples(0, count), audioLength: length, models: models)
                steps.encoded = encoded
                whole = try tdt.decode(steps, encoderLength: encoded.length, frameCount: encoded.readableFrames,
                                       audioFrames: ForkParakeetShape.frames(forSamples: length),
                                       contextFrames: 0, isLast: true, frameOffset: 0)
            case let .window(window):
                let encoded = try encode(reader.samples(window.start, window.end), audioLength: window.sampleCount,
                                         models: models)
                guard encoded.length > 0 else {
                    windows.append([])
                    continue
                }
                steps.encoded = encoded
                windows.append(try tdt.decode(steps, encoderLength: encoded.length,
                                              frameCount: encoded.readableFrames,
                                              audioFrames: window.audioFrames,
                                              contextFrames: window.contextFrames,
                                              isLast: window.isLast, frameOffset: window.frameOffset))
            }
        }
        let tokens = whole ?? models.stitcher.stitch(windows)
        return ForkParakeetTimedTranscript(words: ForkParakeetText.words(of: tokens, vocabulary: models.vocabulary.pieces),
                                           audioDuration: Double(reader.samplesRead) / rate,
                                           processingTime: Date().timeIntervalSince(started),
                                           windowCount: whole == nil ? windows.count : 1)
    }

    /// Preprocessor then encoder on one window (at most 15 s of samples).
    private func encode(_ samples: ArraySlice<Float>, audioLength: Int, models: Models) throws -> ForkParakeetEncoded {
        try autoreleasepool { try encodeInPool(samples, audioLength: audioLength, models: models) }
    }

    private func encodeInPool(_ samples: ArraySlice<Float>, audioLength: Int, models: Models) throws -> ForkParakeetEncoded {
        let audio = models.audio
        let capacity = ForkParakeetShape.windowSamples
        let destination = audio.dataPointer.bindMemory(to: Float.self, capacity: capacity)
        let count = min(samples.count, capacity)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: count) }
        }
        (destination + count).initialize(repeating: 0, count: capacity - count)

        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: audioLength)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audio),
            "audio_length": MLFeatureValue(multiArray: length),
        ])
        let features = try models.preprocessor.prediction(from: input)
        let output = try models.encoder.prediction(from: features)
        guard let encoder = output.featureValue(for: "encoder")?.multiArrayValue,
              let encoderLength = output.featureValue(for: "encoder_length")?.multiArrayValue else {
            throw ForkParakeetError.unexpectedOutput("encoder")
        }
        return try ForkParakeetEncoded(array: encoder, length: encoderLength[0].intValue)
    }

    private struct Models {
        let directory: URL
        let preprocessor: MLModel
        let encoder: MLModel
        let decoder: MLModel
        let joint: MLModel
        let vocabulary: ForkParakeetVocabulary
        let stitcher: ForkParakeetStitcher
        /// The 15 s input, reused from one window to the next.
        let audio: MLMultiArray
    }
}

/// The encoder's output for one window: 1024 values per 80 ms frame.
final class ForkParakeetEncoded {
    let array: MLMultiArray
    let length: Int
    let frames: Int
    private let hiddenStride: Int
    private let timeStride: Int
    private let base: UnsafeMutablePointer<Float>

    /// Frames that both exist in the tensor and the encoder counted as audio.
    var readableFrames: Int { min(length, frames) }

    init(array: MLMultiArray, length: Int) throws {
        let shape = array.shape.map(\.intValue)
        let hidden = ForkParakeetShape.encoderHidden
        guard shape.count == 3, shape[0] == 1, shape[1] == hidden || shape[2] == hidden,
              array.dataType == .float32 else {
            throw ForkParakeetError.unexpectedOutput("encoder shape \(shape)")
        }
        let hiddenAxis = shape[1] == hidden ? 1 : 2
        let timeAxis = hiddenAxis == 1 ? 2 : 1
        let strides = array.strides.map(\.intValue)
        self.array = array
        self.length = length
        self.frames = shape[timeAxis]
        self.hiddenStride = strides[hiddenAxis]
        self.timeStride = strides[timeAxis]
        self.base = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    }

    func copyFrame(_ frame: Int, into destination: UnsafeMutablePointer<Float>, stride: Int) {
        let source = base + frame * timeStride
        for index in 0..<ForkParakeetShape.encoderHidden {
            destination[index * stride] = source[index * hiddenStride]
        }
    }
}

/// The decoder LSTM and the joint network, one call each per step.
final class ForkParakeetCoreMLSteps: ForkParakeetJointStepping {
    var encoded: ForkParakeetEncoded?

    private let decoder: MLModel
    private let joint: MLModel
    private let target: MLMultiArray
    private let targetLength: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private let encoderStep: MLMultiArray
    private let decoderStep: MLMultiArray
    private let jointInput: MLDictionaryFeatureProvider

    init(decoder: MLModel, joint: MLModel) throws {
        self.decoder = decoder
        self.joint = joint
        target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1
        hidden = try Self.zeroState()
        cell = try Self.zeroState()
        encoderStep = try MLMultiArray(shape: [1, NSNumber(value: ForkParakeetShape.encoderHidden), 1],
                                       dataType: .float32)
        decoderStep = try MLMultiArray(shape: [1, NSNumber(value: ForkParakeetShape.decoderHidden), 1],
                                       dataType: .float32)
        jointInput = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encoderStep),
            "decoder_step": MLFeatureValue(multiArray: decoderStep),
        ])
    }

    private static func zeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(
            shape: [NSNumber(value: ForkParakeetShape.decoderLayers), 1,
                    NSNumber(value: ForkParakeetShape.decoderHidden)],
            dataType: .float32)
        state.dataPointer.bindMemory(to: Float.self, capacity: state.count)
            .initialize(repeating: 0, count: state.count)
        return state
    }

    func resetDecoder() throws {
        hidden = try Self.zeroState()
        cell = try Self.zeroState()
    }

    // Each prediction allocates IOSurface-backed outputs that are only
    // autoreleased: a 3 min dictation makes thousands of them, so every step
    // drains its own pool.
    func advanceDecoder(with token: Int) throws {
        try autoreleasepool { try advanceDecoderInPool(with: token) }
    }

    private func advanceDecoderInPool(with token: Int) throws {
        target[0] = NSNumber(value: token)
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: target),
            "target_length": MLFeatureValue(multiArray: targetLength),
            "h_in": MLFeatureValue(multiArray: hidden),
            "c_in": MLFeatureValue(multiArray: cell),
        ]))
        guard let projection = output.featureValue(for: "decoder")?.multiArrayValue,
              let newHidden = output.featureValue(for: "h_out")?.multiArrayValue,
              let newCell = output.featureValue(for: "c_out")?.multiArrayValue,
              projection.dataType == .float32 else {
            throw ForkParakeetError.unexpectedOutput("decoder")
        }
        hidden = newHidden
        cell = newCell

        // [1, 640, 1] or [1, 1, 640]: copy along whichever axis holds 640.
        let shape = projection.shape.map(\.intValue)
        guard shape.count == 3, let axis = [2, 1].first(where: { shape[$0] == ForkParakeetShape.decoderHidden })
        else { throw ForkParakeetError.unexpectedOutput("decoder shape \(shape)") }
        let sourceStride = projection.strides[axis].intValue
        let destinationStride = decoderStep.strides[1].intValue
        let source = projection.dataPointer.bindMemory(to: Float.self, capacity: projection.count)
        let destination = decoderStep.dataPointer.bindMemory(to: Float.self, capacity: decoderStep.count)
        for index in 0..<ForkParakeetShape.decoderHidden {
            destination[index * destinationStride] = source[index * sourceStride]
        }
    }

    func joint(atFrame frame: Int, topK: Bool) throws -> ForkParakeetJointDecision {
        try autoreleasepool { try jointInPool(atFrame: frame, topK: topK) }
    }

    private func jointInPool(atFrame frame: Int, topK: Bool) throws -> ForkParakeetJointDecision {
        guard let encoded, frame >= 0, frame < encoded.readableFrames else {
            throw ForkParakeetError.unexpectedOutput("encoder frame \(frame)")
        }
        let destination = encoderStep.dataPointer.bindMemory(to: Float.self, capacity: encoderStep.count)
        encoded.copyFrame(frame, into: destination, stride: encoderStep.strides[1].intValue)

        let output = try joint.prediction(from: jointInput)
        guard let token = output.featureValue(for: "token_id")?.multiArrayValue,
              let probability = output.featureValue(for: "token_prob")?.multiArrayValue,
              let duration = output.featureValue(for: "duration")?.multiArrayValue else {
            throw ForkParakeetError.unexpectedOutput("joint")
        }
        var decision = ForkParakeetJointDecision(token: Self.integers(token).first ?? 0,
                                                 probability: Self.floats(probability).first ?? 0,
                                                 durationBin: Self.integers(duration).first ?? 0)
        if topK, let ids = output.featureValue(for: "top_k_ids")?.multiArrayValue,
           let logits = output.featureValue(for: "top_k_logits")?.multiArrayValue {
            decision.topKIds = Self.integers(ids)
            decision.topKLogits = Self.floats(logits)
            guard decision.topKIds.count == decision.topKLogits.count else {
                throw ForkParakeetError.unexpectedOutput("joint top-K")
            }
        }
        return decision
    }

    /// The values of a tensor whose only non-unit axis is the last one.
    private static func integers(_ array: MLMultiArray) -> [Int] {
        let count = array.count
        let stride = array.strides.last?.intValue ?? 1
        switch array.dataType {
        case .int32:
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: count * stride)
            return (0..<count).map { Int(pointer[$0 * stride]) }
        default:
            return (0..<count).map { array[$0].intValue }
        }
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        let stride = array.strides.last?.intValue ?? 1
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count * stride)
            return (0..<count).map { pointer[$0 * stride] }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }
}
