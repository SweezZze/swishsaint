// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Copies a meeting into a folder the person chose: a synced folder, a NAS,
/// a folder Hazel watches. No network, no secret.
///
/// `<folder>/<meeting's name>/` receives the audio (M4A), `meeting.json`
/// (without the Google Meet code unless asked) and the transcript when there
/// is one. **Atomic**: everything is copied into a hidden draft beside it,
/// then moved into place in one step, so whatever watches the folder never
/// sees half a meeting. Sent again, the same meeting replaces its copy; a
/// different meeting of the same name gets `(2)`.
///
/// The chosen folder is never made: a disk that is not mounted would
/// otherwise get an empty folder of the same name on the startup disk, and
/// the meetings with it.
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
        do { json = try ForkMeetingExportDocument.json(package.sidecar, includesMeetCode: config.includesMeetCode) } catch {
            throw ForkMeetingExportFailure.unreadable
        }
        let draft = destination.appendingPathComponent(Self.draftPrefix + UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: draft, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: package.audio, to: draft.appendingPathComponent(package.audioName))
            try json.write(to: draft.appendingPathComponent(ForkMeetingFolder.sidecarName))
            if let transcript = package.transcript {
                try manager.copyItem(at: transcript, to: draft.appendingPathComponent(package.transcriptName))
            }
            let target = try place(for: package, in: destination)
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: draft)
            } else {
                try manager.moveItem(at: draft, to: target)
            }
        } catch let failure as ForkMeetingExportFailure {
            try? manager.removeItem(at: draft)
            throw failure
        } catch {
            try? manager.removeItem(at: draft)
            throw ForkMeetingExportFailure.writeFailed
        }
    }

    /// The meeting's folder in the drop folder: its own name, or the first
    /// free `name (n)` when another meeting already has it. The same
    /// meeting sent again (same id) takes its place back.
    func place(for package: ForkMeetingExportPackage, in destination: URL) throws -> URL {
        let manager = FileManager.default
        for index in 1...ForkMeetingFolder.maximumSiblings {
            let name = index == 1 ? package.folderName : "\(package.folderName) (\(index))"
            let candidate = destination.appendingPathComponent(name, isDirectory: true)
            guard manager.fileExists(atPath: candidate.path) else { return candidate }
            let there = ForkMeetingSidecar.read(at: candidate.appendingPathComponent(ForkMeetingFolder.sidecarName))
            if case let .success(sidecar) = there, sidecar.id != nil, sidecar.id == package.sidecar.id { return candidate }
        }
        throw ForkMeetingExportFailure.writeFailed
    }
}
