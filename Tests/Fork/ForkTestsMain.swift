// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

// The fork's own runner (fork/test.sh), same contract as the official one:
// every suite by default, `--suite=<name>` to pick, `--list` to list.
@main
struct ForkTests {
    static func main() {
        let suite = TestSuite()
        let groups: [(String, () -> Void)] = [
            ("fork-defaults", { ForkDefaultsTests.run(suite) }),
            ("window-trackpad", { ForkTrackpadGestureTests.run(suite) }),
            ("fork-update", { ForkUpdateTests.run(suite) }),
            ("fork-claude-usage", { ForkClaudeUsageTests.run(suite) }),
            ("fork-dictation", { ForkDictationTests.run(suite) }),
        ]
        var selected = Set<String>()
        var listOnly = false
        for argument in CommandLine.arguments.dropFirst() {
            if argument == "--list" {
                listOnly = true
                continue
            }
            guard argument.hasPrefix("--suite="),
                  groups.contains(where: { $0.0 == String(argument.dropFirst(8)) }) else {
                fputs("Unknown test selection: \(argument)\n", stderr)
                exit(2)
            }
            selected.insert(String(argument.dropFirst(8)))
        }
        if listOnly {
            groups.forEach { print($0.0) }
            exit(0)
        }
        for (name, body) in groups where selected.isEmpty || selected.contains(name) {
            suite.run(name, body)
        }
        suite.finish()
    }
}
