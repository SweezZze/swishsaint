// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the update window says: the notes the authors wrote for each build
/// skipped since the installed one, put together. Pure, so it is tested.
///
/// The contract with `fork/release-notes.sh`: each release body is markdown
/// for people, plus one machine line the window reads,
/// `<!-- swishsaint-meta v1 {"build":2170,"upstream":"3.4.2-beta.1",
/// "notes":[{"pr":31,"author":"Martial","items":["…"]}],"other":["…"]} -->`,
/// whose JSON never holds `<` or `>` (written `<`, `>`), so it can
/// never end the comment early. A release made before that line existed
/// still gives the bullets of its sections.
enum ForkUpdateNotes {
    static let metaPrefix = "<!-- swishsaint-meta v1 "

    struct Meta: Equatable, Decodable {
        struct Note: Equatable, Decodable {
            let pr: Int?
            let author: String
            let items: [String]

            init(pr: Int?, author: String, items: [String]) {
                self.pr = pr
                self.author = author
                self.items = items
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                pr = try? container.decodeIfPresent(Int.self, forKey: .pr)
                author = try container.decode(String.self, forKey: .author)
                items = (try? container.decodeIfPresent([String].self, forKey: .items)) ?? []
            }

            enum CodingKeys: String, CodingKey { case pr, author, items }
        }

        let build: Int?
        let upstream: String?
        let notes: [Note]
        let other: [String]

        init(build: Int?, upstream: String?, notes: [Note], other: [String]) {
            self.build = build
            self.upstream = upstream
            self.notes = notes
            self.other = other
        }

        /// Lenient on what is missing, so a later field or an empty list
        /// never costs the whole release its notes.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            build = try? container.decodeIfPresent(Int.self, forKey: .build)
            upstream = try? container.decodeIfPresent(String.self, forKey: .upstream)
            notes = (try? container.decodeIfPresent([Note].self, forKey: .notes)) ?? []
            other = (try? container.decodeIfPresent([String].self, forKey: .other)) ?? []
        }

        enum CodingKeys: String, CodingKey { case build, upstream, notes, other }
    }

    /// The window's content: everything the builds in (installed, build]
    /// bring. Saved when offered, so the window after the relaunch can say
    /// the same without asking GitHub again.
    struct Summary: Equatable, Codable {
        struct Author: Equatable, Codable {
            let name: String
            var items: [String]
        }

        /// The newest build, the one installed.
        let build: Int
        /// The official version it is based on, such as 3.4.2-beta.1.
        let upstream: String?
        /// The official version differs from the installed one.
        let upstreamChanged: Bool
        /// Authors in the order they first appear, oldest build first.
        let authors: [Author]
        let other: [String]
        /// How many published builds it gathers (1: just this one).
        let includedBuilds: Int

        var hasNotes: Bool { !authors.isEmpty || !other.isEmpty }

        /// A pre-release of the official app (beta, release candidate).
        var isPrerelease: Bool {
            guard let upstream = upstream?.lowercased() else { return false }
            return upstream.contains("-beta") || upstream.contains("-rc") || upstream.contains("-alpha")
        }
    }

    // MARK: - Reading one release

    /// The machine line of a release body, nil when it has none or it does
    /// not decode.
    static func meta(in body: String?) -> Meta? {
        guard let body, let start = body.range(of: metaPrefix) else { return nil }
        guard let end = body.range(of: "-->", range: start.upperBound..<body.endIndex) else { return nil }
        let json = body[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// The release body as a person may read it: no HTML comment (the
    /// machine line among them) and no checksum line.
    static func displayText(_ body: String?) -> String {
        guard var text = body else { return "" }
        while let open = text.range(of: "<!--") {
            let close = text.range(of: "-->", range: open.upperBound..<text.endIndex)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SHA256:") { continue }
            // One blank line at most between paragraphs.
            if trimmed.isEmpty, lines.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true {
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The official version a release names in its first line: the
    /// `Vorssaint officiel 3.4.2-beta.1` of today's notes, or the
    /// `base officielle Vorssaint 3.4.1` of the older ones.
    static func upstreamVersion(inHeader body: String?) -> String? {
        guard let body else { return nil }
        let header = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for marker in ["Vorssaint officiel ", "base officielle Vorssaint "] {
            guard let range = header.range(of: marker) else { continue }
            let version = header[range.upperBound...].prefix { !$0.isWhitespace && $0 != "(" }
            if let first = version.first, first.isNumber, version != "?" { return String(version) }
        }
        return nil
    }

    private static let conventionalTypes: Set<String> = [
        "feat", "fix", "docs", "chore", "refactor", "perf", "test", "build", "ci", "style", "revert", "sync",
    ]

    /// One line as the window shows it: no bullet, no conventional commit
    /// prefix (`feat(meetings): `), no PR number at the end, and a capital
    /// letter first. A sentence an author wrote is left as it is.
    static func cleanedItem(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["- ", "* ", "• "] where text.hasPrefix(bullet) {
            text = String(text.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
        }
        if let colon = text.range(of: ": ") {
            var kind = String(text[..<colon.lowerBound])
            if kind.hasSuffix("!") { kind.removeLast() }
            if let paren = kind.firstIndex(of: "("), kind.hasSuffix(")") { kind = String(kind[..<paren]) }
            if conventionalTypes.contains(kind) {
                text = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let first = text.first {
                    text = first.uppercased() + text.dropFirst()
                }
            }
        }
        if text.hasSuffix(")"), let open = text.range(of: " (#", options: .backwards),
           text[open.upperBound...].dropLast().allSatisfy(\.isNumber) {
            text = String(text[..<open.lowerBound])
        }
        return text
    }

    /// A release without the machine line: the bullets of its sections,
    /// except the official one's (a link to the official commits).
    static func fallbackItems(in body: String?) -> [String] {
        var items: [String] = []
        var inSection = false
        for line in displayText(body).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                inSection = !title.contains("officiel") && !title.contains("official")
                continue
            }
            guard inSection, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            let item = cleanedItem(trimmed)
            if !item.isEmpty { items.append(item) }
        }
        return items
    }

    // MARK: - Several releases

    /// The notes of every build in (installed, candidate], oldest first:
    /// each author's sentences under their name, in the order the authors
    /// first appear, each sentence once; then the other changes. An unknown
    /// installed build gathers the candidate alone.
    static func summary(releases: [ForkUpdateSupport.Release], installed: Int?, candidate: Int,
                        installedUpstream: String?) -> Summary {
        let included = releases
            .compactMap { release in ForkUpdateSupport.buildNumber(fromTag: release.tagName).map { ($0, release) } }
            .filter { build, _ in build <= candidate && (installed.map { build > $0 } ?? (build == candidate)) }
            .sorted { $0.0 < $1.0 }
        var seenBuilds = Set<Int>()
        var authors: [Summary.Author] = []
        var other: [String] = []
        var upstream: String?
        for (build, release) in included where seenBuilds.insert(build).inserted {
            let meta = meta(in: release.body)
            if build == candidate {
                upstream = meta?.upstream ?? upstreamVersion(inHeader: release.body)
            }
            guard let meta else {
                append(fallbackItems(in: release.body), to: &other)
                continue
            }
            for note in meta.notes {
                let name = note.author.trimmingCharacters(in: .whitespacesAndNewlines)
                let items = note.items.map(cleanedItem).filter { !$0.isEmpty }
                guard !items.isEmpty else { continue }
                guard !name.isEmpty else {
                    append(items, to: &other)
                    continue
                }
                if let index = authors.firstIndex(where: { $0.name == name }) {
                    append(items, to: &authors[index].items)
                } else {
                    var author = Summary.Author(name: name, items: [])
                    append(items, to: &author.items)
                    authors.append(author)
                }
            }
            append(meta.other.map(cleanedItem).filter { !$0.isEmpty }, to: &other)
        }
        let changed = upstream.map { $0 != installedUpstream } ?? false
        return Summary(build: candidate, upstream: upstream, upstreamChanged: changed,
                       authors: authors, other: other, includedBuilds: max(seenBuilds.count, 1))
    }

    private static func append(_ items: [String], to list: inout [String]) {
        for item in items where !list.contains(item) {
            list.append(item)
        }
    }
}
