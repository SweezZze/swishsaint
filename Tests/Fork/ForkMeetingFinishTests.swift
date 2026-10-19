// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The finish's parts, made to agree: one way to mark a moment for every
/// entry, a meeting recorded without picture in the island, the page's
/// switches over the newer notices, and the updater waiting for a summary.
enum ForkMeetingFinishTests {
    static func run(_ suite: TestSuite) {
        markers(suite)
    }

    private static func markers(_ suite: TestSuite) {
        suite.expect(ForkMeetingIslandRules.markedHold >= ForkMeetingMarkers.mergeWindow,
                     "the card's \"Marked\" lasts as long as a second press would be the same moment")
        suite.expect(ForkMeetingMarkers.showsNotice(liveCardShown: false) && !ForkMeetingMarkers.showsNotice(liveCardShown: true),
                     "a marker's notice shows, except while the live card is up to say it itself")
        let strings = AppLanguage.allCases.map { ForkMeetingStrings.strings($0) }
        suite.expect(strings.allSatisfy { $0.voiceMarked("00:12:03").contains("00:12:03") },
                     "VoiceOver hears the time marked, in every language")
    }
}
