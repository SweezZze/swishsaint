// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingSidecarTests {
    static func run(_ suite: TestSuite) {
        roundTrip(suite)
        planExample(suite)
        missingFields(suite)
        unknownContent(suite)
        corruption(suite)
        patches(suite)
        onDisk(suite)
    }

    private static let id = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8") ?? UUID()
    /// Whole seconds: the file does not keep fractions.
    private static let start = Date(timeIntervalSince1970: 1_792_310_531) // 2026-10-18T08:02:11Z

    private static func started() -> ForkMeetingSidecar {
        ForkMeetingSidecar.started(id: id, startedAt: start, origin: .manual, title: nil, titleSource: .user,
                                   capture: .init(target: .window, systemAudio: .app, microphone: "AirPods de Martial",
                                                  quality: .standard))
    }

    private static func decoded(_ json: String) -> ForkMeetingSidecar? {
        guard case let .success(sidecar) = ForkMeetingSidecar.decode(Data(json.utf8)) else { return nil }
        return sidecar
    }

    private static func text(_ sidecar: ForkMeetingSidecar) -> String {
        (try? sidecar.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func roundTrip(_ suite: TestSuite) {
        let first = started()
        suite.expect(first.schema == 1 && first.state == .recording && first.origin == .manual && first.endedAt == nil
                        && first.exports == [] && first.transcript == nil && first.recovered == false
                        && first.titleSource == nil,
                     "a meeting's first sidecar says recording, schema 1, no end, no export and no transcript yet")
        suite.expect(decoded(text(first)) == first, "a sidecar comes back from the disk exactly as written")
        let json = text(first)
        suite.expect(json.contains("\"startedAt\" : \"2026-10-18T08:02:11Z\""), "dates are written in ISO 8601, in UTC")
        let keys = ["\"capture\"", "\"exports\"", "\"id\"", "\"origin\"", "\"schema\"", "\"startedAt\"", "\"state\""]
        let positions = keys.compactMap { json.range(of: $0)?.lowerBound }
        suite.expect(positions.count == keys.count && positions == positions.sorted(),
                     "keys are written in a stable, sorted order")
        suite.expect(text(first) == text(decoded(text(first)) ?? first),
                     "writing a sidecar twice gives the same bytes")
        suite.expect(!json.contains("endedAt") && !json.contains("transcript"),
                     "what is not known yet is not written")
    }

    /// The example of the plan, §5.5.
    private static func planExample(_ suite: TestSuite) {
        let json = """
        {
          "schema": 1,
          "id": "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8",
          "state": "complete",
          "origin": "offered",
          "title": "Point hebdo Opah",
          "titleSource": "user",
          "provider": "meet", "meetCode": "abc-defg-hij", "app": "com.google.Chrome",
          "startedAt": "2026-10-18T08:02:11Z", "endedAt": "2026-10-18T08:54:20Z",
          "recordedSeconds": 2829, "pauses": [{"at": 610, "seconds": 300, "reason": "user"}],
          "capture": {"target": "window", "systemAudio": "app", "microphone": "AirPods de Martial", "quality": "standard"},
          "gaps": [{"at": 1500, "seconds": 1.4, "kind": "microphoneSwitch"}],
          "stopReason": "meetingEnded",
          "recovered": false, "finalPass": "done",
          "calendarEventID": null, "notes": "",
          "exports": [{"exporter": "dropFolder", "at": "2026-10-18T08:55:02Z", "status": "done"}],
          "transcript": null
        }
        """
        guard let meeting = decoded(json) else {
            suite.expect(false, "the plan's example decodes")
            return
        }
        suite.expect(meeting.id == id && meeting.state == .complete && meeting.origin == .offered
                        && meeting.title == "Point hebdo Opah" && meeting.titleSource == .user && meeting.provider == "meet"
                        && meeting.meetCode == "abc-defg-hij" && meeting.app == "com.google.Chrome"
                        && meeting.startedAt == start && meeting.endedAt == Date(timeIntervalSince1970: 1_792_313_660)
                        && meeting.recordedSeconds == 2829,
                     "the plan's example reads with every field")
        suite.expect(meeting.pauses == [.init(at: 610, seconds: 300, reason: .user)]
                        && meeting.gaps == [.init(at: 1500, seconds: 1.4, kind: .microphoneSwitch)]
                        && meeting.capture == .init(target: .window, systemAudio: .app, microphone: "AirPods de Martial",
                                                    quality: .standard)
                        && meeting.stopReason == .meetingEnded && meeting.recovered == false && meeting.finalPass == .done
                        && meeting.notes == "" && meeting.exports?.first?.exporter == "dropFolder",
                     "pauses, gaps, capture, stop reason, final pass and exports read as written")
        suite.expect(meeting.calendarEventID == nil && meeting.transcript == nil && meeting.preserved.isEmpty,
                     "a null is the same as an absent field, and nothing is left over")
        suite.expect(decoded(text(meeting)) == meeting, "the example survives a rewrite")
        suite.expect(ForkMeetingSidecar.FinalPass.skippedDisk.rawValue == "skipped-disk",
                     "a final pass skipped for lack of room is written skipped-disk")
        suite.expect(ForkMeetingOrigin.allCases.map(\.rawValue) == ["manual", "offered", "always"],
                     "the three origins keep their names in the file, even before the offers exist")
    }

    private static func missingFields(_ suite: TestSuite) {
        suite.expect(decoded("{}") == ForkMeetingSidecar(), "an empty object reads, every field absent")
        let early = decoded("{\"id\": \"6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8\", \"state\": \"recording\"}")
        suite.expect(early?.id == id && early?.state == .recording && early?.schema == nil && early?.pauses == nil,
                     "a sidecar from before most fields existed still reads")
        suite.expect(early?.isRewritable == true, "a sidecar without a schema is from the first one, and may be updated")
        let partial = decoded("{\"pauses\": [{\"at\": 12}], \"capture\": {\"quality\": \"high\"}}")
        suite.expect(partial?.pauses == [.init(at: 12, seconds: nil, reason: nil)] && partial?.capture?.quality == .high
                        && partial?.capture?.target == nil,
                     "inside a pause or the capture, a missing field is simply absent")
        let fraction = decoded("{\"startedAt\": \"2026-10-18T08:02:11.250Z\"}")
        suite.expect(fraction?.startedAt == start.addingTimeInterval(0.25),
                     "a date written with fractions of a second still reads")
    }

    private static func unknownContent(_ suite: TestSuite) {
        let json = """
        {"schema": 1, "state": "archived", "title": "Démo", "castral": {"job": "t-42", "stage": "ready"},
         "pauses": [{"at": 3, "reason": "phone"}], "rating": 4}
        """
        guard let meeting = decoded(json) else {
            suite.expect(false, "a sidecar with unknown content reads")
            return
        }
        suite.expect(meeting.title == "Démo" && meeting.state == nil && meeting.pauses == nil,
                     "a value this version does not know reads as absent, the rest normally")
        suite.expect(meeting.preserved["state"] == .string("archived") && meeting.preserved["rating"] == .number(4)
                        && meeting.preserved["castral"] == .object(["job": .string("t-42"), "stage": .string("ready")]),
                     "unknown keys and unreadable values are kept")
        let again = decoded(text(meeting))
        suite.expect(again?.preserved == meeting.preserved && again?.title == "Démo",
                     "and written back untouched: a later version's data is never lost by this one")
        var updated = ForkMeetingSidecarPatch(stopReason: .user, pause: .init(at: 9, seconds: 2, reason: .user))
            .applied(to: meeting)
        updated.state = .complete
        let rewritten = decoded(text(updated))
        suite.expect(rewritten?.state == .complete && rewritten?.preserved["state"] == nil
                        && rewritten?.preserved["pauses"] != nil && rewritten?.pauses == nil,
                     "a value set by this version replaces the unreadable one; an unreadable list is never cut down to a partial one")
        let lockPause = decoded("{\"pauses\": [{\"at\": 3, \"seconds\": 2, \"reason\": \"lock\"}]}")
        suite.expect(lockPause?.pauses == nil && lockPause?.preserved["pauses"] != nil,
                     "a pause reason this version does not know (a lock is no longer a pause) is kept as written")
        let lockGap = decoded("{\"gaps\": [{\"at\": 50, \"seconds\": 20, \"kind\": \"screenLocked\"}]}")
        suite.expect(lockGap?.gaps == [.init(at: 50, seconds: 20, kind: .screenLocked)],
                     "a locked screen is written as a gap of kind screenLocked")
        let newer = decoded("{\"schema\": 2, \"title\": \"Futur\"}")
        suite.expect(newer?.title == "Futur" && newer?.isRewritable == false,
                     "a sidecar from a later version reads, and is not rewritten")
        if let newer {
            suite.expect(ForkMeetingSidecar.rewriting(.success(newer), with: .init(state: .complete)) == nil,
                         "a patch never lands on a later version's sidecar")
        }
    }

    private static func corruption(_ suite: TestSuite) {
        for broken in ["{ pas du json", "[1, 2]", "\"text\"", ""] {
            guard case let .failure(fault) = ForkMeetingSidecar.decode(Data(broken.utf8)) else {
                suite.expect(false, "\(broken) must not decode")
                continue
            }
            if case .corrupt = fault {
                suite.expect(!fault.isNormal, "a sidecar that does not decode is a fault worth saying: \(broken)")
            } else {
                suite.expect(false, "\(broken) is corrupt, not \(fault)")
            }
            suite.expect(ForkMeetingSidecar.rewriting(.failure(fault), with: .init(state: .complete)) == nil,
                         "a corrupt sidecar is never rewritten: it may still be repaired by hand")
        }
        let missing = ForkMeetingSidecarFault.reading(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError))
        let refused = ForkMeetingSidecarFault.reading(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
        suite.expect(missing == .absent && missing.isNormal, "no sidecar is the ordinary case, and silent")
        if case .unreadable = refused {
            suite.expect(!refused.isNormal, "a sidecar the system refuses is not an absent one, and is said")
        } else {
            suite.expect(false, "a refused read is unreadable")
        }
        suite.expect(ForkMeetingSidecar.rewriting(.failure(.absent), with: .init(state: .complete)) == nil,
                     "a patch has nowhere to go without a sidecar, and invents none")
    }

    private static func patches(_ suite: TestSuite) {
        let first = started()
        let patch = ForkMeetingSidecarPatch(state: .finalizing, stopReason: .user, endedAt: start.addingTimeInterval(3000),
                                            recordedSeconds: 2700, pause: .init(at: 600, seconds: 300, reason: .user),
                                            gap: .init(at: 1500, seconds: 1.4, kind: .microphoneSwitch),
                                            microphone: "MacBook Pro")
        let after = patch.applied(to: first)
        suite.expect(after.state == .finalizing && after.stopReason == .user && after.endedAt == start.addingTimeInterval(3000)
                        && after.recordedSeconds == 2700 && after.pauses?.count == 1 && after.gaps?.count == 1
                        && after.capture?.microphone == "MacBook Pro" && after.capture?.quality == .standard
                        && after.id == first.id && after.startedAt == first.startedAt,
                     "a patch changes what it sets, appends pauses and gaps, and keeps everything else")
        let twice = ForkMeetingSidecarPatch(pause: .init(at: 900, seconds: 5, reason: .sleep)).applied(to: after)
        suite.expect(twice.pauses?.map(\.at) == [600, 900], "pauses add up in order")
        suite.expect(ForkMeetingSidecarPatch().applied(to: after) == after, "an empty patch changes nothing")
        suite.expect(ForkMeetingSidecar.rewriting(.success(first), with: patch) == after,
                     "a readable sidecar of this version takes the patch")
        let display = ForkMeetingSidecarPatch(target: .display).applied(to: first)
        suite.expect(display.capture?.target == .display && display.capture?.microphone == first.capture?.microphone
                        && display.capture?.quality == .standard,
                     "the target really filmed replaces the setting's, nothing else of the capture")
        let switched = ForkMeetingSidecarPatch(gap: .init(at: 42, seconds: 0, kind: .targetSwitch)).applied(to: first)
        suite.expect(ForkMeetingSidecar.GapKind.targetSwitch.rawValue == "targetSwitch"
                        && decoded(text(switched))?.gaps == [.init(at: 42, seconds: 0, kind: .targetSwitch)],
                     "a switch between the window and the display is a gap of no length, written targetSwitch")
    }

    private static func onDisk(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForkMeetingSidecarTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ForkMeetingFolder.sidecarName)
        suite.expect(ForkMeetingSidecar.read(at: url) == .failure(.absent), "a folder without a sidecar reads as absent")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try started().encoded().write(to: url, options: .atomic)
            suite.expect(ForkMeetingSidecar.read(at: url) == .success(started()), "a sidecar written to the disk reads back")
            try Data("{ abîmé".utf8).write(to: url)
            if case .failure(.corrupt) = ForkMeetingSidecar.read(at: url) {
                suite.expect(true, "a damaged file on the disk is corrupt")
            } else {
                suite.expect(false, "a damaged file on the disk is corrupt")
            }
        } catch {
            suite.expect(false, "temporary sidecar: \(error)")
        }
    }
}
