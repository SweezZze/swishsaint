// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The bubble shown while dictating when the island cannot take it: a dark
/// capsule centered under the menu bar of the screen being worked on, where
/// the recorder's own pill sits. It never takes the focus or a click, so the
/// text lands where the person was typing.
final class ForkDictationHUD {
    /// The panel is wider than any bubble: the capsule changes its width
    /// inside it, animated, without the window being resized.
    private static let panelSize = CGSize(width: 520, height: 64)

    private let meter: ForkDictationLevelMeter
    private let model = ForkDictationBubbleModel()
    private var panel: NSPanel?
    private var clock: Timer?
    private var clockStart = Date()
    /// Bumped by each show. A fade-out overtaken by a newer show must not
    /// order the panel out from its completion handler.
    private var generation = 0

    init(meter: ForkDictationLevelMeter) {
        self.meter = meter
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(_ presentation: ForkDictationPresentation) {
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let appearing = !panel.isVisible || panel.alphaValue < 1
        if appearing {
            // A fresh bubble starts from its new step, without morphing from
            // the last dictation's.
            model.text = ForkDictationStrings.strings(L10n.shared.language)
            model.presentation = presentation
            refreshFrame(at: Date())
        } else {
            withAnimation(reducesMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.25)) {
                model.presentation = presentation
            }
        }
        switch presentation {
        case .listening, .transcribing: startClock()
        default: stopClock()
        }
        guard appearing else { return }
        if !panel.isVisible {
            place(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// A press that cannot be served now: a short no, like a login field.
    func shake() {
        guard panel?.isVisible == true, !reducesMotion else { return }
        withAnimation(.linear(duration: 0.36)) { model.shakes += 1 }
    }

    func hide() {
        stopClock()
        guard let panel, panel.isVisible else { return }
        generation += 1
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == hiding else { return }
            panel.orderOut(nil)
            self.model.presentation = .hidden
        })
    }

    // MARK: - Clock

    /// Forty frames a second while the voice is drawn, and only then. With
    /// Reduce Motion the wave stops breathing and is read twice a second:
    /// it still follows the voice, which is information, not decoration.
    private func startClock() {
        guard clock == nil else { return }
        clockStart = Date()
        let interval = reducesMotion ? 0.5 : 1.0 / 40
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshFrame(at: Date())
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func refreshFrame(at now: Date) {
        let phase = reducesMotion ? 0 : now.timeIntervalSince(clockStart)
        model.frame = ForkDictationBubbleModel.Frame(samples: meter.samples(at: phase), now: now, phase: phase)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule draws its own shadow: the panel's would outline the
        // whole transparent rectangle.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ForkDictationBubble(model: model))
        host.frame = CGRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Centered under the menu bar of the screen with the window being
    /// worked on, which is where the text goes; else the pointer's.
    private func place(_ panel: NSPanel) {
        guard let screen = Self.activeScreen() else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (area.midX - Self.panelSize.width / 2).rounded(),
                                     y: (area.maxY - Self.panelSize.height - 2).rounded()))
    }

    static func activeScreen() -> NSScreen? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
           let front = windows.first(where: {
               ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
           }),
           let bounds = front[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds),
           let primary = NSScreen.screens.first {
            // Window bounds count down from the top of the primary screen.
            let flipped = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY,
                                 width: rect.width, height: rect.height)
            let center = CGPoint(x: flipped.midX, y: flipped.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }
}

final class ForkDictationBubbleModel: ObservableObject {
    struct Frame {
        var samples: [CGFloat] = []
        var now = Date()
        /// Seconds since the clock started: the pulse, the breathing and the
        /// dots all read it. Zero with Reduce Motion.
        var phase: TimeInterval = 0
    }

    @Published var presentation: ForkDictationPresentation = .hidden
    @Published var frame = Frame()
    @Published var shakes = 0
    var text = ForkDictationStrings.strings(L10n.shared.language)
}

// MARK: - The bubble

/// Sober on purpose: one dark capsule, white marks, orange only for what
/// asks for attention. The same in light and dark mode, like the island.
private struct ForkDictationBubble: View {
    @ObservedObject var model: ForkDictationBubbleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var voice

    var body: some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.leading, 12)
            .padding(.trailing, 13)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.94))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            )
            .modifier(ForkDictationShake(shakes: CGFloat(model.shakes)))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        let text = model.text
        HStack(spacing: 8) {
            switch model.presentation {
            case .hidden:
                EmptyView()
            case let .listening(handsFree, startedAt, nearLimit):
                ForkDictationRecordingDot(phase: model.frame.phase)
                ForkDictationWaveformView(samples: model.frame.samples)
                    .frame(width: 96, height: 18)
                    .modifier(ForkDictationMorph(id: "voice", namespace: voice, enabled: !reduceMotion))
                let elapsed = model.frame.now.timeIntervalSince(startedAt)
                if elapsed >= 1 {
                    Text(ForkDictationPresenter.clock(elapsed))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(nearLimit ? Color.orange : Color.white.opacity(0.75))
                        .transition(.opacity)
                }
                if handsFree {
                    ForkDictationStopMark()
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            case .transcribing:
                ForkDictationDots(phase: model.frame.phase)
                    .frame(width: 30, height: 18)
                    .modifier(ForkDictationMorph(id: "voice", namespace: voice, enabled: !reduceMotion))
                label(text.statusTranscribing, secondary: true)
            case let .pasted(excerpt):
                ForkDictationCheckmark(animated: !reduceMotion)
                    .frame(width: 13, height: 13)
                label(text.statusPasted)
                excerptLabel(excerpt)
            case let .copied(excerpt):
                mark("doc.on.clipboard.fill", color: .orange)
                label(text.statusCopied)
                excerptLabel(excerpt)
            case .keptInClipboard:
                mark("doc.on.clipboard.fill", color: .orange)
                label(text.statusKeptInClipboard)
            case .inHistoryOnly:
                mark("clock.arrow.circlepath", color: .orange)
                label(text.statusInHistoryOnly)
            case let .nothingHeard(afterSilence):
                mark("waveform.slash", color: .white.opacity(0.75))
                label(afterSilence ? text.statusNothingHeardSilence : text.statusNothingHeard, secondary: true)
            case .cancelled:
                mark("xmark", color: .white.opacity(0.75))
                label(text.statusCancelled, secondary: true)
            case .busy:
                mark("hourglass", color: .white.opacity(0.75))
                label(text.statusBusy, secondary: true)
            case let .failure(failure):
                mark("exclamationmark.triangle.fill", color: .orange)
                label(failure.summary(text))
            }
        }
        .transition(.opacity)
    }

    private func mark(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)
            .transition(.opacity)
    }

    private func label(_ string: String, secondary: Bool = false) -> some View {
        Text(string)
            .fontWeight(.semibold)
            .foregroundStyle(secondary ? Color.white.opacity(0.75) : Color.white)
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity)
    }

    /// What was written, on one line: enough to recognise it, never the
    /// whole paragraph.
    @ViewBuilder
    private func excerptLabel(_ excerpt: String) -> some View {
        if !excerpt.isEmpty {
            Text(excerpt)
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

/// The wave and the dots are one shape that folds and unfolds; with Reduce
/// Motion they simply cross-fade.
private struct ForkDictationMorph: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// Red, like every recording light on the Mac, and breathing slowly so it
/// reads as live even through a silence.
private struct ForkDictationRecordingDot: View {
    let phase: TimeInterval

    var body: some View {
        let beat = 0.5 + 0.5 * cos(phase * 2 * .pi / 1.4)
        Circle()
            .fill(Color(red: 1, green: 0.27, blue: 0.23))
            .frame(width: 7, height: 7)
            .opacity(0.55 + 0.45 * beat)
            .background(
                Circle()
                    .fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.35 * beat))
                    .frame(width: 13, height: 13)
            )
            .frame(width: 13, height: 13)
    }
}

/// Hands-free: the next press of the key stops, and this says so.
private struct ForkDictationStopMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white.opacity(0.85))
            .frame(width: 7, height: 7)
            .padding(4)
            .background(Circle().fill(Color.white.opacity(0.14)))
    }
}

/// Three dots lit in turn while the words are written out.
private struct ForkDictationDots: View {
    let phase: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .opacity(phase == 0 ? 0.7 : 0.3 + 0.7 * (0.5 + 0.5 * sin(phase * 6 - Double(index) * 0.9)))
            }
        }
    }
}

/// A check that draws itself, once.
private struct ForkDictationCheckmark: View {
    let animated: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        ForkDictationCheckShape()
            .trim(from: 0, to: progress)
            .stroke(Color(red: 0.2, green: 0.85, blue: 0.45),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .onAppear {
                guard animated else {
                    progress = 1
                    return
                }
                withAnimation(.easeOut(duration: 0.25)) { progress = 1 }
            }
    }
}

private struct ForkDictationCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.minY + rect.height * 0.14))
        return path
    }
}

/// Three quick swings that settle back in place.
private struct ForkDictationShake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(shakes * .pi * 6), y: 0))
    }
}
