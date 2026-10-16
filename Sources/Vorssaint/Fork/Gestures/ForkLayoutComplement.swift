// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import CoreGraphics

/// The four screen halves, the placements that have a facing half.
enum ForkLayoutHalf: Hashable, CaseIterable {
    case left, right, top, bottom

    /// `nil` for everything that is not a half.
    init?(_ action: WindowLayoutAction) {
        switch action {
        case .leftHalf: self = .left
        case .rightHalf: self = .right
        case .topHalf: self = .top
        case .bottomHalf: self = .bottom
        default: return nil
        }
    }

    var complement: ForkLayoutHalf {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    var action: WindowLayoutAction {
        switch self {
        case .left: return .leftHalf
        case .right: return .rightHalf
        case .top: return .topHalf
        case .bottom: return .bottomHalf
        }
    }
}

/// Complementary halves: a half is fitted to the real inner edge of the
/// window already holding the facing half, rather than to the theoretical
/// 50 %, so the two meet exactly one window gap apart.
///
/// The case it exists for: TextEdit on the right half has a minimum width
/// larger than the half, so it stays anchored on the right and spills
/// leftwards. A window then sent to the left half at 50 % slid under it.
/// The other way round, an app narrower than its half left a hole. The rule
/// is symmetric.
///
/// Pure, in AppKit coordinates (y grows upwards, so the top half sits at
/// `maxY`). `layoutFrame` is the visible frame after the screen gap, the
/// frame the halves tile.
enum ForkLayoutComplement {
    /// Under this share of the layout frame the new window would be too
    /// narrow (or too short) to be useful: the theoretical half wins.
    static let minimumShare: CGFloat = 0.25

    /// How far a neighbour may sit from its outer edge and still hold its
    /// half: apps round to whole points.
    static let edgeTolerance: CGFloat = 2

    /// Under this, two edges already meet.
    static let contactTolerance: CGFloat = 1

    /// Where `half` goes when `neighbour` (its real current frame) holds the
    /// facing half; `theoretical` when there is no valid neighbour.
    static func rect(for half: ForkLayoutHalf,
                     theoretical: CGRect,
                     layoutFrame: CGRect,
                     windowGap: CGFloat,
                     neighbour: CGRect?) -> CGRect {
        guard let neighbour,
              isAnchored(neighbour, in: half.complement, of: layoutFrame) else { return theoretical }
        let facing = innerEdge(of: neighbour, in: half.complement)
        let result: CGRect
        switch half {
        case .left:
            result = CGRect(x: layoutFrame.minX, y: theoretical.minY,
                            width: facing - windowGap - layoutFrame.minX, height: theoretical.height)
        case .right:
            result = CGRect(x: facing + windowGap, y: theoretical.minY,
                            width: layoutFrame.maxX - facing - windowGap, height: theoretical.height)
        case .top:
            result = CGRect(x: theoretical.minX, y: facing + windowGap,
                            width: theoretical.width, height: layoutFrame.maxY - facing - windowGap)
        case .bottom:
            result = CGRect(x: theoretical.minX, y: layoutFrame.minY,
                            width: theoretical.width, height: facing - windowGap - layoutFrame.minY)
        }
        let share: CGFloat
        switch half {
        case .left, .right: share = result.width / max(1, layoutFrame.width)
        case .top, .bottom: share = result.height / max(1, layoutFrame.height)
        }
        return share >= minimumShare ? result : theoretical
    }

    /// Where to move the window holding `half` so it meets `neighbour`,
    /// which has just settled in the facing half: `nil` when they already
    /// meet, or when meeting would drop it back to the theoretical half
    /// (neighbour gone from its edge, or under the minimum share).
    ///
    /// A half is fitted to its neighbour when it is placed. When it is the
    /// neighbour, placed afterwards, that ends up off its half (a minimum
    /// size, a size grid), the first one no longer meets it.
    static func refitRect(for half: ForkLayoutHalf,
                          current: CGRect,
                          theoretical: CGRect,
                          layoutFrame: CGRect,
                          windowGap: CGFloat,
                          neighbour: CGRect) -> CGRect? {
        guard !meets(current, in: half, neighbour: neighbour, windowGap: windowGap) else { return nil }
        let target = rect(for: half, theoretical: theoretical, layoutFrame: layoutFrame,
                          windowGap: windowGap, neighbour: neighbour)
        return meets(target, in: half, neighbour: neighbour, windowGap: windowGap) ? target : nil
    }

    /// Whether `frame`, in `half`, sits one window gap from `neighbour`.
    static func meets(_ frame: CGRect, in half: ForkLayoutHalf,
                      neighbour: CGRect, windowGap: CGFloat) -> Bool {
        let distance: CGFloat
        switch half {
        case .left, .bottom:
            distance = innerEdge(of: neighbour, in: half.complement) - innerEdge(of: frame, in: half)
        case .right, .top:
            distance = innerEdge(of: frame, in: half) - innerEdge(of: neighbour, in: half.complement)
        }
        return abs(distance - windowGap) <= contactTolerance
    }

    /// The edge of a window that faces the other half.
    static func innerEdge(of frame: CGRect, in half: ForkLayoutHalf) -> CGFloat {
        switch half {
        case .left: return frame.maxX
        case .right: return frame.minX
        case .top: return frame.minY
        case .bottom: return frame.maxY
        }
    }

    /// Whether the window still rests on the outer edge of its half (the
    /// right edge of the layout frame for a right half). Otherwise it no
    /// longer holds that half, and its inner edge means nothing.
    static func isAnchored(_ frame: CGRect, in half: ForkLayoutHalf, of layoutFrame: CGRect,
                           tolerance: CGFloat = edgeTolerance) -> Bool {
        switch half {
        case .left: return abs(frame.minX - layoutFrame.minX) <= tolerance
        case .right: return abs(frame.maxX - layoutFrame.maxX) <= tolerance
        case .top: return abs(frame.maxY - layoutFrame.maxY) <= tolerance
        case .bottom: return abs(frame.minY - layoutFrame.minY) <= tolerance
        }
    }
}

/// Which window was last placed in which half of which layout frame, with
/// the frame it was read back at.
///
/// A remembered window only counts while its current frame is still the
/// recorded one (`isStillPlaced`): moved or resized by hand, or closed, it
/// drops out without any watching.
/// Keyed by the layout frame itself, so a display change (another
/// resolution, the Dock moved, a gap changed) retires every entry on its
/// own. In memory only, for this app session; a window holds one half at a
/// time.
struct ForkLayoutHalfMemory<Window: Equatable> {
    struct Entry {
        var window: Window
        var half: ForkLayoutHalf
        var layoutFrame: CGRect
        /// AppKit coordinates, read back after the placement.
        var frame: CGRect
    }

    static var moveTolerance: CGFloat { 2 }

    /// Two displays, four halves each, is already a lot; the oldest goes
    /// first past this.
    static var limit: Int { 16 }

    private(set) var entries: [Entry] = []

    mutating func record(_ window: Window, in half: ForkLayoutHalf,
                         layoutFrame: CGRect, frame: CGRect) {
        entries.removeAll { $0.window == window
            || ($0.half == half && $0.layoutFrame == layoutFrame) }
        entries.append(Entry(window: window, half: half, layoutFrame: layoutFrame, frame: frame))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Updates the frame read back for a window already recorded; nothing
    /// otherwise.
    mutating func update(_ window: Window, frame: CGRect) {
        for index in entries.indices where entries[index].window == window {
            entries[index].frame = frame
        }
    }

    /// The window holding `half` of `layoutFrame`.
    func occupant(of half: ForkLayoutHalf, layoutFrame: CGRect) -> Entry? {
        entries.last { $0.half == half && $0.layoutFrame == layoutFrame }
    }

    /// Each layout frame's left and right, then top and bottom, windows,
    /// wherever both halves are held: the pairs that can be linked. The
    /// first of each pair is the left (or top) one.
    func complementaryPairs() -> [(first: Entry, second: Entry)] {
        var frames: [CGRect] = []
        for entry in entries where !frames.contains(entry.layoutFrame) { frames.append(entry.layoutFrame) }
        return frames.flatMap { frame in
            [(ForkLayoutHalf.left, ForkLayoutHalf.right), (.top, .bottom)].compactMap { halves in
                guard let first = occupant(of: halves.0, layoutFrame: frame),
                      let second = occupant(of: halves.1, layoutFrame: frame) else { return nil }
                return (first, second)
            }
        }
    }

    func entry(for window: Window) -> Entry? {
        entries.last { $0.window == window }
    }

    mutating func forget(_ window: Window) {
        entries.removeAll { $0.window == window }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Whether a remembered window still sits where it was recorded;
    /// `actual` is `nil` when the frame cannot be read (window closed).
    /// Minimized and full-screen windows are the caller's to rule out.
    static func isStillPlaced(recorded: CGRect, actual: CGRect?) -> Bool {
        guard let actual else { return false }
        return abs(actual.minX - recorded.minX) <= moveTolerance
            && abs(actual.minY - recorded.minY) <= moveTolerance
            && abs(actual.width - recorded.width) <= moveTolerance
            && abs(actual.height - recorded.height) <= moveTolerance
    }
}

/// Where a repeated left, right or top half gesture goes: the official size
/// cycle, picked up only while the window still sits at the frame the
/// previous gesture left it at. Lets a swipe repeated right after (left,
/// lift, left again) reach two thirds then a third exactly as repeating its
/// keyboard shortcut would, and keeps a top half repeated the official
/// shortcut's own rule: straight to maximize.
enum ForkWindowSizeCycle {
    static func effectiveAction(for action: WindowLayoutAction,
                                current: WindowLayoutFrame,
                                previous: (action: WindowLayoutAction, frame: WindowLayoutFrame)?,
                                tolerance: CGFloat,
                                cyclesThirds: Bool) -> WindowLayoutAction {
        guard action == .leftHalf || action == .rightHalf || action == .topHalf else { return action }
        let previousAction = previous.flatMap { entry in
            current.isClose(to: entry.frame, tolerance: tolerance) ? entry.action : nil
        }
        return WindowLayoutGeometry.effectiveAction(for: action, current: .zero, visibleFrame: .zero,
                                                     previousAction: previousAction,
                                                     sideRepeatCyclesThirds: cyclesThirds)
    }
}

/// Where chaining a Dock icon's windows goes next: the window after (or
/// before) the one last chained to, in a fixed order, cycling past the last
/// back to the first.
///
/// The order must hold steady from one gesture to the next, so it cannot be
/// "whichever window macOS currently shows in front": raising one to the
/// front is itself what every gesture does, which would move the goalposts
/// on the very next swipe. The caller instead orders windows by something
/// that does not change underneath it (their window ID) and remembers which
/// one it chained to last.
enum ForkTrackpadWindowChain {
    static func nextIndex(current: Int?, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        let currentIndex = current.map { ($0 % count + count) % count } ?? 0
        return forward ? (currentIndex + 1) % count : (currentIndex - 1 + count) % count
    }
}
