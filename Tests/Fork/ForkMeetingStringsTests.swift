// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingStringsTests {
    static func run(_ suite: TestSuite) {
        coverage(suite)
        shortTexts(suite)
        formats(suite)
        failures(suite)
        liveTexts(suite)
        typography(suite)
    }

    private static let languages = AppLanguage.allCases
    private static let allStrings = languages.map(ForkMeetingStrings.strings)

    private static func fields(_ strings: ForkMeetingStrings) -> [(String, String)] {
        Mirror(reflecting: strings).children.compactMap { child in
            guard let label = child.label, let value = child.value as? String else { return nil }
            return (label, value)
        }
    }

    private static func coverage(_ suite: TestSuite) {
        suite.expect(languages.count == 15, "the meetings speak the app's fifteen languages")
        suite.expect(allStrings.allSatisfy { strings in fields(strings).allSatisfy { !$0.1.isEmpty } },
                     "every meetings text exists in every language")
        let english = Dictionary(uniqueKeysWithValues: fields(.enUS))
        var untranslated: [String] = []
        for language in languages where language != .enUS {
            for (label, value) in fields(.strings(language)) where value == english[label] {
                untranslated.append("\(language.rawValue).\(label)")
            }
        }
        suite.expect(untranslated.isEmpty, "every text is really translated, none left in English: \(untranslated)")
        let distinct = Set(allStrings.map(\.failFolderRemedy)).count
        suite.expect(distinct >= languages.count - 1,
                     "each language has its own sentences (only Taiwan's and Hong Kong's Chinese may share one)")
        suite.expect(Set(fields(.zhTW).map(\.0)) == Set(english.keys), "every language fills the same fields")
    }

    /// The island, the pill and the bubble show 28 characters at most,
    /// written for that room, never cut.
    private static func shortTexts(_ suite: TestSuite) {
        let notices: [ForkMeetingNotice] = [.started, .resumed, .saved, .recovered, .microphone("AirPods"),
                                            .microphoneSilent, .diskLow(minutesLeft: 25), .displayChanged, .sourceGone]
            + ForkMeetingFailure.all.map { .failure($0) }
        var tooLong: [String] = []
        for (language, strings) in zip(languages, allStrings) {
            for notice in notices {
                let title = notice.title(strings)
                if title.count > 28 { tooLong.append("\(language.rawValue): \(title)") }
                if case .diskLow = notice, let detail = notice.detail(strings), detail.count > 28 {
                    tooLong.append("\(language.rawValue): \(detail)")
                }
            }
            for failure in ForkMeetingFailure.all where failure.summary(strings).count > 28 {
                tooLong.append("\(language.rawValue): \(failure.summary(strings))")
            }
            for name in [strings.folderName, strings.untitledMeeting] where name.count > 28 {
                tooLong.append("\(language.rawValue): \(name)")
            }
        }
        suite.expect(tooLong.isEmpty, "every notice, failure summary and default name fits in 28 characters: \(tooLong)")
        suite.expect(allStrings.allSatisfy { $0.failDiskAtStart(gigabytes: 10).count <= 28 && $0.diskMinutes(999).count <= 28 },
                     "the numbered summaries still fit with larger numbers")
    }

    private static func formats(_ suite: TestSuite) {
        suite.expect(allStrings.allSatisfy { $0.diskMinutes(25).contains("25") && $0.voiceDiskLow(25).contains("25") },
                     "every language says how many minutes of disk are left")
        suite.expect(allStrings.allSatisfy { $0.failDiskAtStart(gigabytes: 2).contains("2") },
                     "every language says how much room a meeting needs")
        suite.expect(allStrings.allSatisfy { $0.voiceMicrophone("AirPods de Martial").contains("AirPods de Martial") },
                     "every language names the new microphone")
        let announcements: [ForkMeetingAnnouncement] = [.started, .paused, .resumed, .stopped, .microphone("X"),
                                                        .microphoneSilent, .diskLow(minutesLeft: 5), .displayChanged,
                                                        .sourceGone, .failure(.diskFull)]
        suite.expect(allStrings.allSatisfy { strings in
                        let texts = announcements.map { $0.text(strings) }
                        return Set(texts).count == texts.count && texts.allSatisfy { !$0.isEmpty }
                     },
                     "VoiceOver has its own sentence for each step, in every language")
        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(ForkMeetingAnnouncement.failure(.diskFull).text(english)
                        == english.failDiskFull + ". " + english.failDiskFullRemedy,
                     "a failure is announced with what to do about it")
        suite.expect(ForkMeetingNotice.microphone("AirPods").detail(english) == "AirPods"
                        && ForkMeetingNotice.diskLow(minutesLeft: 12).detail(english) == english.diskMinutes(12)
                        && ForkMeetingNotice.started.detail(english) == nil,
                     "a new microphone is named under its notice, the minutes of disk under theirs")
        suite.expect(ForkMeetingStrings.strings(.fr).folderName == "Réunions"
                        && ForkMeetingStrings.strings(.enUS).folderName == "Meetings",
                     "the default folder is Réunions in French and Meetings in English")
    }

    private static func failures(_ suite: TestSuite) {
        for strings in allStrings {
            let summaries = ForkMeetingFailure.all.map { $0.summary(strings) }
            let remedies = ForkMeetingFailure.all.map { $0.remedy(strings) }
            suite.expect(Set(summaries).count == summaries.count && Set(remedies).count == remedies.count
                            && remedies.allSatisfy { $0.count > 20 },
                         "every failure explains itself, in every language, each in its own words")
        }
        suite.expect(ForkMeetingFailure.screenRecordingDenied.action == .openScreenRecordingPrivacy
                        && ForkMeetingFailure.systemAudioUnavailable.action == .openScreenRecordingPrivacy
                        && ForkMeetingFailure.microphoneDenied.action == .openMicrophonePrivacy
                        && ForkMeetingFailure.diskFullAtStart(requiredBytes: 1).action == .openStorageSettings
                        && ForkMeetingFailure.diskFull.action == .openStorageSettings
                        && ForkMeetingFailure.folderUnavailable.action == .openMeetingsPage
                        && ForkMeetingFailure.finalPassFailed.action == .openMeetingsFolder
                        && ForkMeetingFailure.officialRecorderBusy.action == nil,
                     "each failure offers the button that fixes it")
        let lasting = ForkMeetingFailure.all.filter(\.isLasting)
        suite.expect(lasting == [.screenRecordingDenied, .screenRecordingRevoked, .microphoneDenied, .systemAudioUnavailable,
                                 .folderUnavailable, .localBuild],
                     "only causes that stay until the person acts get a banner on the page")
        suite.expect(ForkMeetingFailure.gigabytes(2_000_000_000) == 2 && ForkMeetingFailure.gigabytes(2_000_000_001) == 3
                        && ForkMeetingFailure.gigabytes(0) == 0,
                     "the room asked for is rounded up to the gigabyte, never under what is needed")
        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(ForkMeetingFailure.diskFullAtStart(requiredBytes: 2_000_000_000).summary(english) == "2 GB of free space needed",
                     "the start refused for room says how much is needed")
        let keepsFile: [ForkMeetingFailure] = [.screenRecordingRevoked, .diskFull, .streamStopped, .writerFailed, .finalPassFailed]
        suite.expect(keepsFile.allSatisfy { failure in
                        allStrings.allSatisfy { strings in
                            let remedy = failure.remedy(strings)
                            return !remedy.isEmpty && remedy != failure.summary(strings)
                        }
                     } && ["kept", "readable"].allSatisfy { word in
                        keepsFile.contains { $0.remedy(english).contains(word) }
                     },
                     "a failure that ends a meeting says what happened to its file")
    }

    /// The official French puts a no-break space before « : ; ! ? » and
    /// inside the quotes, and typographic apostrophes everywhere.
    private static func typography(_ suite: TestSuite) {
        let french = fields(.fr).map(\.1) + [ForkUpdateStrings.strings(.fr).afterMeeting]
        let loose = french.filter { text in
            text.contains("'") || text.contains("« ")
                || [":", ";", "!", "?", "»"].contains { text.contains(" " + $0) }
        }
        suite.expect(loose.isEmpty, "French texts use no-break spaces and typographic apostrophes: \(loose)")
        let straight = allStrings.flatMap { fields($0).map(\.1) }.filter { $0.contains("'") }
        suite.expect(straight.isEmpty, "no meetings text uses a straight apostrophe: \(straight)")
    }

    /// Every text of the pill, the bubble and their buttons is short,
    /// written for that room in each language.
    private static func liveTexts(_ suite: TestSuite) {
        let live: [KeyPath<ForkMeetingStrings, String>] = [
            \.pillPaused, \.pillStopping, \.pillFinalizing, \.pillPictureFrozen, \.pillPause, \.pillResume,
            \.pillStop, \.pillFilmDisplay, \.pillFilmWindow, \.pillMicrophoneLevel, \.pillMeetingLevel,
            \.pillMicrophoneOff, \.pillElapsed, \.pillRecording, \.actionShow, \.actionOpenSettings,
            \.actionOpenStorage, \.actionOpenMeetings, \.bubbleClose,
        ]
        var tooLong: [String] = []
        for (language, strings) in zip(languages, allStrings) {
            for path in live where strings[keyPath: path].count > 28 {
                tooLong.append("\(language.rawValue): \(strings[keyPath: path])")
            }
        }
        suite.expect(tooLong.isEmpty, "every text of the pill and the bubble fits in 28 characters: \(tooLong)")
        suite.expect(allStrings.allSatisfy { Set([$0.trackMix, $0.trackMeeting, $0.trackMicrophone]).count == 3 },
                     "the final file's three audio tracks have three names in every language")
        suite.expect(ForkMeetingStrings.strings(.fr).trackMeeting == "Réunion" && ForkMeetingStrings.strings(.fr).trackMicrophone == "Micro",
                     "in French the sources are Réunion and Micro")
        suite.expect(allStrings.allSatisfy { $0.pillPause != $0.pillResume && $0.pillFilmDisplay != $0.pillFilmWindow
                                                && $0.pillMicrophoneLevel != $0.pillMeetingLevel },
                     "the buttons and meters VoiceOver reads are told apart in every language")
    }
}
