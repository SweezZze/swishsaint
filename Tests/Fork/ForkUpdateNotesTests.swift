// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkUpdateNotesTests {
    typealias Notes = ForkUpdateNotes
    typealias Support = ForkUpdateSupport

    static func run(_ suite: TestSuite) {
        meta(suite)
        display(suite)
        items(suite)
        aggregation(suite)
        list(suite)
        wiring(suite)
    }

    private static let sha = "SHA256: " + String(repeating: "ab", count: 32)

    private static func release(_ build: Int, _ body: String?, zip: Bool = true,
                                prerelease: Bool? = nil, draft: Bool? = nil) -> Support.Release {
        Support.Release(tagName: "build-\(build)", body: body,
                        assets: zip ? [.init(name: "Swishsaint-build-\(build).zip",
                                             browserDownloadURL: URL(string: "https://example.com/\(build).zip")!,
                                             size: 10)] : [],
                        draft: draft, prerelease: prerelease)
    }

    /// A body as `fork/release-notes.sh` writes it.
    private static func body(_ build: Int, upstream: String = "3.4.2-beta.1",
                             notes: [(Int, String, [String])] = [], other: [String] = []) -> String {
        let notesJSON = notes.map { pr, author, items in
            "{\"pr\":\(pr),\"author\":\"\(author)\",\"items\":[\(items.map { "\"\($0)\"" }.joined(separator: ","))]}"
        }.joined(separator: ",")
        let otherJSON = other.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        **Swishsaint build \(build)** — Vorssaint officiel \(upstream) (v\(upstream) + 10 commits)

        ### Martial
        - visible markdown, not read by the app

        <!-- swishsaint-meta v1 {"build":\(build),"upstream":"\(upstream)","notes":[\(notesJSON)],"other":[\(otherJSON)]} -->
        \(sha)
        """
    }

    private static func meta(_ suite: TestSuite) {
        let parsed = Notes.meta(in: body(2170, notes: [(31, "Martial", ["J'ai corrigé un bug."])], other: ["Docs"]))
        suite.expect(parsed == Notes.Meta(build: 2170, upstream: "3.4.2-beta.1",
                                          notes: [.init(pr: 31, author: "Martial", items: ["J'ai corrigé un bug."])],
                                          other: ["Docs"]),
                     "the machine line gives the build, the official version, each PR's author and sentences, and the rest")
        suite.expect(Notes.meta(in: "**Swishsaint build 2164** — base officielle Vorssaint 3.4.2-beta.1\n\n\(sha)") == nil
                        && Notes.meta(in: nil) == nil && Notes.meta(in: "") == nil,
                     "a release without the machine line has no meta")
        suite.expect(Notes.meta(in: "<!-- swishsaint-meta v1 {\"build\":12,\"notes\":[ -->") == nil
                        && Notes.meta(in: "<!-- swishsaint-meta v1 {\"build\":12}") == nil
                        && Notes.meta(in: "<!-- swishsaint-meta v1 [1,2] -->") == nil,
                     "a broken or unfinished JSON gives no meta instead of a wrong one")
        let partial = Notes.meta(in: "<!-- swishsaint-meta v1 {\"build\":12,\"future\":true} -->")
        suite.expect(partial?.build == 12 && partial?.notes == [] && partial?.other == [] && partial?.upstream == nil,
                     "missing lists and unknown fields leave the rest readable")
        // The script writes < and > as < and >: "-->" can never end the comment early.
        let escaped = Notes.meta(in: "<!-- swishsaint-meta v1 {\"notes\":[{\"author\":\"Louis\",\"items\":[\"a \\u003c b \\u002d-\\u003e c\"]}]} -->")
        suite.expect(escaped?.notes.first?.items == ["a < b --> c"],
                     "escaped angle brackets come back as text, so a sentence may hold \"-->\" safely")
        let first = Notes.meta(in: "<!-- swishsaint-meta v1 {\"build\":1} -->\n<!-- swishsaint-meta v1 {\"build\":2} -->")
        suite.expect(first?.build == 1, "the first machine line is the one read")
    }

    private static func display(_ suite: TestSuite) {
        let raw = body(2170, notes: [(31, "Martial", ["x"])])
        let shown = Notes.displayText(raw)
        suite.expect(!shown.contains("<!--") && !shown.contains("-->") && !shown.contains("swishsaint-meta")
                        && !shown.contains("SHA256") && shown.hasPrefix("**Swishsaint build 2170**")
                        && shown.hasSuffix("- visible markdown, not read by the app"),
                     "the text shown elsewhere never holds the machine line or the checksum")
        suite.expect(Notes.displayText("a\n<!-- one\nline\ntwo -->\nb") == "a\n\nb"
                        && Notes.displayText("a <!-- open") == "a"
                        && Notes.displayText("a\n\n\n\nb") == "a\n\nb"
                        && Notes.displayText(nil) == "",
                     "every HTML comment goes, even over several lines or unclosed, and blank lines collapse")
        let candidate = Support.candidate(from: release(2170, raw))
        suite.expect(candidate?.notes == shown && candidate?.sha256 == String(repeating: "ab", count: 32),
                     "a candidate's notes are the readable text; its checksum still comes from the body")
    }

    private static func items(_ suite: TestSuite) {
        suite.expect(Notes.cleanedItem("- feat(meetings): transcribe meetings on your mac with parakeet (#29)")
                        == "Transcribe meetings on your mac with parakeet"
                        && Notes.cleanedItem("fix: stop the flicker") == "Stop the flicker"
                        && Notes.cleanedItem("feat(x)!: drop the old key") == "Drop the old key",
                     "a conventional commit title loses its prefix and PR number, and starts with a capital")
        suite.expect(Notes.cleanedItem("- J'ai corrigé un bug sur l'historique du presse-papiers.")
                        == "J'ai corrigé un bug sur l'historique du presse-papiers."
                        && Notes.cleanedItem("Note: garder ça") == "Note: garder ça"
                        && Notes.cleanedItem("Réglages (#rapide)") == "Réglages (#rapide)",
                     "an author's sentence stays as written")
        suite.expect(Notes.upstreamVersion(inHeader: "**Swishsaint build 2170** — Vorssaint officiel 3.4.2-beta.1 (v3.4.2-beta.1 + 10 commits)")
                        == "3.4.2-beta.1"
                        && Notes.upstreamVersion(inHeader: "**Swishsaint build 2164** — base officielle Vorssaint 3.4.1 (v3.4.1)\n") == "3.4.1"
                        && Notes.upstreamVersion(inHeader: "**Swishsaint build 1** — base officielle Vorssaint ?") == nil
                        && Notes.upstreamVersion(inHeader: "no header") == nil,
                     "the official version is read from the header of new and old notes alike")
        let old = "**Swishsaint build 2164** — base officielle Vorssaint 3.4.2-beta.1\n\n### Nouveau chez nous\n"
            + "- feat(dictation): show the dictation history in the island (#30)\n- Direct commit\n\n"
            + "### Côté officiel\n- 12 commit(s) intégré(s) depuis build-2160 : https://github.com/x/compare/a...b\n\n\(sha)\n"
        suite.expect(Notes.fallbackItems(in: "### Autres changements\n- Fix for @\u{200B}louis &lt;3 &amp; co (#12)\n")
                        == ["Fix for @louis <3 & co"],
                     "the markdown escapes written for GitHub do not show in the window")
        suite.expect(Notes.fallbackItems(in: old) == ["Show the dictation history in the island", "Direct commit"],
                     "an old release gives the bullets of its sections, never the official compare link")
    }

    private static func aggregation(_ suite: TestSuite) {
        let releases = [
            release(2190, body(2190, upstream: "3.4.2", notes: [(34, "Martial", ["Encore un détail."])],
                               other: ["fix(ci): faster checks"])),
            release(2170, body(2170, notes: [(31, "Martial", ["J'ai corrigé un bug.", "  "]),
                                             (32, "Louis", ["J'ai ajouté un raccourci."])],
                               other: ["Docs"])),
            release(2180, body(2180, notes: [(33, "Martial", ["J'ai corrigé un bug.", "J'ai accéléré la dictée."]),
                                             (35, "Hector", [])])),
            release(2164, "**Swishsaint build 2164** — base officielle Vorssaint 3.4.2-beta.1\n\n### Nouveau chez nous\n- feat(dictation): island history (#30)\n\n\(sha)"),
            release(2160, body(2160, notes: [(29, "Martial", ["Déjà installé."])])),
            Support.Release(tagName: "v3.4.2", body: body(9999, notes: [(1, "Official", ["no"])]), assets: []),
        ]
        let summary = Notes.summary(releases: releases, installed: 2160, candidate: 2190, installedUpstream: "3.4.2-beta.1")
        suite.expect(summary.authors == [.init(name: "Martial", items: ["J'ai corrigé un bug.", "J'ai accéléré la dictée.",
                                                                        "Encore un détail."]),
                                         .init(name: "Louis", items: ["J'ai ajouté un raccourci."])],
                     "authors in the order they first appear, oldest build first, each sentence once, empty ones dropped")
        suite.expect(summary.other == ["Island history", "Docs", "Faster checks"],
                     "other changes add up across builds, an old release's bullets among them")
        suite.expect(summary.build == 2190 && summary.includedBuilds == 4 && summary.hasNotes,
                     "the summary covers every build after the installed one up to the candidate, the installed one excluded")
        suite.expect(summary.upstream == "3.4.2" && summary.upstreamChanged && !summary.isPrerelease,
                     "the official version is the candidate's; it changed from the installed one")

        let same = Notes.summary(releases: releases, installed: 2164, candidate: 2170, installedUpstream: "3.4.2-beta.1")
        suite.expect(same.upstream == "3.4.2-beta.1" && !same.upstreamChanged && same.isPrerelease
                        && same.includedBuilds == 1 && same.authors.map(\.name) == ["Martial", "Louis"],
                     "a single build on the same official beta: not changed, marked beta")
        let unknownInstalled = Notes.summary(releases: releases, installed: nil, candidate: 2170, installedUpstream: nil)
        suite.expect(unknownInstalled.includedBuilds == 1 && unknownInstalled.upstreamChanged
                        && unknownInstalled.other == ["Docs"],
                     "an unknown installed build gathers the candidate alone")
        let oldOnly = Notes.summary(releases: releases, installed: 2160, candidate: 2164, installedUpstream: "3.4.2-beta.1")
        suite.expect(oldOnly.authors.isEmpty && oldOnly.other == ["Island history"]
                        && oldOnly.upstream == "3.4.2-beta.1" && !oldOnly.upstreamChanged,
                     "a release from before the machine line still gives its bullets and its official version")
        let empty = Notes.summary(releases: [], installed: 2160, candidate: 2170, installedUpstream: "3.4.1")
        suite.expect(!empty.hasNotes && empty.upstream == nil && !empty.upstreamChanged && empty.includedBuilds == 1,
                     "no release read: nothing to say, nothing claimed about the official version")
        let duplicated = Notes.summary(releases: [releases[1], releases[1]], installed: 2160, candidate: 2170,
                                       installedUpstream: nil)
        suite.expect(duplicated.includedBuilds == 1 && duplicated.authors.first?.items == ["J'ai corrigé un bug."],
                     "the same build listed twice counts once")

        let withdrawn = Notes.summary(releases: releases + [
            release(2175, body(2175, notes: [(36, "Louis", ["Build retirée."])]), prerelease: true),
            release(2176, body(2176, notes: [(37, "Louis", ["Brouillon."])], other: ["Brouillon"]), draft: true),
        ], installed: 2164, candidate: 2190, installedUpstream: "3.4.2-beta.1")
        suite.expect(withdrawn.includedBuilds == 3
                        && !withdrawn.authors.flatMap(\.items).contains("Build retirée.")
                        && !withdrawn.authors.flatMap(\.items).contains("Brouillon.")
                        && !withdrawn.other.contains("Brouillon"),
                     "a build marked pre-release or still a draft is left out of the notes, as it is never offered")

        let data = try? JSONEncoder().encode(summary)
        let decoded = data.flatMap { try? JSONDecoder().decode(Notes.Summary.self, from: $0) }
        suite.expect(decoded == summary, "the summary saved for after the relaunch reads back the same")
    }

    private static func list(_ suite: TestSuite) {
        suite.expect(Support.releasesURL(repository: "hectorpasserat2004-create/swishsaint").absoluteString
                        == "https://api.github.com/repos/hectorpasserat2004-create/swishsaint/releases?per_page=50"
                        && Support.releasesURL(repository: "a/b", page: 2).absoluteString
                        == "https://api.github.com/repos/a/b/releases?per_page=50&page=2",
                     "one request lists the fork's last 50 releases")
        let releases = [
            release(2160, body(2160)),
            release(2190, body(2190), zip: false),
            release(2185, body(2185), prerelease: true),
            release(2186, body(2186), draft: true),
            release(2180, "no checksum"),
            release(2170, body(2170)),
            Support.Release(tagName: "v9.9.9", body: body(9999), assets: []),
        ]
        suite.expect(Support.newestCandidate(in: releases)?.build == 2170,
                     "the candidate is the newest build with one zip and a checksum, never a draft or a pre-release")
        suite.expect(Support.newestCandidate(in: []) == nil
                        && Support.newestCandidate(in: [release(1, "x")]) == nil,
                     "no installable build, no candidate")
        let full = (0..<50).map { release(3000 - $0, body(3000 - $0)) }
        suite.expect(Support.needsNextPage(full, pageNumber: 1, installed: 2900)
                        && Support.needsNextPage(full, pageNumber: 2, installed: 2900),
                     "a full page of builds all newer than the installed one asks for the next")
        suite.expect(!Support.needsNextPage(full, pageNumber: 1, installed: 2960)
                        && !Support.needsNextPage(Array(full.prefix(49)), pageNumber: 1, installed: 10)
                        && !Support.needsNextPage(full, pageNumber: 3, installed: 10)
                        && !Support.needsNextPage(full, pageNumber: 1, installed: nil)
                        && !Support.needsNextPage((0..<50).map { _ in Support.Release(tagName: "v1", body: nil, assets: []) },
                                                  pageNumber: 1, installed: 10),
                     "no next page once the installed build is reached, on a short page, past 3 pages, or without builds")
    }

    private static func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func wiring(_ suite: TestSuite) {
        let service = source("Sources/Vorssaint/Fork/Update/ForkUpdateService.swift")
        let offer = service.components(separatedBy: "private func offer(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(offer.contains("ForkUpdateNotesWindow.shared.show(") && !offer.contains("NSAlert")
                        && offer.contains("forKey: ForkDefaultsKey.updatePostponedBuild")
                        && offer.contains("forKey: ForkDefaultsKey.updateNotesSeenBuild")
                        && offer.contains("self?.install(candidate)"),
                     "a build is offered in the update window: Later postpones it, Install marks its notes read and installs")
        suite.expect(service.contains("ForkUpdateSupport.releasesURL(repository: repository, page: page)")
                        && service.contains("ForkUpdateSupport.latestReleaseURL(repository: repository)")
                        && service.contains("ForkUpdateSupport.newestCandidate(in: releases)"),
                     "the check reads the release list, and falls back on the latest release alone")
        suite.expect(service.contains("guard repository != nil, timer == nil else { return }\n        noteLaunch()"),
                     "the notes after a relaunch are looked at once, at launch, by a build that updates itself")
        let install = service.components(separatedBy: "func install(_ candidate: ForkUpdateSupport.Candidate) {").dropFirst().first?
            .components(separatedBy: "state = .downloading").first ?? ""
        suite.expect(install.contains("case .downloading, .installing: return")
                        && install.contains("ForkUpdateNotesWindow.shared.closeForInstall()"),
                     "one download at a time, from the window or the Settings, and the offer closes once it starts")
        suite.expect(service.contains("self.offerWhenFree(candidate)") && service.contains("offerWhenFree(pending.candidate)")
                        && service.contains("presentWhenFree(\"offer\")") && service.contains("presentWhenFree(\"installed\")")
                        && service.contains("defaults.string(forKey: DefaultsKey.whatsNewPendingVersion) == nil"),
                     "an offer nobody asked for, like the notes after a relaunch, waits for the launch windows")
        let defaults = source("Sources/Vorssaint/Fork/Core/ForkDefaults.swift")
        suite.expect(defaults.contains("static let updateLastRunBuild = \"fork.update.lastRunBuild\"")
                        && defaults.contains("static let updateNotesSeenBuild = \"fork.update.notesSeenBuild\""),
                     "the update window's state lives under fork.update.")
    }
}
