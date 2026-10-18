// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The second round of fixes of the meetings' first part: each rule as
/// the person would notice it.
enum ForkMeetingFixesG1Tests {
    static func run(_ suite: TestSuite) {
        noAppToHear(suite)
        tapLost(suite)
        switching(suite)
        verdicts(suite)
        failedPassShown(suite)
        startAttempts(suite)
        recoveryLeavesLiveMeetings(suite)
        bidiNames(suite)
    }

    typealias Machine = ForkMeetingMachine

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 10h02 — Meeting", isDirectory: true)
    private static let token1 = ForkMeetingToken(value: 1)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A machine starting (token 1) since `t0`.
    private static func starting(target: ForkMeetingCaptureTarget = .window,
                                 sound: ForkMeetingSystemAudio = .app) -> Machine {
        var machine = Machine()
        let settings = ForkMeetingCaptureSettings(target: target, systemAudio: sound, microphone: "meeting",
                                                  quality: .standard)
        machine.handle(.manualStart(ForkMeetingStartRequest(settings: settings, facts: ready)), now: t0)
        return machine
    }

    /// A machine recording since `t0`, with session token 1.
    private static func recording(target: ForkMeetingCaptureTarget = .window,
                                  sound: ForkMeetingSystemAudio = .app) -> Machine {
        var machine = starting(target: target, sound: sound)
        machine.handle(.captureStarted(token1, folder: folder), now: t0)
        return machine
    }

    private static func patches(_ effects: [Machine.Effect]) -> [ForkMeetingSidecarPatch] {
        effects.compactMap {
            if case let .writeSidecar(_, patch) = $0 { return patch }
            return nil
        }
    }

    /// The app's sound asked for and no app to hear: silence, said, never
    /// the whole Mac in its place.
    private static func noAppToHear(_ suite: TestSuite) {
        let own: Int32 = 100
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: nil, ownPID: own, filmsWindow: false,
                                                   tapAvailable: true) == .none,
                     "a display filmed with no window in front: no app to hear, the meeting track stays silent")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: 200, ownPID: own, filmsWindow: false,
                                                   tapAvailable: false) == .none,
                     "before macOS 14.4 a display's stream is the whole Mac: never written for the app's sound")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: own, ownPID: own, filmsWindow: true,
                                                   tapAvailable: true) == .none
                        && ForkMeetingSoundSource.choose(.app, appPID: own, ownPID: own, filmsWindow: true,
                                                         tapAvailable: false) == .none,
                     "a window of this app has no meeting to hear")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: 200, ownPID: own, filmsWindow: true,
                                                   tapAvailable: false) == .stream,
                     "before macOS 14.4 a window of another app is still heard through its own stream")
        suite.expect(ForkMeetingSoundSource.appTap(pid: 200).refused(filmsWindow: false) == .none
                        && ForkMeetingSoundSource.appTap(pid: 200).refused(filmsWindow: true) == .stream
                        && ForkMeetingSoundSource.macTap.refused(filmsWindow: false) == .stream,
                     "a tap the audio system refuses: the app's gives way to a window's stream only, the Mac's to the stream")
        suite.expect(ForkMeetingSoundSource.none.heard(filmsWindow: false) == .off && !ForkMeetingSoundSource.none.streamListens,
                     "meeting.json then says the track heard nothing, and the stream does not even listen")

        let appOnly = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false, appOnly: true)
        suite.expect(appOnly.streamWrites(filmsWindow: true) && !appOnly.streamWrites(filmsWindow: false),
                     "a stream standing for the app's sound writes while a window is filmed, never once ⧉ films the display")
        let whole = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false)
        suite.expect(whole.streamWrites(filmsWindow: false) && whole.streamWrites(filmsWindow: true),
                     "the whole Mac asked for: the stream writes whatever is filmed")

        let silent = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false)
        suite.expect(ForkMeetingTrackSound.of(setting: .app, sound: .none, arbiter: silent, filmsWindow: false) == .noApp
                        && ForkMeetingTrackSound.of(setting: .app, sound: .stream, arbiter: appOnly, filmsWindow: false) == .noApp
                        && ForkMeetingTrackSound.of(setting: .app, sound: .stream, arbiter: appOnly, filmsWindow: true) == .heard,
                     "the pill and the start's card say when the app's sound has no app to hear")
        suite.expect(ForkMeetingTrackSound.of(setting: .off, sound: .none, arbiter: silent, filmsWindow: false) == .heard
                        && ForkMeetingTrackSound.of(setting: .all, sound: .stream, arbiter: whole, filmsWindow: false) == .heard,
                     "nothing is said when the sound is off by choice, or the whole Mac is heard")
        let app = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        suite.expect(ForkMeetingTrackSound.of(setting: .app, sound: .appTap(pid: 200), arbiter: app, filmsWindow: false) == .heard,
                     "the app's tap hears its app, a display filmed or not")

        let strings = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(strings.allSatisfy { $0.soundNoApp.count <= 28 && !$0.soundNoAppDetail.isEmpty
                                            && $0.soundAppNoAppCaption.contains($0.soundAll) },
                     "the pill's line fits in 28 characters, and the page names the choice to make, in every language")
    }

    /// A tap that lost its reader for good: the stream takes over only
    /// where it hears what was asked for; otherwise silence, said once.
    private static func tapLost(_ suite: TestSuite) {
        var app = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        suite.expect(app.tapReaderLost() && !app.writesTap && !app.needsWitness && !app.tapReaderLost(),
                     "the app's tap without a reader leaves the track once, and nothing is judged any more")
        suite.expect(app.streamWrites(filmsWindow: true) && !app.streamWrites(filmsWindow: false),
                     "a window's stream, the app alone, takes the track; a display's whole Mac never does")
        suite.expect(ForkMeetingTrackSound.of(setting: .app, sound: .appTap(pid: 200), arbiter: app, filmsWindow: false) == .lost
                        && ForkMeetingTrackSound.of(setting: .app, sound: .appTap(pid: 200), arbiter: app,
                                                    filmsWindow: true) == .heard,
                     "on a display the meeting's sound is lost, said; on a window it goes on from the stream")

        var mac = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true, tapFirst: false)
        _ = mac.tapBuffer(heard: true)
        suite.expect(mac.writesTap && mac.tapReaderLost() && mac.streamWrites(filmsWindow: false)
                        && ForkMeetingTrackSound.of(setting: .all, sound: .macTap, arbiter: mac, filmsWindow: false) == .heard,
                     "the whole Mac's tap without a reader: the stream, the whole Mac too, takes the track")
        var unproved = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true, tapFirst: false)
        suite.expect(!unproved.tapReaderLost() && unproved.streamWrites(filmsWindow: false) && !unproved.needsWitness,
                     "the Mac's tap lost before it was proved: the stream kept writing all along")
        var denied = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        _ = denied.streamBuffer(heard: true, counts: true, seconds: 3)
        suite.expect(!denied.tapReaderLost() && denied.streamWrites(filmsWindow: false),
                     "a tap already let go for a missing permission changes nothing (the stream, as said then)")

        var machine = recording(target: .display)
        let effects = machine.handle(.soundLost(token1), now: at(42))
        suite.expect(patches(effects).first?.gap == ForkMeetingSidecar.Gap(at: 42, seconds: 0, kind: .soundLost)
                        && effects.contains(.notice(.soundLost)) && effects.contains(.announce(.soundLost)),
                     "the loss is said in the island and to VoiceOver, and noted in meeting.json where it began")
        suite.expect(machine.handle(.soundLost(ForkMeetingToken(value: 7)), now: at(43)).isEmpty,
                     "a late word from another session says nothing")
        suite.expect(ForkMeetingSidecar.GapKind.soundLost.rawValue == "soundLost",
                     "meeting.json names the gap soundLost")
        let strings = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(strings.allSatisfy { ForkMeetingNotice.soundLost.title($0).count <= 28
                                            && ForkMeetingAnnouncement.soundLost.text($0) != ForkMeetingAnnouncement.sourceGone.text($0) },
                     "the notice fits in 28 characters and VoiceOver has its own sentence, in every language")
    }

    /// ⧉ or a display change while a display is filmed: the stream is left
    /// alone only when it would film the very same display or window.
    private static func switching(_ suite: TestSuite) {
        suite.expect(!ForkMeetingFilmed.switchChangesNothing(current: .display(1), next: .display(2)),
                     "the window moved to another display: the display filmed changes, though the aim did not")
        suite.expect(ForkMeetingFilmed.switchChangesNothing(current: .display(1), next: .display(1))
                        && ForkMeetingFilmed.switchChangesNothing(current: .window(7), next: .window(7)),
                     "the same display, or the same window wherever it is: nothing to change")
        suite.expect(!ForkMeetingFilmed.switchChangesNothing(current: nil, next: .display(1))
                        && !ForkMeetingFilmed.switchChangesNothing(current: .window(7), next: .display(1)),
                     "a stream that films nothing known yet, or the window, is switched")
    }

    /// The system audio verdict: kept while its session starts, said once
    /// it records; only a tap that heard sound clears the page's warning.
    private static func verdicts(_ suite: TestSuite) {
        let other = ForkMeetingToken(value: 9)
        let starting = starting()
        suite.expect(ForkMeetingPendingVerdicts.route(token1, phase: starting.phase) == .hold
                        && ForkMeetingPendingVerdicts.route(other, phase: starting.phase) == .drop,
                     "a verdict of the session starting is held for it; another session's is dropped")
        let recording = recording()
        suite.expect(ForkMeetingPendingVerdicts.route(token1, phase: recording.phase) == .now
                        && ForkMeetingPendingVerdicts.route(other, phase: recording.phase) == .drop,
                     "once it records, its verdict is said at once")
        var stopping = recording
        stopping.handle(.stop, now: at(5))
        suite.expect(ForkMeetingPendingVerdicts.route(token1, phase: stopping.phase) == .drop
                        && ForkMeetingPendingVerdicts.route(token1, phase: Machine().phase) == .drop,
                     "a verdict after the stop has no meeting left to warn about")

        var held = ForkMeetingPendingVerdicts()
        held.hold(.missing, for: token1)
        held.hold(.allowed, for: token1)
        suite.expect(held.take(token1) == .missing && held.take(token1) == nil,
                     "the first verdict is the recording's, replayed once at the start")
        var replayed = starting
        replayed.handle(.captureStarted(token1, folder: folder), now: at(1))
        let effects = replayed.handle(.permissionLost(.systemAudio), now: at(1))
        suite.expect(effects.contains(.notice(.failure(.systemAudioUnavailable))),
                     "replayed after captureStarted, the missing permission is said like any other")

        typealias Support = ForkMeetingServiceSupport
        suite.expect(Support.systemAudioPermission(verified: true, failing: false) == .allowed
                        && Support.systemAudioPermission(verified: false, failing: false) == .missing
                        && Support.systemAudioPermission(verified: nil, failing: false) == .unknown
                        && Support.systemAudioPermission(verified: true, failing: true) == .missing
                        && Support.systemAudioPermission(verified: nil, failing: true) == .missing,
                     "the page shows what the last recording found: allowed in green, missing in orange, else unknown")
    }

    /// A final pass that failed on a master that plays: shown in the Finder
    /// under the meeting's name (the same file), and tried once more at the
    /// next launch all the same.
    private static func failedPassShown(_ suite: TestSuite) {
        typealias Plan = ForkMeetingRecoveryPlan
        func facts(_ state: ForkMeetingSidecar.State, linked: Bool) -> Plan.Facts {
            var meeting = ForkMeetingSidecar()
            meeting.schema = 1
            meeting.state = state
            meeting.finalPass = .failed
            meeting.stopReason = .user
            meeting.recordedSeconds = 600
            return Plan.Facts(sidecar: .success(meeting), master: Plan.Media(duration: 600),
                              final: Plan.Media(duration: 600), finalIsMaster: linked)
        }
        let shown = facts(.finalizing, linked: true)
        suite.expect(Plan.plan(shown) == .finalize(stopReason: .user, recovered: false, discardDrafts: false)
                        && Plan.patch(for: Plan.plan(shown), facts: shown)?.state == .interrupted,
                     "the next launch makes the pass's last try on the master shown, marked interrupted beforehand")
        suite.expect(Plan.plan(facts(.interrupted, linked: true)) == .leave,
                     "its last try failed too: the master stays, shown, never tried again")
        suite.expect(Plan.plan(facts(.finalizing, linked: false)) == .complete(removeMaster: true, discardDrafts: false),
                     "a real final file as long as the master is whole: the master goes, as before")

        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(ForkMeetingFailure.all.contains(.masterMissing) && !ForkMeetingFailure.masterMissing.isLasting
                        && ForkMeetingFailure.masterMissing.action == .openMeetingsFolder
                        && !ForkMeetingFailure.masterMissing.remedy(english).contains("readable"),
                     "no master at all has its own words, which never say the video is readable")
        let strings = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(strings.allSatisfy { $0.failMasterMissing.count <= 28 && $0.failMasterMissing != $0.failFinalPass
                                            && $0.failMasterMissingRemedy != $0.failFinalPassRemedy },
                     "in every language, in 28 characters for the island")
    }

    /// A start cancelled while its facts are gathered: their late answer
    /// starts nothing, and the next start does not wait for it.
    private static func startAttempts(_ suite: TestSuite) {
        var attempts = ForkMeetingStartAttempt()
        let first = attempts.begin()
        suite.expect(attempts.answers(first), "the facts of the start under way are its own")
        attempts.cancel()
        suite.expect(!attempts.answers(first), "cancelled: its answer, arriving late, starts nothing")
        let second = attempts.begin()
        suite.expect(!attempts.answers(first) && attempts.answers(second),
                     "a new start right after: only its own answer counts, the old one is dropped when it comes")
        suite.expect(ForkMeetingServiceSupport.canStart(wanted: true, machineBusy: false, preparingStart: false,
                                                        terminating: false),
                     "the cancel leaves nothing being prepared: a start may be asked at once")
    }

    /// The folder of a meeting about to record is this process's before it
    /// exists, and the recovery never takes a lock this process holds.
    private static func recoveryLeavesLiveMeetings(_ suite: TestSuite) {
        let store = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingStore.swift")
        let make = store.components(separatedBy: "private func makeFolder(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let reserved = make.range(of: "reserve(folder)\n            do {")
        let created = make.range(of: "try manager.createDirectory(at: folder")
        suite.expect(reserved != nil && created != nil && reserved!.upperBound < created!.lowerBound,
                     "the new folder is reserved as this process's (made[id]) before it is made")
        let scan = store.components(separatedBy: "private func recover(root: URL").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(scan.contains("!isMadeHere(folder), !isClaimedHere(folder)")
                        && scan.contains("guard claimForRecovery(folder) else { continue }"),
                     "the recovery skips a folder this process made or holds, and never shares its lock")
        let claim = store.components(separatedBy: "private func claim(_ folder: URL, sharedHere: Bool)").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(claim.contains("if claims[path] != nil { return sharedHere }"),
                     "a lock this process holds is refused to the recovery, under the same lock as the check")
    }

    /// A title cannot make a folder's name lie about what it holds.
    private static func bidiNames(_ suite: TestSuite) {
        let spoof = ForkMeetingFolder.sanitized("Budget \u{202E}xslx.4pm")
        suite.expect(spoof == "Budget xslx.4pm",
                     "a right-to-left override goes: the name reads as typed, not as \"Budget mp4.xlsx\" (\(spoof ?? "nil"))")
        let all = (0x202A...0x202E).map { "a\(Character(Unicode.Scalar($0)!))b" }
            + (0x2066...0x2069).map { "a\(Character(Unicode.Scalar($0)!))b" }
        suite.expect(all.allSatisfy { ForkMeetingFolder.sanitized($0) == "a b" },
                     "every embedding, override and isolate becomes a space, like the other forbidden characters")
        let marks = ["\u{200E}", "\u{200F}", "\u{061C}"].map { "שלום\($0) 2026" }
        suite.expect(marks.allSatisfy { ForkMeetingFolder.sanitized($0) == $0 },
                     "the direction marks a Hebrew or Arabic title needs stay")
        suite.expect(ForkMeetingFolder.sanitized("👨‍👩‍👧 Famille") == "👨‍👩‍👧 Famille",
                     "the zero-width joiner of an emoji family still stays")
    }
}
