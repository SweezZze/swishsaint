// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingTitleRulesTests {
    static func run(_ suite: TestSuite) {
        meetingTitles(suite)
        refusedTitles(suite)
        realTitles(suite)
        exitTitles(suite)
        codes(suite)
        names(suite)
    }

    private static func verdict(_ title: String) -> ForkMeetingTitleVerdict {
        ForkMeetingTitleRules.verdict(title, rules: .googleMeet)
    }

    private static func isMeeting(_ title: String) -> Bool {
        if case .meeting = verdict(title) { return true }
        return false
    }

    /// bran's accepted titles, in French and English, every dash.
    private static func meetingTitles(_ suite: TestSuite) {
        let titles = ["Meet - abc-defg-hij", "Meet – abc-defg-hij", "Meet — abc-defg-hij", "Réunion équipe - Google Meet",
                      "Meet - Point hebdo", "abc-defg-hij - Google Meet", "Team sync – Google Meet", "Meet – Weekly sync",
                      "Point hebdo — Google Meet", "abc-defg-hij", "MEET – Point hebdo", "Meet–Point hebdo"]
        let missed = titles.filter { !isMeeting($0) }
        suite.expect(missed.isEmpty, "a code, \"Meet – name\" or \"name – Google Meet\" is a meeting, with any dash: \(missed)")
    }

    private static func refusedTitles(_ suite: TestSuite) {
        let titles = [
            // False positives bran already refused.
            "Slack | #meeting", "Meeting notes - Notion", "Meeting notes – Notion", "Zoom Meeting",
            "Comment démarrer avec Google Meet - Documentation", "Meetup – Paris Swift",
            // Home and waiting pages.
            "Google Meet", "Meet", "meet", "Meet - Google Meet", "Meet – Google Meet", "Google Meet - Accueil",
            "Google Meet – Home",
            // No title: Screen Recording is off.
            "", "   ",
            // A tab loading, a new tab, in both languages.
            "Sans titre", "Untitled", "Nouvel onglet", "New Tab",
        ]
        let accepted = titles.filter(isMeeting)
        suite.expect(accepted.isEmpty, "notes, chats, home pages, waiting pages and blank tabs are not meetings: \(accepted)")
        suite.expect(titles.allSatisfy { verdict($0) == .none }, "and none of them ends a meeting either")
    }

    /// Every title the S2 spike read from a real Chrome (155, fr-FR).
    private static func realTitles(_ suite: TestSuite) {
        suite.expect(verdict("Meet") == .none,
                     "meet.google.com/abc-defg-hij with a wrong code, in French or English: the code is in the address, not the title")
        suite.expect(verdict("Google Meet : conférences télé…es en ligne | Google Workspace") == .none,
                     "meet.google.com without an account leads to Google Workspace's page: not a meeting")
        suite.expect(verdict("Sans titre") == .none, "a tab still loading is not a meeting")
        suite.expect(verdict("Meet – Point hebdomadaire de l'…vec la direction – abc-defg-hij")
                        == .meeting(code: "abc-defg-hij", name: "Point hebdomadaire de l'…vec la direction"),
                     "a long title Chrome cut in the middle keeps its code at the end, and its name with the cut")
        suite.expect(verdict("Traduire cette page ?") == .none && verdict("Translate this page?") == .none,
                     "Chrome's translate bubble is a window of its own, not a meeting")
        suite.expect(verdict("Choisissez ce qui doit être partagé avec http://127.0.0.1:18765") == .none
                        && verdict("Choisissez ce qui doit être partagé avec https://meet.google.com") == .none
                        && verdict("Choose what to share with https://meet.google.com") == .none,
                     "nor is its share picker, even for Meet")
        suite.expect(verdict("S2 mic ON") == .none, "a page using the microphone is no meeting by its title")
        suite.expect(verdict("meet.google.com partage votre écran") == .none
                        && verdict("meet.google.com is sharing your screen.") == .none,
                     "Chrome's sharing bar is no meeting either")
    }

    private static func exitTitles(_ suite: TestSuite) {
        let exits = ["Vous avez quitté la réunion", "You left the meeting", "You’ve left the meeting",
                     "You've left the meeting", "Meet – Vous avez quitté la réunion", "Vous avez quitté la réunion – abc-defg-hij",
                     "Vous avez quitte\u{0301} la re\u{0301}union"]
        let missed = exits.filter { verdict($0) != .exit }
        suite.expect(missed.isEmpty, "a page saying the call is over ends the meeting, whatever its apostrophe, accents or code: \(missed)")
        suite.expect(verdict("Meeting notes – Notion") != .exit && verdict("Meet – Point hebdo") != .exit,
                     "an ordinary title ends nothing")
    }

    private static func codes(_ suite: TestSuite) {
        suite.expect(ForkMeetingTitleRules.meetCode(in: "Meet - abc-defg-hij") == "abc-defg-hij"
                        && ForkMeetingTitleRules.meetCode(in: "Meet – xyz-qrst-uvw") == "xyz-qrst-uvw"
                        && ForkMeetingTitleRules.meetCode(in: "Meet – ABC-DEFG-HIJ") == "abc-defg-hij",
                     "the code is read, in lower case")
        suite.expect(ForkMeetingTitleRules.meetCode(in: "Meet - Point hebdo") == nil,
                     "a named meeting has no code")
        let lookalikes = ["une-suite-de-mots-ici", "abcd-defg-hij", "abc-defgh-hij", "xabc-defg-hij", "abc-defg-hijk",
                          "abc-de1g-hij", "1abc-defg-hij", "abc_defg_hij", "abc-defg-hi"]
        let read = lookalikes.filter { ForkMeetingTitleRules.meetCode(in: $0) != nil }
        suite.expect(read.isEmpty, "words joined by dashes are not a code: \(read)")
        suite.expect(ForkMeetingTitleRules.meetCode(in: "…bc-defg-hij") == nil
                        && ForkMeetingTitleRules.meetCode(in: "(abc-defg-hij)") == "abc-defg-hij",
                     "a code cut by Chrome is not read; one in brackets is")
    }

    private static func names(_ suite: TestSuite) {
        suite.expect(verdict("Meet – Point hebdo") == .meeting(code: nil, name: "Point hebdo")
                        && verdict("Point hebdo – Google Meet") == .meeting(code: nil, name: "Point hebdo"),
                     "the meeting's name comes from either side of the title")
        suite.expect(verdict("Meet – abc-defg-hij") == .meeting(code: "abc-defg-hij", name: nil)
                        && verdict("abc-defg-hij - Google Meet") == .meeting(code: "abc-defg-hij", name: nil)
                        && verdict("abc-defg-hij") == .meeting(code: "abc-defg-hij", name: nil),
                     "a code alone is no name")
        suite.expect(verdict("Meet – Point hebdo – abc-defg-hij") == .meeting(code: "abc-defg-hij", name: "Point hebdo"),
                     "the name loses the code beside it")
        suite.expect(verdict("Meet\u{00A0}–  Point   hebdo ") == .meeting(code: nil, name: "Point hebdo"),
                     "no-break and repeated spaces are read as one space")
        suite.expect(verdict("Meet – Point…hebdo") == .meeting(code: nil, name: "Point…hebdo")
                        && verdict("Point hebdomadaire…ction – Google Meet") == .meeting(code: nil, name: "Point hebdomadaire…ction"),
                     "Chrome's \"…\" is part of the name, never a separator")
    }
}
