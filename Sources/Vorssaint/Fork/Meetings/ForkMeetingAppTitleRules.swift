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
        case .teamsWeb: return normalized.contains("teams.microsoft.com") ? .meeting(code: nil, name: nil) : .none
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

    /// A part of the title, between Slack's separators, that starts with
    /// the word "huddle": "Huddle", "Huddle: #design". A channel's name
    /// keeps its "#" ("#huddle-notes"), and "#meeting" is no huddle.
    private static func isHuddle(_ normalized: String) -> Bool {
        let separators: Set<Character> = ["|", "-", "\u{2013}", "\u{2014}", "\u{00B7}"]
        return normalized.split(whereSeparator: { separators.contains($0) }).contains { part in
            let words = part.trimmingCharacters(in: .whitespaces)
            guard words.hasPrefix("huddle") else { return false }
            let rest = words.dropFirst("huddle".count)
            return rest.first.map { $0 == " " || $0 == ":" } ?? true
        }
    }

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
