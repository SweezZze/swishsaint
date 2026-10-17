// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import AppKit
import SwiftUI

/// The small pill at the bottom of the screen while dictating: bars that
/// follow the voice, a lock once hands-free, a spinner while the last words
/// are written out. It never takes the focus, so the text lands where the
/// person was typing.
final class ForkDictationHUD {
    static let shared = ForkDictationHUD()

    enum Phase: Equatable {
        case listening
        case handsFree
        case writing
        case problem(String)
    }

    final class Model: ObservableObject {
        static let barCount = 14
        @Published var phase: Phase = .listening
        @Published var levels = [Float](repeating: 0, count: Model.barCount)
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(_ phase: Phase) {
        hideWork?.cancel()
        hideWork = nil
        if case .listening = phase, model.phase != .listening && model.phase != .handsFree {
            model.levels = [Float](repeating: 0, count: Model.barCount)
        }
        withAnimation(.easeInOut(duration: 0.2)) { model.phase = phase }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        if case .problem = phase {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    func push(level: Float) {
        var levels = model.levels
        levels.removeFirst()
        levels.append(level)
        model.levels = levels
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ForkDictationPill(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Bottom center of the screen under the pointer, just above the Dock.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            return
        }
        let size = panel.frame.size
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 14))
    }
}

/// Sober on purpose: a small dark capsule, white marks only, the same in
/// light and dark mode, so it reads like part of the system.
private struct ForkDictationPill: View {
    @ObservedObject var model: ForkDictationHUD.Model

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening, .handsFree:
            ForkDictationWave(levels: model.levels)
            if model.phase == .handsFree {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .transition(.opacity)
            }
        case .writing:
            ForkDictationDots()
        case let .problem(message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The voice as thin bars, tallest in the middle, eased so they glide
/// rather than jump.
private struct ForkDictationWave: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: height(level, at: index))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func height(_ level: Float, at index: Int) -> CGFloat {
        let middle = Double(levels.count - 1) / 2
        let weight = 1 - abs(Double(index) - middle) / (middle + 1) * 0.6
        return 2 + CGFloat(Double(level) * weight) * 14
    }
}

/// Three dots breathing in turn while the last words are written out.
private struct ForkDictationDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 4, height: 4)
                        .opacity(0.35 + 0.55 * (0.5 + 0.5 * sin(time * 6 - Double(index) * 0.9)))
                }
            }
            .frame(width: 44, height: 16)
        }
    }
}
