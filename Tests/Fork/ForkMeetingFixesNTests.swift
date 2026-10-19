// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The exports' corrections after their review: what leaves is a list of
/// fields; the Google Meet code leaves neither the record, nor the title,
/// nor the names unless asked, and the notes not either; each webhook has
/// its own secret; nothing goes on its own once the list was rewritten
/// outside the page, after a meeting that did not end by a Stop or the
/// call's end, or with the feature off; a send follows two redirections at
/// most and a 2xx counts only once the whole body left; the library names
/// only the exporters set up.
enum ForkMeetingFixesNTests {
    static func run(_ suite: TestSuite) {
        allowList(suite)
        meetCodeOut(suite)
        dropFolderNames(suite)
        fingerprint(suite)
        oneSecretEach(suite)
        stopReasons(suite)
        automaticPlan(suite)
        redirections(suite)
        earlyAnswer(suite)
        configured(suite)
        marks(suite)
        help(suite)
        texts(suite)
        transcriptShape(suite)
        notesWithoutCode(suite)
        codeShapes(suite)
        leftovers(suite)
        listStates(suite)
        legacySecrets(suite)
        secondTexts(suite)
    }

    private static let start = Date(timeIntervalSince1970: 1_792_310_531)
    private static let code = "abc-defg-hij"

    /// A meeting with every field this version writes, and some it does not
    /// know, each holding something that must not leave.
    private static func everything() -> ForkMeetingSidecar {
        var sidecar = ForkMeetingSidecar.started(
            id: UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8")!, startedAt: start, origin: .offered,
            title: "Google Meet · \(code)", titleSource: .window,
            capture: .init(target: .window, systemAudio: .app, microphone: "AirPods de Martial", quality: .standard),
            provider: "meet", meetCode: code, app: "com.google.Chrome")
        sidecar.state = .complete
        sidecar.endedAt = start.addingTimeInterval(3120)
        sidecar.recordedSeconds = 3100
        sidecar.stopReason = .user
        sidecar.finalPass = .done
        sidecar.calendarEventID = "EVENT-42@calendar"
        sidecar.notes = "Budget validé"
        sidecar.gaps = [.init(at: 12, seconds: 3, kind: .microphoneSwitch)]
        sidecar.pauses = [.init(at: 60, seconds: 30, reason: .user, preserved: ["where": .string("/Users/martial/secret")])]
        sidecar.exports = [ForkMeetingSidecar.Export(exporter: "webhook", at: start, status: "done", target: "x")]
        sidecar.transcript = .object(["state": .string("done"), "engine": .string("parakeet"), "words": .number(812),
                                      "at": .string("2026-10-19T10:55:00Z"), "file": .string("/Users/martial/x.txt"),
                                      "device": .object(["name": .string("AirPods de Martial")])])
        sidecar.preserved = ["future": .string("a later version's field"), "path": .string("/Users/martial/Movies")]
        return sidecar
    }

    private static func object(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // MARK: - What leaves

    private static func allowList(_ suite: TestSuite) {
        typealias Document = ForkMeetingExportDocument
        let plain = try? Document.json(everything(), includesMeetCode: false, includesNotes: false)
        let text = plain.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let keys = Set(object(plain).keys)
        let allowed = Set(Document.fields).subtracting(["notes", "meetCode"])
        suite.expect(!keys.isEmpty && keys.isSubset(of: allowed),
                     "no field outside the list leaves: \(keys.subtracting(allowed).sorted())")
        suite.expect(keys == allowed, "every field of the list leaves when the meeting has it: \(keys.sorted())")
        for secret in ["AirPods", "com.google.Chrome", "EVENT-42", "Budget", code, "/Users/martial", "later version", "microphoneSwitch"] {
            suite.expect(!text.contains(secret), "what leaves never holds “\(secret)”")
        }
        let pauses = object(plain)["pauses"] as? [[String: Any]] ?? []
        suite.expect(pauses.count == 1 && Set(pauses[0].keys).isSubset(of: Set(Document.pauseFields))
                        && pauses[0]["reason"] as? String == "user",
                     "a pause leaves with its time, its length and its reason only")
        let both = object(try? Document.json(everything(), includesMeetCode: true, includesNotes: true))
        suite.expect(Set(both.keys) == Set(Document.fields) && both["notes"] as? String == "Budget validé"
                        && both["meetCode"] as? String == code && both["title"] as? String == "Google Meet · \(code)",
                     "the notes and the Meet code leave only when asked, and the title keeps its code then")
        let notesOnly = object(try? Document.json(everything(), includesMeetCode: false, includesNotes: true))
        suite.expect(notesOnly["notes"] != nil && notesOnly["meetCode"] == nil, "each option goes alone")
        suite.expect(Document.fields == ["id", "schema", "title", "startedAt", "endedAt", "recordedSeconds", "provider",
                                         "origin", "pauses", "transcript", "notes", "meetCode"],
                     "the list is the one the page says")
    }

    private static func meetCodeOut(_ suite: TestSuite) {
        typealias Document = ForkMeetingExportDocument
        suite.expect(Document.title("Google Meet · \(code)", meetCode: code, includesMeetCode: false) == "Google Meet"
                        && Document.title(code, meetCode: code, includesMeetCode: false) == nil
                        && Document.title("Google Meet · ABC-DEFG-HIJ · Équipe", meetCode: code, includesMeetCode: false) == "Google Meet · Équipe"
                        && Document.title("Point hebdo", meetCode: nil, includesMeetCode: false) == "Point hebdo"
                        && Document.title("Google Meet · \(code)", meetCode: code, includesMeetCode: true) == "Google Meet · \(code)",
                     "the Meet code leaves the title, whatever its case, with the separator it leaves alone")
        suite.expect(Document.title("Meet zzz-zzzz-zzz", meetCode: nil, includesMeetCode: false) == "Meet",
                     "a code of that shape leaves the title even when the record did not keep it")
        let folder = "2026-10-19 10h02 — Google Meet · \(code)"
        suite.expect(Document.name(folder, meetCode: code, includesMeetCode: false) == "2026-10-19 10h02 — Google Meet"
                        && Document.name("2026-10-19 10h02 — \(code)", meetCode: code, includesMeetCode: false) == "2026-10-19 10h02"
                        && Document.name("\(folder) (2)", meetCode: code, includesMeetCode: false) == "2026-10-19 10h02 — Google Meet (2)"
                        && Document.name(folder, meetCode: code, includesMeetCode: true) == folder
                        && Document.name(code, meetCode: code, includesMeetCode: false) == "meeting",
                     "the names sent lose the code too, never their stamp, and are never empty")
        let package = ForkMeetingExportPackage(folderName: folder, sidecar: everything(),
                                               audio: URL(fileURLWithPath: "/tmp/a.m4a"),
                                               transcript: URL(fileURLWithPath: "/tmp/a.txt"))
        let parts = (try? ForkWebhookPayload.parts(package, includesMeetCode: false, includesNotes: false)) ?? []
        suite.expect(parts.compactMap(\.filename) == ["meeting.json", "2026-10-19 10h02 — Google Meet.m4a",
                                                      "2026-10-19 10h02 — Google Meet.txt"],
                     "the multipart's file names carry no Meet code")
        var leaked = false
        for part in parts {
            if case let .data(data) = part.source { leaked = leaked || String(decoding: data, as: UTF8.self).contains(code) }
            leaked = leaked || ForkWebhookMultipart.headers(of: part).contains(code)
        }
        suite.expect(!leaked, "no part, header or body, holds the Meet code without the option")
        let coded = (try? ForkWebhookPayload.parts(package, includesMeetCode: true, includesNotes: false)) ?? []
        suite.expect(coded.dropFirst().first?.filename == "\(folder).m4a", "with the option, the names keep it")
    }

    private static func dropFolderNames(_ suite: TestSuite) {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("fork-fixes-n-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: base) }
        let library = base.appendingPathComponent("Réunions", isDirectory: true)
        let folder = "2026-10-19 10h02 — Google Meet · \(code)"
        let source = library.appendingPathComponent(folder, isDirectory: true)
        let drop = base.appendingPathComponent("Dépôt", isDirectory: true)
        try? manager.createDirectory(at: source, withIntermediateDirectories: true)
        try? manager.createDirectory(at: drop, withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drop.path)
        let audio = source.appendingPathComponent("\(folder).m4a")
        try? Data("audio".utf8).write(to: audio)
        let package = ForkMeetingExportPackage(folderName: folder, sidecar: everything(), audio: audio, transcript: nil)
        let exporter = ForkDropFolderExporter(config: .init(id: "d", kind: .dropFolder, folder: drop.path), libraryRoot: library)
        let copied = drop.appendingPathComponent("2026-10-19 10h02 — Google Meet", isDirectory: true)
        let done = (try? exporter.copy(package, into: drop)) != nil
        let names = (try? manager.contentsOfDirectory(atPath: copied.path)) ?? []
        suite.expect(done && ((try? manager.contentsOfDirectory(atPath: drop.path)) ?? []) == ["2026-10-19 10h02 — Google Meet"]
                        && Set(names) == ["2026-10-19 10h02 — Google Meet.m4a", "meeting.json"],
                     "the drop folder's copy and its files are named without the Meet code: \(names)")
        let json = (try? String(contentsOf: copied.appendingPathComponent("meeting.json"), encoding: .utf8)) ?? ""
        suite.expect(!json.contains(code) && !json.contains("Budget") && !json.contains("AirPods"),
                     "the copied meeting.json has neither the code, nor the notes, nor the microphone")
        let rights = ((try? manager.attributesOfItem(atPath: copied.path))?[.posixPermissions] as? NSNumber)?.intValue
        let fileRights = ((try? manager.attributesOfItem(atPath: copied.appendingPathComponent("meeting.json").path))?[.posixPermissions]
                          as? NSNumber)?.intValue
        suite.expect(rights == 0o755 && fileRights == 0o644,
                     "the copy takes the drop folder's rights: \(String(rights ?? 0, radix: 8)), \(String(fileRights ?? 0, radix: 8))")

        // Another tool added a file to the copy: sent again, only ours change.
        try? Data("summary".utf8).write(to: copied.appendingPathComponent("summary.md"))
        try? Data("audio 2".utf8).write(to: audio)
        let again = (try? exporter.copy(package, into: drop)) != nil
        suite.expect(again && (try? Data(contentsOf: copied.appendingPathComponent("summary.md"))) == Data("summary".utf8)
                        && (try? Data(contentsOf: copied.appendingPathComponent("2026-10-19 10h02 — Google Meet.m4a"))) == Data("audio 2".utf8)
                        && ((try? manager.contentsOfDirectory(atPath: drop.path)) ?? []).count == 1,
                     "sent again, the same meeting replaces only its own files, and keeps what another tool added")

        // A link named like the copy, to the meeting itself: never written into.
        let trap = base.appendingPathComponent("Piège", isDirectory: true)
        try? manager.createDirectory(at: trap, withIntermediateDirectories: true)
        try? manager.createSymbolicLink(at: trap.appendingPathComponent("2026-10-19 10h02 — Google Meet"), withDestinationURL: source)
        try? everything().encoded().write(to: source.appendingPathComponent("meeting.json"))
        let before = Set((try? manager.contentsOfDirectory(atPath: source.path)) ?? [])
        let trapped = (try? exporter.copy(package, into: trap)) != nil
        let after = Set((try? manager.contentsOfDirectory(atPath: source.path)) ?? [])
        suite.expect(trapped && before == after
                        && manager.fileExists(atPath: trap.appendingPathComponent("2026-10-19 10h02 — Google Meet (2)/meeting.json").path),
                     "a link in the drop folder, even to the same meeting, is never written into: the copy takes (2)")

        // What a copy cut short left: this process's own, or one a day old.
        let own = ForkMeetingLeftovers.name(ForkDropFolderExporter.draftPrefix)
        let other = ForkMeetingLeftovers.name(ForkDropFolderExporter.draftPrefix, pid: 1)
        let old = ForkMeetingLeftovers.name(ForkDropFolderExporter.draftPrefix, pid: 2)
        for name in [own, other, old] {
            try? manager.createDirectory(at: drop.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                                   ofItemAtPath: drop.appendingPathComponent(old).path)
        ForkDropFolderExporter.removeDrafts(in: drop)
        suite.expect(Set((try? manager.contentsOfDirectory(atPath: drop.path)) ?? []) == ["2026-10-19 10h02 — Google Meet", other],
                     "a draft of this process, or a day old, is removed; another copy's recent one and the copies are not")
    }

    // MARK: - The list the page wrote

    private static func fingerprint(_ suite: TestSuite) {
        typealias List = ForkMeetingExporterList
        let stored = List.encode([ForkMeetingExporterConfig(id: "d", kind: .dropFolder, mode: .automatic, folder: "/Volumes/NAS")])
        let print = List.fingerprint(stored)
        suite.expect(print.count == 64 && print.allSatisfy(\.isHexDigit) && print == List.fingerprint(stored),
                     "the fingerprint is the SHA-256 of the setting, in hexadecimal, always the same")
        var planted = List.decode(stored)
        planted.append(ForkMeetingExporterConfig(id: "p", kind: .dropFolder, mode: .automatic, includesMeetCode: true, folder: "/tmp/x"))
        let rewritten = List.encode(planted)
        suite.expect(List.matches(stored, fingerprint: print) && !List.matches(rewritten, fingerprint: print)
                        && !List.matches(stored.replacingOccurrences(of: "NAS", with: "Ailleurs"), fingerprint: print),
                     "an exporter added, or a folder changed, outside the page no longer matches")
        suite.expect(!List.matches(stored, fingerprint: nil) && !List.matches(stored, fingerprint: ""),
                     "a list without its fingerprint does not match: written by another process")
        suite.expect(List.matches(nil, fingerprint: nil) && List.matches("", fingerprint: "x") && List.matches("[]", fingerprint: nil),
                     "an empty list sends nothing: it always matches")
    }

    private static func oneSecretEach(_ suite: TestSuite) {
        let a = ForkMeetingExporterConfig(id: "A", kind: .webhook, address: "https://hooks.example.org/a", origin: "hooks.example.org")
        let b = ForkMeetingExporterConfig(id: "B", kind: .webhook, address: "https://hooks.example.org/b", origin: "hooks.example.org")
        suite.expect(a.secretAccount == "webhook@hooks.example.org#A" && b.secretAccount == "webhook@hooks.example.org#B",
                     "two webhooks on one host have each their own secret: webhook@<host>#<id>")
        var moved = a
        moved.origin = "evil.example"
        moved.address = "https://evil.example/a"
        suite.expect(moved.secretAccount == "webhook@evil.example#A" && moved.secretAccount != a.secretAccount,
                     "an origin rewritten in the preferences finds no secret under the real one")
        suite.expect((try? a.approvedTarget().account) == a.secretAccount,
                     "the account signed with is the exporter's own")
    }

    // MARK: - On its own

    private static func stopReasons(_ suite: TestSuite) {
        for reason in ForkMeetingStopReason.allCases {
            var meeting = everything()
            meeting.stopReason = reason
            meeting.exports = []
            let automatic = ForkMeetingExportEligibility.verdict(.success(meeting), live: false, automatic: true, target: "t")
            let click = ForkMeetingExportEligibility.verdict(.success(meeting), live: false, automatic: false, target: "t")
            let expected: ForkMeetingExportEligibility.Verdict = [.user, .meetingEnded].contains(reason) ? .allowed : .needsClick
            suite.expect(automatic == expected && click == .allowed,
                         "stopped by \(reason.rawValue): \(expected == .allowed ? "sent on its own" : "sent with a click only")")
        }
        var unknown = everything()
        unknown.stopReason = nil
        suite.expect(ForkMeetingExportEligibility.verdict(.success(unknown), live: false, automatic: true) == .needsClick,
                     "a meeting that does not say why it stopped waits for a click")
    }

    private static func automaticPlan(_ suite: TestSuite) {
        typealias Plan = ForkMeetingAutomaticExport
        suite.expect(Plan.plan(mode: .automatic, featureOn: false, listMatches: true, readiness: nil) == .none
                        && Plan.plan(mode: .automatic, featureOn: false, listMatches: false, readiness: .noSecret) == .none,
                     "with the feature off, nothing goes on its own, and nothing is written")
        suite.expect(Plan.plan(mode: .manual, featureOn: true, listMatches: false, readiness: .notConfigured) == .none,
                     "an exporter sending when asked does nothing after a meeting")
        suite.expect(Plan.plan(mode: .automatic, featureOn: true, listMatches: false, readiness: nil) == .fail(.listChanged),
                     "a list rewritten outside the page sends nothing on its own, and says so")
        suite.expect(Plan.plan(mode: .automatic, featureOn: true, listMatches: true, readiness: .notConfigured) == .fail(.notConfigured)
                        && Plan.plan(mode: .automatic, featureOn: true, listMatches: true, readiness: .originChanged) == .fail(.originChanged)
                        && Plan.plan(mode: .automatic, featureOn: true, listMatches: true, readiness: .noSecret) == .fail(.noSecret),
                     "an automatic exporter not set up, or whose origin changed, fails with its Retry")
        suite.expect(Plan.plan(mode: .automatic, featureOn: true, listMatches: true, readiness: nil) == .send,
                     "set up, on, and the page's list: sent")
    }

    // MARK: - The send

    private static func redirections(_ suite: TestSuite) {
        let origin = URL(string: "https://hooks.example.org/hook")!
        let same = URL(string: "https://hooks.example.org/next")!
        func follows(_ followed: Int, _ status: Int = 307, method: String = "POST", to: URL? = same) -> Bool {
            ForkWebhookRedirects.follows(followed: followed, status: status, method: method, from: origin, to: to, origin: origin)
        }
        suite.expect(follows(0) && follows(1) && follows(0, 308), "a 307 or 308 on the same origin is followed")
        suite.expect(!follows(2) && !follows(5) && ForkWebhookRedirects.maximum == 2,
                     "two redirections at most: the third is a failure")
        suite.expect(!follows(0, 302) && !follows(0, 301) && !follows(0, 303) && !follows(0, method: "GET"),
                     "a redirection that would drop the body is not followed")
        suite.expect(!follows(0, to: URL(string: "https://evil.example/hook")) && !follows(0, to: URL(string: "http://hooks.example.org/hook"))
                        && !follows(0, to: nil),
                     "another origin, or plain HTTP, is never followed")
        suite.expect(!follows(0, to: URL(string: "https://u:p@hooks.example.org/next")),
                     "a redirection carrying a user name and a password is not followed")
    }

    private static func earlyAnswer(_ suite: TestSuite) {
        typealias Verdict = ForkWebhookVerdict
        func result(_ status: Int?, sent: Int64 = 1000, refused: Bool = false, trust: Bool = false,
                    error: Int? = nil) -> Result<Int, ForkMeetingExportFailure> {
            Verdict.result(status: status, redirectRefused: refused, trustRefused: trust, errorCode: error, sent: sent, bodyBytes: 1000)
        }
        suite.expect(result(200) == .success(200) && result(204) == .success(204), "a 2xx after the whole body is a send done")
        suite.expect(result(200, sent: 0) == .failure(.earlyAnswer) && result(200, sent: 999) == .failure(.earlyAnswer)
                        && result(201, sent: 10, error: NSURLErrorNetworkConnectionLost) == .failure(.earlyAnswer),
                     "a 2xx given before the whole body left is refused")
        suite.expect(result(500, sent: 0) == .failure(.status(500)) && result(302, refused: true) == .failure(.redirected)
                        && result(nil, refused: true) == .failure(.redirected),
                     "an error status or a redirection not followed is said as such")
        suite.expect(result(nil, error: NSURLErrorServerCertificateUntrusted) == .failure(.certificate)
                        && result(nil, trust: true, error: NSURLErrorCancelled) == .failure(.certificate)
                        && result(nil, error: NSURLErrorTimedOut) == .failure(.network)
                        && result(nil, error: NSURLErrorCannotConnectToHost) == .failure(.network),
                     "a certificate refused is not a network failure")
    }

    // MARK: - The library

    private static func configured(_ suite: TestSuite) {
        typealias List = ForkMeetingExporterList
        let empty = ForkMeetingExporterConfig(id: "e", kind: .dropFolder)
        let folder = ForkMeetingExporterConfig(id: "f", kind: .dropFolder, folder: "/Volumes/NAS")
        let hook = ForkMeetingExporterConfig(id: "h", kind: .webhook, address: "https://hooks.example.org/h", origin: "hooks.example.org")
        let unsaved = ForkMeetingExporterConfig(id: "u", kind: .webhook)
        var rewritten = hook
        rewritten.id = "r"
        rewritten.address = "https://evil.example/h"
        let secrets: Set<String> = [hook.secretAccount!, "webhook@evil.example#r"]
        suite.expect(List.configured([], hasSecret: secrets.contains).isEmpty
                        && List.configured([empty, unsaved], hasSecret: secrets.contains).isEmpty,
                     "no exporter set up: the library names none, and shows no export at all")
        suite.expect(List.configured([empty, folder, unsaved, hook, rewritten], hasSecret: secrets.contains).map(\.id) == ["f", "h"],
                     "only the exporters set up are named, in their order")
        suite.expect(List.configured([hook], hasSecret: { _ in false }).isEmpty,
                     "a webhook without its secret is not set up")
        suite.expect(empty.readiness(hasSecret: secrets.contains) == .notConfigured
                        && unsaved.readiness(hasSecret: secrets.contains) == .notConfigured
                        && rewritten.readiness(hasSecret: secrets.contains) == .originChanged
                        && hook.readiness(hasSecret: { _ in false }) == .noSecret,
                     "what keeps an exporter from sending is said")
    }

    private static func marks(_ suite: TestSuite) {
        typealias History = ForkMeetingExportHistory
        let done = ForkMeetingSidecar.Export(exporter: "dropFolder", at: start, status: "done", target: "d")
        let failed = ForkMeetingSidecar.Export(exporter: "webhook", at: start, status: "failed", target: "w", reason: "network")
        suite.expect(History.mark([], targets: ["d"]) == nil && History.mark([done], targets: []) == nil
                        && History.mark([done], targets: ["d", "w"]) == .done
                        && History.mark([done, failed], targets: ["d", "w"]) == .failed
                        && History.mark([done, failed], targets: ["d"]) == .done,
                     "the row shows ✗ when an exporter set up failed last, else ✓ when one went")
    }

    // MARK: - Help and texts

    private static func help(_ suite: TestSuite) {
        let example = ForkWebhookPayload.verificationExample
        suite.expect(ForkWebhookSigner.freshness == 7500 && example.contains("7500"),
                     "a receiver takes a timestamp up to 2 h 05 old: the longest send, and five minutes")
        for piece in ["Buffer.byteLength", "try {", "toLowerCase()", "/^[0-9]+$/", "isdigit()", "key.lower()", "seen", "compare_digest",
                      "'duplicate'", "secret.encode()", "Buffer.from(SECRET)", "seen.has(given)", "given in seen"] {
            suite.expect(example.contains(piece), "the help's examples are robust: \(piece)")
        }
        suite.expect(!example.contains("< 300") && !example.contains("ts = headers['x-swishsaint-timestamp'];"),
                     "the five-minute window and the unchecked header are gone")
    }

    private static func texts(_ suite: TestSuite) {
        let shortened: [KeyPath<ForkMeetingStrings, String>] = [\.exportFailedNotice, \.exportsListConfirm]
        let failures: [ForkMeetingExportFailure] = [.inProgress, .unreadable, .noAudio, .folderMissing, .folderInsideLibrary,
                                                    .writeFailed, .refusedAddress(.fragmentInURL), .originChanged, .noSecret,
                                                    .redirected, .status(500), .network, .notConfigured, .keychain,
                                                    .certificate, .temporarySpace, .earlyAnswer, .listChanged, .dropFolderFull]
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            for path in shortened {
                suite.expect(!strings[keyPath: path].isEmpty && strings[keyPath: path].count <= 28,
                             "\(language.rawValue): “\(strings[keyPath: path])” fits in 28 characters")
            }
            let messages = failures.map { $0.message(strings) }
            suite.expect(!messages.contains(where: \.isEmpty) && Set(messages).count == messages.count,
                         "\(language.rawValue): every export failure has a sentence of its own")
            suite.expect(strings.exportsCaption.contains("recordedSeconds") && strings.exportsCaption.contains("meetCode")
                            && strings.exportsCaption.contains("transcript"),
                         "\(language.rawValue): the page lists the fields that leave")
            suite.expect(strings.webhookHelpCaption.contains("2"), "\(language.rawValue): the help says the window of 2 h 05")
        }
        let french = ForkMeetingStrings.strings(.fr)
        for text in [french.exportsListChanged, french.exportAutomaticNoSecret, french.webhookSecretRefused, french.exportFailKeychain,
                     french.exportFailCertificate, french.exportFailTemporarySpace, french.exportFailEarlyAnswer, french.exportInProgress] {
            suite.expect(!text.contains(" :") && !text.contains(" ;") && text.contains("\u{00A0}:"),
                         "French puts a no-break space before its colons: \(text)")
        }
        suite.expect(french.exportAutomaticNoSecret.hasPrefix("Pas encore de clé secrète")
                        && french.webhookSecretRefused == "Le trousseau a refusé la clé secrète\u{00A0}: elle n’est pas enregistrée."
                        && french.exportFailedNotice == "Échec de l’export",
                     "the French texts are the ones decided")
        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(!english.dropFolderCaption.contains("Nothing goes over the network") && english.dropFolderCaption.contains("NAS"),
                     "the drop folder no longer claims nothing goes over the network: a NAS does")
        suite.expect(!ForkMeetingStrings.strings(.zhTW).dropFolderCaption.contains("檔案夾")
                        && !ForkMeetingStrings.strings(.zhHK).actionExportAudio.contains("輸出")
                        && !ForkMeetingStrings.strings(.zhHK).exportFailed.contains("輸出")
                        && !ForkMeetingStrings.strings(.ko).exportModeCaption.contains("십시오")
                        && !ForkMeetingStrings.strings(.sk).exportModeCaption.lowercased().contains("schôdz")
                        && !ForkMeetingStrings.strings(.de).exportModeCaption.contains("Meeting")
                        && !ForkMeetingStrings.strings(.uk).exportKindDropFolder.contains("Тека"),
                     "each language uses its own word throughout")
    }

    // MARK: - Second review

    private static func transcriptShape(_ suite: TestSuite) {
        typealias Document = ForkMeetingExportDocument
        suite.expect(Document.transcript(nil) == nil && Document.transcript(.string("text")) == nil
                        && Document.transcript(.object(["file": .string("/Users/martial/x.txt")])) == nil
                        && Document.transcript(.object(["engine": .string("parakeet")])) == nil,
                     "nothing of transcript leaves until it has the transcription's shape")
        let sent = Document.transcript(.object([
            "state": .string("done"), "engine": .string("parakeet"), "language": .string("fr"), "at": .string("2026-10-19T10:55:00Z"),
            "words": .number(812), "file": .string("/Users/martial/x.txt"), "device": .string("AirPods"),
            "calendarEventID": .string("EVT-123"),
        ]))
        guard case let .object(fields)? = sent else { return suite.expect(false, "a transcript of its shape leaves") }
        suite.expect(Set(fields.keys) == ["state", "engine", "language", "at", "words"],
                     "under transcript, only state, words, language, engine and at leave: \(fields.keys.sorted())")
        let nested = Document.transcript(.object(["state": .string("done"), "engine": .string("parakeet"),
                                                  "words": .object(["path": .string("/Users/martial")])]))
        suite.expect(nested == .object(["state": .string("done"), "engine": .string("parakeet")]),
                     "a value of the list that is itself an object does not leave")
    }

    private static func notesWithoutCode(_ suite: TestSuite) {
        var meeting = everything()
        meeting.notes = "Lien : https://meet.google.com/\(code)\nBudget validé\nRevoir ZZZ-ZZZZ-ZZZ"
        let off = object(try? ForkMeetingExportDocument.json(meeting, includesMeetCode: false, includesNotes: true))
        let notes = off["notes"] as? String ?? ""
        suite.expect(!notes.contains(code) && !notes.lowercased().contains("zzz-zzzz-zzz") && notes.contains("\nBudget validé\n"),
                     "notes on, Meet code off: the code leaves the notes, their lines stay: \(notes)")
        let on = object(try? ForkMeetingExportDocument.json(meeting, includesMeetCode: true, includesNotes: true))
        suite.expect(on["notes"] as? String == meeting.notes, "both on: the notes leave as written")
    }

    private static func codeShapes(_ suite: TestSuite) {
        typealias Document = ForkMeetingExportDocument
        suite.expect(Document.title("Réunion (\(code))", meetCode: nil, includesMeetCode: false) == "Réunion"
                        && Document.name("Réunion [\(code)]", meetCode: nil, includesMeetCode: false) == "Réunion"
                        && Document.title("Point \(code) (2)", meetCode: code, includesMeetCode: false) == "Point (2)"
                        && Document.title("Google Meet · ABC-DEFG-HIJ", meetCode: nil, includesMeetCode: false) == "Google Meet",
                     "a code between brackets leaves no empty brackets behind")
    }

    private static func leftovers(_ suite: TestSuite) {
        typealias Leftovers = ForkMeetingLeftovers
        let prefix = "fork.meetings.webhook-"
        let now = Date()
        let mine = Leftovers.name(prefix, pid: 4242)
        suite.expect(mine.hasPrefix("fork.meetings.webhook-4242-"), "a leftover is named with its process")
        suite.expect(Leftovers.removable(mine, prefix: prefix, pid: 4242, modified: now, now: now)
                        && !Leftovers.removable(mine, prefix: prefix, pid: 4243, modified: now, now: now)
                        && Leftovers.removable(mine, prefix: prefix, pid: 4243, modified: now.addingTimeInterval(-25 * 3600), now: now)
                        && !Leftovers.removable(mine, prefix: prefix, pid: 4243, modified: nil, now: now),
                     "only this process's own, or one more than a day old, is removed")
        suite.expect(!Leftovers.removable("fork.meetings.webhook-42424-x", prefix: prefix, pid: 4242, modified: now, now: now)
                        && !Leftovers.removable("other-4242-x", prefix: prefix, pid: 4242, modified: .distantPast, now: now),
                     "another process's number, or another prefix, is never taken for ours")
    }

    private static func listStates(_ suite: TestSuite) {
        typealias List = ForkMeetingExporterList
        let stored = List.encode([ForkMeetingExporterConfig(id: "d", kind: .dropFolder, folder: "/Volumes/NAS")])
        suite.expect(List.state(stored, fingerprint: List.fingerprint(stored), keychainFailed: false) == .matches
                        && List.state(stored, fingerprint: "00", keychainFailed: false) == .changed
                        && List.state(stored, fingerprint: nil, keychainFailed: false) == .unconfirmed
                        && List.state(stored, fingerprint: nil, keychainFailed: true) == .keychainRefused
                        && List.state("", fingerprint: nil, keychainFailed: true) == .matches,
                     "the page tells a list changed from one never confirmed, and from a Keychain that refused")
    }

    private static func legacySecrets(_ suite: TestSuite) {
        let configs = [ForkMeetingExporterConfig(id: "a", kind: .webhook, address: "https://h.example/a", origin: "h.example"),
                       ForkMeetingExporterConfig(id: "b", kind: .webhook, address: "https://h.example/b", origin: "h.example"),
                       ForkMeetingExporterConfig(id: "c", kind: .webhook, address: "https://k.example:8443/c", origin: "k.example:8443"),
                       ForkMeetingExporterConfig(id: "d", kind: .dropFolder, folder: "/tmp"),
                       ForkMeetingExporterConfig(id: "e", kind: .webhook)]
        let moves = ForkMeetingExporterList.legacyMoves(configs)
        suite.expect(moves.map(\.from) == ["webhook@h.example", "webhook@k.example:8443"]
                        && moves.map(\.to) == ["webhook@h.example#a", "webhook@k.example:8443#c"],
                     "an earlier version's secret goes to the first webhook of its host, once")
    }

    private static func secondTexts(_ suite: TestSuite) {
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            let distinct = Set([strings.exportsListChanged, strings.exportsListUnconfirmed, strings.exportsListKeychainRefused,
                                strings.exportFailListUnconfirmed])
            suite.expect(distinct.count == 4 && !strings.exportFailListUnconfirmed.contains("Vorssaint"),
                         "\(language.rawValue): a list never confirmed, or refused by the Keychain, is not said changed outside")
            suite.expect(!strings.renameAfterExport.isEmpty && !strings.exportFailDropFolderFull.isEmpty
                            && strings.exportFailDropFolderFull != strings.exportFailTemporarySpace,
                         "\(language.rawValue): the drop folder's disk full is not this Mac's")
        }
        let english = ForkMeetingStrings.strings(.enUS), french = ForkMeetingStrings.strings(.fr)
        suite.expect(english.exportsCaption.contains("history of the exports") && french.exportsCaption.contains("l’historique des exports")
                        && english.exportsCaption.contains("without the Google Meet code unless meetCode"),
                     "the page says the title leaves without the code, and that the history never leaves")
        suite.expect(english.webhookHelpCaption.hasSuffix("and one whose signature you already received: a meeting sent again has a new one.")
                        && french.webhookHelpCaption.hasSuffix("et celle dont vous avez déjà reçu la signature\u{00A0}: une réunion renvoyée en a une nouvelle.")
                        && french.webhookHelpCaption.contains("2\u{00A0}h\u{00A0}05")
                        && ForkMeetingStrings.strings(.de).webhookHelpCaption.contains("um mehr als 2 Std. 05 Min. danebenliegt"),
                     "the help says to refuse a signature already received, in the reviewer's words")
        suite.expect(ForkMeetingStrings.strings(.uk).exportIncludeNotes == "Включати нотатки"
                        && ForkMeetingStrings.strings(.zhHans).exportIncludeNotes == "包含备注"
                        && ForkMeetingStrings.strings(.zhHK).exportIncludeNotes == "包含備註",
                     "the notes' toggle reads as the others")
        let hk = ForkMeetingStrings.strings(.zhHK)
        suite.expect(![hk.noticeDiscardKept, hk.noticeDiscardKeptDetail, hk.voiceDiscardedDeleted, hk.voiceDiscardKept]
                        .contains { $0.contains("檔案夾") },
                     "Hong Kong's Chinese says 資料夾 throughout")
    }
}
