// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The transcript's corrections after its review: the echo filter removes a
/// word only on a proven echo path, and never a word the person said over a
/// participant; the updater waits for a transcription; only this app's own
/// files are ever renamed, replaced or removed; drafts are written together
/// and cleaned; the tracks are told by the file; a silent meeting track is
/// said; no transcription during a final pass; the texts.
enum ForkMeetingFixesOTests {
    static func run(_ suite: TestSuite) {
        voiceOverEcho(suite)
        headphones(suite)
        echoOnSpike(suite)
        followingWords(suite)
        pathBySlice(suite)
        updatesWaitForTranscripts(suite)
        transcriberWiring(suite)
        search(suite)
        ownFiles(suite)
        notices(suite)
        drafts(suite)
        tracks(suite)
        silentMeeting(suite)
        finalPass(suite)
        texts(suite)
        names(suite)
    }

    private static func word(_ text: String, _ start: Double, _ end: Double) -> ForkParakeetWord {
        ForkParakeetWord(text: text, start: start, end: end, confidence: 0.9)
    }

    private static func fill(_ energy: inout [Float], _ from: Double, _ to: Double, _ value: Float, add: Bool = false) {
        for index in Int(from / 0.01)..<min(energy.count, Int(to / 0.01)) {
            energy[index] = add ? energy[index] + value : value
        }
    }

    // MARK: - Echo

    /// The review's proof: laptop speakers, the echo 19 dB under the meeting
    /// track, 120 ms late; 30 echoed words calibrate the path. The person
    /// answers "d'accord" over the participant, its voice 3 to 20 dB above
    /// the echo, and says "alors" while nobody speaks.
    private static func speakers(voiceOverEcho: Float)
        -> (report: ForkMeetingEcho.Report, real: [Int], echoed: [Int]) {
        let seconds = 400.0
        var meeting = [Float](repeating: 1e-7, count: Int(seconds / 0.01))
        var micro = meeting
        let participant: Float = 0.01, gain = powf(10, -1.9)
        var me: [ForkParakeetWord] = [], them: [ForkParakeetWord] = []
        var echoed: [Int] = [], real: [Int] = []
        for turn in 0..<30 {
            let start = Double(turn) * 12
            for index in 0..<5 {
                let at = start + Double(index) * 2
                them.append(word("mot\(turn)x\(index)", at, at + 0.5))
                if index == 0 {
                    echoed.append(me.count)
                    me.append(word("mot\(turn)x\(index)", at + 0.12, at + 0.62))
                }
            }
            fill(&meeting, start, start + 10, participant)
            fill(&micro, start + 0.12, start + 10.12, gain * participant)
        }
        for turn in stride(from: 0, to: 30, by: 3) {
            let at = Double(turn) * 12 + 5
            fill(&micro, at, at + 0.4, gain * participant * powf(10, voiceOverEcho / 10), add: true)
            real.append(me.count)
            me.append(word("d'accord", at, at + 0.4))
        }
        for turn in stride(from: 0, to: 30, by: 5) {
            let at = Double(turn) * 12 + 10.5
            fill(&micro, at, at + 0.4, gain * participant * 3, add: true)
            real.append(me.count)
            me.append(word("alors", at, at + 0.4))
        }
        let report = ForkMeetingEcho.filter(micro: me, meeting: them,
                                            microEnvelope: ForkMeetingEnvelope(meanSquares: micro),
                                            meetingEnvelope: ForkMeetingEnvelope(meanSquares: meeting))
        return (report, real, echoed)
    }

    private static func voiceOverEcho(_ suite: TestSuite) {
        var removed: [String] = []
        var echoKept: [String] = []
        for decibels: Float in [20, 12, 9, 8, 6, 3] {
            let (report, real, echoed) = speakers(voiceOverEcho: decibels)
            let gone = real.filter { report.echo.contains($0) }.count
            if gone > 0 { removed.append("+\(decibels) dB: \(gone)/\(real.count)") }
            let left = echoed.filter { !report.echo.contains($0) }.count
            if left > 0 { echoKept.append("+\(decibels) dB: \(left)/\(echoed.count)") }
        }
        suite.expect(removed.isEmpty,
                     "a word said over a participant 3, 6, 8 dB or more above the echo is never taken out: \(removed)")
        suite.expect(echoKept.isEmpty, "the echoed words still go, every one: \(echoKept)")
    }

    /// The review's proof: headphones, so no echo at all, but 24 times both
    /// sides say "oui", "merci", "ok" within 0.4 s, and the laptop's
    /// microphone 10 dB under the meeting track.
    private static func headphones(_ suite: TestSuite) {
        var meeting = [Float](repeating: 1e-7, count: 60_000), micro = meeting
        var me: [ForkParakeetWord] = [], them: [ForkParakeetWord] = []
        let words = ["oui", "merci", "ok", "voilà"]
        for index in 0..<24 {
            let at = Double(index) * 20
            them.append(word(words[index % 4], at, at + 0.3))
            fill(&meeting, at, at + 6, 0.01)
            me.append(word(words[index % 4], at + 0.2, at + 0.5))
            fill(&micro, at + 0.2, at + 0.5, 0.001, add: true)
            me.append(word("exactement", at + 2, at + 2.5))
            fill(&micro, at + 2, at + 2.5, 0.001, add: true)
        }
        let report = ForkMeetingEcho.filter(micro: me, meeting: them,
                                            microEnvelope: ForkMeetingEnvelope(meanSquares: micro),
                                            meetingEnvelope: ForkMeetingEnvelope(meanSquares: meeting))
        suite.expect(report.matches == 24 && report.echo.isEmpty && report.slices.allSatisfy { $0 == nil },
                     "with headphones, 24 coincidences calibrate nothing: the microphone hears its floor alone where the participant speaks, and no word goes (\(report.echo.count) of \(me.count))")
    }

    /// Spike S6's minute, both ways: the speakers' echo is still taken out,
    /// and with headphones nothing is.
    private static func echoOnSpike(_ suite: TestSuite) {
        typealias Data = ForkMeetingTranscriptSpikeData
        func energy(_ encoded: String) -> ForkMeetingEnvelope {
            ForkMeetingEnvelope(meanSquares: encoded.unicodeScalars.map { powf(10, Float(Int($0.value) - 0x100 - 120) / 10) })
        }
        let meeting = Data.meeting.map { word($0.0, $0.1, $0.2) }
        let heard = Data.microphoneWithEcho
        let report = ForkMeetingEcho.filter(micro: heard.map { word($0.0, $0.1, $0.2) }, meeting: meeting,
                                            microEnvelope: energy(Data.microphoneWithEchoEnergy),
                                            meetingEnvelope: energy(Data.meetingEnergy))
        let ghosts = heard.indices.filter { !heard[$0].3 }
        let removed = ghosts.filter { report.echo.contains($0) }.count
        suite.expect(report.slices.count == 1 && report.slices[0] != nil
                        && Double(removed) >= 0.9 * Double(ghosts.count)
                        && !heard.indices.contains { heard[$0].3 && report.echo.contains($0) },
                     "S6 with speakers: the path is proven, \(removed) of \(ghosts.count) echoed words go, none said")
        let clean = ForkMeetingEcho.filter(micro: Data.microphone.map { word($0.0, $0.1, $0.2) }, meeting: meeting,
                                           microEnvelope: energy(Data.microphoneEnergy),
                                           meetingEnvelope: energy(Data.meetingEnergy))
        suite.expect(clean.echo.isEmpty, "S6 with headphones: nothing goes")
    }

    /// A syllabic meeting: 30 ms to 240 ms syllables at varied levels.
    private static func syllables(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        var energy = [Float](repeating: 1e-9, count: count)
        var index = 0
        while index < count {
            let length = 8 + Int(next() * 17), level = powf(10, (-15 - next() * 20) / 10)
            for step in 0..<length where index + step < count {
                let shape = sinf(Float.pi * Float(step + 1) / Float(length + 1))
                energy[index + step] = max(1e-9, level * shape * shape)
            }
            index += length + 2 + Int(next() * 10)
        }
        return energy
    }

    /// An echoed word Parakeet heard differently ("Pifrance" for
    /// "Bpifrance") has no twin, but its energy follows the meeting's
    /// syllables through the path: it goes. The person's word said alone,
    /// while the meeting is silent, follows nothing: it stays.
    private static func followingWords(_ suite: TestSuite) {
        let gain = powf(10, -1.9), floor: Float = 1e-7
        var meeting = syllables(12_000, seed: 7)
        fill(&meeting, 100, 105, 1e-9)
        var micro = [Float](repeating: floor, count: meeting.count)
        for index in 12..<micro.count { micro[index] = gain * meeting[index - 12] + floor }
        fill(&micro, 101, 101.5, 0.001)
        var them: [ForkParakeetWord] = [], me: [ForkParakeetWord] = []
        for second in stride(from: 2, to: 98, by: 3) {
            them.append(word("mot\(second)", Double(second), Double(second) + 0.4))
            me.append(word("mot\(second)", Double(second) + 0.12, Double(second) + 0.52))
        }
        let twins = me.count
        me.append(word("Pifrance", 40.62, 41.1))
        me.append(word("tournesol", 70.62, 71.1))
        me.append(word("alors", 101, 101.5))
        let report = ForkMeetingEcho.filter(micro: me, meeting: them, microEnvelope: ForkMeetingEnvelope(meanSquares: micro),
                                            meetingEnvelope: ForkMeetingEnvelope(meanSquares: meeting))
        suite.expect(report.echo.contains(twins) && report.echo.contains(twins + 1) && !report.echo.contains(twins + 2)
                        && (0..<twins).allSatisfy { report.echo.contains($0) },
                     "an echoed word without a twin goes when its energy follows the meeting's, a word said alone stays")
        let path = ForkMeetingEcho.Path(gain: gain, floor: floor)
        suite.expect(ForkMeetingEcho.following(micro: ForkMeetingEnvelope(meanSquares: micro),
                                               meeting: ForkMeetingEnvelope(meanSquares: meeting), 40.62, 41.1,
                                               shift: 0.12, path: path) > 0.9
                        && ForkMeetingEcho.following(micro: ForkMeetingEnvelope(meanSquares: micro),
                                                     meeting: ForkMeetingEnvelope(meanSquares: meeting), 101, 101.5,
                                                     shift: 0.12, path: path) < 0.7,
                     "the echo follows the meeting's syllables, the person's word does not")
    }

    /// Speakers for five minutes, then headphones: the second slice proves
    /// no path, and its words stay even when they match.
    private static func pathBySlice(_ suite: TestSuite) {
        let count = 60_000
        var meeting = [Float](repeating: 1e-7, count: count), micro = meeting
        var them: [ForkParakeetWord] = [], me: [ForkParakeetWord] = []
        let gain = powf(10, -1.9)
        for turn in 0..<50 {
            let start = Double(turn) * 12
            them.append(word("mot\(turn)", start, start + 0.5))
            fill(&meeting, start, start + 10, 0.01)
            if start < 300 { fill(&micro, start + 0.12, start + 10.12, gain * 0.01) }
            me.append(word("mot\(turn)", start + 0.12, start + 0.62))
            if start >= 300 { fill(&micro, start + 0.12, start + 0.62, gain * 0.01) }
        }
        let report = ForkMeetingEcho.filter(micro: me, meeting: them, microEnvelope: ForkMeetingEnvelope(meanSquares: micro),
                                            meetingEnvelope: ForkMeetingEnvelope(meanSquares: meeting))
        let first = me.indices.filter { me[$0].start < 300 }, second = me.indices.filter { me[$0].start >= 300 }
        suite.expect(report.slices.count == 2 && report.slices[0] != nil && report.slices[1] == nil
                        && first.allSatisfy { report.echo.contains($0) } && !second.contains { report.echo.contains($0) },
                     "the path is proven five minutes at a time: speakers then headphones, only the first part's echo goes")
    }

    // MARK: - Updates

    private static func updatesWaitForTranscripts(_ suite: TestSuite) {
        let before = ForkMeetingActivity.tally
        guard !before.isBusy else { return suite.expect(false, "the activity starts idle") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        var idle = 0, changes = 0
        let one = NotificationCenter.default.addObserver(forName: ForkMeetingActivity.didBecomeIdle, object: nil,
                                                         queue: nil) { _ in idle += 1 }
        let two = NotificationCenter.default.addObserver(forName: ForkMeetingActivity.didChange, object: nil,
                                                         queue: nil) { _ in changes += 1 }
        defer {
            NotificationCenter.default.removeObserver(one)
            NotificationCenter.default.removeObserver(two)
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        ForkMeetingActivity.setRecording(true)
        ForkMeetingActivity.setTranscribing(true)
        ForkMeetingActivity.setRecording(false)
        settle()
        let whileWaiting = idle
        suite.expect(ForkMeetingActivity.isBusy && whileWaiting == 0,
                     "a pending update is not installed while a transcription runs or waits")
        ForkMeetingActivity.beginFinalizing()
        ForkMeetingActivity.endFinalizing()
        settle()
        let changesBefore = changes
        ForkMeetingActivity.setTranscribing(false)
        settle()
        suite.expect(idle == 1 && !ForkMeetingActivity.isBusy && changes == changesBefore + 1,
                     "the updater hears « idle » once the transcription ends, and the transcriber hears every change")
        ForkMeetingActivity.setTranscribing(false)
        settle()
        suite.expect(idle == 1 && ForkMeetingActivity.tally == before, "saying idle again posts nothing more")
    }

    private static func transcriberWiring(_ suite: TestSuite) {
        let transcriber = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingTranscriber.swift")
        suite.expect(transcriber.contains("ForkMeetingActivity.setTranscribing(running != nil || !waiting.isEmpty)")
                        && transcriber.contains("didSet { if (running == nil) != (oldValue == nil) { activityChanged() } }")
                        && transcriber.contains("didSet { if waiting.isEmpty != oldValue.isEmpty { activityChanged() } }"),
                     "the transcriber holds the updater while a job runs or waits")
        suite.expect(transcriber.contains("ProcessInfo.processInfo.beginActivity(options: [.userInitiated],")
                        && transcriber.contains("defer { ProcessInfo.processInfo.endActivity(activity) }"),
                     "a job holds the Mac awake, like a final pass")
        suite.expect(transcriber.contains("finalizing: finalizing)")
                        && transcriber.contains("activityObserver = NotificationCenter.default.publisher(for: ForkMeetingActivity.didChange)"),
                     "a job waits for the final passes, and starts when they end")
        let store = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingStore+Library.swift")
        suite.expect(store.contains("removeTranscriptDrafts(inside.filter(ForkMeetingTranscript.isDraft), in: folder)")
                        && store.contains("ForkMeetingTranscript.renamed(ours, by: mediaMoved)"),
                     "the listing cleans the drafts on the store's queue, and a rename keeps the transcript's names")
    }

    // MARK: - Search

    private static func search(_ suite: TestSuite) {
        let english = ForkMeetingStrings.strings(.enUS)
        let sidecar = ForkMeetingSidecar.started(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_792_400_000),
                                                 origin: .manual, title: "Weekly", titleSource: .user,
                                                 capture: ForkMeetingSidecar.Capture())
        let names = ["2026-10-18 10h02 — Weekly.mp4", "2026-10-18 10h02 — Weekly.txt", "meeting.json"]
        guard let entry = ForkMeetingLibraryEntry(
            folderName: "2026-10-18 10h02 — Weekly", sidecar: .success(sidecar),
            contents: ForkMeetingFolder.contents(of: names, folderName: "2026-10-18 10h02 — Weekly",
                                                 transcriptFiles: ["2026-10-18 10h02 — Weekly.txt"]))
        else { return suite.expect(false, "a meeting with its transcript is listed") }
        var index = ForkMeetingTranscriptIndex()
        let key = ForkMeetingTranscriptIndex.key(folder: entry.folderName, file: entry.transcript ?? "")
        let said = "[00:00:10] Others: L’Été DÉJÀ prévu, cafe\u{0301} à Zürich, ＡＢＣ."
        index.update(keeping: [key], read: [key: .init(stamp: .init(size: 1, modified: nil),
                                                         folded: ForkMeetingTranscriptIndex.folded(said))])
        let transcript = { (row: ForkMeetingLibraryEntry) in index.text(folder: row.folderName, file: row.transcript) }
        let found = ["l'ete", "déjà", "CAFÉ", "zurich", "abc", "L’été déjà"].filter {
            !ForkMeetingLibrary.matches(entry, query: $0, strings: english, transcript: transcript)
        }
        suite.expect(found.isEmpty,
                     "the transcript is searched without case, accents, widths, NFD or curly apostrophes: \(found)")
        suite.expect(!ForkMeetingLibrary.matches(entry, query: "zzyzx", strings: english, transcript: transcript)
                        && ForkMeetingLibrary.filtered([entry], query: "weekly cafe", strings: english,
                                                       transcript: transcript).count == 1,
                     "a word in no field leaves the row out, words in any field keep it")
        let model = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingLibraryModel.swift")
        suite.expect(model.contains("if let filterCache, filterCache.key == key { return filterCache.rows }"),
                     "the list's rows are filtered once per search, not at every read")
    }

    // MARK: - Own files

    /// The folder renamed in the Finder "Budget Q4", where the person keeps
    /// her own "Budget Q4.txt".
    private static func ownFiles(_ suite: TestSuite) {
        let ours = ["2026-10-18 10h02 — Point.txt", "2026-10-18 10h02 — Point.srt"]
        let names = ["2026-10-18 10h02 — Point.mp4"] + ours + ["Budget Q4.txt", "meeting.json"]
        let contents = ForkMeetingFolder.contents(of: names, folderName: "Budget Q4", transcriptFiles: ours)
        suite.expect(contents.transcript == ours[0] && contents.subtitles == ours[1],
                     "the transcript is this app's file, never the person's named after the folder")
        let hers = ForkMeetingFolder.contents(of: ["Budget Q4.txt", "Budget Q4.srt", "meeting.json"], folderName: "Budget Q4")
        suite.expect(hers.transcript == nil && hers.subtitles == nil,
                     "without its names in meeting.json, a text named after the folder is hers")
        let renames = ForkMeetingFolder.mediaRenames(from: "Budget Q4", to: "2026-10-18 10h02 — Budget", names: names,
                                                     transcriptFiles: ours)
        suite.expect(Set(renames.moves.map(\.from)) == Set(["2026-10-18 10h02 — Point.mp4"] + ours)
                        && !renames.moves.contains { $0.from == "Budget Q4.txt" },
                     "a rename takes this app's transcript and never the person's text")

        let master = ForkMeetingTranscript.placement(source: ForkMeetingFolder.masterName, folderName: "Budget Q4",
                                                     names: [ForkMeetingFolder.masterName, "Budget Q4.txt", "meeting.json"],
                                                     ours: [])
        suite.expect(master == ForkMeetingTranscript.Placement(text: "Budget Q4 2.txt", subtitles: "Budget Q4 2.srt", stale: []),
                     "a transcript never replaces the person's file of the same name: it takes the next free one")
        let again = ForkMeetingTranscript.placement(source: "Budget Q4.mp4", folderName: "Budget Q4",
                                                    names: ["Budget Q4.mp4", "budget q4.TXT", "Old.txt", "Old.srt", "x.txt"],
                                                    ours: ["Old.txt", "Old.srt", "Gone.txt"])
        suite.expect(again == ForkMeetingTranscript.Placement(text: "Budget Q4 2.txt", subtitles: "Budget Q4 2.srt",
                                                              stale: ["Old.txt", "Old.srt"]),
                     "names compare without case; only this app's former files are removed, and only those still there")
        let same = ForkMeetingTranscript.placement(source: "Budget Q4.mp4", folderName: "Budget Q4",
                                                   names: ["Budget Q4.mp4", "Budget Q4.txt", "Budget Q4.srt"],
                                                   ours: ["Budget Q4.txt", "Budget Q4.srt"])
        suite.expect(same == ForkMeetingTranscript.Placement(text: "Budget Q4.txt", subtitles: "Budget Q4.srt", stale: []),
                     "this app's own transcript is replaced in place")

        let record = ForkMeetingTranscriptRecord(state: .done, words: 3, files: ours)
        suite.expect(ForkMeetingTranscriptRecord(json: record.json)?.files == ours,
                     "meeting.json keeps the names written")
        let sneaky = ForkMeetingTranscriptRecord(json: .object([
            "state": .string("done"),
            "files": .array([.string("../notes.txt"), .string(".hidden"), .number(3), .string("a.txt")]),
        ]))
        suite.expect(sneaky?.files == ["a.txt"], "a name with a path, hidden, or not a name, is no file of this app's")
        var sidecar = ForkMeetingSidecar.started(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_792_400_000),
                                                 origin: .manual, title: "Point", titleSource: .user,
                                                 capture: ForkMeetingSidecar.Capture())
        sidecar.transcript = record.json
        let moved = ForkMeetingTranscript.renamed(ours, by: renames.moves)
        let edited = ForkMeetingSidecarEdit(transcriptFiles: moved).applied(to: sidecar)
        suite.expect(moved == ["2026-10-18 10h02 — Budget.txt", "2026-10-18 10h02 — Budget.srt"]
                        && edited.transcriptFiles == moved
                        && ForkMeetingTranscriptRecord(json: edited.transcript)?.words == 3
                        && !ForkMeetingSidecarEdit(transcriptFiles: moved).isEmpty,
                     "a rename writes the transcript's new names, its record otherwise kept")
    }

    // MARK: - Notices

    private static func notices(_ suite: TestSuite) {
        suite.expect(!ForkMeetingTranscript.notifies(.folderGone) && !ForkMeetingTranscript.notifies(.cancelled)
                        && ForkMeetingTranscript.notifies(.engine) && ForkMeetingTranscript.notifies(.modelMissing)
                        && ForkMeetingTranscript.notifies(nil),
                     "no failure notice for a meeting moved to the Trash meanwhile, nor one the person stopped")
        suite.expect(ForkMeetingTranscript.retries(.meetingInProgress, retried: 0)
                        && !ForkMeetingTranscript.retries(.meetingInProgress, retried: ForkMeetingTranscript.maximumRetries)
                        && !ForkMeetingTranscript.retries(.engine, retried: 0)
                        && ForkMeetingTranscript.retryDelay == 30,
                     "a meeting still being written is tried again 30 s later, a bounded number of times")
        let views = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingTranscriptViews.swift")
        let presenter = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingPresenter.swift")
        suite.expect(views.contains("case .cancelled, .modelMissing: return nil")
                        && presenter.contains("failure == .modelMissing ? [text.noticeParakeetMissing] : []"),
                     "missing Parakeet is said once in the detail, and is the failed notice's reason")
    }

    private static func drafts(_ suite: TestSuite) {
        let draft = ForkMeetingTranscript.draftName("2026-10-18 10h02 — Point.txt")
        suite.expect(ForkMeetingTranscript.isDraft(draft) && draft.hasPrefix(".swishsaint-transcript-")
                        && !ForkMeetingTranscript.isDraft(".notes.txt.draft") && !ForkMeetingTranscript.isDraft("notes.draft")
                        && !ForkMeetingTranscript.isDraft(".swishsaint-transcript-.draft"),
                     "a draft is this app's by its name: a hidden file of the person's never is")
        let contents = ForkMeetingFolder.contents(of: [draft, "meeting.json"], folderName: "x", transcriptFiles: [draft])
        suite.expect(contents.transcript == nil, "a draft is never shown as the transcript")
        let store = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingStore+Transcript.swift")
        let together = store.components(separatedBy: "static func writeTogether(").dropFirst().first ?? ""
        let firstDraft = together.range(of: "try Data(file.text.utf8).write(to: draft)")
        let firstMove = together.range(of: "try replace(folder.appendingPathComponent(file.name), with: draft)")
        suite.expect(firstDraft != nil && firstMove != nil && firstDraft!.upperBound < firstMove!.lowerBound
                        && store.contains("guard Self.writeTogether([(place.text, document.text), (place.subtitles, document.srt)], in: found)"),
                     "the .txt and the .srt are both drafted before either is put in place")
    }

    private static func tracks(_ suite: TestSuite) {
        suite.expect(ForkMeetingTranscript.tracks(enabled: [true, true, true])
                        == ForkMeetingTranscript.Tracks(meeting: 0, microphone: 1)
                        && ForkMeetingTranscript.tracks(enabled: [true, false, false, false])
                        == ForkMeetingTranscript.Tracks(meeting: 1, microphone: 2)
                        && ForkMeetingTranscript.tracks(enabled: [false, false])
                        == ForkMeetingTranscript.Tracks(meeting: 0, microphone: 1),
                     "the mix is the one track that plays: told by the file, whatever meeting.json says")
    }

    private static func silentMeeting(_ suite: TestSuite) {
        let labels: (ForkMeetingSpeaker) -> String = { $0 == .me ? "Me: " : "Others: " }
        let silent = ForkMeetingTranscriptFormat.document(
            me: [word("Hello", 1, 1.4)], participants: [], microEnvelope: ForkMeetingEnvelope(meanSquares: [1]),
            meetingEnvelope: ForkMeetingEnvelope(meanSquares: [0]), label: labels)
        let both = ForkMeetingTranscriptFormat.document(me: [word("Hello", 1, 1.4)], participants: [word("Hi", 3, 3.2)],
                                                        microEnvelope: nil, meetingEnvelope: nil, label: labels)
        let alone = ForkMeetingTranscriptFormat.document(me: [], participants: [word("Hi", 3, 3.2)],
                                                         microEnvelope: nil, meetingEnvelope: nil, label: labels)
        suite.expect(silent.meetingSilent && !both.meetingSilent && !alone.meetingSilent,
                     "a silent meeting track under a microphone that heard words is noticed")
        let record = ForkMeetingTranscriptRecord(state: .done, words: 1, meetingSilent: true)
        suite.expect(ForkMeetingTranscriptRecord(json: record.json)?.meetingSilent == true
                        && ForkMeetingTranscriptRecord(json: ForkMeetingTranscriptRecord(state: .done).json)?.meetingSilent == false,
                     "meeting.json keeps it, for the detail")
    }

    private static func finalPass(_ suite: TestSuite) {
        suite.expect(!ForkMeetingTranscript.mayStart(automatic: false, recording: false, finalizing: true)
                        && !ForkMeetingTranscript.mayStart(automatic: true, recording: false, finalizing: true)
                        && ForkMeetingTranscript.mayStart(automatic: false, recording: false, finalizing: false),
                     "no transcription starts while a final pass runs, asked by a click or not")
    }

    // MARK: - Texts

    private static func texts(_ suite: TestSuite) {
        var wrong: [String] = []
        for language in AppLanguage.allCases {
            let text = ForkMeetingStrings.strings(language)
            for short in [text.noticeParakeetMissing, text.transcriptWordsOne, text.noticeTranscriptFailed,
                          text.actionTranscribe, text.transcriptWaiting] where short.isEmpty || short.count > 28 {
                wrong.append("\(language.rawValue): \(short)")
            }
            if text.transcriptMeetingSilent.isEmpty || text.transcriptMeetingSilent.count > 48 {
                wrong.append("\(language.rawValue): \(text.transcriptMeetingSilent)")
            }
            if text.transcriptWords(1) != text.transcriptWordsOne || !text.transcriptWordsOne.contains("1")
                || text.transcriptWords(2).contains(text.transcriptWordsOne) {
                wrong.append("\(language.rawValue): one word")
            }
            if !text.transcribeCaption.contains(".txt") || !text.transcribeCaption.contains(".srt") {
                wrong.append("\(language.rawValue): caption")
            }
        }
        suite.expect(wrong.isEmpty, "the new texts exist in the 15 languages, short where they must be, 1 in the singular: \(wrong)")
        let french = ForkMeetingStrings.strings(.fr), english = ForkMeetingStrings.strings(.enUS)
        let korean = ForkMeetingStrings.strings(.ko)
        suite.expect(english.transcribeCaption.contains("sent nowhere unless an export is added")
                        && french.transcribeCaption.contains("envoyé nulle part sauf si un export est ajouté")
                        && ForkMeetingStrings.strings(.es).transcribeCaption.contains("sustituciones del dictado")
                        && !AppLanguage.allCases.contains { ForkMeetingStrings.strings($0).transcribeCaption.contains("Nothing leaves") },
                     "the caption says plain text on this Mac, sent nowhere unless an export is added")
        suite.expect(french.noticeTranscriptFailed == "Transcription impossible" && english.actionTranscribe == "Transcribe on This Mac"
                        && ForkMeetingStrings.strings(.de).transcriptWaiting == "In der Warteschlange"
                        && french.transcriptWords(1) == "1 mot" && english.transcriptWords(1) == "1 word"
                        && french.transcriptMeetingSilent.contains("\u{00A0}:") && !french.transcriptMeetingSilent.contains(" :"),
                     "the reviewed words, the singular, and French's no-break spaces")
        let koreanTexts = [korean.transcriptTitle, korean.transcribeAutomatically, korean.transcribeCaption,
                           korean.actionTranscribe, korean.actionOpenTranscript, korean.actionRetranscribe,
                           korean.transcriptProgress("1 %"), korean.transcriptNoAudio, korean.transcriptFailedGeneric,
                           korean.noticeTranscriptReady, korean.noticeTranscriptFailed]
        suite.expect(koreanTexts.allSatisfy { $0.replacingOccurrences(of: "받아쓰기 대치", with: "").contains("받아쓰기") == false
                                              && !$0.contains("십시오") }
                        && korean.transcriptTitle == "전사",
                     "Korean says 전사 for a transcription, keeps 받아쓰기 for the dictation, and 세요")
    }

    /// No real person or company in the transcript's code and data.
    private static func names(_ suite: TestSuite) {
        let files = ["Tests/Fork/ForkMeetingTranscriptSpikeData.swift", "Tests/Fork/ForkMeetingTranscriptTests.swift",
                     "Tests/Fork/ForkParakeetLongTests.swift", "Sources/Vorssaint/Fork/Dictation/Parakeet/ForkParakeetLong.swift",
                     "Sources/Vorssaint/Fork/Meetings/ForkMeetingTranscriptFormat.swift"]
        let banned = ["cas" + "tral", "op" + "ah", "mar" + "tial", "lou" + "is", "péage ven" + "ture", "ph ven" + "ture"]
        var found: [String] = []
        for file in files {
            let text = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").lowercased()
                .components(separatedBy: "\n").filter { !$0.hasPrefix("// copyright") }.joined(separator: "\n")
            if text.isEmpty { found.append("\(file): unread") }
            for name in banned where text.contains(name) { found.append("\(file): \(name)") }
        }
        suite.expect(found.isEmpty, "the transcript's data and tests name no real person or company: \(found)")
    }
}
