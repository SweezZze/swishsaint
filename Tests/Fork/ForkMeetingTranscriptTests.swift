// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The transcript of a meeting (PR 6): the echo of the Mac's speakers taken
/// out of the person's track, both sides merged by time, the `.txt` and the
/// `.srt`, what `meeting.json` keeps, which tracks are read, and the search.
enum ForkMeetingTranscriptTests {
    static func run(_ suite: TestSuite) {
        echoOnSpikeData(suite)
        echoGuards(suite)
        envelope(suite)
        segments(suite)
        text(suite)
        subtitles(suite)
        document(suite)
        record(suite)
        tracks(suite)
        folder(suite)
        search(suite)
        scheduling(suite)
        strings(suite)
    }

    private typealias Data = ForkMeetingTranscriptSpikeData

    private static func words(_ rows: [(String, Double, Double)]) -> [ForkParakeetWord] {
        rows.map { ForkParakeetWord(text: $0.0, start: $0.1, end: $0.2, confidence: 0.9) }
    }

    private static func energy(_ encoded: String) -> ForkMeetingEnvelope {
        ForkMeetingEnvelope(meanSquares: encoded.unicodeScalars.map { scalar in
            let decibels = Float(Int(scalar.value) - 0x100 - 120)
            return powf(10, decibels / 10)
        })
    }

    private static func word(_ text: String, _ start: Double, _ end: Double) -> ForkParakeetWord {
        ForkParakeetWord(text: text, start: start, end: end, confidence: 0.9)
    }

    // MARK: - Echo

    /// Spike S6's own minute: the speakers' echo goes, every word the
    /// person said stays.
    private static func echoOnSpikeData(_ suite: TestSuite) {
        let meeting = words(Data.meeting)
        let echoed = Data.microphoneWithEcho
        let report = ForkMeetingEcho.filter(micro: echoed.map { word($0.0, $0.1, $0.2) }, meeting: meeting,
                                            microEnvelope: energy(Data.microphoneWithEchoEnergy),
                                            meetingEnvelope: energy(Data.meetingEnergy))
        let ghosts = echoed.indices.filter { !echoed[$0].3 }
        let said = echoed.indices.filter { echoed[$0].3 }
        let removedGhosts = ghosts.filter { report.echo.contains($0) }.count
        let removedSaid = said.filter { report.echo.contains($0) }
        suite.expect(abs(report.delay - 0.12) <= 0.02,
                     "the speakers' delay is found in the two tracks' energy: \(report.delay) s for 120 ms")
        suite.expect(report.gain.map { $0 < 0.25 } == true && report.matches >= 20,
                     "the words heard on both sides calibrate an echo path well under the voice (\(report.matches) matches)")
        // A word said is worth more than an echo kept: the ones without a
        // twin that rise above the predicted echo stay (`ForkMeetingEcho`).
        suite.expect(Double(removedGhosts) >= 0.85 * Double(ghosts.count),
                     "85 % of the echoed words or more go: \(removedGhosts) of \(ghosts.count)")
        suite.expect(removedSaid.isEmpty,
                     "no word the person said goes with them: \(removedSaid.map { echoed[$0].0 })")

        let clean = ForkMeetingEcho.filter(micro: words(Data.microphone), meeting: meeting,
                                           microEnvelope: energy(Data.microphoneEnergy),
                                           meetingEnvelope: energy(Data.meetingEnergy))
        suite.expect(clean.echo.isEmpty && !clean.applied,
                     "with headphones, nothing is taken out of the person's track")
    }

    private static func echoGuards(_ suite: TestSuite) {
        // A meeting saying "un deux trois…" for a minute, a word a second;
        // the microphone hears each 0.12 s later, 20 dB lower.
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        let meeting = (0..<60).map { word(names[$0 % names.count], Double($0), Double($0) + 0.5) }
        var meetingEnergy = [Float](repeating: 1e-8, count: 6_100)
        var microEnergy = [Float](repeating: 1e-9, count: 6_100)
        for second in 0..<60 {
            for hop in (second * 100)..<(second * 100 + 50) {
                meetingEnergy[hop] = 0.01
                microEnergy[hop + 12] = 0.0001
            }
        }
        let echoes = meeting.map { word($0.text, $0.start + 0.12, $0.end + 0.12) }
        // The person answers over the participants, much louder than the echo.
        var interjection = word("OK", 30.12, 30.4)
        let louder = { (energy: inout [Float]) in for hop in 3_012..<3_040 { energy[hop] = 0.02 } }
        var micro = microEnergy
        louder(&micro)
        var heard = echoes
        heard[30] = interjection
        let report = ForkMeetingEcho.filter(micro: heard, meeting: meeting,
                                            microEnvelope: ForkMeetingEnvelope(meanSquares: micro),
                                            meetingEnvelope: ForkMeetingEnvelope(meanSquares: meetingEnergy))
        suite.expect(report.echo.count == 59 && !report.echo.contains(30),
                     "every echoed word goes, and an interjection said over a participant stays")
        interjection.text = "charlie"
        heard[30] = word(meeting[30].text, 30.12, 30.4)
        let repeated = ForkMeetingEcho.filter(micro: heard, meeting: meeting,
                                              microEnvelope: ForkMeetingEnvelope(meanSquares: micro),
                                              meetingEnvelope: ForkMeetingEnvelope(meanSquares: meetingEnergy))
        suite.expect(!repeated.echo.contains(30),
                     "a word the person says loud stays even when it is the participant's own word")

        let few = ForkMeetingEcho.filter(micro: Array(echoes.prefix(10)), meeting: meeting,
                                         microEnvelope: ForkMeetingEnvelope(meanSquares: microEnergy),
                                         meetingEnvelope: ForkMeetingEnvelope(meanSquares: meetingEnergy))
        suite.expect(few.echo.isEmpty && few.gain == nil,
                     "fewer than 20 words heard on both sides make no echo path: nothing goes")
        let loud = ForkMeetingEcho.filter(micro: echoes, meeting: meeting,
                                          microEnvelope: ForkMeetingEnvelope(meanSquares: meetingEnergy.map { $0 * 0.5 }),
                                          meetingEnvelope: ForkMeetingEnvelope(meanSquares: meetingEnergy))
        suite.expect(loud.echo.isEmpty && (loud.gain ?? 0) >= 0.25,
                     "a path above −6 dB is people answering each other, not an echo: nothing goes")

        suite.expect(ForkMeetingEcho.similar("bpifrance", "pifrance", 0.75)
                        && !ForkMeetingEcho.similar("oui", "ou", 0.75) && ForkMeetingEcho.similar("Oui,", "oui", 0.75) == false
                        && ForkMeetingEcho.normalized("Oui,") == "oui" && ForkMeetingEcho.normalized("Été") == "ete",
                     "words compare without case, accents or punctuation; short ones only when equal")
        suite.expect(ForkMeetingEcho.textMatches(micro: [word("delta", 3.45, 3.7)], meeting: meeting).isEmpty
                        && ForkMeetingEcho.textMatches(micro: [word("delta", 3.2, 3.6)], meeting: meeting) == [0],
                     "a twin counts only from 0.16 s before to 0.4 s after the meeting word")
    }

    private static func envelope(_ suite: TestSuite) {
        var envelope = ForkMeetingEnvelope()
        envelope.add([Float](repeating: 0.5, count: 100))
        envelope.add([Float](repeating: 0.5, count: 60) + [Float](repeating: 0, count: 170))
        suite.expect(envelope.meanSquares.count == 2 && abs(envelope.meanSquares[0] - 0.25) < 1e-6
                        && envelope.meanSquares[1] == 0,
                     "the energy is the mean square of each 10 ms, whatever the reads' sizes")
        let level = ForkMeetingEnvelope(meanSquares: [1, 1, 3, 3])
        suite.expect(level.level(0.02, 0.04) == 3 && level.level(0.02, 0.04, shift: 0.02) == 1 && level.level(1, 2) == 0,
                     "a stretch's level is read where asked, shifted back by the delay")
    }

    // MARK: - Files

    private static func segments(_ suite: TestSuite) {
        let words = [word("Bonjour", 0, 0.5), word("Camille.", 0.6, 1.0), word("On", 1.5, 1.7), word("commence", 1.7, 2.1),
                     word("vite", 3.5, 3.8)]
        let cut = ForkMeetingTranscriptFormat.segments(words, speaker: .me)
        suite.expect(cut.map(\.text) == ["Bonjour Camille.", "On commence", "vite"],
                     "a segment ends at a sentence's end followed by a pause, or at a pause of a second")
        let long = (0..<40).map { word("mot", Double($0), Double($0) + 0.9) }
        suite.expect(ForkMeetingTranscriptFormat.segments(long, speaker: .participants).allSatisfy { $0.end - $0.start <= 30 },
                     "no segment runs past 30 s")
        let me = ForkMeetingTranscriptFormat.segments([word("D’accord.", 12, 12.5)], speaker: .me)
        let others = ForkMeetingTranscriptFormat.segments([word("Le", 10, 10.2), word("budget", 10.2, 15)], speaker: .participants)
        let merged = ForkMeetingTranscriptFormat.merge(me, others)
        suite.expect(merged.map(\.speaker) == [.participants, .me],
                     "an interjection in the middle of a participant's sentence comes after that sentence")
        let same = ForkMeetingTranscriptFormat.merge(ForkMeetingTranscriptFormat.segments([word("Oui", 5, 5.2)], speaker: .me),
                                                     ForkMeetingTranscriptFormat.segments([word("Non", 5, 5.2)], speaker: .participants))
        suite.expect(same.map(\.speaker) == [.me, .participants], "at the same instant, the person first")
    }

    private static let labels: (ForkMeetingSpeaker) -> String = { $0 == .me ? "Moi\u{00A0}: " : "Participants\u{00A0}: " }

    private static func text(_ suite: TestSuite) {
        let merged = ForkMeetingTranscriptFormat.merge(
            ForkMeetingTranscriptFormat.segments([word("Bonjour", 0, 0.4), word("à", 0.4, 0.5), word("tous.", 0.5, 0.9),
                                                  word("D’accord.", 65.2, 65.6)], speaker: .me),
            ForkMeetingTranscriptFormat.segments([word("Bonjour", 10.8, 11.5), word("Camille.", 11.5, 12.2),
                                                  word("On", 13, 13.2), word("avance.", 13.2, 13.8)], speaker: .participants))
        let written = ForkMeetingTranscriptFormat.text(merged, label: labels)
        suite.expect(written == "[00:00:00] Moi\u{00A0}: Bonjour à tous.\n\n[00:00:10] Participants\u{00A0}: Bonjour Camille. On avance.\n\n[00:01:05] Moi\u{00A0}: D’accord.\n",
                     "the text is one paragraph per turn, its time and its speaker first")
        suite.expect(ForkMeetingTranscriptFormat.text([], label: labels).isEmpty, "nothing heard writes an empty text")
        suite.expect(ForkMeetingTranscriptFormat.timestamp(3_725.25) == "01:02:05,250"
                        && ForkMeetingTranscriptFormat.timestamp(3_725.25, milliseconds: false) == "01:02:05"
                        && ForkMeetingTranscriptFormat.timestamp(-1) == "00:00:00,000"
                        && ForkMeetingTranscriptFormat.timestamp(100 * 3_600) == "100:00:00,000",
                     "times read hours, minutes, seconds, and SubRip's milliseconds after a comma")
        let rules = [ForkDictationSupport.Replacement(heard: "kentoso", written: "Contoso"),
                     ForkDictationSupport.Replacement(heard: "google me", written: "Google Meet")]
        let replaced = ForkMeetingTranscriptFormat.text(
            ForkMeetingTranscriptFormat.segments([word("Chez", 0, 0.2), word("Kentoso,", 0.2, 0.6), word("sur", 0.6, 0.8),
                                                  word("Google", 0.8, 1), word("Me.", 1, 1.2)], speaker: .participants),
            label: labels, rewrite: { ForkDictationReplacements.apply(rules, to: $0) })
        suite.expect(replaced == "[00:00:00] Participants\u{00A0}: Chez Contoso, sur Google Meet.\n",
                     "the dictation's replacements put the names right, across words too")
    }

    private static func subtitles(_ suite: TestSuite) {
        var many: [ForkParakeetWord] = []
        for index in 0..<60 { many.append(word(index % 7 == 0 ? "incontestablement" : "mot", Double(index) * 0.3, Double(index) * 0.3 + 0.28)) }
        let merged = ForkMeetingTranscriptFormat.merge(
            ForkMeetingTranscriptFormat.segments(many, speaker: .participants, pause: 100, sentencePause: 100, maxDuration: 100),
            ForkMeetingTranscriptFormat.segments([word("Oui.", 4, 4.3)], speaker: .me))
        let cues = ForkMeetingTranscriptFormat.cues(merged, label: labels)
        suite.expect(cues.allSatisfy { $0.end - $0.start <= ForkMeetingTranscriptFormat.maxCueSeconds
                                       && $0.text.count <= ForkMeetingTranscriptFormat.maxCueCharacters },
                     "every subtitle holds 6 s and 84 characters at most, its speaker included")
        suite.expect(zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start }
                        && cues.contains { $0.text == "Moi\u{00A0}: Oui." },
                     "the subtitles are in time order, both sides together")
        suite.expect(cues.filter { $0.text.hasPrefix("Participants") }.map { $0.text.dropFirst(labels(.participants).count) }.joined(separator: " ")
                        == many.map(\.text).joined(separator: " "),
                     "the subtitles cut between words and lose none")
        let srt = ForkMeetingTranscriptFormat.srt([ForkMeetingTranscriptFormat.Cue(start: 1.5, end: 3, text: "Moi : Bonjour"),
                                                   ForkMeetingTranscriptFormat.Cue(start: 62, end: 64.25, text: "Autres : Salut")])
        suite.expect(srt == "1\n00:00:01,500 --> 00:00:03,000\nMoi : Bonjour\n\n2\n00:01:02,000 --> 00:01:04,250\nAutres : Salut\n\n",
                     "SubRip numbers its cues and writes their times with a comma")
        let short = ForkMeetingTranscriptFormat.cues([ForkMeetingTranscriptFormat.Segment(speaker: .me, words: [word("Oh", 2, 2.1)])],
                                                     label: labels)
        suite.expect(short.first.map { $0.end - $0.start } == 0.5, "a cue lasts half a second at least, to be read")
        // Spike S6's hour: « l'évaluement » heard over 6.6 s.
        let stretched = ForkMeetingTranscriptFormat.cues(
            [ForkMeetingTranscriptFormat.Segment(speaker: .participants, words: [word("l’évaluement", 1_099.28, 1_105.92)])],
            label: labels)
        suite.expect(stretched.first.map { $0.end - $0.start } == ForkMeetingTranscriptFormat.maxCueSeconds,
                     "a word Parakeet stretched over a pause still shows 6 s at most")
        let rules = [ForkDictationSupport.Replacement(heard: "mot", written: "vocabulaire")]
        let rewritten = ForkMeetingTranscriptFormat.cues(merged, label: labels,
                                                         rewrite: { ForkDictationReplacements.apply(rules, to: $0) })
        suite.expect(rewritten.allSatisfy { $0.text.count <= ForkMeetingTranscriptFormat.maxCueCharacters }
                        && rewritten.contains { $0.text.contains("vocabulaire") },
                     "a subtitle is measured once rewritten: replacements never make it overflow")
    }

    private static func document(_ suite: TestSuite) {
        let made = ForkMeetingTranscriptFormat.document(
            me: Data.microphoneWithEcho.map { word($0.0, $0.1, $0.2) }, participants: words(Data.meeting),
            microEnvelope: energy(Data.microphoneWithEchoEnergy), meetingEnvelope: energy(Data.meetingEnergy),
            label: labels)
        let said = Data.microphoneWithEcho.filter(\.3).count
        suite.expect(made.words >= Data.meeting.count + said && made.words <= Data.meeting.count + said + 15,
                     "the document counts the words kept, the echo out (\(made.words))")
        suite.expect(made.text.hasPrefix("[00:00:00] Moi\u{00A0}: Bonjour à tous") && made.text.contains("Participants\u{00A0}: Bonjour Camille."),
                     "the spike's minute reads as the person, then the participants")
        let alone = ForkMeetingTranscriptFormat.document(me: [], participants: [word("Bonjour", 0, 0.5)], microEnvelope: nil,
                                                         meetingEnvelope: nil, label: labels)
        suite.expect(alone.words == 1 && alone.echo == nil && alone.srt.contains("Participants\u{00A0}: Bonjour"),
                     "a meeting without its microphone's track is the participants alone")
    }

    // MARK: - meeting.json

    private static func record(_ suite: TestSuite) {
        let at = Date(timeIntervalSince1970: 1_792_400_000.7)
        let done = ForkMeetingTranscriptRecord(state: .done, words: 8_890, language: "fr", at: at)
        guard case let .object(object) = done.json else {
            suite.expect(false, "a transcript record is an object")
            return
        }
        suite.expect(object["state"] == .string("done") && object["words"] == .number(8_890)
                        && object["language"] == .string("fr") && object["engine"] == .string("parakeet")
                        && object["at"] == .string("2026-10-19T08:53:20Z") && object["reason"] == nil,
                     "meeting.json says {state, words, language, engine: parakeet, at}, at in whole seconds of UTC")
        suite.expect(ForkMeetingTranscriptRecord(json: done.json) == ForkMeetingTranscriptRecord(state: .done, words: 8_890,
                                                                                                   language: "fr",
                                                                                                   at: Date(timeIntervalSince1970: 1_792_400_000)),
                     "a record reads back as it was written")
        let later: ForkMeetingJSON = .object(["state": .string("done"), "words": .number(3), "speakers": .number(4)])
        let replaced = done.replacing(later)
        suite.expect(ForkMeetingTranscriptRecord(json: replaced)?.preserved == ["speakers": .number(4)]
                        && ForkMeetingTranscriptRecord(json: replaced)?.words == 8_890,
                     "a key a later version wrote is kept when the transcript is written again")
        suite.expect(ForkMeetingTranscriptRecord(json: nil) == nil
                        && ForkMeetingTranscriptRecord(json: .object(["state": .string("diarized")])) == nil
                        && ForkMeetingTranscriptRecord(json: .string("done")) == nil,
                     "no transcript, or one this version cannot read, offers to transcribe")
        let failed = ForkMeetingTranscriptRecord(state: .failed, at: at, reason: ForkMeetingTranscriptFailure.noAudio.rawValue)
        suite.expect(ForkMeetingTranscriptRecord(json: failed.json)?.reason == "noAudio"
                        && ForkMeetingTranscriptRecord(json: failed.json)?.words == nil,
                     "a failure is kept with its reason, and no words")

        var sidecar = ForkMeetingSidecar.started(id: UUID(), startedAt: at, origin: .manual, title: "Point",
                                                 titleSource: .user, capture: ForkMeetingSidecar.Capture())
        sidecar.transcript = done.json
        let encoded = (try? sidecar.encoded()).flatMap { try? ForkMeetingSidecar.decode($0).get() }
        suite.expect(encoded.flatMap { ForkMeetingTranscriptRecord(json: $0.transcript) }?.words == 8_890,
                     "the record goes through meeting.json and back")
        let unknownState = ForkMeetingTranscriptRecord(json: .object(["state": .string("done"), "words": .number(-3)]))
        suite.expect(unknownState?.words == nil, "a word count that makes no sense is not shown")
    }

    private static func tracks(_ suite: TestSuite) {
        suite.expect(ForkMeetingTranscript.tracks(enabled: [true, false, false])
                        == ForkMeetingTranscript.Tracks(meeting: 1, microphone: 2),
                     "a final file is read past its mix, the one track that plays: the meeting, then the microphone")
        suite.expect(ForkMeetingTranscript.tracks(enabled: [true, true])
                        == ForkMeetingTranscript.Tracks(meeting: 0, microphone: 1),
                     "a master, or a final file that kept its tracks, is the meeting then the microphone")
        suite.expect(ForkMeetingTranscript.tracks(enabled: [true, false])
                        == ForkMeetingTranscript.Tracks(meeting: 1, microphone: nil)
                        && ForkMeetingTranscript.tracks(enabled: [true])
                        == ForkMeetingTranscript.Tracks(meeting: 0, microphone: nil)
                        && ForkMeetingTranscript.tracks(enabled: []) == nil,
                     "fewer tracks read what there is, and none means nothing to transcribe")
        suite.expect(ForkMeetingTranscript.source(video: "a.mp4", hasMaster: true) == "a.mp4"
                        && ForkMeetingTranscript.source(video: nil, hasMaster: true) == ForkMeetingFolder.masterName
                        && ForkMeetingTranscript.source(video: nil, hasMaster: false) == nil,
                     "the video is read, else an interrupted meeting's master")
        let named = ForkMeetingTranscript.fileNames(source: "2026-10-18 10h02 — Point.mp4", folderName: "x")
        let master = ForkMeetingTranscript.fileNames(source: ForkMeetingFolder.masterName, folderName: "2026-10-18 10h02")
        suite.expect(named == ("2026-10-18 10h02 — Point.txt", "2026-10-18 10h02 — Point.srt")
                        && master == ("2026-10-18 10h02.txt", "2026-10-18 10h02.srt")
                        && ForkMeetingTranscript.draftName("a.txt") == ".swishsaint-transcript-a.txt.draft",
                     "the transcript is named after the video, else the folder, and written through a hidden draft")
    }

    private static func folder(_ suite: TestSuite) {
        let names = ["2026-10-18 10h02 — Point.mp4", "2026-10-18 10h02 — Point.m4a", "2026-10-18 10h02 — Point.txt",
                     "2026-10-18 10h02 — Point.srt", "notes.txt", "meeting.json", ".2026-10-18 10h02 — Point.txt.draft"]
        let ours = ["2026-10-18 10h02 — Point.txt", "2026-10-18 10h02 — Point.srt"]
        let contents = ForkMeetingFolder.contents(of: names, folderName: "2026-10-18 10h02 — Point", transcriptFiles: ours)
        suite.expect(contents.transcript == "2026-10-18 10h02 — Point.txt" && contents.subtitles == "2026-10-18 10h02 — Point.srt",
                     "a folder's transcript is the text this app wrote, by the names meeting.json keeps")
        suite.expect(ForkMeetingFolder.contents(of: names, folderName: "2026-10-18 10h02 — Point").transcript == nil,
                     "without its names in meeting.json, no text is taken for the transcript")
        let other = ForkMeetingFolder.contents(of: ["notes.txt", "meeting.json", "a.mp4"], folderName: "2026-10-18 10h02")
        suite.expect(other.transcript == nil && other.subtitles == nil,
                     "a text file the person put beside the meeting is not its transcript")
        let renames = ForkMeetingFolder.mediaRenames(from: "2026-10-18 10h02 — Point", to: "2026-10-18 10h02 — Budget",
                                                     names: names, transcriptFiles: ours)
        suite.expect(Set(renames.moves.map(\.to)) == ["2026-10-18 10h02 — Budget.mp4", "2026-10-18 10h02 — Budget.m4a",
                                                      "2026-10-18 10h02 — Budget.txt", "2026-10-18 10h02 — Budget.srt"]
                        && !renames.moves.contains { $0.from == "notes.txt" },
                     "a rename takes the transcript and its subtitles with the video, and leaves the person's notes")
    }

    private static func search(_ suite: TestSuite) {
        let english = ForkMeetingStrings.strings(.enUS)
        let sidecar = ForkMeetingSidecar.started(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_792_400_000),
                                                 origin: .manual, title: "Weekly", titleSource: .user,
                                                 capture: ForkMeetingSidecar.Capture())
        let names = ["2026-10-18 10h02 — Weekly.mp4", "2026-10-18 10h02 — Weekly.txt", "meeting.json"]
        guard let entry = ForkMeetingLibraryEntry(folderName: "2026-10-18 10h02 — Weekly", sidecar: .success(sidecar),
                                                  contents: ForkMeetingFolder.contents(
                                                      of: names, folderName: "2026-10-18 10h02 — Weekly",
                                                      transcriptFiles: ["2026-10-18 10h02 — Weekly.txt"]))
        else {
            suite.expect(false, "a meeting with its transcript is listed")
            return
        }
        suite.expect(entry.transcript == "2026-10-18 10h02 — Weekly.txt", "the row knows its transcript")
        let renamed = entry.renamed(to: "2026-10-18 10h02 — Budget",
                                    media: [ForkMeetingFolder.Move(from: "2026-10-18 10h02 — Weekly.txt", to: "2026-10-18 10h02 — Budget.txt")],
                                    title: "Budget")
        suite.expect(renamed.transcript == "2026-10-18 10h02 — Budget.txt", "a renamed row follows its transcript")

        var index = ForkMeetingTranscriptIndex()
        let key = ForkMeetingTranscriptIndex.key(folder: entry.folderName, file: entry.transcript ?? "")
        let stamp = ForkMeetingTranscriptIndex.Stamp(size: 120, modified: Date(timeIntervalSince1970: 1))
        suite.expect(index.stale([key: stamp]) == [key], "a transcript not read yet is read")
        index.update(keeping: [key], read: [key: ForkMeetingTranscriptIndex.Item(
            stamp: stamp, folded: ForkMeetingTranscriptIndex.folded("[00:00:10] Others: Le churn est passé à 4,2 %.\n\n[00:01:00] Me: Bpifrance."))])
        suite.expect(index.stale([key: stamp]).isEmpty
                        && index.stale([key: ForkMeetingTranscriptIndex.Stamp(size: 121, modified: stamp.modified)]) == [key],
                     "a transcript is read again only when it changed")
        let said = { (row: ForkMeetingLibraryEntry) in index.text(folder: row.folderName, file: row.transcript) }
        suite.expect(ForkMeetingLibrary.matches(entry, query: "CHURN passe", strings: english, transcript: said)
                        && ForkMeetingLibrary.matches(entry, query: "weekly bpifrance", strings: english, transcript: said)
                        && !ForkMeetingLibrary.matches(entry, query: "churn", strings: english),
                     "the search finds a meeting by what was said in it, folded like the rest, words in any field")
        suite.expect(!ForkMeetingLibrary.matches(entry, query: "00:00:10", strings: english, transcript: said),
                     "the times of the transcript are not searched")
        index.update(keeping: [], read: [:])
        suite.expect(index.text(folder: entry.folderName, file: entry.transcript) == nil,
                     "a transcript gone is forgotten")
    }

    private static func scheduling(_ suite: TestSuite) {
        suite.expect(ForkMeetingTranscript.transcribesAutomatically(featureOn: true, settingOn: true, recovered: false)
                        && !ForkMeetingTranscript.transcribesAutomatically(featureOn: true, settingOn: false, recovered: false)
                        && !ForkMeetingTranscript.transcribesAutomatically(featureOn: false, settingOn: true, recovered: false)
                        && !ForkMeetingTranscript.transcribesAutomatically(featureOn: true, settingOn: true, recovered: true),
                     "a meeting is transcribed on its own only with the setting on, after a meeting that ended well")
        suite.expect(ForkMeetingTranscript.mayStart(automatic: true, recording: false, finalizing: false)
                        && !ForkMeetingTranscript.mayStart(automatic: true, recording: true, finalizing: false)
                        && ForkMeetingTranscript.mayStart(automatic: false, recording: true, finalizing: false),
                     "an automatic transcription waits for a recording to end; a click starts at once")
        suite.expect(ForkMeetingTranscript.progress(trackIndex: 0, tracks: 2, seconds: 1_800, duration: 3_600) == 0.25
                        && ForkMeetingTranscript.progress(trackIndex: 1, tracks: 2, seconds: 3_600, duration: 3_600) == 1
                        && ForkMeetingTranscript.progress(trackIndex: 0, tracks: 1, seconds: 10, duration: 0) == 0,
                     "the progress shares the two tracks by their length")
        suite.expect(ForkMeetingTranscript.baseLanguage("fr-CA") == "fr" && ForkMeetingTranscript.baseLanguage("und") == nil
                        && ForkMeetingTranscript.baseLanguage(nil) == nil && ForkMeetingTranscript.languageCount == 25,
                     "the language kept is a base code, and Parakeet says its 25 languages")
    }

    private static func strings(_ suite: TestSuite) {
        var tooLong: [String] = []
        for language in AppLanguage.allCases {
            let text = ForkMeetingStrings.strings(language)
            for short in [text.noticeTranscriptReady, text.noticeTranscriptFailed, text.actionTranscribe,
                          text.actionOpenTranscript, text.actionRetranscribe, text.transcriptInstall,
                          text.transcriptWaiting, text.transcriptProgress("100 %"), text.transcriptWords(99_999)]
            where short.count > 28 {
                tooLong.append("\(language.rawValue): \(short)")
            }
        }
        suite.expect(tooLong.isEmpty, "the transcript's notices and buttons fit in 28 characters: \(tooLong)")
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { $0.transcriptLanguages(25).contains("25") && $0.transcriptWords(12).contains("12")
                                      && $0.transcriptMeLabel != $0.transcriptOthersLabel },
                     "every language says Parakeet's languages, the words, and tells the two sides apart")
        suite.expect(ForkMeetingStrings.strings(.fr).transcriptMeLabel == "Moi\u{00A0}: "
                        && ForkMeetingStrings.strings(.enUS).transcriptMeLabel == "Me: ",
                     "the person is “Moi” in French, with its no-break space, and “Me” in English")
    }
}
