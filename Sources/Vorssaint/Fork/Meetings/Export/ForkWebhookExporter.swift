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
///   session's delegate), nor one that would drop the body, and any `3xx`
///   left is a failure: the audio never goes where nobody approved.
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
    let secret: (String) -> Data?
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
    func approvedTarget() throws -> (url: URL, account: String) {
        guard let address = config.address, !address.isEmpty, let frozenName = config.origin else {
            throw ForkMeetingExportFailure.notConfigured
        }
        guard let frozen = ForkMeetingOriginPolicy.Origin(name: frozenName) else { throw ForkMeetingExportFailure.originChanged }
        switch ForkMeetingOriginPolicy.destination(address, frozen: frozen) {
        case let .approved(url, origin):
            return (url, ForkMeetingExporterConfig.secretAccount(origin: origin.name))
        case .refused(.unapprovedHost):
            throw ForkMeetingExportFailure.originChanged
        case let .refused(refusal):
            throw ForkMeetingExportFailure.refusedAddress(refusal)
        }
    }

    func export(_ package: ForkMeetingExportPackage, progress: @escaping (Double) -> Void) async throws -> ForkMeetingExportReceipt {
        let parts: [ForkWebhookMultipart.Part]
        do { parts = try ForkWebhookPayload.parts(package, includesMeetCode: config.includesMeetCode) } catch {
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
        guard let key = secret(target.account) else { throw ForkMeetingExportFailure.noSecret }
        var multipart = ForkWebhookMultipart()
        multipart.parts = parts
        let body = temporaryDirectory.appendingPathComponent("fork.meetings.webhook-\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: body) }
        var signer = ForkWebhookSigner(secret: key, at: Date())
        let length: Int64
        do { length = try multipart.write(to: body) { signer.update($0) } } catch {
            throw ForkMeetingExportFailure.unreadable
        }

        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(signer.timestamp, forHTTPHeaderField: ForkWebhookSigner.timestampHeader)
        request.setValue(signer.signature(), forHTTPHeaderField: ForkWebhookSigner.signatureHeader)
        request.setValue(event, forHTTPHeaderField: ForkWebhookSigner.eventHeader)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ForkWebhookLimits.idleTimeout
        configuration.timeoutIntervalForResource = ForkWebhookLimits.resourceTimeout(bodyBytes: length)
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let transfer = ForkWebhookTransfer(origin: target.url, trust: trust, bodyBytes: length, progress: progress)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let outcome = await transfer.run(session.uploadTask(with: request, fromFile: body))
        switch outcome {
        case let .answered(status) where (200..<300).contains(status):
            return status
        case let .answered(status) where (300..<400).contains(status):
            throw ForkMeetingExportFailure.redirected
        case let .answered(status):
            throw ForkMeetingExportFailure.status(status)
        case .redirectRefused:
            throw ForkMeetingExportFailure.redirected
        case let .failed(code):
            Self.log.error("webhook send failed: \(code, privacy: .public)")
            throw ForkMeetingExportFailure.network
        }
    }
}

/// One request's delegate: the redirection policy, the server's trust, the
/// answer's cap and the progress of the body sent.
final class ForkWebhookTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Equatable {
        case answered(Int)
        case redirectRefused
        /// The `NSURLError` code: no connection, a timeout, a refused
        /// certificate.
        case failed(Int)
    }

    private let origin: URL
    private let trust: ForkWebhookExporter.Trust
    private let bodyBytes: Int64
    private let progress: (Double) -> Void
    private let lock = NSLock()
    /// Under `lock`.
    private var status: Int?
    private var received = 0
    private var redirectRefused = false
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished: Outcome?

    init(origin: URL, trust: ForkWebhookExporter.Trust, bodyBytes: Int64, progress: @escaping (Double) -> Void) {
        self.origin = origin
        self.trust = trust
        self.bodyBytes = bodyBytes
        self.progress = progress
    }

    func run(_ task: URLSessionTask) async -> Outcome {
        await withCheckedContinuation { continuation in
            let done: Outcome? = lock.withLock {
                if let finished { return finished }
                self.continuation = continuation
                return nil
            }
            if let done { continuation.resume(returning: done) } else { task.resume() }
        }
    }

    private func finish(_ outcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>? = lock.withLock {
            guard finished == nil else { return nil }
            finished = outcome
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: outcome)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Followed only on the same origin, and only when the body goes
        // along (307, 308): a 302 would turn the POST into an empty GET,
        // whose "200" would pass for a meeting received.
        let from = task.currentRequest?.url ?? origin
        guard let to = request.url, [307, 308].contains(response.statusCode), request.httpMethod == "POST",
              ForkMeetingOriginPolicy.allowsRedirection(from: from, to: to),
              ForkMeetingOriginPolicy.allowsRedirection(from: origin, to: to) else {
            lock.withLock { redirectRefused = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
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
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let total = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : bodyBytes
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesSent) / Double(total)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode
        lock.withLock { status = code }
        // Only the status matters: an answer announced larger than the cap
        // is not read at all.
        completionHandler(response.expectedContentLength > Int64(ForkWebhookLimits.maximumResponseBytes) ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock { () -> Bool in
            received += data.count
            return received > ForkWebhookLimits.maximumResponseBytes
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (status, refused) = lock.withLock { (self.status, redirectRefused) }
        if let status, !(300..<400).contains(status) || !refused {
            finish(.answered(status))
        } else if refused {
            finish(.redirectRefused)
        } else {
            finish(.failed((error as NSError?)?.code ?? NSURLErrorUnknown))
        }
    }
}
