// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Copies a meeting into a folder the person chose: a synced folder, a NAS,
/// a folder Hazel watches. No secret; the app itself sends nothing over the
/// network, whatever the folder then does with the copy.
///
/// `<folder>/<meeting's name>/` receives the audio (M4A), `meeting.json`
/// (`ForkMeetingExportDocument`) and the transcript when there is one, under
/// the meeting's name without its Google Meet code unless asked.
/// **Atomic**: everything is copied into a hidden draft beside it, then
/// moved into place in one step, so whatever watches the folder never sees
/// half a meeting. Sent again, the same meeting replaces **only its own
/// files** there (what another tool added stays); a different meeting of
/// the same name gets `(2)`. The copy takes the chosen folder's rights.
///
/// The chosen folder is never made: a disk that is not mounted would
/// otherwise get an empty folder of the same name on the startup disk, and
/// the meetings with it. An entry there that is a link, or that leads into
/// the meetings folder, is never written into.
struct ForkDropFolderExporter: ForkMeetingExporter {
    let config: ForkMeetingExporterConfig
    /// The meetings folder: a drop folder there, or inside one of its
    /// meetings, would list the copies as meetings.
    let libraryRoot: URL

    var id: String { config.id }
    var kind: ForkMeetingExportKind { .dropFolder }
    var mode: ForkMeetingExportMode { config.mode }
    var isConfigured: Bool { destination != nil }

    static let draftPrefix = ".swishsaint-export-"

    var destination: URL? {
        guard let folder = config.folder, !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    func check() throws {
        guard isConfigured else { throw ForkMeetingExportFailure.notConfigured }
    }

    /// Whether `folder` may be a drop folder: never the meetings folder nor
    /// anything inside it.
    static func isInsideLibrary(_ folder: URL, libraryRoot: URL) -> Bool {
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let root = libraryRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return folder.count >= root.count && Array(folder.prefix(root.count)) == root
    }

    func export(_ package: ForkMeetingExportPackage, progress: @escaping (Double) -> Void) async throws -> ForkMeetingExportReceipt {
        guard let destination else { throw ForkMeetingExportFailure.notConfigured }
        try copy(package, into: destination)
        progress(1)
        return ForkMeetingExportReceipt(target: id, kind: kind, at: Date())
    }

    /// The copy itself, synchronous: draft, then one move.
    func copy(_ package: ForkMeetingExportPackage, into destination: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ForkMeetingExportFailure.folderMissing
        }
        if Self.isInsideLibrary(destination, libraryRoot: libraryRoot) { throw ForkMeetingExportFailure.folderInsideLibrary }
        let json: Data
        do {
            json = try ForkMeetingExportDocument.json(package.sidecar, includesMeetCode: config.includesMeetCode,
                                                      includesNotes: config.includesNotes)
        } catch {
            throw ForkMeetingExportFailure.unreadable
        }
        let name = package.name(includesMeetCode: config.includesMeetCode)
        // The chosen folder's rights, for the folder and, without their
        // execution, for the files: a shared folder stays shared.
        let rights = (((try? manager.attributesOfItem(atPath: destination.path))?[.posixPermissions] as? NSNumber)?
            .intValue ?? 0o755) & 0o777
        let fileRights = rights & 0o666
        let draft = destination.appendingPathComponent(ForkMeetingLeftovers.name(Self.draftPrefix), isDirectory: true)
        do {
            try manager.createDirectory(at: draft, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: rights])
            let audio = draft.appendingPathComponent(ForkMeetingExportPackage.audioName(name))
            try manager.copyItem(at: package.audio, to: audio)
            let sidecar = draft.appendingPathComponent(ForkMeetingFolder.sidecarName)
            try json.write(to: sidecar)
            var written = [audio, sidecar]
            if let transcript = package.transcript {
                let copy = draft.appendingPathComponent(ForkMeetingExportPackage.transcriptName(name))
                try manager.copyItem(at: transcript, to: copy)
                written.append(copy)
            }
            for file in written { try? manager.setAttributes([.posixPermissions: fileRights], ofItemAtPath: file.path) }
            let target = try place(named: name, id: package.sidecar.id, in: destination)
            if manager.fileExists(atPath: target.path) {
                // Ours: each of our files replaced in one step, the rest kept.
                for file in written {
                    let there = target.appendingPathComponent(file.lastPathComponent)
                    if manager.fileExists(atPath: there.path) {
                        _ = try manager.replaceItemAt(there, withItemAt: file)
                    } else {
                        try manager.moveItem(at: file, to: there)
                    }
                }
                try? manager.removeItem(at: draft)
            } else {
                try manager.moveItem(at: draft, to: target)
            }
        } catch let failure as ForkMeetingExportFailure {
            try? manager.removeItem(at: draft)
            throw failure
        } catch {
            try? manager.removeItem(at: draft)
            throw ForkMeetingExportFailure.isOutOfSpace(error) ? ForkMeetingExportFailure.dropFolderFull
                : ForkMeetingExportFailure.writeFailed
        }
    }

    /// The meeting's folder in the drop folder: its own name, or the first
    /// free `name (n)` when another meeting already has it. The same
    /// meeting sent again (same id) takes its place back. An entry that is
    /// a link, or that leads into the meetings folder, is never ours.
    func place(named name: String, id: UUID?, in destination: URL) throws -> URL {
        let manager = FileManager.default
        for index in 1...ForkMeetingFolder.maximumSiblings {
            let candidate = destination.appendingPathComponent(index == 1 ? name : "\(name) (\(index))", isDirectory: true)
            guard let attributes = try? manager.attributesOfItem(atPath: candidate.path) else { return candidate }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  !Self.isInsideLibrary(candidate, libraryRoot: libraryRoot) else { continue }
            let there = ForkMeetingSidecar.read(at: candidate.appendingPathComponent(ForkMeetingFolder.sidecarName))
            if case let .success(sidecar) = there, sidecar.id != nil, sidecar.id == id { return candidate }
        }
        throw ForkMeetingExportFailure.writeFailed
    }

    /// The drafts a copy cut short (a quit, a disk pulled) left in the drop
    /// folder: removed at the next launch, this process's own or those
    /// older than a day (`ForkMeetingLeftovers`).
    static func removeDrafts(in destination: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier, now: Date = Date()) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: destination.path) else { return }
        for name in names {
            let url = destination.appendingPathComponent(name)
            let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard ForkMeetingLeftovers.removable(name, prefix: draftPrefix, pid: pid, modified: modified, now: now) else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
