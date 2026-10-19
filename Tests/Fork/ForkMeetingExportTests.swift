// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the exports promise: a meeting leaves the Mac only for the origin
/// the person saved, signed so the receiver can tell it from a forgery; a
/// drop folder never sees half a meeting; a meeting that did not end well is
/// never sent on its own; and nothing secret is ever in the preferences or
/// the backup.
enum ForkMeetingExportTests {
    static func run(_ suite: TestSuite) {
        signature(suite)
        originPolicy(suite)
        ports(suite)
        hosts(suite)
        multipart(suite)
        payload(suite)
        eligibility(suite)
        settingsJSON(suite)
        nothingSecret(suite)
        history(suite)
        dropFolder(suite)
        transcript(suite)
        texts(suite)
    }

    // MARK: - Signature

    /// Every expected value below was computed outside the app, with
    /// `printf '%s' "<timestamp>.<body>" | openssl dgst -sha256 -hmac '<secret>'`.
    private static func signature(_ suite: TestSuite) {
        suite.expect(ForkWebhookSigner.signature(secret: Data("whsec_test".utf8), timestamp: "1700000000",
                                                 body: Data("{\"title\":\"Point hebdo\"}".utf8))
                        == "sha256=bf98163c8deb0cfadb86a4c2bc1d744e739a96ee57a5e631a7ce84b1c7e218b4",
                     "the signature is the hex HMAC-SHA256 of the timestamp, a dot and the body, as openssl computes it")
        suite.expect(ForkWebhookSigner.signature(secret: Data("é-secret".utf8), timestamp: "1760868000", body: Data())
                        == "sha256=59666d7d4a5aaedc68d0bbf730cfd393cae48f636aa2cc28aa99ec4a8bbdf114",
                     "a secret outside ASCII is keyed by its UTF-8 bytes, and an empty body still signs the timestamp")
        let body = Data("\r\n--b\r\n".utf8)
        suite.expect(ForkWebhookSigner.signature(secret: Data("k".utf8), timestamp: "1700000000", body: body)
                        == "sha256=0ff5a2d2652640f4b4e78a7030369317df25bc3669dbafb5e68d17b8f53e0f94",
                     "line breaks and dashes in the body are signed as they are")
        var pieces = ForkWebhookSigner(secret: Data("k".utf8), timestamp: "1700000000")
        for byte in body { pieces.update(Data([byte])) }
        suite.expect(pieces.signature() == "sha256=0ff5a2d2652640f4b4e78a7030369317df25bc3669dbafb5e68d17b8f53e0f94",
                     "a body signed byte by byte, as it is written, gives the signature of the whole")
        let secret = Data("whsec_test".utf8), ts = "1700000000", json = Data("{\"title\":\"Point hebdo\"}".utf8)
        let good = ForkWebhookSigner.signature(secret: secret, timestamp: ts, body: json)
        suite.expect(ForkWebhookSigner.verifies(secret: secret, timestamp: ts, body: json, signature: good),
                     "a receiver with the secret accepts the request as sent")
        var changed = json
        changed[changed.startIndex + 2] ^= 0x01
        suite.expect(!ForkWebhookSigner.verifies(secret: secret, timestamp: ts, body: changed, signature: good)
                        && !ForkWebhookSigner.verifies(secret: secret, timestamp: "1700000001", body: json, signature: good)
                        && !ForkWebhookSigner.verifies(secret: Data("other".utf8), timestamp: ts, body: json, signature: good)
                        && !ForkWebhookSigner.verifies(secret: secret, timestamp: ts, body: json,
                                                       signature: String(good.dropFirst(ForkWebhookSigner.prefix.count)))
                        && !ForkWebhookSigner.verifies(secret: secret, timestamp: ts, body: json, signature: good + "0"),
                     "one bit of the body, the timestamp, another secret or a cut signature: refused")
        suite.expect(ForkWebhookSigner.timestamp(Date(timeIntervalSince1970: 1_700_000_000.9)) == "1700000000",
                     "the timestamp is whole Unix seconds")
        suite.expect(ForkWebhookLimits.resourceTimeout(bodyBytes: 0) == 120
                        && ForkWebhookLimits.resourceTimeout(bodyBytes: 40_000_000) == 2000
                        && ForkWebhookLimits.resourceTimeout(bodyBytes: 10_000_000_000) == 7200,
                     "a send is bounded: two minutes at least, about 20 kB/s, two hours at most")
    }

    // MARK: - Origin policy

    /// The hostile inputs of the policy this one was ported from, run
    /// against any approved host: a service name is a parameter here.
    private static func originPolicy(_ suite: TestSuite) {
        let cases: [(host: String, lookalike: String)] = [
            ("hooks.example.org", "evilexample.org"),
            ("n8n.home.example.net", "n8n.home.example.net.attacker.fr"),
            ("hook.eu1.example.com", "hook-eu1.example.com"),
        ]
        for (host, lookalike) in cases {
            let rules: [ForkMeetingOriginPolicy.Rule] = [.exactly(.init(host: host))]
            func verdict(_ text: String) -> ForkMeetingOriginPolicy.Verdict {
                ForkMeetingOriginPolicy.destination(text, within: rules)
            }
            suite.expect(verdict("http://\(host)/webhook").refusal == .notHTTPS(scheme: "http"),
                         "\(host): the same address in plain HTTP is refused, the audio would travel readable")
            suite.expect(verdict("http://100.64.3.7/upload").refusal == .notHTTPS(scheme: "http"),
                         "\(host): a plain upload to a local network address is refused")
            suite.expect(verdict("https://collecte.example/storage/v1/object/upload").refusal == .unapprovedHost("collecte.example"),
                         "\(host): a third party over HTTPS is refused, whatever its path")
            suite.expect(verdict("https://\(host)/webhook/abc?token=eyJhbGciOi").url != nil,
                         "\(host): the approved host is accepted, query included")
            suite.expect(verdict("https://\(lookalike)/webhook").refusal == .unapprovedHost(lookalike),
                         "\(host): a host that looks like it (\(lookalike)) is refused")
            suite.expect(verdict("https://\(host).attacker.fr/x").refusal == .unapprovedHost("\(host).attacker.fr"),
                         "\(host): the approved host as a prefix of another is refused")
            suite.expect(verdict("https://sub.\(host)/x").refusal == .unapprovedHost("sub.\(host)")
                            && ForkMeetingOriginPolicy.destination("https://sub.\(host)/x", within: [.domain(host)]).url != nil
                            && ForkMeetingOriginPolicy.destination("https://x\(host)/x", within: [.domain(host)]).url == nil,
                         "\(host): a subdomain passes only a domain rule, and a bare suffix never")
            let parent = host.split(separator: ".").dropFirst().joined(separator: ".")
            suite.expect(verdict("https://\(parent)/x").refusal == .unapprovedHost(parent),
                         "\(host): the bare parent domain is refused")
            suite.expect(verdict("https://voleur@\(host)/x").refusal == .credentialsInURL
                            && verdict("https://a:b@\(host)/x").refusal == .credentialsInURL,
                         "\(host): a user or a password slipped into the address gets it refused")
            suite.expect(verdict("https://\(host)/x#frag").refusal == .fragmentInURL,
                         "\(host): a fragment gets the address refused")
            suite.expect(verdict(host).refusal == .unreadable && verdict("").refusal == .unreadable
                            && verdict("https:///x").refusal == .unreadable,
                         "\(host): an address without a scheme or a host is refused rather than guessed")
            suite.expect(verdict("  https://\(host)/webhook  ").url?.absoluteString == "https://\(host)/webhook",
                         "\(host): spaces around an address are not part of it")
            let origin = URL(string: "https://\(host)/webhook")!
            suite.expect(!ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: URL(string: "https://collecte.example/upload")!),
                         "\(host): a redirection to another host is not followed")
            suite.expect(ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: URL(string: "https://\(host)/v2/webhook")!)
                            && ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: URL(string: "https://\(host.uppercased())/v2")!),
                         "\(host): a redirection on the same host, in any case, may be followed")
            suite.expect(!ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: URL(string: "http://\(host)/webhook")!),
                         "\(host): a redirection back to plain HTTP is not followed")
            suite.expect(!ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: URL(string: "https://\(host):8443/webhook")!),
                         "\(host): a redirection to another port of the same host is not followed")
            suite.expect(!ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: URL(string: "https://\(lookalike)/webhook")!),
                         "\(host): a redirection to a lookalike is not followed")
            suite.expect(ForkMeetingOriginPolicy.destination("https://\(host)/w", frozen: .init(host: host)).url != nil
                            && ForkMeetingOriginPolicy.destination("https://collecteur.example/w", frozen: .init(host: host)).refusal
                                == .unapprovedHost("collecteur.example"),
                         "\(host): an address rewritten in the preferences no longer reaches the frozen origin")
        }
        let refusals: [ForkMeetingOriginPolicy.Refusal] = [.unreadable, .notHTTPS(scheme: "http"), .credentialsInURL,
                                                           .fragmentInURL, .nonASCIIHost(wire: "xn--bcher-kva.example"),
                                                           .unapprovedHost("collecte.example")]
        var silent: [String] = []
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            let messages = refusals.map { $0.message(strings) }
            if messages.contains(where: \.isEmpty) || Set(messages).count != messages.count { silent.append(language.rawValue) }
        }
        suite.expect(silent.isEmpty, "every refusal says, in every language, a sentence of its own: \(silent)")
        suite.expect(ForkMeetingOriginPolicy.Refusal.nonASCIIHost(wire: "xn--bcher-kva.example")
                        .message(.strings(.enUS)).contains("xn--bcher-kva.example"),
                     "a host outside ASCII is refused with the form it would really reach")
    }

    private static func ports(_ suite: TestSuite) {
        typealias Policy = ForkMeetingOriginPolicy
        suite.expect(Policy.destination("https://hooks.example.org:443/w").origin == Policy.destination("https://hooks.example.org/w").origin
                        && Policy.destination("https://hooks.example.org/w").origin?.name == "hooks.example.org",
                     "HTTPS's own port is the same origin as none")
        let other = Policy.destination("https://hooks.example.org:8443/w").origin
        suite.expect(other?.name == "hooks.example.org:8443" && other != Policy.destination("https://hooks.example.org/w").origin,
                     "another port is another origin, named with its port")
        suite.expect(Policy.destination("https://hooks.example.org:8443/w", frozen: .init(host: "hooks.example.org")).refusal
                        == .unapprovedHost("hooks.example.org:8443"),
                     "an address moved to another port of the frozen host is refused")
        suite.expect(Policy.destination("https://hooks.example.org:0/w").refusal == .unreadable,
                     "a port no connection can use is refused")
        suite.expect(Policy.Origin(name: "hooks.example.org:8443") == .init(host: "hooks.example.org", port: 8443)
                        && Policy.Origin(name: "hooks.example.org") == .init(host: "hooks.example.org")
                        && Policy.Origin(name: "[::1]:8443") == .init(host: "::1", port: 8443)
                        && Policy.Origin(name: "hooks.example.org/x") == nil && Policy.Origin(name: "") == nil,
                     "a frozen origin reads back exactly as it was written, and nothing else does")
        let v6 = Policy.destination("https://[::1]:8443/hook")
        suite.expect(v6.origin?.name == "[::1]:8443", "an IPv6 literal is an origin with its brackets")
        let plain = ForkMeetingExporterConfig(kind: .webhook, origin: "hooks.example.org")
        let ported = ForkMeetingExporterConfig(kind: .webhook, origin: "hooks.example.org:8443")
        suite.expect(plain.secretAccount == "webhook@hooks.example.org" && ported.secretAccount == "webhook@hooks.example.org:8443",
                     "each origin has its own secret account, port included")
    }

    /// A host in another script can pass for a known one (`аpple.com`, with
    /// a Cyrillic `а`): only ASCII is taken, and the refusal shows what it
    /// would really reach.
    private static func hosts(_ suite: TestSuite) {
        typealias Policy = ForkMeetingOriginPolicy
        suite.expect(Policy.destination("https://bücher.example/w").refusal == .nonASCIIHost(wire: "xn--bcher-kva.example"),
                     "a host with letters outside ASCII is refused, with its xn-- form")
        suite.expect(Policy.destination("https://\u{0430}pple.com/").refusal == .nonASCIIHost(wire: "xn--pple-43d.com"),
                     "a Cyrillic lookalike is refused and shown as the other host it is")
        suite.expect(Policy.destination("https://xn--bcher-kva.example/w").origin?.name == "xn--bcher-kva.example",
                     "the xn-- form typed knowingly is accepted")
        suite.expect(Policy.destination("https://example.com%2F.evil.com/").refusal != nil
                        && Policy.destination("https://%65xample.com/").refusal != nil,
                     "a host with escapes is refused: it is not the host it reads as")
        suite.expect(Policy.destination("https://Hooks.Example.ORG./w").origin == .init(host: "hooks.example.org"),
                     "case and a final dot do not make another origin")
    }

    // MARK: - Multipart

    private static func temporary(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorss.tests.fork.export-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func multipart(_ suite: TestSuite) {
        typealias Multipart = ForkWebhookMultipart
        let injected = Multipart.Part(name: "audio", filename: "a.m4a\"\r\nX-Evil: 1", contentType: "audio/mp4\r\nX-Evil: 2",
                                      source: .data(Data()))
        let headers = Multipart.headers(of: injected)
        suite.expect(headers.components(separatedBy: "\r\n").count == 4 && !headers.contains("\r\nX-Evil")
                        && headers.hasSuffix("\r\n\r\n") && headers.contains("filename=\"a.m4a%22%0D%0AX-Evil: 1\""),
                     "a name with quotes and line breaks stays inside its header: escaped, never a new header")
        suite.expect(Multipart.quoted("a\\b\"c") == "\"a%5Cb%22c\"", "backslashes and quotes cannot end a quoted name")
        let accented = Multipart.headers(of: .init(name: "audio", filename: "Réunion — été.m4a", contentType: "audio/mp4",
                                                    source: .data(Data())))
        suite.expect(accented.contains("filename=\"Réunion — été.m4a\"") && !accented.contains("filename*"),
                     "a name outside ASCII goes in UTF-8, as browsers send it, without the filename* RFC 7578 forbids")
        let plain = Multipart.headers(of: .init(name: "meeting", filename: "meeting.json", contentType: "application/json",
                                                 source: .data(Data())))
        suite.expect(plain == "Content-Disposition: form-data; name=\"meeting\"; filename=\"meeting.json\"\r\nContent-Type: application/json\r\n\r\n",
                     "a plain part's headers are the usual two")

        let folder = temporary("multipart")
        defer { try? FileManager.default.removeItem(at: folder) }
        var audioBytes = Data((0..<(Multipart.chunkSize + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        audioBytes.append(contentsOf: Array("\r\n--not-the-boundary\r\n".utf8))
        let audio = folder.appendingPathComponent("audio.m4a")
        try? audioBytes.write(to: audio)
        var body = Multipart(boundary: "swishsaint-test-boundary")
        body.parts = [
            .init(name: "meeting", filename: "meeting.json", contentType: "application/json", source: .data(Data("{\"a\":1}".utf8))),
            .init(name: "audio", filename: "x.m4a", contentType: "audio/mp4", source: .file(audio)),
            .init(name: "transcript", filename: "x.txt", contentType: "text/plain; charset=utf-8", source: .data(Data("Bonjour".utf8))),
        ]
        let out = folder.appendingPathComponent("body")
        var signer = ForkWebhookSigner(secret: Data("k".utf8), timestamp: "1700000000")
        var sunk = Data()
        let length = (try? body.write(to: out) { signer.update($0); sunk.append($0) }) ?? -1
        let written = (try? Data(contentsOf: out)) ?? Data()
        suite.expect(length == Int64(written.count) && sunk == written,
                     "every byte written goes through the signer, in order, and the length is the file's")
        suite.expect(signer.signature() == ForkWebhookSigner.signature(secret: Data("k".utf8), timestamp: "1700000000", body: written),
                     "the signature computed while writing is the one of the body sent")
        let marker = Data("--swishsaint-test-boundary".utf8)
        var count = 0, from = written.startIndex
        while let range = written.range(of: marker, in: from..<written.endIndex) { count += 1; from = range.upperBound }
        suite.expect(count == 4 && written.starts(with: Data("--swishsaint-test-boundary\r\n".utf8))
                        && written.suffix(30) == Data("\r\n--swishsaint-test-boundary--\r\n".utf8).suffix(30),
                     "three parts, four boundaries, the closing one last")
        let text = String(decoding: written, as: UTF8.self)
        let order = ["name=\"meeting\"", "name=\"audio\"", "name=\"transcript\""].compactMap { text.range(of: $0)?.lowerBound }
        suite.expect(order.count == 3 && order == order.sorted(), "the parts come in order: meeting, audio, transcript")
        suite.expect(written.range(of: audioBytes) != nil, "the audio, over a megabyte, arrives whole, byte for byte")
        var hostile = Multipart(boundary: "b0undary")
        hostile.parts = [.init(name: "meeting", filename: nil, contentType: "text/plain", source: .data(Data("x--b0undary".utf8)))]
        var threw = false
        do { try hostile.write(to: folder.appendingPathComponent("hostile")) { _ in } } catch { threw = (error as? Multipart.Failure) == .boundaryInPart }
        suite.expect(threw, "a text part that holds the boundary is refused rather than sent cut in two")
        suite.expect(Multipart().boundary != Multipart().boundary && Multipart().boundary.count >= 40
                        && Multipart().contentType.hasPrefix("multipart/form-data; boundary=swishsaint-"),
                     "each body has its own random boundary, in its content type")
    }

    // MARK: - What leaves the Mac

    private static let meetingID = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8")!
    private static let start = Date(timeIntervalSince1970: 1_792_310_531)

    private static func meeting(state: ForkMeetingSidecar.State = .complete, recovered: Bool = false,
                                stop: ForkMeetingStopReason = .user, id: UUID = meetingID) -> ForkMeetingSidecar {
        var sidecar = ForkMeetingSidecar.started(id: id, startedAt: start, origin: .offered, title: "Point hebdo",
                                                 titleSource: .user,
                                                 capture: .init(target: .window, systemAudio: .app, microphone: "Micro",
                                                                quality: .standard),
                                                 provider: "meet", meetCode: "abc-defg-hij", app: "com.google.Chrome")
        sidecar.state = state
        sidecar.recovered = recovered
        sidecar.stopReason = stop
        sidecar.notes = "Budget validé"
        sidecar.exports = [ForkMeetingSidecar.Export(exporter: "webhook", at: start, status: "done", target: "x")]
        return sidecar
    }

    private static func payload(_ suite: TestSuite) {
        let shared = (try? ForkMeetingExportDocument.json(meeting(), includesMeetCode: false)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        suite.expect(!shared.contains("abc-defg-hij") && !shared.contains("meetCode") && !shared.contains("\"exports\"")
                        && shared.contains("Point hebdo") && shared.contains("Budget validé"),
                     "the meeting.json sent has no Meet code and no export history by default, and keeps the rest")
        let withCode = (try? ForkMeetingExportDocument.json(meeting(), includesMeetCode: true)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        suite.expect(withCode.contains("\"meetCode\" : \"abc-defg-hij\""), "the Meet code goes only when asked")
        let audio = URL(fileURLWithPath: "/tmp/a.m4a"), text = URL(fileURLWithPath: "/tmp/a.txt")
        let package = ForkMeetingExportPackage(folderName: "2026-10-18 10h02 — Point hebdo", sidecar: meeting(), audio: audio, transcript: text)
        let parts = (try? ForkWebhookPayload.parts(package, includesMeetCode: false)) ?? []
        suite.expect(parts.map(\.name) == ["meeting", "audio", "transcript"]
                        && parts.map(\.filename) == ["meeting.json", "2026-10-18 10h02 — Point hebdo.m4a", "2026-10-18 10h02 — Point hebdo.txt"]
                        && parts.map(\.contentType) == ["application/json", "audio/mp4", "text/plain; charset=utf-8"],
                     "a webhook gets the parts meeting, audio and transcript, named after the meeting")
        let alone = ForkMeetingExportPackage(folderName: "x", sidecar: meeting(), audio: audio, transcript: nil)
        suite.expect(((try? ForkWebhookPayload.parts(alone, includesMeetCode: false)) ?? []).map(\.name) == ["meeting", "audio"],
                     "without a transcript, no transcript part")
        let test = ForkWebhookPayload.testParts(at: start)
        if case let .data(data)? = test.first?.source {
            let json = String(decoding: data, as: UTF8.self)
            suite.expect(test.count == 1 && json.contains("\"test\":true") && json.contains("\"schema\":1"),
                         "the page's test is a meeting part saying it is a test, without audio")
        } else {
            suite.expect(false, "the page's test is a meeting part saying it is a test, without audio")
        }
    }

    // MARK: - Eligibility

    private static func eligibility(_ suite: TestSuite) {
        typealias Eligibility = ForkMeetingExportEligibility
        func both(_ sidecar: ForkMeetingSidecar, live: Bool = false, target: String? = "t") -> (Eligibility.Verdict, Eligibility.Verdict) {
            (Eligibility.verdict(.success(sidecar), live: live, automatic: true, target: target),
             Eligibility.verdict(.success(sidecar), live: live, automatic: false, target: target))
        }
        suite.expect(both(meeting()) == (.allowed, .allowed), "a meeting that ended well goes on its own and with a click")
        suite.expect(both(meeting(stop: .meetingEnded)) == (.allowed, .allowed), "a meeting the app saw end goes on its own")
        suite.expect(both(meeting(recovered: true)) == (.needsClick, .allowed), "a recovered meeting goes only with a click")
        suite.expect(both(meeting(state: .interrupted, stop: .crash)) == (.needsClick, .allowed),
                     "an interrupted meeting goes only with a click")
        suite.expect(both(meeting(stop: .cancelled)) == (.needsClick, .allowed) && both(meeting(stop: .quit)) == (.needsClick, .allowed),
                     "a cancelled meeting, or one stopped by a quit, goes only with a click")
        var failedPass = meeting()
        failedPass.finalPass = .failed
        suite.expect(both(failedPass).0 == .needsClick, "a meeting whose final pass failed is not sent on its own")
        suite.expect(both(meeting(state: .recording)) == (.refused(.inProgress), .refused(.inProgress))
                        && both(meeting(state: .finalizing)) == (.refused(.inProgress), .refused(.inProgress))
                        && both(meeting(), live: true) == (.refused(.inProgress), .refused(.inProgress)),
                     "a meeting being recorded or finished is never sent, even with a click")
        suite.expect(Eligibility.verdict(.failure(.corrupt("x")), live: false, automatic: false) == .refused(.unreadable),
                     "a meeting.json that cannot be read is not sent: its history could not be written")
        var later = meeting()
        later.schema = ForkMeetingSidecar.currentSchema + 1
        suite.expect(both(later) == (.refused(.unreadable), .refused(.unreadable)),
                     "a meeting.json of a later version is never rewritten, so not exported from here")
        var sent = meeting()
        sent.exports = [ForkMeetingHistoryFixture.done("t")]
        suite.expect(both(sent) == (.needsClick, .allowed), "a meeting already sent there goes again only with a click")
        sent.exports = [ForkMeetingHistoryFixture.done("t"), ForkMeetingHistoryFixture.failed("t")]
        suite.expect(both(sent).0 == .allowed, "a meeting whose last send there failed may go again")
        suite.expect(both(sent, target: "other").0 == .allowed && both(meeting(), target: nil).0 == .allowed,
                     "what went to one exporter does not count for another")
    }

    // MARK: - Settings

    private static func settingsJSON(_ suite: TestSuite) {
        typealias List = ForkMeetingExporterList
        suite.expect(List.decode(nil).isEmpty && List.decode("").isEmpty && List.decode("garbage").isEmpty
                        && List.decode("{\"kind\":\"webhook\"}").isEmpty && List.decode("[1, null]").isEmpty,
                     "a missing or corrupt setting is no exporter at all, never a crash")
        let mixed = List.decode("""
        [{"id":"a","kind":"dropFolder","folder":"~/Dépôt","mode":"automatic","future":true},
         {"id":"b","kind":"carrierPigeon"},
         {"kind":"webhook","address":"https://hooks.example.org/w","origin":"hooks.example.org","mode":"sometimes"},
         {"id":"a","kind":"webhook"}]
        """)
        suite.expect(mixed.count == 2 && mixed[0].id == "a" && mixed[0].mode == .automatic && mixed[0].folder == "~/Dépôt"
                        && mixed[1].kind == .webhook && mixed[1].mode == .manual && !mixed[1].id.isEmpty
                        && mixed[1].includesMeetCode == false,
                     "an unknown kind or a repeated id is skipped, an unknown mode is manual, a missing id is made")
        let configs = [ForkMeetingExporterConfig(id: "d", kind: .dropFolder, mode: .automatic, includesMeetCode: true, folder: "/Volumes/NAS/Réunions"),
                       ForkMeetingExporterConfig(id: "w", kind: .webhook, address: "https://hooks.example.org/w", origin: "hooks.example.org")]
        suite.expect(List.decode(List.encode(configs)) == configs, "the exporters read back as they were saved")
        suite.expect(List.encode([]) == "", "no exporter is the empty setting")
        suite.expect(configs[0].secretAccount == nil && ForkMeetingExporterConfig(kind: .webhook).secretAccount == nil,
                     "only a webhook with a frozen origin has a secret account")
        suite.expect(configs[0].detail == "Réunions" && configs[1].detail == "hooks.example.org"
                        && configs[1].title(.strings(.fr)) == "Webhook HTTPS — hooks.example.org",
                     "an exporter is named by its kind and its folder or its host")
        suite.expect(ForkDropFolderExporter(config: .init(kind: .dropFolder), libraryRoot: URL(fileURLWithPath: "/tmp")).isConfigured == false
                        && ForkDropFolderExporter(config: configs[0], libraryRoot: URL(fileURLWithPath: "/tmp")).isConfigured,
                     "a drop folder is set up once a folder is chosen")
    }

    /// Nothing secret in the preferences nor the backup: the setting holds
    /// no secret field at all, and stays on this Mac.
    private static func nothingSecret(_ suite: TestSuite) {
        let config = ForkMeetingExporterConfig(id: "w", kind: .webhook, address: "https://hooks.example.org/w", origin: "hooks.example.org")
        let labels = Mirror(reflecting: config).children.compactMap(\.label).map { $0.lowercased() }
        suite.expect(!labels.contains { $0.contains("secret") || $0.contains("token") || $0.contains("password") || $0.contains("key") },
                     "an exporter's settings have no field for a secret: \(labels)")
        let stored = ForkMeetingExporterList.encode([config])
        let keys = (try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [[String: Any]])?.first.map { Set($0.keys) }
        suite.expect(keys == ["id", "kind", "mode", "includesMeetCode", "address", "origin"],
                     "the setting written holds the address and its origin, nothing else: \(keys ?? [])")
        suite.expect(ForkDefaultsKey.meetingsExporters == "fork.meetings.exporters"
                        && !ForkDefaults.backupKeys.contains(ForkDefaultsKey.meetingsExporters)
                        && ForkDefaults.registered[ForkDefaultsKey.meetingsExporters] == nil,
                     "the exporters stay on this Mac: never registered, never in the backup")
        suite.expect(!ForkDefaults.backupKeys.contains { $0.lowercased().contains("secret") || $0.lowercased().contains("token") },
                     "no setting in the backup is named for a secret")
    }

    // MARK: - History

    private static func history(_ suite: TestSuite) {
        typealias History = ForkMeetingExportHistory
        let at = start
        let done = History.record(ForkMeetingExportReceipt(target: "w", kind: .webhook, at: at, httpStatus: 202))
        suite.expect(done == ForkMeetingSidecar.Export(exporter: "webhook", at: at, status: "done", target: "w", httpStatus: 202),
                     "a send done is written with its kind, its exporter, its time and the status the address gave")
        let failed = History.record(.status(500), target: "w", kind: .webhook, at: at.addingTimeInterval(60))
        suite.expect(failed.status == "failed" && failed.reason == "status" && failed.httpStatus == 500,
                     "a failure is written with why")
        let list = [done, ForkMeetingHistoryFixture.done("d"), failed,
                    ForkMeetingSidecar.Export(exporter: "webhook", at: at, status: "queued-by-a-later-version", target: "w")]
        suite.expect(History.lastResult(list, target: "w") == .init(status: .failed, at: at.addingTimeInterval(60), failure: .status(500))
                        && History.lastResult(list, target: "d")?.status == .done
                        && History.lastResult(list, target: "none") == nil,
                     "the latest known attempt of each exporter is what the library shows")
        let failures: [ForkMeetingExportFailure] = [.inProgress, .unreadable, .noAudio, .folderMissing, .folderInsideLibrary,
                                                    .writeFailed, .refusedAddress(.notHTTPS(scheme: nil)), .refusedAddress(.fragmentInURL),
                                                    .originChanged, .noSecret, .redirected, .status(500), .network, .notConfigured]
        suite.expect(failures.allSatisfy { ForkMeetingExportFailure(code: $0.code, httpStatus: $0.httpStatus) == $0 }
                        && Set(failures.map(\.code)).count == failures.count,
                     "every failure reads back from meeting.json as it was written")
        suite.expect(ForkMeetingExportFailure(code: "fromTheFuture", httpStatus: nil) == .network,
                     "a reason this version does not know reads as the vaguest")

        var sidecar = meeting()
        sidecar.exports = []
        var patch = ForkMeetingSidecarPatch()
        patch.export = done
        let once = patch.applied(to: sidecar)
        patch.export = failed
        let twice = patch.applied(to: once)
        suite.expect(once.exports == [done] && twice.exports == [done, failed],
                     "each attempt is appended to meeting.json, in order, never rewritten")
        if case let .success(odd) = ForkMeetingSidecar.decode(Data("{\"schema\":1,\"exports\":\"not a list\"}".utf8)) {
            suite.expect(patch.applied(to: odd).exports == nil && odd.preserved["exports"] == .string("not a list"),
                         "an exports list this version cannot read is kept as it was, never replaced")
        } else {
            suite.expect(false, "an exports list this version cannot read is kept as it was, never replaced")
        }
        let json = "{\"schema\":1,\"exports\":[{\"exporter\":\"webhook\",\"status\":\"done\",\"target\":\"w\",\"httpStatus\":200,\"via\":\"relay\"}]}"
        if case let .success(read) = ForkMeetingSidecar.decode(Data(json.utf8)), let export = read.exports?.first {
            let back = (try? read.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            suite.expect(export.target == "w" && export.httpStatus == 200 && back.contains("\"via\" : \"relay\""),
                         "an export record keeps its fields, and those a later version adds")
        } else {
            suite.expect(false, "an export record keeps its fields, and those a later version adds")
        }
    }

    // MARK: - Drop folder

    private static func dropFolder(_ suite: TestSuite) {
        let manager = FileManager.default
        let base = temporary("drop")
        defer { try? manager.removeItem(at: base) }
        let library = base.appendingPathComponent("Réunions", isDirectory: true)
        let name = "2026-10-18 10h02 — Point hebdo"
        let source = library.appendingPathComponent(name, isDirectory: true)
        let drop = base.appendingPathComponent("NAS", isDirectory: true)
        try? manager.createDirectory(at: source, withIntermediateDirectories: true)
        try? manager.createDirectory(at: drop, withIntermediateDirectories: true)
        let audio = source.appendingPathComponent("\(name).m4a")
        let transcript = source.appendingPathComponent("\(name).txt")
        try? Data("first audio".utf8).write(to: audio)
        try? Data("Bonjour à tous".utf8).write(to: transcript)
        let package = ForkMeetingExportPackage(folderName: name, sidecar: meeting(), audio: audio, transcript: transcript)
        let exporter = ForkDropFolderExporter(config: .init(id: "d", kind: .dropFolder, folder: drop.path), libraryRoot: library)

        var thrown: ForkMeetingExportFailure?
        func attempt(_ exporter: ForkDropFolderExporter, _ package: ForkMeetingExportPackage, into folder: URL) -> Bool {
            thrown = nil
            do { try exporter.copy(package, into: folder); return true } catch {
                thrown = error as? ForkMeetingExportFailure
                return false
            }
        }
        let copied = drop.appendingPathComponent(name, isDirectory: true)
        suite.expect(attempt(exporter, package, into: drop), "a meeting is copied into the drop folder")
        let names = Set((try? manager.contentsOfDirectory(atPath: copied.path)) ?? [])
        suite.expect(names == ["\(name).m4a", "meeting.json", "\(name).txt"],
                     "the drop folder gets the meeting's folder with its audio, meeting.json and transcript: \(names)")
        let json = (try? String(contentsOf: copied.appendingPathComponent("meeting.json"), encoding: .utf8)) ?? ""
        suite.expect(!json.contains("abc-defg-hij") && json.contains("Point hebdo"), "the copied meeting.json has no Meet code")
        suite.expect(((try? manager.contentsOfDirectory(atPath: drop.path)) ?? []) == [name],
                     "no draft is left beside the copy")

        try? Data("second audio".utf8).write(to: audio)
        suite.expect(attempt(exporter, package, into: drop)
                        && (try? Data(contentsOf: copied.appendingPathComponent("\(name).m4a"))) == Data("second audio".utf8)
                        && ((try? manager.contentsOfDirectory(atPath: drop.path)) ?? []) == [name],
                     "the same meeting sent again replaces its copy, in place")
        let other = ForkMeetingExportPackage(folderName: name, sidecar: meeting(id: UUID()), audio: audio, transcript: nil)
        suite.expect(attempt(exporter, other, into: drop)
                        && manager.fileExists(atPath: drop.appendingPathComponent("\(name) (2)/\(name).m4a").path)
                        && !manager.fileExists(atPath: drop.appendingPathComponent("\(name) (2)/\(name).txt").path),
                     "another meeting of the same name gets (2), and no transcript when it has none")

        let coded = ForkDropFolderExporter(config: .init(id: "c", kind: .dropFolder, includesMeetCode: true, folder: drop.path),
                                           libraryRoot: library)
        let codedDrop = base.appendingPathComponent("Coded", isDirectory: true)
        try? manager.createDirectory(at: codedDrop, withIntermediateDirectories: true)
        _ = attempt(coded, package, into: codedDrop)
        let codedJSON = (try? String(contentsOf: codedDrop.appendingPathComponent("\(name)/meeting.json"), encoding: .utf8)) ?? ""
        suite.expect(codedJSON.contains("abc-defg-hij"), "the Meet code is copied only when asked")

        let unmounted = base.appendingPathComponent("Volumes/NAS", isDirectory: true)
        suite.expect(!attempt(exporter, package, into: unmounted) && thrown == .folderMissing
                        && !manager.fileExists(atPath: unmounted.path),
                     "a drop folder that is not there is never made: an unmounted disk does not fill the startup disk")
        suite.expect(!attempt(exporter, package, into: library) && thrown == .folderInsideLibrary
                        && !attempt(exporter, package, into: source) && thrown == .folderInsideLibrary
                        && ForkDropFolderExporter.isInsideLibrary(source, libraryRoot: library)
                        && !ForkDropFolderExporter.isInsideLibrary(base.appendingPathComponent("Réunions 2"), libraryRoot: library),
                     "the meetings folder, or a folder inside it, is refused as a drop folder; a sibling is not")
        let broken = ForkMeetingExportPackage(folderName: "Gone", sidecar: meeting(), audio: source.appendingPathComponent("missing.m4a"),
                                              transcript: nil)
        let fresh = base.appendingPathComponent("Fresh", isDirectory: true)
        try? manager.createDirectory(at: fresh, withIntermediateDirectories: true)
        suite.expect(!attempt(exporter, broken, into: fresh) && thrown == .writeFailed
                        && ((try? manager.contentsOfDirectory(atPath: fresh.path)) ?? ["?"]).isEmpty,
                     "a copy that fails halfway leaves nothing behind: no draft, no half meeting")
    }

    private static func transcript(_ suite: TestSuite) {
        typealias Document = ForkMeetingExportDocument
        suite.expect(Document.transcript(in: ["a.mp4", "a.txt", "notes.txt", "meeting.json"], folderName: "a") == "a.txt"
                        && Document.transcript(in: ["a.mp4", "Renamed.TXT", ".hidden.txt"], folderName: "a") == "Renamed.TXT"
                        && Document.transcript(in: ["x.txt", "y.txt"], folderName: "a") == nil
                        && Document.transcript(in: ["a.mp4"], folderName: "a") == nil,
                     "the transcript is the .txt named after the folder, else the only one; never a guess between two")
    }

    // MARK: - Texts

    private static func texts(_ suite: TestSuite) {
        let short: [KeyPath<ForkMeetingStrings, String>] = [
            \.exportsTitle, \.exportsAdd, \.exportKindDropFolder, \.exportKindWebhook, \.exportMode, \.exportModeManual,
            \.exportModeAutomatic, \.exportRemove, \.actionExportTo, \.exportSending, \.exportDone, \.exportFailedShort,
            \.exportRetry, \.exportNotYet, \.dropFolderNone, \.dropFolderChoose, \.webhookAddress, \.webhookSecret,
            \.webhookSecretNew, \.webhookSave, \.webhookTest, \.webhookHostChangeConfirm, \.webhookHelpCopy, \.webhookHelpTitle,
        ]
        var tooLong: [String] = []
        var formats: [String] = []
        var silent: [String] = []
        let failures: [ForkMeetingExportFailure] = [.inProgress, .unreadable, .noAudio, .folderMissing, .folderInsideLibrary,
                                                    .writeFailed, .refusedAddress(.fragmentInURL), .originChanged, .noSecret,
                                                    .redirected, .status(500), .network, .notConfigured]
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            for path in short where strings[keyPath: path].count > 28 {
                tooLong.append("\(language.rawValue): \(strings[keyPath: path])")
            }
            if !strings.webhookHost("h.example").contains("h.example") || !strings.webhookHostChange("h.example").contains("h.example")
                || !strings.webhookTestDone(204).contains("204") || !strings.exportFailStatus(503).contains("503")
                || !strings.originNonASCII("xn--a").contains("xn--a") {
                formats.append(language.rawValue)
            }
            let messages = failures.map { $0.message(strings) }
            if messages.contains(where: \.isEmpty) || Set(messages).count != messages.count { silent.append(language.rawValue) }
        }
        suite.expect(tooLong.isEmpty, "every short export text fits in 28 characters: \(tooLong)")
        suite.expect(formats.isEmpty, "every export format fills its host or its status in: \(formats)")
        suite.expect(silent.isEmpty, "every export failure has a sentence of its own, in every language: \(silent)")
        let english = ForkMeetingStrings.strings(.enUS).exportsCaption, french = ForkMeetingStrings.strings(.fr).exportsCaption
        suite.expect(english.contains("leave this Mac") && french.contains("quittent alors ce Mac"),
                     "the page says that the audio and the record leave the Mac for the address chosen")
    }
}

/// Export records for the tests.
enum ForkMeetingHistoryFixture {
    static func done(_ target: String) -> ForkMeetingSidecar.Export {
        ForkMeetingSidecar.Export(exporter: "dropFolder", at: Date(timeIntervalSince1970: 1_792_310_600), status: "done", target: target)
    }

    static func failed(_ target: String) -> ForkMeetingSidecar.Export {
        ForkMeetingSidecar.Export(exporter: "dropFolder", at: Date(timeIntervalSince1970: 1_792_310_700), status: "failed",
                                  target: target, reason: "folderMissing")
    }
}
