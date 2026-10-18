// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkParakeetStoreTests {
    typealias Manifest = ForkParakeetManifest

    static func run(_ suite: TestSuite) {
        manifest(suite)
        paths(suite)
        checking(suite)
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func manifest(_ suite: TestSuite) {
        suite.expect(isHex(Manifest.revision, count: 40),
                     "the model is pinned to one commit of its repository, never to a branch")
        suite.expect(Manifest.files.allSatisfy { isHex($0.sha256, count: 64) && $0.size > 0 },
                     "every file carries its size and a full lowercase SHA-256")
        suite.expect(Set(Manifest.files.map(\.path)).count == Manifest.files.count,
                     "no file is listed twice")
        suite.expect(Manifest.models.allSatisfy { model in
                        ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy { part in
                            Manifest.files.contains { $0.path == "\(model).mlmodelc/\(part)" }
                        }
                     } && Manifest.files.contains { $0.path == Manifest.vocabularyPath },
                     "each of the four compiled models is complete, and the vocabulary is there")
        suite.expect(Manifest.models == ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"],
                     "inference runs the preprocessor, the encoder, the decoder and the v3 joint")
        suite.expect(Manifest.totalBytes == 483_105_645,
                     "the download is 483 105 645 bytes, the 461 MiB the page announces")
        suite.expect(Manifest.requiredFreeBytes(toDownload: Manifest.totalBytes) > 1_000_000_000
                        && Manifest.requiredFreeBytes(toDownload: 0) == Manifest.headroomBytes
                        && Manifest.requiredFreeBytes(toDownload: -5) == Manifest.headroomBytes,
                     "a fresh download needs about 1 GB free; a resumed one only what is left plus headroom")
    }

    private static func paths(_ suite: TestSuite) {
        let vocabulary = Manifest.files.first { $0.path == Manifest.vocabularyPath }!
        suite.expect(Manifest.downloadURL(for: vocabulary)?.absoluteString
                        == "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/"
                        + Manifest.revision + "/parakeet_v3_vocab.json",
                     "files are downloaded from the pinned revision")
        suite.expect(Manifest.files.allSatisfy { Manifest.isSafe(path: $0.path) },
                     "every listed path stays inside the model folder")
        suite.expect(!Manifest.isSafe(path: "../x") && !Manifest.isSafe(path: "a/../../x")
                        && !Manifest.isSafe(path: "/etc/hosts") && !Manifest.isSafe(path: "a//b")
                        && !Manifest.isSafe(path: "./a") && !Manifest.isSafe(path: "")
                        && Manifest.isSafe(path: "Encoder.mlmodelc/weights/weight.bin"),
                     "a path that could leave the model folder is refused")
        let evil = Manifest.File(path: "../evil", size: 1, sha256: String(repeating: "0", count: 64))
        suite.expect(Manifest.downloadURL(for: evil) == nil
                        && Manifest.location(of: evil, in: URL(fileURLWithPath: "/tmp/model")) == nil,
                     "an unsafe path gets neither a URL nor a place on disk")
    }

    private static func checking(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork-parakeet-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("a.mlmodelc"),
                                                 withIntermediateDirectories: true)
        // SHA-256("abc"), the FIPS 180-2 test vector.
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let good = Manifest.File(path: "a.mlmodelc/model.mil", size: 3, sha256: abc)
        let tampered = Manifest.File(path: "a.mlmodelc/other.bin", size: 3, sha256: abc)
        let absent = Manifest.File(path: "a.mlmodelc/missing.bin", size: 3, sha256: abc)
        try? Data("abc".utf8).write(to: folder.appendingPathComponent(good.path))
        try? Data("abd".utf8).write(to: folder.appendingPathComponent(tampered.path))

        suite.expect(Manifest.sha256Hex(ofFileAt: folder.appendingPathComponent(good.path)) == abc,
                     "the checksum of a file is its SHA-256 in lowercase hex")
        suite.expect(Manifest.verify(good, in: folder) && !Manifest.verify(tampered, in: folder)
                        && !Manifest.verify(absent, in: folder),
                     "a file is accepted only when present with the right bytes")
        suite.expect(Manifest.verify(tampered, in: folder, checksum: false),
                     "the light check at launch looks at sizes only")
        let shorter = Manifest.File(path: good.path, size: 4, sha256: abc)
        suite.expect(!Manifest.verify(shorter, in: folder, checksum: false),
                     "a file of the wrong size fails even the light check")
        suite.expect(Manifest.missing([good, tampered, absent], in: folder, checksum: true) == [tampered, absent]
                        && Manifest.missing([good, tampered, absent], in: folder, checksum: false) == [absent],
                     "missing lists what a folder lacks or holds a different version of")
    }
}
