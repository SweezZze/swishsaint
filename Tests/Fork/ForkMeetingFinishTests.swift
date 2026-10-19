// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The finish's parts, made to agree: one way to mark a moment for every
/// entry, a meeting recorded without picture in the island, the page's
/// switches over the newer notices, and the updater waiting for a summary.
enum ForkMeetingFinishTests {
    static func run(_ suite: TestSuite) {
        markers(suite)
        soundOnly(suite)
        notifications(suite)
        updates(suite)
        pillStaysForWarnings(suite)
    }

    private static func markers(_ suite: TestSuite) {
        suite.expect(ForkMeetingIslandRules.markedHold >= ForkMeetingMarkers.mergeWindow,
                     "the card's \"Marked\" lasts as long as a second press would be the same moment")
        suite.expect(ForkMeetingMarkers.showsNotice(liveCardShown: false) && !ForkMeetingMarkers.showsNotice(liveCardShown: true),
                     "a marker's notice shows, except while the live card is up to say it itself")
        let strings = AppLanguage.allCases.map { ForkMeetingStrings.strings($0) }
        suite.expect(strings.allSatisfy { $0.voiceMarked("00:12:03").contains("00:12:03") },
                     "VoiceOver hears the time marked, in every language")
    }

    private static func soundOnly(_ suite: TestSuite) {
        var context = ForkMeetingLiveContext()
        context.target = .window
        context.canSwitchTarget = true
        suite.expect(context.offersTargetSwitch, "a filmed window offers to film the screen instead")
        context.target = .audioOnly
        suite.expect(!context.offersTargetSwitch,
                     "a meeting recorded for its sound alone offers neither the screen nor the window, even with a window known")
        context.target = .display
        context.canSwitchTarget = false
        suite.expect(!context.offersTargetSwitch, "nor does a display filmed without a window to come back to")
        for language in AppLanguage.allCases {
            let text = ForkMeetingStrings.strings(language)
            let filmed = ForkMeetingServiceSupport.filmed(target: .audioOnly, appName: "Zoom", noWindowToFilm: false, strings: text)
            if filmed != text.soundOnly
                || ForkMeetingIslandRules.label(target: .audioOnly, strings: text) == text.pillRecording
                || !ForkMeetingIslandRules.label(target: .audioOnly, strings: text).contains(text.soundOnly)
                || ForkMeetingIslandRules.label(target: .window, strings: text) != text.pillRecording {
                suite.expect(false, "\(language.rawValue): the card and the strip say \"sound only\" for a meeting without picture")
                return
            }
        }
        suite.expect(true, "the card and the strip say \"sound only\" for a meeting without picture, in every language")
        let clock = ForkMeetingClock(recordedBefore: 0, runningSince: Date())
        let states: [ForkMeetingPillState] = [.recording(clock, diskMinutesLeft: nil), .paused(clock, .user, diskMinutesLeft: nil)]
        for state in states {
            let look = ForkMeetingPillLook(state: state, context: context, finalizingProgress: nil, reducesMotion: false)
            suite.expect(ForkMeetingIslandRules.hidesPill(indicator: .auto, islandShowsRecording: true, look: look)
                            && !ForkMeetingIslandRules.hidesPill(indicator: .auto, islandShowsRecording: false, look: look),
                         "without picture, the pill steps aside for the island's strip just as with one")
        }
    }

    private static func notifications(_ suite: TestSuite) {
        let allOff: (ForkMeetingNotifyEvent) -> Bool = { _ in false }
        suite.expect(ForkMeetingNotifyEvent.event(of: .marked) == nil && ForkMeetingNotifyEvent.shows(.marked, isOn: allOff),
                     "a moment marked answers a press: no switch silences it")
        suite.expect(ForkMeetingNotifyEvent.allCases.count == 5,
                     "five switches on the page: the summary's word follows the transcripts' and exports' one")
    }

    /// A summary runs for minutes on a long meeting: the updater, which
    /// quits the app, waits for it as for a transcript.
    private static func updates(_ suite: TestSuite) {
        let before = ForkMeetingActivity.tally
        guard !before.isBusy else { return suite.expect(false, "the activity starts idle") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        var idle = 0
        let observer = NotificationCenter.default.addObserver(forName: ForkMeetingActivity.didBecomeIdle, object: nil,
                                                              queue: nil) { _ in idle += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        ForkMeetingActivity.setTranscribing(true)
        ForkMeetingActivity.setSummarizing(true)
        ForkMeetingActivity.setTranscribing(false)
        settle()
        suite.expect(ForkMeetingActivity.isBusy && idle == 0,
                     "a summary still running keeps the updater waiting once the transcript is done")
        ForkMeetingActivity.setSummarizing(false)
        settle()
        suite.expect(!ForkMeetingActivity.isBusy && idle == 1 && ForkMeetingActivity.tally == before,
                     "the updater hears idle once, when the summary ends")
    }

    private static func pillStaysForWarnings(_ suite: TestSuite) {
        let clock = ForkMeetingClock(recordedBefore: 0, runningSince: Date())
        let context = ForkMeetingLiveContext()
        let look = ForkMeetingPillLook(state: .recording(clock, diskMinutesLeft: nil), context: context,
                                       finalizingProgress: nil, reducesMotion: false)
        func hides(_ context: ForkMeetingLiveContext) -> Bool {
            ForkMeetingIslandRules.hidesPill(indicator: .auto, islandShowsRecording: true, look: look, context: context)
        }
        var silent = context
        silent.microphoneSilent = true
        var noApp = context
        noApp.trackSound = .noApp
        var lost = context
        lost.trackSound = .lost
        suite.expect(hides(context) && !hides(silent) && !hides(noApp) && !hides(lost),
                     "the pill never steps aside while the microphone sends nothing or the meeting's sound is not heard")
        let island = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let other = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        suite.expect(ForkMeetingIslandRules.islandShowsRecording(activityShown: true, islandScreen: island, filmedScreen: island,
                                                                 workedScreen: other)
                        && !ForkMeetingIslandRules.islandShowsRecording(activityShown: true, islandScreen: island,
                                                                        filmedScreen: other, workedScreen: island)
                        && ForkMeetingIslandRules.islandShowsRecording(activityShown: true, islandScreen: island,
                                                                       filmedScreen: nil, workedScreen: island)
                        && !ForkMeetingIslandRules.islandShowsRecording(activityShown: false, islandScreen: island,
                                                                        filmedScreen: island, workedScreen: island),
                     "the pill steps aside only for the island of the display filmed, never for a copy it supposes on another")
        let recording = ForkMeetingIslandPhase(state: .recording(clock, diskMinutesLeft: nil), progress: nil)!
        var muted = context
        muted.microphoneSilent = true
        var off = muted
        off.recordsMicrophone = false
        suite.expect(ForkMeetingIslandRules.showsMicrophoneMuted(ForkMeetingIslandSnapshotFacts(phase: recording, context: muted))
                        && !ForkMeetingIslandRules.showsMicrophoneMuted(ForkMeetingIslandSnapshotFacts(phase: recording, context: context))
                        && !ForkMeetingIslandRules.showsMicrophoneMuted(ForkMeetingIslandSnapshotFacts(phase: recording, context: off)),
                     "the strip crosses out a recorded microphone that sends nothing, not one left off")
    }
}
