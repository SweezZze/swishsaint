// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial
// Portions adapted from FluidAudio (Apache-2.0), https://github.com/FluidInference/FluidAudio

import Foundation

/// The SentencePiece pieces of Parakeet v3, by token id. The blank (8192) has
/// no piece.
struct ForkParakeetVocabulary {
    /// The file names the model has shipped it under, newest first.
    static let fileNames = ["parakeet_v3_vocab.json", "parakeet_vocab.json"]

    let pieces: [Int: String]

    var count: Int { pieces.count }

    init(pieces: [Int: String]) {
        self.pieces = pieces
    }

    /// Reads `{"0": "<unk>", …}`, or a plain array where the index is the id.
    init(data: Data) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        var pieces: [Int: String] = [:]
        if let dictionary = json as? [String: String] {
            for (key, value) in dictionary {
                if let id = Int(key) { pieces[id] = value }
            }
        } else if let array = json as? [String] {
            for (id, value) in array.enumerated() { pieces[id] = value }
        } else {
            throw ForkParakeetVocabularyError.unexpectedFormat
        }
        guard !pieces.isEmpty else { throw ForkParakeetVocabularyError.unexpectedFormat }
        self.pieces = pieces
    }

    /// The vocabulary file inside a model folder, if any.
    static func fileURL(in directory: URL) -> URL? {
        fileNames.lazy
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func load(from directory: URL) throws -> ForkParakeetVocabulary {
        guard let url = fileURL(in: directory) else {
            throw ForkParakeetVocabularyError.missing
        }
        return try ForkParakeetVocabulary(data: Data(contentsOf: url))
    }
}

enum ForkParakeetVocabularyError: Error, Equatable {
    case missing
    case unexpectedFormat
}
