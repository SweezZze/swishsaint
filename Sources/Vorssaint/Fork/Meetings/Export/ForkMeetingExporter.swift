// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CryptoKit
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
/// - What leaves is a list of fields, never the meeting.json minus some
///   (`ForkMeetingExportDocument`): a field added later stays on the Mac
///   until it is named there.
protocol ForkMeetingExporter {
    /// The settings it sends with.
    var config: ForkMeetingExporterConfig { get }
    /// The exporter's own id among the configured ones: the `target` of
    /// its records in `meeting.json`.
    var id: String { get }
    var kind: ForkMeetingExportKind { get }
    /// Has what it needs to send (a folder, an address and its secret).
    var isConfigured: Bool { get }
    var mode: ForkMeetingExportMode { get }
    /// Throws what keeps it from sending, before anything is gathered: no
    /// folder, no address, an origin changed, no secret.
    func check() throws
    /// Sends one meeting. Off the main thread; throws a
    /// `ForkMeetingExportFailure`.
    func export(_ package: ForkMeetingExportPackage, progress: @escaping (Double) -> Void) async throws -> ForkMeetingExportReceipt
}

/// The kinds of exporters. Written in `meeting.json` (`exports[].exporter`)
/// and in the settings: names never change, new ones are only added.
enum ForkMeetingExportKind: String, Codable, CaseIterable {
    case dropFolder
    case webhook
    case immich
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
    /// leaves the folder unless the person asks for it, from the title and
    /// the names too.
    var includesMeetCode = false
    /// The notes are the person's own: left out unless asked.
    var includesNotes = false
    /// The summary Apple Intelligence wrote on this Mac: left out unless
    /// asked (Finish E).
    var includesSummary = false
    /// Drop folder: the folder's path, as chosen in the panel.
    var folder: String?
    /// Webhook: the address as saved.
    var address: String?
    /// Webhook: the origin (`host` or `host:port`) frozen when the address
    /// was saved. A different one means the address changed behind the
    /// page's back: nothing is sent and the secret is never read.
    var origin: String?
    /// Immich: the album the meeting's video joins, made when missing;
    /// none, the video only lands in the timeline.
    var album: String?

    /// Sends to an address with a secret in the Keychain: a webhook, an
    /// Immich server (its API key).
    var usesAddress: Bool { kind == .webhook || kind == .immich }

    init(id: String = UUID().uuidString, kind: ForkMeetingExportKind, mode: ForkMeetingExportMode = .manual,
         includesMeetCode: Bool = false, includesNotes: Bool = false, includesSummary: Bool = false,
         folder: String? = nil, address: String? = nil, origin: String? = nil, album: String? = nil) {
        self.album = album
        self.id = id
        self.kind = kind
        self.mode = mode
        self.includesMeetCode = includesMeetCode
        self.includesNotes = includesNotes
        self.includesSummary = includesSummary
        self.folder = folder
        self.address = address
        self.origin = origin
    }

    /// The Keychain account of a webhook's secret: one per exporter and per
    /// origin (`webhook@<host[:port]>#<id>`), so an address rewritten in the
    /// preferences finds no secret instead of the real one, and two
    /// exporters never share one without a word.
    var secretAccount: String? {
        guard usesAddress, let origin, !origin.isEmpty else { return nil }
        return Self.secretAccount(origin: origin, id: id, kind: kind)
    }

    /// An Immich key is filed apart from a webhook's secret
    /// (`immich@<host[:port]>#<id>`): neither kind ever reads the other's.
    static func secretAccount(origin: String, id: String, kind: ForkMeetingExportKind = .webhook) -> String {
        "\(kind == .immich ? "immich" : "webhook")@\(origin)#\(id)"
    }

    /// What the page and the menus call it after its kind: the folder's
    /// name, or the host.
    var detail: String? {
        switch kind {
        case .dropFolder:
            guard let folder, !folder.isEmpty else { return nil }
            return (folder as NSString).lastPathComponent
        case .webhook, .immich:
            return origin
        }
    }
}

extension ForkMeetingExporterConfig {
    /// A webhook's address to send to and its secret's account, once the
    /// origin policy and the frozen origin agree; else why not.
    func approvedTarget() throws -> (url: URL, account: String) {
        guard let address, !address.isEmpty, let frozenName = origin else {
            throw ForkMeetingExportFailure.notConfigured
        }
        guard let frozen = ForkMeetingOriginPolicy.Origin(name: frozenName) else { throw ForkMeetingExportFailure.originChanged }
        switch ForkMeetingOriginPolicy.destination(address, frozen: frozen) {
        case let .approved(url, origin):
            return (url, Self.secretAccount(origin: origin.name, id: id, kind: kind))
        case .refused(.unapprovedHost):
            throw ForkMeetingExportFailure.originChanged
        case let .refused(refusal):
            throw ForkMeetingExportFailure.refusedAddress(refusal)
        }
    }

    /// What keeps this exporter from sending, as far as its settings and
    /// the Keychain's list of secrets say; `nil` when it is set up.
    func readiness(hasSecret: (String) -> Bool) -> ForkMeetingExportFailure? {
        switch kind {
        case .dropFolder:
            return (folder ?? "").isEmpty ? .notConfigured : nil
        case .webhook, .immich:
            do {
                let target = try approvedTarget()
                return hasSecret(target.account) ? nil : .noSecret
            } catch {
                return error as? ForkMeetingExportFailure ?? .notConfigured
            }
        }
    }
}

extension ForkMeetingExporterList {
    /// What the page says of the list read, against the fingerprint the
    /// Keychain keeps (`ForkMeetingExports`).
    enum State: Equatable {
        /// The page's own list, or no exporter at all.
        case matches
        /// Rewritten outside the page.
        case changed
        /// No fingerprint yet: a list of an earlier version.
        case unconfirmed
        /// The Keychain refused to read or to keep the fingerprint.
        case keychainRefused
    }

    /// - `fingerprint`: the one the Keychain gave, `nil` when it has none.
    /// - `keychainFailed`: it refused, or did not answer in time.
    static func state(_ stored: String?, fingerprint saved: String?, keychainFailed: Bool) -> State {
        guard !decode(stored).isEmpty else { return .matches }
        if keychainFailed { return .keychainRefused }
        guard let saved, !saved.isEmpty else { return .unconfirmed }
        return matches(stored, fingerprint: saved) ? .matches : .changed
    }

    /// The secrets an earlier version filed by host alone
    /// (`webhook@<host[:port]>`): each goes to the account of the first
    /// webhook of that host, then the old one is erased.
    static func legacyMoves(_ configs: [ForkMeetingExporterConfig]) -> [(from: String, to: String)] {
        var seen = Set<String>()
        return configs.compactMap { config in
            guard config.kind == .webhook, let origin = config.origin, !origin.isEmpty, let account = config.secretAccount,
                  seen.insert(origin).inserted else { return nil }
            return ("webhook@\(origin)", account)
        }
    }

    /// The exporters set up, in their order: the only ones the library
    /// names (§7.1: no exporter set up, no word of exporting).
    static func configured(_ configs: [ForkMeetingExporterConfig],
                           hasSecret: (String) -> Bool) -> [ForkMeetingExporterConfig] {
        configs.filter { $0.readiness(hasSecret: hasSecret) == nil }
    }
}

extension ForkMeetingExporterConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, mode, includesMeetCode, includesNotes, includesSummary, folder, address, origin, album
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
        includesNotes = ((try? container.decodeIfPresent(Bool.self, forKey: .includesNotes)) ?? nil) ?? false
        includesSummary = ((try? container.decodeIfPresent(Bool.self, forKey: .includesSummary)) ?? nil) ?? false
        folder = (try? container.decodeIfPresent(String.self, forKey: .folder)) ?? nil
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? nil
        origin = (try? container.decodeIfPresent(String.self, forKey: .origin)) ?? nil
        album = (try? container.decodeIfPresent(String.self, forKey: .album)) ?? nil
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

    /// What the Keychain keeps of the list the page wrote
    /// (`ForkMeetingExports`): the SHA-256 of the setting as stored, in
    /// hexadecimal. Another process may write the preferences, not that
    /// item: a list it rewrote no longer matches, and nothing is sent on
    /// its own until the page confirms it.
    static func fingerprint(_ stored: String?) -> String {
        SHA256.hash(data: Data((stored ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the list read matches what the page last wrote. An empty
    /// list sends nothing: it always matches.
    static func matches(_ stored: String?, fingerprint saved: String?) -> Bool {
        guard !decode(stored).isEmpty else { return true }
        guard let saved, !saved.isEmpty else { return false }
        return fingerprint(stored) == saved
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
/// `meeting.json`, its audio as an M4A ready to be read, its transcript
/// when there is one, and its summary's text when there is one.
struct ForkMeetingExportPackage {
    /// The meeting folder's name.
    let folderName: String
    let sidecar: ForkMeetingSidecar
    let audio: URL
    let transcript: URL?
    /// The summary written on this Mac; sent only when the exporter asks
    /// (`includesSummary`).
    var summary: String? = nil
    /// The meeting's video, read in place, when it has one (Immich).
    var video: URL?

    /// The name of what is sent: the folder's, without the Google Meet code
    /// unless asked (`ForkMeetingExportDocument.name`).
    func name(includesMeetCode: Bool) -> String {
        ForkMeetingExportDocument.name(folderName, meetCode: sidecar.meetCode, includesMeetCode: includesMeetCode)
    }

    static func audioName(_ name: String) -> String { "\(name).\(ForkMeetingFolder.audioExtension)" }
    static func transcriptName(_ name: String) -> String { "\(name).\(ForkMeetingExportDocument.transcriptExtension)" }
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
    /// The Keychain refused, or did not answer in time.
    case keychain
    /// The address's certificate was refused: not a network failure.
    case certificate
    /// The disk of this Mac had no room for the copy or the body.
    case temporarySpace
    /// The address answered before the whole meeting reached it: nothing
    /// says it was received.
    case earlyAnswer
    /// The list of exporters was changed outside the page: nothing is sent
    /// on its own until the page confirms it.
    case listChanged
    /// The drop folder's own disk is full.
    case dropFolderFull
    /// The meeting has no video: Immich keeps photos and videos only.
    case noVideo

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
        case .keychain: return "keychain"
        case .certificate: return "certificate"
        case .temporarySpace: return "temporarySpace"
        case .earlyAnswer: return "earlyAnswer"
        case .listChanged: return "listChanged"
        case .dropFolderFull: return "dropFolderFull"
        case .noVideo: return "noVideo"
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
        case "keychain": self = .keychain
        case "certificate": self = .certificate
        case "temporarySpace": self = .temporarySpace
        case "earlyAnswer": self = .earlyAnswer
        case "listChanged": self = .listChanged
        case "dropFolderFull": self = .dropFolderFull
        case "noVideo": self = .noVideo
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

extension ForkMeetingExportFailure {
    /// No room left, as Foundation, POSIX or AVFoundation says it.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        // AVFoundation's "disk full" (AVError.diskFull).
        if error.domain == "AVFoundationErrorDomain", error.code == -11807 { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isOutOfSpace) ?? false
    }
}

// MARK: - Leftovers

/// What a send cut short leaves (a webhook's body, a staged M4A, a drop
/// folder's draft) is named with the process that made it,
/// `<prefix><pid>-<uuid>`: at launch, only this process's own or one older
/// than a day goes, never what another copy of the app is sending now.
enum ForkMeetingLeftovers {
    static let maximumAge: TimeInterval = 24 * 3600

    static func name(_ prefix: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        "\(prefix)\(pid)-\(UUID().uuidString)"
    }

    static func removable(_ name: String, prefix: String, pid: Int32, modified: Date?, now: Date) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let digits = name.dropFirst(prefix.count).prefix { $0.isNumber }
        if Int32(digits) == pid, name.dropFirst(prefix.count + digits.count).first == "-" { return true }
        guard let modified else { return false }
        return now.timeIntervalSince(modified) > maximumAge
    }
}

// MARK: - Eligibility

/// Which meetings may go: never one being written; never on its own one
/// that did not end well, or that already went there.
enum ForkMeetingExportEligibility {
    /// The only ends after which a meeting goes on its own: the person's
    /// Stop, or the call over. A disk full, a permission taken back, a
    /// sleep, the feature turned off, the capture stopped, a crash, a quit
    /// or a cancel each wait for a click.
    static let automaticStopReasons: Set<ForkMeetingStopReason> = [.user, .meetingEnded]

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
            && meeting.stopReason.map(automaticStopReasons.contains) == true
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

    /// The list row's mark (§4.5): ✗ when the latest attempt of one of
    /// `targets` failed, else ✓ when one went, else nothing.
    enum Mark: Equatable {
        case done
        case failed
    }

    static func mark(_ exports: [ForkMeetingSidecar.Export], targets: [String]) -> Mark? {
        let results = targets.compactMap { lastResult(exports, target: $0) }
        if results.contains(where: { $0.status == .failed }) { return .failed }
        return results.isEmpty ? nil : .done
    }
}

// MARK: - On its own

/// What becomes of one automatic exporter once a meeting is finalized,
/// before any file is read.
enum ForkMeetingAutomaticExport {
    enum Plan: Equatable {
        /// Nothing, not even a record: the feature is off, or the exporter
        /// sends only when asked.
        case none
        /// Sent, if the meeting itself may go (`ForkMeetingExportEligibility`).
        case send
        /// Not sent, and said: written in the meeting's history with its
        /// Retry, and in a notice.
        case fail(ForkMeetingExportFailure)
    }

    /// - `featureOn`: the Meetings feature, read at that moment.
    /// - `listMatches`: the list read matches the page's
    ///   (`ForkMeetingExporterList.matches`).
    /// - `readiness`: what the exporter's `check()` threw, if anything.
    static func plan(mode: ForkMeetingExportMode, featureOn: Bool, listMatches: Bool,
                     readiness: ForkMeetingExportFailure?) -> Plan {
        guard featureOn, mode == .automatic else { return .none }
        guard listMatches else { return .fail(.listChanged) }
        if let readiness { return .fail(readiness) }
        return .send
    }
}

// MARK: - What leaves the folder

/// The `meeting.json` that leaves the Mac: **a list of fields**, never the
/// meeting's own minus some. A field this version writes later, or one it
/// does not know (a later version's), stays here until it is named below.
///
/// - Always: `id`, `schema`, `title` (without the Google Meet code unless
///   asked), `startedAt`, `endedAt`, `recordedSeconds`, `provider`,
///   `origin`, `pauses`, `markers` (each one's time only), and `transcript`
///   when there is one.
/// - Only when asked: `notes`, `summary` (the Markdown written on this Mac,
///   when there is one), `meetCode`.
/// - Never: the microphone's name, the app, the calendar event, the
///   history of the exports, a path.
enum ForkMeetingExportDocument {
    static let transcriptExtension = "txt"

    /// Every key that may leave, in the order of the list above.
    static let fields = ["id", "schema", "title", "startedAt", "endedAt", "recordedSeconds", "provider", "origin",
                         "pauses", "markers", "transcript", "notes", "summary", "meetCode"]
    /// The keys of each pause.
    static let pauseFields = ["at", "seconds", "reason"]
    /// The keys of each marker.
    static let markerFields = ["at"]

    static func json(_ sidecar: ForkMeetingSidecar, includesMeetCode: Bool, includesNotes: Bool,
                     includesSummary: Bool = false, summary: String? = nil) throws -> Data {
        let times = ForkMeetingMarkers.times(sidecar.markers)
        let sharedSummary = includesSummary ? summary.flatMap { text -> String? in
            let kept = includesMeetCode ? text : removingMeetCodes(text, meetCode: sidecar.meetCode)
            return kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : kept
        } : nil
        let shared = Shared(
            id: sidecar.id, schema: sidecar.schema,
            title: title(sidecar.title, meetCode: sidecar.meetCode, includesMeetCode: includesMeetCode),
            startedAt: sidecar.startedAt, endedAt: sidecar.endedAt, recordedSeconds: sidecar.recordedSeconds,
            provider: sidecar.provider, origin: sidecar.origin,
            pauses: sidecar.pauses?.map { Shared.Pause(at: $0.at, seconds: $0.seconds, reason: $0.reason) },
            markers: sidecar.markers == nil ? nil : times.map { Shared.Marker(at: $0) },
            transcript: transcript(sidecar.transcript),
            notes: includesNotes ? sidecar.notes.map { includesMeetCode ? $0 : removingMeetCodes($0, meetCode: sidecar.meetCode) } : nil,
            summary: sharedSummary,
            meetCode: includesMeetCode ? sidecar.meetCode : nil)
        return try ForkMeetingSidecar.encoder().encode(shared)
    }

    /// What is written, field by field: only these.
    private struct Shared: Encodable {
        struct Pause: Encodable {
            let at: Double?
            let seconds: Double?
            let reason: ForkMeetingPauseReason?
        }

        struct Marker: Encodable {
            let at: Double
        }

        let id: UUID?
        let schema: Int?
        let title: String?
        let startedAt: Date?
        let endedAt: Date?
        let recordedSeconds: Double?
        let provider: String?
        let origin: ForkMeetingOrigin?
        let pauses: [Pause]?
        let markers: [Marker]?
        let transcript: ForkMeetingJSON?
        let notes: String?
        let summary: String?
        let meetCode: String?
    }

    /// The title sent: without the Google Meet code unless asked
    /// ("Google Meet · abc-defg-hij" → "Google Meet"); `nil` when nothing is
    /// left of it.
    static func title(_ title: String?, meetCode: String?, includesMeetCode: Bool) -> String? {
        guard let title else { return nil }
        let kept = includesMeetCode ? title : withoutMeetCode(title, meetCode: meetCode)
        let trimmed = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name of the folder and the files sent: the meeting folder's,
    /// without the Google Meet code unless asked
    /// ("2026-10-19 10h02 — Google Meet · abc-defg-hij" →
    /// "2026-10-19 10h02 — Google Meet"). Never empty.
    static func name(_ folderName: String, meetCode: String?, includesMeetCode: Bool) -> String {
        guard !includesMeetCode else { return folderName }
        let cleaned = withoutMeetCode(folderName, meetCode: meetCode)
        return cleaned.isEmpty ? "meeting" : cleaned
    }

    /// The text without its Google Meet codes (the meeting's own, and any
    /// other of that shape), and without the separator they leave alone.
    static func withoutMeetCode(_ text: String, meetCode: String?) -> String {
        tidied(removingMeetCodes(text, meetCode: meetCode))
    }

    /// The text without its Google Meet codes, and nothing else changed:
    /// the notes keep their lines.
    static func removingMeetCodes(_ text: String, meetCode: String?) -> String {
        var text = text
        if let meetCode, !meetCode.isEmpty {
            while let range = text.range(of: meetCode, options: .caseInsensitive) { text.removeSubrange(range) }
        }
        // Each pass removes one: the shape's own rule finds the next.
        for _ in 0..<16 {
            guard let code = ForkMeetingTitleRules.meetCode(in: text),
                  let range = text.range(of: code, options: .caseInsensitive) else { break }
            text.removeSubrange(range)
        }
        return text
    }

    /// Spaces in one, and no separator left with nothing after it, or
    /// before a disambiguation's "(2)".
    private static func tidied(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: "·•|–—-:,/").union(.whitespacesAndNewlines)
        var text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        // "Meeting (abc-defg-hij)" leaves no "()" behind.
        text = text.replacingOccurrences(of: #"\s*(\(\s*\)|\[\s*\])"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*[·•|–—:,/-]\s*(?=\(\d+\)$)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\s[·•|–—:,/-])+(?=\s[·•|–—:,/-]\s)"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: separators)
    }

    /// The transcript file of the folder: the `.txt` the transcription
    /// wrote, by the names `meeting.json` keeps (`transcript.files`), still
    /// in the folder; never another text the person left there, even one
    /// named after the folder or the video.
    static func transcript(in names: [String], files: [String]) -> String? {
        files.lazy.filter { ($0 as NSString).pathExtension.lowercased() == transcriptExtension && !$0.hasPrefix(".") }
            .compactMap { file in names.first { $0.lowercased() == file.lowercased() } }
            .first
    }

    /// The `transcript` of `meeting.json`, as its own list of fields: the
    /// shape the transcription writes (`state`, `words`, `language`,
    /// `engine`, `at`), plain values only; nothing until that shape is
    /// there, nothing else under it.
    static let transcriptFields = ["state", "words", "language", "engine", "at"]

    static func transcript(_ value: ForkMeetingJSON?) -> ForkMeetingJSON? {
        guard case let .object(fields)? = value, case .string? = fields["state"], case .string? = fields["engine"] else {
            return nil
        }
        func plain(_ value: ForkMeetingJSON) -> Bool {
            switch value {
            case .null, .bool, .number, .string: return true
            case let .array(items): return items.allSatisfy { if case .object = $0 { return false }; if case .array = $0 { return false }; return true }
            case .object: return false
            }
        }
        var kept: [String: ForkMeetingJSON] = [:]
        for key in transcriptFields { if let value = fields[key], plain(value) { kept[key] = value } }
        return .object(kept)
    }
}

// MARK: - Said

extension ForkMeetingExportKind {
    func name(_ strings: ForkMeetingStrings) -> String {
        switch self {
        case .dropFolder: return strings.exportKindDropFolder
        case .webhook: return strings.exportKindWebhook
        case .immich: return "Immich"
        }
    }
}

extension ForkMeetingExportKind {
    var symbol: String {
        switch self {
        case .dropFolder: return "folder"
        case .webhook: return "network"
        case .immich: return "photo.on.rectangle.angled"
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
        case .keychain: return strings.exportFailKeychain
        case .certificate: return strings.exportFailCertificate
        case .temporarySpace: return strings.exportFailTemporarySpace
        case .earlyAnswer: return strings.exportFailEarlyAnswer
        case .listChanged: return strings.exportFailListUnconfirmed
        case .dropFolderFull: return strings.exportFailDropFolderFull
        case .noVideo: return strings.exportFailNoVideo
        }
    }
}
