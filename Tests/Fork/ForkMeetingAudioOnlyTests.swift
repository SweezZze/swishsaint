// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// "Sound only" (Finish C): a meeting recorded without picture, kept as an
/// `.m4a`, needs no Screen Recording, and goes through the same sidecar,
/// recovery, library, transcription and export rules as a video.
enum ForkMeetingAudioOnlyTests {
    static func run(_ suite: TestSuite) {
        sidecar(suite)
        folder(suite)
        library(suite)
        recovery(suite)
        machine(suite)
        sound(suite)
        sizes(suite)
        offer(suite)
        strings(suite)
    }

    typealias Machine = ForkMeetingMachine

    private static let english = ForkMeetingStrings.strings(.enUS)
    private static let languages = AppLanguage.allCases
    private static let id = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8") ?? UUID()
    private static let start = Date(timeIntervalSince1970: 1_792_310_531) // 2026-10-18T08:02:11Z
    private static let name = "2026-10-18 10h02 — Weekly sync"

    private static func decoded(_ json: String) -> ForkMeetingSidecar? {
        guard case let .success(sidecar) = ForkMeetingSidecar.decode(Data(json.utf8)) else { return nil }
        return sidecar
    }

    private static func text(_ sidecar: ForkMeetingSidecar) -> String {
        (try? sidecar.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func meeting(_ target: ForkMeetingCaptureTarget? = .audioOnly,
                                state: ForkMeetingSidecar.State = .complete) -> ForkMeetingSidecar {
        var sidecar = ForkMeetingSidecar.started(id: id, startedAt: start, origin: .manual, title: "Weekly sync",
                                                 titleSource: .user,
                                                 capture: .init(target: target, systemAudio: .app, microphone: "AirPods",
                                                                quality: .standard))
        sidecar.state = state
        sidecar.endedAt = start.addingTimeInterval(3120)
        sidecar.recordedSeconds = 3120
        return sidecar
    }

    private static func contents(_ names: [String]) -> ForkMeetingFolder.Contents {
        ForkMeetingFolder.contents(of: names + [ForkMeetingFolder.sidecarName], folderName: name)
    }

    // MARK: - meeting.json

    private static func sidecar(_ suite: TestSuite) {
        let first = meeting(state: .recording)
        let json = text(first)
        suite.expect(json.contains("\"target\" : \"audioOnly\"") && decoded(json) == first && first.isAudioOnly,
                     "a meeting without picture says so in meeting.json, and reads back as written")
        suite.expect(ForkMeetingCaptureTarget(stored: "audioOnly") == .audioOnly
                        && ForkMeetingCaptureTarget(stored: "nothing") == .window
                        && ForkMeetingCaptureTarget(stored: nil) == .window
                        && ForkMeetingCaptureTarget.fallback == .window,
                     "the setting reads sound only, and anything unknown still films the window")

        // Files written before sound only existed.
        let old = """
        {"schema": 1, "id": "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", "state": "complete", "origin": "manual",
         "startedAt": "2026-10-18T08:02:11Z", "recordedSeconds": 60,
         "capture": {"target": "display", "systemAudio": "app", "microphone": "off", "quality": "light"}}
        """
        let bare = """
        {"schema": 1, "id": "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", "state": "complete", "origin": "manual",
         "startedAt": "2026-10-18T08:02:11Z"}
        """
        let oldMeeting = decoded(old), bareMeeting = decoded(bare)
        suite.expect(oldMeeting?.capture?.target == .display && oldMeeting?.isAudioOnly == false
                        && oldMeeting?.preserved.isEmpty == true
                        && bareMeeting != nil && bareMeeting?.capture == nil && bareMeeting?.isAudioOnly == false,
                     "an older meeting.json, with a picture or no capture at all, still reads, never as sound only")
        suite.expect(oldMeeting.map { decoded(text($0)) == $0 } == true,
                     "an older meeting.json is written back the same")

        // What a later version might write: kept whole, never cut down.
        let later = """
        {"schema": 1, "id": "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", "state": "complete",
         "capture": {"target": "hologram", "systemAudio": "app", "fps": 60}}
        """
        let kept = decoded(later)
        let patched = kept.map { ForkMeetingSidecarPatch(microphone: "AirPods").applied(to: $0) }
        suite.expect(kept?.capture == nil && kept?.preserved["capture"] != nil && kept?.isAudioOnly == false
                        && patched?.capture == nil && patched.map(text)?.contains("hologram") == true,
                     "a capture this version cannot read is kept as written, and a patch never replaces it")
        var switched = meeting(.audioOnly, state: .recording)
        switched = ForkMeetingSidecarPatch(microphone: "Built-in").applied(to: switched)
        suite.expect(switched.capture?.target == .audioOnly && switched.capture?.microphone == "Built-in",
                     "a microphone switch noted keeps the meeting without picture")
    }

    // MARK: - The folder

    private static func folder(_ suite: TestSuite) {
        let soundOnly = contents(["\(name).m4a", ForkMeetingFolder.masterName])
        suite.expect(soundOnly.media(audioOnly: true) == "\(name).m4a" && soundOnly.media(audioOnly: false) == nil,
                     "without picture the .m4a is the meeting's own file; a video's M4A never stands for its video")
        let video = contents(["\(name).mp4", "\(name).m4a"])
        suite.expect(video.media(audioOnly: false) == "\(name).mp4",
                     "a video meeting's own file is still its video")
        suite.expect(ForkMeetingFolder.finalExtension(audioOnly: true) == "m4a"
                        && ForkMeetingFolder.finalExtension(audioOnly: false) == "mp4",
                     "the final file is an .m4a without picture, an .mp4 otherwise")
        let renames = ForkMeetingFolder.mediaRenames(from: name, to: "2026-10-18 10h02 — Board",
                                                     names: ["\(name).m4a", "\(name).txt"],
                                                     transcriptFiles: ["\(name).txt"])
        suite.expect(renames.moves == [ForkMeetingFolder.Move(from: "\(name).m4a", to: "2026-10-18 10h02 — Board.m4a"),
                                       ForkMeetingFolder.Move(from: "\(name).txt", to: "2026-10-18 10h02 — Board.txt")],
                     "renaming a meeting without picture moves its .m4a and its transcript with the folder")
    }

    // MARK: - The library

    private static func entry(_ sidecar: ForkMeetingSidecar, _ names: [String]) -> ForkMeetingLibraryEntry? {
        ForkMeetingLibraryEntry(folderName: name, sidecar: .success(sidecar), contents: contents(names),
                                bytes: 100_000_000)
    }

    private static func library(_ suite: TestSuite) {
        let complete = entry(meeting(), ["\(name).m4a"])
        suite.expect(complete?.status == .complete && complete?.playable == "\(name).m4a" && complete?.audio == nil
                        && complete?.video == nil && complete?.isAudioOnly == true,
                     "a meeting without picture plays its .m4a, which is no separate M4A")
        var recovered = meeting()
        recovered.recovered = true
        suite.expect(entry(recovered, ["\(name).m4a"])?.playable == "\(name).m4a"
                        && entry(recovered, ["\(name).m4a"])?.status == .recovered,
                     "recovered after a crash, it plays its .m4a too, flagged")
        let interrupted = entry(meeting(state: .interrupted), [ForkMeetingFolder.masterName])
        suite.expect(interrupted?.playable == ForkMeetingFolder.masterName,
                     "interrupted with only its master, the master plays up to its last fragment")
        var noState = meeting()
        noState.state = nil
        suite.expect(entry(noState, ["\(name).m4a"])?.status == .complete
                        && entry(noState, [])?.status == .interrupted(.unknown),
                     "a state this version does not know reads complete with its .m4a, interrupted without")
        let videoGone = entry(meeting(.window), ["\(name).m4a"])
        suite.expect(videoGone?.playable == nil && videoGone?.audio == "\(name).m4a" && videoGone?.isAudioOnly == false,
                     "a video meeting whose video went keeps its M4A as an M4A, nothing changed")

        let caption = complete.map { ForkMeetingLibraryText.caption($0, strings: english, language: .enUS) } ?? ""
        let spoken = complete.map { ForkMeetingLibraryText.accessibilityLabel($0, strings: english, language: .enUS) } ?? ""
        suite.expect(caption.contains("Sound only") && spoken.contains("Sound only"),
                     "its row and VoiceOver say it has sound only")

        let mixed = ForkMeetingProbeCache.Probe(seconds: 3120, audioTracks: 3, hasMix: true)
        let promoted = ForkMeetingProbeCache.Probe(seconds: 3120, audioTracks: 2, hasMix: false)
        let skipped = entry(meeting(), ["\(name).m4a"])
        suite.expect(complete.map { ForkMeetingAudioExport.route($0, probe: mixed) } == .success(.extractMix("\(name).m4a"))
                        && skipped.map { ForkMeetingAudioExport.route($0, probe: promoted) } == .success(.mixDown("\(name).m4a")),
                     "its audio exports as the mix alone, or mixed down from a master kept for room")
        let videoMeeting = entry(meeting(.window), ["\(name).mp4", "\(name).m4a"])
        suite.expect(videoMeeting.map { ForkMeetingAudioExport.route($0, probe: mixed) } == .success(.copy("\(name).m4a")),
                     "a video's M4A is still copied as it is")
        suite.expect(complete.map { ForkMeetingEditorCopy.plan($0, audioTracks: 3, editorAvailable: true) }
                        == .failure(.noVideo),
                     "the editor is not offered a meeting without picture")

        let source = ForkMeetingTranscript.source(video: contents(["\(name).m4a"]).media(audioOnly: true), hasMaster: false)
        let files = source.map { ForkMeetingTranscript.fileNames(source: $0, folderName: name) }
        suite.expect(source == "\(name).m4a" && files?.text == "\(name).txt" && files?.subtitles == "\(name).srt",
                     "it is transcribed from its .m4a, the transcript named after it")
        suite.expect(ForkMeetingTranscript.tracks(enabled: [true, false, false]) == .init(meeting: 1, microphone: 2),
                     "its tracks are read as a video's: the mix, then the meeting, then the microphone")
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        suite.expect(complete.map { ForkMeetingRetention.verdict($0, days: 30, now: start.addingTimeInterval(40 * 86_400),
                                                                 calendar: paris) } == .trash,
                     "the automatic bin takes it like any other meeting")
    }

    // MARK: - Recovery

    private static func recovery(_ suite: TestSuite) {
        typealias Plan = ForkMeetingRecoveryPlan
        let crashed = meeting(state: .recording)
        suite.expect(Plan.plan(.init(sidecar: .success(crashed), master: .init(duration: 597)))
                        == .finalize(stopReason: .crash, recovered: true, discardDrafts: false),
                     "killed while recording, its master is finalized again into an .m4a")
        suite.expect(Plan.plan(.init(sidecar: .success(meeting(state: .finalizing)), master: .init(duration: 600),
                                     final: .init(duration: 600), hasDrafts: true))
                        == .complete(removeMaster: true, discardDrafts: true),
                     "its .m4a whole, the master and the draft go")
        suite.expect(Plan.needsInspection(.success(meeting()), contents: contents(["\(name).m4a", ".finalizing.m4a"])),
                     "an .m4a draft left behind is looked at")
    }

    // MARK: - The machine

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folderURL = URL(fileURLWithPath: "/tmp/Meetings/\(name)", isDirectory: true)
    private static let token = ForkMeetingToken(value: 1)

    private static func settings(_ target: ForkMeetingCaptureTarget) -> ForkMeetingCaptureSettings {
        ForkMeetingCaptureSettings(target: target, systemAudio: .app, microphone: "meeting", quality: .standard)
    }

    private static func facts(screen: Bool = true, busy: Bool = false,
                              free: Int64? = 50_000_000_000) -> ForkMeetingStartFacts {
        ForkMeetingStartFacts(freeBytes: free, screenRecordingAllowed: screen, microphoneAllowed: true,
                              officialRecorderBusy: busy)
    }

    private static func recording(_ target: ForkMeetingCaptureTarget, locked: Bool = false) -> Machine {
        var machine = Machine()
        if locked { machine.handle(.locked, now: t0) }
        machine.handle(.manualStart(.init(settings: settings(target), facts: facts(screen: target != .audioOnly))), now: t0)
        machine.handle(.captureStarted(token, folder: folderURL, target: target), now: t0)
        return machine
    }

    private static func gaps(_ effects: [Machine.Effect]) -> [ForkMeetingSidecar.Gap] {
        effects.compactMap {
            if case let .writeSidecar(_, patch) = $0 { return patch.gap }
            return nil
        }
    }

    private static func isRecording(_ machine: Machine) -> Bool {
        if case .recording = machine.phase { return true }
        return false
    }

    private static func machine(_ suite: TestSuite) {
        func request(_ target: ForkMeetingCaptureTarget, _ facts: ForkMeetingStartFacts) -> ForkMeetingStartRequest {
            ForkMeetingStartRequest(settings: settings(target), facts: facts)
        }
        suite.expect(Machine.refusal(request(.audioOnly, facts(screen: false))) == nil
                        && Machine.refusal(request(.window, facts(screen: false))) == .screenRecordingDenied
                        && Machine.refusal(request(.display, facts(screen: false))) == .screenRecordingDenied,
                     "a meeting without picture starts without Screen Recording; one that films still needs it")
        suite.expect(Machine.refusal(request(.audioOnly, facts(busy: true))) == .officialRecorderBusy
                        && Machine.refusal(request(.audioOnly, facts(free: nil))) == .folderUnavailable
                        && Machine.refusal(request(.audioOnly, facts(free: 1_000_000_000)))
                        == .diskFullAtStart(requiredBytes: ForkMeetingDisk.minimumFreeBytesToStart),
                     "the other refusals stay: the official recorder, an unreadable or full disk")

        var machine = Machine()
        let effects = machine.handle(.manualStart(request(.audioOnly, facts(screen: false))), now: t0)
        suite.expect(effects.count == 1 && { if case .startCapture = effects[0] { return true }; return false }(),
                     "without Screen Recording, a start without picture asks for its capture")
        let started = machine.handle(.captureStarted(token, folder: folderURL, target: .audioOnly), now: t0)
        suite.expect(isRecording(machine) && machine.activeSession?.target == .audioOnly
                        && !started.contains { if case .writeSidecar = $0 { return true }; return false },
                     "it records, and meeting.json already said sound only")

        var soundOnly = recording(.audioOnly)
        suite.expect(soundOnly.handle(.permissionLost(.screenRecording), now: t0.addingTimeInterval(5)).isEmpty
                        && isRecording(soundOnly),
                     "Screen Recording taken back stops nothing that films nothing")
        var filming = recording(.window)
        suite.expect(!filming.handle(.permissionLost(.screenRecording), now: t0.addingTimeInterval(5)).isEmpty
                        && !isRecording(filming),
                     "a meeting that films still stops when it is taken back")

        var locks = recording(.audioOnly)
        locks.handle(.locked, now: t0.addingTimeInterval(10))
        let unlocked = locks.handle(.unlocked, now: t0.addingTimeInterval(70))
        var lockedAtStart = recording(.audioOnly, locked: true)
        let unlockedLater = lockedAtStart.handle(.unlocked, now: t0.addingTimeInterval(30))
        var lockedVideo = recording(.window)
        lockedVideo.handle(.locked, now: t0.addingTimeInterval(10))
        suite.expect(gaps(unlocked).isEmpty && gaps(unlockedLater).isEmpty
                        && gaps(lockedVideo.handle(.unlocked, now: t0.addingTimeInterval(70))).map(\.kind) == [.screenLocked],
                     "a locked screen freezes no picture without one: no gap is noted")
        var toggled = recording(.audioOnly)
        suite.expect(toggled.handle(.toggleTarget, now: t0.addingTimeInterval(3)).isEmpty
                        && toggled.handle(.displayChanged, now: t0.addingTimeInterval(4)).isEmpty,
                     "⧉ and a display change have nothing to switch")

        var low = recording(.audioOnly)
        let lowEffects = low.handle(.diskLow(freeBytes: 1_500_000_000), now: t0.addingTimeInterval(60))
        let minutes = Int((1_500_000_000 - ForkMeetingDisk.minimumFreeBytesToContinue) / ForkMeetingAudioOnly.bytesPerSecond / 60)
        suite.expect(lowEffects.contains(.notice(.diskLow(minutesLeft: minutes))) && minutes == 595,
                     "a low disk counts the minutes left at the sound's rate: 595 for 1.5 GB, not a video's 93")
        var lowVideo = recording(.window)
        suite.expect(lowVideo.handle(.diskLow(freeBytes: 1_500_000_000), now: t0.addingTimeInterval(60))
                        .contains(.notice(.diskLow(minutesLeft: ForkMeetingDisk.minutesLeft(freeBytes: 1_500_000_000,
                                                                                            quality: .standard)))),
                     "a video's minutes are counted as before")
        suite.expect(ForkMeetingServiceSupport.filmed(target: .audioOnly, appName: "Chrome", noWindowToFilm: false,
                                                      strings: english) == "Sound only",
                     "the start and the pill say sound only")
    }

    // MARK: - Sound

    private static func sound(_ suite: TestSuite) {
        suite.expect(ForkMeetingAudioOnly.sound(.stream) == .none && ForkMeetingAudioOnly.sound(.macTap) == .macTap
                        && ForkMeetingAudioOnly.sound(.appTap(pid: 42)) == .appTap(pid: 42)
                        && ForkMeetingAudioOnly.sound(.none) == .none,
                     "without picture only a tap hears the meeting; what needs the stream hears nothing")
        let before144 = ForkMeetingSoundSource.choose(.all, appPID: 42, ownPID: 1, filmsWindow: false, tapAvailable: false)
        suite.expect(ForkMeetingAudioOnly.sound(before144) == .none
                        && ForkMeetingAudioOnly.sound(ForkMeetingSoundSource.appTap(pid: 42).refused(filmsWindow: false)) == .none
                        && ForkMeetingAudioOnly.sound(ForkMeetingSoundSource.macTap.refused(filmsWindow: false)) == .none,
                     "before macOS 14.4, or a tap refused, the meeting track stays silent rather than start a stream")

        var tapped = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true, tapFirst: true)
        func said(_ setting: ForkMeetingSystemAudio, _ source: ForkMeetingSoundSource,
                  _ arbiter: ForkMeetingSoundArbiter) -> ForkMeetingTrackSound {
            ForkMeetingTrackSound.of(setting: setting, sound: source, arbiter: arbiter, filmsWindow: false, hasStream: false)
        }
        suite.expect(said(.app, .appTap(pid: 42), tapped) == .heard && said(.all, .macTap, tapped) == .heard,
                     "a tap that writes is heard")
        _ = tapped.tapReaderLost()
        let none = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false)
        suite.expect(said(.app, .appTap(pid: 42), tapped) == .lost && said(.all, .none, none) == .noApp
                        && said(.app, .none, none) == .noApp && said(.off, .none, none) == .heard,
                     "without a stream, a tap gone is lost sound, none at all is said, sound off is as asked")
        suite.expect(ForkMeetingTrackSound.of(setting: .all, sound: .stream, arbiter: none, filmsWindow: false) == .heard,
                     "with a stream, nothing changes")
    }

    // MARK: - Sizes

    private static func sizes(_ suite: TestSuite) {
        suite.expect(ForkMeetingAudioOnly.totalBitRate == 224_000 && ForkMeetingAudioOnly.estimatedBytesPerHour == 100_800_000,
                     "an hour without picture is about 100 MB: the mix and the two sources")
        let tenth = (ForkMeetingAudioOnly.estimatedGigabytesPerHour * 10).rounded() / 10
        suite.expect(tenth == 0.1 && ForkMeetingAudioOnly.estimatedBytesPerHour * 3 < ForkMeetingQuality.light.estimatedBytesPerHour,
                     "the page says ~0.1 GB/h, under a third of the lightest video")
        suite.expect(settings(.audioOnly).bytesPerSecond == 28_000
                        && settings(.window).bytesPerSecond == ForkMeetingQuality.standard.bytesPerSecond,
                     "what a second weighs follows what is recorded")
    }

    // MARK: - The offer

    private static func candidate() -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: ForkMeetingIdentity("meet:abc-defg-hij"), provider: "meet",
                             providerName: "Google Meet", providerShortName: "Meet", titleName: "Point hebdo",
                             meetCode: "abc-defg-hij", calendarTitle: nil, appBundle: "com.google.Chrome",
                             pid: 100, windowID: 1, windowBundle: "com.google.Chrome", defaultSound: .app,
                             policy: .ask, silenced: true, bornAt: t0, alwaysProof: .meetCode)
    }

    private static func offer(_ suite: TestSuite) {
        let line = ForkMeetingOfferText.capture(target: .audioOnly, windowApp: "Chrome", hasWindow: true, sound: .app,
                                                soundApp: "Chrome", microphone: .named("AirPods"), strings: english)
        suite.expect(line == "No picture · sound:\u{00A0}Chrome · mic:\u{00A0}AirPods",
                     "the offer says the meeting would be recorded without picture, with its sound and microphone")
        suite.expect(ForkMeetingCaptureTarget.window.alternative == .audioOnly
                        && ForkMeetingCaptureTarget.display.alternative == .audioOnly
                        && ForkMeetingCaptureTarget.audioOnly.alternative == .window
                        && !ForkMeetingCaptureTarget.audioOnly.filmsPicture
                        && ForkMeetingCaptureTarget.window.filmsPicture && ForkMeetingCaptureTarget.display.filmsPicture,
                     "the offer's menu records one meeting otherwise: sound only, or with its picture")
        func offer(_ blocked: ForkMeetingFailure?) -> ForkMeetingOffer {
            ForkMeetingOffer(candidate: candidate(), collapsesAt: t0.addingTimeInterval(20), blocked: blocked)
        }
        suite.expect(ForkMeetingOfferText.recordsOtherwise(offer(nil), as: .audioOnly)
                        && ForkMeetingOfferText.recordsOtherwise(offer(.screenRecordingDenied), as: .audioOnly)
                        && !ForkMeetingOfferText.recordsOtherwise(offer(.screenRecordingDenied), as: .window)
                        && !ForkMeetingOfferText.recordsOtherwise(offer(.officialRecorderBusy), as: .audioOnly),
                     "an offer greyed for want of Screen Recording can still record its sound alone, nothing else")
    }

    // MARK: - Words

    private static func strings(_ suite: TestSuite) {
        let all = languages.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { $0.soundOnly.count <= 28 && !$0.soundOnly.isEmpty },
                     "“Sound only” fits the pill and the island in every language")
        suite.expect(all.allSatisfy { strings in
                        let line = strings.offerCaptureSoundOnly(sound: "Chrome", microphone: "AirPods")
                        return line.contains("Chrome") && line.contains("AirPods") && !line.hasPrefix("Chrome")
                     },
                     "every language's offer line says there is no picture, then names the sound and the microphone")
        suite.expect(all.allSatisfy { $0.soundOnlyCaption.contains(".m4a") && $0.soundOnlyBefore144.contains("14.4") },
                     "every language says the file is an .m4a, and what changes before macOS 14.4")
        suite.expect(all.allSatisfy { $0.offerRecordSoundOnly != $0.offerRecordWithPicture
                        && $0.soundOnly != $0.filmedDisplay && $0.soundOnly != $0.pictureMeetingWindow },
                     "each choice has its own words")
    }
}
