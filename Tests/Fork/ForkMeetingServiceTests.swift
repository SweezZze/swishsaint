// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The service's own decisions (`ForkMeetingServiceSupport`), and the texts
/// and machine answers they rely on.
enum ForkMeetingServiceTests {
    typealias Machine = ForkMeetingMachine
    typealias Support = ForkMeetingServiceSupport

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 10h02 — Meeting", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)

    static func run(_ suite: TestSuite) {
        starting(suite)
        shortcut(suite)
        pill(suite)
        notifications(suite)
        filmed(suite)
        displays(suite)
        awake(suite)
        placement(suite)
        texts(suite)
    }

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func start(_ machine: inout Machine, facts: ForkMeetingStartFacts = ready) {
        machine.handle(.manualStart(ForkMeetingStartRequest(settings: settings, facts: facts)), now: t0)
    }

    private static func canStart(_ machine: Machine, wanted: Bool = true, preparing: Bool = false,
                                 terminating: Bool = false) -> Bool {
        Support.canStart(wanted: wanted, machineBusy: machine.isBusy, preparingStart: preparing, terminating: terminating)
    }

    // MARK: - Starting during a final pass

    private static func starting(_ suite: TestSuite) {
        var machine = Machine()
        suite.expect(canStart(machine), "idle and on, a meeting may start")
        suite.expect(!canStart(machine, wanted: false) && !canStart(machine, preparing: true)
                        && !canStart(machine, terminating: true),
                     "not while off, while a start gathers its facts, nor while the app quits")
        start(&machine)
        suite.expect(!canStart(machine), "not while one is starting")
        let token = ForkMeetingToken(value: 1)
        machine.handle(.captureStarted(token, folder: folder), now: t0)
        suite.expect(!canStart(machine), "not while one records")
        machine.handle(.stop, now: at(10))
        suite.expect(!canStart(machine), "not while its file closes")
        let finished = machine.handle(.writerFinished(token, .finished(recordedSeconds: 10)), now: at(10))
        suite.expect(finished.contains(.beginFinalize(folder)) && canStart(machine),
                     "once the file is closed, the next meeting may start while the first one is finalized (§3.2 n° 44)")
        start(&machine)
        suite.expect(machine.handle(.captureStarted(ForkMeetingToken(value: 2), folder: folder), now: at(11))
                        .contains(.notice(.started)),
                     "and it records, the first meeting's pass still running beside it")
    }

    // MARK: - The shortcut

    private static func shortcut(_ suite: TestSuite) {
        var machine = Machine()
        suite.expect(Support.press(phase: machine.phase, preparingStart: false, canStart: true) == .start
                        && Support.press(phase: machine.phase, preparingStart: false, canStart: false) == .ignore,
                     "idle, the shortcut starts a meeting when one may start, else does nothing")
        suite.expect(Support.press(phase: machine.phase, preparingStart: true, canStart: false) == .cancelStart,
                     "pressed again while the microphone and the disk are asked, it cancels the start")
        start(&machine)
        suite.expect(Support.press(phase: machine.phase, preparingStart: false, canStart: false) == .cancelStart,
                     "pressed again while the capture starts, it cancels it")
        let cancelled = machine.handle(.stop, now: at(1))
        suite.expect(machine.phase == .idle && cancelled.contains(.stopCapture(ForkMeetingToken(value: 1)))
                        && !cancelled.contains { if case .writeSidecar = $0 { return true }; return false }
                        && !cancelled.contains { if case .beginFinalize = $0 { return true }; return false },
                     "a start cancelled records nothing: no meeting.json written, nothing finalized")
        start(&machine)
        let token = ForkMeetingToken(value: 2)
        machine.handle(.captureStarted(token, folder: folder), now: t0)
        suite.expect(Support.press(phase: machine.phase, preparingStart: false, canStart: false) == .stop,
                     "recording, it stops")
        machine.handle(.pause, now: at(2))
        suite.expect(Support.press(phase: machine.phase, preparingStart: false, canStart: false) == .stop,
                     "paused, it stops too")
        machine.handle(.stop, now: at(3))
        suite.expect(Support.press(phase: machine.phase, preparingStart: false, canStart: false) == .ignore,
                     "while the file closes, a press has nothing to stop or start")
    }

    // MARK: - The pill

    private static func pill(_ suite: TestSuite) {
        let clock = ForkMeetingClock(recordedBefore: 0, runningSince: t0)
        suite.expect(Support.pill(.hidden, finalizing: true) == .finalizing && Support.pill(.hidden, finalizing: false) == .hidden,
                     "a start cancelled while the last meeting is finalized leaves the pill on its gauge")
        suite.expect(Support.pill(.recording(clock, diskMinutesLeft: nil), finalizing: true) == .recording(clock, diskMinutesLeft: nil),
                     "a new recording takes the pill even while the last meeting is finalized")
        suite.expect(Support.hidesFinishedPill(machineIdle: true, finalizingCount: 0, pill: .finalizing),
                     "the gauge goes once the last pass is done and nothing records")
        suite.expect(!Support.hidesFinishedPill(machineIdle: true, finalizingCount: 1, pill: .finalizing)
                        && !Support.hidesFinishedPill(machineIdle: false, finalizingCount: 0, pill: .finalizing)
                        && !Support.hidesFinishedPill(machineIdle: true, finalizingCount: 0,
                                                      pill: .recording(clock, diskMinutesLeft: nil)),
                     "but not while another meeting's pass runs, nor while a session runs, nor over a recording")
    }

    // MARK: - Notifications

    private static func notifications(_ suite: TestSuite) {
        suite.expect(Support.notifies(shownInIsland: false, shownInBubble: false, canNotify: true),
                     "a notice nothing could show (the screen locked) becomes a notification")
        suite.expect(!Support.notifies(shownInIsland: true, shownInBubble: false, canNotify: true)
                        && !Support.notifies(shownInIsland: false, shownInBubble: true, canNotify: true),
                     "shown in the island or the bubble, it is not said twice")
        suite.expect(!Support.notifies(shownInIsland: false, shownInBubble: false, canNotify: false),
                     "a bare build that cannot notify never tries")
    }

    // MARK: - What is filmed

    private static func filmed(_ suite: TestSuite) {
        let fr = ForkMeetingStrings.strings(.fr), en = ForkMeetingStrings.strings(.enUS)
        suite.expect(Support.filmed(target: .window, appName: "Google Chrome", noWindowToFilm: false, strings: fr)
                        == "Fenêtre\u{00A0}: Google Chrome"
                        && Support.filmed(target: .window, appName: "Google Chrome", noWindowToFilm: false, strings: en)
                        == "Google Chrome window",
                     "the window filmed is named by its app")
        suite.expect(Support.filmed(target: .display, appName: "Google Chrome", noWindowToFilm: false, strings: fr) == "Écran entier",
                     "the display filmed is the whole screen")
        suite.expect(Support.filmed(target: .display, appName: nil, noWindowToFilm: true, strings: fr) == fr.filmedNoWindow
                        && fr.filmedNoWindow != fr.filmedDisplay,
                     "a window asked for and none to film says so")
        suite.expect(Support.filmed(target: .window, appName: "  ", noWindowToFilm: false, strings: en) == en.filmedWindowUnnamed,
                     "a window whose app has no name is still said to be a window")
        var tooLong: [String] = []
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            for text in [strings.filmedWindow("Chrome"), strings.filmedWindowUnnamed, strings.filmedDisplay,
                         strings.filmedNoWindow, strings.pillFilmTheWindow, strings.failMasterHidden]
                where text.count > 28 {
                tooLong.append("\(language.rawValue): \(text)")
            }
            if !strings.filmedWindow("Chrome").contains("Chrome") { tooLong.append("\(language.rawValue): no app") }
        }
        suite.expect(tooLong.isEmpty, "what is filmed fits the pill in every language, the app named: \(tooLong)")
    }

    // MARK: - Displays

    private static func displays(_ suite: TestSuite) {
        suite.expect(!Support.filmedDisplayChanged(filmed: 1, holdingNow: 1, active: [1, 2]),
                     "a display plugged in elsewhere changes nothing in the picture, and says nothing")
        suite.expect(!Support.filmedDisplayChanged(filmed: 1, holdingNow: nil, active: [1]),
                     "a display unplugged elsewhere says nothing either")
        suite.expect(Support.filmedDisplayChanged(filmed: 2, holdingNow: 1, active: [1]),
                     "the filmed display unplugged: the change is said")
        suite.expect(Support.filmedDisplayChanged(filmed: 1, holdingNow: 2, active: [1, 2]),
                     "the filmed window moved to another display: the change is said")
        suite.expect(!Support.filmedDisplayChanged(filmed: nil, holdingNow: 2, active: [1, 2]),
                     "a display never known says nothing")
    }

    // MARK: - Awake

    private static func awake(_ suite: TestSuite) {
        var machine = Machine()
        suite.expect(Support.awake(phase: machine.phase) == .free, "idle, nothing is held")
        start(&machine)
        suite.expect(Support.awake(phase: machine.phase) == .app, "starting, the app stays awake")
        let token = ForkMeetingToken(value: 1)
        machine.handle(.captureStarted(token, folder: folder), now: t0)
        suite.expect(Support.awake(phase: machine.phase) == .display,
                     "recording, the display stays on: a meeting listened to must not lock the Mac")
        machine.handle(.pause, now: at(5))
        suite.expect(Support.awake(phase: machine.phase) == .app,
                     "paused by the person, the display may turn off and the Mac lock, however long the pause")
        machine.handle(.resume, now: at(65))
        machine.handle(.willSleep, now: at(70))
        suite.expect(Support.awake(phase: machine.phase) == .app, "paused by a sleep, the display is not held either")
        machine.handle(.didWake, now: at(80))
        suite.expect(Support.awake(phase: machine.phase) == .display, "back to recording, the display is held again")
        machine.handle(.stop, now: at(90))
        suite.expect(Support.awake(phase: machine.phase) == .app, "closing its file, only the app stays awake")
    }

    // MARK: - The pill's place

    private static func placement(_ suite: TestSuite) {
        let size = ForkMeetingPillLayout.restingSize
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        // The official recorder's pill: 150 pt, centred under the menu bar.
        let official = CGRect(x: visible.midX - 75, y: visible.maxY - 10 - 32, width: 150, height: 32)
        let plain = ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: visible, cameraRightEdge: nil,
                                                        islandFrame: nil)
        suite.expect(!CGRect(origin: plain, size: size).intersects(official)
                        && plain.x == official.maxX + ForkMeetingPillLayout.gap,
                     "without a camera or an island, the pill sits just right of the official recorder's pill, never over it")
        let narrowIsland = CGRect(x: visible.midX - 50, y: 1056, width: 100, height: 24)
        let island = ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: visible, cameraRightEdge: nil,
                                                         islandFrame: narrowIsland)
        suite.expect(!CGRect(origin: island, size: size).intersects(official),
                     "an island narrower than the official pill does not bring it back over it")
    }

    // MARK: - Texts and answers

    private static func texts(_ suite: TestSuite) {
        var machine = Machine()
        start(&machine, facts: ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                    microphoneAllowed: false, officialRecorderBusy: false))
        let effects = machine.handle(.captureStarted(ForkMeetingToken(value: 1), folder: folder), now: t0)
        suite.expect(effects.contains(.announce(.startedWithoutMicrophone)) && !effects.contains(.announce(.started)),
                     "VoiceOver hears at the start that the microphone is left out, in one sentence")
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { strings in
                        ForkMeetingAnnouncement.startedWithoutMicrophone.text(strings) != strings.voiceStarted
                            && !strings.voicePictureFrozen.isEmpty
                     },
                     "the start without a microphone and the frozen picture have their own sentence in every language")
        suite.expect(ForkMeetingFailure.masterHidden.action == .openMeetingsFolder && !ForkMeetingFailure.masterHidden.isLasting
                        && all.allSatisfy { $0.failMasterHiddenRemedy.contains(".recording.mp4") },
                     "a master left hidden says, in every language, the name it is under")
        suite.expect(all.allSatisfy { strings in
                        strings.pictureFrontWindow != strings.pictureFrontDisplay
                            && strings.pillFilmTheWindow != strings.pillFilmDisplay
                            && strings.filmedDisplay != strings.filmedNoWindow
                     },
                     "the picture's two choices, ⧉'s two labels and what is filmed never read alike")
        let english = ForkMeetingStrings.strings(.enUS), french = ForkMeetingStrings.strings(.fr)
        let page = [english.pictureFrontWindow, english.pictureFrontWindowCaption, english.consentIntroFrontWindow,
                    english.voiceFilmedDisplayChanged, english.pillFilmTheWindow]
        let pageFr = [french.pictureFrontWindow, french.pictureFrontWindowCaption, french.consentIntroFrontWindow,
                      french.voiceFilmedDisplayChanged, french.pillFilmTheWindow]
        suite.expect(page.allSatisfy { !$0.contains("meeting window") && !$0.contains("meeting’s window") }
                        && pageFr.allSatisfy { !$0.contains("fenêtre de la réunion") },
                     "nothing speaks of the meeting's window while no meeting is detected: it is the window in front")
    }
}
