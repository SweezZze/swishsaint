// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CryptoKit
import Foundation

/// The exact files of the Parakeet TDT 0.6B v3 speech model the dictation
/// runs on this Mac, pinned to one revision of its Hugging Face repository.
///
/// The model is NVIDIA's (CC-BY-4.0), converted to CoreML by FluidInference.
/// Only what inference needs is listed: the four compiled models and the
/// SentencePiece vocabulary. Every file carries its size and SHA-256, so a
/// download, a resumed download or a copy of another app's cache is accepted
/// only when it is byte for byte the file of this revision. The revision is
/// pinned rather than `main`: a later push to the repository can never change
/// what an installed build downloads.
enum ForkParakeetManifest {
    struct File: Equatable {
        /// Relative to the model folder, `/`-separated, as in the repository.
        let path: String
        let size: Int64
        /// Lowercase hex.
        let sha256: String
    }

    static let repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
    /// The folder the files live in, here and in FluidAudio's cache.
    static let folderName = "parakeet-tdt-0.6b-v3"

    /// The compiled models, in the order inference runs them.
    static let models = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static let vocabularyPath = "parakeet_v3_vocab.json"

    /// Room left for the system on top of what a download still has to write.
    static let headroomBytes: Int64 = 512 << 20

    /// The free space a download needs before it starts: what is left to
    /// download plus `headroomBytes`, about 1 GB for a fresh one.
    static func requiredFreeBytes(toDownload remaining: Int64) -> Int64 {
        max(0, remaining) + headroomBytes
    }

    static let files: [File] = [
        File(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        File(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        File(path: "Decoder.mlmodelc/metadata.json", size: 3_427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        File(path: "Decoder.mlmodelc/model.mil", size: 13_110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        File(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        File(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        File(path: "Encoder.mlmodelc/coremldata.bin", size: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        File(path: "Encoder.mlmodelc/metadata.json", size: 2_921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        File(path: "Encoder.mlmodelc/model.mil", size: 959_769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        File(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        File(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        File(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        File(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3_453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        File(path: "JointDecisionv3.mlmodelc/model.mil", size: 11_775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        File(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        File(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        File(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        File(path: "Preprocessor.mlmodelc/metadata.json", size: 2_841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        File(path: "Preprocessor.mlmodelc/model.mil", size: 28_181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        File(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        File(path: "parakeet_v3_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    /// 483 105 645 bytes, about 461 MiB.
    static var totalBytes: Int64 { totalBytes(of: files) }

    static func totalBytes(of files: [File]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// Where `file` is downloaded from. Hugging Face answers with a redirect
    /// to its CDN for the large files.
    static func downloadURL(for file: File) -> URL? {
        guard isSafe(path: file.path) else { return nil }
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")
    }

    /// Where `file` lives inside a model folder, nil for a path that could
    /// leave it.
    static func location(of file: File, in directory: URL) -> URL? {
        guard isSafe(path: file.path) else { return nil }
        return directory.appendingPathComponent(file.path, isDirectory: false)
    }

    /// A relative path made of plain components: no `..`, no `.`, no empty
    /// component, nothing absolute.
    static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    // MARK: - Checking

    /// The size on disk of `url`, nil when it is missing or not a file.
    static func sizeOfFile(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// The SHA-256 of the file at `url`, read in chunks so a 445 MB weight
    /// file never sits in memory. Slow for the large files: off the main
    /// thread only.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var failed = false
        var done = false
        while !done && !failed {
            // Each 4 MB chunk is freed before the next one is read.
            autoreleasepool {
                do {
                    guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else {
                        done = true
                        return
                    }
                    hasher.update(data: chunk)
                } catch {
                    failed = true
                }
            }
        }
        if failed { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `file` is present in `directory` with its size and, when
    /// `checksum` is true, its SHA-256.
    static func verify(_ file: File, in directory: URL, checksum: Bool = true) -> Bool {
        guard let url = location(of: file, in: directory),
              sizeOfFile(at: url) == file.size
        else { return false }
        return !checksum || sha256Hex(ofFileAt: url) == file.sha256.lowercased()
    }

    /// The files of `files` that `directory` lacks or holds a different
    /// version of. Empty means the folder is a complete model.
    static func missing(_ files: [File] = files, in directory: URL, checksum: Bool) -> [File] {
        files.filter { !verify($0, in: directory, checksum: checksum) }
    }
}
