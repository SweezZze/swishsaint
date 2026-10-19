// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CryptoKit
import Foundation

/// The webhook's signature: `X-Swishsaint-Signature: sha256=<hex>`, the
/// HMAC-SHA256 of `timestamp + "." + body` keyed with the secret, and
/// `X-Swishsaint-Timestamp`, Unix seconds. The receiver recomputes it over
/// the raw body it got and refuses a request whose signature differs or
/// whose timestamp is old: a copy of a request replayed later fails.
///
/// Computed while the body is written, chunk by chunk: an hour of audio is
/// never held in memory.
struct ForkWebhookSigner {
    static let timestampHeader = "X-Swishsaint-Timestamp"
    static let signatureHeader = "X-Swishsaint-Signature"
    /// `meeting`, or `test` for the page's "Send a test".
    static let eventHeader = "X-Swishsaint-Event"
    static let prefix = "sha256="

    let timestamp: String
    private var hmac: HMAC<SHA256>

    init(secret: Data, timestamp: String) {
        self.timestamp = timestamp
        hmac = HMAC<SHA256>(key: SymmetricKey(data: secret))
        hmac.update(data: Data(timestamp.utf8))
        hmac.update(data: Data(".".utf8))
    }

    init(secret: Data, at date: Date) {
        self.init(secret: secret, timestamp: Self.timestamp(date))
    }

    static func timestamp(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970.rounded(.down))) }

    mutating func update(_ data: Data) { hmac.update(data: data) }

    /// The header's value. The signer is spent: the body is complete.
    func signature() -> String {
        Self.prefix + hmac.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The whole signature of a body already in memory.
    static func signature(secret: Data, timestamp: String, body: Data) -> String {
        var signer = ForkWebhookSigner(secret: secret, timestamp: timestamp)
        signer.update(body)
        return signer.signature()
    }

    /// What a receiver does, here for the tests and the help: the same
    /// signature, compared without stopping at the first difference.
    static func verifies(secret: Data, timestamp: String, body: Data, signature: String) -> Bool {
        let expected = Array(Self.signature(secret: secret, timestamp: timestamp, body: body).utf8)
        let given = Array(signature.utf8)
        guard expected.count == given.count else { return false }
        return zip(expected, given).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// A `multipart/form-data` body, written to a file: its parts' headers by
/// hand, each file part streamed in chunks. Every byte written also goes
/// through `sink` (the signer).
struct ForkWebhookMultipart {
    struct Part {
        enum Source {
            case data(Data)
            case file(URL)
        }

        let name: String
        let filename: String?
        let contentType: String
        let source: Source
    }

    enum Failure: Error, Equatable {
        /// A text part holds the boundary: it would cut the body in two.
        case boundaryInPart
        case unreadable(String)
        case unwritable(String)
    }

    let boundary: String
    var parts: [Part] = []

    static let chunkSize = 1 << 20

    /// A boundary no text of ours can hold by chance: 128 random bits.
    init(boundary: String = "swishsaint-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// The part's headers, written as browsers write them (RFC 7578, and
    /// the HTML standard's form encoding): names in UTF-8 between quotes,
    /// with a quote, a backslash and a line break percent-escaped, so a
    /// meeting called `a"\r\nX-Evil: 1` stays one header. No `filename*`:
    /// RFC 7578 forbids it, and receivers read `filename` first.
    static func headers(of part: Part) -> String {
        var disposition = "Content-Disposition: form-data; name=\(quoted(part.name))"
        if let filename = part.filename { disposition += "; filename=\(quoted(filename))" }
        // By scalar: "\r\n" is a single Character, which a filter on
        // Characters would let through.
        let type = String(String.UnicodeScalarView(part.contentType.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        return disposition + "\r\nContent-Type: \(type)\r\n\r\n"
    }

    /// `"…"`, with what could end the value early escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "%22"
            case "\\": out += "%5C"
            case "\r": out += "%0D"
            case "\n": out += "%0A"
            case "\0": out += "%00"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Writes the whole body to `destination` (made, or emptied), and gives
    /// each byte to `sink` in the order written. Returns its length.
    @discardableResult
    func write(to destination: URL, sink: (Data) -> Void) throws -> Int64 {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        guard manager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw Failure.unwritable(destination.lastPathComponent)
        }
        defer { try? handle.close() }
        var length: Int64 = 0
        func emit(_ data: Data) throws {
            guard !data.isEmpty else { return }
            do { try handle.write(contentsOf: data) } catch { throw Failure.unwritable(error.localizedDescription) }
            sink(data)
            length += Int64(data.count)
        }
        let marker = Data("--\(boundary)".utf8)
        for part in parts {
            if case let .data(data) = part.source, data.range(of: marker) != nil { throw Failure.boundaryInPart }
            try emit(Data("--\(boundary)\r\n".utf8))
            try emit(Data(Self.headers(of: part).utf8))
            switch part.source {
            case let .data(data):
                try emit(data)
            case let .file(url):
                guard let reader = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable(url.lastPathComponent) }
                defer { try? reader.close() }
                while true {
                    let chunk: Data
                    do { chunk = try reader.read(upToCount: Self.chunkSize) ?? Data() } catch {
                        throw Failure.unreadable(error.localizedDescription)
                    }
                    if chunk.isEmpty { break }
                    try emit(chunk)
                }
            }
            try emit(Data("\r\n".utf8))
        }
        try emit(Data("--\(boundary)--\r\n".utf8))
        return length
    }
}

/// What a webhook request is made of, from a meeting's package: the parts,
/// in a fixed order (`meeting`, `audio`, then `transcript`), and the test
/// the page sends.
enum ForkWebhookPayload {
    static let meetingPart = "meeting"
    static let audioPart = "audio"
    static let transcriptPart = "transcript"

    static func parts(_ package: ForkMeetingExportPackage, includesMeetCode: Bool) throws -> [ForkWebhookMultipart.Part] {
        var parts = [
            ForkWebhookMultipart.Part(name: meetingPart, filename: ForkMeetingFolder.sidecarName,
                                      contentType: "application/json",
                                      source: .data(try ForkMeetingExportDocument.json(package.sidecar, includesMeetCode: includesMeetCode))),
            ForkWebhookMultipart.Part(name: audioPart, filename: package.audioName, contentType: "audio/mp4",
                                      source: .file(package.audio)),
        ]
        if let transcript = package.transcript {
            parts.append(ForkWebhookMultipart.Part(name: transcriptPart, filename: package.transcriptName,
                                                   contentType: "text/plain; charset=utf-8", source: .file(transcript)))
        }
        return parts
    }

    /// The page's test: a `meeting` part saying so, no audio.
    static func testParts(at date: Date) -> [ForkWebhookMultipart.Part] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(TestMeeting(startedAt: date))) ?? Data("{\"test\":true}".utf8)
        return [ForkWebhookMultipart.Part(name: meetingPart, filename: ForkMeetingFolder.sidecarName,
                                          contentType: "application/json", source: .data(body))]
    }

    private struct TestMeeting: Encodable {
        let schema = ForkMeetingSidecar.currentSchema
        let test = true
        let title = "Swishsaint test"
        let startedAt: Date
    }

    /// The receiver side, in a few lines, for the page's help.
    static let verificationExample = """
    // n8n "Code" node, or any Node.js server (the raw body, not parsed JSON)
    const crypto = require('crypto');
    const ts = headers['x-swishsaint-timestamp'];
    const expected = 'sha256=' + crypto.createHmac('sha256', SECRET)
      .update(ts + '.').update(rawBody).digest('hex');
    const given = headers['x-swishsaint-signature'] || '';
    const fresh = Math.abs(Date.now() / 1000 - Number(ts)) < 300;
    const ok = fresh && given.length === expected.length
      && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected));

    # Python
    import hmac, hashlib, time
    expected = 'sha256=' + hmac.new(SECRET, ts.encode() + b'.' + raw_body, hashlib.sha256).hexdigest()
    ok = abs(time.time() - int(ts)) < 300 and hmac.compare_digest(expected, given)
    """
}

/// The bounds of one request: a body sent at no less than about 20 kB/s,
/// never past two hours, never under two minutes; a minute without a byte
/// either way is a failure; and an answer read no further than 64 KiB, of
/// which only the status matters.
enum ForkWebhookLimits {
    static let idleTimeout: TimeInterval = 60
    static let maximumResponseBytes = 64 << 10

    static func resourceTimeout(bodyBytes: Int64) -> TimeInterval {
        min(2 * 3600, max(120, Double(bodyBytes) / 20_000))
    }
}
