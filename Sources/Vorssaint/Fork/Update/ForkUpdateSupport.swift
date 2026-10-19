// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// Updates for the fork's app, never from the official releases: those
/// would replace it with Vorssaint and its features would be gone.
///
/// The contract with `fork/build-release.sh` and the release workflow:
/// the fork's repository is written in Info.plist (`ForkUpdateRepository`),
/// each release is tagged `build-<N>` where N, also the app's
/// `CFBundleVersion`, counts the commits of `main` (which only grows), and
/// carries the zipped app and, in its notes, a `SHA256: …` line. Which build
/// is newer is a plain comparison of those numbers; whether a download may
/// replace the running app is decided by its signature, by the service.
enum ForkUpdateSupport {
    static let tagPrefix = "build-"
    static let repositoryInfoKey = "ForkUpdateRepository"
    static let upstreamVersionInfoKey = "ForkUpstreamVersion"

    /// `owner/name`, or nil for a build that has no release feed (a local
    /// `./build.sh --dev`): such a build never updates itself.
    static func repository(info: [String: Any]?) -> String? {
        guard let value = info?[repositoryInfoKey] as? String else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        return value
    }

    static func latestReleaseURL(repository: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Releases asked for per request, newest first: one request covers
    /// every build skipped since the installed one, whose notes the update
    /// window puts together.
    static let releasesPerPage = 50
    /// A Mac that missed more than this many pages of builds sees the notes
    /// of the newest ones only.
    static let maxReleasePages = 3

    static func releasesURL(repository: String, page: Int = 1) -> URL {
        var url = "https://api.github.com/repos/\(repository)/releases?per_page=\(releasesPerPage)"
        if page > 1 { url += "&page=\(page)" }
        return URL(string: url)!
    }

    static func releasesPageURL(repository: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/latest")!
    }

    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browserDownloadURL: URL
            let size: Int

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let body: String?
        let assets: [Asset]
        /// Neither is offered, as `/releases/latest` never returned them.
        var draft: Bool? = nil
        var prerelease: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
            case draft
            case prerelease
        }
    }

    struct Candidate: Equatable {
        let build: Int
        let zipURL: URL
        let zipSize: Int
        let sha256: String
        /// The release notes as a person may read them: no checksum line,
        /// no machine line (`ForkUpdateNotes.displayText`).
        let notes: String
    }

    /// `build-42` gives 42; anything else is not a test build.
    static func buildNumber(fromTag tag: String) -> Int? {
        guard tag.hasPrefix(tagPrefix) else { return nil }
        let digits = tag.dropFirst(tagPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// The `SHA256: <64 hex>` line the publishing script writes in the notes.
    static func sha256(inNotes body: String?) -> String? {
        guard let body else { return nil }
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SHA256:") else { continue }
            let value = trimmed.dropFirst("SHA256:".count).trimmingCharacters(in: .whitespaces).lowercased()
            if value.count == 64, value.allSatisfy(\.isHexDigit) { return value }
        }
        return nil
    }

    /// A release a test build can install: a build tag, one zip, a checksum.
    static func candidate(from release: Release) -> Candidate? {
        guard let build = buildNumber(fromTag: release.tagName),
              let sha256 = sha256(inNotes: release.body)
        else { return nil }
        let zips = release.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        guard zips.count == 1 else { return nil }
        return Candidate(build: build, zipURL: zips[0].browserDownloadURL, zipSize: zips[0].size,
                         sha256: sha256, notes: ForkUpdateNotes.displayText(release.body))
    }

    /// The newest installable build of a list of releases, whatever their
    /// order; drafts and pre-releases are never offered.
    static func newestCandidate(in releases: [Release]) -> Candidate? {
        releases
            .filter { $0.draft != true && $0.prerelease != true }
            .compactMap(candidate(from:))
            .max { $0.build < $1.build }
    }

    /// Whether the next page is needed for the notes: only while every
    /// build of a full page is still newer than the installed one, and
    /// never past `maxReleasePages`.
    static func needsNextPage(_ page: [Release], pageNumber: Int, installed: Int?) -> Bool {
        guard let installed, page.count >= releasesPerPage, pageNumber < maxReleasePages else { return false }
        let builds = page.compactMap { buildNumber(fromTag: $0.tagName) }
        return !builds.isEmpty && builds.allSatisfy { $0 > installed }
    }

    /// Only a strictly newer build is offered. A build that does not know
    /// its own number is offered any published one.
    static func isNewer(_ candidate: Candidate, than current: Int?) -> Bool {
        guard let current else { return true }
        return candidate.build > current
    }

    /// The running build's number: its `CFBundleVersion`, which the release
    /// sets to N.
    static func currentBuild(info: [String: Any]?) -> Int? {
        if let number = info?["CFBundleVersion"] as? Int { return number }
        if let text = info?["CFBundleVersion"] as? String { return Int(text) }
        return nil
    }

    /// The official version the build is based on, such as 3.4.1.
    static func upstreamVersion(info: [String: Any]?) -> String? {
        info?[upstreamVersionInfoKey] as? String
    }
}
