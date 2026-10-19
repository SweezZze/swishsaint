// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
import os
import Security

/// Sends a meeting to an HTTPS address as one signed `multipart/form-data`
/// `POST`: the parts `meeting` (its `meeting.json`), `audio` (its M4A) and
/// `transcript` when there is one. Works with n8n, Zapier and Make, whose
/// webhooks take a multipart body as it comes.
///
/// - **The origin is checked at every send**: the address saved must still
///   reach the host frozen when it was saved (`ForkMeetingOriginPolicy`).
///   Only then is the secret read, under that host's account: an address
///   rewritten in the preferences gets nothing signed.
/// - No redirection to another origin or to plain HTTP is followed (the
///   session's delegate), nor one that would drop the body, nor more than
///   two (`ForkWebhookRedirects`), and any `3xx` left is a failure: the
///   audio never goes where nobody approved.
/// - A `2xx` counts only once the whole body has left: an answer given
///   before is no proof the meeting arrived (`ForkWebhookVerdict`).
/// - An ephemeral session (no cookie, no cache, no credential kept),
///   bounded in time (`ForkWebhookLimits`), whose answer is read no further
///   than 64 KiB.
/// - The body is written once to a private temporary file while it is
///   signed, sent from there, then removed: an hour of audio is never held
///   in memory.
struct ForkWebhookExporter: ForkMeetingExporter {
    /// The server's certificate: the system's trust, always, in the app.
    /// The recipe harness alone gives its own local certificate.
    enum Trust {
        case system
        case anchors([SecCertificate])
    }

    let config: ForkMeetingExporterConfig
    /// Reads a secret from the Keychain by account, at the moment of a send.
    let secret: (String) -> ForkMeetingKeychain.Read
    /// Whether a secret is saved, without reading it.
    let hasSecret: (String) -> Bool
    var trust: Trust = .system
    var temporaryDirectory = FileManager.default.temporaryDirectory

    var id: String { config.id }
    var kind: ForkMeetingExportKind { .webhook }
    var mode: ForkMeetingExportMode { config.mode }

    private static let log = Logger(subsystem: "fork.meetings", category: "webhook")

    var isConfigured: Bool {
        guard let target = try? approvedTarget() else { return false }
        return hasSecret(target.account)
    }

    /// The address to send to and its secret's account, once the policy
    /// and the frozen origin agree.
    func check() throws {
        let target = try approvedTarget()
        guard hasSecret(target.account) else { throw ForkMeetingExportFailure.noSecret }
    }

    func approvedTarget() throws -> (url: URL, account: String) {
        try config.approvedTarget()
    }

    func export(_ package: ForkMeetingExportPackage, progress: @escaping (Double) -> Void) async throws -> ForkMeetingExportReceipt {
        let parts: [ForkWebhookMultipart.Part]
        do {
            parts = try ForkWebhookPayload.parts(package, includesMeetCode: config.includesMeetCode,
                                                 includesNotes: config.includesNotes,
                                                 includesSummary: config.includesSummary)
        } catch {
            throw ForkMeetingExportFailure.unreadable
        }
        let status = try await send(parts, event: "meeting", progress: progress)
        return ForkMeetingExportReceipt(target: id, kind: kind, at: Date(), httpStatus: status)
    }

    /// The page's "Send a test": the same request, signed the same way, with
    /// a `meeting` part saying it is a test. The status the address gave.
    func sendTest() async throws -> Int {
        try await send(ForkWebhookPayload.testParts(at: Date()), event: "test", progress: { _ in })
    }

    private func send(_ parts: [ForkWebhookMultipart.Part], event: String,
                      progress: @escaping (Double) -> Void) async throws -> Int {
        let target = try approvedTarget()
        let key: Data
        switch secret(target.account) {
        case let .found(data): key = data
        case .missing: throw ForkMeetingExportFailure.noSecret
        case .failed: throw ForkMeetingExportFailure.keychain
        }
        var multipart = ForkWebhookMultipart()
        multipart.parts = parts
        let body = temporaryDirectory.appendingPathComponent(ForkMeetingLeftovers.name(Self.bodyPrefix) + ".body")
        defer { try? FileManager.default.removeItem(at: body) }
        var signer = ForkWebhookSigner(secret: key, at: Date())
        let length: Int64
        do { length = try multipart.write(to: body) { signer.update($0) } } catch ForkWebhookMultipart.Failure.unwritable {
            throw ForkMeetingExportFailure.temporarySpace
        } catch ForkWebhookMultipart.Failure.unreadable {
            throw ForkMeetingExportFailure.noAudio
        } catch {
            throw ForkMeetingExportFailure.unreadable
        }

        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(signer.timestamp, forHTTPHeaderField: ForkWebhookSigner.timestampHeader)
        request.setValue(signer.signature(), forHTTPHeaderField: ForkWebhookSigner.signatureHeader)
        request.setValue(event, forHTTPHeaderField: ForkWebhookSigner.eventHeader)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ForkWebhookLimits.idleTimeout
        configuration.timeoutIntervalForResource = ForkWebhookLimits.resourceTimeout(bodyBytes: length)
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Neutral: neither this Mac's language nor the app's build.
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "en"]
        let transfer = ForkWebhookTransfer(origin: target.url, trust: trust, bodyBytes: length, progress: progress)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let ending = await transfer.run(session.uploadTask(with: request, fromFile: body))
        if let code = ending.errorCode, ending.status == nil {
            Self.log.error("webhook send failed: \(code, privacy: .public)")
        }
        return try ForkWebhookVerdict.result(status: ending.status, redirectRefused: ending.redirectRefused,
                                             trustRefused: ending.trustRefused, errorCode: ending.errorCode,
                                             sent: ending.sent, bodyBytes: length).get()
    }

    /// The bodies' names in the temporary folder: what a send cut short by
    /// a quit leaves there is removed at the next launch.
    static let bodyPrefix = "fork.meetings.webhook-"
    static let userAgent = "Swishsaint-Webhook/1"
}

/// One request's delegate: the redirection policy, the server's trust, the
/// answer's cap and the body sent.
final class ForkWebhookTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// What the request saw, at its end.
    struct Ending: Equatable {
        var status: Int?
        var redirectRefused = false
        var trustRefused = false
        /// The `NSURLError` code the task ended with: no connection, a
        /// timeout, a refused certificate.
        var errorCode: Int?
        /// The bytes of the body that left.
        var sent: Int64 = 0
        /// The answer, up to the cap: only Immich reads it (the id of the
        /// asset it made).
        var body = Data()
    }

    private let origin: URL
    private let trust: ForkWebhookExporter.Trust
    private let bodyBytes: Int64
    private let progress: (Double) -> Void
    private let lock = NSLock()
    /// Under `lock`.
    private var seen = Ending()
    private var received = 0
    private var redirects = 0
    private var continuation: CheckedContinuation<Ending, Never>?
    private var finished: Ending?

    init(origin: URL, trust: ForkWebhookExporter.Trust, bodyBytes: Int64, progress: @escaping (Double) -> Void) {
        self.origin = origin
        self.trust = trust
        self.bodyBytes = bodyBytes
        self.progress = progress
    }

    func run(_ task: URLSessionTask) async -> Ending {
        await withCheckedContinuation { continuation in
            let done: Ending? = lock.withLock {
                if let finished { return finished }
                self.continuation = continuation
                return nil
            }
            if let done { continuation.resume(returning: done) } else { task.resume() }
        }
    }

    private func finish(_ ending: Ending) {
        let continuation: CheckedContinuation<Ending, Never>? = lock.withLock {
            guard finished == nil else { return nil }
            finished = ending
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: ending)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Followed only on the same origin, only when the body goes along
        // (307, 308: a 302 would turn the POST into an empty GET, whose
        // "200" would pass for a meeting received), and twice at most. The
        // body starts again from its first byte.
        let from = task.currentRequest?.url ?? origin
        let follows = lock.withLock { () -> Bool in
            let follows = ForkWebhookRedirects.follows(followed: redirects, status: response.statusCode,
                                                       method: request.httpMethod, from: from, to: request.url,
                                                       origin: origin)
            if follows {
                redirects += 1
                seen.sent = 0
            } else {
                seen.redirectRefused = true
            }
            return follows
        }
        completionHandler(follows ? request : nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              case let .anchors(certificates) = trust, !certificates.isEmpty,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetAnchorCertificates(serverTrust, certificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        if SecTrustEvaluateWithError(serverTrust, nil) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            lock.withLock { seen.trustRefused = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.withLock { seen.sent = totalBytesSent }
        let total = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : bodyBytes
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesSent) / Double(total)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode
        lock.withLock { seen.status = code }
        // Only the status matters: an answer announced larger than the cap
        // is not read at all.
        completionHandler(response.expectedContentLength > Int64(ForkWebhookLimits.maximumResponseBytes) ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock { () -> Bool in
            received += data.count
            guard received <= ForkWebhookLimits.maximumResponseBytes else { return true }
            seen.body.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ending = lock.withLock { () -> Ending in
            seen.errorCode = (error as NSError?)?.code
            return seen
        }
        finish(ending)
    }
}
