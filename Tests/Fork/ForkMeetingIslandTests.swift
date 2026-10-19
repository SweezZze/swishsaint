// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingIslandTests {
    static func run(_ suite: TestSuite) {
        indicator(suite)
        phases(suite)
        strip(suite)
        pill(suite)
        words(suite)
        texts(suite)
    }

    private static let running = ForkMeetingClock(recordedBefore: 723, runningSince: nil)

    private static func indicator(_ suite: TestSuite) {
        suite.expect(ForkMeetingIndicator(stored: nil) == .auto && ForkMeetingIndicator(stored: "") == .auto
                        && ForkMeetingIndicator(stored: "menuBar") == .auto,
                     "the recording indicator is automatic unless the person chose otherwise")
        suite.expect(ForkMeetingIndicator(stored: "pill") == .pill && ForkMeetingIndicator(stored: "both") == .both,
                     "the pill alone and both are kept as chosen")
        suite.expect(ForkMeetingIndicator.auto.showsStrip && ForkMeetingIndicator.both.showsStrip
                        && !ForkMeetingIndicator.pill.showsStrip,
                     "only the pill alone keeps the recording out of the closed island")
        suite.expect(ForkDefaults.registered[ForkDefaultsKey.meetingsIndicator] as? String == "auto"
                        && ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsIndicator),
                     "the indicator starts automatic and follows the settings backup")
    }

    private static func phases(_ suite: TestSuite) {
        func phase(_ state: ForkMeetingPillState, progress: Double? = nil) -> ForkMeetingIslandPhase? {
            ForkMeetingIslandPhase(state: state, progress: progress)
        }
        suite.expect(phase(.hidden) == nil, "no recording, nothing for the island to show")

        let recording = phase(.recording(running, diskMinutesLeft: nil))
        suite.expect(recording?.mark == .dot && recording?.clockRuns == true && recording?.clockIsAlert == false
                        && recording?.showsLevels == true && recording?.acceptsControls == true && recording?.canMark == true,
                     "recording, the red dot, the time running, the levels, the controls and Mark")
        let disk = phase(.recording(running, diskMinutesLeft: 20))
        suite.expect(disk?.mark == .disk && disk?.clockRuns == true && disk?.clockIsAlert == true,
                     "short of disk, the disk in orange takes the dot's place while the time goes on in orange")

        let paused = phase(.paused(running, .user, diskMinutesLeft: nil))
        suite.expect(paused?.mark == .pause && paused?.clockRuns == false && paused?.clockIsAlert == true
                        && paused?.showsLevels == false && paused?.acceptsControls == true && paused?.canMark == false
                        && paused?.isPaused == true,
                     "paused, the orange bars, the time still and orange, no levels and no mark, but resume and stop")
        suite.expect(phase(.paused(running, .sleep, diskMinutesLeft: 5))?.mark == .pause,
                     "a pause says it is a pause even short of disk")

        let stopping = phase(.stopping)
        let finishing = phase(.finalizing, progress: 0.42)
        suite.expect(stopping?.mark == .gauge && stopping?.acceptsControls == false && stopping?.clockRuns == false
                        && finishing?.mark == .gauge && finishing?.progress == 0.42,
                     "once stopped, a gauge, the time it reached, and no controls left")
        suite.expect(phase(.finalizing, progress: 3)?.progress == 1 && phase(.finalizing, progress: -1)?.progress == 0
                        && phase(.finalizing, progress: .nan)?.progress == 0 && phase(.finalizing)?.progress == nil,
                     "the gauge stays between empty and full, and turns while its share is unknown")
        suite.expect(phase(.finalizing, progress: 0.1)?.mark == phase(.finalizing, progress: 0.9)?.mark
                        && phase(.stopping)?.mark == phase(.finalizing)?.mark,
                     "the mark swaps only when the meaning changes, never as the gauge fills")
    }

    private static func strip(_ suite: TestSuite) {
        let recording = ForkMeetingPillState.recording(running, diskMinutesLeft: nil)
        suite.expect(ForkMeetingIslandRules.showsStrip(enabled: true, indicator: .auto, state: recording)
                        && ForkMeetingIslandRules.showsStrip(enabled: true, indicator: .both, state: .finalizing)
                        && ForkMeetingIslandRules.showsStrip(enabled: true, indicator: .auto, state: .stopping),
                     "the closed island shows the recording from its start until its file is finished")
        suite.expect(!ForkMeetingIslandRules.showsStrip(enabled: true, indicator: .auto, state: .hidden)
                        && !ForkMeetingIslandRules.showsStrip(enabled: true, indicator: .pill, state: recording)
                        && !ForkMeetingIslandRules.showsStrip(enabled: false, indicator: .auto, state: recording),
                     "nothing without a recording, with the pill alone chosen, or with the feature off")
        suite.expect(ForkMeetingIslandRules.clock(723) == "12:03" && ForkMeetingIslandRules.clock(3723) == "1:02:03",
                     "the strip reads the time as the pill does")
    }

    private static func pill(_ suite: TestSuite) {
        let context = ForkMeetingLiveContext()
        func look(_ state: ForkMeetingPillState, _ context: ForkMeetingLiveContext = context,
                  endingSoon: Bool = false) -> ForkMeetingPillLook? {
            ForkMeetingPillLook(state: state, context: context, finalizingProgress: nil, reducesMotion: false,
                                endingSoon: endingSoon)
        }
        let recording = look(.recording(running, diskMinutesLeft: nil))
        func hides(_ indicator: ForkMeetingIndicator, island: Bool = true, _ shown: ForkMeetingPillLook?) -> Bool {
            ForkMeetingIslandRules.hidesPill(indicator: indicator, islandShowsRecording: island, look: shown)
        }
        suite.expect(hides(.auto, recording) && hides(.auto, look(.paused(running, .user, diskMinutesLeft: nil)))
                        && hides(.auto, look(.stopping)) && hides(.auto, look(.finalizing)),
                     "automatic, the pill steps aside while the island shows the recording, paused or finishing")
        suite.expect(!hides(.auto, island: false, recording),
                     "the pill comes back when the island does not show it: hidden, full screen, another activity or display")
        suite.expect(!hides(.both, recording) && !hides(.pill, recording),
                     "with both, or the pill alone, the pill always stays")
        var frozen = context
        frozen.pictureFrozen = true
        var gone = context
        gone.sourceGone = true
        suite.expect(!hides(.auto, look(.recording(running, diskMinutesLeft: nil), endingSoon: true))
                        && !hides(.auto, look(.recording(running, diskMinutesLeft: 12)))
                        && !hides(.auto, look(.recording(running, diskMinutesLeft: nil), frozen))
                        && !hides(.auto, look(.recording(running, diskMinutesLeft: nil), gone)),
                     "the pill comes back for what only it says: the countdown, the disk left, a frozen picture, a filmed app gone")
        suite.expect(!hides(.auto, nil), "a hidden pill has nothing to step aside from")
    }

    private static func words(_ suite: TestSuite) {
        let french = ForkMeetingStrings.strings(.fr), english = ForkMeetingStrings.strings(.enUS)
        let spokenFrench = ForkMeetingIslandRules.spokenDuration(723, language: .fr)
        suite.expect(spokenFrench.contains("12") && spokenFrench.contains("3") && spokenFrench.contains("min"),
                     "VoiceOver says the time recorded in words, minutes then seconds: \(spokenFrench)")
        let hour = ForkMeetingIslandRules.spokenDuration(3723, language: .enUS)
        suite.expect(hour.contains("1") && hour.contains("2") && !hour.contains("3"),
                     "past the hour, hours and minutes, no seconds: \(hour)")
        suite.expect(!ForkMeetingIslandRules.spokenDuration(0, language: .enUS).isEmpty
                        && !ForkMeetingIslandRules.spokenDuration(.nan, language: .ja).isEmpty,
                     "the first second and a clock gone wrong still say something")
        let paused = ForkMeetingIslandRules.value(phase: .paused(diskLow: false), elapsed: 723, language: .fr,
                                                  strings: french)
        suite.expect(paused == spokenFrench + ", en pause", "paused, VoiceOver adds it after the time: \(paused)")
        suite.expect(ForkMeetingIslandRules.value(phase: .recording(diskLow: false), elapsed: 723, language: .fr,
                                                  strings: french) == spokenFrench,
                     "recording, the time alone")
        let finishing = ForkMeetingIslandRules.value(phase: .finalizing(progress: 0.42), elapsed: 723, language: .enUS,
                                                     strings: english)
        suite.expect(finishing.hasPrefix(english.pillFinalizing) && finishing.contains("42"),
                     "finishing, how far the final pass went: \(finishing)")
        suite.expect(ForkMeetingIslandRules.value(phase: .stopping, elapsed: 723, language: .enUS, strings: english)
                        == english.pillStopping,
                     "stopping, the pill's own word")
    }

    /// The live card's buttons and what they say fit the island, in every
    /// language; the paused value keeps its one placeholder.
    private static func texts(_ suite: TestSuite) {
        var tooLong: [String] = []
        var placeholders: [String] = []
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            for text in [strings.cardMark, strings.cardMarked, strings.cardMarkHelp, strings.pauseRecording,
                         strings.resumeRecording, strings.stopRecording, strings.untitledMeeting] where text.count > 28 {
                tooLong.append("\(language.rawValue): \(text)")
            }
            if strings.islandValuePausedFormat.components(separatedBy: "%@").count != 2 {
                placeholders.append(language.rawValue)
            }
            if strings.cardMark == strings.cardMarked || strings.indicatorAuto == strings.indicatorBoth {
                placeholders.append(language.rawValue + " (same words)")
            }
        }
        suite.expect(tooLong.isEmpty, "the live card's buttons fit in 28 characters: \(tooLong)")
        suite.expect(placeholders.isEmpty, "each language keeps the time in its paused value and tells its choices apart: \(placeholders)")
    }
}
