// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import SwiftUI

/// What the lift will do, shown while a trackpad window gesture is under way.
///
/// Two panels, picked by what the preview says:
///
/// - **A traffic light on the pointer** (close, minimize, full screen, quit):
///   the button the gesture stands for, where the pointer rests. The pointer
///   does not move during a two-finger gesture, so its tip lands in the middle
///   of the light.
/// - **A glass HUD centered on the target's screen** (halves, quarters, fill,
///   center, or a question mark for a sequence without action): a small screen
///   with the target zone in the accent color. Screen-relative geometry would
///   be cramped, even cut, next to a title bar at the top of the screen.
///
/// One gesture can go from one to the other (↓ minimizes, ↓ then → is a
/// quarter), so each has its own panel and one fades out as the other fades
/// in. Neither ever takes focus or the mouse.
final class ForkTrackpadGesturePreview {
    static let shared = ForkTrackpadGesturePreview()

    private let hud = ForkTrackpadPreviewWindow(style: .hud)
    private let pointerLight = ForkTrackpadPreviewWindow(style: .pointerLight)

    private init() {}

    /// - Parameters:
    ///   - targetFrame: the target window, in Accessibility coordinates: its
    ///     screen hosts the HUD. `nil` for a Dock icon, which uses the
    ///     pointer's screen.
    ///   - pointer: where the gesture began, in Accessibility coordinates.
    ///   - appIcon: for quitting, the icon of the app about to quit; for
    ///     emptying the Trash, the Trash's; for calling windows back, their
    ///     app's.
    func show(_ content: ForkTrackpadPreviewContent,
              targetFrame: CGRect?,
              pointer: CGPoint,
              appIcon: NSImage?) {
        let (shown, other) = content.isAtPointer ? (pointerLight, hud) : (hud, pointerLight)
        other.hide()
        shown.show(content, appIcon: appIcon, targetFrame: targetFrame, pointer: pointer)
    }

    func hide() {
        hud.hide()
        pointerLight.hide()
    }
}

// MARK: - One preview panel

private final class ForkTrackpadPreviewWindow {
    enum Style {
        /// A 160 pt glass HUD, centered on the target's screen.
        case hud
        /// A 22 pt light on the pointer, without a background.
        case pointerLight

        var size: CGSize {
            switch self {
            case .hud: return CGSize(width: 160, height: 160)
            // The light, plus room for its shadow and the quit icon's corner.
            case .pointerLight: return CGSize(width: 44, height: 44)
            }
        }
    }

    static let cornerRadius: CGFloat = 32
    static let lightDiameter: CGFloat = 22
    static let appearDuration: TimeInterval = 0.12
    static let disappearDuration: TimeInterval = 0.1
    static let appearScale: CGFloat = 0.92

    let style: Style
    private var panel: NSPanel?
    private let model = ForkTrackpadPreviewModel()
    /// Bumped on every appearance: a late fade-out must not close the panel of
    /// the next gesture.
    private var generation = 0
    private var isShown = false

    init(style: Style) {
        self.style = style
    }

    func show(_ content: ForkTrackpadPreviewContent,
              appIcon: NSImage?,
              targetFrame: CGRect?,
              pointer: CGPoint) {
        model.appIcon = appIcon
        model.content = content
        // An update: the view animates from one content to the next.
        guard !isShown else { return }

        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.maxY else { return }
        let targetAX: CGRect
        switch style {
        case .hud:
            let frames = screens.map { Self.axRect(fromAppKit: $0.frame, primaryHeight: primaryHeight) }
            guard let index = ForkTrackpadPreviewPlacement.screenIndex(targetFrame: targetFrame,
                                                                        pointer: pointer,
                                                                        screens: frames)
            else { return }
            model.screenAspect = frames[index].width / max(frames[index].height, 1)
            let visible = Self.axRect(fromAppKit: screens[index].visibleFrame, primaryHeight: primaryHeight)
            targetAX = ForkTrackpadPreviewPlacement.frame(size: style.size, centeredIn: visible)
        case .pointerLight:
            targetAX = ForkTrackpadPreviewPlacement.frame(size: style.size, centeredOn: pointer)
        }
        // The same flip both ways: Accessibility's origin is the top left of
        // the main screen, AppKit's its bottom left.
        let target = Self.axRect(fromAppKit: targetAX, primaryHeight: primaryHeight)

        isShown = true
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduceMotion ? target : target.insetBy(dx: target.width * (1 - Self.appearScale) / 2,
                                                            dy: target.height * (1 - Self.appearScale) / 2)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        }
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        let hiding = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.disappearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // A new gesture may have brought the panel back during the fade.
            guard let self, let panel, self.generation == hiding, !self.isShown else { return }
            panel.orderOut(nil)
        }
    }

    private static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: CGRect(origin: .zero, size: style.size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Above the Dock, for the light on a Dock icon.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        let hosting = NSHostingView(rootView: ForkTrackpadPreviewView(model: model, style: style))
        hosting.setAccessibilityElement(false)
        switch style {
        case .hud:
            panel.hasShadow = true
            // The glass of Window Layout's directional ring: follows light and
            // dark mode and Reduce Transparency on its own.
            let glass = NSVisualEffectView(frame: CGRect(origin: .zero, size: style.size))
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = Self.cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.layer?.borderWidth = 0.5
            glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            hosting.frame = glass.bounds
            hosting.autoresizingMask = [.width, .height]
            glass.addSubview(hosting)
            panel.contentView = glass
        case .pointerLight:
            // No background: the light alone, its shadow drawn by the view.
            panel.hasShadow = false
            panel.contentView = hosting
        }
        return panel
    }
}

// MARK: - Views

private final class ForkTrackpadPreviewModel: ObservableObject {
    @Published var content: ForkTrackpadPreviewContent = .unrecognized
    @Published var appIcon: NSImage?
    @Published var screenAspect: CGFloat = 16 / 10
}

private struct ForkTrackpadPreviewView: View {
    @ObservedObject var model: ForkTrackpadPreviewModel
    let style: ForkTrackpadPreviewWindow.Style

    var body: some View {
        ZStack {
            switch model.content {
            case .zone(let zone):
                // One view for every zone, so going from a half to a quarter
                // slides the zone rather than swapping pictures.
                ForkTrackpadMiniScreen(zone: zone, aspect: model.screenAspect)
                    .transition(.opacity)
            case .light(let light):
                ForkTrackpadLightView(light: light, diameter: diameter)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .id(light)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .quitApp, .emptyTrash:
                ForkTrackpadQuitLightView(icon: model.appIcon, diameter: diameter,
                                            iconSize: style == .hud ? 30 : 16)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .showApp:
                // The icon a little above its Dock place, the way its windows
                // will rise.
                if let icon = model.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: diameter, height: diameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .unrecognized:
                Image(systemName: "questionmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                   ? .easeInOut(duration: 0.1)
                   : .spring(response: 0.22, dampingFraction: 0.82),
                   value: model.content)
        .frame(width: style.size.width, height: style.size.height)
    }

    private var diameter: CGFloat {
        style == .hud ? 72 : ForkTrackpadPreviewWindow.lightDiameter
    }
}

/// A small screen at the real screen's proportions, the target zone filled
/// like Window Layout's drag-to-edge preview: accent tint, accent outline.
private struct ForkTrackpadMiniScreen: View {
    let zone: CGRect
    let aspect: CGFloat

    private static let maxSize = CGSize(width: 112, height: 72)
    private static let inset: CGFloat = 3

    var body: some View {
        let size = fitted
        let accent = Color(nsColor: .controlAccentColor)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.75)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                .frame(width: max(zone.width * size.width - 2 * Self.inset, 1),
                       height: max(zone.height * size.height - 2 * Self.inset, 1))
                .offset(x: zone.minX * size.width + Self.inset,
                        y: zone.minY * size.height + Self.inset)
        }
        .frame(width: size.width, height: size.height)
    }

    private var fitted: CGSize {
        let width = min(Self.maxSize.width, Self.maxSize.height * aspect)
        return CGSize(width: width, height: width / max(aspect, 0.1))
    }
}

/// The red light, with the app's icon small in its bottom right corner. The
/// icon's offset follows the diameter so the proportions hold at any size.
private struct ForkTrackpadQuitLightView: View {
    let icon: NSImage?
    let diameter: CGFloat
    let iconSize: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ForkTrackpadLightView(light: .close, diameter: diameter)
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .offset(x: diameter * 0.17, y: diameter * 0.14)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A macOS window button, redrawn as vectors: a disc in a light gradient, a
/// rim one shade darker, and its symbol always shown (a preview, not a
/// button). The real buttons are 14 pt and blur once enlarged.
private struct ForkTrackpadLightView: View {
    let light: ForkTrackpadTrafficLight
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [light.top, light.fill], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(light.rim, lineWidth: diameter * 0.035)
            glyph
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private var glyph: some View {
        let d = diameter
        let ink = light.glyph.opacity(0.85)
        let stroke = StrokeStyle(lineWidth: 0.095 * d, lineCap: .round)
        switch light {
        case .close:
            Path { p in
                p.move(to: CGPoint(x: 0.30 * d, y: 0.30 * d))
                p.addLine(to: CGPoint(x: 0.70 * d, y: 0.70 * d))
                p.move(to: CGPoint(x: 0.70 * d, y: 0.30 * d))
                p.addLine(to: CGPoint(x: 0.30 * d, y: 0.70 * d))
            }
            .stroke(ink, style: stroke)
        case .minimize:
            Path { p in
                p.move(to: CGPoint(x: 0.25 * d, y: 0.5 * d))
                p.addLine(to: CGPoint(x: 0.75 * d, y: 0.5 * d))
            }
            .stroke(ink, style: stroke)
        case .fullScreen:
            // Two opposite triangles, pointing at the top left and bottom
            // right corners on either side of the diagonal.
            Path { p in
                p.move(to: CGPoint(x: 0.28 * d, y: 0.28 * d))
                p.addLine(to: CGPoint(x: 0.61 * d, y: 0.28 * d))
                p.addLine(to: CGPoint(x: 0.28 * d, y: 0.61 * d))
                p.closeSubpath()
                p.move(to: CGPoint(x: 0.72 * d, y: 0.72 * d))
                p.addLine(to: CGPoint(x: 0.39 * d, y: 0.72 * d))
                p.addLine(to: CGPoint(x: 0.72 * d, y: 0.39 * d))
                p.closeSubpath()
            }
            .fill(ink)
        }
    }
}

private extension ForkTrackpadTrafficLight {
    var fill: Color {
        switch self {
        case .close: return Color(red: 1.000, green: 0.373, blue: 0.341)      // #FF5F57
        case .minimize: return Color(red: 0.996, green: 0.737, blue: 0.180)   // #FEBC2E
        case .fullScreen: return Color(red: 0.157, green: 0.784, blue: 0.251) // #28C840
        }
    }

    /// The top of the gradient, a light white veil over `fill`, fixed as
    /// constants: `Color.mix(with:by:)` needs macOS 15.
    var top: Color {
        switch self {
        case .close: return Color(.sRGB, red: 1.0138, green: 0.4762, blue: 0.4351)
        case .minimize: return Color(.sRGB, red: 0.9987, green: 0.7766, blue: 0.3568)   // #FFC65B
        case .fullScreen: return Color(.sRGB, red: 0.3459, green: 0.8181, blue: 0.3793) // #58D161
        }
    }

    var rim: Color {
        switch self {
        case .close: return Color(red: 0.878, green: 0.267, blue: 0.243)      // #E0443E
        case .minimize: return Color(red: 0.871, green: 0.631, blue: 0.137)   // #DEA123
        case .fullScreen: return Color(red: 0.102, green: 0.671, blue: 0.161) // #1AAB29
        }
    }

    var glyph: Color {
        switch self {
        case .close: return Color(red: 0.302, green: 0.000, blue: 0.000)      // #4D0000
        case .minimize: return Color(red: 0.600, green: 0.341, blue: 0.000)   // #995700
        case .fullScreen: return Color(red: 0.000, green: 0.396, blue: 0.000) // #006500
        }
    }
}
