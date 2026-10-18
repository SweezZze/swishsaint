// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingSettingsTests {
    static func run(_ suite: TestSuite) {
        shortcut(suite)
        shortcutProblems(suite)
        microphone(suite)
        announcement(suite)
        texts(suite)
    }

    private static let languages = AppLanguage.allCases

    private static func shortcut(_ suite: TestSuite) {
        let combination = GlobalShortcut(keyCode: 15, modifiers: [.control, .option, .command])
        suite.expect(ForkMeetingShortcut.decode(ForkMeetingShortcut.encode(combination)) == combination,
                     "a meeting shortcut reads back as it was saved")
        suite.expect(ForkMeetingShortcut.encode(combination) == combination.storageValue,
                     "the meeting shortcut is stored like the official shortcuts")
        suite.expect(ForkMeetingShortcut.decode("") == nil && ForkMeetingShortcut.decode("   ") == nil
                        && ForkMeetingShortcut.encode(nil).isEmpty,
                     "no shortcut by default, and none stored as empty")
        suite.expect(ForkMeetingShortcut.decode("banana") == nil && ForkMeetingShortcut.decode("hyper:15") == nil,
                     "an unreadable stored shortcut is no shortcut")
        suite.expect(ForkMeetingShortcut.decode(" control+option+command:15\n") == combination,
                     "spaces around a stored shortcut, as a hand-edited backup may carry, do not lose it")
        suite.expect(ForkMeetingShortcut.decode("control+option:53") == nil
                        && ForkMeetingShortcut.decode("command+shift:53") == nil,
                     "Escape is never accepted, whatever the modifiers")
        suite.expect(ForkMeetingShortcut.decode(":15") == nil,
                     "a letter alone, which would be typed, is never a shortcut")
        suite.expect(ForkMeetingShortcut.decode(":100") == GlobalShortcut(keyCode: 100, modifiers: []),
                     "a function key alone is accepted, like the official shortcuts allow")

        let name = "vorss.tests.fork.meetings.settings"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suite.expect(ForkMeetingShortcut.load(defaults) == nil, "nothing stored is no shortcut")
        ForkMeetingShortcut.save(combination, defaults)
        suite.expect(ForkMeetingShortcut.load(defaults) == combination
                        && defaults.string(forKey: ForkDefaultsKey.meetingsShortcut) == "control+option+command:15",
                     "the shortcut is saved under fork.meetings.shortcut")
        ForkMeetingShortcut.save(nil, defaults)
        suite.expect(ForkMeetingShortcut.load(defaults) == nil
                        && defaults.string(forKey: ForkDefaultsKey.meetingsShortcut) == "",
                     "removing the shortcut leaves an empty setting")
        defaults.removePersistentDomain(forName: name)
    }

    private static func shortcutProblems(_ suite: TestSuite) {
        let free: (GlobalShortcut) -> Bool = { _ in false }
        let combination = GlobalShortcut(keyCode: 15, modifiers: [.control, .option, .command])
        suite.expect(ForkMeetingShortcut.problem(of: combination, isTaken: free) == nil,
                     "a free combination with a modifier works")
        suite.expect(ForkMeetingShortcut.problem(of: combination, isTaken: { $0 == combination }) == .conflict,
                     "a combination something else answers to is refused")
        suite.expect(ForkMeetingShortcut.problem(of: GlobalShortcut(keyCode: 53, modifiers: [.command]), isTaken: free)
                        == .reservedKey,
                     "Escape is refused even with Command")
        suite.expect([36, 48, 49, 51].allSatisfy {
                        ForkMeetingShortcut.problem(of: GlobalShortcut(keyCode: $0, modifiers: []), isTaken: free) == .reservedKey
                     },
                     "Return, Tab, Space and Delete alone are refused")
        suite.expect(ForkMeetingShortcut.problem(of: GlobalShortcut(keyCode: 15, modifiers: [.shift]), isTaken: free)
                        == .needsModifier,
                     "Shift and a letter types a capital, so it is refused")

        let dictationCombo = ForkDictationShortcut(key: .combo(keyCode: 2, modifiers: GlobalShortcutModifiers([.control, .option]).rawValue))
        let dictationKey = ForkDictationShortcut(key: .modifier(.rightCommand))
        let taken = GlobalShortcut(keyCode: 2, modifiers: [.control, .option])
        suite.expect(ForkMeetingShortcut.usedByDictation(taken, enabled: true, shortcuts: [dictationKey, dictationCombo]),
                     "a combination dictation listens to is taken")
        suite.expect(!ForkMeetingShortcut.usedByDictation(taken, enabled: false, shortcuts: [dictationCombo]),
                     "switched off, dictation holds no combination")
        suite.expect(!ForkMeetingShortcut.usedByDictation(GlobalShortcut(keyCode: 2, modifiers: [.control]),
                                                          enabled: true, shortcuts: [dictationKey, dictationCombo]),
                     "only the exact combination counts, not its key with other modifiers")
    }

    private static func microphone(_ suite: TestSuite) {
        suite.expect(ForkMeetingMicrophoneChoice(stored: nil) == .meeting && ForkMeetingMicrophoneChoice(stored: "") == .meeting,
                     "the meeting's own microphone is the default")
        let all: [ForkMeetingMicrophoneChoice] = [.meeting, .system, .builtIn, .off, .device("AppleUSBAudioEngine:42")]
        suite.expect(all.allSatisfy { ForkMeetingMicrophoneChoice(stored: $0.storageValue) == $0 },
                     "every microphone choice reads back as it was saved")
        suite.expect(ForkMeetingMicrophoneChoice.builtIn.storageValue == "builtin"
                        && ForkMeetingMicrophoneChoice.system.storageValue == "system",
                     "the built-in and system microphones are stored with dictation's words")
        suite.expect(ForkMeetingMicrophoneChoice(stored: ForkDefaults.registered[ForkDefaultsKey.meetingsMicrophone] as? String)
                        == ForkMeetingMicrophoneChoice.fallback,
                     "the registered default is the meeting's microphone")

        let uid = "BuiltInHeadphones:7"
        let chosen = ForkMeetingMicrophoneChoice.device(uid)
        suite.expect(chosen.effective(available: [uid, "other"]) == chosen,
                     "a chosen microphone that is plugged in is the one recorded")
        suite.expect(chosen.effective(available: ["other"]) == .builtIn && chosen.effective(available: []) == .builtIn,
                     "a chosen microphone missing on this Mac falls back to the built-in one, as the recording opens it, never to none")
        suite.expect([ForkMeetingMicrophoneChoice.meeting, .system, .builtIn, .off].allSatisfy { $0.effective(available: []) == $0 },
                     "the other choices do not depend on what is plugged in, and none stays none")
    }

    private static func announcement(_ suite: TestSuite) {
        for language in languages {
            let strings = ForkMeetingStrings.strings(language)
            suite.expect(ForkMeetingAnnouncementText.text(stored: "", strings: strings) == strings.announcementDefault
                            && ForkMeetingAnnouncementText.text(stored: " \n ", strings: strings) == strings.announcementDefault,
                         "an empty announcement is the default one, in the person's language")
        }
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingAnnouncementText.text(stored: "  Enregistré pour Acme.\n", strings: french) == "Enregistré pour Acme.",
                     "the person's own announcement is copied as they wrote it")
        suite.expect(ForkMeetingAnnouncementText.stored(edited: french.announcementDefault, strings: french) == ""
                        && ForkMeetingAnnouncementText.stored(edited: "   ", strings: french) == "",
                     "the default text, or nothing, is stored as empty, so it keeps following the language")
        suite.expect(ForkMeetingAnnouncementText.stored(edited: " Mon texte ", strings: french) == "Mon texte",
                     "an edited announcement is stored trimmed")
        suite.expect(Set(languages.map { ForkMeetingStrings.strings($0).announcementDefault }).count >= languages.count - 1,
                     "the default announcement is written in each language")
        suite.expect(languages.allSatisfy { language in
                        let text = ForkMeetingStrings.strings(language).announcementDefault
                        return !text.contains("[") && !text.contains("%")
                     },
                     "the default announcement has no blank left to fill")
    }

    private static func texts(_ suite: TestSuite) {
        suite.expect(languages.allSatisfy { ForkExtrasStrings.strings($0).meetingsTitle == ForkMeetingStrings.strings($0).folderName },
                     "the feature is called by the same word as its default folder, in every language")
        let summaries = languages.map { ForkExtrasStrings.strings($0).meetingsSummary }
        suite.expect(Set(summaries).count >= languages.count - 1 && summaries.allSatisfy { $0.count > 30 },
                     "the Extras summary of meetings is written in each language")
        suite.expect(languages.allSatisfy { language in
                        let strings = ForkMeetingStrings.strings(language)
                        return strings.microphoneMissing("AirPods d’Alice").contains("AirPods d’Alice")
                            && strings.perHour("0,6").contains("0,6")
                     },
                     "every language names the unplugged microphone and the size per hour")
        suite.expect(languages.allSatisfy { language in
                        let strings = ForkMeetingStrings.strings(language)
                        let presets = [strings.qualityLight, strings.qualityStandard, strings.qualityHigh]
                        let pictures = [strings.pictureMeetingWindow, strings.pictureFrontDisplay]
                        let sounds = [strings.soundApp, strings.soundAll, strings.soundOff]
                        return Set(presets).count == 3 && Set(pictures).count == 2 && Set(sounds).count == 3
                     },
                     "the choices of a menu never read alike")
    }
}
