// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The offer's interface: where it shows, when it folds, what its lines and
/// its countdowns say.
enum ForkMeetingOfferTests {
    static func run(_ suite: TestSuite) {
        surfaces(suite)
        folding(suite)
        countdowns(suite)
        captureLine(suite)
        names(suite)
        texts(suite)
        pillCountdown(suite)
    }

    private static let zero = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { zero.addingTimeInterval(seconds) }

    private static func meet(name: String? = "Point hebdo", code: String? = "abc-defg-hij",
                             calendar: String? = nil, window: UInt32? = 1) -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: ForkMeetingIdentity("meet:" + (code ?? "x")), provider: "meet",
                             providerName: "Google Meet", providerShortName: "Meet", titleName: name, meetCode: code,
                             calendarTitle: calendar, windowTitle: "Meet – Point hebdo", appBundle: "com.google.Chrome",
                             pid: 100, windowID: window, windowBundle: "com.google.Chrome", defaultSound: .app,
                             policy: .ask, silenced: true, bornAt: zero)
    }

    // MARK: - Where

    private static func surfaces(_ suite: TestSuite) {
        suite.expect(ForkMeetingOfferSurface.choose(folded: false, islandAvailable: true, islandTurnedAway: false) == .island,
                     "an offer opens in the island when it is free")
        suite.expect(ForkMeetingOfferSurface.choose(folded: false, islandAvailable: false, islandTurnedAway: false) == .bubble,
                     "an island turned off, open on something else or hidden in full screen gives the bubble")
        suite.expect(ForkMeetingOfferSurface.choose(folded: false, islandAvailable: true, islandTurnedAway: true) == .bubble,
                     "once the island turned the offer away it stays in the bubble: no back and forth")
        suite.expect([true, false].allSatisfy { available in
                        [true, false].allSatisfy { away in
                            ForkMeetingOfferSurface.choose(folded: true, islandAvailable: available,
                                                           islandTurnedAway: away) == .reminder
                        }
                     },
                     "a folded offer is its grey reminder, wherever it was open")
    }

    // MARK: - When it folds

    private static func folding(_ suite: TestSuite) {
        var fold = ForkMeetingOfferFold.opened()
        suite.expect(fold.due == nil && !fold.isDue(at: at(60)),
                     "an offer the machine opened waits for the machine's 20 s, never folds on its own")
        fold.ask(at: at(20))
        suite.expect(fold.isDue(at: at(20)), "the machine's fold folds it at once when the pointer is elsewhere")

        var held = ForkMeetingOfferFold.opened()
        held.hover(true, at: at(15))
        held.ask(at: at(20))
        suite.expect(!held.isDue(at: at(20)) && !held.isDue(at: at(90)),
                     "the pointer resting on the offer holds the fold, however long")
        held.hover(false, at: at(95))
        suite.expect(!held.isDue(at: at(96)) && held.isDue(at: at(95 + ForkMeetingOfferFold.grace)),
                     "it folds \(ForkMeetingOfferFold.grace) s after the pointer leaves, so a click on its way lands")

        var left = ForkMeetingOfferFold.opened()
        left.hover(true, at: at(5))
        left.hover(false, at: at(8))
        suite.expect(left.due == nil, "the pointer passing over an offer the machine has not folded starts no clock")

        var reopened = ForkMeetingOfferFold.reopened(at: at(100))
        suite.expect(!reopened.isDue(at: at(119)) && reopened.isDue(at: at(120)),
                     "opened again from its reminder, it folds back on its own 20 s later")
        reopened.hover(true, at: at(110))
        suite.expect(!reopened.isDue(at: at(125)), "the pointer holds it there too")
        reopened.hover(false, at: at(130))
        suite.expect(!reopened.isDue(at: at(149)) && reopened.isDue(at: at(150)),
                     "and once it leaves, the 20 s count again in full, as the bubble's cards do")
        suite.expect(ForkMeetingOfferFold.reopenedHold == ForkMeetingMachine.offerCollapse,
                     "an offer opened again stays as long as the first time")
    }

    // MARK: - Countdowns

    private static func countdowns(_ suite: TestSuite) {
        let until = at(15)
        suite.expect(ForkMeetingOfferTiming.secondsLeft(until: until, now: at(0)) == 15
                        && ForkMeetingOfferTiming.secondsLeft(until: until, now: at(2.8)) == 13
                        && ForkMeetingOfferTiming.secondsLeft(until: until, now: at(14.9)) == 1,
                     "the seconds left are rounded up: never 0 while there is still time to press")
        suite.expect(ForkMeetingOfferTiming.secondsLeft(until: until, now: at(15)) == 0
                        && ForkMeetingOfferTiming.secondsLeft(until: until, now: at(40)) == 0,
                     "over, it reads 0, never a negative number")
        let start = ForkMeetingOfferTiming.tickStart(until: until, now: at(2.8))
        let offset = until.timeIntervalSince(start)
        suite.expect(start <= at(2.8) && offset == offset.rounded(),
                     "the once-a-second redraw ticks when the number changes, not up to a second late")

        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingOfferText.endingSoon(until: at(12), now: at(0), strings: french)
                        == "Réunion terminée\u{00A0}? Arrêt dans 12 s"
                        && ForkMeetingOfferText.endingSoon(until: at(12), now: at(11.5), strings: french)
                        == "Réunion terminée\u{00A0}? Arrêt dans 1 s",
                     "the pill reads « Réunion terminée ? Arrêt dans 12 s », the seconds going down")
        suite.expect(ForkMeetingOfferText.undo(until: at(5), now: at(0), strings: french) == "Annuler (5 s)"
                        && ForkMeetingOfferText.undo(until: at(5), now: at(4.5), strings: french) == "Annuler (1 s)",
                     "« Annuler (5 s) » counts down to its last second")
        var tooLong: [String] = []
        for language in AppLanguage.allCases {
            let s = ForkMeetingStrings.strings(language)
            for text in [ForkMeetingOfferText.undo(until: at(5), now: at(0), strings: s),
                         s.endingSoon(seconds: 300), s.endingSoonTitle] where text.count > 28 {
                tooLong.append("\(language.rawValue): \(text)")
            }
        }
        suite.expect(tooLong.isEmpty, "the countdowns' parts fit in 28 characters in every language: \(tooLong)")
    }

    // MARK: - What will be recorded

    private static func captureLine(_ suite: TestSuite) {
        let french = ForkMeetingStrings.strings(.fr)
        func line(_ target: ForkMeetingCaptureTarget = .window, window: String? = "Arc", hasWindow: Bool = true,
                  sound: ForkMeetingSystemAudio = .app, soundApp: String? = "Arc",
                  microphone: ForkMeetingOfferMicrophone = .named("AirPods"),
                  _ strings: ForkMeetingStrings = french) -> String {
            ForkMeetingOfferText.capture(target: target, windowApp: window, hasWindow: hasWindow, sound: sound,
                                         soundApp: soundApp, microphone: microphone, strings: strings)
        }
        suite.expect(line() == "Fenêtre\u{00A0}:\u{00A0}Arc · son\u{00A0}:\u{00A0}Arc · micro\u{00A0}:\u{00A0}AirPods",
                     "the French line is « Fenêtre : Arc · son : Arc · micro : AirPods », never « Fenêtre de Arc »")
        suite.expect(line(sound: .all) == "Fenêtre\u{00A0}:\u{00A0}Arc · son\u{00A0}:\u{00A0}tout\u{00A0}le\u{00A0}Mac · micro\u{00A0}:\u{00A0}AirPods",
                     "the whole Mac's sound says so")
        suite.expect(line(sound: .off, microphone: .off) == "Fenêtre\u{00A0}:\u{00A0}Arc · son\u{00A0}:\u{00A0}aucun · micro\u{00A0}:\u{00A0}aucun",
                     "no sound and no microphone read « aucun »")
        suite.expect(line(microphone: .denied).hasSuffix("micro\u{00A0}:\u{00A0}non\u{00A0}autorisé"),
                     "a microphone macOS does not allow says so before the start")
        suite.expect(line(.display) == "Écran entier · son\u{00A0}:\u{00A0}Arc · micro\u{00A0}:\u{00A0}AirPods"
                        && line(hasWindow: false) == line(.display) && line(window: nil) == line(.display),
                     "the display chosen, or no window to film, films the whole screen and says it")
        suite.expect(line(soundApp: nil).contains("son\u{00A0}:\u{00A0}Arc") && line(window: nil, soundApp: nil).contains("son\u{00A0}:\u{00A0}aucun"),
                     "an app sound without its app's name takes the window's, else says none")
        suite.expect(ForkMeetingOfferText.sound(setting: .app, providerDefault: .all) == .all
                        && ForkMeetingOfferText.sound(setting: .app, providerDefault: .app) == .app
                        && ForkMeetingOfferText.sound(setting: .off, providerDefault: .all) == .off,
                     "FaceTime, heard from a system process, records the whole Mac when the app's sound is asked")
        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(line(sound: .all, english) == "Window:\u{00A0}Arc · sound:\u{00A0}whole\u{00A0}Mac · mic:\u{00A0}AirPods",
                     "English reads label then value too")
        var missing: [String] = []
        for language in AppLanguage.allCases {
            let s = ForkMeetingStrings.strings(language)
            let window = line(window: "Chrome", soundApp: "Safari", microphone: .named("AirPods"), s)
            let display = line(.display, soundApp: "Safari", microphone: .off, s)
            if !["Chrome", "Safari", "AirPods"].allSatisfy(window.contains) { missing.append("\(language.rawValue): \(window)") }
            if !display.contains("Safari") || !display.contains(s.offerNone) || display.contains("Chrome") {
                missing.append("\(language.rawValue): \(display)")
            }
        }
        suite.expect(missing.isEmpty, "every language names the window, the sound and the microphone: \(missing)")
        let wrapped = line(microphone: .named("AirPods d’Alice"))
        suite.expect(wrapped.hasSuffix("micro\u{00A0}:\u{00A0}AirPods\u{00A0}d’Alice")
                        && wrapped.components(separatedBy: " ").count == 5,
                     "the line wraps only between its parts: never inside « micro : AirPods d’Alice »")
        let japanese = line(microphone: .named("AirPods"), ForkMeetingStrings.strings(.ja))
        suite.expect(japanese.contains("マ\u{2060}イ\u{2060}ク\u{2060}：\u{2060}AirPods"),
                     "nor after a full-width colon, where Japanese would break before the name")
        let longName = String(repeating: "Microphone ", count: 4)
        suite.expect(line(microphone: .named(longName)).contains("Microphone Microphone"),
                     "a name too long for one line may still wrap rather than overflow")
        let values = AppLanguage.allCases.map(ForkMeetingStrings.strings).flatMap {
            [$0.offerNone, $0.offerMicrophoneDenied, $0.offerWholeMac]
        }
        suite.expect(values.allSatisfy { $0.count <= 28 && !$0.isEmpty }, "the line's values are short words")
    }

    private static func names(_ suite: TestSuite) {
        suite.expect(ForkMeetingOfferText.subtitle(meet()) == "Google Meet · abc-defg-hij",
                     "under a named meeting: the service and its code")
        suite.expect(ForkMeetingOfferText.subtitle(meet(name: nil)) == nil,
                     "a meeting named « Google Meet · abc-defg-hij » does not say it twice")
        suite.expect(ForkMeetingOfferText.subtitle(meet(name: nil, code: nil)) == nil,
                     "nor one named after its service alone")
        suite.expect(ForkMeetingOfferText.subtitle(meet(name: nil, calendar: "Point hebdo")) == "Google Meet · abc-defg-hij",
                     "a meeting named by its calendar event shows its service and code under it")
        suite.expect(ForkMeetingOfferText.reminderTitle(meet()) == "Meet", "the reminder reads « ○ Meet »")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingOfferText.blocked(.officialRecorderBusy, strings: french)
                        == "Un enregistrement d’écran est en cours.",
                     "greyed while the official recorder runs, it says « Un enregistrement d’écran est en cours »")
        suite.expect(ForkMeetingOfferText.blocked(.screenRecordingDenied, strings: french)
                        == ForkMeetingFailure.screenRecordingDenied.summary(french),
                     "greyed for another reason, it says the refusal's own words")
    }

    private static func texts(_ suite: TestSuite) {
        let languages = AppLanguage.allCases
        suite.expect(languages.map(ForkMeetingStrings.strings).allSatisfy { s in
                        s.offerCaptureDisplay(sound: "Safari", microphone: "AirPods").contains("Safari")
                            && s.offerCaptureDisplay(sound: "Safari", microphone: "AirPods").contains("AirPods")
                     },
                     "every language names the sound and the microphone of a whole-screen recording")
        let french = ForkMeetingStrings.strings(.fr)
        let frenchLine = [french.offerCaptureFormat, french.offerCaptureDisplayFormat]
        suite.expect(frenchLine.allSatisfy { !$0.contains(" :") && $0.contains("\u{00A0}:") },
                     "the French line puts a no-break space before each colon")
        let labelled = languages.map(ForkMeetingStrings.strings).filter { s in
            [s.offerCaptureFormat, s.offerCaptureDisplayFormat].allSatisfy { $0.contains(":") || $0.contains("：") }
        }
        suite.expect(labelled.count == languages.count,
                     "every language writes the line « label: value », so a name needs no article")
    }

    // MARK: - In the pill

    private static func pillCountdown(_ suite: TestSuite) {
        let running = ForkMeetingClock(recordedBefore: 30, runningSince: nil)
        let context = ForkMeetingLiveContext()
        let ending = ForkMeetingPillLook(state: .recording(running, diskMinutesLeft: 25), context: context,
                                         finalizingProgress: nil, reducesMotion: false, endingSoon: true)
        suite.expect(ending?.status == .endingSoon && ending?.showsClock == false && ending?.showsControls == true,
                     "during the countdown the pill says it, before even the disk, in place of the time")
        let still = ForkMeetingPillLook(state: .recording(running, diskMinutesLeft: nil), context: context,
                                        finalizingProgress: nil, reducesMotion: true, endingSoon: true)
        suite.expect(still?.mark == .recording(pulses: false), "with Reduce Motion its dot stays still")
        let paused = ForkMeetingPillLook(state: .paused(running, .user, diskMinutesLeft: nil), context: context,
                                         finalizingProgress: nil, reducesMotion: false, endingSoon: true)
        suite.expect(paused?.status == .paused, "a pause takes the countdown away: the pill says paused")
        let plain = ForkMeetingPillLook(state: .recording(running, diskMinutesLeft: nil), context: context,
                                        finalizingProgress: nil, reducesMotion: false)
        suite.expect(plain?.status == .meters && plain?.showsClock == true, "without a countdown nothing changes")
    }
}
