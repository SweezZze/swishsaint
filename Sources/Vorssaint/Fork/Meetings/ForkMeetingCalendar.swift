// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import EventKit
import Foundation

/// Names a detected meeting after the calendar event that links to it,
/// when the person turned "Name with the calendar" on and gave full access.
/// It never makes a meeting: the resolver only takes the event's title for
/// the Google Meet whose code its link, notes or place holds, or for an
/// app's call or another web call when it is the only event going on with
/// that service's link (`ForkMeetingCalendarLink`).
///
/// The events from 10 minutes ago to 10 minutes from now are read when it
/// starts and once a minute, on a utility serial queue that keeps the
/// EventKit store; only their titles, codes, kinds of link and times leave
/// it, and nothing is kept on disk.
final class ForkMeetingCalendar {
    static let interval: TimeInterval = 60
    /// Around now, either way.
    static let reach: TimeInterval = 10 * 60

    /// The option is on and the calendar can be read.
    static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: ForkDefaultsKey.meetingsCalendarNaming)
            && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private let queue = DispatchQueue(label: "fork.meetings.calendar", qos: .utility)
    private let onHints: ([ForkMeetingCalendarHint]) -> Void

    // Queue only.
    private var store: EKEventStore?
    private var timer: DispatchSourceTimer?

    /// `onHints` runs on the main thread.
    init(onHints: @escaping ([ForkMeetingCalendarHint]) -> Void) {
        self.onHints = onHints
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(5))
            source.setEventHandler { [weak self] in self?.read() }
            timer = source
            source.resume()
        }
    }

    /// Stops reading and lets the store go.
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            store = nil
        }
    }

    private func read() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return deliver([]) }
        let store = self.store ?? EKEventStore()
        self.store = store
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.reach),
                                                 end: now.addingTimeInterval(Self.reach), calendars: nil)
        let hints = store.events(matching: predicate).compactMap { event -> ForkMeetingCalendarHint? in
            // Its title as written: the meeting's name cleans it, once
            // (`ForkMeetingCandidate.name`); one with nothing left to show
            // names nothing.
            guard event.status != .canceled, !event.isAllDay,
                  let start = event.startDate, let end = event.endDate,
                  let title = event.title, !ForkMeetingTitleRules.displayName(title).isEmpty else { return nil }
            let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
            let code = texts.lazy.compactMap(ForkMeetingTitleRules.meetCode(inLink:)).first
            let links = ForkMeetingCalendarLink.found(in: texts.joined(separator: "\n"))
            guard code != nil || !links.isEmpty else { return nil }
            return ForkMeetingCalendarHint(title: title, meetCode: code, startsAt: start, endsAt: end, links: links)
        }
        // The event nearest to now first: the resolver takes the first one
        // with the meeting's code.
        let middle = now.timeIntervalSinceReferenceDate
        deliver(hints.sorted {
            abs($0.startsAt.timeIntervalSinceReferenceDate - middle) < abs($1.startsAt.timeIntervalSinceReferenceDate - middle)
        })
    }

    private func deliver(_ hints: [ForkMeetingCalendarHint]) {
        DispatchQueue.main.async { [weak self] in self?.onHints(hints) }
    }
}
