// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

enum ForkClaudeUsageTests {
    static func run(_ suite: TestSuite) {
        reading(suite)
        settings(suite)
    }

    private static func reading(_ suite: TestSuite) {
        let paris = TimeZone(identifier: "Europe/Paris")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 10, minute: 50))!
        let answer = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 46% used · resets Oct 15 at 1:10pm (Europe/Paris)
        Current week (all models): 11% used · resets Oct 21 at 6pm (Europe/Paris)

        What's contributing to your limits usage?
        """
        let limits = ForkClaudeCodeUsage.limits(from: answer, now: now)
        let session = limits?.windows.first { $0.kind == .session }
        let week = limits?.windows.first { $0.kind == .weekly }
        suite.expect(limits?.source == .account && limits?.provider == .claude && limits?.windows.count == 2,
                     "Claude Code's /usage gives the account's session and week")
        suite.expect(session?.usedPercent == 46 && session?.id == "claude.fh"
                        && session?.resetsAt == calendar.date(from: DateComponents(year: 2026, month: 10, day: 15,
                                                                                   hour: 13, minute: 10)),
                     "the session reads 46% used, renewing at 1:10 pm Paris time")
        suite.expect(week?.usedPercent == 11 && week?.id == "claude.sd"
                        && week?.resetsAt == calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18)),
                     "the week reads 11% used, renewing on the 21st at 6 pm")
        suite.expect(ForkClaudeCodeUsage.limits(from: "Total cost: $0.0000\nUsage: 0 input", now: now) == nil,
                     "an API key answer, without plan limits, reads as nothing")
        let newYear = calendar.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 12))!
        suite.expect(ForkClaudeCodeUsage.resetDate("Jan 2 at 9am (Europe/Paris)", now: newYear)
                        == calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9)),
                     "a renewal past New Year lands in the next year")
    }

    private static func settings(_ suite: TestSuite) {
        suite.expect(ForkDefaults.registered[ForkDefaultsKey.claudeUsageEnabled] as? Bool == false
                        && ForkDefaults.backupKeys.contains(ForkDefaultsKey.claudeUsageEnabled),
                     "reading Claude's limits through Claude Code starts off and is backed up")
        let all = AppLanguage.allCases.map(ForkExtrasStrings.strings)
        suite.expect(all.allSatisfy {
                        !$0.claudeUsageTitle.isEmpty && !$0.claudeUsageSummary.isEmpty
                            && $0.claudeUsageStatusFormat.contains("%@") && !$0.claudeUsageWaiting.isEmpty
                     },
                     "the Claude usage texts exist in every language")
    }
}
