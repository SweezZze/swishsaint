// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// One window as the window scanner read it (`CGWindowListCopyWindowInfo`,
/// every window of layer 0, on every Space, minimized ones included). The
/// scanner only reports windows of apps the provider table knows.
struct ForkMeetingWindowSignal: Equatable {
    /// The bundle of the app that owns the window: a browser, or a web
    /// app's own bundle (`com.google.Chrome.app.<id>`).
    var bundle: String
    var pid: Int32
    /// As macOS gives it: Chrome shows the active tab's title alone, cut in
    /// the middle with "…" past about 62 characters.
    var title: String
    /// Hidden, minimized or on another Space, a window keeps its title: a
    /// meeting is never asked to be in front.
    var onScreen: Bool
    var windowID: UInt32
}

/// One process with a microphone input running, as the microphone watcher
/// read it (CoreAudio's process objects, `IsRunningInput`).
struct ForkMeetingMicSignal: Equatable {
    /// The regular app the process belongs to (Chrome for its audio
    /// helper, Safari for WebKit's), `nil` for a system process that no app
    /// owns: FaceTime's calls run in `avconferenced`.
    var appBundle: String?
    var appPID: Int32?
    /// The process itself, and its bundle as CoreAudio reports it.
    var pid: Int32
    var processBundle: String?
    /// The input it records from (a CoreAudio device UID, the capture
    /// device's unique ID), for "Meeting microphone (auto)".
    var inputDevice: String?

    init(appBundle: String?, appPID: Int32? = nil, pid: Int32, processBundle: String? = nil,
         inputDevice: String? = nil) {
        self.appBundle = appBundle
        self.appPID = appPID
        self.pid = pid
        self.processBundle = processBundle
        self.inputDevice = inputDevice
    }
}

/// A calendar event around now that links to a meeting: it only names the
/// meeting, it never makes one.
struct ForkMeetingCalendarHint: Equatable {
    var title: String
    /// The Google Meet code found in its link, notes or place.
    var meetCode: String?
    var startsAt: Date
    var endsAt: Date
    /// The other meeting links found there (Zoom, Teams, Webex, Whereby,
    /// Jitsi Meet), by kind.
    var links: Set<ForkMeetingCalendarLink> = []
    /// A print of each of those links (`ForkMeetingCalendarLink.prints`),
    /// never the link: one event in two calendars holds the same.
    var linkPrints: Set<Int> = []
}

/// What the detection read at one moment. A source left `nil` was not read
/// this time: what it said last still holds (the windows are read every
/// 3 s, the microphones when CoreAudio wakes the watcher).
struct ForkMeetingReading: Equatable {
    var at: Date
    var windows: [ForkMeetingWindowSignal]?
    var microphones: [ForkMeetingMicSignal]?
    var calendar: [ForkMeetingCalendarHint]?
    /// Screen Recording went away: no title can be read any more, so a
    /// meeting in a browser can no longer be told apart and ends now.
    var titlesUnreadable: Bool

    init(at: Date, windows: [ForkMeetingWindowSignal]? = nil, microphones: [ForkMeetingMicSignal]? = nil,
         calendar: [ForkMeetingCalendarHint]? = nil, titlesUnreadable: Bool = false) {
        self.at = at
        self.windows = windows
        self.microphones = microphones
        self.calendar = calendar
        self.titlesUnreadable = titlesUnreadable
    }
}

/// Which meeting a candidate is: `meet:<code>`, else `meet:<pid>:<title>`
/// for a Google Meet without a code in its title; `<provider>:<pid>#<birth>`
/// for a meeting app, its second meeting `#2`. Two windows, two profiles or a
/// web app and a tab on the same Google Meet give the same identity, so one
/// meeting.
struct ForkMeetingIdentity: Hashable, CustomStringConvertible {
    let value: String

    init(_ value: String) { self.value = value }

    var description: String { value }
}

/// A meeting the detection believes in: born after its readings agreed, and
/// still alive. The machine offers it, starts it on its own ("Always") or
/// keeps it for later.
struct ForkMeetingCandidate: Equatable {
    let identity: ForkMeetingIdentity
    /// `ForkMeetingProvider.id`.
    let provider: String
    /// The provider's name, never translated ("Google Meet").
    let providerName: String
    /// Its short name, for "Always for Meet".
    let providerShortName: String
    /// The meeting's own name from its title ("Point hebdo"), `nil` when the
    /// title holds none.
    var titleName: String?
    var meetCode: String?
    /// The calendar event's title, when one links to this meeting.
    var calendarTitle: String?
    /// The app whose sound is recorded and whose microphone keeps the meeting
    /// alive: a web app's browser, not its own bundle.
    var appBundle: String
    /// The window's owner, or the app's process when only its microphone is
    /// seen.
    var pid: Int32
    /// The window to film, `nil` when none is known.
    var windowID: UInt32?
    var windowBundle: String?
    /// The sound the provider records by default (FaceTime's comes from a
    /// system process: the whole Mac).
    var defaultSound: ForkMeetingSystemAudio
    var policy: ForkMeetingPolicy
    /// Already offered, or set aside with "Not now": no new offer opens for
    /// it until it has been over for 10 minutes.
    var silenced: Bool
    let bornAt: Date
    /// What lets "Always" start it on its own (`ForkMeetingProvider.alwaysProof`);
    /// unknown, nothing does.
    var alwaysProof: ForkMeetingProvider.AlwaysProof = .none
    /// An app's meeting: since when its app has used the microphone without
    /// a break; `nil` while it does not, and for a meeting in a browser.
    var microphoneSince: Date? = nil

    /// An app without a meeting window of its own proves its call by its
    /// microphone open this long: testing it in the app's settings takes a
    /// few seconds.
    static let alwaysMicrophone: TimeInterval = 15

    /// Whether it shows who it is beyond a title any page may copy or a
    /// microphone test: Meet's code, an app's meeting window, an app's
    /// microphone open for 15 s. "Always" starts only such a meeting.
    func provesItself(at now: Date) -> Bool {
        switch alwaysProof {
        case .meetCode: return meetCode != nil
        case .meetingWindow: return windowID != nil
        case .longMicrophone: return microphoneSince.map { now.timeIntervalSince($0) >= Self.alwaysMicrophone } ?? false
        case .none: return false
        }
    }

    /// An app's call that may still prove itself: its microphone open for
    /// less than 15 s. "Always" waits for it rather than offer it; past
    /// that, or its microphone closed (a test), it is offered.
    func awaitsProof(at now: Date) -> Bool {
        switch alwaysProof {
        case .meetingWindow, .longMicrophone:
            return microphoneSince.map { now.timeIntervalSince($0) < Self.alwaysMicrophone } ?? false
        case .meetCode, .none:
            return false
        }
    }

    /// The name to show and to give the recording: the title's, else the
    /// calendar's, else "Google Meet · abc-defg-hij", else the provider's.
    /// Brand names and codes are never translated, nor the middle dot. A
    /// page or an event chooses its own text: it is cleaned here, once, for
    /// every place that shows or saves it (`ForkMeetingTitleRules.displayName`).
    var name: String {
        for text in [titleName, calendarTitle].compactMap({ $0 }) {
            let name = ForkMeetingTitleRules.displayName(text)
            if !name.isEmpty { return name }
        }
        if let meetCode { return providerName + " · " + meetCode }
        return providerName
    }
}
