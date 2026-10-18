// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// How a delivered dictation ended up.
enum ForkDictationDeliveryOutcome: Equatable {
    /// Written where the person was typing.
    case pasted
    /// Left on the clipboard, as the Copy action asks.
    case copied
    /// The paste could not happen (the app quit, secure input, a stuck
    /// clipboard): the text waits on the clipboard for ⌘V.
    case keptInClipboard
}

/// The only place where the dictation decides anything.
///
/// The machine does nothing itself: it never touches the microphone, the
/// clipboard or the screen. It takes an event and returns the effects the
/// service must run, which is what makes every path testable in a
/// millisecond. An event that makes no sense in the current phase returns
/// nothing and changes nothing: a key pressed twice in 50 ms must never
/// break the app.
///
/// ```
///  idle ──press──► arming ──0.15 s──► listening ──release/press──► transcribing ──text──► delivering ──► idle
///   │  (fn, combo) ─────────────────────▲    │ Escape, silence, failure        │ Escape, nothing heard
///   └─ Paste last: no listening            ▼                                  ▼
///                                         idle                               idle
/// ```
///
/// The session token lives in the service, which checks it in every
/// callback: a result arriving after a cancel reaches a machine that is no
/// longer transcribing, and is dropped here too.
struct ForkDictationMachine {
    enum Phase: Equatable {
        case idle
        /// A modifier is down alone; the microphone is still closed, and
        /// nothing shows. A shortcut such as ⌘C ends it without a trace.
        case arming(ForkDictationShortcut)
        case listening(ForkDictationShortcut, handsFree: Bool)
        case transcribing(ForkDictationShortcut)
        case delivering
    }

    enum Event: Equatable {
        /// Every command of the session's gesture, `.none` included: it
        /// carries the gesture's hands-free state after the key event.
        case gesture(ForkDictationGesture.Command, ForkDictationShortcut, handsFree: Bool)
        case armElapsed
        /// The microphone really opened (not merely asked to).
        case captureStarted
        /// Escape, swallowed by the tap only while `isCancellable`.
        case escape
        /// Thirty seconds before the time limit.
        case timeLimitNear
        case timeLimitReached
        /// Hands-free, a minute without a voice.
        case silenceLimitReached
        /// The corrected, trimmed, non-empty text.
        case transcribed(String)
        case transcribedNothing
        case delivered(ForkDictationDeliveryOutcome)
        case failed(ForkDictationFailure)
    }

    enum Effect: Equatable {
        case scheduleArm(TimeInterval)
        /// Load the engine now, behind the first seconds of speech.
        case prepareEngine
        case startCapture
        case finishCaptureAndTranscribe
        /// Stop the microphone if it runs, drop its audio and any result
        /// still on its way.
        case discardCapture
        case deliver(String, ForkDictationShortcut.Action)
        case pasteLast
        case present(ForkDictationPresentation)
        case play(ForkDictationSound)
        case announceBusy
    }

    private(set) var phase: Phase = .idle
    /// Hands-free chosen while the microphone was not open yet.
    private var pendingHandsFree = false
    private var listeningSince: Date?
    private var nearLimit = false
    private var text = ""

    /// Escape belongs to the dictation only here: everywhere else it goes to
    /// the app in front.
    var isCancellable: Bool {
        switch phase {
        case .listening, .transcribing: return true
        case .idle, .arming, .delivering: return false
        }
    }

    var isBusy: Bool { phase != .idle }

    /// Whether the microphone really opened in this session.
    var isCapturing: Bool { listeningSince != nil }

    @discardableResult
    mutating func handle(_ event: Event, now: Date = Date()) -> [Effect] {
        switch (phase, event) {

        // Start.
        case let (.idle, .gesture(.start, shortcut, handsFree)):
            if shortcut.action == .pasteLast { return [.pasteLast] }
            reset()
            pendingHandsFree = handsFree
            if shortcut.armingDelay > 0 {
                phase = .arming(shortcut)
                return [.scheduleArm(shortcut.armingDelay)]
            }
            phase = .listening(shortcut, handsFree: handsFree)
            return [.prepareEngine, .startCapture]

        case let (.arming(shortcut), .armElapsed):
            phase = .listening(shortcut, handsFree: pendingHandsFree)
            return [.prepareEngine, .startCapture]

        case let (.arming(shortcut), .gesture(.none, _, handsFree)):
            pendingHandsFree = handsFree
            phase = .arming(shortcut)
            return []

        // Nothing was opened yet: a shortcut, Escape or an early end leave no trace.
        case (.arming, .gesture(.abort, _, _)), (.arming, .gesture(.cancel, _, _)),
             (.arming, .gesture(.finish, _, _)), (.arming, .escape):
            phase = .idle
            return []

        case let (.listening(shortcut, handsFree), .captureStarted) where listeningSince == nil:
            listeningSince = now
            phase = .listening(shortcut, handsFree: handsFree)
            return [.play(.start), .present(listening(handsFree))]

        case let (.listening(shortcut, false), .gesture(.none, _, true)):
            phase = .listening(shortcut, handsFree: true)
            return isCapturing ? [.present(listening(true))] : []

        case let (.listening(_, handsFree), .timeLimitNear):
            nearLimit = true
            return isCapturing ? [.present(listening(handsFree))] : []

        // Stop and write.
        case let (.listening(shortcut, _), .gesture(.finish, _, _)),
             let (.listening(shortcut, _), .timeLimitReached):
            guard isCapturing else {
                phase = .idle
                return [.discardCapture, .present(.hidden)]
            }
            phase = .transcribing(shortcut)
            return [.finishCaptureAndTranscribe, .play(.stop), .present(.transcribing)]

        // Give up.
        case (.listening, .gesture(.cancel, _, _)), (.listening, .escape):
            let wasCapturing = isCapturing
            phase = .idle
            return wasCapturing ? [.discardCapture, .play(.cancel), .present(.cancelled)]
                : [.discardCapture, .present(.hidden)]

        case (.listening, .gesture(.abort, _, _)):
            phase = .idle
            return [.discardCapture, .present(.hidden)]

        case (.listening, .silenceLimitReached):
            phase = .idle
            return [.discardCapture, .present(.nothingHeard(afterSilence: true))]

        // Result. A late one, after a cancel, finds the machine elsewhere.
        case let (.transcribing(shortcut), .transcribed(result)):
            text = result
            phase = .delivering
            return [.deliver(result, shortcut.action)]

        case (.transcribing, .transcribedNothing):
            phase = .idle
            return [.present(.nothingHeard(afterSilence: false))]

        // The engine cannot be stopped mid-inference: its result is dropped.
        case (.transcribing, .escape):
            phase = .idle
            return [.discardCapture, .play(.cancel), .present(.cancelled)]

        case let (.delivering, .delivered(outcome)):
            phase = .idle
            let excerpt = ForkDictationPresentation.excerpt(text)
            switch outcome {
            case .pasted: return [.present(.pasted(excerpt: excerpt))]
            case .copied: return [.present(.copied(excerpt: excerpt))]
            case .keptInClipboard: return [.present(.keptInClipboard)]
            }

        // A press while the last dictation is still being written.
        case (.transcribing, .gesture(.start, _, _)), (.delivering, .gesture(.start, _, _)):
            return [.announceBusy, .present(.busy)]

        // Failure.
        case let (_, .failed(failure)):
            let previous = phase
            phase = .idle
            switch previous {
            case .listening:
                return [.discardCapture, .play(.failure), .present(.failure(failure))]
            case .transcribing, .delivering, .idle, .arming:
                return [.play(.failure), .present(.failure(failure))]
            }

        default:
            return []
        }
    }

    private func listening(_ handsFree: Bool) -> ForkDictationPresentation {
        .listening(handsFree: handsFree, startedAt: listeningSince ?? Date(), nearLimit: nearLimit)
    }

    private mutating func reset() {
        pendingHandsFree = false
        listeningSince = nil
        nearLimit = false
        text = ""
    }
}

enum ForkDictationSound: Equatable {
    /// The microphone is open.
    case start
    /// Listening is over, writing begins.
    case stop
    case cancel
    case failure
}
