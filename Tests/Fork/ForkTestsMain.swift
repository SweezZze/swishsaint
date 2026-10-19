// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

// The fork's own runner (fork/test.sh), same contract as the official one:
// every suite by default, `--suite=<name>` to pick, `--list` to list.
@main
struct ForkTests {
    static func main() {
        let suite = TestSuite()
        let groups: [(String, () -> Void)] = [
            ("fork-defaults", { ForkDefaultsTests.run(suite) }),
            ("window-trackpad", { ForkTrackpadGestureTests.run(suite) }),
            ("fork-update", { ForkUpdateTests.run(suite) }),
            ("fork-update-notes", { ForkUpdateNotesTests.run(suite) }),
            ("fork-dictation", { ForkDictationTests.run(suite) }),
            ("fork-dictation-machine", { ForkDictationMachineTests.run(suite) }),
            ("fork-dictation-replacements", { ForkDictationReplacementsTests.run(suite) }),
            ("fork-dictation-shortcuts", { ForkDictationShortcutTests.run(suite) }),
            ("fork-dictation-parakeet-offer", { ForkDictationParakeetOfferTests.run(suite) }),
            ("fork-dictation-history", { ForkDictationHistoryTests.run(suite) }),
            ("fork-dictation-history-search", { ForkDictationHistorySearchTests.run(suite) }),
            ("fork-notch-dictations", { ForkNotchDictationsTests.run(suite) }),
            ("fork-parakeet", { ForkParakeetTests.run(suite) }),
            ("fork-parakeet-store", { ForkParakeetStoreTests.run(suite) }),
            ("fork-parakeet-long", { ForkParakeetLongTests.run(suite) }),
            ("fork-meetings-machine", { ForkMeetingMachineTests.run(suite) }),
            ("fork-meetings-quality", { ForkMeetingQualityTests.run(suite) }),
            ("fork-meetings-folder", { ForkMeetingFolderTests.run(suite) }),
            ("fork-meetings-sidecar", { ForkMeetingSidecarTests.run(suite) }),
            ("fork-meetings-recovery", { ForkMeetingRecoveryTests.run(suite) }),
            ("fork-meetings-strings", { ForkMeetingStringsTests.run(suite) }),
            ("fork-meetings-settings", { ForkMeetingSettingsTests.run(suite) }),
            ("fork-meetings-live", { ForkMeetingLiveTests.run(suite) }),
            ("fork-meetings-capture", { ForkMeetingCaptureTests.run(suite) }),
            ("fork-meetings-finalize", { ForkMeetingFinalizeTests.run(suite) }),
            ("fork-meetings-store", { ForkMeetingStoreTests.run(suite) }),
            ("fork-meetings-behavior", { ForkMeetingBehaviorTests.run(suite) }),
            ("fork-meetings-service", { ForkMeetingServiceTests.run(suite) }),
            ("fork-meetings-fixes-g1", { ForkMeetingFixesG1Tests.run(suite) }),
            ("fork-meetings-titles", { ForkMeetingTitleRulesTests.run(suite) }),
            ("fork-meetings-resolver", { ForkMeetingResolverTests.run(suite) }),
            ("fork-meetings-detection", { ForkMeetingDetectionTests.run(suite) }),
            ("fork-meetings-detection-effects", { ForkMeetingDetectionEffectsTests.run(suite) }),
            ("fork-meetings-offer", { ForkMeetingOfferTests.run(suite) }),
            ("fork-meetings-detection-behavior", { ForkMeetingDetectionBehaviorTests.run(suite) }),
            ("fork-meetings-fixes-h1", { ForkMeetingFixesH1Tests.run(suite) }),
            ("fork-meetings-offer-h2", { ForkMeetingOfferH2Tests.run(suite) }),
            ("fork-meetings-apps", { ForkMeetingAppsTests.run(suite) }),
            ("fork-meetings-fixes-j", { ForkMeetingFixesJTests.run(suite) }),
            ("fork-meetings-fixes-k", { ForkMeetingFixesKTests.run(suite) }),
            ("fork-meetings-library", { ForkMeetingLibraryTests.run(suite) }),
            ("fork-meetings-library-effects", { ForkMeetingLibraryEffectsTests.run(suite) }),
            ("fork-meetings-fixes-m", { ForkMeetingFixesMTests.run(suite) }),
            ("fork-meetings-fixes-l", { ForkMeetingFixesLTests.run(suite) }),
            ("fork-meetings-transcript", { ForkMeetingTranscriptTests.run(suite) }),
            ("fork-meetings-fixes-o", { ForkMeetingFixesOTests.run(suite) }),
            ("fork-meetings-export", { ForkMeetingExportTests.run(suite) }),
            ("fork-meetings-fixes-n", { ForkMeetingFixesNTests.run(suite) }),
            ("fork-meetings-island", { ForkMeetingIslandTests.run(suite) }),
            ("fork-meetings-audio-only", { ForkMeetingAudioOnlyTests.run(suite) }),
            ("fork-meetings-finish-b", { ForkMeetingFinishBTests.run(suite) }),
            ("fork-meetings-finish-e", { ForkMeetingFinishETests.run(suite) }),
            ("fork-meetings-finish", { ForkMeetingFinishTests.run(suite) }),
            ("fork-immich", { ForkImmichTests.run(suite) }),
        ]
        var selected = Set<String>()
        var listOnly = false
        for argument in CommandLine.arguments.dropFirst() {
            if argument == "--list" {
                listOnly = true
                continue
            }
            guard argument.hasPrefix("--suite="),
                  groups.contains(where: { $0.0 == String(argument.dropFirst(8)) }) else {
                fputs("Unknown test selection: \(argument)\n", stderr)
                exit(2)
            }
            selected.insert(String(argument.dropFirst(8)))
        }
        if listOnly {
            groups.forEach { print($0.0) }
            exit(0)
        }
        for (name, body) in groups where selected.isEmpty || selected.contains(name) {
            suite.run(name, body)
        }
        suite.finish()
    }
}
