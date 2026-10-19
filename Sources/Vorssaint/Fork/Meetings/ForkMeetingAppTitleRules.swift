// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The titles of the meeting apps and of the other calls in a browser.
/// Exact words only: an article about Zoom, a channel called "#meeting" or
/// a page that names Whereby are not meetings. None of these titles says a
/// call is over; their meetings end with their window and their microphone.
extension ForkMeetingTitleRules {
    static func appVerdict(_ title: String, rules: ForkMeetingTitleRuleSet) -> ForkMeetingTitleVerdict {
        let normalized = cleaned(title).lowercased()
        guard !normalized.isEmpty else { return .none }
        switch rules {
        case .googleMeet: return googleMeet(title)
        case .zoomApp: return zoomMeetingTitles.contains(normalized) ? .meeting(code: nil, name: nil) : .none
        case .slackHuddle: return isHuddle(normalized) ? .meeting(code: nil, name: nil) : .none
        case .zoomWeb:
            return normalized == "zoom" || zoomMeetingTitles.contains(normalized) ? .meeting(code: nil, name: nil) : .none
        case .whereby: return normalized == "whereby" ? .meeting(code: nil, name: nil) : .none
        case .jitsiMeet: return jitsiMeet(cleaned(title), normalized: normalized)
        case .teamsWeb: return isTeamsWeb(normalized) ? .meeting(code: nil, name: nil) : .none
        }
    }

    /// Zoom's meeting and webinar windows, in every language Zoom 6.6.10
    /// translates them to (`LN_Meeting_Title_148329`, `LN_Webinar_Title_148329`
    /// in its `Localizable.strings`), lowercased; the English ones whatever
    /// the system's language. Its main window ("Zoom", "Zoom Workplace") is
    /// none of them.
    static let zoomMeetingTitles: Set<String> = [
        "zoom meeting", "zoom webinar", "zoom-webinar",
        "réunion zoom", "webinaire zoom",
        "reunión de zoom", "seminario web de zoom",
        "riunione zoom", "webinar zoom",
        "reunião zoom",
        "zoom-vergadering",
        "spotkanie zoom", "webinar w zoomie",
        "конференция zoom", "вебинар zoom",
        "zoom-möte",
        "zoom toplantısı", "zoom web semineri",
        "zoom ミーティング", "zoom ウェビナー",
        "zoom 회의", "zoom 웨비나",
        "cuộc họp zoom", "hội thảo trực tuyến zoom",
        "zoom会议", "zoom网络研讨会",
        "zoom會議", "zoom網路研討會",
    ]

    /// "Huddle", "Huddle: #design" or "Huddle – Acme" at the head of the
    /// title, as Slack titles a huddle's window. Slack writes a channel's
    /// name without its "#" ("huddle-notes (Channel) - Acme - Slack"), and a
    /// channel's name may hold a "-": only "|" and "–" part the title, and a
    /// channel called "huddle" or "huddle-notes" is no huddle.
    private static func isHuddle(_ normalized: String) -> Bool {
        let separators: Set<Character> = ["|", "\u{2013}"]
        guard let head = normalized.split(omittingEmptySubsequences: false, whereSeparator: separators.contains).first
        else { return false }
        let words = head.trimmingCharacters(in: .whitespaces)
        return words == "huddle" || words.hasPrefix("huddle:")
    }

    /// Teams on the web, only on a call: the address of one (a meeting's
    /// link), or "<page> | Microsoft Teams" whose page begins with a call's
    /// word ("Meeting with Alice", "Réunion", "Call with Bob", "Appel", "Meet
    /// now"), as Teams titles its call. Its chat, its calendar or its list of
    /// calls ("Chat | Microsoft Teams", "Calls | Microsoft Teams") are no call,
    /// even with the browser's microphone in use for another one.
    private static func isTeamsWeb(_ normalized: String) -> Bool {
        if teamsCallAddresses.contains(where: normalized.contains) { return true }
        let suffix = "| microsoft teams"
        guard normalized.hasSuffix(suffix) else { return false }
        let page = normalized.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        return teamsCallWords.contains { word in
            page == word || [" ", ":", "\u{FF1A}"].contains { page.hasPrefix(word + $0) }
        }
    }

    /// A Teams meeting's own link, which a tab may show as its title while
    /// it loads.
    private static let teamsCallAddresses = [
        "teams.microsoft.com/l/meetup-join", "teams.microsoft.com/meet/", "teams.live.com/meet/",
    ]

    /// The words a Teams call's page begins with, lowercased, a whole word
    /// ("Meetings" or "Calls", lists, are not "Meeting" or "Call"): English
    /// whatever the system's language, then the app's other languages.
    static let teamsCallWords: Set<String> = [
        "meeting", "call", "meet now",
        "réunion", "appel", "reunión", "llamada", "reunião", "chamada", "besprechung", "anruf", "riunione",
        "chiamata", "toplantı", "çağrı", "собрание", "звонок", "вызов", "нарада", "дзвінок", "виклик", "schôdza",
        "hovor", "会議", "通話", "회의", "통화", "会议", "通话", "會議",
    ]

    /// "Jitsi Meet" alone, or "<room> | Jitsi Meet" as its rooms are titled:
    /// the room is the meeting's name.
    private static func jitsiMeet(_ title: String, normalized: String) -> ForkMeetingTitleVerdict {
        if normalized == "jitsi meet" { return .meeting(code: nil, name: nil) }
        let suffix = " | jitsi meet"
        guard normalized.hasSuffix(suffix) else { return .none }
        let room = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        return room.isEmpty ? .none : .meeting(code: nil, name: room)
    }
}
