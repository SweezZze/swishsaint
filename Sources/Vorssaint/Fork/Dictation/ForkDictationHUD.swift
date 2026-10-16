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
        static let barCount = 9
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.phase = phase }
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
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 20))
    }
}

private struct ForkDictationPill: View {
    @ObservedObject var model: ForkDictationHUD.Model

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening, .handsFree:
            Image(systemName: model.phase == .handsFree ? "lock.fill" : "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.phase == .handsFree ? Color.accentColor : Color.red)
                .frame(width: 14)
            HStack(spacing: 3) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(width: 3, height: 4 + CGFloat(level) * 16)
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.08), value: model.levels)
        case .writing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: 14, height: 14)
            Image(systemName: "text.cursor")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case let .problem(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
