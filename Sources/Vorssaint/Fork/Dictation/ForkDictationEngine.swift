// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What turns one dictation's audio into text: Parakeet on this Mac, or
/// Apple's speech recognition.
///
/// Every method is called on the main thread, except `append`, called on
/// the microphone's queue. Audio is 16 kHz mono Float32.
protocol ForkDictationEngine: AnyObject {
    var kind: ForkDictationEngineKind { get }

    /// A real failure while the person is still speaking (Apple's servers
    /// gone, say), on the main thread: the dictation stops now rather than
    /// after minutes of talking into nothing. Never called after `cancel`.
    var onFailure: ((ForkDictationFailure) -> Void)? { get set }

    /// The engine can no longer hear but keeps what it understood (Apple's
    /// servers gone after the first minute, say), on the main thread: the
    /// dictation ends now and is transcribed. Never called after `cancel`.
    var onStopped: (() -> Void)? { get set }

    /// Gets ready without blocking: Parakeet loads its model in the
    /// background, so the load hides behind the first seconds of speech.
    func prepare()

    /// At the start of a capture. `language` is BCP 47, empty for the
    /// automatic one. Apple opens its recognition request here. Nil when
    /// the engine can take the dictation.
    func begin(language: String, vocabulary: [String]) -> ForkDictationFailure?

    /// On the microphone's queue, as the audio comes in. Apple recognizes
    /// while the person speaks; Parakeet waits for `finish`.
    func append(_ samples: UnsafeBufferPointer<Float>)

    /// The capture is over: `samples` is all of its audio. `completion`
    /// runs once, on the main thread, with the raw text (possibly empty:
    /// nothing was understood). It never runs after `cancel`.
    func finish(samples: [Float], completion: @escaping (Result<String, ForkDictationFailure>) -> Void)

    /// Gives up the dictation under way. A result still computing is dropped.
    func cancel()
}
