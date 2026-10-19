// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The detection's fixes after the PR 2 reviews (H1): each rule as the
/// person would notice it, played through the resolver and the machine
/// wired as the service wires them.
enum ForkMeetingFixesH1Tests {
    typealias Machine = ForkMeetingMachine
    typealias Effect = ForkMeetingMachine.Effect
    typealias Window = ForkMeetingWindowSignal
    typealias Microphone = ForkMeetingMicSignal
    typealias Support = ForkMeetingDetectionSupport

    static func run(_ suite: TestSuite) {
        codesOnlyInMeetTitles(suite)
        cleanNames(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 10h00", isDirectory: true)
    private static let second = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 11h00", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let recorderBusy = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                            microphoneAllowed: true, officialRecorderBusy: true)
    private static let token1 = ForkMeetingToken(value: 1)
    private static let token2 = ForkMeetingToken(value: 2)
    private static let ownPID: Int32 = 999
    private static let chromePID: Int32 = 100
    private static let codeA = "abc-defg-hij"
    private static let codeB = "xyz-qrst-uvw"
    private static let meetA = ForkMeetingIdentity("meet:abc-defg-hij")
    private static let meetB = ForkMeetingIdentity("meet:xyz-qrst-uvw")
    private static let chromeMicrophone = Microphone(appBundle: "com.google.Chrome", appPID: chromePID, pid: 101,
                                                     processBundle: "com.google.Chrome.helper",
                                                     inputDevice: "BuiltInMicrophoneDevice")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request(_ facts: ForkMeetingStartFacts = ready) -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(settings: settings, facts: facts)
    }

    private static func chrome(_ title: String, window: UInt32 = 7) -> Window {
        Window(bundle: "com.google.Chrome", pid: chromePID, title: title, onScreen: true, windowID: window)
    }

    private static func verdict(_ title: String) -> ForkMeetingTitleVerdict {
        ForkMeetingTitleRules.verdict(title, rules: .googleMeet)
    }

    private static func offers(_ effects: [Effect]) -> [ForkMeetingOffer] {
        effects.compactMap {
            if case let .showOffer(offer) = $0 { return offer }
            return nil
        }
    }

    private static func starts(_ effects: [Effect]) -> [ForkMeetingCaptureConfig] {
        effects.compactMap {
            if case let .startCapture(config, _) = $0 { return config }
            return nil
        }
    }

    private static func stops(_ effects: [Effect]) -> Bool {
        effects.contains {
            if case .stopCapture = $0 { return true }
            return false
        }
    }

    private static func countdowns(_ effects: [Effect]) -> [Date] {
        effects.compactMap {
            if case let .showEndingSoon(until) = $0 { return until }
            return nil
        }
    }

    // MARK: - H1.1

    /// A code counts only in a title Google Meet writes; three, four and
    /// three letters elsewhere are words.
    private static func codesOnlyInMeetTitles(_ suite: TestSuite) {
        let pages = ["Bitcoin hits all-time-low – Le Monde", "Fix the-null-ptr bug · Pull Request",
                     "Comparing main...fix-auth-bug · octo/app · GitHub", "branch fix-auth-bug",
                     "The one-time-pad, explained - YouTube", "Notes: abc-defg-hij"]
        let read = pages.filter { verdict($0) != .none }
        suite.expect(read.isEmpty, "a 3-4-3 word outside a Meet title is not a code: \(read)")
        suite.expect(verdict("Meet – Point hebdo – abc-defg-hij") == .meeting(code: codeA, name: "Point hebdo")
                        && verdict("Meet - abc-defg-hij") == .meeting(code: codeA, name: nil)
                        && verdict("Meet: abc-defg-hij") == .meeting(code: codeA, name: nil)
                        && verdict("abc-defg-hij – Google Meet") == .meeting(code: codeA, name: nil)
                        && verdict("Point hebdo – abc-defg-hij – Google Meet") == .meeting(code: codeA, name: "Point hebdo")
                        && verdict("abc-defg-hij") == .meeting(code: codeA, name: nil),
                     "Meet's own titles keep their code: « Meet – x – code », « Meet - code », « Meet: code », « code – Google Meet »")
        suite.expect(verdict("Meet – Bitcoin hits all-time-low") == .meeting(code: nil, name: "Bitcoin hits all-time-low"),
                     "in a Meet title, a word inside the name is not its code either")
        suite.expect(verdict("Meet - Glass Animals (Official Video) - YouTube")
                        == .meeting(code: nil, name: "Glass Animals (Official Video) - YouTube"),
                     "« Meet - Glass Animals (Official Video) - YouTube » is a name without a code")
    }

    // MARK: - H1.14

    private static func cleanNames(_ suite: TestSuite) {
        let name = ForkMeetingTitleRules.displayName
        suite.expect(name("Point\u{202E}ofni\u{202C} hebdo") == "Pointofni hebdo"
                        && name("\u{2066}Revue\u{2069}") == "Revue",
                     "bidi controls go: a name cannot turn its text around")
        suite.expect(name("Point\nhebdo\t\r\n  équipe\u{0007}") == "Point hebdo équipe"
                        && name("  \u{0000}\u{001B}  ").isEmpty,
                     "control characters go, line breaks and runs of spaces are one space")
        let long = String(repeating: "Comité de pilotage ", count: 12)
        let cut = name(long)
        suite.expect(cut.count <= ForkMeetingTitleRules.nameLimit + 1 && cut.hasSuffix("…") && cut.hasPrefix("Comité de pilotage")
                        && !cut.contains("  "),
                     "a long name is cut near 100 characters, at a word, with « … »")
        suite.expect(name("Point d’équipe — Q4") == "Point d’équipe — Q4", "an ordinary name is kept as it is")

        var meeting = ForkMeetingCandidate(identity: meetA, provider: "meet", providerName: "Google Meet",
                                           providerShortName: "Meet", titleName: nil, meetCode: codeA,
                                           calendarTitle: "Point\u{202E} hebdo\n", appBundle: "com.google.Chrome",
                                           pid: chromePID, windowID: 7, windowBundle: "com.google.Chrome",
                                           defaultSound: .app, policy: .ask, silenced: false, bornAt: at(0))
        suite.expect(meeting.name == "Point hebdo", "the calendar's title is cleaned once, in the meeting's name")
        meeting.calendarTitle = "\u{202E}\n"
        suite.expect(meeting.name == "Google Meet · abc-defg-hij", "a title with nothing left names nothing")
        suite.expect(ForkMeetingDetectionSupport.titleSource(title: meeting.name, meeting: meeting) == .provider,
                     "and its source says so")
        suite.expect(verdict("\u{202E}Meet – Point hebdo") == .meeting(code: nil, name: "Point hebdo"),
                     "a title read past its bidi controls")
    }
}
