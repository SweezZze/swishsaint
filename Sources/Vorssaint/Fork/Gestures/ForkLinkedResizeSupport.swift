// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import CoreGraphics
import Foundation

/// Which way the shared edge of two linked windows runs.
enum ForkLinkAxis: Hashable {
    /// Left | right: the edge is vertical and moves along x.
    case vertical
    /// Top / bottom: the edge is horizontal and moves along y.
    case horizontal
}

/// The shared edge of two linked windows. Coordinate-agnostic: `first` is
/// the window lower along the axis (left, or top in Accessibility
/// coordinates where y grows downwards).
struct ForkLinkedBorder: Equatable {
    var axis: ForkLinkAxis
    /// Where the first window ends along the axis.
    var firstEnd: CGFloat
    /// The distance to the second window: the window gap, give or take the
    /// apps' rounding.
    var gap: CGFloat
    /// The stretch of the other axis where the two windows face each other.
    var spanStart: CGFloat
    var spanEnd: CGFloat

    /// The band that can be grabbed: the gap plus
    /// `ForkLinkedPair.handleOverlap` over each window, along the stretch
    /// where they face each other.
    var handleRect: CGRect {
        let overlap = ForkLinkedPair.handleOverlap
        let start = firstEnd - overlap
        let thickness = max(0, gap) + 2 * overlap
        switch axis {
        case .vertical:
            return CGRect(x: start, y: spanStart, width: thickness, height: spanEnd - spanStart)
        case .horizontal:
            return CGRect(x: spanStart, y: start, width: spanEnd - spanStart, height: thickness)
        }
    }
}

/// Two linked windows: the two complementary halves of a layout frame, one
/// window gap apart. Their shared edge can be grabbed to resize both at once.
enum ForkLinkedPair {
    /// How far off the window gap two edges may sit and still meet: apps
    /// round to whole points.
    static let contactTolerance: CGFloat = 2

    /// How far the handle reaches over each window: 8 pt in all without a
    /// gap, a little more than the native resize edge so it covers it.
    static let handleOverlap: CGFloat = 4

    /// Under this the windows barely face each other: no shared edge.
    static let minimumSpan: CGFloat = 40

    /// How far a window may sit from the outer edge of its half and still
    /// hold it. Loose on purpose: Terminal rounds its height to a text line
    /// and leaves a few points under a bottom half, and a pair that dissolved
    /// on that would stop answering with nothing visibly moved.
    static let anchorTolerance: CGFloat = 24

    /// - Returns: `nil` unless the windows meet one `windowGap` apart and
    ///   face each other over at least `minimumSpan`.
    static func border(between first: CGRect, and second: CGRect,
                       axis: ForkLinkAxis, windowGap: CGFloat) -> ForkLinkedBorder? {
        let gap = second.minAlong(axis) - first.maxAlong(axis)
        guard abs(gap - windowGap) <= contactTolerance else { return nil }
        let spanStart = max(first.minAcross(axis), second.minAcross(axis))
        let spanEnd = min(first.maxAcross(axis), second.maxAcross(axis))
        guard spanEnd - spanStart >= minimumSpan else { return nil }
        return ForkLinkedBorder(axis: axis, firstEnd: first.maxAlong(axis), gap: gap,
                                  spanStart: spanStart, spanEnd: spanEnd)
    }
}

/// One drag of a shared edge: where the edge goes, and the two frames that
/// follow from it.
///
/// Each window keeps its outer edge and the gap between them stays what it
/// was; only the edge moves. Both windows therefore stay within their
/// original stretch, so within the screen, without knowing it.
///
/// An app does not always take the size it is asked for: a minimum size
/// (TextEdit) or a size rounded to its grid (Terminal, to the character).
/// macOS exposes neither, so every write is read back and the edge follows
/// the size really taken (`settledBorder`).
struct ForkLinkedResize {
    enum Side: Equatable { case first, second }

    /// Never shrink a window under this many points, even if the app would
    /// accept it: it would be of no use any more.
    static let minimumExtent: CGFloat = 120

    /// Past this many points the size received is no longer the one asked
    /// for; under it, rounding.
    static let sizeTolerance: CGFloat = 1

    let axis: ForkLinkAxis
    let originalFirst: CGRect
    let originalSecond: CGRect
    let gap: CGFloat
    let minimumFirst: CGFloat
    let minimumSecond: CGFloat

    init(axis: ForkLinkAxis, first: CGRect, second: CGRect) {
        self.axis = axis
        originalFirst = first
        originalSecond = second
        gap = second.minAlong(axis) - first.maxAlong(axis)
        // Never more than the starting size, so the starting edge stays
        // reachable even for a window that is already very narrow.
        minimumFirst = min(Self.minimumExtent, first.extentAlong(axis))
        minimumSecond = min(Self.minimumExtent, second.extentAlong(axis))
    }

    /// The edge, the first window's end, when the drag begins.
    var startBorder: CGFloat { originalFirst.maxAlong(axis) }

    /// The edge asked for, bounded so each window keeps its floor.
    func clampedBorder(_ proposed: CGFloat) -> CGFloat {
        let lower = originalFirst.minAlong(axis) + minimumFirst
        let upper = originalSecond.maxAlong(axis) - minimumSecond - gap
        guard lower <= upper else { return startBorder }
        return min(max(proposed, lower), upper)
    }

    /// Both frames for an edge (bounded on the way): the gap unchanged and
    /// the total stretch unchanged.
    func frames(borderAt proposed: CGFloat) -> (first: CGRect, second: CGRect) {
        let border = clampedBorder(proposed)
        var first = originalFirst
        var second = originalSecond
        switch axis {
        case .vertical:
            first.size.width = border - originalFirst.minX
            second.origin.x = border + gap
            second.size.width = originalSecond.maxX - border - gap
        case .horizontal:
            first.size.height = border - originalFirst.minY
            second.origin.y = border + gap
            second.size.height = originalSecond.maxY - border - gap
        }
        return (first, second)
    }

    /// Where the edge really landed, from the sizes read back after a
    /// write: `nil` when both windows took the size asked for. Otherwise the
    /// frames are to be written again for this edge, which the stubborn
    /// window already accepts; the other one comes to meet it.
    ///
    /// Nothing is learned from one move to the next: the next move asks
    /// again from the pointer, so an app rounding to its grid eventually
    /// moves on to its next step, where a "minimum" learned from mere
    /// rounding would have blocked the edge for good (seen with Terminal:
    /// the edge could no longer be brought back toward it).
    ///
    /// A window left larger than asked (a minimum, or rounding up) wins:
    /// it is a constraint, the other one gives way.
    func settledBorder(requested: (first: CGRect, second: CGRect),
                       actualFirst: CGRect, actualSecond: CGRect) -> CGFloat? {
        let extraFirst = actualFirst.extentAlong(axis) - requested.first.extentAlong(axis)
        let extraSecond = actualSecond.extentAlong(axis) - requested.second.extentAlong(axis)
        let borderFromFirst = originalFirst.minAlong(axis) + actualFirst.extentAlong(axis)
        let borderFromSecond = originalSecond.maxAlong(axis) - actualSecond.extentAlong(axis) - gap
        if extraFirst > Self.sizeTolerance { return borderFromFirst }
        if extraSecond > Self.sizeTolerance { return borderFromSecond }
        if extraFirst < -Self.sizeTolerance { return borderFromFirst }
        if extraSecond < -Self.sizeTolerance { return borderFromSecond }
        return nil
    }

    /// The order of the writes: the shrinking window first, the growing one
    /// after. At worst a one-frame hole between them, never an overlap.
    static func writeOrder(from oldBorder: CGFloat, to newBorder: CGFloat) -> [Side] {
        newBorder > oldBorder ? [.second, .first] : [.first, .second]
    }

    /// A shrinking window takes its size before its position: the other way
    /// round it would spill out of its stretch (and off the screen) for a
    /// moment before shrinking.
    static func resizesBeforeMoving(from old: CGRect, to new: CGRect) -> Bool {
        new.width * new.height < old.width * old.height
    }
}

/// Where a handle belongs in the window stack: just above the frontmost of
/// its two windows, and never above a third window that covers the edge,
/// which keeps its clicks. Pure over a front-to-back window list.
enum ForkLinkedResizeOrder {
    struct Window: Equatable {
        let number: CGWindowID
        let layer: Int
        /// Accessibility coordinates, like the window list's own bounds.
        let bounds: CGRect

        /// The visible windows of the current Space, front to back.
        static func frontToBack() -> [Window] {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] ?? []
            return list.compactMap { info in
                guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsInfo)
                else { return nil }
                return Window(number: number,
                              layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                              bounds: bounds)
            }
        }
    }

    enum Placement: Equatable {
        /// One of the two windows is not on screen (another Space, hidden).
        case hidden
        /// Already where it belongs.
        case keep
        /// To be ordered just above this window.
        case above(CGWindowID)
    }

    static func placement(handle: CGWindowID, strip: CGRect,
                          first: CGWindowID, second: CGWindowID,
                          in windows: [Window]) -> Placement {
        guard let firstIndex = windows.firstIndex(where: { $0.number == first }),
              let secondIndex = windows.firstIndex(where: { $0.number == second })
        else { return .hidden }
        let front = min(firstIndex, secondIndex)
        guard let me = windows.firstIndex(where: { $0.number == handle }), me < front else {
            return .above(windows[front].number)
        }
        let blocked = windows[(me + 1)..<front].contains {
            $0.layer == 0 && $0.number != first && $0.number != second && $0.bounds.intersects(strip)
        }
        return blocked ? .above(windows[front].number) : .keep
    }

    /// The side Command resizes alone: the frontmost of the two, the first
    /// when the order cannot be read.
    static func frontSide(first: CGWindowID, second: CGWindowID,
                          in windows: [Window]) -> ForkLinkedResize.Side {
        let firstIndex = windows.firstIndex { $0.number == first } ?? .max
        let secondIndex = windows.firstIndex { $0.number == second } ?? .max
        return secondIndex < firstIndex ? .second : .first
    }
}

// MARK: - Measures along an axis

extension CGRect {
    /// Along the axis the edge moves on.
    func minAlong(_ axis: ForkLinkAxis) -> CGFloat { axis == .vertical ? minX : minY }
    func maxAlong(_ axis: ForkLinkAxis) -> CGFloat { axis == .vertical ? maxX : maxY }
    func extentAlong(_ axis: ForkLinkAxis) -> CGFloat { axis == .vertical ? width : height }
    /// Across it: the length of the edge.
    func minAcross(_ axis: ForkLinkAxis) -> CGFloat { axis == .vertical ? minY : minX }
    func maxAcross(_ axis: ForkLinkAxis) -> CGFloat { axis == .vertical ? maxY : maxX }
}
