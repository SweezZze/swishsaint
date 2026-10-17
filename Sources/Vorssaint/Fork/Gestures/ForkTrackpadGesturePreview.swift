// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat
// Copyright (C) 2026 Louis (SweezZze)

import AppKit
import SwiftUI

/// What the lift will do, shown while a trackpad window gesture is under way.
/// Where depends on what it says (`ForkTrackpadPreviewAnchor`): window buttons
/// in place of the pointer, at the size chosen in Settings; anything on the
/// Dock centered on the icon touched, the pointer left; zones at the center
/// of the screen or on the pointer, as chosen in Settings. Once the lift
/// acts, the preview leaves the way its action goes.
///
/// One panel and one view for every preview, so the gesture never jumps from
/// one window to another: a glass plate shaped like the screen carries the
/// target zone (halves, quarters, fill, center, or a question mark for a
/// sequence without action), and morphs into a traffic light (close,
/// minimize, full screen, quit) when the gesture comes to mean one. Every
/// change is a spring, the zone sliding from a half to a quarter.
///
/// On the pointer: the pointer does not move during a two-finger gesture, so
/// the preview is centered on it, moved in just enough to stay whole near a
/// screen edge, and the pointer itself hides meanwhile. At the center: a
/// larger preview in the middle of the target's screen, the pointer left
/// alone. A gesture that goes from one place to the other pops in again at
/// the new one. The panel never takes focus or the mouse.
final class ForkTrackpadGesturePreview {
    static let shared = ForkTrackpadGesturePreview()

    /// The panel's side at scale 1: the screen badge or the light, plus room
    /// for their shadow.
    static let panelSide: CGFloat = 64
    /// How much larger the preview is at the center of the screen, where it
    /// sits away from the eye, than on the pointer.
    static let centeredScale: CGFloat = 2.5
    static let disappearDelay: TimeInterval = 0.16
    /// Longer than a cancel's fade: the gesture's own exit (the yellow light
    /// dropping to the Dock, the green one opening out) has to be seen.
    static let commitDelay: TimeInterval = 0.3
    /// How long a preview shown only at the commit, a double tap's, stays.
    static let flashDuration: TimeInterval = 0.2

    private let model = ForkTrackpadPreviewModel()
    private var panel: NSPanel?
    /// Bumped on every appearance: a late fade-out must not close the panel of
    /// the next gesture.
    private var generation = 0
    private(set) var isShown = false
    private var shownAnchor: ForkTrackpadPreviewAnchor?
    private var pointerHidden = false

    private init() {}

    /// - Parameters:
    ///   - anchor: where the preview goes; a change during the gesture moves
    ///     it there, a new pop at the new place.
    ///   - targetFrame: the target window, in Accessibility coordinates: the
    ///     mini screen draws its screen. `nil` for a Dock icon, which uses the
    ///     pointer's screen.
    ///   - pointer: where the gesture began, in Accessibility coordinates.
    ///   - appIcon: for quitting, the icon of the app about to quit; for
    ///     emptying the Trash, the Trash's; for calling windows back, their
    ///     app's.
    func show(_ content: ForkTrackpadPreviewContent,
              anchor: ForkTrackpadPreviewAnchor,
              targetFrame: CGRect?,
              pointer: CGPoint,
              appIcon: NSImage?) {
        if isShown, anchor == shownAnchor {
            // An update: the view springs from one content to the next.
            withAnimation(Self.change) {
                model.appIcon = appIcon
                model.content = content
            }
            return
        }

        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.maxY else { return }
        let frames = screens.map { Self.axRect(fromAppKit: $0.frame, primaryHeight: primaryHeight) }
        guard let index = ForkTrackpadPreviewPlacement.screenIndex(targetFrame: targetFrame,
                                                                    pointer: pointer,
                                                                    screens: frames)
        else { return }
        let pointerIndex = ForkTrackpadPreviewPlacement.screenIndex(targetFrame: nil,
                                                                      pointer: pointer,
                                                                      screens: frames) ?? index
        let scale = anchor.scale(chosen: CGFloat(ForkTrackpadTuning.previewSize.current),
                                 centeredScale: Self.centeredScale)
        let side = Self.panelSide * scale
        let size = CGSize(width: side, height: side)
        let frameAX: CGRect
        switch anchor {
        case .pointer:
            frameAX = ForkTrackpadPreviewPlacement.frame(size: size, centeredOn: pointer,
                                                         within: frames[pointerIndex])
        case .screenCenter:
            let visible = Self.axRect(fromAppKit: screens[index].visibleFrame, primaryHeight: primaryHeight)
            frameAX = ForkTrackpadPreviewPlacement.frame(size: size, centeredIn: visible)
        case .dockItem(let item):
            frameAX = ForkTrackpadPreviewPlacement.frame(size: size, centeredOnItem: item)
        }
        // The same flip both ways: Accessibility's origin is the top left of
        // the main screen, AppKit's its bottom left.
        let frame = Self.axRect(fromAppKit: frameAX, primaryHeight: primaryHeight)

        isShown = true
        shownAnchor = anchor
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Set without animation, then grown in: no stale content flashes.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.scale = scale
            model.screenAspect = frames[index].width / max(frames[index].height, 1)
            model.appIcon = appIcon
            model.content = content
            model.onDock = { if case .dockItem = anchor { return true } else { return false } }()
            model.exit = .cancel
            model.visible = false
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        withAnimation(Self.appear) { model.visible = true }
        setPointerHidden(anchor.hidesPointer)
    }

    /// - Parameter committed: the lift acts; the preview then leaves the way
    ///   its action goes, a cancel only fades.
    func hide(committed: Bool = false) {
        setPointerHidden(false)
        guard isShown, let panel else { return }
        isShown = false
        shownAnchor = nil
        let hiding = generation
        let exits = committed && !Self.reduceMotion
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { model.exit = committed ? .commit : .cancel }
        withAnimation(exits ? .easeOut(duration: Self.commitDelay * 0.85)
                            : .easeIn(duration: Self.disappearDelay * 0.8)) { model.visible = false }
        let delay = exits ? Self.commitDelay : Self.disappearDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
            // A new gesture may have brought the panel back during the fade.
            guard let self, let panel, self.generation == hiding, !self.isShown else { return }
            panel.orderOut(nil)
        }
    }

    /// For an action with no preview before it, a double tap's: shown, then
    /// gone the way it acts, so every gesture answers.
    func flash(_ content: ForkTrackpadPreviewContent,
               anchor: ForkTrackpadPreviewAnchor,
               targetFrame: CGRect?,
               pointer: CGPoint,
               appIcon: NSImage?) {
        show(content, anchor: anchor, targetFrame: targetFrame, pointer: pointer, appIcon: appIcon)
        let flashing = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration) { [weak self] in
            guard let self, self.generation == flashing, self.isShown else { return }
            self.hide(committed: true)
        }
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var change: Animation {
        reduceMotion ? .easeInOut(duration: 0.1) : .spring(response: 0.26, dampingFraction: 0.8)
    }

    private static var appear: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.22, dampingFraction: 0.72)
    }

    /// Hidden once per gesture and shown back once, so the system's hide count
    /// stays balanced. A background app may only touch the cursor with the
    /// window server's leave; if it ever refuses, the pointer simply stays.
    private func setPointerHidden(_ hidden: Bool) {
        guard hidden != pointerHidden else { return }
        pointerHidden = hidden
        if hidden {
            ForkBackgroundCursor.acquire()
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
            ForkBackgroundCursor.release()
        }
    }

    private static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func makePanel() -> NSPanel {
        let side = Self.panelSide
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: side, height: side),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The view draws its own shadow, which follows the plate as it morphs.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Above the Dock, for the light on a Dock icon.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: ForkTrackpadPreviewView(model: model))
        hosting.setAccessibilityElement(false)
        panel.contentView = hosting
        return panel
    }
}

// MARK: - Views

private final class ForkTrackpadPreviewModel: ObservableObject {
    @Published var content: ForkTrackpadPreviewContent = .unrecognized
    @Published var appIcon: NSImage?
    @Published var screenAspect: CGFloat = 16 / 10
    /// The preview size chosen in Settings.
    @Published var scale: CGFloat = 1
    @Published var visible = false
    /// On a Dock icon: the icon coming back hops up from its place.
    @Published var onDock = false
    /// How the preview leaves once `visible` turns off.
    @Published var exit: ForkTrackpadPreviewExit = .cancel
}

enum ForkTrackpadPreviewExit {
    /// Nothing happens: the preview shrinks back and fades.
    case cancel
    /// The action fires: the preview leaves the way it goes.
    case commit
}

private struct ForkTrackpadPreviewView: View {
    @ObservedObject var model: ForkTrackpadPreviewModel

    static let cornerRadius: CGFloat = 6
    static let lightDiameter: CGFloat = 22

    var body: some View {
        let scale = model.scale
        let plate = plateSize
        ZStack {
            // The glass plate: the screen for a zone, shrunk to the light's
            // disc and faded under it for a button, so one becomes the other.
            RoundedRectangle(cornerRadius: plateRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: plateRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.45)))
                .frame(width: plate.width, height: plate.height)
                .shadow(color: .black.opacity(0.28), radius: 4 * scale, y: 1.5 * scale)
                .opacity(showsPlate ? 1 : 0)

            switch model.content {
            case .zone(let zone):
                // One view for every zone, so going from a half to a quarter
                // slides the zone rather than swapping pictures.
                ForkTrackpadMiniScreen(zone: zone, aspect: model.screenAspect, scale: scale)
                    .frame(width: plate.width, height: plate.height)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .light(let light):
                ForkTrackpadLightView(light: light, diameter: diameter)
                    .shadow(color: .black.opacity(0.3), radius: 2 * scale, y: scale)
                    .id(light)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .quitApp, .emptyTrash:
                ForkTrackpadQuitLightView(icon: model.appIcon, diameter: diameter, iconSize: 16 * scale)
                    .shadow(color: .black.opacity(0.3), radius: 2 * scale, y: scale)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .showApp:
                // The icon a little above its Dock place, the way its windows
                // will rise; on the icon itself, a hop like the Dock's bounce.
                if let icon = model.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: diameter, height: diameter)
                        .shadow(color: .black.opacity(0.3), radius: 2 * scale, y: scale)
                        .offset(y: model.onDock && model.visible ? -diameter * 0.3 : 0)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .unrecognized:
                Image(systemName: "questionmark")
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(model.visible ? 1 : exitScale)
        .offset(y: model.visible ? 0 : exitOffset)
        .opacity(model.visible ? 1 : 0)
    }

    private var diameter: CGFloat { Self.lightDiameter * model.scale }

    /// A cancel shrinks back. An action leaves its own way: closing and
    /// quitting puff out, full screen opens wide, the zone settles in place.
    private var exitScale: CGFloat {
        guard model.exit == .commit else { return 0.7 }
        switch model.content {
        case .light(.minimize): return 0.3
        case .light(.close), .quitApp, .emptyTrash: return 1.3
        case .light(.fullScreen): return 1.9
        case .showApp: return 1.05
        case .zone, .symbol: return 1.08
        case .unrecognized: return 0.7
        }
    }

    /// Minimizing drops toward the Dock, windows coming back rise from it.
    private var exitOffset: CGFloat {
        guard model.exit == .commit else { return 0 }
        switch model.content {
        case .light(.minimize): return diameter * 0.9
        case .showApp: return -diameter * 0.6
        default: return 0
        }
    }

    private var showsPlate: Bool {
        switch model.content {
        case .zone, .symbol, .unrecognized: return true
        case .light, .quitApp, .emptyTrash, .showApp: return false
        }
    }

    private var plateSize: CGSize {
        guard showsPlate else { return CGSize(width: diameter, height: diameter) }
        let size = ForkTrackpadMiniScreen.fitted(aspect: model.screenAspect)
        return CGSize(width: size.width * model.scale, height: size.height * model.scale)
    }

    private var plateRadius: CGFloat {
        showsPlate ? Self.cornerRadius * model.scale : diameter / 2
    }
}

/// The badge's drawing: the glass behind it is the screen, so only its rim
/// and the target zone are drawn, the zone in the accent color like Window
/// Layout's drag-to-edge preview.
private struct ForkTrackpadMiniScreen: View {
    let zone: CGRect
    let aspect: CGFloat
    var scale: CGFloat = 1

    static let maxSize = CGSize(width: 44, height: 30)
    private static let inset: CGFloat = 2.5

    /// The badge's size: the real screen's proportions within `maxSize`.
    static func fitted(aspect: CGFloat) -> CGSize {
        let width = min(maxSize.width, maxSize.height * aspect)
        return CGSize(width: width, height: width / max(aspect, 0.1))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let accent = Color(nsColor: .controlAccentColor)
            let inset = Self.inset * scale
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: ForkTrackpadPreviewView.cornerRadius * scale, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: max(1, scale))
                RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.8)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: max(zone.width * size.width - 2 * inset, 1),
                           height: max(zone.height * size.height - 2 * inset, 1))
                    .offset(x: zone.minX * size.width + inset,
                            y: zone.minY * size.height + inset)
            }
        }
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
