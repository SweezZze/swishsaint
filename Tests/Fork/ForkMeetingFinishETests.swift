// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// After the meeting, as Loom and Tella do it (Finish E): the moments
/// marked while recording, the transcript that follows the video, and the
/// summary written on this Mac.
enum ForkMeetingFinishETests {
    static func run(_ suite: TestSuite) {
        markersInTheRecord(suite)
        markerTimes(suite)
        markersInTheTranscript(suite)
        subtitlesRead(suite)
        followingTheVideo(suite)
        speeds(suite)
        summaryParts(suite)
        summaryAnswers(suite)
        summaryFile(suite)
        summaryRecord(suite)
        exportsSendThem(suite)
        libraryShowsThem(suite)
        texts(suite)
    }

    private static let start = Date(timeIntervalSince1970: 1_792_310_531)

    private static func meeting() -> ForkMeetingSidecar {
        var sidecar = ForkMeetingSidecar.started(id: UUID(uuidString: "1B2C3D4E-5F60-4718-8293-A4B5C6D7E8F9")!,
                                                 startedAt: start, origin: .manual, title: "Point hebdo",
                                                 titleSource: .user,
                                                 capture: .init(target: .window, systemAudio: .app, microphone: "off",
                                                                quality: .standard))
        sidecar.state = .complete
        sidecar.recordedSeconds = 1800
        return sidecar
    }

    private static func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> ForkParakeetWord {
        ForkParakeetWord(text: text, start: start, end: end, confidence: 0.9)
    }

    // MARK: - Markers

    private static func markersInTheRecord(_ suite: TestSuite) {
        let patched = ForkMeetingSidecarPatch(marker: .init(at: 754.2)).applied(to: meeting())
        let again = ForkMeetingSidecarPatch(marker: .init(at: 1201)).applied(to: patched)
        suite.expect(again.markers?.map(\.at) == [754.2, 1201],
                     "each moment marked is appended to meeting.json, in the order it was marked")
        let data = (try? again.encoded()) ?? Data()
        let read = try? ForkMeetingSidecar.decode(data).get()
        suite.expect(read?.markers == again.markers && String(decoding: data, as: UTF8.self).contains("\"markers\""),
                     "the markers are written and read back as they were")
        let later = Data(#"{"schema":1,"markers":[{"at":12.5,"label":"Budget"}],"summary":{"state":"done","engine":"apple","model":"v2"}}"#.utf8)
        let kept = try? ForkMeetingSidecar.decode(later).get()
        let rewritten = kept.flatMap { try? ForkMeetingSidecarPatch(marker: .init(at: 30)).applied(to: $0).encoded() }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        suite.expect(kept?.markers?.first?.at == 12.5 && rewritten.contains("Budget") && rewritten.contains("\"model\""),
                     "a later version's keys inside a marker and the summary survive a patch of this one")
        let unreadable = Data(#"{"schema":1,"markers":"twelve"}"#.utf8)
        let odd = try? ForkMeetingSidecar.decode(unreadable).get()
        let after = odd.map { ForkMeetingSidecarPatch(marker: .init(at: 30)).applied(to: $0) }
        suite.expect(after?.markers == nil && after?.preserved["markers"] == .string("twelve"),
                     "markers this version cannot read are kept as written, never replaced by a partial list")
        suite.expect(ForkMeetingSidecar.started(id: UUID(), startedAt: start, origin: .manual, title: nil,
                                                titleSource: nil, capture: .init()).markers == nil,
                     "a meeting starts without markers: the key appears with the first one")
    }

    private static func markerTimes(_ suite: TestSuite) {
        typealias M = ForkMeetingMarkers
        suite.expect(M.time(recorded: 754.236) == 754.2 && M.time(recorded: -3) == 0 && M.time(recorded: .nan) == 0,
                     "a marker's time is the recording's, in tenths of a second, never negative")
        suite.expect(M.isNew(10, after: []) && !M.isNew(11.5, after: [10]) && M.isNew(12.1, after: [10]),
                     "a second press within 2 s is the same moment")
        let times = M.times([.init(at: 30), .init(at: nil), .init(at: -1), .init(at: 10), .init(at: 11), .init(at: .infinity)])
        suite.expect(times == [10, 30], "the markers read are sorted, the unreadable left out, the doubles merged: \(times)")
        suite.expect(M.playFrom(10) == 7 && M.playFrom(1) == 0, "a marker plays from 3 s before it, never before the start")
        suite.expect(M.transcriptLine(3723) == "★ [01:02:03]" && M.clock(5) == "00:00:05",
                     "a marker is written ★ [hh:mm:ss], the same in every language")
        suite.expect(M.fraction(450, duration: 1800) == 0.25 && M.fraction(2000, duration: 1800) == 1
                        && M.fraction(10, duration: nil) == nil && M.fraction(10, duration: 0) == nil,
                     "a marker sits on the strip at its share of the video, inside it")
    }

    private static func markersInTheTranscript(_ suite: TestSuite) {
        let label: (ForkMeetingSpeaker) -> String = { $0 == .me ? "Moi : " : "Participants : " }
        let me = ForkMeetingTranscriptFormat.segments([word("Bonjour.", 1, 1.5)], speaker: .me)
        let others = ForkMeetingTranscriptFormat.segments([word("Le", 10, 10.2), word("budget.", 10.2, 11),
                                                           word("Validé.", 40, 41)], speaker: .participants)
        let merged = ForkMeetingTranscriptFormat.merge(me, others)
        let plain = ForkMeetingTranscriptFormat.text(merged, label: label)
        let marked = ForkMeetingTranscriptFormat.text(merged, label: label, markers: [0.5, 12, 3600])
        suite.expect(plain == ForkMeetingTranscriptFormat.text(merged, label: label, markers: []),
                     "without markers the text is what it was")
        let paragraphs = marked.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }
        suite.expect(paragraphs == ["★ [00:00:00]", "[00:00:01] Moi : Bonjour.", "[00:00:10] Participants : Le budget. Validé.",
                                    "★ [00:00:12]", "★ [01:00:00]"],
                     "each marker is a line before the first paragraph that starts after it, the last ones at the end: \(paragraphs)")
        let document = ForkMeetingTranscriptFormat.document(me: [], participants: [word("Oui.", 5, 6)], microEnvelope: nil,
                                                            meetingEnvelope: nil, label: label, markers: [2])
        suite.expect(document.text.hasPrefix("★ [00:00:02]\n\n[00:00:05]") && !document.srt.contains("★"),
                     "the transcription writes the markers in the .txt, not in the subtitles")
        suite.expect(ForkMeetingTranscriptIndex.folded(marked).contains("bonjour"),
                     "a transcript with markers is still found by the search")
    }

    // MARK: - Synced transcript

    private static func subtitlesRead(_ suite: TestSuite) {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\nMoi : Bonjour\r\n\r\n2\n00:00:02,000 --> 00:00:04,000\nParticipants : Salut\nà tous\n\nbroken\n\n3\n00:00:09,000 --> 00:00:08,000\nbackwards\n\n4\n00:01:00.250 --> 00:01:02,000\nLe budget\n"
        let cues = ForkMeetingPlayback.cues(srt: srt)
        suite.expect(cues.map(\.text) == ["Moi : Bonjour", "Participants : Salut à tous", "Le budget"]
                        && cues.first?.start == 1 && cues.last?.start == 60.25,
                     "the subtitles are read, Windows line ends and a mark included; a block that does not read is skipped: \(cues)")
        let ours = ForkMeetingTranscriptFormat.srt([.init(start: 3723.5, end: 3725, text: "Moi : Oui")])
        suite.expect(ForkMeetingPlayback.cues(srt: ours) == [.init(start: 3723.5, end: 3725, text: "Moi : Oui")],
                     "what the transcription writes reads back exactly")
        suite.expect(ForkMeetingPlayback.seconds("01:02:03,5") == 3723.5 && ForkMeetingPlayback.seconds("1:2") == nil,
                     "a SubRip time reads to the millisecond, a broken one not at all")
    }

    private static func followingTheVideo(_ suite: TestSuite) {
        typealias P = ForkMeetingPlayback
        let cues = [P.Cue(start: 1, end: 3, text: "a"), P.Cue(start: 10, end: 12, text: "b"), P.Cue(start: 11, end: 13, text: "c")]
        let rows = P.rows(cues: cues, markers: [10, 20])
        suite.expect(rows == [.cue(cues[0]), .marker(10), .cue(cues[1]), .cue(cues[2]), .marker(20)],
                     "the markers sit among the lines by time, before the line that starts with them")
        suite.expect(P.current(rows, at: 0.5) == nil && P.current(rows, at: 2) == 0 && P.current(rows, at: 5) == 0
                        && P.current(rows, at: 7) == nil,
                     "a line stays lit while said and 3 s after, then none in a long silence")
        suite.expect(P.current(rows, at: 10) == 2 && P.current(rows, at: 11.5) == 3 && P.current(rows, at: 21) == nil
                        && P.current(rows, at: 15) == 3,
                     "the line lit is the last one started, never a marker")
        suite.expect(P.current([], at: 5) == nil, "no line, nothing lit")
        suite.expect(P.copiedText("\n[00:00:01] Moi : Oui\n\n") == "[00:00:01] Moi : Oui\n",
                     "the transcript copied is the text as written")
    }

    private static func speeds(_ suite: TestSuite) {
        typealias P = ForkMeetingPlayback
        suite.expect(P.speeds == [1, 1.5, 2] && P.nextSpeed(after: 1) == 1.5 && P.nextSpeed(after: 2) == 1
                        && P.nextSpeed(after: 1.25) == 1,
                     "the speed goes 1×, 1.5×, 2×, and around")
        suite.expect(P.speedLabel(1.5, locale: Locale(identifier: "fr_FR")) == "1,5×"
                        && P.speedLabel(1.5, locale: Locale(identifier: "en_US")) == "1.5×"
                        && P.speedLabel(2, locale: Locale(identifier: "en_US")) == "2×",
                     "the speed is written as the language writes its numbers")
    }

    // MARK: - Summary

    private static func summaryParts(_ suite: TestSuite) {
        typealias S = ForkMeetingSummary
        let paragraphs = (0..<40).map { "[00:\(String(format: "%02d", $0)):00] Moi : " + String(repeating: "mot ", count: 40) }
        let text = paragraphs.joined(separator: "\n\n")
        let parts = S.parts(text, limit: 1000)
        suite.expect(parts.count > 1 && parts.allSatisfy { $0.count <= 1000 }
                        && parts.joined(separator: "\n\n") == paragraphs.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n\n"),
                     "a long transcript is cut between paragraphs, each part under the limit, nothing lost")
        let long = String(repeating: "Une phrase assez longue pour remplir. ", count: 100)
        let cut = S.parts(long, limit: 500)
        suite.expect(cut.count > 1 && cut.allSatisfy { $0.count <= 500 } && cut.allSatisfy { $0.hasSuffix(".") },
                     "a paragraph longer than a part is cut between sentences")
        let words = S.split(String(repeating: "x", count: 30) + " " + String(repeating: "y ", count: 300), limit: 100)
        suite.expect(words.allSatisfy { $0.count <= 100 } && words.count > 1, "a sentence longer than a part, between words")
        suite.expect(S.parts("  \n\n  ") == [] && S.parts("Oui.") == ["Oui."], "an empty transcript has no part, a short one one")
        let groups = S.mergeGroups(Array(repeating: String(repeating: "n", count: 400), count: 7), limit: 1000)
        suite.expect(groups.flatMap { $0 }.count == 7 && groups.allSatisfy { $0.count >= 2 } && groups.count == 3,
                     "the notes are merged in groups under the limit, never a group of one: \(groups.map(\.count))")
        suite.expect(S.mergeGroups(["a"]) == [["a"]], "a single note is its own group")
        suite.expect(S.progress(done: 0, parts: 4) == 0 && S.progress(done: 4, parts: 4) == 0.8
                        && S.progress(done: 1, parts: 1) == 1,
                     "the share done counts the parts, then the merge")
    }

    private static func summaryAnswers(_ suite: TestSuite) {
        typealias S = ForkMeetingSummary
        let answer = """
        **SUMMARY:**
        - Le budget Q4 est validé à 38 500 €.
        • Thomas présente la feuille de route.
        ## Decisions
        1. Lancer la due diligence avec Bpifrance.
        ACTIONS: Martial envoie le compte rendu vendredi.
        - none
        """
        let notes = S.notes(from: answer)
        suite.expect(notes.points == ["Le budget Q4 est validé à 38 500 €.", "Thomas présente la feuille de route."]
                        && notes.decisions == ["Lancer la due diligence avec Bpifrance."]
                        && notes.actions == ["Martial envoie le compte rendu vendredi."],
                     "the model's answer is read whatever the dress of its headers and bullets: \(notes)")
        let bare = S.notes(from: "The team agreed to ship on Friday.\nSummary of the call follows.")
        suite.expect(bare.points == ["The team agreed to ship on Friday.", "Summary of the call follows."]
                        && bare.decisions.isEmpty,
                     "an answer without headers is points; a sentence starting with Summary is not a header")
        suite.expect(S.isNothing("None.") && S.isNothing("Aucune") && S.isNothing("N/A") && !S.isNothing("Nonetheless"),
                     "what the model writes for nothing is left out")
        let round = ForkMeetingSummaryNotes(points: ["a"], decisions: [], actions: ["b"])
        suite.expect(S.notes(from: round.text) == round, "the notes read back as they were given to the merge")
        let instructions = S.instructions(language: "fr", me: "Moi\u{00A0}: ", others: "Participants\u{00A0}: ")
        suite.expect(instructions.contains("Write every point in French.") && instructions.contains("\"Moi\"")
                        && instructions.contains("SUMMARY:") && instructions.contains("never invent"),
                     "the model is told the meeting's language, who is who, and to invent nothing")
        suite.expect(S.languageName("fr") == "French" && S.languageName("de") == "German" && S.languageName(nil) == nil,
                     "the language is named for the model in English")
        suite.expect(S.partPrompt("x", index: 1, count: 3).hasPrefix("Part 2 of 3") && S.mergePrompt(["a", "b"]).contains("Notes 2:"),
                     "each part says where it is in the meeting")
    }

    private static func summaryFile(_ suite: TestSuite) {
        typealias S = ForkMeetingSummary
        let french = ForkMeetingStrings.strings(.fr)
        let notes = ForkMeetingSummaryNotes(points: ["Budget validé."], decisions: [], actions: ["Martial : compte rendu."])
        let file = S.markdown(notes, title: "Point hebdo", date: "lundi 19 octobre 2026", headings: french.summaryHeadings,
                              partial: true)
        suite.expect(file.hasPrefix("# Point hebdo — Résumé\n\nlundi 19 octobre 2026\n\n> ")
                        && file.contains("## Points clés\n\n- Budget validé.")
                        && file.contains("## Décisions\n\n_Rien de noté._")
                        && file.contains("## À faire\n\n- Martial : compte rendu.")
                        && file.hasSuffix("_" + french.summaryFooter + "_\n"),
                     "the file has its title, its date, a partial note, three sections and where it comes from: \(file)")
        suite.expect(S.fileName(source: "2026-10-19 10h02 — Point.mp4", folderName: "x", word: "résumé")
                        == "2026-10-19 10h02 — Point résumé.md"
                        && S.fileName(source: ForkMeetingFolder.masterName, folderName: "Dossier", word: "summary") == "Dossier summary.md",
                     "the summary is named after the video, else the folder")
        suite.expect(S.placement("A résumé.md", names: ["A résumé.md"], ours: []) == "A résumé 2.md"
                        && S.placement("A résumé.md", names: ["a RÉSUMÉ.md"], ours: ["A résumé.md"]) == "A résumé.md"
                        && S.placement("A résumé.md", names: ["A.mp4"], ours: []) == "A résumé.md",
                     "a file of the person's under that name is never replaced; this app's own is")
        suite.expect(S.isSummaryName("a.md") && !S.isSummaryName("../a.md") && !S.isSummaryName(".a.md")
                        && !S.isSummaryName("a.mp4"),
                     "only a bare .md is ever a summary")
        suite.expect(S.headingLanguage("fr", app: .enUS) == .fr && S.headingLanguage("en", app: .fr) == .enUS
                        && S.headingLanguage("nl", app: .de) == .de && S.headingLanguage(nil, app: .it) == .it
                        && S.headingLanguage("zh", app: .zhHK) == .zhHK,
                     "the file speaks the meeting's language when the app does, else the app's")
        suite.expect(S.summarizesAutomatically(featureOn: true, settingOn: true, available: true)
                        && !S.summarizesAutomatically(featureOn: true, settingOn: true, available: false)
                        && !S.summarizesAutomatically(featureOn: true, settingOn: false, available: true),
                     "a summary starts on its own only when asked, and only where Apple Intelligence runs")
    }

    private static func summaryRecord(_ suite: TestSuite) {
        let record = ForkMeetingSummaryRecord(state: .done, at: start, language: "fr", parts: 3, skipped: 0,
                                              files: ["A résumé.md"])
        let json = record.replacing(.object(["future": .bool(true)]))
        let read = ForkMeetingSummaryRecord(json: json)
        suite.expect(read?.state == .done && read?.parts == 3 && read?.files == ["A résumé.md"] && read?.language == "fr"
                        && read?.skipped == nil && read?.preserved["future"] == .bool(true),
                     "the summary's record reads back, a later version's key kept")
        let hostile = ForkMeetingSummaryRecord(json: .object(["state": .string("done"),
                                                              "files": .array([.string("../x.md"), .string("a.mp4"), .string("b.md")])]))
        suite.expect(hostile?.files == ["b.md"], "a record never names a file outside the folder, nor the video")
        suite.expect(ForkMeetingSummaryRecord(json: .object(["state": .string("thinking")])) == nil
                        && ForkMeetingSummaryRecord(json: nil) == nil,
                     "a state this version does not know is no summary")
    }

    private static func exportsSendThem(_ suite: TestSuite) {
        typealias Document = ForkMeetingExportDocument
        var sidecar = meeting()
        sidecar.meetCode = "abc-defg-hij"
        sidecar.markers = [.init(at: 30, preserved: ["label": .string("Budget privé")]), .init(at: 10)]
        let summary = "# Point — Summary\n- Rejoindre abc-defg-hij demain."
        func object(_ data: Data?) -> [String: Any] {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let plain = object(try? Document.json(sidecar, includesMeetCode: false, includesNotes: false, summary: summary))
        let markers = plain["markers"] as? [[String: Any]] ?? []
        suite.expect(markers.count == 2 && markers.allSatisfy { Set($0.keys) == Set(Document.markerFields) }
                        && markers.first?["at"] as? Double == 10 && plain["summary"] == nil,
                     "the markers leave sorted, with their time only; the summary not without its option")
        let asked = object(try? Document.json(sidecar, includesMeetCode: false, includesNotes: false, includesSummary: true,
                                              summary: summary))
        suite.expect((asked["summary"] as? String)?.contains("Rejoindre") == true
                        && (asked["summary"] as? String)?.contains("abc-defg-hij") == false,
                     "the summary leaves when asked, without the Meet code unless that is asked too")
        let none = object(try? Document.json(meeting(), includesMeetCode: false, includesNotes: false, includesSummary: true,
                                             summary: "  \n"))
        suite.expect(none["summary"] == nil && none["markers"] == nil,
                     "no summary and no markers: neither key leaves")
        let config = ForkMeetingExporterList.decode(#"[{"kind":"dropFolder","id":"a","folder":"/x"}]"#).first
        suite.expect(config?.includesSummary == false, "an exporter sends no summary until asked")
        let saved = ForkMeetingExporterList.decode(ForkMeetingExporterList.encode([ForkMeetingExporterConfig(
            id: "b", kind: .webhook, includesSummary: true)])).first
        suite.expect(saved?.includesSummary == true, "the option is kept with the exporter")
    }

    private static func libraryShowsThem(_ suite: TestSuite) {
        var sidecar = meeting()
        sidecar.markers = [.init(at: 70), .init(at: 12)]
        sidecar.summary = ForkMeetingSummaryRecord(state: .done, files: ["Point summary.md"]).json
        let contents = ForkMeetingFolder.contents(of: ["meeting.json", "Point.mp4"], folderName: "Point")
        let entry = ForkMeetingLibraryEntry(folderName: "Point", sidecar: .success(sidecar), contents: contents)
        suite.expect(entry?.markers == [12, 70] && entry?.summaryRecord?.files == ["Point summary.md"],
                     "the library knows a meeting's markers and its summary")
    }

    private static func texts(_ suite: TestSuite) {
        var tooLong: [String] = []
        var unformatted: [String] = []
        for language in AppLanguage.allCases {
            let s = ForkMeetingStrings.strings(language)
            for short in [s.pillMark, s.noticeMarked, s.noticeSummaryReady, s.noticeSummaryFailed,
                          ForkMeetingNotice.marked.title(s)] where short.count > 28 {
                tooLong.append("\(language.rawValue): \(short)")
            }
            if !s.voiceMarked("00:12:03").contains("00:12:03") || !s.markerLabel("00:12:03").contains("00:12:03")
                || !s.summaryProgress("42 %").contains("42 %") {
                unformatted.append(language.rawValue)
            }
        }
        suite.expect(tooLong.isEmpty, "the marker's and the summary's short texts fit in 28 characters: \(tooLong)")
        suite.expect(unformatted.isEmpty, "every language says the time marked and the share done: \(unformatted)")
        let headings = ForkMeetingStrings.strings(.enUS).summaryHeadings
        suite.expect(Set([headings.points, headings.decisions, headings.actions]).count == 3,
                     "the summary's three sections have three names")
    }
}
