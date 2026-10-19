// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine
import SwiftUI

/// Meetings in Vorssaint's island. The only file that talks to
/// `NotchService` for them: it is the official API that moves the most, so
/// each change lands here and nowhere else.
///
/// Two ways in. A capture notice at each transition ("Recording started"),
/// which the island keeps 12 s, without a button, and refuses while a
/// louder notice (the dictation's microphone, the volume) is up. And a card
/// on the island's Captures page, with buttons, for what asks for a gesture
/// ("Meeting saved · Show in Finder"). Anything the island turns away goes to
/// the bubble; the pill carries the recording's real state either way.
enum ForkMeetingIsland {
    /// Whether the closed island is free for a meeting now. Open, dragged
    /// into, holding the official capture controls or a dictation, it is
    /// doing something else. The capture controls matter most:
    /// `presentCapture` says yes while they are up, then unfolds them instead
    /// of showing the card.
    static var isAvailable: Bool {
        let island = NotchService.shared
        return NotchSupport.routes(.capture) && island.showsSystemFeedback
            && !island.expanded && !island.dragPlaceholder && island.captureControls == nil
            && ForkDictationPresenter.shared.presentation == .hidden
    }

    /// The official "Show in screenshots and videos" setting, which the
    /// Command Bar and the island follow too.
    static var showsInCaptures: Bool { NotchSupport.showsInCaptures() }

    /// False when the island refused it: the caller shows it elsewhere.
    @discardableResult
    static func show(_ notice: ForkMeetingNotice, detail: String?, text: ForkMeetingStrings) -> Bool {
        guard isAvailable else { return false }
        return NotchService.shared.show(notchNotice(for: notice, detail: detail, text: text))
    }

    static func notchNotice(for notice: ForkMeetingNotice, detail: String?, text: ForkMeetingStrings) -> NotchNotice {
        NotchNotice(event: .capture, title: notice.title(text), detail: detail ?? notice.detail(text) ?? "",
                    symbol: symbol(for: notice))
    }

    static func symbol(for notice: ForkMeetingNotice) -> String {
        switch notice {
        case .started: return "record.circle"
        case .resumed: return "play.circle"
        case .saved: return "checkmark.circle"
        case .recovered: return "arrow.counterclockwise.circle"
        case .microphone: return "mic"
        case .microphoneSilent: return "mic.slash"
        case .diskLow: return "externaldrive.badge.exclamationmark"
        case .displayChanged: return "display"
        case .sourceGone: return "rectangle.on.rectangle.slash"
        case .failure: return "exclamationmark.triangle.fill"
        case .soundLost: return "speaker.slash"
        case .neverOffered: return "bell.slash"
        case .alwaysChosen: return "bolt.circle"
        }
    }

    /// Opens the island on a card with buttons. It never takes the keyboard:
    /// the call goes on typing where it was. `closeOnCollapse` so that every
    /// way the card leaves (a click on the island, the capture controls, a
    /// lock) calls `close`, instead of the card staying attached unseen.
    /// `fallback` runs when the island goes away under it (turned off, its
    /// display unplugged). A card with a ⋯ menu puts it in the island's top
    /// row, right of the camera, where the page's own controls go.
    @discardableResult
    static func present(_ card: ForkMeetingCard, id: UUID, height: CGFloat, fallback: @escaping () -> Void,
                        close: @escaping () -> Void, hover: @escaping (Bool) -> Void) -> Bool {
        guard isAvailable else { return false }
        let actions = card.menu.isEmpty ? nil : AnyView(ForkMeetingCardMenu(card: card))
        return NotchService.shared.presentCapture(
            id: id, content: AnyView(ForkMeetingCardView(card: card)), actions: actions, height: height,
            takeFocus: false, closeOnCollapse: true, fallback: fallback, close: close, hover: hover)
    }

    /// Whether the island still shows the card `id`, as it was presented.
    static func isShowing(id: UUID) -> Bool {
        NotchService.shared.isCaptureVisible(id: id)
    }

    /// The card's height in the island, measured at the island's width:
    /// a remedy of three lines is never cut, nor one of one line given room
    /// for two. Main thread.
    static func height(of card: ForkMeetingCard, minimum: CGFloat) -> CGFloat {
        let width = NotchService.shared.expandedGeometry.contentWidth
        guard width > 0 else { return minimum }
        let host = NSHostingView(rootView: ForkMeetingCardView(card: card)
            .environment(\.notchPresentation, true)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        let measured = host.fittingSize.height
        return measured.isFinite ? max(minimum, measured.rounded(.up)) : minimum
    }

    /// Takes the card away; never calls its `close`.
    static func remove(id: UUID) {
        NotchService.shared.removeCapture(id: id)
    }

    /// The island's surface at rest on that display, in screen points, when
    /// it runs there: the pill sits right of it.
    static func restingFrame(on screen: NSScreen) -> CGRect? {
        let island = NotchService.shared
        let geometry = island.geometry
        guard island.presentationWindow != nil, geometry.screen == screen.frame else { return nil }
        return geometry.frame(for: geometry.restingSize(showsContent: false))
    }

    /// Calls `change` on the main thread after the island moved or changed
    /// size at rest (another display, another width), until the returned
    /// token is released.
    static func observeGeometry(_ change: @escaping () -> Void) -> AnyCancellable {
        NotchService.shared.$geometry
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in change() }
    }
}
