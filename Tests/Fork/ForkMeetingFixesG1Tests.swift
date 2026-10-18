// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The second round of fixes of the meetings' first part: each rule as
/// the person would notice it.
enum ForkMeetingFixesG1Tests {
    static func run(_ suite: TestSuite) {
        noAppToHear(suite)
    }

    /// The app's sound asked for and no app to hear: silence, said, never
    /// the whole Mac in its place.
    private static func noAppToHear(_ suite: TestSuite) {
        let own: Int32 = 100
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: nil, ownPID: own, filmsWindow: false,
                                                   tapAvailable: true) == .none,
                     "a display filmed with no window in front: no app to hear, the meeting track stays silent")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: 200, ownPID: own, filmsWindow: false,
                                                   tapAvailable: false) == .none,
                     "before macOS 14.4 a display's stream is the whole Mac: never written for the app's sound")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: own, ownPID: own, filmsWindow: true,
                                                   tapAvailable: true) == .none
                        && ForkMeetingSoundSource.choose(.app, appPID: own, ownPID: own, filmsWindow: true,
                                                         tapAvailable: false) == .none,
                     "a window of this app has no meeting to hear")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: 200, ownPID: own, filmsWindow: true,
                                                   tapAvailable: false) == .stream,
                     "before macOS 14.4 a window of another app is still heard through its own stream")
        suite.expect(ForkMeetingSoundSource.appTap(pid: 200).refused(filmsWindow: false) == .none
                        && ForkMeetingSoundSource.appTap(pid: 200).refused(filmsWindow: true) == .stream
                        && ForkMeetingSoundSource.macTap.refused(filmsWindow: false) == .stream,
                     "a tap the audio system refuses: the app's gives way to a window's stream only, the Mac's to the stream")
        suite.expect(ForkMeetingSoundSource.none.heard(filmsWindow: false) == .off && !ForkMeetingSoundSource.none.streamListens,
                     "meeting.json then says the track heard nothing, and the stream does not even listen")

        let appOnly = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false, appOnly: true)
        suite.expect(appOnly.streamWrites(filmsWindow: true) && !appOnly.streamWrites(filmsWindow: false),
                     "a stream standing for the app's sound writes while a window is filmed, never once ⧉ films the display")
        let whole = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false)
        suite.expect(whole.streamWrites(filmsWindow: false) && whole.streamWrites(filmsWindow: true),
                     "the whole Mac asked for: the stream writes whatever is filmed")

        let silent = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false)
        suite.expect(ForkMeetingTrackSound.of(setting: .app, sound: .none, arbiter: silent, filmsWindow: false) == .noApp
                        && ForkMeetingTrackSound.of(setting: .app, sound: .stream, arbiter: appOnly, filmsWindow: false) == .noApp
                        && ForkMeetingTrackSound.of(setting: .app, sound: .stream, arbiter: appOnly, filmsWindow: true) == .heard,
                     "the pill and the start's card say when the app's sound has no app to hear")
        suite.expect(ForkMeetingTrackSound.of(setting: .off, sound: .none, arbiter: silent, filmsWindow: false) == .heard
                        && ForkMeetingTrackSound.of(setting: .all, sound: .stream, arbiter: whole, filmsWindow: false) == .heard,
                     "nothing is said when the sound is off by choice, or the whole Mac is heard")
        let app = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        suite.expect(ForkMeetingTrackSound.of(setting: .app, sound: .appTap(pid: 200), arbiter: app, filmsWindow: false) == .heard,
                     "the app's tap hears its app, a display filmed or not")

        let strings = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(strings.allSatisfy { $0.soundNoApp.count <= 28 && !$0.soundNoAppDetail.isEmpty
                                            && $0.soundAppNoAppCaption.contains($0.soundAll) },
                     "the pill's line fits in 28 characters, and the page names the choice to make, in every language")
    }
}
