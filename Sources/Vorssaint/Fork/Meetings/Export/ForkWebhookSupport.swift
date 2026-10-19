// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CryptoKit
import Foundation

/// The webhook's signature: `X-Swishsaint-Signature: sha256=<hex>`, the
/// HMAC-SHA256 of `timestamp + "." + body` keyed with the secret, and
/// `X-Swishsaint-Timestamp`, Unix seconds, taken when the body is signed,
/// before it is sent. The receiver recomputes it over the raw body it got,
/// refuses a request whose signature differs or whose timestamp is older
/// than `freshness` (the longest send, and five minutes of clocks apart),
/// and keeps the signatures it took for that long: a copy replayed within
/// that window is answered without being taken twice, while a meeting sent
/// again (a Retry) is signed anew.
///
/// Computed while the body is written, chunk by chunk: an hour of audio is
/// never held in memory.
struct ForkWebhookSigner {
    static let timestampHeader = "X-Swishsaint-Timestamp"
    static let signatureHeader = "X-Swishsaint-Signature"
    /// `meeting`, or `test` for the page's "Send a test".
    static let eventHeader = "X-Swishsaint-Event"
    static let prefix = "sha256="
    /// How old a timestamp a receiver takes: a send may last two hours
    /// (`ForkWebhookLimits.resourceTimeout`), plus five minutes. Said in
    /// the page's help.
    static let freshness: TimeInterval = ForkWebhookLimits.longestSend + 5 * 60

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

    /// The file names carry the meeting's name, without its Google Meet
    /// code unless asked, like the `meeting` part.
    static func parts(_ package: ForkMeetingExportPackage, includesMeetCode: Bool,
                      includesNotes: Bool) throws -> [ForkWebhookMultipart.Part] {
        let json = try ForkMeetingExportDocument.json(package.sidecar, includesMeetCode: includesMeetCode,
                                                      includesNotes: includesNotes)
        let name = package.name(includesMeetCode: includesMeetCode)
        var parts = [
            ForkWebhookMultipart.Part(name: meetingPart, filename: ForkMeetingFolder.sidecarName,
                                      contentType: "application/json", source: .data(json)),
            ForkWebhookMultipart.Part(name: audioPart, filename: ForkMeetingExportPackage.audioName(name),
                                      contentType: "audio/mp4", source: .file(package.audio)),
        ]
        if let transcript = package.transcript {
            parts.append(ForkWebhookMultipart.Part(name: transcriptPart, filename: ForkMeetingExportPackage.transcriptName(name),
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

    /// The receiver side, for the page's help: the raw body, headers in any
    /// case and maybe missing, a timestamp that may not be a number, the
    /// window of `ForkWebhookSigner.freshness`, the secret as bytes, and a
    /// request already taken answered 2xx without being taken twice (by its
    /// signature: a meeting sent again has a new one, and is new).
    static let verificationExample = """
    // Node.js (n8n "Code" node, Express with express.raw()): rawBody is a Buffer
    const crypto = require('crypto');
    const WINDOW = 7500; // 2 h 05, in seconds
    const seen = new Map(); // signature -> when it was taken
    function header(headers, name) {
      for (const [key, value] of Object.entries(headers || {})) {
        if (key.toLowerCase() === name) return String(value);
      }
      return '';
    }
    // 'new', 'duplicate' (answer 2xx, take nothing) or null (answer 401)
    function verify(headers, rawBody, SECRET) {
      const ts = header(headers, 'x-swishsaint-timestamp');
      const given = header(headers, 'x-swishsaint-signature');
      if (!/^[0-9]+$/.test(ts)) return null;
      const now = Date.now() / 1000;
      if (Math.abs(now - Number(ts)) > WINDOW) return null;
      const expected = 'sha256=' + crypto.createHmac('sha256', Buffer.from(SECRET))
        .update(ts + '.').update(rawBody).digest('hex');
      if (Buffer.byteLength(given) !== Buffer.byteLength(expected)) return null;
      try {
        if (!crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) return null;
      } catch (e) { return null; }
      for (const [signature, at] of seen) if (now - at > WINDOW) seen.delete(signature);
      if (seen.has(given)) return 'duplicate';
      seen.set(given, now);
      return 'new';
    }

    # Python: raw_body is bytes, headers any mapping
    import hashlib, hmac, time
    WINDOW = 7500  # 2 h 05, in seconds
    seen = {}  # signature -> when it was taken
    def header(headers, name):
        for key, value in (headers or {}).items():
            if key.lower() == name:
                return str(value)
        return ''
    # 'new', 'duplicate' (answer 2xx, take nothing) or None (answer 401)
    def verify(headers, raw_body, secret):
        if isinstance(secret, str):
            secret = secret.encode()
        ts = header(headers, 'x-swishsaint-timestamp')
        given = header(headers, 'x-swishsaint-signature')
        if not (ts.isascii() and ts.isdigit()):
            return None
        now = time.time()
        if abs(now - int(ts)) > WINDOW:
            return None
        expected = 'sha256=' + hmac.new(secret, ts.encode() + b'.' + raw_body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected.encode(), given.encode()):
            return None
        for signature, at in list(seen.items()):
            if now - at > WINDOW:
                del seen[signature]
        if given in seen:
            return 'duplicate'
        seen[given] = now
        return 'new'
    """
}

/// The bounds of one request: a body sent at no less than about 20 kB/s,
/// never past two hours, never under two minutes; a minute without a byte
/// either way is a failure; and an answer read no further than 64 KiB, of
/// which only the status matters.
enum ForkWebhookLimits {
    static let idleTimeout: TimeInterval = 60
    static let maximumResponseBytes = 64 << 10
    static let longestSend: TimeInterval = 2 * 3600

    static func resourceTimeout(bodyBytes: Int64) -> TimeInterval {
        min(longestSend, max(120, Double(bodyBytes) / 20_000))
    }
}

/// The redirections a send follows: on the same origin, with its body (307,
/// 308), and no more than `maximum` of them; any other is a failure.
enum ForkWebhookRedirects {
    static let maximum = 2

    /// - `followed`: how many this request already followed.
    /// - `from`: the address redirected; `origin`, the one approved.
    static func follows(followed: Int, status: Int, method: String?, from: URL, to: URL?, origin: URL) -> Bool {
        guard followed < maximum, let to, [307, 308].contains(status), method == "POST" else { return false }
        return ForkMeetingOriginPolicy.allowsRedirection(from: from, to: to)
            && ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: to)
    }
}

/// What a send's end means, from what its delegate saw.
enum ForkWebhookVerdict {
    /// - `status`: the answer's, when one came.
    /// - `redirectRefused`: a redirection was not followed.
    /// - `trustRefused`: the server's certificate was refused.
    /// - `errorCode`: the `NSURLError` the task ended with, if any.
    /// - `sent` / `bodyBytes`: a 2xx counts only once the whole body left.
    static func result(status: Int?, redirectRefused: Bool, trustRefused: Bool, errorCode: Int?,
                       sent: Int64, bodyBytes: Int64) -> Result<Int, ForkMeetingExportFailure> {
        if let status, !((300..<400).contains(status) && redirectRefused) {
            switch status {
            case 200..<300: return sent >= bodyBytes ? .success(status) : .failure(.earlyAnswer)
            case 300..<400: return .failure(.redirected)
            default: return .failure(.status(status))
            }
        }
        if redirectRefused { return .failure(.redirected) }
        if trustRefused || errorCode.map(certificateErrors.contains) == true { return .failure(.certificate) }
        return .failure(.network)
    }

    /// The `NSURLError` codes of a certificate refused, here or there.
    static let certificateErrors: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]
}
