// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

/// What the Immich API takes and gives, apart from the network.
enum ForkImmichSupport {
    static let deviceID = "Swishsaint"

    /// `https://photos.example.org` → `https://photos.example.org/api/<path>`.
    /// An address given with its `/api`, or a path of its own (a server
    /// behind `/immich`), keeps it once.
    static func endpoint(_ base: URL, _ path: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var root = components.path
        while root.hasSuffix("/") { root.removeLast() }
        if root.lowercased().hasSuffix("/api") { root.removeLast(4) }
        components.path = root + "/api/" + path
        components.query = nil
        components.fragment = nil
        return components.url ?? base
    }

    /// The upload's fields, then the video, as the Immich apps send them.
    /// `deviceAssetId` comes from the meeting: the same meeting sent again
    /// is recognized by the server rather than kept twice.
    static func uploadParts(video: URL, name: String, meetingID: UUID?, startedAt: Date?,
                            endedAt: Date?) -> [ForkWebhookMultipart.Part] {
        let created = startedAt ?? endedAt ?? Date()
        let modified = endedAt ?? created
        let assetID = "swishsaint-" + (meetingID?.uuidString.lowercased() ?? name)
        func field(_ name: String, _ value: String) -> ForkWebhookMultipart.Part {
            ForkWebhookMultipart.Part(name: name, filename: nil, contentType: "text/plain; charset=utf-8",
                                      source: .data(Data(value.utf8)))
        }
        return [
            field("deviceAssetId", assetID),
            field("deviceId", deviceID),
            field("fileCreatedAt", date(created)),
            field("fileModifiedAt", date(modified)),
            field("filename", "\(name).\(ForkMeetingFolder.videoExtension)"),
            ForkWebhookMultipart.Part(name: "assetData", filename: "\(name).\(ForkMeetingFolder.videoExtension)",
                                      contentType: "video/mp4", source: .file(video)),
        ]
    }

    static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The asset's id in the upload's answer: `{"id": …, "status":
    /// "created" | "duplicate"}`. A duplicate is the same video, already
    /// there: it counts as sent, and still joins the album.
    static func assetID(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? String, isPlainID(id) else { return nil }
        return id
    }

    /// The album of exactly that name among the server's, if any.
    static func albumID(named name: String, in body: Data) -> String? {
        guard let albums = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
        for album in albums where (album["albumName"] as? String) == name {
            if let id = album["id"] as? String, isPlainID(id) { return id }
        }
        return nil
    }

    /// The album chosen, trimmed; none when left empty.
    static func albumName(_ stored: String?) -> String? {
        let name = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// An id read from the server goes into a path: letters, digits and
    /// dashes only (Immich's are UUIDs), so an answer cannot steer a later
    /// request elsewhere.
    static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
        }
    }

    static func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
