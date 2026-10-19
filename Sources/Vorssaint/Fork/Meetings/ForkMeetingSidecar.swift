// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// How a meeting began: from the record button or shortcut, from an offer
/// the person accepted, or on its own for an app set to "Always". Written in
/// every `meeting.json`, so the names never change.
enum ForkMeetingOrigin: String, Codable, CaseIterable {
    case manual
    case offered
    case always
}

/// Why a meeting stopped. Written in `meeting.json`: names never change, and
/// new ones are only ever added.
enum ForkMeetingStopReason: String, Codable, CaseIterable {
    /// The person's Stop.
    case user
    /// The meeting app said the call was over.
    case meetingEnded
    /// The disk ran low.
    case disk
    /// Screen Recording was taken back.
    case permission
    /// The Mac slept and the meeting was over at the wake.
    case sleep
    /// The app quit while recording.
    case quit
    /// Found unfinished at a launch, after a crash.
    case crash
    /// The feature was turned off while recording.
    case featureDisabled
    /// macOS or the capture itself stopped it.
    case captureStopped
    /// "Cancel" after a start "Always" made: its folder goes to the Trash,
    /// at the next launch if the app ended before (never recovered).
    case cancelled
}

/// Why a recording paused. A locked screen is not one: it pauses nothing,
/// and is noted as a gap. A value this version does not know is kept as it
/// was written (`preserved`).
enum ForkMeetingPauseReason: String, Codable, CaseIterable {
    case user
    case sleep
}

/// What the picture follows: the meeting's window, or the display it is on.
enum ForkMeetingCaptureTarget: String, Codable, CaseIterable {
    case window
    case display

    static let fallback: ForkMeetingCaptureTarget = .window

    init(stored: String?) {
        self = ForkMeetingCaptureTarget(rawValue: stored ?? "") ?? .fallback
    }
}

/// The Mac's sound: the meeting app's own, the whole Mac's, or none.
enum ForkMeetingSystemAudio: String, Codable, CaseIterable {
    case app
    case all
    case off

    static let fallback: ForkMeetingSystemAudio = .app

    init(stored: String?) {
        self = ForkMeetingSystemAudio(rawValue: stored ?? "") ?? .fallback
    }
}

/// A JSON value kept as it was read, for what this version of the app does
/// not understand: written back untouched, never dropped.
enum ForkMeetingJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ForkMeetingJSON])
    case object([String: ForkMeetingJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ForkMeetingJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ForkMeetingJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// `meeting.json`: what a meeting folder says about its meeting.
///
/// - **Every field is optional when read.** Swift's synthesized decoding
///   ignores default values, so one required field added later would make
///   every file already on the disk unreadable, and the library would empty
///   itself without a word.
/// - **Nothing is ever lost.** A key this version does not know (written by
///   a later one), or a value it cannot read (an unknown state), is kept in
///   `preserved` and written back as it was.
/// - **A file that does not decode is never rewritten**: it may still be
///   repaired by hand (`ForkMeetingSidecarFault`).
/// - Stable on the disk: sorted keys, ISO 8601 dates in UTC, whole seconds.
struct ForkMeetingSidecar: Equatable {
    static let currentSchema = 1

    enum State: String, Codable, CaseIterable {
        /// Being written. Found at a launch: the app died while recording.
        case recording
        /// The final pass runs.
        case finalizing
        case complete
        /// Never closed properly: kept, flagged in the library, recovered
        /// when its master is still readable.
        case interrupted
    }

    enum TitleSource: String, Codable, CaseIterable {
        case window
        case calendar
        case user
        case provider
    }

    enum FinalPass: String, Codable, CaseIterable {
        case done
        /// No room for the copy: the master became the final file, with its
        /// separate tracks.
        case skippedDisk = "skipped-disk"
        case failed
    }

    enum GapKind: String, Codable, CaseIterable {
        /// The microphone changed and its input was rebuilt.
        case microphoneSwitch
        /// The capture restarted (after a sleep, a lost stream).
        case streamRestart
        /// The screen was locked: the sound went on, the picture froze.
        case screenLocked
        /// Not a loss: ⧉ switched the picture between the window and the
        /// display (`seconds` 0). `capture.target` is the start's; each switch
        /// flips it.
        case targetSwitch
        /// The meeting app's sound was lost from here on (`seconds` 0): its
        /// tap lost its reader, and nothing else hears that app alone.
        case soundLost
    }

    /// `at` and every time below are seconds of recording, pauses excluded;
    /// `seconds` of a pause is time on the clock. Like the sidecar, each
    /// object below keeps the keys it does not know (`preserved`), written
    /// back as they were.
    struct Pause: Equatable {
        var at: Double?
        var seconds: Double?
        var reason: ForkMeetingPauseReason?
        var preserved: [String: ForkMeetingJSON] = [:]
    }

    struct Gap: Equatable {
        var at: Double?
        var seconds: Double?
        var kind: GapKind?
        var preserved: [String: ForkMeetingJSON] = [:]
    }

    struct Capture: Equatable {
        /// Wanted, not allowed: the meeting was recorded without it.
        static let microphoneDenied = "denied"

        var target: ForkMeetingCaptureTarget?
        var systemAudio: ForkMeetingSystemAudio?
        /// The microphone's name as recorded, or "off", or "denied".
        var microphone: String?
        var quality: ForkMeetingQuality?
        var preserved: [String: ForkMeetingJSON] = [:]
    }

    /// One attempt to send the meeting somewhere (`ForkMeetingExportHistory`):
    /// appended, never rewritten.
    struct Export: Equatable {
        /// The kind: `dropFolder`, `webhook`.
        var exporter: String?
        var at: Date?
        /// `done` or `failed`.
        var status: String?
        /// Which configured exporter, by its id.
        var target: String?
        /// Why it failed (`ForkMeetingExportFailure.code`).
        var reason: String?
        /// What the address answered.
        var httpStatus: Int?
        var preserved: [String: ForkMeetingJSON] = [:]
    }

    var schema: Int?
    var id: UUID?
    var state: State?
    var origin: ForkMeetingOrigin?
    var title: String?
    var titleSource: TitleSource?
    /// The provider's id ("meet", "zoom"), from the detection.
    var provider: String?
    var meetCode: String?
    /// The meeting app's bundle identifier.
    var app: String?
    var startedAt: Date?
    /// Only once the recording really closed: never after a failure, so a
    /// missing end is the mark of a meeting that did not end well.
    var endedAt: Date?
    var recordedSeconds: Double?
    var pauses: [Pause]?
    var capture: Capture?
    var gaps: [Gap]?
    var stopReason: ForkMeetingStopReason?
    var recovered: Bool?
    var finalPass: FinalPass?
    var calendarEventID: String?
    var notes: String?
    var exports: [Export]?
    /// Not written yet: the transcript arrives with its own part of the
    /// feature, and its shape with it.
    var transcript: ForkMeetingJSON?
    /// What this version could not read or does not know, written back as is.
    var preserved: [String: ForkMeetingJSON] = [:]

    /// The sidecar written when a meeting's folder is made, before anything
    /// is recorded: from then on a missing end means the meeting did not end
    /// well.
    /// A detected meeting adds its provider, its Google Meet code and its
    /// app.
    static func started(id: UUID, startedAt: Date, origin: ForkMeetingOrigin, title: String?,
                        titleSource: TitleSource?, capture: Capture, provider: String? = nil,
                        meetCode: String? = nil, app: String? = nil) -> ForkMeetingSidecar {
        var sidecar = ForkMeetingSidecar()
        sidecar.schema = currentSchema
        sidecar.id = id
        sidecar.state = .recording
        sidecar.origin = origin
        sidecar.title = title
        sidecar.titleSource = title == nil ? nil : titleSource
        sidecar.provider = provider
        sidecar.meetCode = meetCode
        sidecar.app = app
        sidecar.startedAt = startedAt
        sidecar.recordedSeconds = 0
        sidecar.pauses = []
        sidecar.gaps = []
        sidecar.capture = capture
        sidecar.recovered = false
        sidecar.notes = ""
        sidecar.exports = []
        return sidecar
    }

    /// A sidecar written by a later version of the app may mean something
    /// this one does not know: read, shown, never rewritten.
    var isRewritable: Bool { (schema ?? Self.currentSchema) <= Self.currentSchema }
}

// MARK: - Reading and writing

/// Why a `meeting.json` could not be read. "No sidecar" is normal (a folder
/// dropped by hand); one that will not decode is a fault, and maybe a file
/// someone can still repair by hand, so it is said and never overwritten.
enum ForkMeetingSidecarFault: Error, Equatable {
    case absent
    /// There, but the system refuses it: unmounted volume, rights taken away.
    case unreadable(String)
    /// There, read, and not a JSON object.
    case corrupt(String)

    /// Classifies an error met while reading the bytes: only a missing file
    /// is ordinary.
    static func reading(_ error: Error) -> ForkMeetingSidecarFault {
        let cocoa = error as NSError
        let missing = (cocoa.domain == NSCocoaErrorDomain
            && (cocoa.code == NSFileReadNoSuchFileError || cocoa.code == NSFileNoSuchFileError))
            || (cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(ENOENT))
        return missing ? .absent : .unreadable(cocoa.localizedDescription)
    }

    static func decoding(_ error: Error) -> ForkMeetingSidecarFault {
        .corrupt((error as NSError).localizedDescription)
    }

    /// Nothing to tell anyone about.
    var isNormal: Bool { self == .absent }
}

extension ForkMeetingSidecar {
    static func decode(_ data: Data) -> Result<ForkMeetingSidecar, ForkMeetingSidecarFault> {
        do {
            return .success(try decoder().decode(ForkMeetingSidecar.self, from: data))
        } catch {
            return .failure(.decoding(error))
        }
    }

    static func read(at url: URL) -> Result<ForkMeetingSidecar, ForkMeetingSidecarFault> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.reading(error))
        }
        return decode(data)
    }

    func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// The sidecar to write after `patch`, or `nil` when it must stay as it
    /// is on the disk: missing, unreadable, corrupt, or from a later version.
    static func rewriting(_ read: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
                          with patch: ForkMeetingSidecarPatch) -> ForkMeetingSidecar? {
        guard case let .success(sidecar) = read, sidecar.isRewritable else { return nil }
        return patch.applied(to: sidecar)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Reads ISO 8601 dates with or without fractions of a second: a file
    /// edited by hand, or by a later version, must not lose its dates.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }
}

extension ForkMeetingSidecar: Codable {
    private enum Field: String, CaseIterable {
        case schema, id, state, origin, title, titleSource, provider, meetCode, app, startedAt, endedAt,
             recordedSeconds, pauses, capture, gaps, stopReason, recovered, finalPass, calendarEventID, notes,
             exports, transcript
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        // Not an object: corrupt, and the caller never rewrites it.
        let container = try decoder.container(keyedBy: Key.self)
        var kept: [String: ForkMeetingJSON] = [:]
        func field<Value: Decodable>(_ field: Field) -> Value? {
            let key = Key(field.rawValue)
            guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else { return nil }
            if let value = try? container.decode(Value.self, forKey: key) { return value }
            kept[field.rawValue] = try? container.decode(ForkMeetingJSON.self, forKey: key)
            return nil
        }
        schema = field(.schema)
        id = field(.id)
        state = field(.state)
        origin = field(.origin)
        title = field(.title)
        titleSource = field(.titleSource)
        provider = field(.provider)
        meetCode = field(.meetCode)
        app = field(.app)
        startedAt = field(.startedAt)
        endedAt = field(.endedAt)
        recordedSeconds = field(.recordedSeconds)
        pauses = field(.pauses)
        capture = field(.capture)
        gaps = field(.gaps)
        stopReason = field(.stopReason)
        recovered = field(.recovered)
        finalPass = field(.finalPass)
        calendarEventID = field(.calendarEventID)
        notes = field(.notes)
        exports = field(.exports)
        transcript = field(.transcript)
        let known = Set(Field.allCases.map(\.rawValue))
        for key in container.allKeys where !known.contains(key.stringValue) {
            kept[key.stringValue] = try? container.decode(ForkMeetingJSON.self, forKey: key)
        }
        preserved = kept
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        var written = Set<String>()
        func put<Value: Encodable>(_ value: Value?, _ field: Field) throws {
            guard let value else { return }
            try container.encode(value, forKey: Key(field.rawValue))
            written.insert(field.rawValue)
        }
        try put(schema, .schema)
        try put(id, .id)
        try put(state, .state)
        try put(origin, .origin)
        try put(title, .title)
        try put(titleSource, .titleSource)
        try put(provider, .provider)
        try put(meetCode, .meetCode)
        try put(app, .app)
        try put(startedAt, .startedAt)
        try put(endedAt, .endedAt)
        try put(recordedSeconds, .recordedSeconds)
        try put(pauses, .pauses)
        try put(capture, .capture)
        try put(gaps, .gaps)
        try put(stopReason, .stopReason)
        try put(recovered, .recovered)
        try put(finalPass, .finalPass)
        try put(calendarEventID, .calendarEventID)
        try put(notes, .notes)
        try put(exports, .exports)
        try put(transcript, .transcript)
        for (key, value) in preserved where !written.contains(key) {
            try container.encode(value, forKey: Key(key))
        }
    }
}

// MARK: - The objects inside

/// The keys of one object of `meeting.json`.
private struct ForkMeetingSidecarObjectKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Reads a pause, a gap, the capture or an export as strictly as Swift's
/// synthesized decoding: a value this version cannot read fails the whole
/// object, which the sidecar then keeps as written rather than cut down to a
/// partial one. What it adds is the keys this version does not know, kept in
/// `unknown` for the object's `preserved`: a later version's `capture.fps`
/// survives a patch of this one.
private struct ForkMeetingSidecarObjectReader {
    let container: KeyedDecodingContainer<ForkMeetingSidecarObjectKey>
    let unknown: [String: ForkMeetingJSON]

    init<Field: RawRepresentable & CaseIterable>(_ decoder: Decoder, fields: Field.Type) throws
    where Field.RawValue == String {
        container = try decoder.container(keyedBy: ForkMeetingSidecarObjectKey.self)
        let known = Set(fields.allCases.map(\.rawValue))
        var kept: [String: ForkMeetingJSON] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            kept[key.stringValue] = try? container.decode(ForkMeetingJSON.self, forKey: key)
        }
        unknown = kept
    }

    func field<Value: Decodable, Field: RawRepresentable>(_ field: Field) throws -> Value?
    where Field.RawValue == String {
        try container.decodeIfPresent(Value.self, forKey: ForkMeetingSidecarObjectKey(field.rawValue))
    }
}

/// Writes one of those objects: its own fields, then what it kept.
private struct ForkMeetingSidecarObjectWriter {
    private var container: KeyedEncodingContainer<ForkMeetingSidecarObjectKey>

    init(_ encoder: Encoder) {
        container = encoder.container(keyedBy: ForkMeetingSidecarObjectKey.self)
    }

    mutating func put<Value: Encodable, Field: RawRepresentable>(_ value: Value?, _ field: Field) throws
    where Field.RawValue == String {
        try container.encodeIfPresent(value, forKey: ForkMeetingSidecarObjectKey(field.rawValue))
    }

    /// A kept key that this version now knows is never written twice: its
    /// own field wins.
    mutating func keep<Field: RawRepresentable & CaseIterable>(_ preserved: [String: ForkMeetingJSON],
                                                               besides fields: Field.Type) throws
    where Field.RawValue == String {
        let known = Set(fields.allCases.map(\.rawValue))
        for (key, value) in preserved where !known.contains(key) {
            try container.encode(value, forKey: ForkMeetingSidecarObjectKey(key))
        }
    }
}

extension ForkMeetingSidecar.Pause: Codable {
    private enum Field: String, CaseIterable { case at, seconds, reason }

    init(from decoder: Decoder) throws {
        let object = try ForkMeetingSidecarObjectReader(decoder, fields: Field.self)
        self.init(at: try object.field(Field.at), seconds: try object.field(Field.seconds),
                  reason: try object.field(Field.reason), preserved: object.unknown)
    }

    func encode(to encoder: Encoder) throws {
        var object = ForkMeetingSidecarObjectWriter(encoder)
        try object.put(at, Field.at)
        try object.put(seconds, Field.seconds)
        try object.put(reason, Field.reason)
        try object.keep(preserved, besides: Field.self)
    }
}

extension ForkMeetingSidecar.Gap: Codable {
    private enum Field: String, CaseIterable { case at, seconds, kind }

    init(from decoder: Decoder) throws {
        let object = try ForkMeetingSidecarObjectReader(decoder, fields: Field.self)
        self.init(at: try object.field(Field.at), seconds: try object.field(Field.seconds),
                  kind: try object.field(Field.kind), preserved: object.unknown)
    }

    func encode(to encoder: Encoder) throws {
        var object = ForkMeetingSidecarObjectWriter(encoder)
        try object.put(at, Field.at)
        try object.put(seconds, Field.seconds)
        try object.put(kind, Field.kind)
        try object.keep(preserved, besides: Field.self)
    }
}

extension ForkMeetingSidecar.Capture: Codable {
    private enum Field: String, CaseIterable { case target, systemAudio, microphone, quality }

    init(from decoder: Decoder) throws {
        let object = try ForkMeetingSidecarObjectReader(decoder, fields: Field.self)
        self.init(target: try object.field(Field.target), systemAudio: try object.field(Field.systemAudio),
                  microphone: try object.field(Field.microphone), quality: try object.field(Field.quality),
                  preserved: object.unknown)
    }

    func encode(to encoder: Encoder) throws {
        var object = ForkMeetingSidecarObjectWriter(encoder)
        try object.put(target, Field.target)
        try object.put(systemAudio, Field.systemAudio)
        try object.put(microphone, Field.microphone)
        try object.put(quality, Field.quality)
        try object.keep(preserved, besides: Field.self)
    }
}

extension ForkMeetingSidecar.Export: Codable {
    private enum Field: String, CaseIterable { case exporter, at, status, target, reason, httpStatus }

    init(from decoder: Decoder) throws {
        let object = try ForkMeetingSidecarObjectReader(decoder, fields: Field.self)
        self.init(exporter: try object.field(Field.exporter), at: try object.field(Field.at),
                  status: try object.field(Field.status), target: try object.field(Field.target),
                  reason: try object.field(Field.reason), httpStatus: try object.field(Field.httpStatus),
                  preserved: object.unknown)
    }

    func encode(to encoder: Encoder) throws {
        var object = ForkMeetingSidecarObjectWriter(encoder)
        try object.put(exporter, Field.exporter)
        try object.put(at, Field.at)
        try object.put(status, Field.status)
        try object.put(target, Field.target)
        try object.put(reason, Field.reason)
        try object.put(httpStatus, Field.httpStatus)
        try object.keep(preserved, besides: Field.self)
    }
}

/// A change to `meeting.json`, as the session machine asks for it. Only what
/// is set changes; pauses and gaps are appended.
struct ForkMeetingSidecarPatch: Equatable {
    var state: ForkMeetingSidecar.State?
    var stopReason: ForkMeetingStopReason?
    var endedAt: Date?
    var recordedSeconds: Double?
    var pause: ForkMeetingSidecar.Pause?
    var gap: ForkMeetingSidecar.Gap?
    /// The microphone now recording.
    var microphone: String?
    /// What the picture really followed at the start, when it was not the
    /// setting.
    var target: ForkMeetingCaptureTarget?
    /// What the meeting track really heard, when it was not the setting:
    /// the whole Mac, when no app's tap could hear the meeting app.
    var systemAudio: ForkMeetingSystemAudio?
    var recovered: Bool?
    var finalPass: ForkMeetingSidecar.FinalPass?
    /// One export attempt, appended to `exports`.
    var export: ForkMeetingSidecar.Export?

    /// A list or an object this version could not read is never replaced by
    /// a partial one: the addition is dropped rather than what was there.
    func applied(to sidecar: ForkMeetingSidecar) -> ForkMeetingSidecar {
        var result = sidecar
        if let state { result.state = state }
        if let stopReason { result.stopReason = stopReason }
        if let endedAt { result.endedAt = endedAt }
        if let recordedSeconds { result.recordedSeconds = recordedSeconds }
        if let pause, sidecar.preserved["pauses"] == nil { result.pauses = (result.pauses ?? []) + [pause] }
        if let gap, sidecar.preserved["gaps"] == nil { result.gaps = (result.gaps ?? []) + [gap] }
        if let export, sidecar.preserved["exports"] == nil { result.exports = (result.exports ?? []) + [export] }
        if microphone != nil || target != nil || systemAudio != nil, sidecar.preserved["capture"] == nil {
            var capture = result.capture ?? ForkMeetingSidecar.Capture()
            if let microphone { capture.microphone = microphone }
            if let target { capture.target = target }
            if let systemAudio { capture.systemAudio = systemAudio }
            result.capture = capture
        }
        if let recovered { result.recovered = recovered }
        if let finalPass { result.finalPass = finalPass }
        return result
    }
}
