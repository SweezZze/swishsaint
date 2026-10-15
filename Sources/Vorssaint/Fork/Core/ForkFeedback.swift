// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit

/// The in-app feedback form, sent to the fork instead of the official
/// developer (seam `feedback`): a bug of the fork is not theirs to read.
///
/// The fork has no server of its own, so the message opens as a new issue
/// of the fork's repository, filled in, for the person to send from their
/// browser. Nothing leaves the Mac until they do.
enum ForkFeedback {
    static func takesOver(kind: FeedbackKind, message: String, diagnostics: FeedbackDiagnostics?) -> Bool {
        if let url = issueURL(kind: kind, message: message, diagnostics: diagnostics,
                              repository: ForkInfo.repository,
                              build: ForkUpdateService.shared.currentBuild) {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    static func issueURL(kind: FeedbackKind, message: String, diagnostics: FeedbackDiagnostics?,
                         repository: String, build: Int?) -> URL? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = (kind == .bug ? "Bug: " : "Idea: ") + String(firstLine.prefix(80))
        var body = trimmed
        if let diagnostics {
            body += "\n\n---\n"
            body += "- build: \(build.map(String.init) ?? "local")\n"
            body += "- Vorssaint: \(diagnostics.appVersion)\n"
            body += "- macOS: \(diagnostics.macOS)\n"
            if let model = diagnostics.macModel { body += "- Mac: \(model)\n" }
            body += "- language: \(diagnostics.language)\n"
        }
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: kind == .bug ? "bug" : "enhancement"),
        ]
        return components?.url
    }
}
