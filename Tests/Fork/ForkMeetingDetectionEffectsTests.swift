// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The service's side of the detection: when it runs, when its clock
/// ticks, which input "Meeting microphone (auto)" records, what the offer
/// says it records, the calendar's links, and the page's words.
enum ForkMeetingDetectionEffectsTests {
    typealias Machine = ForkMeetingMachine
    typealias Support = ForkMeetingDetectionSupport

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 10h02 — Point hebdo", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)

    static func run(_ suite: TestSuite) {
        running(suite)
        clock(suite)
        meetingMicrophone(suite)
        offerCapture(suite)
        freeSpace(suite)
        calendarLinks(suite)
        pageTexts(suite)
        sidecar(suite)
        sound(suite)
        codeLeavesTheTitle(suite)
    }

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request() -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(settings: settings, facts: ready)
    }

    private static func candidate(policy: ForkMeetingPolicy = .ask) -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: ForkMeetingIdentity("meet:abc-defg-hij"), provider: "meet",
                             providerName: "Google Meet", providerShortName: "Meet", titleName: "Point hebdo",
                             meetCode: "abc-defg-hij", calendarTitle: nil, windowTitle: "Meet – Point hebdo – abc-defg-hij",
                             appBundle: "com.google.Chrome", pid: 100, windowID: 7, windowBundle: "com.google.Chrome",
                             defaultSound: .app, policy: policy, silenced: false, bornAt: at(0))
    }

    private static func running(_ suite: TestSuite) {
        suite.expect(Support.runs(wanted: true, consentAcknowledged: true, terminating: false),
                     "the detection runs once the feature is on and its first-use sheet confirmed")
        suite.expect(!Support.runs(wanted: false, consentAcknowledged: true, terminating: false)
                        && !Support.runs(wanted: true, consentAcknowledged: false, terminating: false)
                        && !Support.runs(wanted: true, consentAcknowledged: true, terminating: true),
                     "nothing is read with the feature off, before the sheet is confirmed, or while the app quits")
    }

    private static func clock(_ suite: TestSuite) {
        var machine = Machine()
        suite.expect(!Support.clockRuns(phase: machine.phase), "idle: no clock")
        machine.handle(.candidates([candidate()], request()), now: at(0))
        suite.expect(Support.clockRuns(phase: machine.phase), "an offer up: the clock ticks, for it to fold after 20 s")
        machine.handle(.accept(request()), now: at(1))
        suite.expect(!Support.clockRuns(phase: machine.phase), "starting: no clock")
        machine.handle(.captureStarted(ForkMeetingToken(value: 1), folder: folder), now: at(2))
        suite.expect(!Support.clockRuns(phase: machine.phase), "recording an offered meeting: no clock")
        machine.handle(.endProbable(ForkMeetingIdentity("meet:abc-defg-hij"), countdown: 15), now: at(60))
        suite.expect(Support.clockRuns(phase: machine.phase), "the countdown runs: the clock ticks")
        machine.handle(.tick, now: at(75))
        suite.expect(!Support.clockRuns(phase: machine.phase), "stopping: no clock")

        var always = Machine()
        always.handle(.candidates([candidate(policy: .always)], request()), now: at(0))
        always.handle(.captureStarted(ForkMeetingToken(value: 1), folder: folder), now: at(1))
        suite.expect(Support.clockRuns(phase: always.phase), "started by Always: the clock ticks while Cancel can be used")
        always.handle(.tick, now: at(6.5))
        suite.expect(!Support.clockRuns(phase: always.phase), "Cancel expired: no clock any more")
    }

    private static func meetingMicrophone(_ suite: TestSuite) {
        let helper = ForkMeetingMicSignal(appBundle: "com.google.Chrome", appPID: 100, pid: 101,
                                          processBundle: "com.google.Chrome.helper", inputDevice: "AirPods-UID")
        let other = ForkMeetingMicSignal(appBundle: "com.apple.VoiceMemos", appPID: 300, pid: 300,
                                         inputDevice: "BuiltInMicrophoneDevice")
        let deviceless = ForkMeetingMicSignal(appBundle: "com.google.Chrome", appPID: 100, pid: 102)
        suite.expect(Support.meetingInput(for: candidate(), in: [other, helper]) == "AirPods-UID",
                     "Meeting microphone (auto) records the input Chrome's audio helper uses")
        suite.expect(Support.meetingInput(for: candidate(), in: [other, deviceless]) == nil
                        && Support.meetingInput(for: nil, in: [helper]) == nil
                        && Support.meetingInput(for: candidate(), in: []) == nil,
                     "another app's input, an unknown device or no meeting: the system's input")
    }

    private static func offerCapture(_ suite: TestSuite) {
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(Support.offerCapture(window: "Chrome", sound: "Chrome", microphone: "AirPods", strings: french)
                        == "Fenêtre\u{00A0}: Chrome · son\u{00A0}: Chrome · micro\u{00A0}: AirPods"
                        && Support.offerCapture(window: "Chrome", sound: french.offerWholeMac, microphone: "AirPods",
                                                strings: french) == "Fenêtre\u{00A0}: Chrome · son\u{00A0}: tout le Mac · micro\u{00A0}: AirPods",
                     "the offer says the window, the sound and the microphone it records")
        suite.expect(Support.offerCapture(window: "Chrome", sound: nil, microphone: "AirPods", strings: french)
                        == "Fenêtre\u{00A0}: Chrome · micro\u{00A0}: AirPods"
                        && Support.offerCapture(window: "Chrome", sound: "Chrome", microphone: nil, strings: french)
                        == "Fenêtre\u{00A0}: Chrome · son\u{00A0}: Chrome"
                        && Support.offerCapture(window: "Chrome", sound: nil, microphone: nil, strings: french)
                        == "Fenêtre\u{00A0}: Chrome",
                     "a sound or a microphone turned off is left out, never named as nothing")
        suite.expect(AppLanguage.allCases.map(ForkMeetingStrings.strings).allSatisfy { strings in
                        let line = Support.offerCapture(window: "Chrome", sound: nil, microphone: "AirPods", strings: strings)
                        return line.contains("Chrome") && line.contains("AirPods")
                            && line.components(separatedBy: " · ").count == 2
                     },
                     "every language keeps its parts apart, so one can be left out")
    }

    private static func freeSpace(_ suite: TestSuite) {
        suite.expect(Support.freeSpaceIsStale(readAt: nil, now: at(0))
                        && !Support.freeSpaceIsStale(readAt: at(0), now: at(14))
                        && Support.freeSpaceIsStale(readAt: at(0), now: at(15))
                        && Support.freeSpaceIsStale(readAt: at(10), now: at(0)),
                     "the free space for an offer is read again after 15 s, and when the clock went back")
    }

    private static func calendarLinks(_ suite: TestSuite) {
        let rules = ForkMeetingTitleRules.self
        suite.expect(rules.meetCode(inLink: "https://meet.google.com/abc-defg-hij?authuser=0&hs=122") == "abc-defg-hij"
                        && rules.meetCode(inLink: "Rejoindre avec Google Meet : MEET.GOOGLE.COM/ABC-DEFG-HIJ") == "abc-defg-hij"
                        && rules.meetCode(inLink: "Salle 2\nhttps://meet.google.com/xyz-qrst-uvw") == "xyz-qrst-uvw",
                     "an event's address, notes or place gives the code of its Google Meet link, lowercased")
        suite.expect(rules.meetCode(inLink: "Code : abc-defg-hij") == nil
                        && rules.meetCode(inLink: "https://meet.google.com/lookup/abcdefghij") == nil
                        && rules.meetCode(inLink: "https://meet.google.com/abc-defg-hijk") == nil
                        && rules.meetCode(inLink: "https://zoom.us/j/123456789") == nil
                        && rules.meetCode(inLink: "") == nil,
                     "a code outside a link, a lookup link, a longer path or another service: no code")
        suite.expect(rules.meetCode(inLink: "meet.google.com/new puis https://meet.google.com/abc-defg-hij") == "abc-defg-hij",
                     "a link without a code before the real one does not hide it")

        var resolver = ForkMeetingResolver(ownPID: 999)
        let tab = ForkMeetingWindowSignal(bundle: "com.google.Chrome", pid: 100, title: "Meet – abc-defg-hij",
                                          onScreen: true, windowID: 1)
        let hint = ForkMeetingCalendarHint(title: "Point hebdo équipe", meetCode: rules.meetCode(inLink:
                                               "https://meet.google.com/abc-defg-hij"), startsAt: at(-60), endsAt: at(1800))
        _ = resolver.resolve(ForkMeetingReading(at: at(0), windows: [tab], calendar: [hint]))
        let named = resolver.resolve(ForkMeetingReading(at: at(3), windows: [tab])).candidates.first?.name
        suite.expect(named == "Point hebdo équipe",
                     "a meeting whose tab shows only its code takes the name of the event linking to it")
        let cleared = resolver.resolve(ForkMeetingReading(at: at(6), windows: [tab], calendar: [])).candidates.first?.name
        suite.expect(cleared == "Google Meet · abc-defg-hij",
                     "the calendar turned off: the name goes back to the provider and the code")
    }

    private static func pageTexts(_ suite: TestSuite) {
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { strings in
                        Set([strings.policyAsk, strings.policyAlways, strings.policyNever]).count == 3
                            && Set([strings.policyAskCaption, strings.policyAlwaysCaption, strings.policyNeverCaption]).count == 3
                            && strings.detected("Point hebdo").contains("Point hebdo")
                            && strings.detectionTitlesOnly.contains("14.4")
                            && strings.policyAlwaysCaption.contains("5")
                            && strings.policyAskCaption.contains("20")
                     },
                     "every language has three distinct choices per provider, names the detected meeting, and says the 14.4 limit")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(french.detectionTitle == "Détection" && french.policyAsk == "Proposer" && french.policyAlways == "Toujours"
                        && french.policyNever == "Jamais" && french.calendarNaming == "Nommer avec le calendrier"
                        && french.autoStop == "Arrêter automatiquement à la fin de la réunion"
                        && french.detected("Point hebdo") == "Réunion détectée\u{00A0}: Point hebdo",
                     "the French page reads as the plan writes it")
        suite.expect(all.allSatisfy { !$0.microphoneMeetingCaption.isEmpty }
                        && !french.microphoneMeetingCaption.contains("Pour l’instant"),
                     "Meeting microphone (auto) no longer says it is the system's for now")
    }

    private static func sidecar(_ suite: TestSuite) {
        var meeting = candidate()
        suite.expect(Support.titleSource(title: meeting.name, meeting: meeting) == .window
                        && Support.titleSource(title: "Mon nom", meeting: meeting) == .user
                        && Support.titleSource(title: "Mon nom", meeting: nil) == .user
                        && Support.titleSource(title: nil, meeting: meeting) == nil,
                     "a name from the meeting's title says so; one given otherwise is the person's")
        meeting.titleName = nil
        meeting.calendarTitle = "Point hebdo équipe"
        suite.expect(Support.titleSource(title: meeting.name, meeting: meeting) == .calendar,
                     "a name from the calendar event says so")
        meeting.calendarTitle = nil
        suite.expect(meeting.name == "Google Meet · abc-defg-hij"
                        && Support.titleSource(title: meeting.name, meeting: meeting) == .provider,
                     "with neither, the provider and the code name it")
        let started = ForkMeetingSidecar.started(id: UUID(), startedAt: at(0), origin: .offered, title: meeting.name,
                                                 titleSource: .provider, capture: ForkMeetingSidecar.Capture(),
                                                 provider: meeting.provider, meetCode: meeting.meetCode,
                                                 app: meeting.appBundle)
        suite.expect(started.origin == .offered && started.provider == "meet" && started.meetCode == "abc-defg-hij"
                        && started.app == "com.google.Chrome" && started.titleSource == .provider,
                     "a detected meeting's first meeting.json names its provider, its code and its app")
        let manual = ForkMeetingSidecar.started(id: UUID(), startedAt: at(0), origin: .manual, title: nil,
                                                titleSource: nil, capture: ForkMeetingSidecar.Capture())
        suite.expect(manual.provider == nil && manual.meetCode == nil && manual.app == nil,
                     "a recording by hand with no meeting names none")
    }

    private static func sound(_ suite: TestSuite) {
        var faceTime = candidate()
        faceTime.defaultSound = .all
        var chosen = settings
        suite.expect(Support.settings(chosen, for: faceTime).systemAudio == .all
                        && Support.settings(chosen, for: candidate()).systemAudio == .app
                        && Support.settings(chosen, for: nil).systemAudio == .app,
                     "the meeting app's sound is the whole Mac for a provider whose calls no app carries, only for it")
        chosen.systemAudio = .off
        suite.expect(Support.settings(chosen, for: faceTime).systemAudio == .off,
                     "a sound turned off stays off")
        chosen.systemAudio = .all
        suite.expect(Support.settings(chosen, for: faceTime) == chosen, "the whole Mac chosen stays the whole Mac")
    }

    /// Seen in the recipe: the same tab showing its title without the code
    /// a moment made a second meeting, offered again.
    private static func codeLeavesTheTitle(_ suite: TestSuite) {
        var resolver = ForkMeetingResolver(ownPID: 999)
        func tab(_ title: String, window: UInt32 = 1) -> ForkMeetingWindowSignal {
            ForkMeetingWindowSignal(bundle: "com.google.Chrome", pid: 100, title: title, onScreen: true, windowID: window)
        }
        let microphone = ForkMeetingMicSignal(appBundle: "com.google.Chrome", appPID: 100, pid: 101)
        _ = resolver.resolve(ForkMeetingReading(at: at(-5), microphones: [microphone]))
        _ = resolver.resolve(ForkMeetingReading(at: at(0), windows: [tab("Meet – Point hebdo – abc-defg-hij")]))
        _ = resolver.resolve(ForkMeetingReading(at: at(3), windows: [tab("Gmail")]))
        let renamed = resolver.resolve(ForkMeetingReading(at: at(6), windows: [tab("Meet – Point hebdo")]))
        let again = resolver.resolve(ForkMeetingReading(at: at(9), windows: [tab("Meet – Point hebdo")]))
        suite.expect(renamed.candidates.map(\.identity.value) == ["meet:abc-defg-hij"]
                        && again.candidates.map(\.identity.value) == ["meet:abc-defg-hij"]
                        && again.candidates.first?.meetCode == "abc-defg-hij",
                     "the meeting's window showing its title without the code is still that meeting")
        let other = resolver.resolve(ForkMeetingReading(at: at(12), windows: [tab("Meet – Point hebdo – abc-defg-hij"),
                                                                              tab("Meet – Revue", window: 2)]))
        _ = other
        let later = resolver.resolve(ForkMeetingReading(at: at(15), windows: [tab("Meet – Point hebdo – abc-defg-hij"),
                                                                              tab("Meet – Revue", window: 2)]))
        suite.expect(Set(later.candidates.map(\.identity.value)) == ["meet:abc-defg-hij", "meet:100:Meet – Revue"],
                     "another window without a code stays another meeting")
    }
}
