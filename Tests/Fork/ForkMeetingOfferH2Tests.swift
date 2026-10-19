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
        undoWindow(suite)
        voiceOver(suite)
        discarded(suite)
        menu(suite)
        undoCardWords(suite)
        undoLabel(suite)
        pageDelay(suite)
    }

    private static let zero = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let french = ForkMeetingStrings.strings(.fr)

    private static func at(_ seconds: TimeInterval) -> Date { zero.addingTimeInterval(seconds) }

    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 10h02 — Point hebdo", isDirectory: true)
    private static let token1 = ForkMeetingToken(value: 1)

    private static func request() -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(
            settings: ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                 quality: .standard),
            facts: ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                         microphoneAllowed: true, officialRecorderBusy: false,
                                         // Its browser uses the microphone: "Always" may start it.
                                         meetingsOnMicrophone: [meet().identity]))
    }

    /// A meeting "Always" started at 1 s, VoiceOver on or off.
    private static func autoStarted(voiceOver: Bool) -> (ForkMeetingMachine, [ForkMeetingMachine.Effect]) {
        var machine = ForkMeetingMachine()
        var meeting = meet()
        meeting.silenced = false
        meeting.policy = .always
        machine.handle(.candidates([meeting], request()), now: zero)
        machine.voiceOver = voiceOver
        let effects = machine.handle(.captureStarted(token1, folder: folder), now: at(1))
        return (machine, effects)
    }

    private static func meet(name: String? = "Point hebdo", code: String? = "abc-defg-hij") -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: ForkMeetingIdentity("meet:" + (code ?? "x")), provider: "meet",
                             providerName: "Google Meet", providerShortName: "Meet", titleName: name, meetCode: code,
                             calendarTitle: nil, appBundle: "com.google.Chrome",
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

    // MARK: - H2.5 "Cancel" with VoiceOver, and the pill's stop

    private static func undoWindow(_ suite: TestSuite) {
        let (plain, plainEffects) = autoStarted(voiceOver: false)
        suite.expect(plainEffects.contains(.showUndo(until: at(6))) && plainEffects.contains(.announce(.autoStarted(seconds: 5)))
                        && plain.activeSession?.undoUntil == at(6),
                     "without VoiceOver « Annuler » stays 5 s")
        var spoken = autoStarted(voiceOver: true)
        suite.expect(spoken.1.contains(.showUndo(until: at(16))) && spoken.1.contains(.announce(.autoStarted(seconds: 15)))
                        && spoken.0.activeSession?.undoUntil == at(16),
                     "with VoiceOver it stays 15 s, and the announcement says 15: \(spoken.1)")
        suite.expect(spoken.0.handle(.tick, now: at(6)).isEmpty && spoken.0.handle(.cancelAutoStart, now: at(15)).contains(.hideUndo),
                     "a cancel at 14 s still cancels with VoiceOver")
        suite.expect(ForkMeetingMachine.undoWindow(voiceOver: false) == 5 && ForkMeetingMachine.undoWindow(voiceOver: true) == 15,
                     "5 s, 15 s with VoiceOver")
        suite.expect(ForkMeetingOfferTiming.pillStopCancels(undoUntil: at(6), now: at(3))
                        && !ForkMeetingOfferTiming.pillStopCancels(undoUntil: at(6), now: at(6))
                        && !ForkMeetingOfferTiming.pillStopCancels(undoUntil: nil, now: at(3)),
                     "the pill's stop cancels while « Annuler » runs, and stops once it is over")
        let labels = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(labels.allSatisfy { !$0.pillStopCancels.isEmpty && $0.pillStopCancels != $0.pillStop },
                     "the pill's stop says it cancels, in every language")
    }

    // MARK: - H2.7 VoiceOver

    /// The sentences a presenter would say for these effects, in order.
    private static func said(_ effects: [ForkMeetingMachine.Effect]) -> [String] {
        var spoken = ForkMeetingSpoken()
        var said: [String] = []
        for effect in effects {
            if case let .announce(announcement) = effect, spoken.says(announcement.text(french)) {
                said.append(announcement.text(french))
            }
            if ForkMeetingSpoken.forgets(after: effect) { spoken.forget() }
        }
        return said
    }

    private static func voiceOver(_ suite: TestSuite) {
        let countdown = ForkMeetingMachine.Effect.announce(.endingSoon(seconds: 15))
        suite.expect(said([countdown, .hideEndingSoon, countdown]).count == 2,
                     "a second countdown is said in full once the first is gone")
        suite.expect(said([countdown, countdown]).count == 1, "the same sentence twice in a row is said once")
        let offered = ForkMeetingMachine.Effect.announce(.offered("Point hebdo"))
        suite.expect(said([offered, .hideOffer, offered]).count == 2, "an offer offered again is said again")
        suite.expect(said([offered, .showPill(.hidden), offered]).count == 2
                        && said([offered, .collapseOffer, offered]).count == 1,
                     "the recording's pill gone forgets too; a fold does not")

        var machine = ForkMeetingMachine()
        var meeting = meet()
        meeting.silenced = false
        machine.handle(.candidates([meeting], request()), now: zero)
        machine.handle(.accept(request()), now: at(1))
        machine.handle(.captureStarted(token1, folder: folder), now: at(2))
        machine.handle(.endProbable(meeting.identity, countdown: 15), now: at(600))
        let back = machine.handle(.candidates([meeting], request()), now: at(605))
        suite.expect(back == [.hideEndingSoon, .announce(.meetingBack)]
                        && said(back) == ["La réunion continue\u{00A0}: l’enregistrement ne s’arrête pas."],
                     "its meeting back during the countdown, VoiceOver hears « La réunion continue »: \(back)")
        let again = machine.handle(.endProbable(meeting.identity, countdown: 15), now: at(700))
        suite.expect(said(back + again).last == ForkMeetingAnnouncement.endingSoon(seconds: 15).text(french),
                     "and the next countdown is said again")
    }

    // MARK: - H2.8 After "Cancel"

    private struct Refused: Error {}

    private static func discarded(_ suite: TestSuite) {
        var removed = false
        suite.expect(ForkMeetingDiscardOutcome.discard(trash: {}, remove: { removed = true }) == .trashed && !removed,
                     "a cancelled recording goes to the Trash, never deleted when it can")
        suite.expect(ForkMeetingDiscardOutcome.discard(trash: { throw Refused() }, remove: {}) == .deleted,
                     "a volume without a Trash deletes it")
        suite.expect(ForkMeetingDiscardOutcome.discard(trash: { throw Refused() }, remove: { throw Refused() }) == .kept,
                     "neither: it is kept, and said so")
        suite.expect(ForkMeetingNotice.discarded(.trashed).title(french) == "Annulé · mis à la Corbeille",
                     "« Annulé · mis à la Corbeille »")
        let kept = ForkMeetingNotice.discarded(.kept)
        suite.expect(kept.title(french) == "Annulé · dossier non jeté"
                        && kept.detail(french) == "Il reste avec vos réunions"
                        && ForkMeetingDiscardOutcome.kept.spoken(french).contains("il reste avec vos réunions"),
                     "a folder that stayed is never said deleted, on the screen or to VoiceOver")
        let outcomes: [ForkMeetingDiscardOutcome] = [.trashed, .deleted, .kept]
        let languages = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(languages.allSatisfy { s in
                        let titles = outcomes.map { ForkMeetingNotice.discarded($0).title(s) }
                        let voices = outcomes.map { $0.spoken(s) }
                        return Set(titles).count == 3 && Set(voices).count == 3
                            && (titles + [s.noticeDiscardKeptDetail]).allSatisfy { !$0.isEmpty && $0.count <= 28 }
                     },
                     "three outcomes, three notices of 28 characters at most, three sentences, in every language")
    }

    // MARK: - H2.10 The ⋯ menu

    private static func menu(_ suite: TestSuite) {
        let open = ForkMeetingOffer(candidate: meet(), collapsesAt: at(20))
        var greyed = open
        greyed.blocked = .officialRecorderBusy
        suite.expect(ForkMeetingOfferText.allowsAlways(open) && !ForkMeetingOfferText.allowsAlways(greyed),
                     "« Toujours pour Meet » records now: greyed with the offer")
        let copied = ForkMeetingNotice.announcementCopied
        suite.expect(copied.title(french) == "Annonce copiée" && copied.detail(french) == "À coller dans la discussion",
                     "« Copier l’annonce » shows a short notice, not only VoiceOver")
        let languages = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(languages.allSatisfy { s in
                        [copied.title(s), copied.detail(s) ?? ""].allSatisfy { !$0.isEmpty && $0.count <= 28 }
                     },
                     "its two lines fit in 28 characters in every language")
    }

    // MARK: - H2.11 The "Cancel" card says it started on its own

    private static func undoCardWords(_ suite: TestSuite) {
        suite.expect(french.undoAutoStarted("Meet") == "Démarré seul · Toujours pour Meet",
                     "« Démarré seul · Toujours pour Meet »")
        suite.expect(AppLanguage.allCases.map(ForkMeetingStrings.strings).allSatisfy { $0.undoAutoStarted("Meet").contains("Meet") },
                     "every language names the provider")
    }

    // MARK: - H2.12 "Cancel (5 s)" for VoiceOver

    private static func undoLabel(_ suite: TestSuite) {
        // The button's title and its VoiceOver name are the same words of
        // the same second (`ForkMeetingCardView.actionButton`).
        let words = (0...4).map { ForkMeetingOfferText.undo(until: at(5), now: at(Double($0) + 0.5), strings: french) }
        suite.expect(words == ["Annuler (5 s)", "Annuler (4 s)", "Annuler (3 s)", "Annuler (2 s)", "Annuler (1 s)"],
                     "the words VoiceOver reads go down with the seconds: \(words)")
        suite.expect(ForkMeetingOfferTiming.tickStart(until: at(5), now: at(0.4)) <= at(0.4),
                     "its timeline ticks from the past, on whole seconds before the end")
    }

    // MARK: - H2.13 The page's delay

    private static func pageDelay(_ suite: TestSuite) {
        suite.expect(ForkMeetingAutoStop.bounded(3) == 5 && ForkMeetingAutoStop.bounded(500) == 120
                        && ForkMeetingAutoStop.bounded(30) == 30,
                     "a stored delay out of 5–120 s reads as its bound")
        suite.expect([-4, 0, 3, 5, 15, 120, 121, 9999].allSatisfy { seconds in
                        ForkMeetingAutoStop(enabled: true, seconds: seconds).countdown
                            == TimeInterval(ForkMeetingAutoStop.bounded(seconds))
                     },
                     "the page shows the delay the countdown really gives")
    }
}
