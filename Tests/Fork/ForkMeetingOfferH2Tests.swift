// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The offer's interface after the second review: what a screen share may
/// see of it, which microphone it names, how long "Cancel" stays and where
/// it goes, what VoiceOver says again.
enum ForkMeetingOfferH2Tests {
    static func run(_ suite: TestSuite) {
        shares(suite)
        microphone(suite)
        islandCards(suite)
    }

    private static let zero = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let french = ForkMeetingStrings.strings(.fr)

    private static func at(_ seconds: TimeInterval) -> Date { zero.addingTimeInterval(seconds) }

    private static func meet(name: String? = "Point hebdo", code: String? = "abc-defg-hij") -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: ForkMeetingIdentity("meet:" + (code ?? "x")), provider: "meet",
                             providerName: "Google Meet", providerShortName: "Meet", titleName: name, meetCode: code,
                             calendarTitle: nil, windowTitle: "Meet – Point hebdo", appBundle: "com.google.Chrome",
                             pid: 100, windowID: 1, windowBundle: "com.google.Chrome", defaultSound: .app,
                             policy: .ask, silenced: true, bornAt: zero)
    }

    // MARK: - H2.1 Seen in screen shares

    private static func shares(_ suite: TestSuite) {
        let shared = ForkMeetingOfferText.heading(meet(), seenInShares: true, strings: french)
        suite.expect(shared.title == "Google Meet" && shared.subtitle == "Nom masqué pour les partages",
                     "an island seen in shares names the service, never the meeting: \(shared)")
        suite.expect(!(shared.subtitle ?? "").contains("abc-defg-hij") && !shared.title.contains("Point hebdo"),
                     "neither the meeting's name nor its code reach a share")
        let private_ = ForkMeetingOfferText.heading(meet(), seenInShares: false, strings: french)
        suite.expect(private_.title == "Point hebdo" && private_.subtitle == "Google Meet · abc-defg-hij",
                     "out of shares (the bubble, or the island with the setting off) the card names the meeting")
        let unnamed = ForkMeetingOfferText.heading(meet(name: nil), seenInShares: true, strings: french)
        suite.expect(unnamed.title == "Google Meet" && unnamed.subtitle == "Nom masqué pour les partages",
                     "a meeting named after its code hides the code too")
        let fits = AppLanguage.allCases.map(ForkMeetingStrings.strings).allSatisfy {
            !$0.offerNameHidden.isEmpty && $0.offerNameHidden.count <= 28
        }
        suite.expect(fits, "the hidden name's line fits in 28 characters in every language")
    }

    // MARK: - H2.2 The app's microphone

    private static func microphone(_ suite: TestSuite) {
        suite.expect(ForkMeetingOfferInput.of(.meeting, meetingInput: "AirPodsUID") == .meetingApp("AirPodsUID"),
                     "« Automatique » names the input the meeting's app records from")
        suite.expect(ForkMeetingOfferInput.of(.meeting, meetingInput: nil) == .system
                        && ForkMeetingOfferInput.of(.meeting, meetingInput: "") == .system,
                     "an app that records no input leaves the system's, as the start does")
        suite.expect(ForkMeetingOfferInput.of(.system, meetingInput: "AirPodsUID") == .system
                        && ForkMeetingOfferInput.of(.builtIn, meetingInput: "AirPodsUID") == .builtIn
                        && ForkMeetingOfferInput.of(.device("USB"), meetingInput: "AirPodsUID") == .chosen("USB")
                        && ForkMeetingOfferInput.of(.off, meetingInput: "AirPodsUID") == .off,
                     "any other choice names its own microphone, whatever the app uses")
        let microphones = [
            ForkMeetingMicSignal(appBundle: "com.google.Chrome", appPID: 100, pid: 200, inputDevice: "AirPodsUID"),
        ]
        let meeting = meet()
        suite.expect(ForkMeetingOfferInput.of(.meeting, meetingInput: ForkMeetingDetectionSupport.meetingInput(
                        for: meeting, in: microphones)) == .meetingApp("AirPodsUID"),
                     "the offer and the start read the same input: Chrome's AudioService's")
    }

    // MARK: - H2.3, H2.4 The island's cards

    private static func islandCards(_ suite: TestSuite) {
        suite.expect(ForkMeetingIslandCard.islandTakes(available: false, showingThisCard: true),
                     "our card up in the island is changed in place, though the island open on it is not free")
        suite.expect(ForkMeetingIslandCard.islandTakes(available: true, showingThisCard: false)
                        && !ForkMeetingIslandCard.islandTakes(available: false, showingThisCard: false),
                     "a new card opens the island only when it is free")
        suite.expect(ForkMeetingIslandCard.undo.afterClose(undoUntil: at(5), now: at(1)) == .bubble,
                     "the island closed by the first click: « Annuler » goes on in the bubble while it runs")
        suite.expect(ForkMeetingIslandCard.undo.afterClose(undoUntil: at(5), now: at(5)) == .gone
                        && ForkMeetingIslandCard.undo.afterClose(undoUntil: nil, now: at(1)) == .gone,
                     "« Annuler » over, nothing moves to the bubble")
        suite.expect(ForkMeetingIslandCard.offer.afterClose(undoUntil: nil, now: at(1)) == .fold,
                     "an offer the island closed over folds into its reminder: not a « Pas cette fois »")
        suite.expect(ForkMeetingIslandCard.endingSoon.afterClose(undoUntil: at(5), now: at(1)) == .gone,
                     "the countdown stays in the pill alone")
    }
}
