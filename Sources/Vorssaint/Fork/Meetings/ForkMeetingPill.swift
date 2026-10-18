// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The pill shown while a meeting records: the red dot, the time, the
/// microphone's and the meeting's levels, pause and stop. The pointer on it
/// adds the meeting's name and the button that films the display instead of
/// the window, or back.
///
/// It floats, like the recorder's own pill, so a full menu bar can never
/// drop the one control that ends a recording; and it moves, unlike that
/// one, since a meeting lasts long enough to be in the way. By default it
/// sits under the menu bar just right of the island at rest or of the
/// camera; where the person drags it is kept per display.
///
/// Our recording leaves it out: the capture filter excludes all of this
/// app's windows (`window` is here for a filter that names windows). In
/// someone else's screen share it follows the official "Show in screenshots
/// and videos" setting, like the Command Bar.
final class ForkMeetingPill {
    struct Actions {
        var pause: () -> Void = {}
        var resume: () -> Void = {}
        var stop: () -> Void = {}
        var toggleTarget: () -> Void = {}
    }

    private let model = ForkMeetingPillModel()
    private let ticker = ForkMeetingPillTicker()
    private var levels: () -> ForkMeetingLevels = { ForkMeetingLevels() }
    private var actions = Actions()
    private var panel: NSPanel?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var geometryWatch: AnyCancellable?
    private var collapseWork: DispatchWorkItem?
    private var screensWork: DispatchWorkItem?
    private var dragWork: DispatchWorkItem?
    private var dragObserver: NSObjectProtocol?
    private var dragStart: CGPoint?
    /// The person dragged it there: it stays, the island moving or not.
    private var placedByPerson = false
    /// Bumped by each show: a fade-out overtaken by a newer show must not
    /// order the panel out from its completion handler.
    private var generation = 0

    /// The pill's window, created by `prepare` before the first recording,
    /// so a capture filter built before the pill shows can already name it.
    var window: NSWindow? { panel }
    var windowNumber: Int? { panel.map(\.windowNumber).flatMap { $0 > 0 ? $0 : nil } }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `levels` runs on the main thread at each tick: it reads the engine's
    /// latest levels under its lock and returns at once.
    func configure(levels: @escaping () -> ForkMeetingLevels, actions: Actions) {
        self.levels = levels
        self.actions = actions
    }

    @discardableResult
    func prepare() -> NSPanel {
        if let panel { return panel }
        let size = ForkMeetingPillLayout.restingSize
        let panel = OverlayPanel(contentRect: CGRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = ForkMeetingHostingView(rootView: makeView())
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host
        self.panel = panel
        return panel
    }

    func show(_ state: ForkMeetingPillState, context: ForkMeetingLiveContext) {
        guard state != .hidden else {
            hide()
            return
        }
        generation += 1
        let panel = prepare()
        let appearing = !panel.isVisible || model.state == .hidden || panel.alphaValue < 1
        model.text = ForkMeetingStrings.current
        model.reducesMotion = reducesMotion
        // A new recording's gauge starts from nothing, even when the pill
        // was still on the last meeting's.
        if case .recording = state, model.state == .finalizing || model.state == .hidden { model.progress = nil }
        if appearing {
            model.hovering = false
            model.progress = nil
            model.state = state
            model.context = context
        } else {
            withAnimation(model.reducesMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.25)) {
                model.state = state
                model.context = context
            }
        }
        tick()
        updateTicker()
        applySharing()
        guard appearing else {
            fit()
            return
        }
        place(panel, on: screen(for: context))
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        observe()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func update(_ context: ForkMeetingLiveContext) {
        guard model.context != context else { return }
        withAnimation(model.reducesMotion ? nil : .smooth(duration: 0.25)) { model.context = context }
        fit()
    }

    /// The final pass's share done, between 0 and 1; `nil` while unknown.
    func setFinalizing(progress: Double?) {
        guard model.progress != progress else { return }
        let changesKind = (model.progress == nil) != (progress == nil)
        model.progress = progress
        if changesKind { fit() }
    }

    func hide() {
        stopTicker()
        unobserve()
        collapseWork?.cancel()
        collapseWork = nil
        guard let panel, panel.isVisible else {
            model.state = .hidden
            return
        }
        generation += 1
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == hiding else { return }
            panel.orderOut(nil)
            self.model.state = .hidden
            self.model.hovering = false
        })
    }

    // MARK: - Ticks

    /// Fifteen readings a second while recording, for the meters; the time
    /// only needs one. With Reduce Motion, twice a second: the meters still
    /// follow the voices, which is information, not decoration. Paused or
    /// finishing, nothing ticks.
    private func updateTicker() {
        guard case .recording = model.state else {
            stopTicker()
            return
        }
        let interval = model.reducesMotion ? 0.5 : 1.0 / 15
        if let timer, timer.timeInterval == interval { return }
        stopTicker()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let clock: ForkMeetingClock?
        switch model.state {
        case let .recording(running, _): clock = running
        case let .paused(stopped, _, _): clock = stopped
        case .hidden, .stopping, .finalizing: clock = nil
        }
        if let clock {
            let text = ForkMeetingPillLayout.clock(clock.elapsed(at: Date()))
            if text != ticker.clock {
                // Past the hour the time takes two more digits once.
                let widens = text.count != ticker.clock.count
                ticker.clock = text
                if widens { fit() }
            }
        }
        if case .recording = model.state {
            let reading = levels()
            if reading != ticker.levels { ticker.levels = reading }
        } else if ticker.levels != ForkMeetingLevels() {
            ticker.levels = ForkMeetingLevels()
        }
    }

    // MARK: - Size and place

    /// The buttons reach the actions through the pill, so a `configure`
    /// after the panel was made still holds.
    private func makeView() -> ForkMeetingPillView {
        let forward = Actions(pause: { [weak self] in self?.actions.pause() },
                              resume: { [weak self] in self?.actions.resume() },
                              stop: { [weak self] in self?.actions.stop() },
                              toggleTarget: { [weak self] in self?.actions.toggleTarget() })
        return ForkMeetingPillView(model: model, ticker: ticker, actions: forward,
                            beginDrag: { [weak self] in self?.beginDrag() },
                            resetPlace: { [weak self] in self?.resetPlace() })
    }

    /// The pill's size for what it shows now, measured on a host of its own:
    /// the panel's host never sizes itself, so SwiftUI cannot resize the
    /// window behind our back, and a fresh one answers for the new state,
    /// not the one last drawn.
    private func fittedSize() -> CGSize {
        let ideal = NSHostingView(rootView: makeView()).fittingSize
        return CGSize(width: max(ForkMeetingPillLayout.restingSize.width, ideal.width.rounded(.up)),
                      height: ForkMeetingPillLayout.restingSize.height)
    }

    /// A new width keeps the left edge where it is, unless the pill would
    /// leave its display.
    private func fit() {
        guard let panel, panel.isVisible else { return }
        let size = fittedSize()
        guard size != panel.frame.size else { return }
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let frame = ForkMeetingPillLayout.resized(panel.frame, to: size, within: area)
        if model.reducesMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
        panel.invalidateShadow()
    }

    private func screen(for context: ForkMeetingLiveContext) -> NSScreen? {
        if let id = context.displayID, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return ForkDictationHUD.activeScreen() ?? NSScreen.main
    }

    private func place(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let size = fittedSize()
        let positions = ForkMeetingPillPositions(
            json: UserDefaults.standard.string(forKey: ForkDefaultsKey.meetingsPillPositions))
        if let origin = positions.origin(on: Self.key(screen), size: size, screenFrame: screen.frame,
                                         visibleFrame: screen.visibleFrame) {
            placedByPerson = true
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        } else {
            placedByPerson = false
            panel.setFrame(CGRect(origin: Self.defaultOrigin(size: size, on: screen), size: size), display: true)
        }
        panel.invalidateShadow()
    }

    private static func defaultOrigin(size: CGSize, on screen: NSScreen) -> CGPoint {
        let camera = screen.auxiliaryTopRightArea.flatMap { area -> CGFloat? in
            area.isEmpty ? nil : ForkMeetingPillLayout.cameraRightEdge(auxiliaryMinX: area.minX,
                                                                        screenFrame: screen.frame)
        }
        return ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: screen.visibleFrame,
                                                   cameraRightEdge: camera,
                                                   islandFrame: ForkMeetingIsland.restingFrame(on: screen))
    }

    /// A display's lasting name: its ID can change between two launches.
    private static func key(_ screen: NSScreen) -> String {
        let id = screen.displayID
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return String(id)
    }

    /// Back to the default place, the island having moved or the displays
    /// changed; a pill the person placed only comes back inside its display.
    private func reposition() {
        guard let panel, panel.isVisible else { return }
        let current = panel.screen
        guard let screen = current ?? screen(for: model.context) else { return }
        if placedByPerson, current != nil {
            let frame = ForkMeetingPillLayout.clamped(panel.frame, into: screen.visibleFrame)
            if frame != panel.frame { panel.setFrame(frame, display: true) }
            return
        }
        place(panel, on: screen)
    }

    // MARK: - Drag

    /// The window server moves the panel, like a title bar; the place is
    /// kept once it stops moving.
    private func beginDrag() {
        guard let panel else { return }
        dragStart = dragStart ?? panel.frame.origin
        if dragObserver == nil {
            dragObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                                  object: panel, queue: .main) { [weak self] _ in
                self?.scheduleDragEnd()
            }
        }
        scheduleDragEnd()
    }

    private func scheduleDragEnd() {
        dragWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endDrag() }
        dragWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func endDrag() {
        dragWork = nil
        if let dragObserver { NotificationCenter.default.removeObserver(dragObserver) }
        dragObserver = nil
        let start = dragStart
        dragStart = nil
        guard let panel, let start, panel.frame.origin != start else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen else { return }
        let frame = ForkMeetingPillLayout.clamped(panel.frame, into: screen.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        var positions = ForkMeetingPillPositions(
            json: UserDefaults.standard.string(forKey: ForkDefaultsKey.meetingsPillPositions))
        positions.remember(frame, on: Self.key(screen), screenFrame: screen.frame)
        UserDefaults.standard.set(positions.json, forKey: ForkDefaultsKey.meetingsPillPositions)
        placedByPerson = true
    }

    /// A double click on the pill puts it back at its default place, and
    /// forgets the one kept for that display.
    private func resetPlace() {
        guard let panel, let screen = panel.screen ?? screen(for: model.context) else { return }
        var positions = ForkMeetingPillPositions(
            json: UserDefaults.standard.string(forKey: ForkDefaultsKey.meetingsPillPositions))
        positions.forget(Self.key(screen))
        UserDefaults.standard.set(positions.json, forKey: ForkDefaultsKey.meetingsPillPositions)
        placedByPerson = false
        let frame = CGRect(origin: Self.defaultOrigin(size: panel.frame.size, on: screen), size: panel.frame.size)
        if model.reducesMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    // MARK: - Hover

    /// The name and the target button come with the pointer and leave a
    /// moment after it, so crossing an edge does not make the pill flicker.
    private func hoverChanged(_ inside: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        if inside {
            guard !model.hovering else { return }
            setHovering(true)
        } else {
            guard model.hovering else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.dragStart == nil else { return }
                self.setHovering(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func setHovering(_ hovering: Bool) {
        withAnimation(model.reducesMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.2)) {
            model.hovering = hovering
        }
        fit()
    }

    // MARK: - Observers

    /// Only while the pill shows: a feature turned off leaves nothing
    /// listening.
    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }))
        observers.append((center, center.addObserver(forName: UserDefaults.didChangeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.applySharing()
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.motionChanged()
        }))
        geometryWatch = ForkMeetingIsland.observeGeometry { [weak self] in
            guard let self, !self.placedByPerson else { return }
            self.reposition()
        }
    }

    private func unobserve() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        geometryWatch = nil
        screensWork?.cancel()
        screensWork = nil
        dragWork?.cancel()
        dragWork = nil
        if let dragObserver { NotificationCenter.default.removeObserver(dragObserver) }
        dragObserver = nil
        dragStart = nil
    }

    /// Displays come and go in bursts: the last one settles the place.
    private func screensChanged() {
        screensWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reposition() }
        screensWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func motionChanged() {
        model.reducesMotion = reducesMotion
        updateTicker()
    }

    private func applySharing() {
        let sharing: NSWindow.SharingType = ForkMeetingIsland.showsInCaptures ? .readOnly : .none
        if panel?.sharingType != sharing { panel?.sharingType = sharing }
    }
}

final class ForkMeetingPillModel: ObservableObject {
    @Published var state: ForkMeetingPillState = .hidden
    @Published var context = ForkMeetingLiveContext()
    @Published var progress: Double?
    @Published var hovering = false
    @Published var reducesMotion = false
    var text = ForkMeetingStrings.current

    var look: ForkMeetingPillLook? {
        ForkMeetingPillLook(state: state, context: context, finalizingProgress: progress, reducesMotion: reducesMotion)
    }
}

/// What changes at each tick, apart from the rest: only the time and the
/// meters observe it, so fifteen readings a second never redraw the pill.
final class ForkMeetingPillTicker: ObservableObject {
    @Published var clock = "0:00"
    @Published var levels = ForkMeetingLevels()
}

// MARK: - The pill

/// Dark in light and dark mode, like the recorder's pill and the island;
/// red only for the recording light and stop, orange for what asks for
/// attention.
struct ForkMeetingPillView: View {
    @ObservedObject var model: ForkMeetingPillModel
    let ticker: ForkMeetingPillTicker
    let actions: ForkMeetingPill.Actions
    let beginDrag: () -> Void
    let resetPlace: () -> Void

    var body: some View {
        content
            .padding(.leading, 11)
            .padding(.trailing, 4)
            .frame(minWidth: ForkMeetingPillLayout.restingSize.width,
                   maxWidth: .infinity, minHeight: 32, maxHeight: .infinity, alignment: .leading)
            .background(ForkMeetingPillDragHandle(beginDrag: beginDrag, reset: resetPlace))
            .background(
                Capsule(style: .continuous)
                    .fill(Color(white: 0.12).opacity(0.94))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            )
            .clipShape(Capsule(style: .continuous))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.text.pillRecording)
            // The name, what is filmed and ⧉ show under the pointer only:
            // VoiceOver has them at any time.
            .accessibilityValue(accessibilityValue)
            .accessibilityActions {
                if model.look?.showsControls == true, model.context.canSwitchTarget {
                    Button(toggleLabel) { actions.toggleTarget() }
                }
            }
    }

    private var filmed: String {
        ForkMeetingServiceSupport.filmed(target: model.context.target, appName: model.context.appName,
                                         noWindowToFilm: model.context.noWindowToFilm, strings: model.text)
    }

    private var accessibilityValue: String {
        guard model.look?.showsControls == true else { return "" }
        let value = (model.context.title ?? model.text.untitledMeeting) + ", " + filmed
        return soundNote.map { value + ", " + $0 } ?? value
    }

    /// Why the meeting's meter is crossed out, when it is.
    private var soundNote: String? {
        ForkMeetingPillView.soundNote(model.context.trackSound, text: model.text)
    }

    static func soundNote(_ sound: ForkMeetingTrackSound, text: ForkMeetingStrings) -> String? {
        switch sound {
        case .heard: return nil
        case .noApp: return text.soundNoApp
        case .lost: return text.noticeSoundLost
        }
    }

    private var toggleLabel: String {
        model.context.target == .window ? model.text.pillFilmDisplay : model.text.pillFilmTheWindow
    }

    @ViewBuilder
    private var content: some View {
        if let look = model.look {
            let text = model.text
            HStack(spacing: 6) {
                ForkMeetingPillMark(mark: look.mark)
                if look.showsClock {
                    ForkMeetingPillClock(ticker: ticker, alert: look.clockIsAlert, label: text.pillElapsed)
                }
                if model.hovering, look.showsControls {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.context.title ?? text.untitledMeeting)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                        // What is filmed: the window of which app, or the screen.
                        Text(filmed)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.6))
                        if let soundNote {
                            Text(soundNote)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
                status(look.status, text: text)
                    .transition(.opacity)
                if look.showsControls {
                    controls(paused: look.paused, text: text)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func status(_ status: ForkMeetingPillLook.Status, text: ForkMeetingStrings) -> some View {
        switch status {
        case .meters:
            ForkMeetingPillMeters(ticker: ticker, context: model.context, text: text,
                                  animated: !model.reducesMotion)
        case .paused:
            label(text.pillPaused, color: .orange)
        case let .diskLow(minutes):
            label(text.diskMinutes(minutes), color: .orange)
        case .pictureFrozen:
            label(text.pillPictureFrozen, color: .orange)
        case .sourceGone:
            label(text.noticeSourceGone, color: .orange)
        case .stopping:
            label(text.pillStopping, color: .white.opacity(0.85))
        case let .finalizing(progress):
            label(text.pillFinalizing, color: .white.opacity(0.85))
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 44)
                    .accessibilityLabel(text.pillFinalizing)
            }
        }
    }

    private func label(_ string: String, color: Color) -> some View {
        Text(string)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func controls(paused: Bool, text: ForkMeetingStrings) -> some View {
        HStack(spacing: 0) {
            pillButton(symbol: paused ? "play.fill" : "pause.fill", color: .white,
                       label: paused ? text.pillResume : text.pillPause,
                       action: paused ? actions.resume : actions.pause)
            pillButton(symbol: "stop.fill", color: Color(nsColor: .systemRed), label: text.pillStop,
                       action: actions.stop)
            if model.hovering, model.context.canSwitchTarget {
                let window = model.context.target == .window
                pillButton(symbol: window ? "display" : "macwindow", color: .white,
                           label: window ? text.pillFilmDisplay : text.pillFilmTheWindow,
                           action: actions.toggleTarget)
                    .transition(.opacity)
            }
        }
    }

    private func pillButton(symbol: String, color: Color, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 8, lifts: false))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The time, in digits of one width so it does not jiggle, room kept for
/// "00:00" so the pill does not grow at ten minutes; it grows once, at the
/// hour.
private struct ForkMeetingPillClock: View {
    @ObservedObject var ticker: ForkMeetingPillTicker
    let alert: Bool
    let label: String

    var body: some View {
        Text(ticker.clock)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(alert ? Color.orange : Color.white)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 40, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(ticker.clock)
    }
}

/// The microphone's level, then the meeting's. A microphone left out of
/// the recording is crossed out in grey; one that sends nothing, in orange.
private struct ForkMeetingPillMeters: View {
    @ObservedObject var ticker: ForkMeetingPillTicker
    let context: ForkMeetingLiveContext
    let text: ForkMeetingStrings
    let animated: Bool

    var body: some View {
        HStack(spacing: 5) {
            if !context.recordsMicrophone {
                crossed(color: .white.opacity(0.45), label: text.pillMicrophoneOff)
            } else if context.microphoneSilent {
                crossed(color: .orange, label: text.noticeMicrophoneSilent)
            } else {
                ForkMeetingMiniMeter(level: ticker.levels.microphone, animated: animated)
                    .help(text.pillMicrophoneLevel)
                    .accessibilityLabel(text.pillMicrophoneLevel)
            }
            if let note = ForkMeetingPillView.soundNote(context.trackSound, text: text) {
                crossed(symbol: "speaker.slash.fill", color: .orange, label: note)
            } else {
                ForkMeetingMiniMeter(level: ticker.levels.meeting, animated: animated)
                    .help(text.pillMeetingLevel)
                    .accessibilityLabel(text.pillMeetingLevel)
            }
        }
        .allowsHitTesting(false)
    }

    private func crossed(symbol: String = "mic.slash.fill", color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 12, height: 16)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Three bars rising with the level, like the menu bar's sound meters.
private struct ForkMeetingMiniMeter: View {
    let level: Float
    let animated: Bool

    var body: some View {
        let value = CGFloat(min(1, max(0, level.isFinite ? level : 0)))
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                let lit = min(1, max(0, (value - CGFloat(index) / 3) * 3))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.35 + 0.6 * lit))
                    .frame(width: 2.5, height: 3 + 11 * lit * (0.6 + 0.2 * CGFloat(index)))
            }
        }
        .frame(width: 12, height: 16, alignment: .bottom)
        .animation(animated ? .linear(duration: 1.0 / 15) : nil, value: value)
        .accessibilityElement()
        .accessibilityValue((Double(value)).formatted(.percent.precision(.fractionLength(0))))
    }
}

private struct ForkMeetingPillMark: View {
    let mark: ForkMeetingPillLook.Mark

    var body: some View {
        Group {
            switch mark {
            case let .recording(pulses):
                ForkMeetingRecordingDot(pulses: pulses)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.orange)
            case .working:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// The recorder's own light: red, breathing from full to 0.28 in 0.85 s,
/// drawn by Core Animation so it stays live without waking the app. Still
/// with Reduce Motion.
private struct ForkMeetingRecordingDot: NSViewRepresentable {
    let pulses: Bool

    func makeNSView(context: Context) -> DotView {
        let view = DotView()
        view.pulses = pulses
        return view
    }

    func updateNSView(_ view: DotView, context: Context) {
        view.pulses = pulses
    }

    final class DotView: NSView {
        private let dot = CALayer()

        var pulses = true {
            didSet { if pulses != oldValue { refresh() } }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            dot.backgroundColor = NSColor.systemRed.cgColor
            dot.cornerRadius = 4
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: (bounds.width - 8) / 2, y: (bounds.height - 8) / 2, width: 8, height: 8)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refresh()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func refresh() {
            guard pulses else {
                dot.removeAnimation(forKey: "pulse")
                dot.opacity = 1
                return
            }
            guard dot.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.28
            pulse.duration = 0.85
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }
}

/// The pill's body, under its buttons: dragging it moves the panel through
/// the window server, as a title bar does, rather than with a SwiftUI
/// gesture whose translation is read in a space that moves with the window.
private struct ForkMeetingPillDragHandle: NSViewRepresentable {
    let beginDrag: () -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.beginDrag = beginDrag
        view.reset = reset
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.beginDrag = beginDrag
        view.reset = reset
    }

    final class HandleView: NSView {
        var beginDrag: () -> Void = {}
        var reset: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                reset()
                return
            }
            guard let window else { return }
            beginDrag()
            window.performDrag(with: event)
        }
    }
}
