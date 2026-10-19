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
    /// browser's windows: elsewhere "Meet – …" means nothing.
    case googleMeet
}

/// `String → verdict`, pure. Conservative on purpose: a false positive
/// offers a meeting that does not exist and makes the detection look broken;
/// a missed title still leaves the microphone and the Record button.
///
/// The Google Meet rules come from an earlier recorder's matcher (a code
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

        // 1. A code, only in Meet's own titles: three, four and three letters
        // are everywhere else too ("all-time-low", "fix-auth-bug"). 2. "Meet –
        // <name>": a named meeting without its code in the tab, which the
        // resolver takes only with the browser's microphone in use. 3. "<name>
        // – Google Meet": the end tells a meeting from an article about it.
        let code = isMeetFormat(normalized) ? formatCode(in: normalized) : nil
        let named = afterMeetPrefix(title) ?? beforeGoogleMeetSuffix(title)
        guard code != nil || named != nil else { return .none }
        return .meeting(code: code, name: named.flatMap { meetingName($0, code: code) })
    }

    // MARK: Fixes H1

    /// A title as Google Meet writes it: "Meet – …", "Meet - …", "Meet: …",
    /// "… – Google Meet", or its code alone. Lowercased.
    private static func isMeetFormat(_ normalized: String) -> Bool {
        if normalized.hasSuffix("google meet") { return true }
        if let code = meetCode(in: normalized), code == normalized { return true }
        guard normalized.hasPrefix("meet") else { return false }
        let rest = normalized.dropFirst(4).drop(while: { $0 == " " })
        guard let separator = rest.first else { return false }
        return dashes.contains(separator) || separator == ":"
    }

    /// The first code of a Meet title that stands as a part of its own: at
    /// the start, or after a dash or a colon ("Meet – Point hebdo –
    /// abc-defg-hij"), never inside a sentence ("Meet – Bitcoin hits
    /// all-time-low").
    private static func formatCode(in normalized: String) -> String? {
        let characters = Array(normalized)
        for (start, code) in codes(in: characters) {
            var before = start - 1
            while before >= 0, characters[before] == " " { before -= 1 }
            if before < 0 || dashes.contains(characters[before]) || characters[before] == ":" { return code }
        }
        return nil
    }

    /// Every `abc-defg-hij` of the text, with where it starts.
    private static func codes(in characters: [Character]) -> [(start: Int, code: String)] {
        let groups = [3, 4, 3]
        let length = 12
        guard characters.count >= length else { return [] }
        func isLetter(_ c: Character) -> Bool { c >= "a" && c <= "z" }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var found: [(start: Int, code: String)] = []
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
            if matches { found.append((start, String(characters[start..<end]))) }
        }
        return found
    }

    /// The name a meeting is shown and saved with: no control or bidi
    /// character (a page could turn its text around), every run of spaces
    /// and line breaks one space, about 100 characters at most, cut at a
    /// word with "…".
    static func displayName(_ text: String) -> String {
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            if scalar.properties.generalCategory == .control || bidiControls.contains(scalar.value) { return nil }
            return scalar
        }))
        let name = kept.split(separator: " ").joined(separator: " ")
        guard name.count > nameLimit else { return name }
        let head = String(name.prefix(nameLimit))
        let word = head.lastIndex(of: " ").map { String(head[..<$0]) }
        let cut = word.flatMap { $0.count >= nameLimit - 20 ? $0 : nil } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    static let nameLimit = 100

    /// U+202A–202E (embeddings and overrides) and U+2066–2069 (isolates).
    private static let bidiControls: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                    0x2066, 0x2067, 0x2068, 0x2069]

    /// The first `abc-defg-hij` in the text, lowercased: three letters, four,
    /// three, between anything but letters and digits.
    static func meetCode(in text: String) -> String? {
        codes(in: Array(text.lowercased())).first?.code
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
    /// no-break one), curly apostrophes straight, accents composed, bidi
    /// controls gone (a page could hide "Meet" behind one): the case is
    /// kept, for the name.
    static func cleaned(_ title: String) -> String {
        let composed = title.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{2019}", with: "'")
        let visible = composed.unicodeScalars.contains(where: { bidiControls.contains($0.value) })
            ? String(String.UnicodeScalarView(composed.unicodeScalars.filter { !bidiControls.contains($0.value) }))
            : composed
        return visible.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
