// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine
import SwiftUI

/// A meeting's recording as the island shows it: the presenter tells it
/// each step, the strip, the live card and the island's tile read it.
///
/// Main thread only. Every change that can bring the strip in or out, or
/// change its width, asks the island to lay itself out again: the island
/// reads `ForkMeetingIslandStrip.activities` and the strip's sizes as it
/// does, and moves between them on its own springs (`NotchMotion`).
final class ForkMeetingIslandModel: ObservableObject {
    static let shared = ForkMeetingIslandModel()

    @Published private(set) var state: ForkMeetingPillState = .hidden
    @Published private(set) var context = ForkMeetingLiveContext()
    /// The final pass's share done, while it runs.
    @Published private(set) var progress: Double?
    /// "Marked" stands on the card's button until then.
    @Published private(set) var markedUntil: Date?
    /// The time recorded when the clock last stopped: once the recording
    /// stops, the strip keeps the length it reached.
    private(set) var lastElapsed: TimeInterval = 0
    /// The engine's latest levels, read under its lock (the pill's own).
    var levels: () -> ForkMeetingLevels = { .silent }
    /// The pill's actions: the card's buttons do exactly what the pill's do.
    var actions = ForkMeetingPill.Actions()

    private var markedWork: DispatchWorkItem?

    private init() {}

    var phase: ForkMeetingIslandPhase? { ForkMeetingIslandPhase(state: state, progress: progress) }

    var clock: ForkMeetingClock? {
        switch state {
        case let .recording(clock, _): return clock
        case let .paused(clock, _, _): return clock
        case .hidden, .stopping, .finalizing: return nil
        }
    }

    func elapsed(at now: Date) -> TimeInterval {
        clock.map { $0.elapsed(at: now) } ?? lastElapsed
    }

    /// What the strip draws, held by `NotchStripHold` while the strip leaves.
    var snapshot: ForkMeetingIslandSnapshot? {
        phase.map { ForkMeetingIslandSnapshot(phase: $0, clock: clock, stoppedAt: lastElapsed, context: context) }
    }

    /// The pill's state, as the machine gives it.
    func show(_ state: ForkMeetingPillState) {
        guard state != self.state else { return }
        if let clock { lastElapsed = clock.elapsed(at: Date()) }
        // A new meeting starts from nothing, even after the last one's gauge.
        let starts: Bool
        if case .recording = state { starts = self.state == .hidden || self.state == .finalizing } else { starts = false }
        if starts || state == .hidden {
            lastElapsed = 0
            progress = nil
            markedUntil = nil
        }
        self.state = state
        ForkMeetingIslandStrip.refreshIsland()
        ForkMeetingLiveCard.shared.stateChanged()
    }

    func update(_ context: ForkMeetingLiveContext) {
        guard context != self.context else { return }
        self.context = context
    }

    func setProgress(_ progress: Double?) {
        guard progress != self.progress else { return }
        self.progress = progress
    }

    /// "Marked" on the card's button for a moment.
    func marked() {
        markedWork?.cancel()
        let until = Date().addingTimeInterval(ForkMeetingIslandRules.markedHold)
        markedUntil = until
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.markedUntil == until else { return }
            self.markedUntil = nil
        }
        markedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ForkMeetingIslandRules.markedHold, execute: work)
    }

    /// The feature is off: nothing stays, nothing is held.
    func reset() {
        markedWork?.cancel()
        markedWork = nil
        levels = { .silent }
        actions = ForkMeetingPill.Actions()
        context = ForkMeetingLiveContext()
        show(.hidden)
    }
}

/// What a strip draws of a recording, as the island last showed it.
struct ForkMeetingIslandSnapshot: Equatable {
    let phase: ForkMeetingIslandPhase
    let clock: ForkMeetingClock?
    let stoppedAt: TimeInterval
    let context: ForkMeetingLiveContext

    func elapsed(at now: Date) -> TimeInterval { clock.map { $0.elapsed(at: now) } ?? stoppedAt }

    var facts: ForkMeetingIslandSnapshotFacts { ForkMeetingIslandSnapshotFacts(phase: phase, context: context) }

    /// The microphone is recorded and sends sound: its meter is drawn.
    var hearsMicrophone: Bool { context.recordsMicrophone && !context.microphoneSilent }
    /// The meeting's own sound reaches its track.
    var hearsMeeting: Bool { context.trackSound == .heard }
}

/// The closed island while a meeting records, an official live activity
/// like Keep Awake's (`NotchKeepAwakeStrip`): left of the camera the red
/// dot breathing, the pause bars in orange, the disk running low, or the
/// gauge of the file being finished, with the microphone's and the
/// meeting's levels where the wing has room; right of it the time
/// recorded, its digits rolling, still while paused. A click opens the
/// live card with the controls.
///
/// The wings or the capsule are as wide as the wider side needs, measured
/// with the strip's own fonts, and follow the reading as it gains a digit
/// at the hour.
struct ForkMeetingIslandStrip: View {
    @ObservedObject var service: NotchService
    /// The capsule's size, when the island floats; nil for the wings.
    private let size: CGSize?
    /// Where the island draws it: its own strip as of the last update, or
    /// another display's when the island shows on every display.
    private let displayGeometry: NotchGeometry?
    @ObservedObject private var model = ForkMeetingIslandModel.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The hanging strip, around the camera.
    init(service: NotchService, displayGeometry: NotchGeometry?) {
        self.service = service
        self.size = nil
        self.displayGeometry = displayGeometry
    }

    /// The floating capsule.
    init(service: NotchService, size: CGSize, displayGeometry: NotchGeometry? = nil) {
        self.service = service
        self.size = size
        self.displayGeometry = displayGeometry
    }

    var body: some View {
        // Ending a recording clears its state before the strip has left.
        NotchStripHold(model.snapshot, shows: model.state != .hidden) { snapshot in
            if let snapshot { ticking(snapshot) }
        }
    }

    /// The time moves once a second while it runs, at the second the
    /// reading changes; otherwise nothing wakes.
    @ViewBuilder private func ticking(_ snapshot: ForkMeetingIslandSnapshot) -> some View {
        if snapshot.phase.clockRuns {
            TimelineView(.periodic(from: Self.tickStart(snapshot, now: Date()), by: 1)) { context in
                strip(snapshot, now: context.date)
            }
        } else {
            strip(snapshot, now: Date())
        }
    }

    @ViewBuilder private func strip(_ snapshot: ForkMeetingIslandSnapshot, now: Date) -> some View {
        let reading = ForkMeetingIslandRules.clock(snapshot.elapsed(at: now))
        Button { ForkMeetingLiveCard.shared.present() } label: {
            if let size {
                capsule(snapshot, reading: reading, size: size)
            } else {
                wings(snapshot, reading: reading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ForkMeetingIslandRules.label(target: snapshot.context.target, strings: text))
        .accessibilityValue(ForkMeetingIslandRules.value(phase: snapshot.phase, elapsed: snapshot.elapsed(at: now),
                                                         language: l10n.language, strings: text))
        .accessibilityHint(text.islandHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("notch.meeting")
        // A reading that gains a character, at the hour, widens the strip;
        // the island measures the same reading.
        .onChange(of: NotchAgentSupport.readingShape(reading)) { _, _ in
            DispatchQueue.main.async { service.refreshPresentation() }
        }
        .onChange(of: snapshot.phase.mark) { _, _ in
            DispatchQueue.main.async { service.refreshPresentation() }
        }
        // The crossed-out microphone widens the wing that has no meters.
        .onChange(of: ForkMeetingIslandRules.showsMicrophoneMuted(snapshot.facts)) { _, _ in
            DispatchQueue.main.async { service.refreshPresentation() }
        }
    }

    private var text: ForkMeetingStrings { ForkMeetingStrings.strings(l10n.language) }

    // MARK: Wings

    private func wings(_ snapshot: ForkMeetingIslandSnapshot, reading: String) -> some View {
        let geometry = displayGeometry ?? service.compactActivityGeometry
        let height = geometry.compactActivityContentHeight
        let wing = geometry.compactActivityWingWidth
        let iconSize = NotchTimerSupport.stripIconSize(height: height)
        let textSize = NotchTimerSupport.stripTextSize(height: height)
        let markInset = geometry.compactActivityEdgeInset(boxHeight: Self.markSide(iconSize: iconSize),
                                                          radius: Self.markSide(iconSize: iconSize) / 2)
        let metersFit = wing - markInset - NotchTimerSupport.stripCameraGap
            >= Self.markSide(iconSize: iconSize) + Self.markSpacing + ForkMeetingIslandMeters.width
        let muted = ForkMeetingIslandRules.showsMicrophoneMuted(snapshot.facts)
        return HStack(spacing: 0) {
            HStack(spacing: Self.markSpacing) {
                if wing >= 28 {
                    mark(snapshot.phase, side: Self.markSide(iconSize: iconSize))
                }
                if metersFit, snapshot.phase.acceptsControls {
                    ForkMeetingIslandMeters(snapshot: snapshot, height: min(14, iconSize))
                        .transition(.opacity)
                } else if muted {
                    ForkMeetingIslandMutedMicrophone(side: Self.markSide(iconSize: iconSize))
                        .transition(.opacity)
                }
            }
            .padding(.leading, markInset)
            .frame(width: wing, height: height, alignment: .leading)
            Color.clear.frame(width: geometry.compactActivityCameraGap)
            Group {
                if wing >= 42 {
                    readingText(reading, phase: snapshot.phase, size: textSize)
                }
            }
            // Digits carry no descenders, so their ink is about the cap height.
            .padding(.trailing, geometry.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0))
            .frame(width: wing, height: height, alignment: .trailing)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .padding(.horizontal, geometry.compactActivityHorizontalPadding)
        .padding(.top, geometry.compactActivityTopPadding)
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: snapshot.phase.acceptsControls)
    }

    // MARK: Capsule

    private func capsule(_ snapshot: ForkMeetingIslandSnapshot, reading: String, size: CGSize) -> some View {
        let geometry = displayGeometry ?? service.geometry
        let side = NotchCapsuleLayout.side(geometry)
        return HStack(spacing: NotchCapsuleLayout.spacing) {
            mark(snapshot.phase, side: NotchCapsuleLayout.symbolSize)
                .frame(width: NotchCapsuleLayout.symbolWidth)
            if snapshot.phase.acceptsControls {
                ForkMeetingIslandMeters(snapshot: snapshot, height: NotchCapsuleLayout.symbolSize)
                    .transition(.opacity)
            }
            readingText(reading, phase: snapshot.phase, font: Font(NotchCapsuleLayout.readingFont as CTFont))
        }
        .padding(.leading, side + NotchCapsuleLayout.endPadding)
        .padding(.trailing, side + NotchCapsuleLayout.endPadding)
        .frame(width: size.width, height: geometry.stripHeight)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: snapshot.phase.acceptsControls)
    }

    // MARK: Parts

    /// The mark swaps through a blur as the recording changes step, never
    /// as a gauge moves; in place with Reduce Motion.
    private func mark(_ phase: ForkMeetingIslandPhase, side: CGFloat) -> some View {
        ZStack {
            ForkMeetingIslandMark(phase: phase, side: side)
                .id(phase.mark)
                .transition(.blurReplace)
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: phase.mark)
    }

    private func readingText(_ reading: String, phase: ForkMeetingIslandPhase, size pointSize: CGFloat) -> some View {
        readingText(reading, phase: phase, font: .system(size: pointSize, weight: .medium))
    }

    private func readingText(_ reading: String, phase: ForkMeetingIslandPhase, font: Font) -> some View {
        Text(reading)
            .font(font).monospacedDigit()
            .foregroundStyle(Self.readingColor(phase))
            .lineLimit(1).minimumScaleFactor(0.65)
            .fixedSize(horizontal: size != nil, vertical: false)
            .modifier(NotchRollingDigits(value: reading, countsDown: false, everySecond: false))
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: phase.clockIsAlert)
    }

    static func readingColor(_ phase: ForkMeetingIslandPhase) -> Color {
        if phase.clockIsAlert { return .orange }
        return phase.clockRuns || phase.isPaused ? .white : .white.opacity(0.55)
    }

    /// The last whole second the time crossed: ticking from there, the
    /// strip wakes exactly when its reading changes.
    static func tickStart(_ snapshot: ForkMeetingIslandSnapshot, now: Date) -> Date {
        let elapsed = snapshot.elapsed(at: now)
        guard elapsed.isFinite else { return now }
        return now.addingTimeInterval(-(elapsed - elapsed.rounded(.down)))
    }

    // MARK: Measures

    /// Between the mark and the meters.
    static let markSpacing: CGFloat = 5

    /// The mark's box: a dot, a symbol or a gauge, a little under the
    /// strip's icons, which carry their own circles.
    static func markSide(iconSize: CGFloat) -> CGFloat { min(14, max(9, iconSize - 4)) }

    /// The closed island lists the recording among its live activities
    /// (seam `notch-meeting3`): first, since it says what the person must
    /// know while it runs, and above all in a meeting the calendar shows.
    static var activities: [NotchCompactActivity] {
        let defaults = UserDefaults.standard
        let shows = ForkMeetingIslandRules.showsStrip(
            enabled: defaults.bool(forKey: ForkFeature.meetings.enabledKey),
            indicator: ForkMeetingIndicator(stored: defaults.string(forKey: ForkDefaultsKey.meetingsIndicator)),
            state: ForkMeetingIslandModel.shared.state)
        return shows ? [.meeting] : []
    }

    /// The wider of the two sides, the mark or the time, drawn as the strip
    /// draws them, with the timer's clearance from the silhouette's curve
    /// and air beside the camera (seam `notch-meeting3`). The meters only
    /// come where that leaves room.
    static func wing(in geometry: NotchGeometry) -> CGFloat {
        let provisional = geometry.compactTimerGeometry(showsDownloads: false,
                                                        wing: NotchTimerSupport.stripWingRange.lowerBound)
        let height = provisional.compactActivityContentHeight
        let textSize = NotchTimerSupport.stripTextSize(height: height)
        let reading = (NotchAgentSupport.readingShape(currentReading) as NSString)
            .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .medium)])
            .width.rounded(.up)
        let side = markSide(iconSize: NotchTimerSupport.stripIconSize(height: height))
        var mark = side + provisional.compactActivityEdgeInset(boxHeight: side, radius: side / 2)
        // Room for the microphone crossed out beside the mark, when it is.
        if let snapshot = ForkMeetingIslandModel.shared.snapshot,
           ForkMeetingIslandRules.showsMicrophoneMuted(snapshot.facts) {
            mark += markSpacing + side
        }
        return max(reading + provisional.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0), mark)
            + NotchTimerSupport.stripCameraGap
    }

    /// The floating capsule: the mark, the meters while recording or paused,
    /// and the time (seam `notch-meeting3`).
    static func capsuleSize(geometry: NotchGeometry) -> CGSize {
        let layout = NotchCapsuleLayout.self
        let meters = ForkMeetingIslandModel.shared.phase?.acceptsControls == true
            ? ForkMeetingIslandMeters.width + layout.spacing : 0
        let content = layout.symbolWidth + layout.spacing + meters
            + layout.width(NotchAgentSupport.readingShape(currentReading), font: layout.readingFont)
        return layout.surface(content: content, maximum: layout.Maximum.activity, geometry: geometry)
    }

    /// The time as the strip reads it now.
    private static var currentReading: String {
        ForkMeetingIslandRules.clock(ForkMeetingIslandModel.shared.elapsed(at: Date()))
    }

    // MARK: The island

    /// At launch (`ForkBootstrap.start`): the activity's name in the
    /// island's picker, and the Meeting button among its controls while the
    /// feature is on.
    static func start() {
        // The island's own tests build without the fork: it reaches the
        // strip through these hooks, never by its name (seam `notch-meeting`).
        NotchCompactActivity.meetingHooks = (title: { ForkMeetingStrings.strings($0).untitledMeeting },
                                             activities: { activities }, wing: { wing(in: $0) })
        NotchControlItem.meetingIsAvailable = { $0.bool(forKey: ForkFeature.meetings.enabledKey) }
    }

    /// The island lays itself out again: the strip came or went, or changed
    /// width. It moves between the two on its own springs (`NotchMotion`),
    /// or at once with Reduce Motion, as for any activity.
    static func refreshIsland() {
        let island = NotchService.shared
        // An island that is off or not up yet lays itself out when it comes.
        guard island.presentationWindow != nil else { return }
        island.objectWillChange.send()
        island.refreshPresentation()
    }
}

/// The mark left of the camera: the dot, the pause bars, the disk, or the
/// gauge of the file being finished.
private struct ForkMeetingIslandMark: View {
    let phase: ForkMeetingIslandPhase
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch phase.mark {
        case .dot:
            ForkMeetingRecordingDot(pulses: !reduceMotion, diameter: (side * 0.7).rounded())
                .frame(width: side, height: side)
        case .pause:
            Image(systemName: "pause.fill")
                .font(.system(size: side * 0.85, weight: .bold))
                .foregroundStyle(.orange)
        case .disk:
            Image(systemName: "externaldrive.fill.badge.exclamationmark")
                .font(.system(size: side * 0.85, weight: .semibold))
                .foregroundStyle(.orange)
        case .gauge:
            ForkMeetingIslandGauge(progress: phase.progress, side: side)
        }
    }
}

/// The microphone crossed out in orange: recorded, it sends nothing.
private struct ForkMeetingIslandMutedMicrophone: View {
    let side: CGFloat

    var body: some View {
        Image(systemName: "mic.slash.fill")
            .font(.system(size: side * 0.85, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// A small ring: filled as far as the final pass went, or a turning arc
/// while that is unknown (still with Reduce Motion).
struct ForkMeetingIslandGauge: View {
    let progress: Double?
    let side: CGFloat
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        let line = max(1.5, side * 0.16)
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: line)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 270 : -90))
                    .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
                    .onAppear { turning = !reduceMotion }
            }
        }
        .padding(line / 2)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The microphone's level, then the meeting's, as two small bar meters.
/// Only this view reads the levels, fifteen times a second while it is on
/// screen (twice with Reduce Motion), so the rest of the strip never
/// redraws for them. A source not heard is drawn flat and dim.
struct ForkMeetingIslandMeters: View {
    let snapshot: ForkMeetingIslandSnapshot
    let height: CGFloat
    var tint: Color = .white
    @ObservedObject private var model = ForkMeetingIslandModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two meters of three bars and the room between them.
    static let width: CGFloat = 2 * meterWidth + 3
    static let meterWidth: CGFloat = 3 * 2 + 2 * 1

    var body: some View {
        let live = snapshot.phase.showsLevels
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 15, paused: !live)) { _ in
            let levels = live ? model.levels() : .silent
            HStack(alignment: .center, spacing: 3) {
                if ForkMeetingIslandRules.showsMicrophoneMuted(snapshot.facts) {
                    // Recorded and silent: crossed out in orange, as the pill does.
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: min(9, height * 0.75), weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: Self.meterWidth, height: height)
                } else {
                    ForkMeetingIslandMeter(level: snapshot.hearsMicrophone ? levels.microphone : 0,
                                           heard: snapshot.hearsMicrophone && live, height: height, tint: tint,
                                           animated: !reduceMotion)
                }
                ForkMeetingIslandMeter(level: snapshot.hearsMeeting ? levels.meeting : 0,
                                       heard: snapshot.hearsMeeting && live, height: height, tint: tint,
                                       animated: !reduceMotion)
            }
        }
        .frame(width: Self.width, height: height)
        .accessibilityHidden(true)
    }
}

/// Three bars rising with a level, centred on the strip's middle line.
private struct ForkMeetingIslandMeter: View {
    let level: Float
    let heard: Bool
    let height: CGFloat
    let tint: Color
    let animated: Bool

    var body: some View {
        let value = CGFloat(min(1, max(0, level.isFinite ? level : 0)))
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<3, id: \.self) { index in
                let lit = heard ? min(1, max(0, (value - CGFloat(index) / 3) * 3)) : 0
                let shape: CGFloat = index == 1 ? 1 : 0.7
                Capsule(style: .continuous)
                    .fill(tint.opacity(heard ? 0.4 + 0.6 * lit : 0.25))
                    .frame(width: 2, height: max(2, height * shape * (0.25 + 0.75 * lit)))
            }
        }
        .frame(width: ForkMeetingIslandMeters.meterWidth, height: height)
        .animation(animated ? .linear(duration: 1.0 / 15) : nil, value: value)
    }
}

// MARK: - The pill steps aside

extension ForkMeetingIsland {
    /// Whether the closed island shows the recording's strip where the pill
    /// would stand: on the filmed display only, the island's own (a copy
    /// on every display is not assumed); not while the island is hidden, in
    /// full screen, or on another activity, nor while it takes no cards,
    /// since its strip then opens none.
    static func showsRecording(onDisplay displayID: UInt32?) -> Bool {
        let island = NotchService.shared
        let shown = island.showsSystemFeedback && NotchSupport.routes(.capture) && island.compactActivity == .meeting
        return ForkMeetingIslandRules.islandShowsRecording(
            activityShown: shown, islandScreen: island.geometry.screen,
            filmedScreen: displayID.flatMap { id in NSScreen.screens.first { $0.displayID == id } }?.frame,
            workedScreen: NSScreen.main?.frame)
    }

    /// Calls `change` on the main thread a moment after the island changed
    /// what it shows, until the returned token is released.
    static func observeIsland(_ change: @escaping () -> Void) -> AnyCancellable {
        NotchService.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { _ in change() }
    }
}
