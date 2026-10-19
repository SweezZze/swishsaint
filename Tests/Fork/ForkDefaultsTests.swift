// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

enum ForkDefaultsTests {
    static func run(_ suite: TestSuite) {
        keys(suite)
        backup(suite)
        legacy(suite)
        strings(suite)
    }

    private static func keys(_ suite: TestSuite) {
        suite.expect(ForkDefaults.registered.keys.allSatisfy { $0.hasPrefix("fork.") }
                        && ForkDefaultsKey.updatePostponedBuild.hasPrefix("fork.")
                        && [ForkDefaultsKey.meetingsFolder, ForkDefaultsKey.meetingsPillPositions,
                            ForkDefaultsKey.meetingsConsentAcknowledged,
                            ForkDefaultsKey.meetingsSystemAudioVerified].allSatisfy { $0.hasPrefix("fork.meetings.") },
                     "every fork setting lives under fork., where the official app never writes")
        suite.expect(Set(ForkDefaults.registered.keys).isDisjoint(with: Defaults.registeredDefaults.keys),
                     "no fork setting shadows an official one")
        // Settings added since the fork never had a pre-fork name.
        let addedSinceFork: Set<String> = [ForkDefaultsKey.cancelEnabled, ForkDefaultsKey.gridModifierKeys,
                                           ForkDefaultsKey.strongerModifierKeys, ForkDefaultsKey.previewAtPointer,
                                           ForkDefaultsKey.sizeCycleEnabled,
                                           ForkDefaultsKey.dictationEnabled, ForkDefaultsKey.dictationTrigger,
                                           ForkDefaultsKey.dictationLocale, ForkDefaultsKey.dictationSounds,
                                           ForkDefaultsKey.dictationVocabulary, ForkDefaultsKey.dictationReplacements,
                                           ForkDefaultsKey.dictationShortcuts, ForkDefaultsKey.dictationEngine,
                                           ForkDefaultsKey.dictationMicrophone, ForkDefaultsKey.dictationAddsToHistory,
                                           ForkDefaultsKey.dictationFeedback, ForkDefaultsKey.dictationStopsOnSilence,
                                           ForkDefaultsKey.dictationUnloadMinutes,
                                           ForkDefaultsKey.dictationKeepsHistory,
                                           ForkDefaultsKey.meetingsEnabled, ForkDefaultsKey.meetingsCaptureTarget,
                                           ForkDefaultsKey.meetingsSystemAudio, ForkDefaultsKey.meetingsMicrophone,
                                           ForkDefaultsKey.meetingsQuality, ForkDefaultsKey.meetingsExtractAudio,
                                           ForkDefaultsKey.meetingsConsentReminder, ForkDefaultsKey.meetingsAnnouncement,
                                           ForkDefaultsKey.meetingsShortcut, ForkDefaultsKey.meetingsApps,
                                           ForkDefaultsKey.meetingsAutoStop, ForkDefaultsKey.meetingsAutoStopSeconds,
                                           ForkDefaultsKey.meetingsCalendarNaming]
        suite.expect(Set(ForkDefaults.legacyKeys.values) == Set(ForkDefaults.registered.keys).subtracting(addedSinceFork)
                        && ForkDefaults.legacyKeys.count == ForkDefaults.registered.count - addedSinceFork.count,
                     "every setting of the pre-fork test builds has its new name, and only those")
    }

    private static func backup(_ suite: TestSuite) {
        suite.expect(!ForkDefaults.backupKeys.contains(ForkDefaultsKey.updatePostponedBuild),
                     "the postponed update stays on this Mac")
        suite.expect(!ForkDefaults.backupKeys.contains(ForkDefaultsKey.dictationParakeetOffered),
                     "the Parakeet offer already made stays on this Mac")
        suite.expect(!ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsFolder),
                     "the meetings folder stays on this Mac: its path means nothing on another one")
        suite.expect(!ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsPillPositions),
                     "where the meeting pill was dragged stays on this Mac, whose displays it describes")
        suite.expect(!ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsConsentAcknowledged),
                     "the first-use consent sheet already confirmed stays on this Mac")
        suite.expect(!ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsSystemAudioVerified)
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsSystemAudioVerified] == nil,
                     "whether this Mac allows system audio recording stays on this Mac, and is never registered")
        suite.expect(ForkDefaults.backupKeys.isSuperset(of: [ForkDefaultsKey.meetingsEnabled, ForkDefaultsKey.meetingsQuality,
                                                             ForkDefaultsKey.meetingsShortcut, ForkDefaultsKey.meetingsAnnouncement]),
                     "the meetings choices go into the backup")
        suite.expect(ForkDefaults.registered[ForkDefaultsKey.meetingsEnabled] as? Bool == false
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsCaptureTarget] as? String == "window"
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsSystemAudio] as? String == "app"
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsMicrophone] as? String == "meeting"
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsQuality] as? String == "standard"
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsExtractAudio] as? Bool == true
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsConsentReminder] as? Bool == true,
                     "meetings start off; once on, they film the window with the app's sound and its microphone, in standard quality")
        suite.expect(ForkDefaults.backupKeys.isSuperset(of: [ForkDefaultsKey.meetingsApps, ForkDefaultsKey.meetingsAutoStop,
                                                             ForkDefaultsKey.meetingsAutoStopSeconds])
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsApps] as? String == ForkMeetingPolicies.defaultJSON
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsAutoStop] as? Bool == true
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsAutoStopSeconds] as? Int == 15,
                     "what each meeting app does, and the stop 15 s after a meeting ends, go into the backup")
        suite.expect(ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsCalendarNaming)
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsCalendarNaming] as? Bool == false,
                     "naming meetings with the calendar starts off, and the choice goes into the backup")
        let key = SettingsBackupSupport.settingsKey
        let payload: [String: Any] = [
            SettingsBackupSupport.formatVersionKey: SettingsBackupSupport.formatVersion,
            key: [
                "launchAtLogin": true,
                ForkDefaultsKey.gesturesEnabled: true,
                ForkDefaultsKey.disabledGestures: "close",
                "windowTrackpadCenterSizeStep": 4,
                ForkDefaultsKey.swipeSensitivityStep: "fast",
                ForkDefaultsKey.previewEnabled: 1,
                "fork.unknown": true,
                ForkDefaultsKey.updatePostponedBuild: 12,
            ] as [String: Any],
        ]
        let found = ForkBackup.settings(inPayload: payload)
        suite.expect(found.count == 3
                        && found[ForkDefaultsKey.gesturesEnabled] as? Bool == true
                        && found[ForkDefaultsKey.disabledGestures] as? String == "close"
                        && found["windowTrackpadCenterSizeStep"] as? Int == 4,
                     "an imported backup restores fork settings and old names, nothing unknown or of the wrong type")
        let added = ForkBackup.adding([ForkDefaultsKey.gesturesEnabled: false], to: payload)
        let settings = added[key] as? [String: Any]
        suite.expect(settings?["launchAtLogin"] as? Bool == true
                        && settings?[ForkDefaultsKey.gesturesEnabled] as? Bool == false
                        && added[SettingsBackupSupport.formatVersionKey] as? Int == SettingsBackupSupport.formatVersion,
                     "the fork settings join the official ones in the same file, which keep their values")
        suite.expect(ForkBackup.settings(inPayload: [:]).isEmpty
                        && ForkBackup.adding([ForkDefaultsKey.gesturesEnabled: true], to: [:]).isEmpty,
                     "a file that is not a backup gives and takes nothing")

        let name = "vorss.tests.fork.backup"
        guard let defaults = UserDefaults(suiteName: name) else {
            suite.expect(false, "test defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: ForkDefaultsKey.linkedResizeEnabled)
        defaults.set(6, forKey: ForkDefaultsKey.titlebarBandStep)
        ForkBackup.apply([ForkDefaultsKey.gesturesEnabled: true], to: defaults)
        suite.expect(defaults.object(forKey: ForkDefaultsKey.linkedResizeEnabled) == nil
                        && defaults.object(forKey: ForkDefaultsKey.titlebarBandStep) == nil
                        && defaults.bool(forKey: ForkDefaultsKey.gesturesEnabled),
                     "an import replaces every fork setting, like the official import replaces its own")
        defaults.set(true, forKey: ForkDefaultsKey.previewEnabled)
        defaults.set(42, forKey: ForkDefaultsKey.updatePostponedBuild)
        let current = ForkBackup.currentSettings(defaults)
        suite.expect(current[ForkDefaultsKey.gesturesEnabled] as? Bool == true
                        && current[ForkDefaultsKey.previewEnabled] as? Bool == true
                        && current[ForkDefaultsKey.updatePostponedBuild] == nil,
                     "an export writes the fork settings, never the postponed update")
        defaults.removePersistentDomain(forName: name)

        let service = source("Sources/Vorssaint/Services/SettingsBackup.swift")
        suite.expect(service.contains("try data.write(to: url, options: .atomic)\n            ForkBackup.addForkSettings(toBackupAt: url) // FORK(backup)")
                        && service.contains("static func readSettings(at url: URL) -> [String: Any]? {\n        ForkBackup.rememberForkSettings(inBackupAt: url) // FORK(backup)")
                        && service.contains("ForkBackup.applyRememberedForkSettings() // FORK(backup)\n        FeatureRuntime.shared.relaunchApp()"),
                     "export adds the fork settings to the file, import reads and applies them before relaunching (seam backup)")
    }

    private static func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func legacy(_ suite: TestSuite) {
        let name = "vorss.tests.fork.defaults"
        guard let defaults = UserDefaults(suiteName: name) else {
            suite.expect(false, "test defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: "windowTrackpadGesturesEnabled")
        defaults.set(5, forKey: "windowTrackpadCenterSizeStep")
        defaults.set(1, forKey: ForkDefaultsKey.cancelDelayStep)
        ForkDefaults.register(defaults)
        suite.expect(defaults.bool(forKey: ForkDefaultsKey.gesturesEnabled)
                        && defaults.integer(forKey: ForkDefaultsKey.centerSizeStep) == 5
                        && defaults.object(forKey: "windowTrackpadGesturesEnabled") == nil
                        && defaults.object(forKey: "windowTrackpadCenterSizeStep") == nil
                        && defaults.integer(forKey: ForkDefaultsKey.cancelDelayStep) == 1
                        && defaults.integer(forKey: ForkDefaultsKey.swipeSensitivityStep)
                            == ForkTrackpadTuning.swipeSensitivity.defaultStep,
                     "old names move to the new ones and disappear; the rest keeps its value or default")
        defaults.removePersistentDomain(forName: name)
    }

    private static func strings(_ suite: TestSuite) {
        let extras = AppLanguage.allCases.map(ForkExtrasStrings.strings)
        let updates = AppLanguage.allCases.map(ForkUpdateStrings.strings)
        func filled(_ value: Any) -> Bool {
            Mirror(reflecting: value).children.allSatisfy { ($0.value as? String)?.isEmpty == false }
        }
        suite.expect(extras.allSatisfy(filled) && updates.allSatisfy(filled),
                     "every Extras and update text exists in every language")
        suite.expect(Set(AppLanguage.allCases.map { ForkExtrasStrings.strings($0).aboutBody }).count
                        >= AppLanguage.allCases.count - 1,
                     "the about text is translated (only the two Chinese scripts of Taiwan and Hong Kong may share one)")
        suite.expect(extras.allSatisfy { $0.aboutBody.contains("Vorssaint") },
                     "every language credits Vorssaint")
    }
}
