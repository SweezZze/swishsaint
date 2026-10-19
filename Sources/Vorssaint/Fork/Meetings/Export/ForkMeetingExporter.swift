// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Where a meeting can be sent once it is recorded. Nothing is, until the
/// person adds an exporter on the Meetings page: **no exporter, no mention
/// of exporting** anywhere but "Export Audio (M4A)…".
///
/// - The exporters' settings are machine state (`fork.meetings.exporters`,
///   JSON): a folder's path and an address depend on this Mac, so they stay
///   out of the settings backup. Their secrets are in the Keychain only
///   (`ForkMeetingKeychain`), never in the preferences nor the backup.
/// - Every attempt is written in the meeting's `meeting.json` (`exports`,
///   appended only), and a failed one has its Retry.
/// - A meeting that did not end well (interrupted, recovered, cancelled) is
///   never sent without a click (`ForkMeetingExportEligibility`).
protocol ForkMeetingExporter {
    /// The exporter's own id among the configured ones: the `target` of
    /// its records in `meeting.json`.
    var id: String { get }
    var kind: ForkMeetingExportKind { get }
    /// Has what it needs to send (a folder, an address and its secret).
    var isConfigured: Bool { get }
    var mode: ForkMeetingExportMode { get }
    /// Sends one meeting. Off the main thread; throws a
    /// `ForkMeetingExportFailure`.
    func export(_ package: ForkMeetingExportPackage, progress: @escaping (Double) -> Void) async throws -> ForkMeetingExportReceipt
}

/// The kinds of exporters. Written in `meeting.json` (`exports[].exporter`)
/// and in the settings: names never change, new ones are only added.
enum ForkMeetingExportKind: String, Codable, CaseIterable {
    case dropFolder
    case webhook
}

/// Sent when asked from the library, or after each meeting on its own.
enum ForkMeetingExportMode: String, Codable, CaseIterable {
    case manual
    case automatic
}

/// One exporter as the page set it up. Nothing secret: a webhook's secret is
/// in the Keychain under `secretAccount`, and only `origin` decides which.
struct ForkMeetingExporterConfig: Equatable, Identifiable {
    var id: String
    var kind: ForkMeetingExportKind
    var mode: ForkMeetingExportMode = .manual
    /// The Google Meet code is a way into the meeting: left out of what
    /// leaves the folder unless the person asks for it.
    var includesMeetCode = false
    /// Drop folder: the folder's path, as chosen in the panel.
    var folder: String?
    /// Webhook: the address as saved.
    var address: String?
    /// Webhook: the origin (`host` or `host:port`) frozen when the address
    /// was saved. A different one means the address changed behind the
    /// page's back: nothing is sent and the secret is never read.
    var origin: String?

    init(id: String = UUID().uuidString, kind: ForkMeetingExportKind, mode: ForkMeetingExportMode = .manual,
         includesMeetCode: Bool = false, folder: String? = nil, address: String? = nil, origin: String? = nil) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.includesMeetCode = includesMeetCode
        self.folder = folder
        self.address = address
        self.origin = origin
    }

    /// The Keychain account of a webhook's secret: one per origin, so an
    /// address rewritten in the preferences finds no secret instead of the
    /// real one.
    var secretAccount: String? {
        guard kind == .webhook, let origin, !origin.isEmpty else { return nil }
        return Self.secretAccount(origin: origin)
    }

    static func secretAccount(origin: String) -> String { "webhook@\(origin)" }

    /// What the page and the menus call it after its kind: the folder's
    /// name, or the host.
    var detail: String? {
        switch kind {
        case .dropFolder:
            guard let folder, !folder.isEmpty else { return nil }
            return (folder as NSString).lastPathComponent
        case .webhook:
            return origin
        }
    }
}

extension ForkMeetingExporterConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, mode, includesMeetCode, folder, address, origin
    }

    /// Lenient: a missing or unknown mode is manual, a missing option off.
    /// Only the kind is required: an exporter of a kind this version does
    /// not know is skipped by the list, never guessed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ForkMeetingExportKind.self, forKey: .kind)
        let id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
        self.id = id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        mode = ((try? container.decodeIfPresent(ForkMeetingExportMode.self, forKey: .mode)) ?? nil) ?? .manual
        includesMeetCode = ((try? container.decodeIfPresent(Bool.self, forKey: .includesMeetCode)) ?? nil) ?? false
        folder = (try? container.decodeIfPresent(String.self, forKey: .folder)) ?? nil
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? nil
        origin = (try? container.decodeIfPresent(String.self, forKey: .origin)) ?? nil
    }
}

/// `fork.meetings.exporters`: the configured exporters, as a JSON array in
/// a String setting (the backup and the defaults take only Bool, Int and
/// String). Read leniently: a corrupt setting is no exporter at all, an
/// entry this version cannot read is skipped, the others kept.
enum ForkMeetingExporterList {
    static func decode(_ stored: String?) -> [ForkMeetingExporterConfig] {
        guard let data = stored?.data(using: .utf8), !data.isEmpty,
              let items = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        var seen = Set<String>()
        return items.compactMap(\.config).filter { seen.insert($0.id).inserted }
    }

    static func encode(_ configs: [ForkMeetingExporterConfig]) -> String {
        guard !configs.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(configs) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One entry of the array, whatever it holds.
    private struct Lenient: Decodable {
        let config: ForkMeetingExporterConfig?
        init(from decoder: Decoder) throws {
            config = try? ForkMeetingExporterConfig(from: decoder)
        }
    }
}

/// What a meeting holds for an export, gathered once from its folder: its
/// `meeting.json`, its audio as an M4A ready to be read, and its transcript
/// when there is one.
struct ForkMeetingExportPackage {
    /// The meeting folder's name: the name of what is sent.
    let folderName: String
    let sidecar: ForkMeetingSidecar
    let audio: URL
    let transcript: URL?

    var audioName: String { "\(folderName).\(ForkMeetingFolder.audioExtension)" }
    var transcriptName: String { "\(folderName).\(ForkMeetingExportDocument.transcriptExtension)" }
}

/// One export done: where to, and when.
struct ForkMeetingExportReceipt: Equatable {
    let target: String
    let kind: ForkMeetingExportKind
    let at: Date
    /// The webhook's answer.
    var httpStatus: Int?
}

/// Why an export did not happen. Its `code` is what `meeting.json` keeps
/// (`exports[].reason`): stable names, new ones only added.
enum ForkMeetingExportFailure: Error, Equatable {
    /// Recording or finishing, here or in another copy of the app.
    case inProgress
    /// `meeting.json` cannot be read, or comes from a later version: its
    /// history could not be written.
    case unreadable
    case noAudio
    /// The drop folder is not there: an unmounted disk, a folder moved.
    case folderMissing
    /// The drop folder is the meetings folder or inside it.
    case folderInsideLibrary
    /// The files could not be copied.
    case writeFailed
    /// The address saved does not pass the origin policy.
    case refusedAddress(ForkMeetingOriginPolicy.Refusal)
    /// The address no longer reaches the origin frozen with its secret.
    case originChanged
    case noSecret
    /// The address answered with a redirection, not followed.
    case redirected
    case status(Int)
    /// No connection, no answer in time, or an answer cut off.
    case network
    /// The exporter is not set up (no folder, no address).
    case notConfigured

    var code: String {
        switch self {
        case .inProgress: return "inProgress"
        case .unreadable: return "unreadable"
        case .noAudio: return "noAudio"
        case .folderMissing: return "folderMissing"
        case .folderInsideLibrary: return "folderInsideLibrary"
        case .writeFailed: return "writeFailed"
        case let .refusedAddress(refusal): return "refusedAddress." + Self.refusalCode(refusal)
        case .originChanged: return "originChanged"
        case .noSecret: return "noSecret"
        case .redirected: return "redirected"
        case .status: return "status"
        case .network: return "network"
        case .notConfigured: return "notConfigured"
        }
    }

    var httpStatus: Int? {
        if case let .status(status) = self { return status }
        return nil
    }

    /// Read back from `meeting.json`: a code this version does not know
    /// reads as the network's, the vaguest.
    init(code: String?, httpStatus: Int?) {
        switch code {
        case "inProgress": self = .inProgress
        case "unreadable": self = .unreadable
        case "noAudio": self = .noAudio
        case "folderMissing": self = .folderMissing
        case "folderInsideLibrary": self = .folderInsideLibrary
        case "writeFailed": self = .writeFailed
        case "originChanged": self = .originChanged
        case "noSecret": self = .noSecret
        case "redirected": self = .redirected
        case "status": self = .status(httpStatus ?? 0)
        case "notConfigured": self = .notConfigured
        case let code? where code.hasPrefix("refusedAddress"):
            self = .refusedAddress(Self.refusal(String(code.dropFirst("refusedAddress.".count))))
        default: self = .network
        }
    }

    private static func refusalCode(_ refusal: ForkMeetingOriginPolicy.Refusal) -> String {
        switch refusal {
        case .unreadable: return "unreadable"
        case .notHTTPS: return "notHTTPS"
        case .credentialsInURL: return "credentials"
        case .fragmentInURL: return "fragment"
        case .nonASCIIHost: return "nonASCII"
        case .unapprovedHost: return "unapprovedHost"
        }
    }

    /// The host itself is not kept in `meeting.json`: only the kind.
    private static func refusal(_ code: String) -> ForkMeetingOriginPolicy.Refusal {
        switch code {
        case "notHTTPS": return .notHTTPS(scheme: nil)
        case "credentials": return .credentialsInURL
        case "fragment": return .fragmentInURL
        case "unapprovedHost": return .unapprovedHost("")
        default: return .unreadable
        }
    }
}

// MARK: - Eligibility

/// Which meetings may go: never one being written; never on its own one
/// that did not end well, or that already went there.
enum ForkMeetingExportEligibility {
    enum Verdict: Equatable {
        case allowed
        case refused(ForkMeetingExportFailure)
        /// Fine to send with a click, but not on its own.
        case needsClick
    }

    /// - `live`: this app records or finishes the folder now.
    static func verdict(_ sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>, live: Bool,
                        automatic: Bool, target: String? = nil) -> Verdict {
        if live { return .refused(.inProgress) }
        guard case let .success(meeting) = sidecar, meeting.isRewritable else { return .refused(.unreadable) }
        switch meeting.state {
        case .recording?, .finalizing?: return .refused(.inProgress)
        case .complete?, .interrupted?, nil: break
        }
        guard automatic else { return .allowed }
        let endedWell = meeting.state == .complete && meeting.recovered != true
            && meeting.stopReason != .cancelled && meeting.stopReason != .crash && meeting.stopReason != .quit
            && meeting.finalPass != .failed
        guard endedWell else { return .needsClick }
        if let target, ForkMeetingExportHistory.lastResult(meeting.exports ?? [], target: target)?.status == .done {
            return .needsClick
        }
        return .allowed
    }
}

// MARK: - History

/// The `exports` of `meeting.json`: one record per attempt, appended, never
/// rewritten. The latest record per exporter is what the library shows.
enum ForkMeetingExportHistory {
    enum Status: String {
        case done
        case failed
    }

    struct Result: Equatable {
        let status: Status
        let at: Date?
        let failure: ForkMeetingExportFailure?
    }

    static func record(_ receipt: ForkMeetingExportReceipt) -> ForkMeetingSidecar.Export {
        ForkMeetingSidecar.Export(exporter: receipt.kind.rawValue, at: receipt.at, status: Status.done.rawValue,
                                  target: receipt.target, httpStatus: receipt.httpStatus)
    }

    static func record(_ failure: ForkMeetingExportFailure, target: String, kind: ForkMeetingExportKind,
                       at: Date) -> ForkMeetingSidecar.Export {
        ForkMeetingSidecar.Export(exporter: kind.rawValue, at: at, status: Status.failed.rawValue, target: target,
                                  reason: failure.code, httpStatus: failure.httpStatus)
    }

    /// The latest attempt for `target`, by its place in the list (appended
    /// in order), whatever the clock said. A record of a status this version
    /// does not know does not count.
    static func lastResult(_ exports: [ForkMeetingSidecar.Export], target: String) -> Result? {
        for record in exports.reversed() where record.target == target {
            guard let status = record.status.flatMap(Status.init(rawValue:)) else { continue }
            let failure = status == .failed ? ForkMeetingExportFailure(code: record.reason, httpStatus: record.httpStatus) : nil
            return Result(status: status, at: record.at, failure: failure)
        }
        return nil
    }
}

// MARK: - What leaves the folder

/// The `meeting.json` that leaves the Mac: the meeting's own, without what
/// only matters here (the history of its exports) and without the Google
/// Meet code unless asked, since it lets anyone with it in.
enum ForkMeetingExportDocument {
    static let transcriptExtension = "txt"

    static func json(_ sidecar: ForkMeetingSidecar, includesMeetCode: Bool) throws -> Data {
        var shared = sidecar
        shared.exports = nil
        shared.preserved["exports"] = nil
        if !includesMeetCode {
            shared.meetCode = nil
            shared.preserved["meetCode"] = nil
        }
        return try shared.encoded()
    }

    /// The transcript of the folder, when there is one: the `.txt` named
    /// after the folder, else the only `.txt` there.
    static func transcript(in names: [String], folderName: String) -> String? {
        let texts = names.filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == transcriptExtension }
        if let own = texts.first(where: { ($0 as NSString).deletingPathExtension == folderName }) { return own }
        return texts.count == 1 ? texts[0] : nil
    }
}

// MARK: - Said

extension ForkMeetingExportKind {
    func name(_ strings: ForkMeetingStrings) -> String {
        switch self {
        case .dropFolder: return strings.exportKindDropFolder
        case .webhook: return strings.exportKindWebhook
        }
    }
}

extension ForkMeetingExporterConfig {
    /// "Drop folder — Shared", "HTTPS webhook — hooks.example.org".
    func title(_ strings: ForkMeetingStrings) -> String {
        guard let detail else { return kind.name(strings) }
        return "\(kind.name(strings)) — \(detail)"
    }
}

extension ForkMeetingOriginPolicy.Refusal {
    func message(_ strings: ForkMeetingStrings) -> String {
        switch self {
        case .unreadable: return strings.originUnreadable
        case .notHTTPS: return strings.originNotHTTPS
        case .credentialsInURL: return strings.originCredentials
        case .fragmentInURL: return strings.originFragment
        case let .nonASCIIHost(wire): return wire.map(strings.originNonASCII) ?? strings.originUnreadable
        case .unapprovedHost: return strings.exportFailOriginChanged
        }
    }
}

extension ForkMeetingExportFailure {
    /// A whole sentence, beside the exporter's Retry.
    func message(_ strings: ForkMeetingStrings) -> String {
        switch self {
        case .inProgress: return strings.refusedWhileRecording
        case .unreadable: return strings.exportFailUnreadable
        case .noAudio: return strings.exportFailNoAudio
        case .folderMissing: return strings.exportFailFolder
        case .folderInsideLibrary: return strings.dropFolderInsideLibrary
        case .writeFailed: return strings.exportFailWrite
        case let .refusedAddress(refusal): return refusal.message(strings)
        case .originChanged: return strings.exportFailOriginChanged
        case .noSecret: return strings.exportFailNoSecret
        case .redirected: return strings.exportFailRedirect
        case let .status(status): return strings.exportFailStatus(status)
        case .network: return strings.exportFailNetwork
        case .notConfigured: return strings.exportFailNotConfigured
        }
    }
}
