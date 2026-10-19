// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The Meetings page's finish: the notifications each switch silences, the
/// quality's figures, the folder's way back to the default, and the pause
/// and marker shortcuts.
enum ForkMeetingFinishBTests {
    static func run(_ suite: TestSuite) {
        notifications(suite)
        quality(suite)
        folder(suite)
        shortcuts(suite)
        settings(suite)
        texts(suite)
    }

    private static func notifications(_ suite: TestSuite) {
        let allOn: (ForkMeetingNotifyEvent) -> Bool = { _ in true }
        let allOff: (ForkMeetingNotifyEvent) -> Bool = { _ in false }
        let events: [ForkMeetingNotice] = [.started, .resumed, .saved, .recovered, .microphone("AirPods"),
                                           .microphoneSilent, .diskLow(minutesLeft: 12), .displayChanged, .sourceGone]
        suite.expect(events.allSatisfy { ForkMeetingNotifyEvent.shows($0, isOn: allOn) }
                        && events.allSatisfy { !ForkMeetingNotifyEvent.shows($0, isOn: allOff) },
                     "every event's notice shows by default, and each one can be silenced")
        suite.expect(ForkMeetingNotifyEvent.event(of: .started) == .start && ForkMeetingNotifyEvent.event(of: .resumed) == .start
                        && ForkMeetingNotifyEvent.event(of: .saved) == .saved
                        && ForkMeetingNotifyEvent.event(of: .recovered) == .saved
                        && ForkMeetingNotifyEvent.event(of: .diskLow(minutesLeft: 3)) == .warnings
                        && ForkMeetingNotifyEvent.event(of: .microphoneSilent) == .warnings,
                     "each notice belongs to its own switch")
        let neverSilenced: [ForkMeetingNotice] = ForkMeetingFailure.all.map { .failure($0) }
            + [.soundLost, .neverOffered("Meet"), .neverOfferedWebCalls, .alwaysChosen("Meet"), .discarded(.trashed),
               .announcementCopied, .askedAgain("Meet")]
        suite.expect(neverSilenced.allSatisfy { ForkMeetingNotifyEvent.shows($0, isOn: allOff) },
                     "a failure, the meeting's sound lost and the answer to a click are shown whatever the switches say")
        let onlyStartOff: (ForkMeetingNotifyEvent) -> Bool = { $0 != .start }
        suite.expect(!ForkMeetingNotifyEvent.shows(.started, isOn: onlyStartOff)
                        && ForkMeetingNotifyEvent.shows(.saved, isOn: onlyStartOff),
                     "turning one switch off silences that event alone")
        suite.expect(ForkMeetingNotifyEvent.showsStart(.started, remindsConsent: true, noAppSound: false, isOn: allOff)
                        && ForkMeetingNotifyEvent.showsStart(.started, remindsConsent: false, noAppSound: true, isOn: allOff)
                        && !ForkMeetingNotifyEvent.showsStart(.started, remindsConsent: false, noAppSound: false, isOn: allOff),
                     "the start's card still shows for the consent reminder or a missing app sound")
        suite.expect(Set(ForkMeetingNotifyEvent.allCases.map(\.key)).count == ForkMeetingNotifyEvent.allCases.count
                        && ForkMeetingNotifyEvent.allCases.allSatisfy {
                            $0.key.hasPrefix("fork.meetings.notify.") && ForkDefaults.registered[$0.key] as? Bool == true
                        },
                     "each switch has its own setting, on by default")
        let name = "vorss.tests.fork.meetings.finish-b"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suite.expect(ForkMeetingNotifyEvent.isOn(.saved, defaults: defaults),
                     "a switch never written is on")
        defaults.set(false, forKey: ForkMeetingNotifyEvent.saved.key)
        suite.expect(!ForkMeetingNotifyEvent.isOn(.saved, defaults: defaults) && ForkMeetingNotifyEvent.isOn(.offers, defaults: defaults),
                     "a switch turned off reads off, the others stay on")
        defaults.removePersistentDomain(forName: name)
    }

    private static func quality(_ suite: TestSuite) {
        let english = ForkMeetingStrings.strings(.enUS)
        let us = Locale(identifier: "en_US")
        suite.expect(ForkMeetingQuality.standard.specification(codec: "HEVC", strings: english, recorder: FeatureStrings.recorder(.enUS), locale: us)
                        == "1080p · 30 fps · HEVC · 1.2 Mbit/s · ~0.6 GB/h",
                     "Balanced reads 1080p, 30 fps, HEVC, 1.2 Mbit/s and its size per hour")
        suite.expect(ForkMeetingQuality.light.specification(codec: "H.264", strings: english, recorder: FeatureStrings.recorder(.enUS), locale: us)
                        .hasPrefix("720p · 30 fps · H.264 · 0.6 Mbit/s"),
                     "Light reads 720p and the codec this Mac takes")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingQuality.high.specification(codec: "HEVC", strings: french, recorder: FeatureStrings.recorder(.fr), locale: Locale(identifier: "fr"))
                        == "1080p · 30 i/s · HEVC · 2,5 Mbit/s · ~1,2 Go/h",
                     "in French the frame rate is in i/s, the decimals take a comma")
        for preset in ForkMeetingQuality.allCases {
            let text = preset.specification(codec: "HEVC", strings: english, recorder: FeatureStrings.recorder(.enUS), locale: us)
            let megabits = String(format: "%.1f", Double(preset.videoBitRate) / 1_000_000)
            suite.expect(text.contains("\(preset.maximumLines)p") && text.contains("\(ForkMeetingQuality.Rates.frameRate) ")
                            && text.contains(megabits),
                         "the \(preset.rawValue) figures come from the writer's rates, not from a text")
        }
        suite.expect(AppLanguage.allCases.allSatisfy { language in
                        let text = ForkMeetingQuality.standard.specification(codec: "HEVC", strings: .strings(language),
                                                                             recorder: FeatureStrings.recorder(language),
                                                                             locale: Locale(identifier: language.rawValue))
                        return text.contains("1080") && text.contains("30") && text.contains("HEVC")
                     },
                     "every language says the lines, the frame rate and the codec")
    }

    private static func folder(_ suite: TestSuite) {
        let movies = URL(fileURLWithPath: "/Users/alice/Movies", isDirectory: true)
        let names = AppLanguage.allCases.map { ForkMeetingStrings.strings($0).folderName }
        suite.expect(ForkMeetingFolder.isDefault(stored: "", movies: movies, names: names)
                        && ForkMeetingFolder.isDefault(stored: "  ", movies: movies, names: names),
                     "no folder chosen is the default one")
        suite.expect(ForkMeetingFolder.isDefault(stored: "/Users/alice/Movies/Réunions", movies: movies, names: names)
                        && ForkMeetingFolder.isDefault(stored: "/Users/alice/Movies/Meetings/", movies: movies, names: names),
                     "the folder in Movies the first recording saved, in any language, has no way back: it is the default")
        suite.expect(!ForkMeetingFolder.isDefault(stored: "/Volumes/NAS/Calls", movies: movies, names: names)
                        && !ForkMeetingFolder.isDefault(stored: "/Users/alice/Documents/Meetings", movies: movies, names: names),
                     "a folder the person chose gets the ✕ back to the default")
    }

    private static func shortcuts(_ suite: TestSuite) {
        suite.expect(ForkMeetingShortcutRole.toggle.key == ForkDefaultsKey.meetingsShortcut
                        && ForkMeetingShortcutRole.pause.key == "fork.meetings.pauseShortcut"
                        && ForkMeetingShortcutRole.marker.key == "fork.meetings.markerShortcut",
                     "the start's shortcut keeps its setting, pause and marker have their own")
        suite.expect(ForkMeetingShortcutRole.toggle.isInstalled(featureOn: true, recording: false)
                        && !ForkMeetingShortcutRole.pause.isInstalled(featureOn: true, recording: false)
                        && !ForkMeetingShortcutRole.marker.isInstalled(featureOn: true, recording: false)
                        && ForkMeetingShortcutRole.pause.isInstalled(featureOn: true, recording: true)
                        && ForkMeetingShortcutRole.marker.isInstalled(featureOn: true, recording: true)
                        && !ForkMeetingShortcutRole.allCases.contains { $0.isInstalled(featureOn: false, recording: true) },
                     "pausing and marking take their combinations only while a meeting records, nothing with the feature off")
        let name = "vorss.tests.fork.meetings.finish-b.shortcuts"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let pause = GlobalShortcut(keyCode: 35, modifiers: [.control, .option, .command])
        ForkMeetingShortcut.save(pause, defaults, role: .pause)
        suite.expect(ForkMeetingShortcut.load(defaults, role: .pause) == pause && ForkMeetingShortcut.load(defaults) == nil
                        && defaults.string(forKey: ForkDefaultsKey.meetingsPauseShortcut) == pause.storageValue,
                     "the pause's shortcut is saved under its own key, the start's is untouched")
        suite.expect(ForkMeetingShortcut.usedByMeetings(pause, besides: .marker, defaults: defaults)
                        && ForkMeetingShortcut.usedByMeetings(pause, besides: .toggle, defaults: defaults)
                        && !ForkMeetingShortcut.usedByMeetings(pause, besides: .pause, defaults: defaults),
                     "a combination another meetings shortcut already has is taken, never its own")
        defaults.removePersistentDomain(forName: name)
    }

    private static func settings(_ suite: TestSuite) {
        suite.expect(ForkDefaults.registered[ForkDefaultsKey.meetingsSounds] as? Bool == false
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsPauseShortcut] as? String == ""
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsMarkerShortcut] as? String == "",
                     "the sounds start off, the pause and marker shortcuts empty")
        suite.expect(ForkDefaults.backupKeys.isSuperset(of: [ForkDefaultsKey.meetingsSounds, ForkDefaultsKey.meetingsPauseShortcut,
                                                             ForkDefaultsKey.meetingsMarkerShortcut, ForkDefaultsKey.meetingsNotifyOffers,
                                                             ForkDefaultsKey.meetingsNotifyStart, ForkDefaultsKey.meetingsNotifySaved,
                                                             ForkDefaultsKey.meetingsNotifyWarnings,
                                                             ForkDefaultsKey.meetingsNotifyResults]),
                     "the notifications, the sounds and the new shortcuts are the person's choices: they go into the backup")
        let clock = ForkMeetingClock(recordedBefore: 30, runningSince: Date(timeIntervalSince1970: 100))
        suite.expect(ForkMeetingServiceSupport.clock(of: .recording(clock, diskMinutesLeft: nil)) == clock
                        && ForkMeetingServiceSupport.clock(of: .paused(clock, .user, diskMinutesLeft: 4)) == clock
                        && ForkMeetingServiceSupport.clock(of: .finalizing) == nil
                        && ForkMeetingServiceSupport.clock(of: .hidden) == nil,
                     "the page counts with the pill's time while recording or paused, and none once stopped")
    }

    private static func texts(_ suite: TestSuite) {
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { strings in
                        Set([strings.barStart, strings.barStop, strings.barPause, strings.barResume, strings.barMarker,
                             strings.openLibrary]).count == 6
                     },
                     "the Command Bar's rows have six distinct names in every language")
        suite.expect(all.allSatisfy { strings in
                        Set([strings.notifyOffers, strings.notifyStart, strings.notifySaved, strings.notifyWarnings,
                             strings.notifyResults]).count == 5
                     },
                     "each notification switch has its own name in every language")
        suite.expect(all.allSatisfy { strings in
                        strings.qualitySpecFormat.components(separatedBy: "%").count == 6
                     },
                     "every language's quality line takes the five figures")
    }
}
