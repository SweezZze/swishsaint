// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

/// Keeps the account's Claude limits current for the Dynamic Island's Agents
/// section, read by Claude Code (`ForkClaudeCodeUsage`) every few minutes,
/// without the Claude app.
///
/// The official reader asks for them on each tick (seam `claude-usage` in
/// `AgentUsageService.readClaudeApp`), from its own queue: the answer of the
/// last check comes back at once, and a new check starts in the background
/// when one is due. The next tick picks its result up. Off, it never runs the
/// tool and the official sources (the Claude app, the estimate) stand alone.
final class ForkClaudeUsage: ObservableObject {
    static let shared = ForkClaudeUsage()

    /// When Claude Code last read the limits, for the Extras page. Main thread.
    @Published private(set) var lastReading: Date?

    private let lock = NSLock()
    private var latest: AgentLimits?
    private var attempted = Date.distantPast
    private var inFlight = false
    private var failed = false
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private init() {}

    /// Puts the fresh account limits in the store and returns true, so the
    /// official reader stops there; otherwise takes out a reading of its own
    /// gone stale and returns false, and the official sources speak. Called
    /// from the reader's queue on every tick.
    static func apply(to store: AgentUsageStore, readsClaude: Bool, now: Date) -> Bool {
        if store.limits[.claude]?.source == .account { store.clearLimits(.claude) }
        guard readsClaude, let limits = accountLimits(now: now) else { return false }
        store.setLimits(limits)
        return true
    }

    /// The fresh account limits, or nil to let the official sources speak.
    /// Starts a check when one is due. Any thread.
    static func accountLimits(now: Date) -> AgentLimits? {
        guard ForkFeature.claudeUsage.isEnabled else { return nil }
        return shared.limits(now: now)
    }

    /// Forgets the last reading, when the switch goes off.
    static func reset() {
        shared.lock.withLock {
            shared.latest = nil
            shared.attempted = .distantPast
            shared.failed = false
        }
        DispatchQueue.main.async { shared.lastReading = nil }
    }

    private func limits(now: Date) -> AgentLimits? {
        let (reading, due) = lock.withLock { () -> (AgentLimits?, Bool) in
            let wait = failed ? ForkClaudeCodeUsage.retryInterval : ForkClaudeCodeUsage.checkInterval
            let due = !inFlight && now.timeIntervalSince(attempted) >= wait
            if due {
                inFlight = true
                attempted = now
            }
            return (latest, due)
        }
        if due { check() }
        guard let reading, now.timeIntervalSince(reading.observedAt) < ForkClaudeCodeUsage.freshness else {
            return nil
        }
        // A window renewed since the reading has spent an unknown amount.
        let windows = reading.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
        guard !windows.isEmpty else { return nil }
        return AgentLimits(provider: .claude, windows: windows, observedAt: reading.observedAt, source: .account)
    }

    private func check() {
        let home = self.home
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let limits = ForkClaudeCodeUsage.check(home: home)
            guard let self else { return }
            self.lock.withLock {
                self.inFlight = false
                self.failed = limits == nil
                if let limits { self.latest = limits }
            }
            if let limits {
                DispatchQueue.main.async { self.lastReading = limits.observedAt }
            }
        }
    }
}
