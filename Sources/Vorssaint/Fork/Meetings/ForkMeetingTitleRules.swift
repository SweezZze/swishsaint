// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What a window title says about a meeting.
enum ForkMeetingTitleVerdict: Equatable {
    /// A meeting is on in this window: its code when the title shows one, its
    /// name when the title holds one.
    case meeting(code: String?, name: String?)
    /// The meeting page says the call is over ("You left the meeting"): the
    /// meeting ends now, without waiting.
    case exit
    /// Nothing to do with a meeting, or a page around one (home, waiting,
    /// a browser's own window).
    case none
}

/// The rules a provider's windows are read with. Each provider of the table
/// names its own; a new provider adds a case and its function.
enum ForkMeetingTitleRuleSet: Equatable {
    /// Google Meet in a browser or its web app. Only ever applied to a
    /// browser's windows: elsewhere "Meet – …" means nothing (bran's lesson).
    case googleMeet
}

/// `String → verdict`, pure. Conservative on purpose: a false positive
/// offers a meeting that does not exist and makes the detection look broken;
/// a missed title still leaves the microphone and the Record button.
///
/// The Google Meet rules come from bran's `MeetTitleMatcher` (a code
/// `abc-defg-hij`, "Meet – x", "x – Google Meet"), with what the S2 spike
/// read from a real Chrome added: the page titles around a meeting are
/// refused (home, "Untitled" while loading, Google Workspace's page, the
/// translate bubble and the share picker, which are windows of their own),
/// a title saying the call is over ends it, and Chrome's cut in the middle
/// ("…") is kept as it is, never read as a separator.
enum ForkMeetingTitleRules {
    static func verdict(_ title: String, rules: ForkMeetingTitleRuleSet) -> ForkMeetingTitleVerdict {
        switch rules {
        case .googleMeet: return googleMeet(title)
        }
    }

    /// The dashes Chrome, Safari and Meet use without distinction.
    private static let dashes: Set<Character> = ["-", "\u{2013}", "\u{2014}"]

    /// Titles that carry "Meet" with no meeting on: the home page, its
    /// variants, a tab still loading, and Chrome's own small windows (S2).
    /// Compared once normalized, every dash as "-".
    private static let refusedTitles: Set<String> = [
        "meet", "google meet", "meet - google meet", "google meet - accueil", "google meet - home",
        "sans titre", "untitled", "nouvel onglet", "new tab",
        "traduire cette page ?", "traduire cette page?", "translate this page?", "translate this page ?",
    ]

    /// The beginnings of Chrome's share picker ("Choisissez ce qui doit être
    /// partagé avec http://…"), and the bar it shows while sharing.
    private static let refusedPrefixes = ["choisissez ce qui doit être partagé avec", "choose what to share with"]
    private static let refusedFragments = ["| google workspace", "partage votre écran", "is sharing your screen"]

    /// What the meeting page says once the call is over. Only French and
    /// English were seen; the others end with the microphone, 20 s later.
    private static let exitFragments = [
        "vous avez quitté la réunion", "vous avez été retiré de la réunion", "la réunion est terminée",
        "you left the meeting", "you've left the meeting", "you have left the meeting",
        "you've been removed from the meeting", "the meeting has ended",
    ]

    static func googleMeet(_ rawTitle: String) -> ForkMeetingTitleVerdict {
        let title = cleaned(rawTitle)
        // Empty: Screen Recording is not allowed, every other app's title is
        // blank. Not a meeting.
        guard !title.isEmpty else { return .none }
        let normalized = title.lowercased()
        let dashed = String(normalized.map { dashes.contains($0) ? "-" : $0 })
        if refusedTitles.contains(dashed) || normalized.hasSuffix("google workspace")
            || refusedPrefixes.contains(where: normalized.hasPrefix)
            || refusedFragments.contains(where: normalized.contains) {
            return .none
        }
        if exitFragments.contains(where: normalized.contains) { return .exit }

        let code = meetCode(in: normalized)
        // 1. A code is proof enough. 2. "Meet – <name>": a named meeting
        // without its code in the tab. 3. "<name> – Google Meet": the end
        // tells a meeting from an article about Google Meet.
        let named = afterMeetPrefix(title) ?? beforeGoogleMeetSuffix(title)
        guard code != nil || named != nil else { return .none }
        return .meeting(code: code, name: named.flatMap { meetingName($0, code: code) })
    }

    /// The first `abc-defg-hij` in the text, lowercased: three letters, four,
    /// three, between anything but letters and digits.
    static func meetCode(in text: String) -> String? {
        let characters = Array(text.lowercased())
        let groups = [3, 4, 3]
        let length = 12
        guard characters.count >= length else { return nil }
        func isLetter(_ c: Character) -> Bool { c >= "a" && c <= "z" }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        for start in 0...(characters.count - length) {
            if start > 0, isWord(characters[start - 1]) { continue }
            let end = start + length
            if end < characters.count, isWord(characters[end]) { continue }
            var index = start
            var matches = true
            for (number, group) in groups.enumerated() {
                for _ in 0..<group where matches {
                    matches = isLetter(characters[index])
                    index += 1
                }
                if matches, number < groups.count - 1 {
                    matches = characters[index] == "-"
                    index += 1
                }
                if !matches { break }
            }
            if matches { return String(characters[start..<end]) }
        }
        return nil
    }

    /// The code of the first Google Meet link in a calendar event's address,
    /// notes or place (`https://meet.google.com/abc-defg-hij?authuser=0`),
    /// lowercased; `nil` without one. A code alone, outside a link, is not
    /// taken: notes are free text.
    static func meetCode(inLink text: String) -> String? {
        let lowered = text.lowercased()
        var searched = lowered.startIndex..<lowered.endIndex
        while let host = lowered.range(of: "meet.google.com/", range: searched) {
            let path = lowered[host.upperBound...].prefix { ($0 >= "a" && $0 <= "z") || $0 == "-" }
            if path.count == 12, let code = meetCode(in: String(path)) { return code }
            searched = host.upperBound..<lowered.endIndex
        }
        return nil
    }

    /// Trimmed, every run of spaces one plain space (Chrome may give a
    /// no-break one), curly apostrophes straight, accents composed: the
    /// case is kept, for the name.
    static func cleaned(_ title: String) -> String {
        let composed = title.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{2019}", with: "'")
        return composed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "Meet – Point hebdo" → "Point hebdo".
    private static func afterMeetPrefix(_ title: String) -> String? {
        guard title.prefix(4).lowercased() == "meet" else { return nil }
        let rest = title.dropFirst(4).drop(while: { $0 == " " })
        guard let separator = rest.first, dashes.contains(separator) else { return nil }
        let name = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "Point hebdo – Google Meet" → "Point hebdo".
    private static func beforeGoogleMeetSuffix(_ title: String) -> String? {
        guard title.suffix(11).lowercased() == "google meet" else { return nil }
        let head = title.dropLast(11).trimmingCharacters(in: .whitespaces)
        guard let separator = head.last, dashes.contains(separator) else { return nil }
        let name = head.dropLast().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The name without the code beside it; `nil` when only the code is left.
    private static func meetingName(_ text: String, code: String?) -> String? {
        var name = text
        if let code {
            for dash in dashes {
                for affix in [" \(dash) \(code)", "\(dash)\(code)"] where name.lowercased().hasSuffix(affix) {
                    name = String(name.dropLast(affix.count))
                }
                for affix in ["\(code) \(dash) ", "\(code)\(dash)"] where name.lowercased().hasPrefix(affix) {
                    name = String(name.dropFirst(affix.count))
                }
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.lowercased() == code || name.lowercased() == "google meet" { return nil }
        return name
    }
}
