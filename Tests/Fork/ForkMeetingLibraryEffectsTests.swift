// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the library's store and window decide around the files: the
/// lengths kept between scans, what an audio export copies or mixes, the row
/// kept selected when the folder changes, and the words a row is read with.
enum ForkMeetingLibraryEffectsTests {
    static func run(_ suite: TestSuite) {
        cache(suite)
        audioExport(suite)
        selection(suite)
        words(suite)
        notes(suite)
        texts(suite)
    }

    private static let english = ForkMeetingStrings.strings(.enUS)
    private static let french = ForkMeetingStrings.strings(.fr)
    private static let languages = AppLanguage.allCases

    private static let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }()

    private static func date(_ hour: Int, _ minute: Int) -> Date {
        paris.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: hour, minute: minute))
            ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static let folder = "2026-10-18 10h02 — Weekly sync"

    private static func entry(state: ForkMeetingSidecar.State = .complete, video: Bool = true, audio: Bool = true,
                              master: Bool = false, live: Bool = false, provider: String? = "meet",
                              recovered: Bool = false, name: String = folder) -> ForkMeetingLibraryEntry? {
        var meeting = ForkMeetingSidecar.started(id: UUID(), startedAt: date(10, 2), origin: .offered, title: "Weekly sync",
                                                 titleSource: .window, capture: ForkMeetingSidecar.Capture(),
                                                 provider: provider, meetCode: "abc-defg-hij")
        meeting.state = state
        meeting.recordedSeconds = 3120
        meeting.recovered = recovered
        var names = [ForkMeetingFolder.sidecarName]
        if video { names.append("\(name).mp4") }
        if audio { names.append("\(name).m4a") }
        if master { names.append(ForkMeetingFolder.masterName) }
        return ForkMeetingLibraryEntry(folderName: name, sidecar: .success(meeting),
                                       contents: ForkMeetingFolder.contents(of: names, folderName: name), live: live,
                                       bytes: 410_000_000, calendar: paris)
    }

    // MARK: - Measures kept between scans

    private static func cache(_ suite: TestSuite) {
        var cache = ForkMeetingProbeCache()
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stamp = ForkMeetingProbeCache.Stamp(modified: when, size: 2_700_000)
        let probe = ForkMeetingProbeCache.Probe(seconds: 18.4, audioTracks: 3, hasMix: true)
        suite.expect(cache.probe(for: "/a.mp4", stamp: stamp) == nil, "a file never measured is measured")
        cache.remember(probe, for: "/a.mp4", stamp: stamp)
        suite.expect(cache.probe(for: "/a.mp4", stamp: stamp) == probe,
                     "a file unchanged since it was measured is not opened again")
        suite.expect(cache.probe(for: "/a.mp4", stamp: .init(modified: when.addingTimeInterval(1), size: 2_700_000)) == nil
                        && cache.probe(for: "/a.mp4", stamp: .init(modified: when, size: 2_700_001)) == nil,
                     "a file written again, even to the same size or at the same date, is measured again")
        cache.remember(probe, for: "/b.mp4", stamp: .init(modified: nil, size: 10))
        suite.expect(cache.probe(for: "/b.mp4", stamp: .init(modified: nil, size: 10)) == nil && cache.count == 1,
                     "a file whose date cannot be read is never trusted to be the same")
        cache.remember(probe, for: "/c.mp4", stamp: stamp)
        cache.keep(only: ["/c.mp4"])
        suite.expect(cache.count == 1 && cache.probe(for: "/a.mp4", stamp: stamp) == nil
                        && cache.probe(for: "/c.mp4", stamp: stamp) == probe,
                     "a meeting gone from the folder is forgotten, so the cache never outgrows the library")
    }

    // MARK: - Exporting the audio

    private static func audioExport(_ suite: TestSuite) {
        let mixed = ForkMeetingProbeCache.Probe(seconds: 3120, audioTracks: 3, hasMix: true)
        let separate = ForkMeetingProbeCache.Probe(seconds: 3120, audioTracks: 2, hasMix: false)
        if let complete = entry() {
            suite.expect(ForkMeetingAudioExport.route(complete, probe: mixed) == .success(.copy("\(folder).m4a")),
                         "the M4A the final pass made is copied as it is")
            suite.expect(ForkMeetingAudioExport.route(complete, probe: mixed, live: true) == .failure(.meetingInProgress),
                         "nothing is exported from a meeting being written")
            suite.expect(ForkMeetingAudioExport.suggestedName(complete) == "\(folder).m4a",
                         "the save panel suggests the meeting's own name")
        }
        if let noM4A = entry(audio: false) {
            suite.expect(ForkMeetingAudioExport.route(noM4A, probe: mixed) == .success(.extractMix("\(folder).mp4")),
                         "without an M4A, the final file's mix is copied out of it, not encoded again")
            suite.expect(ForkMeetingAudioExport.route(noM4A, probe: separate) == .success(.mixDown("\(folder).mp4"))
                            && ForkMeetingAudioExport.route(noM4A, probe: nil) == .success(.mixDown("\(folder).mp4")),
                         "a file that kept its two sources, or one not measured, has them mixed: one alone is half the meeting")
            suite.expect(ForkMeetingAudioExport.route(noM4A, probe: .init(seconds: 10, audioTracks: 0)) == .failure(.noAudio),
                         "a video without sound has no audio to export")
        }
        if let crashed = entry(state: .interrupted, video: false, audio: false, master: true) {
            suite.expect(ForkMeetingAudioExport.route(crashed, probe: mixed)
                            == .success(.mixDown(ForkMeetingFolder.masterName)),
                         "an interrupted meeting exports its master's two sources mixed")
        }
        if let recording = entry(state: .recording, video: false, audio: false, master: true, live: true) {
            suite.expect(ForkMeetingAudioExport.route(recording, probe: nil) == .failure(.meetingInProgress),
                         "the meeting being recorded exports nothing")
        }
        if let empty = entry(video: false, audio: false) {
            suite.expect(ForkMeetingAudioExport.route(empty, probe: nil) == .failure(.noAudio),
                         "a folder with neither video nor audio has nothing to export")
        }
    }

    // MARK: - Selection

    private static func selection(_ suite: TestSuite) {
        let before = ["c", "b", "a"]
        suite.expect(ForkMeetingLibrary.keptSelection("b", before: before, after: ["d", "c", "b", "a"]) == "b",
                     "a new meeting arriving keeps the one selected")
        suite.expect(ForkMeetingLibrary.keptSelection("b", renamed: ["b": "b2"], before: before, after: ["c", "b2", "a"]) == "b2",
                     "a renamed meeting stays selected under its new name")
        suite.expect(ForkMeetingLibrary.keptSelection("b", before: before, after: ["c", "a"]) == "a"
                        && ForkMeetingLibrary.keptSelection("a", before: before, after: ["c", "b"]) == "b",
                     "a meeting gone selects the one after it, else the one before")
        suite.expect(ForkMeetingLibrary.keptSelection("x", before: before, after: ["c"]) == "c"
                        && ForkMeetingLibrary.keptSelection("c", before: before, after: []) == nil
                        && ForkMeetingLibrary.keptSelection(nil, before: before, after: ["c"]) == nil,
                     "an unknown selection falls on the first row, an empty list selects nothing")
        suite.expect(ForkMeetingLibrary.neighbour(of: "b", in: before) == "a"
                        && ForkMeetingLibrary.neighbour(of: "a", in: before) == "b"
                        && ForkMeetingLibrary.neighbour(of: "c", in: ["c"]) == nil,
                     "a move to the Trash selects the next meeting, else the previous one")
        let now = date(18, 0)
        if let one = entry(name: "2026-10-18 10h02 — A"), let two = entry(name: "2026-10-18 10h02 — B") {
            let groups = ForkMeetingLibrary.groups([one, two], now: now, calendar: paris)
            suite.expect(ForkMeetingLibrary.order(groups) == ["2026-10-18 10h02 — B", "2026-10-18 10h02 — A"],
                         "the list's order is the groups' order, top to bottom")
        }
    }

    // MARK: - Words

    private static func words(_ suite: TestSuite) {
        let length = ForkMeetingLibraryText.duration(3120, language: .enUS) ?? ""
        suite.expect(length.contains("52") && !length.contains("s"), "52 minutes read as minutes")
        let long = ForkMeetingLibraryText.duration(3900, language: .fr) ?? ""
        suite.expect(long.contains("1") && long.contains("5") && long.contains("h"), "an hour and five minutes reads both")
        suite.expect((ForkMeetingLibraryText.duration(45, language: .enUS) ?? "").contains("45")
                        && ForkMeetingLibraryText.duration(0, language: .enUS) == nil
                        && ForkMeetingLibraryText.duration(nil, language: .enUS) == nil
                        && ForkMeetingLibraryText.duration(.nan, language: .enUS) == nil,
                     "under a minute in seconds; nothing for a length unknown")
        suite.expect(ForkMeetingLibraryText.time(date(10, 2), language: .fr, calendar: paris) == "10:02"
                        && ForkMeetingLibraryText.time(date(14, 5), language: .fr, calendar: paris) == "14:05",
                     "the time of day as French writes it")
        let american = ForkMeetingLibraryText.time(date(14, 5), language: .enUS, calendar: paris)
        // The clock follows the Mac's own 12 or 24 hours, whatever the language.
        suite.expect(american.contains("2:05") || american.contains("14:05"),
                     "the time of day in English, on the Mac's clock")
        suite.expect(ForkMeetingLibraryText.providerName("meet") == "Meet" && ForkMeetingLibraryText.providerName("zoom") == "Zoom"
                        && ForkMeetingLibraryText.providerName(nil) == nil
                        && ForkMeetingLibraryText.providerName("later-app") == nil,
                     "a row names its service by its short name, and none it does not know")
        let services = ["meet", "zoom", "teams", "slack", "facetime", "webex", "discord"]
        suite.expect(services.allSatisfy { ForkMeetingLibraryText.providerName($0) != nil }
                        && ForkMeetingLibraryText.providerName("facetime") == "FaceTime"
                        && ForkMeetingLibraryText.providerName("web") == nil,
                     "each of the seven services has its name; the other web calls, all written web, are not called by one of theirs")
        if let complete = entry(), let recovered = entry(recovered: true), let manual = entry(provider: nil) {
            let caption = ForkMeetingLibraryText.caption(complete, strings: english, language: .enUS)
            suite.expect(caption.hasPrefix("Meet · ") && caption.contains("410") && !caption.contains("Recovered"),
                         "under a row: its service and its size")
            suite.expect(ForkMeetingLibraryText.caption(recovered, strings: english, language: .enUS).hasSuffix("· Recovered")
                            && !ForkMeetingLibraryText.caption(manual, strings: english, language: .enUS).contains("Meet"),
                         "a flagged meeting adds its status; one recorded by hand names no service")
            let spoken = ForkMeetingLibraryText.accessibilityLabel(recovered, strings: french, language: .fr, calendar: paris)
            suite.expect(spoken.hasPrefix("Weekly sync, 10:02, ") && spoken.contains("Meet") && spoken.hasSuffix("Récupérée"),
                         "VoiceOver reads a row's title, time, length, service and status in one sentence")
        }
    }

    private static func notes(_ suite: TestSuite) {
        var plan = ForkMeetingRename.Plan()
        suite.expect(ForkMeetingLibraryText.renameNote(plan, strings: english) == nil, "a rename done as asked says nothing")
        plan.folderKept = .renamedByHand
        suite.expect(ForkMeetingLibraryText.renameNote(plan, strings: english) == english.renameFolderKept,
                     "a folder filed by hand keeps its name, and the detail says so")
        plan.folderKept = .namesExhausted
        suite.expect(ForkMeetingLibraryText.renameNote(plan, strings: english) == english.renameNamesExhausted,
                     "fifty folders of that name: the folder keeps its own, said")
        plan.folderKept = nil
        plan.media.blocked = ["x.mp4"]
        suite.expect(ForkMeetingLibraryText.renameNote(plan, strings: english) == english.renameMediaKept,
                     "a medium that could not follow is said")
        suite.expect(ForkMeetingLibraryText.refusal(.meetingInProgress, strings: english) == english.refusedWhileRecording
                        && ForkMeetingLibraryText.refusal(.sidecarUnreadable, strings: english) == english.renameUnreadable,
                     "a refused rename says why")
    }

    // MARK: - Texts

    private static func texts(_ suite: TestSuite) {
        let all = languages.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { $0.emptyWhere("~/Movies/X").contains("~/Movies/X") },
                     "an empty library says where its meetings will go, in every language")
        suite.expect(all.allSatisfy { $0.actionShowMeeting != $0.actionShow && $0.openLibrary != $0.actionOpenMeetings },
                     "Show opens the library, not the Finder; Open Meetings is not the page's settings")
        let trash: [AppLanguage: String] = [
            .enUS: "Trash", .ptBR: "Lixo", .tr: "Çöp Kutusu", .ru: "Корзин", .es: "papelera", .sk: "koš",
            .de: "Papierkorb", .fr: "Corbeille", .it: "Cestino", .ja: "ゴミ箱", .ko: "휴지통", .uk: "Смітник",
            .zhHans: "废纸篓", .zhTW: "垃圾桶", .zhHK: "垃圾桶",
        ]
        var missing: [String] = []
        for language in languages {
            let strings = ForkMeetingStrings.strings(language)
            for line in [strings.trashFailed, strings.voiceTrashed, strings.actionTrash, strings.confirmTrashMessage]
            where !line.contains(trash[language] ?? "?") {
                missing.append("\(language.rawValue): \(line)")
            }
        }
        suite.expect(trash.count == languages.count && missing.isEmpty,
                     "the library speaks of the Trash with macOS's word, in every language: \(missing)")
        suite.expect(french.actionTrash == "Mettre à la Corbeille" && french.openLibrary == "Ouvrir les réunions"
                        && french.actionShowMeeting == "Afficher",
                     "in French: Mettre à la Corbeille, Ouvrir les réunions, Afficher")
        suite.expect(all.allSatisfy { strings in
                        ForkMeetingLibrary.statusText(.interrupted(.stopped(.cancelled)), strings: strings).map { $0.count <= 28 } ?? false
                     },
                     "a cancelled recording's status fits beside its row")
    }
}
