// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

enum ForkImmichTests {
    static func run(_ suite: TestSuite) {
        endpoints(suite)
        answers(suite)
        upload(suite)
        settings(suite)
        strings(suite)
    }

    private static func endpoints(_ suite: TestSuite) {
        func endpoint(_ base: String, _ path: String) -> String {
            ForkImmichSupport.endpoint(URL(string: base)!, path).absoluteString
        }
        suite.expect(endpoint("https://photos.example.org", "assets") == "https://photos.example.org/api/assets",
                     "the server's address gets the API's path")
        suite.expect(endpoint("https://photos.example.org/api/", "albums") == "https://photos.example.org/api/albums"
                        && endpoint("https://photos.example.org/API", "albums") == "https://photos.example.org/api/albums",
                     "an address given with its /api keeps it once")
        suite.expect(endpoint("https://example.org:8443/immich/", "users/me") == "https://example.org:8443/immich/api/users/me",
                     "a server behind a path and a port keeps both")
        suite.expect(endpoint("https://photos.example.org/?x=1", "assets") == "https://photos.example.org/api/assets",
                     "a query of the address is not carried along")
    }

    private static func answers(_ suite: TestSuite) {
        let id = "8f2c1d5e-0a4b-4c3d-9e8f-1a2b3c4d5e6f"
        suite.expect(ForkImmichSupport.assetID(from: Data(#"{"id":"\#(id)","status":"created"}"#.utf8)) == id
                        && ForkImmichSupport.assetID(from: Data(#"{"id":"\#(id)","status":"duplicate"}"#.utf8)) == id,
                     "a created or duplicate video gives its id")
        suite.expect(ForkImmichSupport.assetID(from: Data(#"{"id":"../../albums"}"#.utf8)) == nil
                        && ForkImmichSupport.assetID(from: Data("<html>".utf8)) == nil,
                     "an id that could steer a later request, or no JSON, is no id")
        let albums = Data(#"[{"id":"a1","albumName":"Réunions"},{"id":"b2","albumName":"réunions"}]"#.utf8)
        suite.expect(ForkImmichSupport.albumID(named: "réunions", in: albums) == "b2"
                        && ForkImmichSupport.albumID(named: "Travail", in: albums) == nil,
                     "the album is found by its exact name, else made")
        suite.expect(ForkImmichSupport.albumName("  Réunions ") == "Réunions" && ForkImmichSupport.albumName("  ") == nil
                        && ForkImmichSupport.albumName(nil) == nil,
                     "an album left empty is no album")
    }

    private static func upload(_ suite: TestSuite) {
        let meeting = UUID(uuidString: "8F2C1D5E-0A4B-4C3D-9E8F-1A2B3C4D5E6F")!
        let start = Date(timeIntervalSince1970: 1_792_400_000)
        let parts = ForkImmichSupport.uploadParts(video: URL(fileURLWithPath: "/tmp/m.mp4"), name: "Point hebdo",
                                                  meetingID: meeting, startedAt: start,
                                                  endedAt: start.addingTimeInterval(1800))
        suite.expect(parts.map(\.name) == ["deviceAssetId", "deviceId", "fileCreatedAt", "fileModifiedAt", "filename",
                                           "assetData"],
                     "the fields come before the video, as the Immich apps send them")
        func value(_ name: String) -> String? {
            guard case let .data(data)? = parts.first(where: { $0.name == name })?.source else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        suite.expect(value("deviceAssetId") == "swishsaint-8f2c1d5e-0a4b-4c3d-9e8f-1a2b3c4d5e6f"
                        && value("fileCreatedAt") == ForkImmichSupport.date(start),
                     "the video is named after the meeting and dated from its start")
        let video = parts.last
        suite.expect(video?.filename == "Point hebdo.mp4" && video?.contentType == "video/mp4",
                     "the video goes as an MP4 named after the meeting")
    }

    private static func settings(_ suite: TestSuite) {
        let immich = ForkMeetingExporterConfig(id: "i", kind: .immich, origin: "photos.example.org", album: "Réunions")
        let webhook = ForkMeetingExporterConfig(id: "i", kind: .webhook, origin: "photos.example.org")
        suite.expect(immich.secretAccount == "immich@photos.example.org#i"
                        && webhook.secretAccount == "webhook@photos.example.org#i",
                     "an Immich key is filed apart from a webhook's secret")
        let stored = ForkMeetingExporterList.encode([immich])
        let read = ForkMeetingExporterList.decode(stored).first
        suite.expect(read?.kind == .immich && read?.album == "Réunions" && read?.usesAddress == true,
                     "an Immich exporter and its album come back as saved")
        let saved = ForkMeetingExporterConfig(id: "i", kind: .immich, address: "https://photos.example.org",
                                              origin: "photos.example.org")
        suite.expect(saved.readiness(hasSecret: { _ in false }) == .noSecret
                        && saved.readiness(hasSecret: { $0 == "immich@photos.example.org#i" }) == nil,
                     "an Immich exporter sends only with its own key")
        let moved = ForkMeetingExporterConfig(id: "i", kind: .immich, address: "https://evil.example.net",
                                              origin: "photos.example.org")
        suite.expect(moved.readiness(hasSecret: { _ in true }) == .originChanged,
                     "an address rewritten behind the page reads no key")
        suite.expect(ForkMeetingExportFailure(code: ForkMeetingExportFailure.noVideo.code, httpStatus: nil) == .noVideo,
                     "a meeting without video reads back as such from its history")
    }

    private static func strings(_ suite: TestSuite) {
        let all = AppLanguage.allCases.map(ForkImmichStrings.strings)
        suite.expect(all.allSatisfy { !$0.caption.isEmpty && !$0.driveTip.isEmpty && $0.testDone(200).contains("200") },
                     "Immich and the Google Drive hint are said in every language")
        suite.expect(AppLanguage.allCases.allSatisfy { !ForkMeetingStrings.strings($0).exportFailNoVideo.isEmpty },
                     "a meeting without video is explained in every language")
    }
}
