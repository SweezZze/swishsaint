// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkDictationMachineTests {
    private static let rightCommand = ForkDictationShortcut.default
    private static let fn = ForkDictationShortcut(key: .modifier(.fn))
    private static let copy = ForkDictationShortcut(key: .modifier(.fn), action: .copy)
    private static let pasteLast = ForkDictationShortcut(key: .modifier(.rightOption), action: .pasteLast)
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    static func run(_ suite: TestSuite) {
        arming(suite)
        nominal(suite)
        cancelling(suite)
        limits(suite)
        failures(suite)
        actions(suite)
    }

    private static func press(_ shortcut: ForkDictationShortcut, handsFree: Bool = false) -> ForkDictationMachine.Event {
        .gesture(.start, shortcut, handsFree: handsFree)
    }

    /// A machine already listening with an open microphone.
    private static func listening(_ shortcut: ForkDictationShortcut = fn) -> ForkDictationMachine {
        var machine = ForkDictationMachine()
        machine.handle(press(shortcut))
        if case .arming = machine.phase { machine.handle(.armElapsed) }
        machine.handle(.captureStarted, now: t0)
        return machine
    }

    private static func arming(_ suite: TestSuite) {
        var machine = ForkDictationMachine()
        suite.expect(machine.handle(press(rightCommand)) == [.scheduleArm(0.15)]
                        && machine.phase == .arming(rightCommand),
                     "a modifier arms first: the microphone stays closed")
        suite.expect(!machine.isCancellable && machine.isBusy, "Escape is not taken while arming")
        suite.expect(machine.handle(.gesture(.abort, rightCommand, handsFree: false)).isEmpty && machine.phase == .idle,
                     "a keyboard shortcut during arming leaves no trace: no sound, no microphone, nothing shown")

        machine.handle(press(rightCommand))
        suite.expect(machine.handle(.escape).isEmpty && machine.phase == .idle,
                     "Escape while arming drops silently")

        machine.handle(press(rightCommand))
        suite.expect(machine.handle(.armElapsed) == [.prepareEngine, .startCapture]
                        && machine.phase == .listening(rightCommand, handsFree: false),
                     "after the arming delay the engine loads and the microphone opens")

        var tapped = ForkDictationMachine()
        tapped.handle(press(rightCommand))
        tapped.handle(.gesture(.none, rightCommand, handsFree: true))
        tapped.handle(.armElapsed)
        suite.expect(tapped.phase == .listening(rightCommand, handsFree: true),
                     "a tap during arming goes hands-free once armed")

        var direct = ForkDictationMachine()
        suite.expect(direct.handle(press(fn)) == [.prepareEngine, .startCapture],
                     "fn opens the microphone on the press")
        suite.expect(direct.handle(.armElapsed).isEmpty, "a late arming timer does nothing")
    }

    private static func nominal(_ suite: TestSuite) {
        var machine = ForkDictationMachine()
        machine.handle(press(fn))
        suite.expect(!machine.isCancellable && !machine.isCapturing,
                     "listening, the microphone not open yet: nothing shows, Escape stays the app's")
        suite.expect(machine.handle(.captureStarted, now: t0)
                        == [.play(.start), .present(.listening(handsFree: false, startedAt: t0, nearLimit: false))],
                     "listening shows, with its sound, only once the microphone really opened")
        suite.expect(machine.isCancellable, "once it shows, Escape is the dictation's")
        suite.expect(machine.handle(.captureStarted, now: t0.addingTimeInterval(1)).isEmpty,
                     "a second start report does nothing")
        suite.expect(machine.handle(.gesture(.none, fn, handsFree: true))
                        == [.present(.listening(handsFree: true, startedAt: t0, nearLimit: false))],
                     "going hands-free shows the stop square, the timer kept")
        suite.expect(machine.handle(.gesture(.finish, fn, handsFree: false))
                        == [.finishCaptureAndTranscribe, .play(.stop), .present(.transcribing)]
                        && machine.phase == .transcribing(fn) && machine.isCancellable,
                     "the end of listening transcribes")
        suite.expect(machine.handle(.transcribed("Bonjour à tous.")) == [.deliver("Bonjour à tous.", .paste)]
                        && machine.phase == .delivering && !machine.isCancellable,
                     "the text is delivered, and Escape goes back to the app")
        suite.expect(machine.handle(.escape).isEmpty && machine.phase == .delivering,
                     "Escape during the paste does nothing")
        suite.expect(machine.handle(.delivered(.pasted)) == [.present(.pasted(excerpt: "Bonjour à tous."))]
                        && machine.phase == .idle,
                     "pasted is shown when the paste really happened")

        var nothing = listening()
        nothing.handle(.gesture(.finish, fn, handsFree: false))
        suite.expect(nothing.handle(.transcribedNothing) == [.present(.nothingHeard(afterSilence: false))]
                        && nothing.phase == .idle,
                     "an empty transcript says nothing was heard, and delivers nothing")

        var early = ForkDictationMachine()
        early.handle(press(fn))
        suite.expect(early.handle(.gesture(.finish, fn, handsFree: false)) == [.discardCapture, .present(.hidden)]
                        && early.phase == .idle,
                     "released before the microphone opened: nothing to transcribe")
    }

    private static func cancelling(_ suite: TestSuite) {
        var escaped = listening()
        suite.expect(escaped.handle(.escape) == [.discardCapture, .play(.cancel), .present(.cancelled)]
                        && escaped.phase == .idle,
                     "Escape while listening drops the audio, with a sound")

        var aborted = listening()
        suite.expect(aborted.handle(.gesture(.abort, fn, handsFree: false)) == [.discardCapture, .present(.hidden)],
                     "a shortcut after the microphone opened drops silently")

        var late = listening()
        late.handle(.gesture(.finish, fn, handsFree: false))
        suite.expect(late.handle(.escape) == [.discardCapture, .play(.cancel), .present(.cancelled)]
                        && late.phase == .idle,
                     "Escape while transcribing gives up the result")
        suite.expect(late.handle(.transcribed("trop tard")).isEmpty && late.phase == .idle,
                     "a late result is ignored, never pasted")
        suite.expect(late.handle(.delivered(.pasted)).isEmpty, "a stray delivery report does nothing")

        var idle = ForkDictationMachine()
        suite.expect(idle.handle(.escape).isEmpty && idle.handle(.transcribed("perdu")).isEmpty
                        && idle.phase == .idle,
                     "Escape and a stray result do nothing when idle")
    }

    private static func limits(_ suite: TestSuite) {
        var machine = listening()
        suite.expect(machine.handle(.timeLimitNear)
                        == [.present(.listening(handsFree: false, startedAt: t0, nearLimit: true))],
                     "thirty seconds before the limit, the timer turns orange")
        suite.expect(machine.handle(.timeLimitReached) == [.finishCaptureAndTranscribe, .play(.stop), .present(.transcribing)],
                     "the time limit still transcribes what was said")

        var silent = listening()
        silent.handle(.gesture(.none, fn, handsFree: true))
        suite.expect(silent.handle(.silenceLimitReached) == [.discardCapture, .present(.nothingHeard(afterSilence: true))]
                        && silent.phase == .idle,
                     "a forgotten hands-free dictation stops after a silent minute")

        var busy = listening()
        busy.handle(.gesture(.finish, fn, handsFree: false))
        suite.expect(busy.handle(press(rightCommand)) == [.announceBusy, .present(.busy)]
                        && busy.phase == .transcribing(fn),
                     "a press while transcribing is refused, and says so")
        busy.handle(.transcribed("ok"))
        suite.expect(busy.handle(press(fn)) == [.announceBusy, .present(.busy)], "and while pasting")
    }

    private static func failures(_ suite: TestSuite) {
        var machine = listening()
        suite.expect(machine.handle(.failed(.microphoneSilent))
                        == [.discardCapture, .play(.failure), .present(.failure(.microphoneSilent))]
                        && machine.phase == .idle,
                     "a silent microphone stops the dictation instead of pretending")
        suite.expect(machine.handle(press(fn)) == [.prepareEngine, .startCapture],
                     "after a failure, the next press starts again")

        var idle = ForkDictationMachine()
        suite.expect(idle.handle(.failed(.accessibilityMissing))
                        == [.play(.failure), .present(.failure(.accessibilityMissing))] && idle.phase == .idle,
                     "a failure on the press is shown without opening anything")

        var transcribing = listening()
        transcribing.handle(.gesture(.finish, fn, handsFree: false))
        suite.expect(transcribing.handle(.failed(.transcriptionFailed))
                        == [.play(.failure), .present(.failure(.transcriptionFailed))],
                     "a failed transcription has nothing left to drop")
    }

    private static func actions(_ suite: TestSuite) {
        var machine = ForkDictationMachine()
        suite.expect(machine.handle(press(pasteLast)) == [.pasteLast] && machine.phase == .idle,
                     "paste last writes again without listening")
        suite.expect(pasteLast.armingDelay == 0, "and without arming")

        var copying = listening(copy)
        copying.handle(.gesture(.finish, copy, handsFree: false))
        suite.expect(copying.handle(.transcribed("Un texte")) == [.deliver("Un texte", .copy)],
                     "the copy action reaches the delivery")
        suite.expect(copying.handle(.delivered(.copied)) == [.present(.copied(excerpt: "Un texte"))],
                     "and shows copied")

        var kept = listening()
        kept.handle(.gesture(.finish, fn, handsFree: false))
        kept.handle(.transcribed("x"))
        suite.expect(kept.handle(.delivered(.keptInClipboard)) == [.present(.keptInClipboard)],
                     "a paste that could not happen says the text waits for ⌘V")

        var stuck = listening()
        stuck.handle(.gesture(.finish, fn, handsFree: false))
        stuck.handle(.transcribed("x"))
        suite.expect(stuck.handle(.delivered(.inHistoryOnly)) == [.present(.inHistoryOnly)] && stuck.phase == .idle,
                     "a clipboard that never answered says the text is in the history")

        var overtaken = listening()
        overtaken.handle(.gesture(.finish, fn, handsFree: false))
        overtaken.handle(.transcribed("x"))
        suite.expect(overtaken.handle(.delivered(.superseded)) == [.present(.hidden)] && overtaken.phase == .idle,
                     "a paste overtaken by a newer one says nothing of its own")

        var secure = listening()
        suite.expect(secure.handle(.failed(.secureInput(app: "Terminal")))
                        == [.discardCapture, .present(.failure(.secureInput(app: "Terminal")))],
                     "secure input is said without a beep")
    }
}
