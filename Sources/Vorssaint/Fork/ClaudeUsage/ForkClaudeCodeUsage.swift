// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

/// Claude Code answers `/usage` for the account it is signed in to: the
/// session and the week in percent, the figures claude.ai and the Claude app
/// show, counting every device. It reads them from the account without
/// asking a model, so the check costs nothing, and it signs in with its own
/// credentials, which Vorssaint never reads.
///
/// `ForkClaudeUsage` asks every few minutes, so the limits stay current
/// without the Claude app. The check runs from a folder of its own, without the user's
/// settings (no hooks fire) and without saving a session.
enum ForkClaudeCodeUsage {
    static let checkInterval: TimeInterval = 5 * 60
    /// After a failure (signed out, offline, an API key), the next try waits.
    static let retryInterval: TimeInterval = 15 * 60
    /// A reading older than this has missed checks; another source takes over.
    static let freshness: TimeInterval = 15 * 60
    static let timeout: TimeInterval = 30

    /// Where the official installer, its older layout, Homebrew and npm put
    /// the tool.
    static func candidates(home: URL) -> [URL] {
        [home.appending(path: ".local/bin/claude"), home.appending(path: ".claude/local/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    static func executable(home: URL) -> URL? {
        candidates(home: home).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs the check, off the main thread. Nil when Claude Code is missing,
    /// signed out or on an API key, out of time, or answering in words this
    /// reader does not know.
    static func check(home: URL, now: @escaping () -> Date = Date.init) -> AgentLimits? {
        guard let tool = executable(home: home) else { return nil }
        let folder = home.appending(path: "Library/Application Support/Vorssaint/Claude usage",
                                    directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = tool
        process.arguments = ["-p", "/usage", "--output-format", "json",
                             "--no-session-persistence", "--setting-sources", "local"]
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["is_error"] as? Bool != true,
              let text = json["result"] as? String
        else { return nil }
        return limits(from: text, now: now())
    }

    /// The lines that matter in the answer, in the tool's own English:
    ///
    ///     Current session: 46% used · resets Oct 15 at 1:10pm (Europe/Paris)
    ///     Current week (all models): 11% used · resets Oct 21 at 6pm (Europe/Paris)
    static func limits(from text: String, now: Date) -> AgentLimits? {
        var windows: [AgentLimitWindow] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let match = parse(line) else { continue }
            let resets = match.resets.flatMap { resetDate($0, now: now) }
            switch match.label.lowercased() {
            case "current session":
                windows.append(AgentLimitWindow(id: "claude.fh", kind: .session, minutes: 300, scope: nil,
                                                usedPercent: match.used, resetsAt: resets))
            case "current week (all models)":
                windows.append(AgentLimitWindow(id: "claude.sd", kind: .weekly, minutes: 10_080, scope: nil,
                                                usedPercent: match.used, resetsAt: resets))
            case let label where label.hasPrefix("current week (opus"):
                windows.append(AgentLimitWindow(id: "claude.so", kind: .weekly, minutes: 10_080, scope: "Opus",
                                                usedPercent: match.used, resetsAt: resets))
            case let label where label.hasPrefix("current week (sonnet"):
                windows.append(AgentLimitWindow(id: "claude.sn", kind: .weekly, minutes: 10_080, scope: "Sonnet",
                                                usedPercent: match.used, resetsAt: resets))
            default:
                continue
            }
        }
        guard !windows.isEmpty else { return nil }
        return AgentLimits(provider: .claude, windows: windows, observedAt: now, source: .account)
    }

    private static let line = try! NSRegularExpression(
        pattern: #"^(Current [^:]+):\s*([0-9]+(?:\.[0-9]+)?)%\s*used(?:\s*·\s*resets\s+(.+))?$"#)

    private static func parse(_ text: String) -> (label: String, used: Double, resets: String?)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = line.firstMatch(in: text, range: range),
              let label = Range(match.range(at: 1), in: text),
              let number = Range(match.range(at: 2), in: text),
              let used = Double(text[number])
        else { return nil }
        let resets = Range(match.range(at: 3), in: text).map { String(text[$0]) }
        return (String(text[label]), min(100, max(0, used)), resets)
    }

    /// "Oct 15 at 1:10pm (Europe/Paris)", "Oct 21 at 6pm (Europe/Paris)", or
    /// a time alone for today. The year is the one that puts the date ahead,
    /// within the week a window lasts at most.
    static func resetDate(_ text: String, now: Date) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if let named = TimeZone(identifier: name) { zone = named }
            text = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        for format in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy", "MMM d yyyy"] {
            formatter.dateFormat = format
            for candidate in [year, year + 1] {
                if let date = formatter.date(from: "\(text) \(candidate)"),
                   date > now.addingTimeInterval(-3_600) {
                    return date
                }
            }
        }
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            guard let time = formatter.date(from: text) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            guard var date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0,
                                           second: 0, of: now) else { continue }
            if date < now.addingTimeInterval(-3_600) { date = date.addingTimeInterval(86_400) }
            return date
        }
        return nil
    }
}
