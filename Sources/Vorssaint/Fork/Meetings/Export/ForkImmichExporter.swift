// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation
import os

/// Sends a meeting's video to the person's own Immich server, the way the
/// Immich apps upload: `POST /api/assets`, then the meeting's title as the
/// asset's description, then the album chosen (made when missing).
///
/// Immich keeps photos and videos: a meeting without video is refused
/// before anything leaves (`noVideo`), never sent as audio it would reject.
///
/// The same guards as the webhook (`ForkWebhookExporter`), on the same
/// transport (`ForkWebhookTransfer`): HTTPS only, the origin frozen with the
/// key and checked at every request, the key read from the Keychain only
/// then (`immich@<host[:port]>#<id>`, apart from any webhook's), no
/// redirection elsewhere, an ephemeral session, bounded answers.
struct ForkImmichExporter: ForkMeetingExporter {
    let config: ForkMeetingExporterConfig
    /// Reads the API key from the Keychain by account, at the moment of a send.
    let secret: (String) -> ForkMeetingKeychain.Read
    /// Whether a key is saved, without reading it.
    let hasSecret: (String) -> Bool
    var trust: ForkWebhookExporter.Trust = .system
    var temporaryDirectory = FileManager.default.temporaryDirectory

    var id: String { config.id }
    var kind: ForkMeetingExportKind { .immich }
    var mode: ForkMeetingExportMode { config.mode }

    private static let log = Logger(subsystem: "fork.meetings", category: "immich")

    var isConfigured: Bool {
        guard let target = try? config.approvedTarget() else { return false }
        return hasSecret(target.account)
    }

    func check() throws {
        let target = try config.approvedTarget()
        guard hasSecret(target.account) else { throw ForkMeetingExportFailure.noSecret }
    }

    func export(_ package: ForkMeetingExportPackage, progress: @escaping (Double) -> Void) async throws -> ForkMeetingExportReceipt {
        guard let video = package.video else { throw ForkMeetingExportFailure.noVideo }
        let (base, key) = try approved()
        let name = package.name(includesMeetCode: config.includesMeetCode)
        let parts = ForkImmichSupport.uploadParts(video: video, name: name, meetingID: package.sidecar.id,
                                                  startedAt: package.sidecar.startedAt,
                                                  endedAt: package.sidecar.endedAt)
        let upload = try await request("POST", ForkImmichSupport.endpoint(base, "assets"), key: key,
                                       body: .multipart(parts), progress: progress)
        guard let asset = ForkImmichSupport.assetID(from: upload.body) else {
            throw ForkMeetingExportFailure.status(upload.status)
        }

        // The title helps find the meeting among the photos; a server that
        // refuses it still has the video.
        if let title = ForkMeetingExportDocument.title(package.sidecar.title, meetCode: package.sidecar.meetCode,
                                                       includesMeetCode: config.includesMeetCode),
           let body = ForkImmichSupport.json(["description": title]) {
            _ = try? await request("PUT", ForkImmichSupport.endpoint(base, "assets/\(asset)"), key: key,
                                   body: .json(body), progress: { _ in })
        }

        if let album = ForkImmichSupport.albumName(config.album) {
            try await add(asset, to: album, base: base, key: key)
        }
        return ForkMeetingExportReceipt(target: id, kind: kind, at: Date(), httpStatus: upload.status)
    }

    /// The page's test: the key read and accepted by the server.
    func sendTest() async throws -> Int {
        let (base, key) = try approved()
        return try await request("GET", ForkImmichSupport.endpoint(base, "users/me"), key: key, body: .none,
                                 progress: { _ in }).status
    }

    /// Into the album of that name, made with the video when there is none.
    /// Adding a video already there is no error: Immich says so per id.
    private func add(_ asset: String, to album: String, base: URL, key: Data) async throws {
        let albums = try await request("GET", ForkImmichSupport.endpoint(base, "albums"), key: key, body: .none,
                                       progress: { _ in })
        if let existing = ForkImmichSupport.albumID(named: album, in: albums.body) {
            guard let body = ForkImmichSupport.json(["ids": [asset]]) else { return }
            _ = try await request("PUT", ForkImmichSupport.endpoint(base, "albums/\(existing)/assets"), key: key,
                                  body: .json(body), progress: { _ in })
        } else {
            guard let body = ForkImmichSupport.json(["albumName": album, "assetIds": [asset]]) else { return }
            _ = try await request("POST", ForkImmichSupport.endpoint(base, "albums"), key: key, body: .json(body),
                                  progress: { _ in })
        }
    }

    /// The server's address and its key, once the policy and the frozen
    /// origin agree.
    private func approved() throws -> (URL, Data) {
        let target = try config.approvedTarget()
        switch secret(target.account) {
        case let .found(data): return (target.url, data)
        case .missing: throw ForkMeetingExportFailure.noSecret
        case .failed: throw ForkMeetingExportFailure.keychain
        }
    }

    private enum Body {
        case none
        case json(Data)
        case multipart([ForkWebhookMultipart.Part])
    }

    /// One request to the server. Every one checks the origin again: the
    /// endpoints are built from the approved address, never from an answer.
    private func request(_ method: String, _ url: URL, key: Data, body: Body,
                         progress: @escaping (Double) -> Void) async throws -> (status: Int, body: Data) {
        guard ForkMeetingOriginPolicy.allowsRedirection(from: try config.approvedTarget().url, to: url) else {
            throw ForkMeetingExportFailure.originChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(String(decoding: key, as: UTF8.self), forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        var file: URL?
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        var length: Int64 = 0
        switch body {
        case .none:
            break
        case let .json(data):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            length = Int64(data.count)
        case let .multipart(parts):
            var multipart = ForkWebhookMultipart()
            multipart.parts = parts
            let destination = temporaryDirectory.appendingPathComponent(ForkMeetingLeftovers.name(Self.bodyPrefix) + ".body")
            file = destination
            do { length = try multipart.write(to: destination) { _ in } } catch ForkWebhookMultipart.Failure.unwritable {
                throw ForkMeetingExportFailure.temporarySpace
            } catch ForkWebhookMultipart.Failure.unreadable {
                throw ForkMeetingExportFailure.noVideo
            } catch {
                throw ForkMeetingExportFailure.unreadable
            }
            request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ForkWebhookLimits.idleTimeout
        configuration.timeoutIntervalForResource = ForkWebhookLimits.resourceTimeout(bodyBytes: length)
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "en"]
        let transfer = ForkWebhookTransfer(origin: url, trust: trust, bodyBytes: length, progress: progress)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task: URLSessionTask
        switch body {
        case .none: task = session.dataTask(with: request)
        case let .json(data): task = session.uploadTask(with: request, from: data)
        case .multipart: task = session.uploadTask(with: request, fromFile: file!)
        }
        let ending = await transfer.run(task)
        if let code = ending.errorCode, ending.status == nil {
            Self.log.error("immich \(method, privacy: .public) failed: \(code, privacy: .public)")
        }
        let status = try ForkWebhookVerdict.result(status: ending.status, redirectRefused: ending.redirectRefused,
                                                   trustRefused: ending.trustRefused, errorCode: ending.errorCode,
                                                   sent: ending.sent, bodyBytes: length).get()
        return (status, ending.body)
    }

    /// The bodies' names in the temporary folder, removed at the next
    /// launch when a quit cut a send short.
    static let bodyPrefix = "fork.meetings.immich-"
    static let userAgent = "Swishsaint-Immich/1"
}
